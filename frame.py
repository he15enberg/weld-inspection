"""Rotate and square-crop a capture before the model sees it.

The model was trained on 102 photographs that were all 3072x3072 -- square, and
all with the part lying ACROSS the frame. The phone sends 1920x1440, and ARKit
hands over `frame.capturedImage` in the sensor's own orientation with nothing
correcting it, so the part arrives standing on end. Both of those are
geometries the model has never seen, and measured on the stored captures they
cost most of the detector:

    as-is                   weld_seam found in 3 of 9 frames
    turned 270 (clockwise)  weld_seam found in 9 of 9, workpiece 0.85 -> 0.94

`preprocess()` stretches whatever it is handed to a square 1272, so a 4:3 frame
also arrives squeezed 25% in x. Cropping to square removes that and, because it
discards bench rather than weld, raises how much of the frame the part fills.

Both operations are applied to the colour frame AND to the depth and confidence
maps, so the three stay in step. That matters more than it sounds: `measure.py`
works in normalised coordinates on the premise that colour and depth share one
field of view, and a crop applied to only one of them silently breaks it --
producing wrong millimetres rather than an error.

Intrinsics: cropping does not change fx or fy at all, and `measure.py` never
reads cx/cy. A quarter turn swaps fx and fy, which `main.py` does. On this
hardware they are equal to the last decimal place anyway (measured across every
stored capture: fx == fy == 1408.579..., square pixels), so the swap is a
no-op -- but it is done properly rather than relied upon.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

# Any multiple of 15 works for a 1920x1440 frame over a 256x192 depth grid; see
# `snap()` for why, and for what happens when the geometry is not that.
DEFAULT_CROP = 1380


def snap(image_w: int, image_h: int, depth_w: int, depth_h: int,
         want: int) -> int:
    """The largest square crop <= `want` whose edges land on WHOLE depth pixels.

    The depth grid is an exact 7.5x reduction of the colour frame today, so a
    crop of 1392 would start at x = 24, and 24 / 7.5 = 3.2 -- there is no depth
    pixel 3.2. Rounding it slides depth against colour by up to half a depth
    pixel, which is nearly 4 colour pixels, and every millimetre afterwards is
    quietly a little wrong.

    1380 divides cleanly: 1380 / 7.5 = 184, and the centring offsets 30 / 7.5 = 4
    and 270 / 7.5 = 36. Rather than hardcode that, search down from `want` for
    the first size where the crop size and both offsets are exact. 12 pixels of
    give costs nothing -- preprocess() restretches to 1272 regardless, so the
    crop SIZE was never the point; the crop itself is.

    Returns 0 when nothing fits, which the caller treats as "do not crop"
    rather than cropping wrongly.
    """
    sx = image_w / depth_w
    sy = image_h / depth_h
    if abs(sx - sy) > 1e-6:            # colour and depth disagree on aspect
        return 0

    limit = min(want, image_w, image_h)
    for side in range(limit, 0, -1):
        ox, oy = (image_w - side) / 2, (image_h - side) / 2
        if ox != int(ox) or oy != int(oy):
            continue                   # crop would start on a half colour pixel
        if all(abs(v / sx - round(v / sx)) < 1e-9 for v in (side, ox, oy)):
            return side
    return 0


def _rot_k(degrees: int) -> int:
    """Quarter turns anticlockwise, matching PIL's rotate() convention."""
    return int(degrees // 90) % 4


def unmap_box(box, k: int, src_w: int, src_h: int) -> list[int]:
    """A box in ROTATED coordinates, expressed back in SOURCE coordinates.

    The model is fed a turned frame, so every box it returns is in turned
    coordinates. The phone still holds the untouched capture, so anything it
    has to line up against those boxes needs them the other way round.

    Corners are mapped and re-bounded rather than the box being transformed
    directly, because a quarter turn exchanges the axes and "x0 < x1" stops
    holding halfway through.

    Boxes here are half-open, [x0, x1) -- so the corners are taken at x1 - 1
    and the 1 is added back afterwards. Mapping x1 directly is off by one, and
    one DEPTH pixel of error is seven and a half colour pixels, which is the
    exact misalignment this whole transform exists to avoid.
    """
    k %= 4
    x0, y0, x1, y1 = box
    xi, yi = x1 - 1, y1 - 1               # inclusive far corner
    pts = [(x0, y0), (xi, y0), (x0, yi), (xi, yi)]
    out = []
    for x, y in pts:
        if k == 0:
            out.append((x, y))
        elif k == 1:                      # source -> 90 CCW was x'=y, y'=W-1-x
            out.append((src_w - 1 - y, x))
        elif k == 2:
            out.append((src_w - 1 - x, src_h - 1 - y))
        else:                             # k == 3: x'=H-1-y, y'=x
            out.append((y, src_h - 1 - x))
    xs = [p[0] for p in out]
    ys = [p[1] for p in out]
    # +1 turns the inclusive far corner back into a half-open bound
    return [int(min(xs)), int(min(ys)), int(max(xs)) + 1, int(max(ys)) + 1]


def unrotate_image(img: Image.Image, info: dict) -> Image.Image:
    """Turn a processed image back to the orientation the capture arrived in.

    The model wants the frame turned; a person wants to see what they were
    pointing at. Analysis runs in model space and only the pictures handed back
    are turned round, so the two never have to be reconciled twice.
    """
    k = _rot_k(info.get("rotate", 0))
    return img if not k else img.rotate(-90 * k, expand=True)


def unrotate_mask(mask: np.ndarray, info: dict) -> np.ndarray:
    """Same, for a boolean mask."""
    k = _rot_k(info.get("rotate", 0))
    return mask if not k else np.ascontiguousarray(np.rot90(mask, -k))


def prepare(img: Image.Image, depth: np.ndarray, conf: np.ndarray,
            rotate: int = 0, crop: int = 0) -> tuple:
    """(img, depth, conf, info) with the same turn and crop applied to all three.

    `rotate` is degrees anticlockwise and is rounded to a quarter turn -- 270 is
    a quarter turn CLOCKWISE, which is the one this hardware needs. `crop` is
    the requested square side in colour pixels; 0 disables it. The returned
    `info` records what was actually done, which goes into the response and into
    the stored record so a capture can never be mistaken for an untransformed
    one.
    """
    info = {"rotate": 0, "crop": 0, "source": [img.width, img.height],
            "depth_source": [depth.shape[1], depth.shape[0]], "swap_fxfy": False}

    k = _rot_k(rotate)
    if k:
        img = img.rotate(90 * k, expand=True)
        # np.rot90 turns anticlockwise too, so one k drives all three
        depth = np.ascontiguousarray(np.rot90(depth, k))
        conf = np.ascontiguousarray(np.rot90(conf, k))
        info["rotate"] = 90 * k
        info["swap_fxfy"] = k % 2 == 1

    if crop:
        side = snap(img.width, img.height, depth.shape[1], depth.shape[0], crop)
        if side:
            ox, oy = (img.width - side) // 2, (img.height - side) // 2
            scale = img.width / depth.shape[1]
            dside = round(side / scale)
            dox, doy = round(ox / scale), round(oy / scale)

            img = img.crop((ox, oy, ox + side, oy + side))
            depth = depth[doy:doy + dside, dox:dox + dside]
            conf = conf[doy:doy + dside, dox:dox + dside]
            info["crop"] = side
            info["crop_box"] = [ox, oy, ox + side, oy + side]
            info["depth_crop_box"] = [dox, doy, dox + dside, doy + dside]
            # The same two rectangles in the coordinates of the frame the phone
            # actually holds. The app crops its own JPEG and depth map with
            # these, which is what puts its point cloud in the same space as the
            # masks coming back -- without it the mask is indexed against a grid
            # of a different size and the workpiece view silently empties.
            info["crop_box_source"] = unmap_box(
                info["crop_box"], k, *info["source"])
            info["depth_crop_box_source"] = unmap_box(
                info["depth_crop_box"], k, *info["depth_source"])
            if side != crop:
                # said out loud: the caller asked for one size and got another
                info["crop_requested"] = crop
        else:
            info["crop_skipped"] = (
                f"no square <= {crop} lands on whole depth pixels for "
                f"{img.width}x{img.height} over "
                f"{depth.shape[1]}x{depth.shape[0]}")

    info["output"] = [img.width, img.height]
    info["depth_output"] = [depth.shape[1], depth.shape[0]]
    return img, depth, conf, info
