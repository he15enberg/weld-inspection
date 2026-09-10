"""Fill the store with plausible history, cloned from a REAL capture.

`seed_demo.py` draws its own weld images with PIL, which is fine for laying out
a chart and useless for anything that reads the pixels -- the point cloud view
needs a real depth buffer and a real photograph behind it. This takes one
genuine capture and replays it across a stretch of dates, copying the four
binary files verbatim so every seeded row has a working photo, overlay, depth
map and confidence map.

What varies is the DETECTION LIST, not the pixels: counts and sizes are
resampled per clone and the verdict is re-derived by the same `scoring.evaluate`
the server runs, against the live `ruleset.json`. So the charts show a real
distribution rather than noise, and no row carries a verdict the rule table
would disagree with.

    python seed_from_capture.py --source ../captures/2026-09-10/cap_...
    python seed_from_capture.py --days 28 --count 120
    python seed_from_capture.py --wipe-demo        # clear seeded rows first

Every row is marked `"demo": true` and the dashboard says so while any are
present. The structural masks (workpiece, weld_seam) are copied unchanged, so
they still line up with the copied depth buffer -- which is what keeps the
point cloud honest. Invented defect rows carry no mask, because a mask in the
wrong place would be worse than none.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import random
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

DEVICES = ["iPhone15,3", "iPhone16,2", "iPhone15,3", "iPhone16,1"]
OPERATORS = ["A. Rehman", "S. Manikumar", "J. Fernandes", "K. Iyer"]

SUMMARY = {
    "reject": [
        "A dark line runs along the toe of the bead over roughly a third of "
        "its length; the surface is otherwise even.",
        "There is a clear break in the bead about a third of the way along.",
        "The bead stops short and restarts, leaving a visible gap at the toe.",
    ],
    "rework": [
        "The bead edge is cut back on the left over roughly a third of its "
        "length.",
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
            "bead width varies along the run", "the start of the run is uneven"]


def defect_row(template: dict, label: str, size_mm: float,
               rng: random.Random) -> dict:
    """One invented defect, shaped like the real ones but with no mask.

    Geometry is derived from `size_mm` and the source's own mm-per-pixel, so a
    2 mm pore has a 2 mm box rather than whatever the template happened to be.
    """
    row = copy.deepcopy(template)
    row.pop("mask_png", None)          # no mask is better than a wrong one
    mm_px = row.get("mm_per_px") or 0.135
    w_px = max(int(round(size_mm / mm_px)), 3)
    h_px = max(int(round(size_mm * rng.uniform(0.6, 1.0) / mm_px)), 3)
    x0 = rng.randint(520, 600)
    y0 = rng.randint(360, 1080)
    row.update({
        "label": label,
        "confidence": round(rng.uniform(0.28, 0.72), 3),
        "bbox_px": [x0, y0, x0 + w_px, y0 + h_px],
        "width_mm": round(size_mm, 2),
        "height_mm": round(size_mm * rng.uniform(0.6, 1.0), 2),
        "area_mm2": round(size_mm * size_mm * 0.7, 2),
        "depth_fill": round(rng.uniform(0.35, 1.0), 3),
    })
    return row


def build_rows(src_rows: list[dict], target: str, rng: random.Random) -> list[dict]:
    """A detection list for one clone, aimed at `target` but not forced to it.

    The verdict is recomputed from these rows afterwards, so `target` only
    steers the sampling -- if the numbers land somewhere else, the recomputed
    verdict is what gets stored. That is deliberate: a seeded row whose verdict
    contradicts its own detections would make the dashboard lie.
    """
    structural = [copy.deepcopy(r) for r in src_rows
                  if r.get("label") in ("workpiece", "weld_seam")]
    pool = [r for r in src_rows if r.get("label") == "porosity"] or src_rows
    template = pool[0]

    rows = list(structural)

    # Sampled against the LIVE ruleset rather than by feel. The score weights
    # are porosity 5, overlap 15, undercut 25 with bands at 20 / 60, and E1
    # trips on any defect over 3 mm while E3 trips once defects pass 2% of the
    # seam's area. Sampling "a few pores" without checking those puts almost
    # every clone over the line -- the first run of this script came out at a
    # 71% reject rate for exactly that reason.
    if target == "approve":
        n_por, cap = rng.randint(0, 3), 2.4          # <= 15 pts, under E1 and E3
    elif target == "rework":
        n_por, cap = rng.randint(4, 8), 2.9          # 20-40 pts
    else:
        n_por, cap = rng.randint(12, 22), 6.5        # >= 60 pts, and over E1

    # a long tail inside the cap, so p50 and p95 genuinely differ in the charts
    for _ in range(n_por):
        size = rng.gauss(cap * 0.55, cap * 0.18) + rng.expovariate(2.2)
        rows.append(defect_row(template, "porosity",
                               min(max(size, 0.4), cap), rng))

    # spatter is 1 point each, so it never moves a band on its own
    for _ in range(rng.choices([0, 1, 2, 3], weights=[40, 32, 18, 10])[0]):
        rows.append(defect_row(template, "spatter", rng.uniform(0.5, 2.4), rng))

    if target != "approve" and rng.random() < 0.18:
        rows.append(defect_row(template, "overlap", rng.uniform(1.5, 4.0), rng))

    # undercut alone is 25 points -- enough for rework by itself, which is why
    # it is the usual way a rework clone gets there
    if target == "rework" and rng.random() < 0.45:
        rows.append(defect_row(template, "undercut", rng.uniform(0.4, 1.8), rng))
    if target == "reject" and rng.random() < 0.35:
        rows.append(defect_row(template, "undercut", rng.uniform(0.6, 2.2), rng))

    if target == "reject" and rng.random() < 0.35:
        label = rng.choice(["crack", "discontinuity"])
        rows.append(defect_row(template, label, rng.uniform(1.4, 9.0), rng))

    return rows


def build_seam(src_seam: dict, rows: list[dict], rng: random.Random,
               target: str = "approve") -> dict:
    """Seam metrics consistent with the row list, so the E-rules see numbers
    that match the detections beside them."""
    seam = copy.deepcopy(src_seam) if isinstance(src_seam, dict) else {}
    length = round(rng.uniform(78.0, 112.0), 2)
    defects = [r for r in rows
               if r.get("label") not in ("workpiece", "weld_seam")]
    area = sum(r.get("area_mm2") or 0 for r in defects)
    seam.update({
        "status": "ok",
        "length_mm": length,
        "width_mm": round(rng.uniform(4.6, 9.4), 2),
        "width_max_mm": round(rng.uniform(5.0, 10.5), 2),
        "area_mm2": round(length * rng.uniform(5.5, 7.5), 1),
        # E5 wants >= 0.9, so this has to track the target or it fires on half
        # the rows regardless of what the detections say
        "continuity": round(min(max(rng.gauss(
            {"approve": 0.96, "rework": 0.93, "reject": 0.84}[target],
            0.03), 0.35), 1.0), 3),
        "defects_on_seam": max(len(defects) - rng.randint(0, 2), 0),
        "defects_off_seam": rng.randint(0, 2),
        "elongation": round(rng.uniform(9.0, 19.0), 1),
    })
    seam["defect_area_mm2"] = round(area, 1)
    return seam


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="")
    ap.add_argument("--days", type=int, default=24)
    ap.add_argument("--count", type=int, default=110)
    ap.add_argument("--root", default=os.environ.get("WELDZ_CAPTURES", "captures"))
    ap.add_argument("--seed", type=int, default=20260911)
    ap.add_argument("--wipe-demo", action="store_true",
                    help="delete previously seeded rows (leaves real ones)")
    args = ap.parse_args()

    root = Path(args.root).expanduser().resolve()
    os.environ["WELDZ_CAPTURES"] = str(root)

    import geometry  # noqa: F401  (imported for parity with the server)
    import ruleset
    import scoring
    import store
    store.ROOT = root
    store.init()

    # Newest real capture with the current geometry, unless one is named. A
    # pre-rotation capture would seed a history whose point clouds do not match
    # the masks, which is exactly the mismatch this pipeline was fixed to avoid.
    if args.source:
        src_dir = Path(args.source).expanduser().resolve()
    else:
        best = None
        for f in sorted(root.rglob("result.json")):
            doc = json.loads(f.read_text(encoding="utf-8"))
            if doc.get("demo"):
                continue
            if (doc.get("geometry") or {}).get("crop"):
                best = f.parent
        if best is None:
            raise SystemExit("no real capture with a crop/rotate geometry found "
                             "-- take one with the current app, or pass --source")
        src_dir = best

    src = json.loads((src_dir / "result.json").read_text(encoding="utf-8"))
    print(f"cloning {src_dir.name}  ({src['image']['width']}x"
          f"{src['image']['height']}, {len(src['detections'])} detections)")

    if args.wipe_demo:
        removed = 0
        for f in sorted(root.rglob("result.json")):
            if json.loads(f.read_text(encoding="utf-8")).get("demo"):
                shutil.rmtree(f.parent, ignore_errors=True)
                removed += 1
        if removed:
            store.rebuild()
        print(f"  removed {removed} previously seeded rows")

    blobs = {name: (src_dir / name).read_bytes()
             for name in ("color.jpg", "overlay.jpg", "depth.u16",
                          "confidence.u8")}
    meta = dict(src.get("meta") or {})
    config = ruleset.load()
    rng = random.Random(args.seed)
    now = datetime.now(timezone.utc)

    # A weekday rhythm and an improving reject rate, so the trend charts have a
    # trend rather than noise.
    plan: list[datetime] = []
    for back in range(args.days - 1, -1, -1):
        day = now - timedelta(days=back)
        weekend = day.weekday() >= 5
        share = 0.25 if weekend else 1.0
        n = max(int(round(args.count / args.days * share * rng.uniform(0.5, 1.6))), 0)
        for _ in range(n):
            plan.append(day.replace(
                hour=rng.choice([7, 8, 9, 10, 11, 13, 14, 15, 16, 17]),
                minute=rng.randrange(60), second=rng.randrange(60)))

    made: dict[str, int] = {}
    for when in plan:
        progress = 1 - ((now - when).days / max(args.days - 1, 1))
        roll = rng.random()
        p_reject = 0.30 - 0.17 * progress
        p_rework = 0.26 - 0.07 * progress
        target = ("reject" if roll < p_reject
                  else "rework" if roll < p_reject + p_rework else "approve")

        rows = build_rows(src["detections"], target, rng)
        seam = build_seam(src.get("seam") or {}, rows, rng, target)
        judgement = scoring.evaluate(rows, seam, config)
        verdict = judgement["verdict"]

        infer = rng.randint(240, 420)
        assess_ms = rng.randint(2100, 4200)
        result = {
            "detections": rows,
            "image": dict(src["image"]),
            "geometry": copy.deepcopy(src.get("geometry") or {}),
            "seam": seam,
            "annotated": "",              # save() drops it anyway
            "judgement": judgement,
            "assessment": {
                "status": "ready",
                "summary": rng.choice(SUMMARY.get(verdict, SUMMARY["approve"])),
                "concerns": rng.sample(CONCERNS, rng.choices(
                    [0, 1, 2], weights=[46, 36, 18])[0]),
                "image_quality": rng.choice(["good", "good", "fair", "poor"]),
                "missed_rejectable": ["crack"] if rng.random() < 0.03 else [],
                "ms": assess_ms,
            },
            "timing_ms": {"decode": rng.randint(30, 90), "infer": infer,
                          "measure": rng.randint(90, 260), "assess": assess_ms,
                          "total": infer + assess_ms + rng.randint(140, 380)},
            "demo": True,
        }

        cid = store.save(
            result=result,
            color=blobs["color.jpg"], overlay=blobs["overlay.jpg"],
            depth=blobs["depth.u16"], confidence=blobs["confidence.u8"],
            meta={**meta, "device": rng.choice(DEVICES),
                  "operator": rng.choice(OPERATORS), "demo": True},
            stamp=store.model_stamp({}),
            coverage=round(min(max(rng.gauss(0.42, 0.12), 0.05), 0.92), 4),
            depth_fill=round(min(max(rng.gauss(0.86, 0.07), 0.35), 0.99), 4),
        )
        if not cid:
            continue

        # Backdate the row AND move the folder. store.file_path() resolves from
        # the row's `day`, so moving one without the other orphans the files and
        # the detail view comes back empty.
        new_day = f"{when:%Y-%m-%d}"
        old = root / f"{now:%Y-%m-%d}" / cid
        new = root / new_day / cid
        if old != new and old.exists():
            new.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old), str(new))
        with store._connect() as conn:
            conn.execute("UPDATE captures SET ts = ?, day = ? WHERE id = ?",
                         (when.isoformat(timespec="seconds"), new_day, cid))
        made[verdict] = made.get(verdict, 0) + 1

    total = sum(made.values())
    stats = store.stats(days=args.days + 2)
    print(f"\nseeded {total} captures over {args.days} days into {root}")
    print(f"  verdicts     {made}")
    print(f"  reject rate  {stats['reject_rate']:.1%}")
    print(f"  days present {len(stats['per_day'])}")
    print(f"  classes      "
          + ", ".join(f"{c['label']} {c['n']}" for c in stats["by_class"]))
    print("\nEvery row is marked demo:true, and every one has a real photo, "
          "depth map and\nworkpiece mask behind it -- so the point cloud view "
          "works on all of them.\nRun with --wipe-demo to clear.")


if __name__ == "__main__":
    main()
