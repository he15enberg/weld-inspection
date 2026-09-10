"""Persisting captures: files on disk, SQLite as the index.

Two copies of the truth, on purpose:

  `result.json` is the record. It is the response verbatim, so a capture can be
  replayed against a future checkpoint and it survives any schema change here.

  SQLite is only an index, and can be rebuilt from those JSON files at any time.
  It exists because the dashboard asks things like "reject rate this week" and
  "every capture with undercut" -- fine by scanning ten JSON files, unusable at
  a thousand.

Never derive one from the other at read time.

Writing must never cost a capture. `save()` catches everything and returns None:
a full disk or a locked database becomes a log line, not an HTTP 500 on a good
inspection. WELDZ_CAPTURES unset turns storage off entirely.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

log = logging.getLogger("weldz.store")

ROOT = Path(os.environ.get("WELDZ_CAPTURES", "")).expanduser()
KEEP_DAYS = int(os.environ.get("WELDZ_KEEP_DAYS", "0"))    # 0 = keep forever

# Only these names can be fetched through the API. A whitelist rather than a
# path join, so no request can walk out of the capture directory.
FILES = ("color.jpg", "overlay.jpg", "depth.u16", "confidence.u8", "result.json")

DEFECTS = ("crack", "discontinuity", "undercut", "porosity", "spatter", "overlap")

SCHEMA = """
CREATE TABLE IF NOT EXISTS captures (
    id TEXT PRIMARY KEY,
    ts TEXT NOT NULL,                 -- ISO 8601, server clock
    day TEXT NOT NULL,                -- YYYY-MM-DD, for the directory and grouping
    device TEXT,
    verdict TEXT NOT NULL,
    fired TEXT,                       -- comma-separated rule ids
    headline TEXT,
    n_detections INTEGER,
    n_defects INTEGER,
    worst_label TEXT,
    worst_mm REAL,
    coverage REAL,                    -- workpiece fraction of the frame
    depth_fill REAL,
    image_w INTEGER, image_h INTEGER,
    fx REAL, threshold REAL,
    checkpoint TEXT, checkpoint_mtime INTEGER, checkpoint_bytes INTEGER,
    resolution INTEGER, n_classes INTEGER,
    ms_total INTEGER, ms_infer INTEGER, ms_assess INTEGER,
    assess_status TEXT, assess_quality TEXT, assess_summary TEXT,
    missed TEXT,
    demo INTEGER DEFAULT 0            -- synthetic row from seed_demo.py
);
CREATE INDEX IF NOT EXISTS captures_ts ON captures(ts DESC);
CREATE INDEX IF NOT EXISTS captures_verdict ON captures(verdict);
CREATE INDEX IF NOT EXISTS captures_day ON captures(day);

CREATE TABLE IF NOT EXISTS detections (
    capture_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    confidence REAL,
    width_mm REAL, height_mm REAL, area_mm2 REAL,
    distance_m REAL, depth_fill REAL, uncertainty_mm REAL
);
CREATE INDEX IF NOT EXISTS detections_capture ON detections(capture_id);
CREATE INDEX IF NOT EXISTS detections_label ON detections(label);
"""


def enabled() -> bool:
    return bool(str(ROOT))


def db_path() -> Path:
    return ROOT / "weldz.db"


@contextmanager
def _connect():
    """A connection per call, committed and CLOSED.

    FastAPI runs sync endpoints on a threadpool, so a shared connection would
    need `check_same_thread=False` plus a lock of our own. One per call is
    simpler and, for a file database serving one dashboard, indistinguishable in
    cost. `busy_timeout` covers a write landing during a read.

    The close matters. `with sqlite3.connect(...)` manages the TRANSACTION, not
    the connection -- it commits and never closes. Leaking one handle per
    request eventually exhausts them, and on Windows the open handle also locks
    the database file against being replaced.
    """
    conn = sqlite3.connect(db_path(), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init() -> None:
    if not enabled():
        log.info("storage: off (WELDZ_CAPTURES unset)")
        return
    try:
        ROOT.mkdir(parents=True, exist_ok=True)
        with _connect() as conn:
            conn.executescript(SCHEMA)
            # A tiny migration, because CREATE TABLE IF NOT EXISTS will not add
            # a column to a database that already exists.
            cols = {r[1] for r in conn.execute("PRAGMA table_info(captures)")}
            if "demo" not in cols:
                conn.execute("ALTER TABLE captures ADD COLUMN demo INTEGER DEFAULT 0")
                log.info("added the `demo` column")
        n = _count()
        log.info("storage: %s (%d captures)%s", ROOT, n,
                 f", pruning past {KEEP_DAYS} days" if KEEP_DAYS else "")
        if KEEP_DAYS:
            prune()
    except Exception:                                              # noqa: BLE001
        log.exception("storage unavailable; captures will not be saved")


def _count() -> int:
    with _connect() as conn:
        return conn.execute("SELECT count(*) FROM captures").fetchone()[0]


def new_id(when: datetime) -> str:
    """Sorts chronologically in a plain directory listing."""
    return f"cap_{when:%Y%m%d_%H%M%S}_{secrets.token_hex(2)}"


def model_stamp(info: dict) -> dict:
    """Which checkpoint produced a result.

    Without this a stored capture is uninterpretable after a retrain -- there is
    no way to tell whether a `discontinuity` came from the 7-class head or the
    8-class one. mtime and size are a cheap content identity; a path alone is
    not, because the file behind it gets replaced.
    """
    path = Path(str(info.get("checkpoint", "")))
    stat = path.stat() if path.exists() else None
    return {
        "checkpoint": path.name or None,
        "checkpoint_mtime": int(stat.st_mtime) if stat else None,
        "checkpoint_bytes": stat.st_size if stat else None,
        "resolution": info.get("resolution"),
        "n_classes": len(info.get("classes") or []),
    }


def save(*, result: dict, color: bytes, overlay: bytes, depth: bytes,
         confidence: bytes, meta: dict, stamp: dict,
         coverage: float | None, depth_fill: float | None) -> str | None:
    """Write one capture. Returns its id, or None if anything went wrong."""
    if not enabled():
        return None

    when = datetime.now(timezone.utc)
    cid = new_id(when)
    day = f"{when:%Y-%m-%d}"
    folder = ROOT / day / cid

    try:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "color.jpg").write_bytes(color)
        (folder / "overlay.jpg").write_bytes(overlay)
        (folder / "depth.u16").write_bytes(depth)
        (folder / "confidence.u8").write_bytes(confidence)

        # `annotated` is dropped: it is the same bytes as overlay.jpg, and
        # base64 in JSON would inflate ~400 kB to ~550 kB and double the
        # per-capture footprint. mask_png stays -- it is ~300 B and is what
        # lets the cropped point cloud be rebuilt later.
        record = {k: v for k, v in result.items() if k != "annotated"}
        record |= {
            "id": cid,
            "captured_at": when.isoformat(timespec="seconds"),
            "device": meta.get("device"),
            "meta": meta,
            "model": stamp,
            "coverage": coverage,
            "frame_depth_fill": depth_fill,
        }
        (folder / "result.json").write_text(
            json.dumps(record, indent=1), encoding="utf-8")

        _index(cid, when, day, record, meta, stamp, coverage, depth_fill)
        return cid
    except Exception:                                              # noqa: BLE001
        log.exception("could not save capture %s", cid)
        return None


def _index(cid, when, day, record, meta, stamp, coverage, depth_fill) -> None:
    rows = record.get("detections") or []
    judgement = record.get("judgement") or {}
    assessment = record.get("assessment") or {}
    timing = record.get("timing_ms") or {}

    defects = [r for r in rows if r.get("label") in DEFECTS]
    worst_label, worst_mm = None, None
    for r in defects:
        size = max((v for v in (r.get("width_mm"), r.get("height_mm"))
                    if isinstance(v, (int, float))), default=None)
        if size is not None and (worst_mm is None or size > worst_mm):
            worst_label, worst_mm = r.get("label"), size
    if worst_label is None and defects:
        worst_label = defects[0].get("label")

    with _connect() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO captures VALUES ("
            ":id,:ts,:day,:device,:verdict,:fired,:headline,:n_detections,"
            ":n_defects,:worst_label,:worst_mm,:coverage,:depth_fill,"
            ":image_w,:image_h,:fx,:threshold,:checkpoint,:checkpoint_mtime,"
            ":checkpoint_bytes,:resolution,:n_classes,:ms_total,:ms_infer,"
            ":ms_assess,:assess_status,:assess_quality,:assess_summary,:missed,"
            ":demo)",
            {
                "id": cid,
                "ts": when.isoformat(timespec="seconds"),
                "day": day,
                "device": meta.get("device"),
                "verdict": judgement.get("verdict", "approve"),
                "fired": ",".join(judgement.get("fired") or []),
                "headline": judgement.get("headline"),
                "n_detections": len(rows),
                "n_defects": len(defects),
                "worst_label": worst_label,
                "worst_mm": worst_mm,
                "coverage": coverage,
                "depth_fill": depth_fill,
                "image_w": (record.get("image") or {}).get("width"),
                "image_h": (record.get("image") or {}).get("height"),
                "fx": meta.get("fx"),
                "threshold": meta.get("conf"),
                "ms_total": timing.get("total"),
                "ms_infer": timing.get("infer"),
                "ms_assess": timing.get("assess"),
                "assess_status": assessment.get("status"),
                "assess_quality": assessment.get("image_quality"),
                "assess_summary": assessment.get("summary"),
                "missed": ",".join(assessment.get("missed_rejectable") or []),
                "demo": 1 if record.get("demo") else 0,
                **stamp,
            },
        )
        conn.executemany(
            "INSERT INTO detections VALUES (?,?,?,?,?,?,?,?,?)",
            [(cid, r.get("label"), r.get("confidence"), r.get("width_mm"),
              r.get("height_mm"), r.get("area_mm2"), r.get("distance_m"),
              r.get("depth_fill"), r.get("uncertainty_mm")) for r in rows],
        )


# ---------------------------------------------------------------------------
# reading
# ---------------------------------------------------------------------------

def listing(*, verdict: str | None = None, label: str | None = None,
            since: str | None = None, until: str | None = None,
            limit: int = 40, offset: int = 0) -> dict:
    if not enabled():
        return {"total": 0, "captures": []}

    where, args = [], []
    if verdict:
        where.append("verdict = ?")
        args.append(verdict)
    if since:
        where.append("day >= ?")
        args.append(since)
    if until:
        where.append("day <= ?")
        args.append(until)
    if label:
        # EXISTS rather than a join: a capture with three pores must appear once
        where.append("EXISTS (SELECT 1 FROM detections d "
                     "WHERE d.capture_id = captures.id AND d.label = ?)")
        args.append(label)
    clause = f"WHERE {' AND '.join(where)}" if where else ""

    try:
        return _query(clause, args, limit, offset)
    except sqlite3.Error:
        log.exception("listing failed; is the index corrupt? try store.rebuild()")
        return {"total": 0, "captures": [], "error": "index unavailable"}


def _query(clause, args, limit, offset) -> dict:
    with _connect() as conn:
        total = conn.execute(
            f"SELECT count(*) FROM captures {clause}", args).fetchone()[0]
        rows = conn.execute(
            f"SELECT * FROM captures {clause} ORDER BY ts DESC LIMIT ? OFFSET ?",
            [*args, max(1, min(limit, 200)), max(0, offset)]).fetchall()
    return {"total": total, "captures": [dict(r) for r in rows]}


def record(cid: str) -> dict | None:
    """The stored result.json, read back off disk rather than reassembled."""
    path = _file(cid, "result.json")
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:                                              # noqa: BLE001
        log.exception("could not read %s", path)
        return None


def ids(limit: int = 500) -> list[str]:
    """Capture ids, newest first. Used by re-scoring to walk the archive."""
    if not enabled():
        return []
    try:
        with _connect() as conn:
            rows = conn.execute(
                "SELECT id FROM captures WHERE coalesce(demo, 0) = 0 "
                "ORDER BY ts DESC LIMIT ?", (max(1, limit),)).fetchall()
        return [r["id"] for r in rows]
    except sqlite3.Error:
        log.exception("could not list ids; try store.rebuild()")
        return []


def rejudge(cid: str, judgement: dict, version) -> bool:
    """Replace a stored capture's verdict, leaving everything else alone.

    Only `judgement` and the ruleset stamp are rewritten. The detections, the
    millimetres and the images are the record of what was SEEN and must never
    change because a limit moved -- re-scoring reinterprets evidence, it does
    not revise it.

    The JSON on disk is the record of truth, so it is written first and the
    index is updated to match. Written via a temp file and replaced, because a
    half-written result.json is a capture lost.
    """
    path = _file(cid, "result.json")
    if path is None:
        return False
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
        doc["judgement"] = judgement
        meta = doc.get("meta")
        if isinstance(meta, dict):
            meta["ruleset_version"] = version
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(doc), encoding="utf-8")
        tmp.replace(path)

        with _connect() as conn:
            conn.execute(
                "UPDATE captures SET verdict = ?, headline = ?, fired = ? "
                "WHERE id = ?",
                (judgement.get("verdict"), judgement.get("headline"),
                 ",".join(judgement.get("fired") or []), cid))
        return True
    except Exception:                                              # noqa: BLE001
        log.exception("could not re-judge %s", cid)
        return False


def _file(cid: str, name: str) -> Path | None:
    if not enabled() or name not in FILES:
        return None
    try:
        with _connect() as conn:
            row = conn.execute(
                "SELECT day FROM captures WHERE id = ?", (cid,)).fetchone()
    except sqlite3.Error:
        log.exception("lookup failed for %s", cid)
        return None
    if row is None:
        return None
    path = ROOT / row["day"] / cid / name
    return path if path.exists() else None


def file_path(cid: str, name: str) -> Path | None:
    return _file(cid, name)


def stats(days: int = 30) -> dict:
    """Aggregates for the overview. One SQL round trip per panel.

    Counted in SQL rather than shipped to the browser to count: the whole point
    of the index is that the client never sees rows it is not displaying.
    """
    if not enabled():
        return {"enabled": False}

    try:
        return _aggregate(days)
    except sqlite3.Error:
        log.exception("stats failed; is the index corrupt? try store.rebuild()")
        return {"enabled": True, "error": "index unavailable", "total": 0,
                "verdicts": {}, "per_day": [], "by_class": [], "framing": [],
                "timing": {}, "reject_rate": 0, "rework_rate": 0,
                "sizes": {}, "depth_hist": [0] * 10, "hours": [0] * 24,
                "demo": 0}


def _aggregate(days: int) -> dict:
    floor = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    with _connect() as conn:
        verdicts = {r["verdict"]: r["n"] for r in conn.execute(
            "SELECT verdict, count(*) n FROM captures GROUP BY verdict")}
        per_day = [dict(r) for r in conn.execute(
            "SELECT day, count(*) n, "
            "sum(verdict='reject') rejects, sum(verdict='rework') reworks "
            "FROM captures WHERE day >= ? GROUP BY day ORDER BY day", (floor,))]
        by_class = [dict(r) for r in conn.execute(
            "SELECT label, count(*) n, "
            "       round(avg(coalesce(width_mm, 0)), 2) avg_mm, "
            "       round(max(coalesce(width_mm, 0)), 2) max_mm "
            "FROM detections WHERE label IN "
            f"({','.join('?' * len(DEFECTS))}) "
            "GROUP BY label ORDER BY n DESC", DEFECTS)]
        # Coverage against verdict: the framing claim, finally measurable rather
        # than asserted from a couple of screenshots.
        framing = [dict(r) for r in conn.execute(
            "SELECT verdict, count(*) n, round(avg(coverage), 4) avg_coverage "
            "FROM captures WHERE coverage IS NOT NULL GROUP BY verdict")]
        recent = conn.execute(
            "SELECT round(avg(ms_total)) avg_ms, round(avg(ms_infer)) avg_infer, "
            "       round(avg(ms_assess)) avg_assess FROM captures "
            "WHERE ts >= datetime('now', '-7 days')").fetchone()

        # Sizes come back as raw lists and the percentiles are computed here.
        # SQLite has no percentile function, and a median is the honest summary
        # for defect size -- a mean is dragged around by one large pore.
        sizes = {}
        for label in DEFECTS:
            vals = [r[0] for r in conn.execute(
                "SELECT max(coalesce(width_mm, 0), coalesce(height_mm, 0)) s "
                "FROM detections WHERE label = ? AND width_mm IS NOT NULL "
                "ORDER BY s", (label,)) if r[0]]
            if vals:
                sizes[label] = {
                    "n": len(vals),
                    "min": round(vals[0], 2),
                    "p50": round(_percentile(vals, 0.50), 2),
                    "p95": round(_percentile(vals, 0.95), 2),
                    "max": round(vals[-1], 2),
                }

        # Depth coverage per detection, bucketed. This is the measurement
        # reliability distribution: a pile of mass below 0.3 means most sizes
        # rest on a handful of pixels, whatever the millimetres claim.
        depth_hist = [0] * 10
        for (fill,) in conn.execute(
                "SELECT depth_fill FROM detections WHERE depth_fill IS NOT NULL"):
            depth_hist[min(int(fill * 10), 9)] += 1

        demo = conn.execute(
            "SELECT count(*) FROM captures WHERE demo = 1").fetchone()[0]

        hours = [0] * 24
        for (hh, n) in conn.execute(
                "SELECT cast(strftime('%H', ts) AS INTEGER) h, count(*) "
                "FROM captures GROUP BY h"):
            if hh is not None:
                hours[hh] = n

    total = sum(verdicts.values())
    return {
        "enabled": True,
        "total": total,
        "verdicts": verdicts,
        "reject_rate": round(verdicts.get("reject", 0) / total, 4) if total else 0,
        "rework_rate": round(verdicts.get("rework", 0) / total, 4) if total else 0,
        "per_day": per_day,
        "by_class": by_class,
        "framing": framing,
        "timing": dict(recent) if recent else {},
        "demo": demo,
        "sizes": sizes,
        "depth_hist": depth_hist,
        "hours": hours,
    }


def _percentile(sorted_vals: list[float], q: float) -> float:
    """Linear-interpolated percentile over an already-sorted list."""
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    pos = q * (len(sorted_vals) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def prune() -> int:
    """Drop captures older than WELDZ_KEEP_DAYS. Returns how many went."""
    if not enabled() or KEEP_DAYS <= 0:
        return 0
    floor = (datetime.now(timezone.utc) - timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
    removed = 0
    try:
        with _connect() as conn:
            old = conn.execute(
                "SELECT id, day FROM captures WHERE day < ?", (floor,)).fetchall()
            for row in old:
                shutil.rmtree(ROOT / row["day"] / row["id"], ignore_errors=True)
            conn.execute("DELETE FROM captures WHERE day < ?", (floor,))
            removed = len(old)
        # empty date folders left behind
        for folder in ROOT.iterdir():
            if folder.is_dir() and folder.name < floor and not any(folder.iterdir()):
                folder.rmdir()
        if removed:
            log.info("pruned %d captures older than %s", removed, floor)
    except Exception:                                              # noqa: BLE001
        log.exception("prune failed")
    return removed


def rebuild() -> int:
    """Re-index every result.json on disk.

    The point of keeping the JSON as the record: the database is disposable.
    Delete weldz.db, run this, and the index is back.
    """
    if not enabled():
        return 0
    db_path().unlink(missing_ok=True)
    with _connect() as conn:
        conn.executescript(SCHEMA)

    n = 0
    for path in sorted(ROOT.glob("*/cap_*/result.json")):
        try:
            rec = json.loads(path.read_text(encoding="utf-8"))
            when = datetime.fromisoformat(rec["captured_at"])
            _index(rec["id"], when, path.parent.parent.name, rec,
                   rec.get("meta") or {}, rec.get("model") or {},
                   rec.get("coverage"), rec.get("frame_depth_fill"))
            n += 1
        except Exception:                                          # noqa: BLE001
            log.warning("skipped %s", path)
    log.info("rebuilt index from %d captures", n)
    return n


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    t0 = time.perf_counter()
    init()
    print(f"rebuilt {rebuild()} in {(time.perf_counter() - t0):.1f}s")
