"""Run a trained RF-DETR Seg checkpoint over a folder of images.

Mirrors ../yolo/predict.py and shares its drawing code, so the two models'
outputs can be compared frame by frame.

Two RF-DETR specifics this handles:

1. **Class names are not in the checkpoint.** `class_names` comes back None, so
   the id -> name mapping is rebuilt the way training built it: the annotated
   categories, filtered and sorted, enumerated from 0. That derivation is done
   here from the run's own COCO annotations rather than hardcoded, because the
   two datasets disagree -- dataset-combined inserts `discontinuity` at index 1
   and shifts every class after it. Whatever list is resolved is checked against
   the checkpoint's head width, so a mismatch fails loudly instead of silently
   mislabelling everything.

2. **RGB, not BGR.** predict() wants RGB; cv2 gives BGR. Getting this wrong
   costs accuracy silently rather than erroring.

Needs the RF-DETR venv:

    D:\\hackathon\\.venv-rfdetr\\Scripts\\python.exe train\\rfdetr\\predict.py
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))          # train/overlay.py
import overlay                                 # noqa: E402

REPO = HERE.parents[1]
CKPT = HERE / "runs" / "rfdetr_seg_small_1272" / "checkpoint_best_ema.pth"

COCO_DIR = HERE / "dataset_coco"

# Fallbacks, used only when the COCO annotations are not on disk. Both are the
# order training derives: annotated categories, filtered, sorted, from 0.
KNOWN_CLASSES = {
    7: ["crack", "overlap", "porosity", "spatter", "undercut",
        "weld_seam", "workpiece"],                      # data-40
    8: ["crack", "discontinuity", "overlap", "porosity", "spatter",
        "undercut", "weld_seam", "workpiece"],          # dataset-combined
}


def resolve_classes(num_classes: int) -> tuple[list[str], str]:
    """The label space the checkpoint was trained in.

    Preferred source is the run's own `_annotations.coco.json`, read through
    rfdetr's own `filter_parent_categories` -- the same function the dataset
    loader used to build cat2label, so the order cannot drift from training.
    Falls back to KNOWN_CLASSES keyed on the head width.
    """
    ann = COCO_DIR / "train" / "_annotations.coco.json"
    if ann.exists():
        try:
            from rfdetr.datasets.coco import (annotated_category_ids,
                                              filter_parent_categories)
            data = json.loads(ann.read_text(encoding="utf-8"))
            kept = filter_parent_categories(data["categories"],
                                            annotated_category_ids(data))
            names = [c["name"] for c in kept]
            if len(names) == num_classes:
                return names, f"derived from {ann.parent.name}/_annotations.coco.json"
        except Exception as exc:                       # noqa: BLE001
            print(f"  (could not read {ann}: {exc})")

    if num_classes in KNOWN_CLASSES:
        return KNOWN_CLASSES[num_classes], f"built-in list for a {num_classes}-class head"

    raise SystemExit(
        f"checkpoint head has {num_classes} classes and no matching label space "
        f"was found. Either run train.py --prepare-only to regenerate "
        f"{COCO_DIR}, or add the list to KNOWN_CLASSES."
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=str(CKPT))
    ap.add_argument("--source", default=str(REPO / "welds" / "welds"))
    ap.add_argument("--out", default=str(HERE / "runs" / "predictions"))
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--res", type=int, default=0, help="0 = the model's own resolution")
    ap.add_argument("--size", type=int, default=1600, help="longest side of the output")
    ap.add_argument("--only", help="draw just this class")
    args = ap.parse_args()

    from rfdetr import RFDETR

    model = RFDETR.from_checkpoint(args.ckpt, trust_checkpoint=True)
    cfg = model.model_config
    nc = int(getattr(cfg, "num_classes", 0))
    classes, source = resolve_classes(nc)
    res = args.res or getattr(cfg, "resolution", 1272)
    shape = (res, res)

    src, out_dir = Path(args.source), Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    images = sorted(p for p in src.iterdir()
                    if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"})
    if not images:
        raise SystemExit(f"no images in {src}")

    print(f"{type(model).__name__}  |  {len(images)} images  |  conf {args.conf}"
          f"  |  res {res}")
    print(f"{nc} classes ({source}):\n  {classes}\n")

    totals: collections.Counter = collections.Counter()
    empty: list[str] = []

    for p in images:
        bgr = cv2.imread(str(p))
        if bgr is None:
            print(f"  ! unreadable: {p.name}")
            continue

        det = model.predict(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB),
                            threshold=args.conf, shape=shape,
                            include_source_image=False)

        dets = []
        masks = getattr(det, "mask", None)
        for i in range(len(det)):
            label = classes[int(det.class_id[i])]
            if args.only and label != args.only:
                continue
            conf = float(det.confidence[i])
            if masks is not None:
                m = masks[i]
                if m.shape[:2] != bgr.shape[:2]:      # decoded at model res
                    m = cv2.resize(m.astype(np.uint8), (bgr.shape[1], bgr.shape[0]),
                                   interpolation=cv2.INTER_NEAREST)
                polys = overlay.mask_to_polys(m)
            else:                                      # box-only fallback
                x0, y0, x1, y1 = det.xyxy[i].astype(np.int32)
                polys = [np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], np.int32)]
            for poly in polys:
                dets.append((label, poly, conf))

        # count instances, not contours: one mask can break into several pieces
        tally = collections.Counter()
        for i in range(len(det)):
            label = classes[int(det.class_id[i])]
            if not args.only or label == args.only:
                tally[label] += 1
        totals.update(tally)
        if not tally:
            empty.append(p.name)

        summary = ", ".join(f"{c} x{n}" for c, n in tally.most_common()) or "nothing detected"
        drawn = overlay.banner(overlay.fit(overlay.draw(bgr, dets), args.size),
                               f"{p.name}  |  {summary}")
        cv2.imwrite(str(out_dir / f"{p.stem}.jpg"), drawn, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f"  {p.name[:34]:<36} {summary}")

    print(f"\n{'class':<16}{'detections':>12}")
    print("-" * 28)
    for c, n in totals.most_common():
        print(f"  {c:<14}{n:>12}")
    print("-" * 28)
    print(f"  {'TOTAL':<14}{sum(totals.values()):>12}")
    if empty:
        print(f"\nnothing detected in {len(empty)}: {empty}")
    print(f"\nannotated -> {out_dir}")


if __name__ == "__main__":
    main()
