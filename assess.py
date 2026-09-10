"""Calling the VLM service, and never letting it cost us the capture.

The VLM lives in its own process (WSL, port 8001) so a 4B model that OOMs or
wedges cannot take the inference server with it. That isolation is only worth
anything if the failure path here is genuinely soft -- so every error becomes a
status string the app can render, and nothing raises.

Qwen3-VL-4B in bf16 answers in about 2-3 s, which is why this is called inline
rather than as a background job with a polling endpoint. If a bigger model goes
back in, that decision has to be revisited.
"""

from __future__ import annotations

import base64
import logging
import os

import httpx
import numpy as np

log = logging.getLogger("weldz.assess")

URL = os.environ.get("WELDZ_VLM_URL", "").strip()

# Generous relative to the ~3 s expected, tight enough that a wedged service
# does not hold a capture open for a minute.
TIMEOUT = float(os.environ.get("WELDZ_VLM_TIMEOUT", "25"))

STRUCTURAL = ("workpiece", "weld_seam")


def enabled() -> bool:
    return bool(URL)


def coverage(rows: list[dict], masks, image_area: int) -> float | None:
    """Fraction of the frame the workpiece covers.

    Framing is the strongest lever on result quality -- a part filling 12% of
    the frame is why a result looks poor -- and it is free to compute here. The
    VLM is far more useful told the number than left to judge it by eye.
    """
    if masks is None or not rows or image_area <= 0:
        return None
    for want in STRUCTURAL:
        for i, row in enumerate(rows):
            if row.get("label") == want and i < len(masks):
                return round(float(np.count_nonzero(masks[i])) / image_area, 4)
    return None


def request(jpeg: bytes, verdict: dict, rows: list[dict],
            cover: float | None, depth_fill: float | None,
            seam: dict | None = None) -> dict:
    """Ask for an assessment. Returns a dict with `status` -- always.

    The rule results go across with the image. That is the difference between
    asking a model to guess at quality and asking it to explain an arithmetic
    result it can see the working for -- it is handed each rule's measured
    value, its limit and how close the two are, and asked to say WHERE on the
    weld the tightest one is. That is a question a vision model is good at.
    """
    if not enabled():
        return {"status": "disabled"}

    payload = {
        "image": base64.b64encode(jpeg).decode(),
        "verdict": verdict["verdict"],
        "headline": verdict["headline"],
        "score": verdict.get("score"),
        "bands": verdict.get("bands"),
        # Only the fields the prompt uses. Sending masks or bboxes would bloat
        # the request for text the model is told not to reason about.
        "detections": [
            {k: r.get(k) for k in
             ("label", "confidence", "width_mm", "height_mm", "distance_m",
              "on_seam")}
            for r in rows
        ],
        # measured vs limit vs utilisation, per rule -- the thing to narrate
        "rules": [
            {k: u.get(k) for k in
             ("name", "status", "value", "limit", "limit_max", "comparator",
              "utilisation", "detail")}
            for u in (verdict.get("utilisations") or [])
        ],
        "binding": verdict.get("binding"),
        "seam": {k: (seam or {}).get(k) for k in
                 ("status", "length_mm", "width_mm", "continuity",
                  "defects_on_seam", "defects_off_seam")},
        "coverage": cover,
        "depth_fill": depth_fill,
    }

    try:
        res = httpx.post(f"{URL.rstrip('/')}/assess", json=payload, timeout=TIMEOUT)
        res.raise_for_status()
        return {"status": "ready", **res.json()}
    except httpx.TimeoutException:
        log.warning("VLM timed out after %.0f s", TIMEOUT)
        return {"status": "failed", "error": "the assessment timed out"}
    except httpx.HTTPStatusError as exc:
        log.warning("VLM said %s", exc.response.status_code)
        return {"status": "failed",
                "error": f"assessment service returned {exc.response.status_code}"}
    except Exception as exc:                                       # noqa: BLE001
        log.warning("VLM unreachable: %s", exc)
        return {"status": "failed", "error": "assessment service unreachable"}
