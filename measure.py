"""Turning masks plus a LiDAR depth map into millimetres.

Three pixel spaces are in play and mixing them produces plausible wrong numbers
rather than errors:

    image   1920 x 1440   the JPEG; fx, fy, cx, cy are quoted for THIS
    model   1272 x 1272   what RF-DETR sees -- a plain stretch of image space
    depth    256 x 192    ARKit sceneDepth and confidenceMap

Two facts keep it simple. The model resize is a stretch, so normalised
coordinates pass through it unchanged. And ARKit's depth shares the camera's
field of view, so normalised coordinates map 1:1 onto the depth grid. Hence
everything here works in normalised coordinates, and intrinsics are rescaled
explicitly at the one place the depth grid is indexed.
"""

from __future__ import annotations

import numpy as np

# ARKit confidence levels; ARConfidenceLevel.high == 2
CONF_HIGH = 2

# ARKit LiDAR is roughly 1% of range. Only used for the error bar.
DEPTH_REL_NOISE = 0.01

# A mask boundary is good to about this many pixels.
EDGE_PX = 2.0


def depth_stats(mask: np.ndarray, depth_m: np.ndarray, conf: np.ndarray):
    """Median depth under a full-resolution mask, plus the valid fraction.

    Median rather than mean: a mask straddling an edge collects background
    pixels, and the mean is dragged toward them while the median is not.

    Sampling the MASK rather than the bounding box matters more than it sounds.
    A box around a diagonal weld seam is mostly not the seam, so its box-median
    is a mixture of the bead and whatever lies beside it.
    """
    dh, dw = depth_m.shape
    mh, mw = mask.shape

    ys, xs = np.nonzero(mask)
    if ys.size == 0:
        return None, 0.0

    # mask pixel -> depth pixel, in normalised coordinates
    dy = np.clip((ys.astype(np.float32) + 0.5) * dh / mh, 0, dh - 1).astype(np.int32)
    dx = np.clip((xs.astype(np.float32) + 0.5) * dw / mw, 0, dw - 1).astype(np.int32)

    z = depth_m[dy, dx]
    c = conf[dy, dx]
    good = (z > 0) & (c >= CONF_HIGH)
    if not good.any():
        return None, 0.0

    return float(np.median(z[good])), float(good.sum() / good.size)


def measure(mask: np.ndarray, xyxy, depth_m: np.ndarray, conf: np.ndarray,
            fx: float, image_w: int) -> dict:
    """Millimetre size of one detection.

    Lateral quantities, so depth contributes exactly one number: the distance z.

        mm_per_px = z / fx * 1000

    fx is quoted in IMAGE pixels, so the mask must be at image resolution for
    this to hold -- which it is, postprocess() upsamples it there.
    """
    z, fill = depth_stats(mask, depth_m, conf)
    out = {"distance_m": z, "depth_fill": round(fill, 3),
           "width_mm": None, "height_mm": None, "area_mm2": None,
           "mm_per_px": None, "uncertainty_mm": None}
    if z is None:
        return out

    mm_px = z / fx * 1000.0
    x0, y0, x1, y1 = (float(v) for v in xyxy)
    width_mm = (x1 - x0) * mm_px
    height_mm = (y1 - y0) * mm_px

    # Area from the mask is the part a box cannot give you.
    area_mm2 = float(mask.sum()) * mm_px * mm_px

    # Two independent contributions, combined in quadrature. Worth knowing which
    # dominates: at 0.3 m with fx ~1450, mm_per_px is ~0.21 mm, so the edge term
    # is ~0.42 mm while the scale term is 1% of the measurement. Edge wins for
    # anything under ~40 mm -- i.e. every defect. The limit is mask boundary
    # precision, not LiDAR accuracy.
    sigma_scale = max(width_mm, height_mm) * DEPTH_REL_NOISE
    sigma_edge = EDGE_PX * mm_px
    sigma = float(np.hypot(sigma_scale, sigma_edge))

    out.update(
        width_mm=round(width_mm, 2),
        height_mm=round(height_mm, 2),
        area_mm2=round(area_mm2, 2),
        mm_per_px=round(mm_px, 5),
        uncertainty_mm=round(sigma, 2),
    )
    return out


def decode_depth(raw: bytes, w: int, h: int) -> np.ndarray:
    """uint16 millimetres from the phone -> float32 metres. 0 stays 0 = no reading."""
    a = np.frombuffer(raw, dtype="<u2")
    if a.size != w * h:
        raise ValueError(f"depth is {a.size} samples, expected {w * h}")
    return a.reshape(h, w).astype(np.float32) / 1000.0


def decode_confidence(raw: bytes | None, w: int, h: int) -> np.ndarray:
    """Missing confidence is treated as all-high, matching the phone's fallback."""
    if not raw:
        return np.full((h, w), CONF_HIGH, np.uint8)
    a = np.frombuffer(raw, dtype=np.uint8)
    if a.size != w * h:
        raise ValueError(f"confidence is {a.size} samples, expected {w * h}")
    return a.reshape(h, w)
