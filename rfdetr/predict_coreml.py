"""Run the exported .mlpackage over a folder of images and save annotated results.

macOS ONLY. This is the app's inference path without the app: same preprocessing,
same postprocessing, same model file -- so if these pictures look right and the
phone does not, the fault is in the Swift, not the model.

    python predict_coreml.py --source ~/Desktop/welds        # -> outputs/
    python predict_coreml.py --source one.jpg --conf 0.4
    python predict_coreml.py --only porosity

Needs `reference_postprocess.py` beside it (it supplies preprocess/postprocess).
Draws with PIL rather than OpenCV so there is nothing extra to install.

A note on resolution: masks are decoded straight to the OUTPUT size rather than
to the source and then shrunk. Decoding 100 masks at 3072x3072 would be ~2 GB of
booleans for a picture that gets scaled to 1600 px anyway.
"""

from __future__ import annotations

import argparse
import collections
import platform
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from reference_postprocess import postprocess, preprocess  # noqa: E402

# RGB, matching train/overlay.py (which stores the same colours as BGR for cv2)
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
DEFAULT_COLOR = (200, 200, 200)

STRUCTURAL = {"workpiece", "weld_seam"}
FILL_ALPHA = 0.35
STRUCTURAL_ALPHA = 0.15

# Keyed on head width. Both are the order training derives: annotated COCO
# categories, filtered, sorted, enumerated from 0.
KNOWN_CLASSES = {
    7: ["crack", "overlap", "porosity", "spatter", "undercut",
        "weld_seam", "workpiece"],                          # data-40
    8: ["crack", "discontinuity", "overlap", "porosity", "spatter",
        "undercut", "weld_seam", "workpiece"],              # dataset-combined
}


def bind(arrays):
    """Match outputs by rank and last dim, as the Swift must: coremltools does
    not preserve the ONNX output names."""
    r3 = [a for a in arrays if a.ndim == 3]
    boxes = next(a for a in r3 if a.shape[-1] == 4)
    logits = next(a for a in r3 if a.shape[-1] != 4)
    masks = next((a for a in arrays if a.ndim == 4), None)
    return boxes, logits, masks


def draw(img: Image.Image, dets, labels, only=None) -> Image.Image:
    """Masks composited under boxes and captions, matching the app's layering."""
    base = np.asarray(img.convert("RGB"), dtype=np.float32)
    xyxy, scores, cls, masks = dets

    order = sorted(range(len(scores)),
                   key=lambda i: labels[cls[i]] not in STRUCTURAL)

    if masks is not None:
        for i in order:
            label = labels[cls[i]]
            if only and label != only:
                continue
            alpha = STRUCTURAL_ALPHA if label in STRUCTURAL else FILL_ALPHA
            m = masks[i]
            colour = np.array(COLORS.get(label, DEFAULT_COLOR), np.float32)
            base[m] = base[m] * (1 - alpha) + colour * alpha

    out = Image.fromarray(base.astype(np.uint8))
    d = ImageDraw.Draw(out)

    for i in order:
        label = labels[cls[i]]
        if only and label != only:
            continue
        colour = COLORS.get(label, DEFAULT_COLOR)
        structural = label in STRUCTURAL
        x0, y0, x1, y1 = xyxy[i]
        d.rectangle([x0, y0, x1, y1], outline=colour, width=1 if structural else 2)

        if structural:
            continue                       # captions on full-frame boxes just clutter
        text = f"{label} {scores[i]:.2f}"
        tx, ty = float(x0), max(float(y0) - 12, 0.0)
        d.rectangle([tx, ty, tx + 7 * len(text), ty + 12], fill=colour)
        d.text((tx + 2, ty + 1), text, fill=(255, 255, 255))

    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mlpackage", default=str(HERE / "weld_rfdetr.mlpackage"))
    ap.add_argument("--source", required=True, help="image file or folder")
    ap.add_argument("--out", default=str(HERE / "outputs"))
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--size", type=int, default=1600, help="longest side of the output")
    ap.add_argument("--only", help="draw just this class")
    ap.add_argument("--classes", help="comma-separated override for the class list")
    args = ap.parse_args()

    if platform.system() != "Darwin":
        sys.exit("CoreML can only execute on macOS. Run this on the Mac.")
    if not Path(args.mlpackage).exists():
        sys.exit(f"not found: {args.mlpackage}   (pass --mlpackage)")

    import coremltools as ct

    ml = ct.models.MLModel(args.mlpackage)
    input_name = list(ml.input_description)[0]
    out_names = list(ml.output_description)

    spec = ml.get_spec()
    shape = [int(d) for d in spec.description.input[0].type.multiArrayType.shape]
    res = shape[2]
    print(f"model {Path(args.mlpackage).name}")
    print(f"  input '{input_name}' {shape}   outputs {out_names}")

    src = Path(args.source)
    images = ([src] if src.is_file()
              else sorted(p for p in src.iterdir()
                          if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}))
    if not images:
        sys.exit(f"no images in {src}")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    labels: list[str] | None = args.classes.split(",") if args.classes else None
    totals: collections.Counter = collections.Counter()

    print(f"  {len(images)} images   conf {args.conf}   res {res}\n")

    for p in images:
        img = Image.open(p)
        ow, oh = img.size

        raw = ml.predict({input_name: preprocess(img, res)})
        arrays = [np.asarray(raw[k], dtype=np.float32) for k in out_names]
        b, l, m = bind(arrays)

        if labels is None:
            width = l.shape[-1]
            # A head one wider than the class list carries a background slot,
            # which sits in the LAST column for these checkpoints.
            labels = KNOWN_CLASSES.get(width) or KNOWN_CLASSES.get(width - 1)
            if labels is None:
                sys.exit(f"logits width {width} matches no known class list; "
                         f"pass --classes")
            print(f"  {len(labels)} classes: {labels}\n")
        bg = None if l.shape[-1] == len(labels) else -1

        # Decode straight to the output size -- see the module docstring.
        scale = min(args.size / max(ow, oh), 1.0)
        dw, dh = max(int(ow * scale), 1), max(int(oh * scale), 1)

        dets = postprocess(b[0], l[0], None if m is None else m[0],
                           dw, dh, args.conf, background_class_id=bg)

        cls = dets[2]
        tally = collections.Counter(
            labels[c] for c in cls
            if not args.only or labels[c] == args.only
        )
        totals.update(tally)

        canvas = img.convert("RGB").resize((dw, dh), Image.LANCZOS)
        draw(canvas, dets, labels, args.only).save(
            out_dir / f"{p.stem}.jpg", quality=92)

        summary = ", ".join(f"{c} x{n}" for c, n in tally.most_common())
        print(f"  {p.name[:34]:<36} {summary or 'nothing detected'}")

    print(f"\n{'class':<16}{'detections':>12}")
    print("-" * 28)
    for c, n in totals.most_common():
        print(f"  {c:<14}{n:>12}")
    print("-" * 28)
    print(f"  {'TOTAL':<14}{sum(totals.values()):>12}")
    print(f"\nannotated -> {out_dir}")


if __name__ == "__main__":
    main()
