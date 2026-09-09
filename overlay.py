"""Drawing the result, server-side.

The phone gets a finished JPEG rather than polygons. That costs ~400 kB down and
removes every normalised-to-screen coordinate calculation from the client --
which is where the mask flip, the stride bug and the aspect questions all came
from when inference ran on-device. The phone shows a picture and a list.

Colours match train/overlay.py so a phone screenshot and a desktop prediction of
the same weld read the same.
"""

from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw

COLORS = {
    "crack": (231, 76, 60),
    "discontinuity": (230, 126, 34),
    "overlap": (155, 89, 182),
    "porosity": (230, 126, 34),
    "spatter": (26, 188, 156),
    "undercut": (241, 196, 15),
    "weld_seam": (46, 204, 113),
    "workpiece": (255, 255, 0),
}
DEFAULT = (200, 200, 200)

# Large regions get a light wash so the defects on top stay legible.
STRUCTURAL = {"workpiece", "weld_seam"}
FILL = 0.35
STRUCTURAL_FILL = 0.15


def draw(img: Image.Image, rows: list[dict], masks) -> Image.Image:
    """rows carry label / confidence / bbox / width_mm; masks are full-res bool."""
    base = np.asarray(img.convert("RGB"), np.float32)

    # structural first so defect masks land on top of them
    order = sorted(range(len(rows)), key=lambda i: rows[i]["label"] not in STRUCTURAL)

    if masks is not None:
        for i in order:
            label = rows[i]["label"]
            colour = np.array(COLORS.get(label, DEFAULT), np.float32)
            a = STRUCTURAL_FILL if label in STRUCTURAL else FILL
            m = masks[i]
            base[m] = base[m] * (1 - a) + colour * a

    out = Image.fromarray(base.astype(np.uint8))
    pen = ImageDraw.Draw(out)
    scale = max(out.width / 1600, 1.0)

    for i in order:
        r = rows[i]
        label = r["label"]
        colour = COLORS.get(label, DEFAULT)
        structural = label in STRUCTURAL
        x0, y0, x1, y1 = r["bbox_px"]
        pen.rectangle([x0, y0, x1, y1], outline=colour,
                      width=int((1 if structural else 2) * scale))
        if structural:
            continue                    # a caption on a full-frame box just covers the weld

        text = f"{label} {r['confidence']:.2f}"
        if r.get("width_mm") is not None:
            text += f"  {r['width_mm']:.1f}x{r['height_mm']:.1f}mm"
        pad = int(3 * scale)
        th = int(12 * scale)
        tw = int(len(text) * 6.2 * scale)
        ty = max(y0 - th - pad, 0)
        pen.rectangle([x0, ty, x0 + tw + 2 * pad, ty + th + pad], fill=colour)
        pen.text((x0 + pad, ty + pad // 2), text, fill=(255, 255, 255))

    return out
