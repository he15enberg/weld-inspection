"""Seam geometry, and whether a defect is actually on the weld.

Everything here is LATERAL -- lengths and widths in the image plane, converted
with the `mm_per_px` that measure.py already derived per detection. Nothing
reads the depth profile: bead crown height would need a plane fit against a
184x184 depth grid, and a 0.3 mm crown sits under that noise floor. Width,
length and area survive; height does not.

Two things come out of this module, and both are things the pipeline currently
throws away:

  * the seam's own dimensions -- length along the joint, width across it, and
    how much of the joint it actually covers. "The weld stops 30% short" is a
    real finding that no detection list can express.
  * whether each defect lies ON that seam. A pore detected on a bench cable is
    not a weld defect, and until now it counted as one.

Detections are ANNOTATED, never dropped. An excluded detection you cannot see
is indistinguishable from one that was never found, and the exclusion has to
survive a re-score under different rules.
"""

from __future__ import annotations

import numpy as np

SEAM = "weld_seam"
PART = "workpiece"
STRUCTURAL = (PART, SEAM)

# How far off the seam a defect may sit and still count as a weld defect.
# Undercut lives at the toe, just outside the bead, so a margin of zero would
# discard exactly the class that most needs measuring.
TOE_MARGIN_MM = 4.0

# A bead is long and thin. Below this length/width ratio the mask is not a
# bead, whatever it is labelled -- and its width is not a bead width.
#
# This is not theoretical. Replayed over the stored captures, eleven seams
# measured 94-99 mm long and 6.5-10.8 mm wide, and one came back 124 mm long
# by 112 mm wide: a blob covering most of the part. Without this gate that
# capture hands a 112 mm "bead width" to a rule with a 12 mm limit and fails
# the part for a reason that does not exist. The training set puts a real
# seam's bbox aspect at a median of 12.7, so 3.0 is a floor, not a target.
MIN_ELONGATION = 3.0


def _dilate(mask: np.ndarray, radius_px: int) -> np.ndarray:
    """Grow a boolean mask by `radius_px`, via max-pool.

    torch is already a hard dependency of the server and max_pool2d over a
    square window IS binary dilation, so this avoids pulling in scipy for one
    morphology call. A shift-and-or loop would be ~40 passes at this radius.
    """
    if radius_px <= 0:
        return mask
    import torch
    import torch.nn.functional as F

    k = int(radius_px) * 2 + 1
    t = torch.from_numpy(mask.astype(np.float32))[None, None]
    out = F.max_pool2d(t, kernel_size=k, stride=1, padding=k // 2)
    return out[0, 0].numpy() > 0.5


def _axes(mask: np.ndarray):
    """Principal axes of a mask: (centre, major unit vector, minor unit vector).

    PCA rather than the bounding box, because a seam running diagonally has a
    bbox far wider than the bead -- the box would report the diagonal, not the
    weld. Returns None for an empty mask.
    """
    ys, xs = np.nonzero(mask)
    if xs.size < 2:
        return None
    pts = np.stack([xs, ys], 1).astype(np.float64)
    centre = pts.mean(0)
    centred = pts - centre
    # eigenvectors of the 2x2 covariance, largest first
    cov = np.cov(centred, rowvar=False)
    vals, vecs = np.linalg.eigh(cov)
    order = np.argsort(vals)[::-1]
    return centre, vecs[:, order[0]], vecs[:, order[1]]


def _extent(mask: np.ndarray, centre, axis) -> float:
    """Span of a mask along one axis, in pixels, from the 1st to 99th
    percentile of the projection.

    Percentiles, not min/max: one stray pixel from a ragged mask edge would
    otherwise stretch the measurement, and this number goes straight into a
    pass/fail limit.
    """
    ys, xs = np.nonzero(mask)
    pts = np.stack([xs, ys], 1).astype(np.float64) - centre
    proj = pts @ axis
    return float(np.percentile(proj, 99) - np.percentile(proj, 1))


def analyse(rows: list[dict], masks) -> dict:
    """Seam metrics, plus `on_seam` / `seam_overlap` written onto every row.

    Returns a dict that is always shaped the same. When the seam is missing or
    unmeasurable the fields come back None and `status` says why -- the callers
    then treat the seam-derived rules as INDETERMINATE rather than passing
    them, which mirrors how the existing evaluator handles an unmeasurable
    defect. A missing seam must never look like a clean weld.
    """
    out = {"status": "ok", "length_mm": None, "width_mm": None,
           "area_mm2": None, "continuity": None, "mm_per_px": None,
           "defects_on_seam": 0, "defects_off_seam": 0}

    if masks is None or not rows:
        out["status"] = "no masks"
        return out

    seam_i = next((i for i, r in enumerate(rows)
                   if r.get("label") == SEAM and i < len(masks)), None)
    if seam_i is None:
        out["status"] = "no weld_seam detected"
        # Without a seam there is nothing to be on or off, so every defect is
        # left unmarked rather than being called off-seam and quietly dropped.
        for r in rows:
            if r.get("label") not in STRUCTURAL:
                r["on_seam"] = None
                r["seam_overlap"] = None
        return out

    seam = masks[seam_i]
    scale = rows[seam_i].get("mm_per_px")
    axes = _axes(seam)
    if axes is None:
        out["status"] = "weld_seam mask is empty"
        return out

    centre, major, minor = axes
    length_px = _extent(seam, centre, major)
    area_px = float(np.count_nonzero(seam))
    # Mean width, not the minor-axis extent: area over length is stable against
    # a bead that widens at one end, where the extent reports only the widest
    # point and calls the whole seam that.
    width_px = area_px / length_px if length_px > 0 else 0.0

    elongation = length_px / width_px if width_px > 0 else 0.0
    out["elongation"] = round(elongation, 2)

    if isinstance(scale, (int, float)) and scale > 0:
        out.update({
            "length_mm": round(length_px * scale, 2),
            "width_mm": round(width_px * scale, 2),
            "width_max_mm": round(_extent(seam, centre, minor) * scale, 2),
            "area_mm2": round(area_px * scale * scale, 1),
            "mm_per_px": scale,
        })
    else:
        out["status"] = "no depth under the seam, so it cannot be sized"

    # Numbers are kept even when this trips -- they are the evidence that it
    # tripped -- but `status` is no longer "ok", and scoring reads status, so
    # every seam-derived rule goes indeterminate rather than acting on them.
    if elongation and elongation < MIN_ELONGATION and out["status"] == "ok":
        out["status"] = (f"weld_seam mask is not bead-shaped "
                         f"(length/width {elongation:.1f}, expected >= "
                         f"{MIN_ELONGATION:.0f})")

    # Continuity: the joint length measured ALONG THE SEAM's own axis, not the
    # workpiece's. A part photographed at an angle has its own principal axis
    # pointing somewhere else, and the ratio would be meaningless.
    part_i = next((i for i, r in enumerate(rows)
                   if r.get("label") == PART and i < len(masks)), None)
    if part_i is not None:
        joint_px = _extent(masks[part_i], centre, major)
        if joint_px > 0:
            out["continuity"] = round(min(length_px / joint_px, 1.0), 3)

    # Spatial gate. The margin is in mm where a scale exists, so the band is a
    # physical distance rather than a number of pixels that means something
    # different at every working distance.
    margin_px = int(round(TOE_MARGIN_MM / scale)) if (
        isinstance(scale, (int, float)) and scale > 0) else int(
        round(0.02 * max(seam.shape)))
    band = _dilate(seam, margin_px)

    for i, r in enumerate(rows):
        if r.get("label") in STRUCTURAL or i >= len(masks):
            continue
        m = masks[i]
        total = float(np.count_nonzero(m))
        share = float(np.count_nonzero(m & band)) / total if total else 0.0
        r["seam_overlap"] = round(share, 3)
        # Any real contact counts. A pore straddling the toe is still a pore;
        # the threshold is only here to reject a mask that clips the band by a
        # pixel or two of ragged edge.
        r["on_seam"] = share >= 0.10
        if r["on_seam"]:
            out["defects_on_seam"] += 1
        else:
            out["defects_off_seam"] += 1

    return out
