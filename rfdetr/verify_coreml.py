"""Parity gate: does the exported .mlpackage agree with PyTorch?

macOS ONLY (CoreML cannot execute elsewhere). Run this BEFORE writing or
trusting any Swift. A failure here is a model problem, and finding it after the
Swift is in play costs far more to diagnose.

Both the checkpoint and the .mlpackage default to this directory.

    python verify_coreml.py
    python verify_coreml.py --mlpackage other.mlpackage --ckpt other.pth

Three deliberate choices, each of which the obvious version gets wrong:

1. REAL IMAGES, NOT torch.randn. On random noise every query scores near zero,
   so the two models agree to 1e-6 and the test tells you nothing. Worse,
   rfdetr's own known-flaky parity case is specifically on real-image input --
   noise hides the exact failure this is meant to catch.

2. THE SAME PREPROCESSING BOTH SIDES, from reference_postprocess.py: stretch
   resize, bilinear, half-pixel centres, antialias OFF, ImageNet normalise.
   Feeding CoreML a differently-resized tensor measures the resize, not the
   export.

3. COMPARED AFTER POSTPROCESSING, not just on raw tensors. Raw logits can drift
   a little with no effect, or drift a little and move a detection across the
   threshold. Detections are what ships, so detections are what is compared --
   raw deltas are reported too, for diagnosis.

The model input is an MLMultiArray, not an image: rfdetr converts with no
ImageType, so there is no "image" key. The real input name is read from the
model spec.
"""

from __future__ import annotations

import argparse
import os
import platform
import sys
from pathlib import Path

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "-1")

import numpy as np
import torch
from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

from reference_postprocess import (  # noqa: E402
    postprocess,
    prepare_export,
    preprocess,
    raw_outputs,
)

DEFAULT_SOURCE = REPO / "welds" / "welds"


def bind(arrays: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    """Match outputs by rank and last dim, as Swift must: coremltools does not
    preserve the ONNX names."""
    r3 = [a for a in arrays if a.ndim == 3]
    boxes = next(a for a in r3 if a.shape[-1] == 4)
    logits = next(a for a in r3 if a.shape[-1] != 4)
    masks = next((a for a in arrays if a.ndim == 4), None)
    return boxes, logits, masks


def iou(a: np.ndarray, b: np.ndarray) -> float:
    u = np.logical_or(a, b).sum()
    return 1.0 if u == 0 else float(np.logical_and(a, b).sum() / u)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mlpackage", default=str(HERE / "weld_rfdetr.mlpackage"))
    ap.add_argument("--ckpt", default=str(HERE / "checkpoint_best_ema.pth"))
    ap.add_argument("--source", default=str(DEFAULT_SOURCE))
    ap.add_argument("-n", type=int, default=5)
    ap.add_argument("--conf", type=float, default=0.25)
    # Tolerances: a couple of pixels on a 3072 px frame is invisible; mask IoU
    # 0.98 allows a boundary pixel or two without allowing a different shape.
    ap.add_argument("--max-box-px", type=float, default=2.0)
    ap.add_argument("--min-mask-iou", type=float, default=0.98)
    args = ap.parse_args()

    if platform.system() != "Darwin":
        sys.exit("CoreML can only execute on macOS. Run this on the Mac.")
    for path, flag in ((args.mlpackage, "--mlpackage"), (args.ckpt, "--ckpt")):
        if not Path(path).exists():
            sys.exit(f"not found: {path}\n"
                     f"Both default to {HERE}; pass {flag} to point elsewhere.")

    import coremltools as ct

    ml = ct.models.MLModel(args.mlpackage)
    spec_in = list(ml.input_description)
    if not spec_in:
        sys.exit("model has no inputs?")
    input_name = spec_in[0]
    out_names = list(ml.output_description)
    print(f"mlpackage input '{input_name}'   outputs {out_names}")

    from rfdetr import RFDETR

    model = RFDETR.from_checkpoint(args.ckpt, trust_checkpoint=True)
    model.model.device = torch.device("cpu")
    model.model.model = model.model.model.to("cpu")
    res = getattr(model.model_config, "resolution", 1272)
    nc = getattr(model.model_config, "num_classes", None)
    inner, _ = prepare_export(model, res)
    print(f"{type(model).__name__}  res {res}  num_classes {nc}\n")

    images = sorted(
        p for p in Path(args.source).iterdir()
        if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )[: args.n]
    if not images:
        sys.exit(f"no images in {args.source}")

    failures = 0
    for p in images:
        img = Image.open(p)
        ow, oh = img.size
        tensor = preprocess(img, res)

        pt = raw_outputs(inner, tensor)
        cm_raw = ml.predict({input_name: tensor})
        cm = [np.asarray(cm_raw[k], dtype=np.float32) for k in out_names]

        pb, pl, pm = bind(pt)
        cb, cl, cmk = bind(cm)

        # raw deltas, for diagnosis when the detection comparison fails
        d_box = float(np.abs(pb - cb).max())
        d_log = float(np.abs(pl - cl).max())
        d_msk = float(np.abs(pm - cmk).max()) if pm is not None and cmk is not None else 0.0

        bg = None if pl.shape[-1] == nc else -1
        a = postprocess(pb[0], pl[0], None if pm is None else pm[0], ow, oh,
                        args.conf, background_class_id=bg)
        b = postprocess(cb[0], cl[0], None if cmk is None else cmk[0], ow, oh,
                        args.conf, background_class_id=bg)

        print(f"{p.name}   {ow}x{oh}")
        print(f"  raw max|d|  boxes {d_box:.2e}  logits {d_log:.2e}  masks {d_msk:.2e}")
        print(f"  detections  pytorch {len(a[1])}   coreml {len(b[1])}")

        if len(a[1]) != len(b[1]):
            print("  FAIL: detection counts differ — a score crossed the threshold\n")
            failures += 1
            continue
        if len(a[1]) == 0:
            print("  (no detections either side; try a lower --conf for a real test)\n")
            continue

        px = float(np.abs(a[0] - b[0]).max())
        cls_ok = bool((a[2] == b[2]).all())
        mi = 1.0
        if a[3] is not None and b[3] is not None:
            mi = min(iou(a[3][i], b[3][i]) for i in range(len(a[1])))

        ok = px <= args.max_box_px and cls_ok and mi >= args.min_mask_iou
        print(f"  box max|d| {px:.3f} px   classes {'match' if cls_ok else 'DIFFER'}"
              f"   min mask IoU {mi:.5f}   {'OK' if ok else 'FAIL'}\n")
        if not ok:
            failures += 1

    print("-" * 60)
    if failures:
        print(f"{failures}/{len(images)} images FAILED parity.")
        print("\nThe export is not faithful. Do NOT build Swift on top of it. Try, in order:")
        print("  1. confirm torch<2.12 (the coreml extra pins it for exactly this)")
        print("  2. re-run the export — this divergence is known to be intermittent")
        print("  3. if you exported float16, try float32 and compare")
        sys.exit(1)

    print(f"all {len(images)} images match PyTorch.")
    print("\nThe export is faithful. Safe to add to the Runner target and port to Swift.")


if __name__ == "__main__":
    main()
