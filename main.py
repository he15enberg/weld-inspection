"""weldz server: one endpoint, one job.

    POST /measure   multipart: meta (JSON) + color (JPEG) + depth + confidence
                    -> detections in millimetres + an annotated JPEG

Run:
    set WELDZ_CKPT=D:\\path\\to\\checkpoint_best_ema.pth
    uvicorn main:app --host 127.0.0.1 --port 8000

Bind to localhost and put cloudflared in front. The tunnel makes an OUTBOUND
connection, so there is no firewall rule to add and the phone gets HTTPS -- which
iOS App Transport Security requires anyway.
"""

from __future__ import annotations

import base64
import io
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
from fastapi import FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image

import assess
import frame
import geometry
import measure as mm
import overlay
import rules
import ruleset
import scoring
import store
from model import CLASSES, model

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("weldz")

TOKEN = os.environ.get("WELDZ_TOKEN", "").strip()

# Server-side fallbacks for the geometry, used when the phone does not say.
# An older app build sends neither, so it keeps today's behaviour unless the
# operator turns these on -- which is why the default is 0/0 rather than the
# 270/1380 this hardware wants. The app sends both explicitly.
ROTATE = int(os.environ.get("WELDZ_ROTATE", "0"))
CROP = int(os.environ.get("WELDZ_CROP", "0"))


def _as_int(value, default: int) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _as_float(value, default: float, low: float, high: float) -> float:
    """Parse and clamp. Anything unparseable falls back rather than 422s -- a
    typo in a settings field should not cost the operator the capture."""
    try:
        return min(max(float(value), low), high)
    except (TypeError, ValueError):
        return default


def check(token: str | None) -> None:
    """Reject unless the caller presents WELDZ_TOKEN, when one is configured.

    Unset means open, which keeps a quick tunnel usable with no ceremony.
    Compared with compare_digest so a wrong guess cannot be narrowed down by
    timing the reply.
    """
    if not TOKEN:
        return
    if not token or not secrets.compare_digest(token, TOKEN):
        raise HTTPException(401, "bad or missing X-Weldz-Token")


@asynccontextmanager
async def lifespan(_: FastAPI):
    model.load()          # loads and warms; the first request must not pay for it
    store.init()
    log.info("assessment: %s", assess.URL or "off (WELDZ_VLM_URL unset)")
    log.info("auth: %s",
             "X-Weldz-Token required" if TOKEN else "open (WELDZ_TOKEN unset)")
    yield


app = FastAPI(title="weldz", lifespan=lifespan)


def mask_png(mask: np.ndarray, w: int, h: int) -> str:
    """One mask, downsampled to the DEPTH grid, as a base64 PNG.

    The phone needs masks for two things: cropping the point cloud to the
    workpiece, and nothing else. Cropping happens in depth space, so there is no
    point shipping a 1920x1440 mask -- (w, h) here is the depth grid the phone
    sent, and NEAREST keeps it a clean binary after the downsample.

    PNG because a binary blob compresses to about a kilobyte, and because Dart
    can already decode PNG to raw bytes without a package.
    """
    full = Image.fromarray(mask.astype(np.uint8) * 255, mode="L")
    small = full.resize((w, h), Image.NEAREST)
    buf = io.BytesIO()
    small.save(buf, "PNG", optimize=True)
    return base64.b64encode(buf.getvalue()).decode()


@app.get("/health")
def health(x_weldz_token: str | None = Header(None)):
    check(x_weldz_token)
    return {"ok": model.ready, "auth": bool(TOKEN), "model": model.info()}


@app.post("/measure")
async def measure_endpoint(
    meta: str = Form(...),
    color: UploadFile = File(...),
    depth: UploadFile = File(...),
    confidence: UploadFile | None = File(None),
    x_weldz_token: str | None = Header(None),
):
    check(x_weldz_token)
    if not model.ready:
        raise HTTPException(503, model.error or "model not loaded")

    t0 = time.perf_counter()
    try:
        m = json.loads(meta)
    except json.JSONDecodeError as exc:
        raise HTTPException(422, f"meta is not JSON: {exc}") from exc

    for key in ("fx", "depth_width", "depth_height"):
        if key not in m:
            raise HTTPException(422, f"meta is missing '{key}'")

    # Held rather than streamed: an UploadFile can only be read once, and
    # storage needs the same bytes the model saw.
    color_bytes = await color.read()
    depth_bytes = await depth.read()
    conf_bytes = await confidence.read() if confidence else b""

    img = Image.open(io.BytesIO(color_bytes)).convert("RGB")
    dw, dh = int(m["depth_width"]), int(m["depth_height"])
    try:
        depth_m = mm.decode_depth(depth_bytes, dw, dh)
        conf = mm.decode_confidence(conf_bytes or None, dw, dh)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc

    # fx/fy are quoted for the captured image. If the JPEG was downscaled before
    # upload, scale them to match or every millimetre is wrong by that factor.
    # Computed BEFORE the geometry below: once the frame is turned or cropped,
    # img.width no longer describes the upload and this ratio is meaningless.
    upscale = img.width / float(m.get("image_width", img.width))
    fx = float(m["fx"]) * upscale
    fy = float(m.get("fy", m["fx"])) * upscale

    # Turn and square-crop before the model sees it. See frame.py -- the model
    # has never seen a part on its end or a 4:3 frame, and on the stored
    # captures this is the difference between finding the weld seam in 3 of 9
    # frames and 9 of 9. Depth and confidence get the same treatment, or
    # measure.py's "colour and depth share one field of view" premise breaks
    # and the millimetres go quietly wrong.
    img, depth_m, conf, geo = frame.prepare(
        img, depth_m, conf,
        rotate=_as_int(m.get("rotate"), ROTATE),
        crop=_as_int(m.get("crop"), CROP))
    dw, dh = geo["depth_output"]
    if geo["swap_fxfy"]:
        fx, fy = fy, fx              # a quarter turn exchanges the two axes

    # Clamped, not trusted: the threshold is a free-text field in the app now,
    # and 0 would return all 300 queries while 1.0 returns nothing.
    threshold = _as_float(m.get("conf"), 0.25, 0.01, 0.95)

    t1 = time.perf_counter()
    xyxy, scores, cls, masks = model.infer(img, threshold)
    t2 = time.perf_counter()

    rows = []
    for i in range(len(scores)):
        box = [float(v) for v in xyxy[i]]
        row = {
            "label": CLASSES[int(cls[i])],
            "confidence": round(float(scores[i]), 3),
            "bbox_px": [int(round(v)) for v in box],
            # normalised too, so the client never needs the pixel size
            "bbox": [round(box[0] / img.width, 4), round(box[1] / img.height, 4),
                     round(box[2] / img.width, 4), round(box[3] / img.height, 4)],
        }
        if masks is not None:
            row.update(mm.measure(masks[i], box, depth_m, conf, fx, img.width))
            # Turned back before it is shipped: the phone holds the untouched
            # capture, so a mask in model space would be indexed against a grid
            # of a different size and shape. That is what silently emptied the
            # workpiece cloud.
            row["mask_png"] = mask_png(
                frame.unrotate_mask(masks[i], geo), dw, dh)
        rows.append(row)
    t3 = time.perf_counter()

    # Seam metrics and the spatial gate, both in MODEL space -- the masks are
    # still model-space here, and they must be, because `analyse` compares them
    # against each other. It annotates rows with on_seam rather than dropping
    # anything: an excluded detection you cannot see is indistinguishable from
    # one that was never found.
    seam = geometry.analyse(rows, masks)

    # The verdict: fatal classes from rules.py (code, uneditable), then the
    # five tunable rules and the weighted score from scoring.py. Never the VLM
    # -- a model asked "does a crack mean reject" adds nothing and cannot be
    # audited. The ruleset version travels with the capture so two captures
    # judged under different limits can be told apart later.
    rule_config = ruleset.load()
    judgement = scoring.evaluate(rows, seam, rule_config)

    # Drawn in model space -- rows still carry model-space boxes at this point,
    # which is what overlay.draw() needs -- then turned back for the client.
    annotated = frame.unrotate_image(overlay.draw(img, rows, masks), geo)
    buf = io.BytesIO()
    annotated.save(buf, "JPEG", quality=88)
    overlay_jpeg = buf.getvalue()

    # Now the boxes follow the picture. Everything the client receives is in
    # ONE space from here on: cropped, and the way up the capture arrived.
    turn = (geo["rotate"] // 90) % 4
    if turn:
        for row in rows:
            box = frame.unmap_box(row["bbox_px"], turn,
                                  annotated.width, annotated.height)
            row["bbox_px"] = box
            row["bbox"] = [round(box[0] / annotated.width, 4),
                           round(box[1] / annotated.height, 4),
                           round(box[2] / annotated.width, 4),
                           round(box[3] / annotated.height, 4)]
    t4 = time.perf_counter()

    # The VLM sees the overlay, not the raw frame: that is what lets it comment
    # on what the detector found rather than re-detecting from scratch. It runs
    # inline because 4B answers in ~3 s; it can only ever add text, so any
    # failure comes back as a status the app renders and the capture stands.
    # Both of these are stored too: `cover` is the framing number, and plotted
    # against verdict it is what turns "small in frame gives bad results" from
    # an assertion into something measured.
    cover = assess.coverage(rows, masks, img.width * img.height)
    frame_fill = round(float((depth_m > 0).mean()), 4)

    assessment = assess.request(overlay_jpeg, judgement, rows, cover,
                                frame_fill, seam)
    t5 = time.perf_counter()

    total = time.perf_counter() - t0
    response = {
        "detections": rows,
        # the size AFTER the turn and crop -- what `annotated` is, and what
        # every bbox in `detections` is measured against
        "image": {"width": img.width, "height": img.height},
        # What was done to get there. `crop_box_source` and
        # `depth_crop_box_source` are the rectangles in the coordinates of the
        # frame the PHONE holds -- it crops its own JPEG and depth with those,
        # which is what puts its point cloud in the same space as the masks.
        # The archive needs all of it so a transformed capture can never be
        # mistaken for a raw one.
        "geometry": geo,
        # seam length/width/continuity, and how many detections the
        # spatial gate set aside as not being on the weld
        "seam": seam,
        "annotated": base64.b64encode(overlay_jpeg).decode(),
        "judgement": judgement,
        "assessment": assessment,
        "timing_ms": {
            "decode": round((t1 - t0) * 1000),
            "infer": round((t2 - t1) * 1000),
            "measure": round((t3 - t2) * 1000),
            "assess": round((t5 - t4) * 1000),
            "total": round(total * 1000),
        },
    }

    # Persisted after the response is built, and save() swallows everything --
    # a full disk must not turn a good inspection into a 500. The capture id
    # comes back so the app could deep-link to it later.
    response["id"] = store.save(
        result=response,
        color=color_bytes,
        overlay=overlay_jpeg,
        depth=depth_bytes,
        confidence=conf_bytes,
        meta={**m, "geometry": geo, "conf_used": threshold,
              "ruleset_version": rule_config.get("version")},
        stamp=store.model_stamp(model.info()),
        coverage=cover,
        depth_fill=frame_fill,
    )

    log.info("measure: %d detections (%d off-seam), verdict=%s score %.0f, "
             "rot %d crop %d, thr %.2f, %.0f ms (infer %.0f, assess %.0f)%s",
             len(rows), judgement["off_seam_ignored"],
             judgement["verdict"], judgement["score"],
             geo["rotate"], geo["crop"], threshold, total * 1000,
             (t2 - t1) * 1000, (t5 - t4) * 1000,
             f" -> {response['id']}" if response["id"] else "")
    return response


# ---------------------------------------------------------------------------
# stored captures, for the dashboard
# ---------------------------------------------------------------------------

@app.get("/captures")
def captures(
    verdict: str | None = None,
    label: str | None = None,
    since: str | None = None,
    until: str | None = None,
    limit: int = Query(40, ge=1, le=200),
    offset: int = Query(0, ge=0),
    x_weldz_token: str | None = Header(None),
):
    check(x_weldz_token)
    return store.listing(verdict=verdict, label=label, since=since,
                         until=until, limit=limit, offset=offset)


@app.get("/captures/{cid}")
def capture(cid: str, x_weldz_token: str | None = Header(None)):
    check(x_weldz_token)
    rec = store.record(cid)
    if rec is None:
        raise HTTPException(404, "capture not found")
    return rec


@app.get("/captures/{cid}/file/{name}")
def capture_file(cid: str, name: str, x_weldz_token: str | None = Header(None)):
    check(x_weldz_token)
    # store.file_path checks `name` against a whitelist rather than joining a
    # user string onto a path, so `../` can never resolve outside the capture.
    path = store.file_path(cid, name)
    if path is None:
        raise HTTPException(404, "file not found")
    return FileResponse(path, headers={"Cache-Control": "public, max-age=86400"})


@app.get("/rules")
def get_rules(x_weldz_token: str | None = Header(None)):
    """The editable rule set, plus the metric vocabulary the editor offers.

    METRICS is sent with it so the dashboard never hardcodes a metric name the
    server does not implement -- the list of what can be measured lives in one
    place, here.
    """
    check(x_weldz_token)
    return {**ruleset.load(),
            "metrics": {k: {"label": v[0], "unit": v[1], "help": v[2]}
                        for k, v in ruleset.METRICS.items()},
            "comparators": list(ruleset.COMPARATORS),
            "outcomes": list(ruleset.OUTCOMES),
            "needs_seam": sorted(ruleset.NEEDS_SEAM)}


@app.put("/rules")
async def put_rules(doc: dict, x_weldz_token: str | None = Header(None)):
    check(x_weldz_token)
    try:
        return ruleset.save(doc)
    except ValueError as exc:
        # 422 with the reason, so the editor can point at the offending field
        raise HTTPException(422, str(exc)) from exc


@app.post("/rescore")
def rescore(dry_run: bool = Query(True),
            limit: int = Query(500, ge=1, le=5000),
            x_weldz_token: str | None = Header(None)):
    """Re-judge stored captures under the current rules.

    The detections and the millimetres are already on disk, so changing a limit
    does not need the model again -- which is what makes the rule editor worth
    having: move a limit, see the whole archive re-grade.

    `dry_run` is the default on purpose. Overwriting an archive of verdicts is
    not something to do by accident, so the dashboard previews first and the
    caller has to ask for the write.

    Detections are never touched. Only the judgement block is rewritten.
    """
    check(x_weldz_token)
    config = ruleset.load()
    changed, examined, errors = [], 0, 0

    for cid in store.ids(limit=limit):
        rec = store.record(cid)
        if not rec or rec.get("demo"):
            continue
        rows = rec.get("detections") or []
        if not rows:
            continue
        examined += 1
        try:
            # The seam block was computed when the capture was taken and stored
            # with it. Recomputing it would need the masks, which are not kept
            # at full resolution -- so a capture from before this feature has no
            # seam, and its seam-derived rules correctly come back
            # indeterminate rather than being invented.
            fresh = scoring.evaluate(rows, rec.get("seam"), config)
        except Exception:                                          # noqa: BLE001
            errors += 1
            continue
        before = (rec.get("judgement") or {}).get("verdict")
        if before != fresh["verdict"]:
            changed.append({"id": cid, "from": before, "to": fresh["verdict"],
                            "score": fresh["score"],
                            "headline": fresh["headline"]})
        if not dry_run:
            store.rejudge(cid, fresh, config.get("version"))

    moves: dict[str, int] = {}
    for c in changed:
        moves[f"{c['from']} -> {c['to']}"] = moves.get(f"{c['from']} -> {c['to']}", 0) + 1
    return {"dry_run": dry_run, "ruleset_version": config.get("version"),
            "examined": examined, "changed": len(changed), "moves": moves,
            "errors": errors, "sample": changed[:25]}


@app.get("/stats")
def stats(days: int = Query(30, ge=1, le=365),
          x_weldz_token: str | None = Header(None)):
    check(x_weldz_token)
    return store.stats(days)


# The dashboard, mounted last so it cannot shadow an API route.
_DASHBOARD = Path(__file__).resolve().parent.parent / "weldz-dashboard"
if _DASHBOARD.is_dir():
    app.mount("/", StaticFiles(directory=_DASHBOARD, html=True), name="dashboard")
    log.info("dashboard: %s", _DASHBOARD)
