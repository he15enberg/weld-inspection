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
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from PIL import Image

import measure as mm
import overlay
from model import CLASSES, model

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("weldz")


@asynccontextmanager
async def lifespan(_: FastAPI):
    model.load()          # loads and warms; the first request must not pay for it
    yield


app = FastAPI(title="weldz", lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": model.ready, "model": model.info()}


@app.post("/measure")
async def measure_endpoint(
    meta: str = Form(...),
    color: UploadFile = File(...),
    depth: UploadFile = File(...),
    confidence: UploadFile | None = File(None),
):
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

    img = Image.open(io.BytesIO(await color.read())).convert("RGB")
    dw, dh = int(m["depth_width"]), int(m["depth_height"])
    try:
        depth_m = mm.decode_depth(await depth.read(), dw, dh)
        conf = mm.decode_confidence(await confidence.read() if confidence else None, dw, dh)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc

    # fx is quoted for the captured image. If the JPEG was downscaled before
    # upload, scale fx to match, or every millimetre is wrong by that factor.
    fx = float(m["fx"]) * (img.width / float(m.get("image_width", img.width)))
    threshold = float(m.get("conf", 0.25))

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
        rows.append(row)
    t3 = time.perf_counter()

    annotated = overlay.draw(img, rows, masks)
    buf = io.BytesIO()
    annotated.save(buf, "JPEG", quality=88)

    total = time.perf_counter() - t0
    log.info("measure: %d detections, %.0f ms (infer %.0f)",
             len(rows), total * 1000, (t2 - t1) * 1000)

    return {
        "detections": rows,
        "image": {"width": img.width, "height": img.height},
        "annotated": base64.b64encode(buf.getvalue()).decode(),
        "timing_ms": {
            "decode": round((t1 - t0) * 1000),
            "infer": round((t2 - t1) * 1000),
            "measure": round((t3 - t2) * 1000),
            "total": round(total * 1000),
        },
    }
