"""Train yolo11s-seg on dataset-combined (102 images, 8 classes).

imgsz is 1280 for a measured reason. At the native 3072 px the 5th-percentile
shortest side is 11 px for spatter and 16 px for porosity. Resized to 640 those
become 2.3 px and 3.4 px, below anything YOLO can represent; at 1280 they are
4.6 px and 6.8 px and the larger defects land at 13-15 px.

Augmentation runs hot because 78 training images is still very few, and a weld
has no canonical orientation, so full rotation and both flips are valid.

    python train.py                       # 200 epochs at 1280
    python train.py --imgsz 1536          # more detail, more memory
    python train.py --model yolo11m-seg.pt
"""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
DATA = REPO / "dataset-combined" / "data.yaml"
RUNS = HERE / "runs"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(REPO / "test" / "yolo11s-seg.pt"))
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--epochs", type=int, default=200)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--device", default="0")
    ap.add_argument("--name", default="yolo11s_seg_1280")
    args = ap.parse_args()

    if not DATA.exists():
        raise SystemExit(f"{DATA} not found -- run build_combined.py first")

    model = YOLO(args.model)
    model.train(
        data=str(DATA),
        imgsz=args.imgsz,
        epochs=args.epochs,
        batch=args.batch,
        device=args.device,
        workers=4,
        seed=0,
        patience=50,          # val is 24 images, so per-class AP still bounces

        project=str(RUNS),
        name=args.name,
        exist_ok=True,
        plots=True,

        # --- augmentation ---
        degrees=180.0,        # a weld has no up
        fliplr=0.5,
        flipud=0.5,
        scale=0.5,
        translate=0.15,
        shear=5.0,
        hsv_h=0.015,
        hsv_s=0.6,
        hsv_v=0.4,
        mosaic=1.0,
        close_mosaic=20,      # last 20 epochs on clean images
        erasing=0.0,          # would delete whole small defects
    )

    metrics = model.val(data=str(DATA), imgsz=args.imgsz, device=args.device, plots=True)

    print("\n=== per-class mask AP50 (read these, not the mean) ===")
    for i, c in enumerate(metrics.seg.ap_class_index):
        print(f"  {model.names[int(c)]:<16} {metrics.seg.ap50[i]:.4f}")
    print(f"\n  mask mAP50    {metrics.seg.map50:.4f}")
    print(f"  mask mAP50-95 {metrics.seg.map:.4f}")
    print(f"  box  mAP50    {metrics.box.map50:.4f}")
    print(f"\nweights -> {RUNS / args.name / 'weights' / 'best.pt'}")


if __name__ == "__main__":
    main()
