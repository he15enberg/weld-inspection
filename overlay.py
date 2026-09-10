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

# ---------------------------------------------------------------------------
# The class palette. THIS IS THE CANONICAL COPY -- mirrored in
# weldz-mobile/lib/theme.dart, weldz-dashboard/charts.js (light steps),
# inf-test/common.py and train/overlay.py (BGR). Change all five together.
#
# Eight hues drawn on one photograph is an all-pairs problem, and no eight-hue
# set clears the colour-blind gates all-pairs -- that was measured, not assumed
# (worst dark pair here is weld_seam/overlap at delta-E 1.9 protan). So the
# palette is built to a weaker but honest rule instead:
#
#     every pair that IS confusable leads to the SAME decision.
#
#   crack / discontinuity   both REJECT -- mistaking one for the other changes
#                           nothing, and they are the two rarest classes
#   porosity / spatter      both ACCEPTABLE -- likewise
#   overlap / weld_seam     overlap is the rarest defect (30 instances in the
#                           training set) and weld_seam is structural, drawn as
#                           a thin 0.15-alpha wash with no caption at all
#   spatter / workpiece     workpiece is the same kind of wash
#
# The four classes that actually co-occur on every frame -- porosity (472
# instances), spatter (148), workpiece (102), weld_seam (101) -- were validated
# as a set and PASS every gate all-pairs in both light and dark.
#
# Every defect box also carries a text label, which is the secondary encoding
# the 6-8 delta-E band requires. The label is authoritative; the colour is a
# hint.
#
# workpiece is pink and weld_seam blue by request.
# ---------------------------------------------------------------------------
COLORS = {
    "crack": (230, 103, 103),          # red      -- reject
    "discontinuity": (217, 89, 38),    # orange   -- reject
    "undercut": (201, 133, 0),         # amber    -- rework
    "porosity": (0, 131, 0),           # green    -- acceptable
    "spatter": (25, 158, 112),         # aqua     -- acceptable
    "overlap": (144, 133, 233),        # violet   -- acceptable
    "weld_seam": (57, 135, 229),       # blue     -- structure
    "workpiece": (224, 71, 158),       # pink     -- structure
}
DEFAULT = (200, 200, 200)

# Large regions get a light wash so the defects on top stay legible.
STRUCTURAL = {"workpiece", "weld_seam"}
FILL = 0.35
# 0.10, not 0.15: pink is a good deal more saturated than the yellow this
# used to be, and at 0.15 it tints the whole part purple instead of just
# marking it. The outline carries the identity; the wash only groups.
STRUCTURAL_FILL = 0.10


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
