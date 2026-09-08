"""Shared prediction drawing, so YOLO and RF-DETR outputs are directly comparable.

Colours and the fill convention come from data-40/overlay_labels.py: workpiece
and weld_seam are large regions and get a light fill, defects get a strong one,
so a defect sitting inside the seam stays readable.

Detections are passed as a list of (label, polygon Nx2 int32, confidence).
"""

from __future__ import annotations

import cv2
import numpy as np

# BGR, matching data-40/overlay_labels.py
COLORS = {
    "crack": (60, 76, 231),
    "discontinuity": (34, 126, 230),
    "overlap": (182, 89, 155),
    "porosity": (34, 126, 230),
    "spatter": (156, 188, 26),
    "undercut": (15, 196, 241),
    "weld_seam": (113, 204, 46),
    "workpiece": (0, 255, 255),
}
DEFAULT_COLOR = (200, 200, 200)

STRUCTURAL = {"workpiece", "weld_seam"}
FILL_ALPHA = 0.35
STRUCTURAL_ALPHA = 0.15
FONT = cv2.FONT_HERSHEY_SIMPLEX


def color_for(label: str):
    return COLORS.get(label, DEFAULT_COLOR)


def mask_to_polys(mask: np.ndarray, min_area: int = 12) -> list[np.ndarray]:
    """Boolean mask -> contour polygons, so mask models and polygon models share
    one drawing path. Tiny specks are dropped; they are decode noise, not defects."""
    m = (mask.astype(np.uint8) if mask.dtype != np.uint8 else mask)
    contours, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return [c.reshape(-1, 2).astype(np.int32) for c in contours
            if len(c) >= 3 and cv2.contourArea(c) >= min_area]


def draw(img, dets):
    out = img.copy()

    for label, poly, _ in dets:
        if label not in STRUCTURAL:
            continue
        layer = out.copy()
        cv2.fillPoly(layer, [poly], color_for(label))
        cv2.addWeighted(layer, STRUCTURAL_ALPHA, out, 1 - STRUCTURAL_ALPHA, 0, out)
        cv2.polylines(out, [poly], True, color_for(label), 4, cv2.LINE_AA)

    fill = None
    for label, poly, _ in dets:
        if label in STRUCTURAL:
            continue
        if fill is None:
            fill = out.copy()
        cv2.fillPoly(fill, [poly], color_for(label))
        cv2.polylines(out, [poly], True, color_for(label), 3, cv2.LINE_AA)
    if fill is not None:
        cv2.addWeighted(fill, FILL_ALPHA, out, 1 - FILL_ALPHA, 0, out)

    for label, poly, conf in dets:
        if label in STRUCTURAL:
            continue
        x, y = poly[:, 0].min(), poly[:, 1].min()
        scale = max(out.shape[1] / 1600, 0.5)
        text = f"{label} {conf:.2f}"
        (tw, th), _ = cv2.getTextSize(text, FONT, 0.5 * scale, 1)
        top = max(int(y) - th - 8, 0)
        cv2.rectangle(out, (int(x), top), (int(x) + tw + 8, top + th + 8),
                      color_for(label), -1)
        cv2.putText(out, text, (int(x) + 4, top + th + 2), FONT,
                    0.5 * scale, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def banner(img, text):
    h = max(int(img.shape[0] * 0.045), 28)
    bar = np.full((h, img.shape[1], 3), 20, np.uint8)
    scale = h / 46
    cv2.putText(bar, text, (12, int(h * 0.7)), FONT, 0.8 * scale,
                (255, 255, 255), max(int(2 * scale), 1), cv2.LINE_AA)
    return np.vstack([bar, img])


def fit(img, longest: int):
    h, w = img.shape[:2]
    if not longest or max(h, w) <= longest:
        return img
    s = longest / max(h, w)
    return cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
