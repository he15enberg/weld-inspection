"""Run the exported .mlpackage over a folder of images and save annotated results.

macOS ONLY. This is the app's inference path without the app: same preprocessing,
same postprocessing, same model file -- so if these pictures look right and the
phone does not, the fault is in the Swift, not the model.

    python predict_coreml.py --source ~/Desktop/welds        # -> outputs/
    python predict_coreml.py --source one.jpg --conf 0.4
    python predict_coreml.py --only porosity

To run the COMPILED model from inside the built app instead of the .mlpackage:

    find ~/Downloads/rfdetr_test/build -name "*.mlmodelc"
    python predict_coreml.py --mlmodelc <that path> --source ~/Desktop/welds

Same weights either way -- coremlc only repackages the graph -- so this only
tells you something new if you suspect the Xcode compile step itself.

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


def load_compiled(mlmodelc: Path, mlpackage: Path | None):
    """Load the .mlmodelc that is actually inside the built app.

    `CompiledMLModel` runs a compiled model but exposes no `get_spec()`, so the
    input name, output names and resolution have to come from somewhere else.
    Tried in order:

      1. `metadata.json` inside the .mlmodelc — present in most compiled models,
         but its schema is not a documented contract, so failures here are
         expected and non-fatal.
      2. The .mlpackage the bundle was compiled from, if it is around. Same
         graph, so the names match.

    If both miss, pass --input-name / --outputs / --res explicitly.
    """
    import coremltools as ct

    model = ct.models.CompiledMLModel(str(mlmodelc))
    inp = outs = res = None

    meta = mlmodelc / "metadata.json"
    if meta.exists():
        try:
            import json
            doc = json.loads(meta.read_text())
            doc = doc[0] if isinstance(doc, list) else doc
            ins = doc.get("inputSchema") or []
            outs = [o["name"] for o in (doc.get("outputSchema") or [])] or None
            if ins:
                inp = ins[0]["name"]
                shape = ins[0].get("shape")
                if isinstance(shape, str):
                    shape = [int(x) for x in shape.strip("[]").split(",")]
                if shape and len(shape) == 4:
                    res = int(shape[2])
        except Exception as exc:                              # noqa: BLE001
            print(f"  (metadata.json unreadable: {exc})")

    if (inp is None or outs is None or res is None) and mlpackage and mlpackage.exists():
        ref = ct.models.MLModel(str(mlpackage))
        inp = inp or list(ref.input_description)[0]
        outs = outs or list(ref.output_description)
        if res is None:
            shape = ref.get_spec().description.input[0].type.multiArrayType.shape
            res = int(shape[2])
        print(f"  (schema read from {mlpackage.name})")

    return model, inp, outs, res


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
    ap.add_argument("--mlmodelc",
                    help="run the COMPILED model from inside the built app "
                         "instead (find it with: find <app> -name '*.mlmodelc')")
    ap.add_argument("--source", required=True, help="image file or folder")
    ap.add_argument("--out", default=str(HERE / "outputs"))
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--size", type=int, default=1600, help="longest side of the output")
    ap.add_argument("--only", help="draw just this class")
    ap.add_argument("--classes", help="comma-separated override for the class list")
    ap.add_argument("--input-name", help="override, when the schema cannot be read")
    ap.add_argument("--outputs", help="comma-separated output names, same case")
    ap.add_argument("--res", type=int, help="model input side, same case")
    args = ap.parse_args()

    if platform.system() != "Darwin":
        sys.exit("CoreML can only execute on macOS. Run this on the Mac.")

    import coremltools as ct

    if args.mlmodelc:
        path = Path(args.mlmodelc)
        if not path.exists():
            sys.exit(f"not found: {path}")
        pkg = Path(args.mlpackage)
        ml, input_name, out_names, res = load_compiled(path, pkg if pkg.exists() else None)
        input_name = args.input_name or input_name
        out_names = args.outputs.split(",") if args.outputs else out_names
        res = args.res or res
        if not (input_name and out_names and res):
            sys.exit("could not determine the model schema; pass --input-name, "
                     "--outputs and --res (or keep the .mlpackage nearby)")
        print(f"model {path.name}  (compiled, from the app bundle)")
    else:
        if not Path(args.mlpackage).exists():
            sys.exit(f"not found: {args.mlpackage}   (pass --mlpackage)")
        ml = ct.models.MLModel(args.mlpackage)
        input_name = list(ml.input_description)[0]
        out_names = list(ml.output_description)
        res = int(ml.get_spec().description.input[0].type.multiArrayType.shape[2])
        print(f"model {Path(args.mlpackage).name}")

    print(f"  input '{input_name}' side {res}   outputs {out_names}")

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
