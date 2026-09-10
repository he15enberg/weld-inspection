"""The verdict: fatal classes first, then a weighted score against editable rules.

Replaces the presence lookup that came before it. That table could not tell a
0.5 mm pore from an 8 mm one, or three pores from thirty -- every defect was
equal and the verdict was a set membership test.

Three layers, in order:

  1. FATAL. A crack or a discontinuity ends the assessment. This comes from
     rules.py, which is code, and no browser edit can reach it.
  2. RULES. The five editable rules in ruleset.py, each yielding a utilisation
     -- measured over limit. Above 1.0 is a breach.
  3. SCORE. Per-class weights times how far over the limit things are, summed,
     against two editable bands. This is what lets a good weld carry a few
     small pores: three of them score a handful of points, thirty do not.

The output keeps the envelope `rules.evaluate()` used -- verdict, headline,
checks, noted -- and adds to it. The phone renders `checks` and keeps working
untouched while the server changes underneath it.

INDETERMINATE is a first-class outcome. A rule that needs the seam, on a
capture with no usable seam, is not a pass. It comes back indeterminate and
drags the verdict to at least rework, exactly as an unmeasurable defect did
before. Silence must never read as clean.
"""

from __future__ import annotations

import rules as fatal
import ruleset as rs
from rules import Verdict

OUTCOME_VERDICT = {"note": Verdict.APPROVE, "rework": Verdict.REWORK,
                   "reject": Verdict.REJECT}


def _defect_rows(rows: list[dict]) -> list[dict]:
    """Defects that are actually on the weld.

    `on_seam` is None when there was no seam to test against -- those are kept,
    because discarding them would turn a failed seam detection into a clean
    weld. Only an explicit False is excluded.
    """
    return [r for r in rows
            if r.get("label") not in geometry_structural()
            and r.get("on_seam") is not False]


def geometry_structural() -> tuple:
    return ("workpiece", "weld_seam")


def _largest_mm(r: dict) -> float | None:
    vals = [v for v in (r.get("width_mm"), r.get("height_mm"))
            if isinstance(v, (int, float))]
    return max(vals) if vals else None


def _metric(name: str, defects: list[dict], seam: dict):
    """(value, note) for one metric, or (None, why) when it cannot be had."""
    if name in rs.NEEDS_SEAM and seam.get("status") != "ok":
        return None, seam.get("status", "seam unavailable")

    if name == "max_defect_mm":
        sizes = [s for s in (_largest_mm(d) for d in defects) if s is not None]
        if not defects:
            return 0.0, "no defects on the seam"
        if not sizes:
            return None, "defects found but none could be sized"
        return max(sizes), f"{len(sizes)} of {len(defects)} sized"

    if name == "defect_density_per_100mm":
        length = seam.get("length_mm")
        if not length:
            return None, "seam length unavailable"
        return len(defects) / length * 100.0, f"{len(defects)} over {length:.0f} mm"

    if name == "defect_area_fraction":
        area = seam.get("area_mm2")
        if not area:
            return None, "seam area unavailable"
        total = sum(d["area_mm2"] for d in defects
                    if isinstance(d.get("area_mm2"), (int, float)))
        return total / area, f"{total:.1f} of {area:.0f} mm2"

    if name == "seam_width_mm":
        w = seam.get("width_mm")
        return (w, "mean across the bead") if w else (None, "seam width unavailable")

    if name == "seam_continuity":
        c = seam.get("continuity")
        return (c, "seam over joint length") if c is not None else (
            None, "joint length unavailable")

    return None, f"unknown metric {name}"


def _utilisation(rule: dict, value: float) -> tuple[float, bool]:
    """How close to the limit, and whether it is breached.

    Utilisation is always "1.0 means at the limit", whichever way the
    comparator points -- so one progress bar renders every rule and a
    `>=` rule does not read backwards.
    """
    lo = float(rule["limit"])
    cmp = rule["comparator"]

    if cmp == "<=":
        return (value / lo if lo else 0.0), value > lo
    if cmp == ">=":
        # inverted: falling below the floor is the breach
        return (lo / value if value else float("inf")), value < lo
    hi = float(rule.get("limit_max", lo))
    if value < lo:
        return (lo / value if value else float("inf")), True
    if value > hi:
        return value / hi, True
    # inside the band: distance to whichever edge is nearer, as a fraction
    span = (hi - lo) / 2.0
    mid = (hi + lo) / 2.0
    return (abs(value - mid) / span if span else 0.0), False


def _fmt(rule: dict, value: float | None) -> str:
    if value is None:
        return "not measurable"
    unit = rs.METRICS.get(rule["metric"], ("", "", ""))[1]
    if rule["metric"] in ("defect_area_fraction", "seam_continuity"):
        shown, lo = f"{value * 100:.1f}%", f"{rule['limit'] * 100:.0f}%"
    else:
        shown, lo = f"{value:.2f}", f"{rule['limit']:.1f}"
    if rule["comparator"] == "between":
        return f"{shown} {unit}, band {lo} to {rule.get('limit_max')}"
    return f"{shown} {unit}, limit {rule['comparator']} {lo}"


def evaluate(rows: list[dict], seam: dict | None = None,
             config: dict | None = None) -> dict:
    """Detections plus seam metrics -> the verdict the app renders."""
    seam = seam or {"status": "no seam supplied"}
    config = config or rs.load()
    weights = config.get("weights") or rs.DEFAULT_WEIGHTS
    bands = config.get("bands") or rs.DEFAULT_BANDS

    base = fatal.evaluate(rows)          # crack / discontinuity, unchanged
    checks = list(base["checks"])
    verdict = Verdict[base["verdict"].upper()]

    defects = _defect_rows(rows)
    off_seam = [r for r in rows if r.get("on_seam") is False]

    utilisations: list[dict] = []
    score = 0.0
    indeterminate: list[str] = []

    for rule in config["rules"]:
        if not rule.get("enabled", True):
            continue
        value, note = _metric(rule["metric"], defects, seam)

        if value is None:
            indeterminate.append(rule["name"])
            entry = {"id": rule["id"], "name": rule["name"],
                     "metric": rule["metric"], "status": "indeterminate",
                     "detail": note, "utilisation": None,
                     "value": None, "limit": rule["limit"]}
            utilisations.append(entry)
            checks.append({"id": rule["id"], "title": rule["name"],
                           "status": "unmeasured", "verdict": Verdict.REWORK.label,
                           "detail": note,
                           "reason": "Could not be measured, so the limit "
                                     "cannot be applied."})
            continue

        util, breached = _utilisation(rule, value)
        entry = {"id": rule["id"], "name": rule["name"],
                 "metric": rule["metric"],
                 "status": "breached" if breached else "clear",
                 "value": round(value, 4), "limit": rule["limit"],
                 "limit_max": rule.get("limit_max"),
                 "comparator": rule["comparator"],
                 "utilisation": round(util, 3), "detail": _fmt(rule, value),
                 "weight": rule["weight"], "on_breach": rule["on_breach"]}
        utilisations.append(entry)

        if breached:
            score += float(rule["weight"]) * min(util, 4.0)
            verdict = max(verdict, OUTCOME_VERDICT[rule["on_breach"]])
            checks.append({"id": rule["id"], "title": rule["name"],
                           "status": "fired",
                           "verdict": OUTCOME_VERDICT[rule["on_breach"]].label,
                           "detail": _fmt(rule, value),
                           "reason": rs.METRICS[rule["metric"]][2]})
        else:
            checks.append({"id": rule["id"], "title": rule["name"],
                           "status": "clear", "verdict": Verdict.APPROVE.label,
                           "detail": _fmt(rule, value)})

    # Per-defect severity, on top of the rules. This is what separates "three
    # small pores" from "thirty" when no single rule has been breached.
    for d in defects:
        w = weights.get(d.get("label"), 0.0)
        if not w:
            continue
        size = _largest_mm(d) or 0.0
        score += w * (0.5 + min(size, 10.0) / 10.0)

    if score >= bands["reject_at"]:
        verdict = max(verdict, Verdict.REJECT)
    elif score >= bands["rework_at"]:
        verdict = max(verdict, Verdict.REWORK)
    if indeterminate:
        verdict = max(verdict, Verdict.REWORK)

    breached = [u for u in utilisations if u["status"] == "breached"]
    ranked = [u for u in utilisations if u["utilisation"] is not None]
    binding = max(ranked, key=lambda u: u["utilisation"]) if ranked else None

    return {
        **base,
        "verdict": verdict.label,
        "checks": checks,
        "score": round(score, 1),
        "bands": dict(bands),
        "utilisations": utilisations,
        "binding": binding,
        "indeterminate": indeterminate,
        "seam": seam,
        "off_seam_ignored": len(off_seam),
        "ruleset_version": config.get("version"),
        "headline": _headline(verdict, base, breached, indeterminate, binding),
    }


def _headline(verdict: Verdict, base: dict, breached: list,
              indeterminate: list, binding) -> str:
    """One line naming every cause, with the FINAL verdict's wording.

    Not `base["headline"]` when a fatal rule fired: that sentence was written
    knowing only about the fatal rules, so an undercut that scores its way up
    to reject would be announced as "Rework: undercut" over a reject verdict.
    A headline that contradicts the verdict beside it is worse than a vague one.
    """
    causes = [t.lower() for t in base.get("fired_titles") or []]
    causes += [b["name"].lower() for b in breached]

    if causes:
        shown = ", ".join(causes[:3])
        if len(causes) > 3:
            shown += f" and {len(causes) - 3} more"
        lead = {Verdict.REJECT: "Rejected: ", Verdict.REWORK: "Rework: ",
                Verdict.APPROVE: "Noted: "}[verdict]
        return lead + shown
    if indeterminate:
        return "Could not check: " + ", ".join(i.lower() for i in indeterminate[:2])
    if binding:
        return (f"Passes all rules - closest is {binding['name'].lower()} "
                f"at {binding['utilisation'] * 100:.0f}% of its limit")
    return "No rejectable defects found"
