"""Run the trained model over a folder of images and save annotated results.

Drawing matches data-40/overlay_labels.py so predictions and ground-truth
overlays can be compared side by side without re-reading a legend: same colours,
same convention that workpiece and weld_seam get a light fill while defects get
a strong one.

    python predict.py                                  # welds/welds at conf 0.25
    python predict.py --source path/to/imgs --conf 0.4
    python predict.py --only porosity
"""

from __future__ import annotations

import argparse
import collections
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WEIGHTS = HERE / "runs" / "yolo11s_seg_1280" / "weights" / "best.pt"

# BGR, matching data-40/overlay_labels.py
COLORS = {
    "crack": (60, 76, 231),
    "discontinuity": (34, 126, 230),
    "overlap": (182, 89, 155),
    "porosity": (34, 126, 230),
    "spatter": (156, 188, 26),
    "undercut": (15, 196, 241),
    "weld_seam": (113, 204, 46),
    "workpiece": (0, 255, 255),
}
DEFAULT_COLOR = (200, 200, 200)

# large regions get a light fill so the defects on top stay legible
STRUCTURAL = {"workpiece", "weld_seam"}
FILL_ALPHA = 0.35
STRUCTURAL_ALPHA = 0.15
FONT = cv2.FONT_HERSHEY_SIMPLEX


def color_for(label: str):
    return COLORS.get(label, DEFAULT_COLOR)


def draw(img, dets):
    out = img.copy()

    for label, poly, _ in dets:
        if label not in STRUCTURAL:
            continue
        layer = out.copy()
        cv2.fillPoly(layer, [poly], color_for(label))
        cv2.addWeighted(layer, STRUCTURAL_ALPHA, out, 1 - STRUCTURAL_ALPHA, 0, out)
        cv2.polylines(out, [poly], True, color_for(label), 4, cv2.LINE_AA)

    fill = None
    for label, poly, _ in dets:
        if label in STRUCTURAL:
            continue
        if fill is None:
            fill = out.copy()
        cv2.fillPoly(fill, [poly], color_for(label))
        cv2.polylines(out, [poly], True, color_for(label), 3, cv2.LINE_AA)
    if fill is not None:
        cv2.addWeighted(fill, FILL_ALPHA, out, 1 - FILL_ALPHA, 0, out)

    for label, poly, conf in dets:
        if label in STRUCTURAL:
            continue
        x, y = poly[:, 0].min(), poly[:, 1].min()
        scale = max(out.shape[1] / 1600, 0.5)
        text = f"{label} {conf:.2f}"
        (tw, th), _ = cv2.getTextSize(text, FONT, 0.5 * scale, 1)
        top = max(int(y) - th - 8, 0)
        cv2.rectangle(out, (int(x), top), (int(x) + tw + 8, top + th + 8),
                      color_for(label), -1)
        cv2.putText(out, text, (int(x) + 4, top + th + 2), FONT,
                    0.5 * scale, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def banner(img, text):
    h = max(int(img.shape[0] * 0.045), 28)
    bar = np.full((h, img.shape[1], 3), 20, np.uint8)
    scale = h / 46
    cv2.putText(bar, text, (12, int(h * 0.7)), FONT, 0.8 * scale,
                (255, 255, 255), max(int(2 * scale), 1), cv2.LINE_AA)
    return np.vstack([bar, img])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=str(WEIGHTS))
    ap.add_argument("--source", default=str(REPO / "welds" / "welds"))
    ap.add_argument("--out", default=str(HERE / "runs" / "predictions"))
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--size", type=int, default=1600, help="longest side of the output")
    ap.add_argument("--only", help="draw just this class")
    ap.add_argument("--device", default="0")
    args = ap.parse_args()

    src = Path(args.source)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    model = YOLO(args.weights)
    images = sorted(p for p in src.iterdir()
                    if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"})
    if not images:
        raise SystemExit(f"no images in {src}")
    print(f"{len(images)} images  |  conf {args.conf}  |  imgsz {args.imgsz}\n")

    totals = collections.Counter()
    empty = []

    for p in images:
        img = cv2.imread(str(p))
        if img is None:
            print(f"  ! unreadable: {p.name}")
            continue

        r = model.predict(img, imgsz=args.imgsz, conf=args.conf,
                          device=args.device, retina_masks=True, verbose=False)[0]

        dets = []
        if r.masks is not None:
            for poly, cls, conf in zip(r.masks.xy,
                                       r.boxes.cls.cpu().numpy(),
                                       r.boxes.conf.cpu().numpy()):
                label = model.names[int(cls)]
                if args.only and label != args.only:
                    continue
                if poly is None or len(poly) < 3:
                    continue
                dets.append((label, poly.astype(np.int32), float(conf)))

        tally = collections.Counter(d[0] for d in dets)
        totals.update(tally)
        if not dets:
            empty.append(p.name)

        drawn = draw(img, dets)
        h, w = drawn.shape[:2]
        if args.size and max(h, w) > args.size:
            s = args.size / max(h, w)
            drawn = cv2.resize(drawn, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)

        summary = ", ".join(f"{c} x{n}" for c, n in tally.most_common()) or "nothing detected"
        drawn = banner(drawn, f"{p.name}  |  {summary}")
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
