"""Fill the store with plausible captures, so the dashboard has something to show.

    python seed_demo.py                    # 14 days into WELDZ_CAPTURES
    python seed_demo.py --days 30 --wipe
    python seed_demo.py --root ./demo_captures

Everything written here is synthetic and is labelled as such: each record gets
`"demo": true`, and the dashboard shows a banner while any demo capture is
present. That matters more than it sounds -- an inspection archive that mixes
invented rows with real ones without saying so is worse than an empty one.

The shapes are deliberately not uniform:

  * a weekday rhythm, with almost nothing at weekends
  * a reject rate that drifts down over the fortnight, so the trend line has
    something to show rather than being flat noise
  * framing correlated with verdict, because that is the real relationship --
    a part small in frame produces a worse result, and the framing chart
    should reproduce that rather than hide it
  * porosity sizes on a long tail, so p50 and p95 differ
"""

from __future__ import annotations

import argparse
import io
import math
import os
import random
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

DW, DH = 256, 192
IMG_W, IMG_H = 1920, 1440

SUMMARY = {
    "reject": [
        "A dark line runs along the toe of the bead; the surface is otherwise even.",
        "There is a clear break in the bead about a third of the way along.",
        "The bead stops short and restarts, leaving a visible gap.",
    ],
    "rework": [
        "The bead edge is cut back on the left over roughly a third of its length.",
        "The toe is undercut along one side; the rest of the bead looks sound.",
        "Undercut is visible where the bead meets the vertical plate.",
    ],
    "approve": [
        "The bead is even and the surface is clean apart from light spatter.",
        "Ripples are regular and the toes are well wetted on both sides.",
        "A few small pores near the start, otherwise a tidy bead.",
    ],
}
CONCERNS = ["light spatter", "slight arc strike", "discolouration near the toe",
            "bead width varies", "start of the run is uneven"]


def photo(rng: random.Random, verdict: str) -> bytes:
    """A small synthetic 'weld' image, so thumbnails are not broken rectangles."""
    w, h = 320, 240
    img = Image.new("RGB", (w, h), (58, 60, 64))
    pen = ImageDraw.Draw(img)

    # plate, then a bead across it
    pen.rectangle([26, 78, w - 26, h - 62], fill=(96, 92, 86))
    for x in range(30, w - 30, 6):
        y = 138 + int(3 * math.sin(x / 9.0))
        pen.ellipse([x - 5, y - 8, x + 7, y + 8],
                    fill=(188 + rng.randint(-18, 18),) * 3)

    if verdict == "reject":
        pen.line([(90, 141), (215, 145)], fill=(24, 22, 24), width=3)
    elif verdict == "rework":
        pen.line([(60, 152), (150, 154)], fill=(52, 48, 46), width=4)

    px = np.asarray(img).astype(np.int16)
    px += np.asarray(rng.choices(range(-13, 14), k=px.size)).reshape(px.shape)
    out = io.BytesIO()
    Image.fromarray(np.clip(px, 0, 255).astype("uint8")).save(
        out, "JPEG", quality=82)
    return out.getvalue()


def depth(rng: random.Random, coverage: float) -> bytes:
    """A tilted plane at roughly arm's length, with realistic dropouts.

    Zero means no reading, exactly as ARKit produces -- so the stored buffer
    exercises the same paths a real capture does.
    """
    y, x = np.mgrid[0:DH, 0:DW]
    base = 300 + (1 - coverage) * 420          # small in frame == further away
    mm = base + (x - DW / 2) * 0.14 + (y - DH / 2) * 0.09
    mm = mm.astype(np.int32)

    holes = np.random.default_rng(rng.randrange(1 << 30)).random((DH, DW))
    mm[holes < 0.10 + (1 - coverage) * 0.18] = 0      # shiny steel drops out
    return np.clip(mm, 0, 65535).astype("<u2").tobytes()


def detections(rng: random.Random, verdict: str, coverage: float) -> list[dict]:
    """Structure always, then whatever defect drove the verdict."""
    scale = 0.55 + coverage
    rows = [
        {"label": "workpiece", "confidence": round(rng.uniform(0.78, 0.95), 2),
         "width_mm": round(186 * scale, 1), "height_mm": round(118 * scale, 1),
         "area_mm2": round(20800 * scale, 1),
         "distance_m": round(0.30 + (1 - coverage) * 0.42, 3),
         "depth_fill": round(rng.uniform(0.72, 0.94), 2), "uncertainty_mm": 0.61},
        {"label": "weld_seam", "confidence": round(rng.uniform(0.55, 0.86), 2),
         "width_mm": round(126 * scale, 1), "height_mm": round(rng.uniform(7.4, 10.6), 1),
         "area_mm2": round(1080 * scale, 1),
         "distance_m": round(0.30 + (1 - coverage) * 0.42, 3),
         "depth_fill": round(rng.uniform(0.58, 0.90), 2), "uncertainty_mm": 0.52},
    ]

    def defect(label: str, size: float, fill=None):
        rows.append({
            "label": label,
            "confidence": round(rng.uniform(0.27, 0.66), 2),
            "width_mm": round(size, 1), "height_mm": round(size * rng.uniform(0.6, 1.0), 1),
            "area_mm2": round(size * size * 0.68, 1),
            "distance_m": round(0.30 + (1 - coverage) * 0.42, 3),
            "depth_fill": round(fill if fill is not None else rng.uniform(0.2, 0.9), 2),
            "uncertainty_mm": round(rng.uniform(0.32, 0.58), 2),
        })

    if verdict == "reject":
        if rng.random() < 0.45:
            defect("crack", rng.uniform(1.4, 4.2))
        else:
            defect("discontinuity", rng.uniform(4.0, 11.0))
    elif verdict == "rework":
        defect("undercut", rng.uniform(0.4, 1.6))

    # porosity on a long tail, so p50 and p95 are genuinely different
    for _ in range(rng.choices([0, 1, 2, 3, 6], weights=[34, 26, 18, 14, 8])[0]):
        defect("porosity", min(rng.gauss(3.1, 1.5) + rng.expovariate(0.45), 14.0))
    for _ in range(rng.choices([0, 1, 2], weights=[52, 32, 16])[0]):
        defect("spatter", rng.uniform(0.5, 2.4))
    if rng.random() < 0.08:
        defect("overlap", rng.uniform(1.5, 5.0))

    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--root", default=os.environ.get("WELDZ_CAPTURES", "captures"))
    ap.add_argument("--wipe", action="store_true",
                    help="delete the store first (demo AND real captures)")
    ap.add_argument("--seed", type=int, default=20260910)
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    if args.wipe and root.exists():
        shutil.rmtree(root, ignore_errors=True)
    os.environ["WELDZ_CAPTURES"] = str(root)

    import rules
    import store
    store.ROOT = root
    store.init()

    rng = random.Random(args.seed)
    now = datetime.now(timezone.utc)
    made = 0

    for back in range(args.days - 1, -1, -1):
        when_day = now - timedelta(days=back)
        weekend = when_day.weekday() >= 5
        count = rng.randint(0, 2) if weekend else rng.randint(4, 11)

        # improving over the fortnight, so the trend line is a trend
        progress = 1 - (back / max(args.days - 1, 1))
        p_reject = 0.34 - 0.20 * progress
        p_rework = 0.26 - 0.08 * progress

        for _ in range(count):
            roll = rng.random()
            verdict = ("reject" if roll < p_reject
                       else "rework" if roll < p_reject + p_rework else "approve")

            # framing tracks verdict, because that is the real relationship
            coverage = round(min(max({
                "reject": rng.gauss(0.19, 0.07),
                "rework": rng.gauss(0.44, 0.12),
                "approve": rng.gauss(0.63, 0.11),
            }[verdict], 0.05), 0.92), 4)

            rows = detections(rng, verdict, coverage)
            judged = rules.evaluate(rows)

            quality = ("poor" if coverage < 0.22
                       else "fair" if coverage < 0.40 else "good")
            frame_fill = round(min(max(rng.gauss(0.86, 0.07), 0.35), 0.99), 4)
            infer_ms = rng.randint(760, 1080)
            assess_ms = rng.randint(2100, 3400)

            result = {
                "detections": rows,
                "image": {"width": IMG_W, "height": IMG_H},
                "annotated": "",                 # dropped by save() anyway
                "judgement": judged,
                "assessment": {
                    "status": "ready",
                    "summary": rng.choice(SUMMARY[judged["verdict"]]),
                    "concerns": rng.sample(CONCERNS, rng.choices(
                        [0, 1, 2], weights=[50, 34, 16])[0]),
                    "image_quality": quality,
                    # the carve-out fires rarely, as it should
                    "missed_rejectable": ["crack"] if rng.random() < 0.04 else [],
                    "ms": assess_ms,
                },
                "timing_ms": {"decode": rng.randint(30, 55), "infer": infer_ms,
                              "measure": rng.randint(18, 34), "assess": assess_ms,
                              "total": infer_ms + assess_ms + rng.randint(70, 130)},
                "demo": True,
            }

            cid = store.save(
                result=result,
                color=photo(rng, judged["verdict"]),
                overlay=photo(rng, judged["verdict"]),
                depth=depth(rng, coverage),
                confidence=bytes([2]) * (DW * DH),
                meta={"fx": 1450.0, "fy": 1450.0, "cx": 960.0, "cy": 720.0,
                      "conf": 0.25, "device": rng.choice(
                          ["iPhone15,3", "iPhone16,2"]),
                      "depth_width": DW, "depth_height": DH,
                      "image_width": IMG_W, "image_height": IMG_H},
                stamp={"checkpoint": "checkpoint_best_ema.pth",
                       "checkpoint_mtime": 1757000000,
                       "checkpoint_bytes": 150994944,
                       "resolution": 1272, "n_classes": 8},
                coverage=coverage,
                depth_fill=frame_fill,
            )
            if not cid:
                continue

            # Backdate the row AND move the folder. store._file() resolves paths
            # from the row's `day`, so moving one without the other orphans the
            # files and the detail view comes back empty.
            when = when_day.replace(
                hour=rng.choice([7, 8, 9, 10, 11, 13, 14, 15, 16, 17]),
                minute=rng.randrange(60), second=rng.randrange(60))
            new_day = f"{when:%Y-%m-%d}"
            src = root / f"{now:%Y-%m-%d}" / cid
            dst = root / new_day / cid
            if src != dst and src.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(dst))
            with store._connect() as conn:
                conn.execute("UPDATE captures SET ts = ?, day = ? WHERE id = ?",
                             (when.isoformat(timespec="seconds"), new_day, cid))
            made += 1

    stats = store.stats(days=args.days + 1)
    print(f"seeded {made} demo captures into {root}")
    print(f"  verdicts     {stats['verdicts']}")
    print(f"  reject rate  {stats['reject_rate']:.1%}")
    print(f"  days         {len(stats['per_day'])}")
    print(f"  classes      "
          + ", ".join(f"{c['label']} {c['n']}" for c in stats["by_class"]))
    print(f"  framing      "
          + ", ".join(f"{f['verdict']} {f['avg_coverage']:.0%}"
                      for f in stats["framing"]))
    print("\nEvery row is marked demo:true. Run with --wipe to clear, and delete "
          "the store before recording anything real.")


if __name__ == "__main__":
    main()
