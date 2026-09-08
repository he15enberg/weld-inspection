"""Train RF-DETR Seg on dataset-combined, for a like-for-like comparison
against the YOLO run in ../yolo.

Two things this handles that are easy to get wrong:

1. **Format.** RF-DETR wants Roboflow-style COCO -- images sitting alongside
   `_annotations.coco.json` in `train/` and `valid/`. dataset-combined is YOLO
   layout, so this converts it. The conversion reads the YOLO polygons rather
   than the original exports, which guarantees both models train on byte
   identical labels.

2. **The identical split.** Train/val membership comes from the folders
   dataset-combined already has, so nothing is recomputed and the two models
   see exactly the same images.

Resolution is 1272, not 1280. RF-DETR needs it divisible by
patch_size * num_windows, and that product is variant specific -- the docs say
56, some variants assert 32, and RFDETRSegSmall actually wants 24 (patch 12 x
2 windows). Even Roboflow's own `resolution=640` example fails this model.
1272 = 24 x 53 is the closest valid value to the 1280 the object-size analysis
called for.

    python train.py --prepare-only    # build the COCO copy, no training
    python train.py
"""

from __future__ import annotations

import argparse
import collections
import json
import shutil
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SRC = REPO / "dataset-combined"
COCO = HERE / "dataset_coco"
RUNS = HERE / "runs"

SPLITS = {"train": "train", "val": "valid"}      # RF-DETR expects "valid"


def load_classes() -> list[str]:
    """Read the class list out of data.yaml so it can never drift from the
    dataset. Parsed by hand to avoid a pyyaml dependency in this venv."""
    names: dict[int, str] = {}
    in_names = False
    for line in (SRC / "data.yaml").read_text(encoding="utf-8").splitlines():
        if line.startswith("names:"):
            in_names = True
            continue
        if in_names:
            if not line.startswith((" ", "\t")):
                break
            idx, _, name = line.strip().partition(":")
            names[int(idx)] = name.strip()
    return [names[i] for i in sorted(names)]


def build_coco(classes: list[str]) -> None:
    cat_id = {c: i + 1 for i, c in enumerate(classes)}      # COCO ids are 1-based
    counts: collections.Counter = collections.Counter()

    for split, folder in SPLITS.items():
        out_dir = COCO / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        # clear files, not directories: on Windows a shell sitting in this
        # folder holds a handle and rmtree dies with WinError 32
        for old in out_dir.iterdir():
            if old.is_file():
                old.unlink()

        doc = {"images": [], "annotations": [],
               "categories": [{"id": cat_id[c], "name": c, "supercategory": "weld"}
                              for c in classes]}
        next_ann = 1

        for img_id, img_path in enumerate(sorted((SRC / "images" / split).iterdir()), 1):
            with Image.open(img_path) as im:
                w, h = im.size
            doc["images"].append({"id": img_id, "file_name": img_path.name,
                                  "width": w, "height": h})
            shutil.copy2(img_path, out_dir / img_path.name)

            label = SRC / "labels" / split / f"{img_path.stem}.txt"
            if not label.exists():
                continue
            for line in label.read_text().strip().splitlines():
                parts = line.split()
                if len(parts) < 7:
                    continue
                cls = classes[int(parts[0])]
                coords = [float(x) for x in parts[1:]]
                xs = [coords[i] * w for i in range(0, len(coords), 2)]
                ys = [coords[i] * h for i in range(1, len(coords), 2)]
                poly = [v for pair in zip(xs, ys) for v in pair]
                x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
                doc["annotations"].append({
                    "id": next_ann, "image_id": img_id,
                    "category_id": cat_id[cls],
                    "segmentation": [poly],
                    "bbox": [x0, y0, x1 - x0, y1 - y0],
                    "area": (x1 - x0) * (y1 - y0),
                    "iscrowd": 0,
                })
                next_ann += 1
                counts[(folder, cls)] += 1

        (out_dir / "_annotations.coco.json").write_text(json.dumps(doc), encoding="utf-8")
        print(f"{folder:<7} {len(doc['images']):>4} images, {len(doc['annotations']):>4} annotations")

    print(f"\n{'class':<15}{'train':>8}{'valid':>8}")
    print("-" * 31)
    for c in classes:
        print(f"{c:<15}{counts[('train', c)]:>8}{counts[('valid', c)]:>8}")


def train(args) -> None:
    from rfdetr import RFDETRSegSmall

    model = RFDETRSegSmall()
    model.train(
        dataset_dir=str(COCO),
        output_dir=str(RUNS / args.name),
        epochs=args.epochs,
        batch_size=args.batch,
        grad_accum_steps=args.grad_accum,
        lr=args.lr,
        resolution=args.resolution,
        early_stopping=True,
        early_stopping_patience=40,
    )
    print(f"\ncheckpoints -> {RUNS / args.name}")
    print("note: checkpoint_best_ema.pth is chosen on a blended detection+segmentation\n"
          "      score, which is not always the best segmentation epoch -- check\n"
          "      metrics.csv column val/ema_segm_mAP_50 before picking a checkpoint.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--prepare-only", action="store_true")
    ap.add_argument("--epochs", type=int, default=200)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--grad-accum", type=int, default=4)     # effective batch 8
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--resolution", type=int, default=1272)
    ap.add_argument("--name", default="rfdetr_seg_small_1272")
    a = ap.parse_args()

    if not SRC.exists():
        raise SystemExit(f"{SRC} not found -- run build_combined.py first")
    # RFDETRSegSmall: patch_size 12 * num_windows 2 = 24
    if a.resolution % 24:
        raise SystemExit(f"resolution {a.resolution} must be divisible by 24 "
                         f"(try 1272 or 1296)")

    classes = load_classes()
    print(f"{len(classes)} classes: {classes}\n")
    build_coco(classes)
    print(f"\ndataset -> {COCO}")
    if a.prepare_only:
        raise SystemExit(0)
    train(a)
