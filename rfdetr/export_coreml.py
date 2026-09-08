"""Export a trained RF-DETR Seg checkpoint to a CoreML .mlpackage.

macOS ONLY. coremltools cannot produce an .mlpackage on Windows or Linux.

    pip install "rfdetr[coreml]"
    python export_coreml.py                        # best epoch, fp32, 1272
    python export_coreml.py --precision float16    # smaller, ANE-oriented
    python export_coreml.py --ckpt path/to/other.pth

Then run verify_coreml.py before writing or trusting any Swift.

Two things worth knowing before you start:

* The `coreml` extra pins **torch<2.12** deliberately. Above that, rfdetr's own
  test suite records the CoreML/eager parity divergence rate on real images
  jumping from about 1-in-6 runs to 6-in-7. Do not force a newer torch.

* fp32 is the default because it holds tight parity with eager PyTorch. fp16
  halves the bundle and suits the ANE better, but drifts more -- so export fp32
  first, get verify_coreml.py passing, and only then try fp16 and re-verify.
"""

from __future__ import annotations

import argparse
import csv
import platform
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNS = HERE / "runs"
DEFAULT_RUN = RUNS / "rfdetr_seg_small_1272"

# RFDETRSegSmall asserts input divisibility by patch_size * num_windows = 12 * 2.
BLOCK = 24


def best_epoch(run_dir: Path) -> tuple[int, float] | None:
    """Peak val/ema_segm_mAP_50 from metrics.csv, for reporting.

    Reads the `epoch` column rather than the row index: metrics.csv writes TWO
    rows per epoch, so counting rows silently doubles every epoch number.
    """
    path = run_dir / "metrics.csv"
    if not path.exists():
        return None
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    scored = [
        (int(r["epoch"]), float(r["val/ema_segm_mAP_50"]))
        for r in rows
        if r.get("val/ema_segm_mAP_50") not in (None, "", "nan")
    ]
    return max(scored, key=lambda x: x[1]) if scored else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default=str(DEFAULT_RUN),
                    help="training run directory holding the checkpoints")
    ap.add_argument("--ckpt", default=None,
                    help="checkpoint file; defaults to <run>/checkpoint_best_ema.pth")
    ap.add_argument("--out", default=None,
                    help="output directory; defaults to <run>/coreml")
    ap.add_argument("--name", default="weld_rfdetr",
                    help="bundle name; must match RFDetrRunner's modelName in Swift")
    ap.add_argument("--resolution", type=int, default=1272,
                    help="must match the trained resolution and be divisible by 24")
    ap.add_argument("--precision", choices=["float32", "float16"], default="float32")
    args = ap.parse_args()

    if platform.system() != "Darwin":
        sys.exit("CoreML export requires macOS. Run this on the Mac.")
    if args.resolution % BLOCK:
        sys.exit(f"resolution {args.resolution} is not divisible by {BLOCK} "
                 f"(patch 12 x 2 windows); try 1272 or 1296")

    run = Path(args.run)
    ckpt = Path(args.ckpt) if args.ckpt else run / "checkpoint_best_ema.pth"
    out = Path(args.out) if args.out else run / "coreml"
    if not ckpt.exists():
        sys.exit(f"checkpoint not found: {ckpt}")
    out.mkdir(parents=True, exist_ok=True)

    peak = best_epoch(run)
    if peak:
        print(f"run peak: val/ema_segm_mAP_50 {peak[1]:.4f} at epoch {peak[0]}")
        print("  (checkpoint_best_ema.pth should correspond to this epoch; if the\n"
              "   score decayed later in training, the LAST epoch is not the best one)")
    print(f"checkpoint  {ckpt}")
    print(f"resolution  {args.resolution}   precision {args.precision}\n")

    from rfdetr import RFDETR

    model = RFDETR.from_checkpoint(str(ckpt), trust_checkpoint=True)
    nc = getattr(model.model_config, "num_classes", "?")
    print(f"{type(model).__name__}, {nc} classes\n")

    # `export`, not `export_coreml`: format is a parameter, and it takes a
    # (height, width) `shape` and an `output_dir` -- there is no img_size or
    # output_path argument. export_coreml() is the internal converter and
    # expects an already-prepared module.
    path = model.export(
        output_dir=str(out),
        format="coreml",
        shape=(args.resolution, args.resolution),
        coreml_precision=args.precision,
        output_name=args.name,
    )

    print(f"\nexported -> {path}")
    print("\nnext:")
    print(f"  python verify_coreml.py --mlpackage {path} --ckpt {ckpt}")
    print("  and only once that passes, add the bundle to the Runner TARGET in Xcode")


if __name__ == "__main__":
    main()
