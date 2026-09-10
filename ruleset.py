"""The five editable rules, stored as data and versioned.

Deliberately NOT where cracks live. `rules.py` keeps the fatal classes in code
because nobody should be able to edit "a crack is acceptable" from a browser
form. This file holds the tunable layer: limits an inspector might legitimately
argue about, on quantities the server knows how to compute.

`metric` is a closed vocabulary, not an expression. A rule editor that accepted
arbitrary formulae would be a remote code execution endpoint with a nice UI;
this way the browser chooses from a list the server already implements, and the
worst a bad edit can do is set a silly limit.

Every save bumps `version`. That matters more than it looks: the moment limits
are editable, two captures judged under different limits are not comparable,
and a dashboard chart spanning the change is quietly mixing two systems. The
version travels with each stored capture so they can be told apart.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

log = logging.getLogger("weldz.ruleset")

# Quantities scoring.py knows how to measure. Anything else is rejected on save.
METRICS = {
    "max_defect_mm": ("Largest defect", "mm",
                      "The biggest single defect on the seam."),
    "defect_density_per_100mm": ("Defect density", "per 100 mm",
                                 "How many defects per 100 mm of seam."),
    "defect_area_fraction": ("Defect area", "% of seam",
                             "Total defect area against the seam's own area."),
    "seam_width_mm": ("Bead width", "mm",
                      "Mean width of the bead across the joint."),
    "seam_continuity": ("Seam continuity", "% of joint",
                        "How much of the joint the weld actually covers."),
}

COMPARATORS = ("<=", ">=", "between")
OUTCOMES = ("note", "rework", "reject")

# Which metrics cannot be computed without a usable seam. When geometry reports
# anything other than "ok", these go indeterminate rather than passing.
NEEDS_SEAM = {"defect_density_per_100mm", "defect_area_fraction",
              "seam_width_mm", "seam_continuity"}

DEFAULTS: list[dict] = [
    {"id": "E1", "name": "Largest defect", "metric": "max_defect_mm",
     "comparator": "<=", "limit": 3.0, "weight": 25, "on_breach": "rework",
     "enabled": True},
    {"id": "E2", "name": "Defect density", "metric": "defect_density_per_100mm",
     "comparator": "<=", "limit": 8.0, "weight": 15, "on_breach": "rework",
     "enabled": True},
    {"id": "E3", "name": "Defect area", "metric": "defect_area_fraction",
     "comparator": "<=", "limit": 0.02, "weight": 20, "on_breach": "rework",
     "enabled": True},
    {"id": "E4", "name": "Bead width", "metric": "seam_width_mm",
     "comparator": "between", "limit": 4.0, "limit_max": 12.0,
     "weight": 10, "on_breach": "note", "enabled": True},
    {"id": "E5", "name": "Seam continuity", "metric": "seam_continuity",
     "comparator": ">=", "limit": 0.90, "weight": 30, "on_breach": "reject",
     "enabled": True},
]

# Score bands. Editable alongside the rules, because "how much is too much" is
# the same kind of judgement as a limit.
DEFAULT_BANDS = {"rework_at": 20.0, "reject_at": 60.0}

# Per-class severity. A weld with three small pores should still pass, and a
# weighted sum gives that for free -- three pores score a few points, fifteen
# do not. crack and discontinuity are absent on purpose: rules.py ends the
# assessment before any arithmetic happens.
DEFAULT_WEIGHTS = {
    "undercut": 25.0,
    "overlap": 15.0,
    "porosity": 5.0,
    "spatter": 1.0,
}


def path() -> Path:
    root = os.environ.get("WELDZ_CAPTURES", "captures")
    return Path(root).expanduser() / "ruleset.json"


def default() -> dict:
    return {"version": 1, "saved": None, "rules": [dict(r) for r in DEFAULTS],
            "bands": dict(DEFAULT_BANDS), "weights": dict(DEFAULT_WEIGHTS)}


def load() -> dict:
    """Current rule set, or the defaults. Never raises -- a corrupt or missing
    file falls back rather than taking the measure endpoint down with it."""
    p = path()
    try:
        if p.exists():
            doc = json.loads(p.read_text(encoding="utf-8"))
            ok, err = validate(doc)
            if ok:
                return doc
            log.warning("ruleset.json is invalid (%s); using defaults", err)
    except Exception as exc:                                       # noqa: BLE001
        log.warning("could not read %s (%s); using defaults", p, exc)
    return default()


def validate(doc: dict) -> tuple[bool, str]:
    if not isinstance(doc, dict):
        return False, "not an object"
    rules = doc.get("rules")
    if not isinstance(rules, list) or not rules:
        return False, "rules must be a non-empty list"
    seen = set()
    for r in rules:
        rid = r.get("id")
        if not rid or rid in seen:
            return False, f"duplicate or missing rule id: {rid!r}"
        seen.add(rid)
        if r.get("metric") not in METRICS:
            return False, f"{rid}: unknown metric {r.get('metric')!r}"
        if r.get("comparator") not in COMPARATORS:
            return False, f"{rid}: unknown comparator {r.get('comparator')!r}"
        if r.get("on_breach") not in OUTCOMES:
            return False, f"{rid}: unknown outcome {r.get('on_breach')!r}"
        for key in ("limit", "weight"):
            if not isinstance(r.get(key), (int, float)):
                return False, f"{rid}: {key} must be a number"
        if r["weight"] < 0:
            return False, f"{rid}: weight cannot be negative"
        if r["comparator"] == "between":
            hi = r.get("limit_max")
            if not isinstance(hi, (int, float)) or hi <= r["limit"]:
                return False, f"{rid}: limit_max must be above limit"

    bands = doc.get("bands") or {}
    for key in ("rework_at", "reject_at"):
        if not isinstance(bands.get(key), (int, float)):
            return False, f"bands.{key} must be a number"
    if bands["reject_at"] <= bands["rework_at"]:
        return False, "bands.reject_at must be above bands.rework_at"

    weights = doc.get("weights") or {}
    for k, v in weights.items():
        if not isinstance(v, (int, float)) or v < 0:
            return False, f"weights.{k} must be a non-negative number"
    return True, ""


def save(doc: dict) -> dict:
    """Validate, bump the version, write. Returns the stored document.

    The version is taken from what is on disk rather than from the caller, so a
    stale browser tab cannot roll it backwards and make two different rule sets
    share a number.
    """
    ok, err = validate(doc)
    if not ok:
        raise ValueError(err)
    current = load()
    stored = {
        "version": int(current.get("version", 0)) + 1,
        "saved": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "rules": doc["rules"],
        "bands": doc["bands"],
        "weights": doc.get("weights") or dict(DEFAULT_WEIGHTS),
    }
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(stored, indent=2), encoding="utf-8")
    tmp.replace(p)          # atomic: a half-written ruleset must never be read
    log.info("ruleset saved, version %d", stored["version"])
    return stored
