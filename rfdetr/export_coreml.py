"""Export a trained RF-DETR Seg checkpoint to a CoreML .mlpackage.

macOS ONLY. coremltools cannot produce an .mlpackage on Windows or Linux.

Everything defaults to this directory: drop `checkpoint_best_ema.pth` next to
this script and the bundle is written beside it.

    pip install "rfdetr[coreml]"
    python export_coreml.py                        # fp32, 1272
    python export_coreml.py --precision float16    # smaller, ANE-oriented
    python export_coreml.py --ckpt other.pth

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

# RFDETRSegSmall asserts input divisibility by patch_size * num_windows = 12 * 2.
BLOCK = 24


def require_rfdetr():
    """Import RFDETR, or explain precisely what is wrong.

    rfdetr >= 1.10 requires Python 3.10+. On an older interpreter pip does not
    error -- it silently resolves to an ancient release that has no `RFDETR`
    class at all (only RFDETRBase / RFDETRLarge), and the failure surfaces as a
    bare ImportError with no hint about the interpreter. macOS ships Python 3.9
    as /usr/bin/python3, so a venv made with the system python lands exactly
    here.
    """
    if sys.version_info < (3, 10):
        v = ".".join(map(str, sys.version_info[:3]))
        sys.exit(
            f"Python {v} is too old -- rfdetr needs 3.10 or newer.\n"
            f"  interpreter: {sys.executable}\n\n"
            "macOS ships 3.9 as /usr/bin/python3, so a venv built from it lands\n"
            "exactly here. Rebuild with a newer one:\n"
            "  brew install python@3.12\n"
            "  rm -rf .venv && /opt/homebrew/bin/python3.12 -m venv .venv\n"
            "  source .venv/bin/activate && pip install 'rfdetr[coreml]'"
        )
    try:
        from rfdetr import RFDETR
    except ImportError as exc:
        try:
            import rfdetr
            have = getattr(rfdetr, "__version__", "unknown")
        except Exception:                                     # noqa: BLE001
            sys.exit(f"rfdetr is not installed: {exc}\n"
                     "  pip install 'rfdetr[coreml]'")
        sys.exit(
            f"rfdetr {have} is installed but has no RFDETR class "
            "(added in 1.7; these scripts target 1.10+).\n"
            f"  interpreter: {sys.executable}\n"
            "  pip install --upgrade 'rfdetr[coreml]'"
        )
    return RFDETR


def best_epoch(metrics: Path) -> tuple[int, float] | None:
    """Peak val/ema_segm_mAP_50 from a metrics.csv, for reporting. Optional.

    Reads the `epoch` column rather than the row index: metrics.csv writes TWO
    rows per epoch, so counting rows silently doubles every epoch number.
    """
    if not metrics.exists():
        return None
    rows = list(csv.DictReader(metrics.open(encoding="utf-8")))
    scored = [
        (int(r["epoch"]), float(r["val/ema_segm_mAP_50"]))
        for r in rows
        if r.get("val/ema_segm_mAP_50") not in (None, "", "nan")
    ]
    return max(scored, key=lambda x: x[1]) if scored else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=str(HERE / "checkpoint_best_ema.pth"))
    ap.add_argument("--out", default=str(HERE),
                    help="directory to write the .mlpackage into")
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

    ckpt = Path(args.ckpt)
    out = Path(args.out)
    if not ckpt.exists():
        sys.exit(f"checkpoint not found: {ckpt}\n"
                 f"Put checkpoint_best_ema.pth in {HERE}, or pass --ckpt.")
    out.mkdir(parents=True, exist_ok=True)

    # metrics.csv is only there if the whole run directory was copied across;
    # its absence is normal and costs nothing but this note.
    peak = best_epoch(ckpt.parent / "metrics.csv")
    if peak:
        print(f"run peak: val/ema_segm_mAP_50 {peak[1]:.4f} at epoch {peak[0]}")
        print("  (if the score decayed later in training, the LAST epoch is not\n"
              "   the best one -- make sure this checkpoint is the peak)")
    print(f"checkpoint  {ckpt}")
    print(f"resolution  {args.resolution}   precision {args.precision}\n")

    RFDETR = require_rfdetr()
    model = RFDETR.from_checkpoint(str(ckpt), trust_checkpoint=True)
    nc = getattr(model.model_config, "num_classes", "?")
    print(f"{type(model).__name__}, {nc} classes\n")

    # The checkpoint records the device it trained on -- 'cuda' here. export()
    # reads self.model.device and does `model.to(device)` (detr.py:1768), which
    # on a Mac raises "Torch not compiled with CUDA enabled". Pin the context to
    # CPU; CoreML conversion has to happen on CPU anyway.
    import torch

    model.model.device = torch.device("cpu")
    model.model.model = model.model.model.to("cpu")

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
    print("  python verify_coreml.py")
    print("  and only once that passes, add the bundle to the Runner TARGET in Xcode")


if __name__ == "__main__":
    main()
