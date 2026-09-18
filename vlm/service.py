r"""Qwen3-VL-4B as a small HTTP service, for the weldz backend to call.

    ..\..\..\.venv\Scripts\python.exe -m uvicorn service:app --host 127.0.0.1 --port 8001

Normally started by ../serve.py rather than directly.

Runs on the same interpreter and the same GPU as weldz-server, in its own
process on its own port. That separation is the point, and it is not
historical:

  * Fault isolation. A 4B model that OOMs or wedges must not take the detector
    with it. Proven in practice -- when the GPU went away under this service
    one morning, `assess.py` returned {"status": "disabled"} and every capture
    still produced a full verdict. In one process that outage would have cost
    the whole inspection.
  * One generation at a time. `Model.lock` serialises, so two captures cannot
    interleave and blow the KV cache budget.

It used to live in WSL, on the grounds that it needed transformers-from-git
while the server needed rfdetr's pinned torch. That conflict has since
dissolved -- both now run torch 2.11.0+cu128, and rfdetr accepts
transformers<6 -- so it moved here, which removes WSL's GPU passthrough as a
failure mode and leaves one venv to maintain.

GPU is required, not preferred: `device_map="cuda:0"` is not a fallback, and
4B in bf16 on CPU would be minutes per capture rather than seconds -- far too
slow to sit inside the capture round trip, which is the only reason
weldz-server calls this synchronously instead of polling a job id.

The weights are ~8 GB in bf16 (no bitsandbytes, no quantization loss), leaving
the 5090 plenty of room for RF-DETR at the same time. Set HF_HOME to keep the
cache off the system drive.
"""

from __future__ import annotations

import base64
import io
import json
import logging
import os
import re
import threading
import time

import torch
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("vlm")

MODEL_ID = os.environ.get("WELDZ_VLM_MODEL", "Qwen/Qwen3-VL-4B-Instruct")

# Qwen3-VL uses dynamic resolution, so a 1920x1440 frame becomes 1500+ image
# tokens and buys latency directly. 1024 on the long side keeps the bead legible
# while roughly quartering that.
MAX_SIDE = int(os.environ.get("WELDZ_VLM_MAX_SIDE", "1024"))

# Short on purpose: the app shows 2-3 sentences, and a 4B model padded out to
# 500 tokens does not get better, only vaguer.
MAX_NEW = int(os.environ.get("WELDZ_VLM_MAX_TOKENS", "220"))

# Low, not zero: two captures of the same weld reading differently would
# undermine the whole feature.
TEMPERATURE = float(os.environ.get("WELDZ_VLM_TEMP", "0.2"))

DEFECTS = {"crack", "discontinuity", "undercut", "porosity", "spatter", "overlap"}
REJECTABLE = {"crack", "discontinuity"}


# ---------------------------------------------------------------------------
# the prompt
# ---------------------------------------------------------------------------

SYSTEM = """You are helping a welding inspector read an automated result.

A detector has already found and measured the features. A fixed rule table has
already decided the verdict and worked out how close each rule came to its
limit. None of that is your job and none of it is up for debate.

Your job is three things:

1. Say whether the PHOTOGRAPH is good enough to judge from. If the part is
   small in the frame, blurred, badly lit, or cut off, set "usable": false and
   say so in one sentence. A bad photograph is the most common reason a result
   is poor, and refusing it is more useful than describing it.
2. Explain what is visible, in plain language.
3. Say WHERE on the weld the tightest rule is. You are told which rule is
   tightest and what it measured; point at the place, do not recompute it.

How to answer:
- 2 to 3 sentences in "overall". No headings, no bullet lists, no restating
  numbers you were given.
- Never estimate a size. The measurements are given to you; you cannot measure
  from a photograph.
- Only raise a concern if it is CLEARLY visible. If the weld looks reasonable,
  say so plainly - a short, calm answer is the right answer.
- "bead_quality" is a few short descriptors of what the bead LOOKS like:
  uniform, ropey, irregular width, poor wetting, heavy spatter, clean.
- "agrees_with_verdict" is your own read of the picture against the verdict you
  were given. Disagreeing is allowed and useful; it raises a flag for a person,
  it does not change the outcome. Give your reason in one sentence.

Reply with JSON only:
{"usable": true, "image_quality": "good|fair|poor", "overall": "...",
 "bead_quality": ["..."], "binding_rule_note": "...", "concerns": ["..."],
 "visual_flags": ["..."], "agrees_with_verdict": true, "reason": "...",
 "suspected": ["..."]}

"concerns", "visual_flags" and "suspected" may be empty. Put a class name in
"suspected" ONLY if you can clearly see that defect and it is absent from the
detection list."""


def build_prompt(payload: "AssessRequest") -> str:
    lines = [f"Verdict from the rules: {payload.verdict.upper()} - {payload.headline}"]

    if payload.detections:
        lines.append("\nDetected:")
        for d in payload.detections:
            bit = f"- {d.get('label', '?')} ({int(round(d.get('confidence', 0) * 100))}%)"
            if d.get("width_mm") is not None:
                bit += f", {d['width_mm']:.1f} x {d.get('height_mm', 0):.1f} mm"
            if d.get("distance_m") is not None:
                bit += f", {int(round(d['distance_m'] * 1000))} mm away"
            lines.append(bit)
    else:
        lines.append("\nThe detector found nothing.")

    # Framing is the strongest lever on result quality and the server can
    # compute it for free, so hand the number over rather than hoping the model
    # notices on its own.
    if payload.coverage is not None:
        lines.append(f"\nThe workpiece fills about {payload.coverage * 100:.0f}% "
                     f"of the frame.")
    if payload.depth_fill is not None:
        lines.append(f"Depth coverage over the frame: {payload.depth_fill * 100:.0f}%.")

    if payload.seam and payload.seam.get("status") == "ok":
        sm = payload.seam
        bits = []
        if sm.get("length_mm"):
            bits.append(f"{sm['length_mm']:.0f} mm long")
        if sm.get("width_mm"):
            bits.append(f"{sm['width_mm']:.1f} mm wide")
        if sm.get("continuity") is not None:
            bits.append(f"covering {sm['continuity'] * 100:.0f}% of the joint")
        if bits:
            lines.append("\nThe weld seam measures " + ", ".join(bits) + ".")
        if sm.get("defects_off_seam"):
            lines.append(f"{sm['defects_off_seam']} detection(s) sit off the "
                         f"weld and have been ignored.")
    elif payload.seam and payload.seam.get("status"):
        lines.append(f"\nThe weld seam could not be measured: "
                     f"{payload.seam['status']}.")

    # The rules, with the arithmetic already done. The model is NOT being
    # asked whether the weld complies -- that is computed and auditable. It
    # is being asked where on the weld the tightest rule is, which is a
    # question a vision model can actually answer.
    if payload.rules:
        lines.append("\nRule check (already computed -- do not recompute):")
        for r in payload.rules:
            util = r.get("utilisation")
            state = (f"{util * 100:.0f}% of limit"
                     if isinstance(util, (int, float)) else "not measurable")
            lines.append(f"- {r.get('name', '?')}: {r.get('detail', '')} "
                         f"({state}, {r.get('status', '?')})")
    if payload.binding and payload.binding.get("name"):
        lines.append(f"\nTightest rule: {payload.binding['name']}.")

    lines.append("\nThe image shows the detector's own overlay: coloured masks "
                 "and boxes on the captured photo.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------

class Model:
    def __init__(self) -> None:
        self.model = None
        self.processor = None
        self.error: str | None = None
        self.load_ms: float | None = None
        self.last_ms: float | None = None
        # One GPU, one model: serialise so two captures cannot interleave
        # generations and blow the KV cache budget.
        self.lock = threading.Lock()

    @property
    def ready(self) -> bool:
        return self.model is not None

    def load(self) -> None:
        try:
            from transformers import AutoProcessor, Qwen3VLForConditionalGeneration

            if not torch.cuda.is_available():
                # device_map="cuda:0" would fail below anyway, but with a
                # traceback that reads like a transformers problem. This is the
                # actual cause, and on CPU a 4B model is minutes per capture --
                # useless inside a synchronous round trip.
                raise RuntimeError(
                    "no CUDA device. This service must run on the GPU; on CPU a "
                    "capture would take minutes. Check nvidia-smi and that this "
                    "interpreter has a CUDA build of torch "
                    f"(this one reports torch.version.cuda={torch.version.cuda}).")

            t0 = time.perf_counter()
            log.info("loading %s onto %s", MODEL_ID, torch.cuda.get_device_name(0))
            self.processor = AutoProcessor.from_pretrained(MODEL_ID)
            self.model = Qwen3VLForConditionalGeneration.from_pretrained(
                MODEL_ID,
                dtype=torch.bfloat16,     # 4B fits at full precision; no NF4 needed
                device_map="cuda:0",
            ).eval()
            self.load_ms = (time.perf_counter() - t0) * 1000
            log.info("ready in %.0f ms", self.load_ms)
        except Exception as exc:                                   # noqa: BLE001
            self.error = str(exc)
            self.model = None
            log.exception("could not load the model")

    def generate(self, image: Image.Image, prompt: str) -> str:
        messages = [
            {"role": "system", "content": [{"type": "text", "text": SYSTEM}]},
            {"role": "user", "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": prompt},
            ]},
        ]
        with self.lock:
            t0 = time.perf_counter()
            inputs = self.processor.apply_chat_template(
                messages,
                tokenize=True,
                add_generation_prompt=True,
                return_dict=True,
                return_tensors="pt",
            ).to(self.model.device)

            with torch.inference_mode():
                out = self.model.generate(
                    **inputs,
                    max_new_tokens=MAX_NEW,
                    do_sample=TEMPERATURE > 0,
                    temperature=TEMPERATURE or None,
                )
            # generate() returns the prompt too; keep only what was added
            new = out[0][inputs["input_ids"].shape[1]:]
            text = self.processor.decode(new, skip_special_tokens=True)
            self.last_ms = (time.perf_counter() - t0) * 1000
        return text.strip()

    def info(self) -> dict:
        gpu = {}
        if torch.cuda.is_available():
            gpu = {
                "device": torch.cuda.get_device_name(0),
                "allocated_gb": round(torch.cuda.memory_allocated(0) / 1e9, 2),
                "total_gb": round(
                    torch.cuda.get_device_properties(0).total_memory / 1e9, 1),
            }
        return {
            "ready": self.ready,
            "model": MODEL_ID,
            "max_side": MAX_SIDE,
            "max_new_tokens": MAX_NEW,
            "load_ms": round(self.load_ms) if self.load_ms else None,
            "last_ms": round(self.last_ms) if self.last_ms else None,
            "error": self.error,
            "gpu": gpu,
        }


model = Model()


# ---------------------------------------------------------------------------
# lenient parsing
# ---------------------------------------------------------------------------

def parse(text: str) -> dict:
    """Pull the JSON out, and fall back to prose rather than failing.

    A 4B model will occasionally wrap the object in prose or a code fence. Since
    the summary is the only field the app really needs, a failed parse should
    degrade to "use the whole reply as the summary" -- not to an error.
    """
    body = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    match = re.search(r"\{.*\}", body, re.S)
    if match:
        try:
            doc = json.loads(match.group(0))
            if isinstance(doc, dict) and not doc.get("summary"):
                # the schema calls it "overall"; older prompts said
                # "summary". Accept either rather than dropping a good
                # reply over a key name.
                doc["summary"] = doc.get("overall")
            if isinstance(doc, dict) and doc.get("summary"):
                return {
                    "summary": str(doc["summary"]).strip(),
                    "concerns": [str(c) for c in doc.get("concerns") or []][:4],
                    "image_quality": _quality(doc.get("image_quality")),
                    "usable": _bool(doc.get("usable"), True),
                    "bead_quality": [str(b) for b in doc.get("bead_quality") or []][:5],
                    "binding_rule_note": str(doc.get("binding_rule_note") or "").strip(),
                    "visual_flags": [str(v) for v in doc.get("visual_flags") or []][:4],
                    "agrees_with_verdict": _bool(doc.get("agrees_with_verdict"), None),
                    "reason": str(doc.get("reason") or "").strip(),
                    "suspected": [
                        s for s in
                        (str(x).lower().strip() for x in doc.get("suspected") or [])
                        if s in DEFECTS
                    ],
                    "parsed": True,
                }
        except json.JSONDecodeError:
            pass

    # Truncated JSON would otherwise put a raw `{"summary": "half a sen` into
    # the app. Rescue the field if it is there, and show nothing if it is not --
    # a blank assessment is honest, a broken one looks like a crash.
    salvage = re.search(r'"summary"\s*:\s*"([^"]{8,})', body)
    if salvage:
        log.warning("JSON was malformed; salvaged the summary field")
        return {"summary": salvage.group(1).strip(), "concerns": [],
                "image_quality": None, "suspected": [], "parsed": False}

    if body.lstrip().startswith("{"):
        log.warning("unparseable JSON and nothing to salvage")
        return {"summary": "", "concerns": [], "image_quality": None,
                "suspected": [], "parsed": False}

    log.warning("no JSON in the reply; using it as prose")
    return {"summary": body, "concerns": [], "image_quality": None,
            "suspected": [], "parsed": False}


def _bool(value, default):
    """Tolerant boolean: the model sometimes writes "yes" or "true"."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        low = value.strip().lower()
        if low in ("true", "yes", "y", "1"):
            return True
        if low in ("false", "no", "n", "0"):
            return False
    return default


def _quality(value) -> str | None:
    v = str(value or "").lower().strip()
    return v if v in ("good", "fair", "poor") else None


def shrink(image: Image.Image) -> Image.Image:
    if max(image.size) <= MAX_SIDE:
        return image
    scale = MAX_SIDE / max(image.size)
    size = (max(int(image.width * scale), 1), max(int(image.height * scale), 1))
    return image.resize(size, Image.LANCZOS)


# ---------------------------------------------------------------------------
# api
# ---------------------------------------------------------------------------

class AssessRequest(BaseModel):
    image: str                       # base64 JPEG, the annotated overlay
    verdict: str = "approve"
    headline: str = ""
    score: float | None = None
    bands: dict | None = None
    detections: list[dict] = []
    rules: list[dict] = []           # measured / limit / utilisation each
    binding: dict | None = None      # the rule closest to its limit
    seam: dict | None = None         # length, width, continuity
    coverage: float | None = None    # workpiece mask / frame area
    depth_fill: float | None = None


app = FastAPI(title="weldz-vlm")


@app.on_event("startup")
def _startup() -> None:
    model.load()


@app.get("/health")
def health():
    return {"ok": model.ready, **model.info()}


@app.post("/assess")
def assess(req: AssessRequest):
    if not model.ready:
        raise HTTPException(503, model.error or "model not loaded")

    try:
        image = shrink(Image.open(io.BytesIO(base64.b64decode(req.image))).convert("RGB"))
    except Exception as exc:                                       # noqa: BLE001
        raise HTTPException(422, f"could not decode the image: {exc}") from exc

    t0 = time.perf_counter()
    raw = model.generate(image, build_prompt(req))
    result = parse(raw)

    # The one place the VLM can influence the UI: a rejectable defect it can see
    # and the detector did not. It does NOT change the verdict -- it raises a
    # warning for a person to judge. Keeping the verdict reproducible matters
    # more than catching every miss automatically.
    missed = [
        s for s in result["suspected"]
        if s in REJECTABLE
        and not any(d.get("label") == s for d in req.detections)
    ]
    result["missed_rejectable"] = missed

    result["ms"] = round((time.perf_counter() - t0) * 1000)
    log.info("assess: %d ms, quality=%s, concerns=%d, missed=%s",
             result["ms"], result["image_quality"], len(result["concerns"]), missed)
    return result
