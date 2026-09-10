"""The verdict. Deterministic, presence-based, and decided here -- not by the VLM.

Rule compliance is a lookup, not a judgement: a model asked "does a crack mean
reject?" adds nothing and can get it wrong, unauditably. So the verdict comes
from the table below and the VLM only ever explains it.

The rules are DATA, not branches. Adding one means an entry in RULES; the logic
never changes. Worst outcome across all fired rules wins.

Today's set is presence-based, which has a useful consequence: no operator-
supplied material thickness is needed, so nothing here waits on a UI decision.
When a rule needs a measurement, give its entry a `min_mm` and the evaluator
already handles it.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


class Verdict(IntEnum):
    """Ordered so `max()` picks the worst outcome. Do not reorder."""

    APPROVE = 0
    REWORK = 1
    REJECT = 2

    @property
    def label(self) -> str:
        return self.name.lower()


@dataclass(frozen=True)
class Rule:
    id: str
    label: str                  # the detection class this fires on
    verdict: Verdict
    title: str                  # what the app shows
    reason: str                 # why, in one line
    min_mm: float | None = None  # fire only at or above this size; None = presence


RULES: tuple[Rule, ...] = (
    Rule(
        id="R1",
        label="crack",
        verdict=Verdict.REJECT,
        title="Crack",
        reason="Cracks are not permitted at any size.",
    ),
    Rule(
        id="R2",
        label="discontinuity",
        verdict=Verdict.REJECT,
        title="Discontinuity",
        reason="A discontinuity in the bead is not permitted.",
    ),
    Rule(
        id="R3",
        label="undercut",
        verdict=Verdict.REWORK,
        title="Undercut",
        reason="Undercut is repairable; the joint needs rework.",
    ),
)

# Everything not named above is acceptable on presence alone. Kept explicit so
# the app can show what was checked and passed rather than an empty list.
ACCEPTABLE = ("porosity", "spatter", "overlap")


def evaluate(detections: list[dict]) -> dict:
    """Detections -> verdict plus the per-rule outcome the app displays.

    A detection with no measured size still fires a presence rule. It does NOT
    fire a `min_mm` rule -- an unmeasurable defect must not be silently treated
    as small enough to pass, so those come back as `unmeasured` and are reported
    rather than counted as clear.
    """
    present: dict[str, list[dict]] = {}
    for d in detections:
        present.setdefault(d.get("label", ""), []).append(d)

    checks = []
    fired: list[Rule] = []
    unmeasured: list[str] = []

    for rule in RULES:
        hits = present.get(rule.label, [])
        if not hits:
            checks.append({
                "id": rule.id, "title": rule.title, "status": "clear",
                "verdict": Verdict.APPROVE.label, "detail": "not detected",
            })
            continue

        if rule.min_mm is None:
            fired.append(rule)
            worst = max((_size(h) or 0.0) for h in hits)
            detail = f"{len(hits)} found"
            if worst:
                detail += f", largest {worst:.1f} mm"
            checks.append({
                "id": rule.id, "title": rule.title, "status": "fired",
                "verdict": rule.verdict.label, "detail": detail,
                "reason": rule.reason,
            })
            continue

        sized = [s for s in (_size(h) for h in hits) if s is not None]
        if not sized:
            unmeasured.append(rule.title)
            checks.append({
                "id": rule.id, "title": rule.title, "status": "unmeasured",
                "verdict": Verdict.REWORK.label,
                "detail": f"{len(hits)} found, no depth to size them",
                "reason": "Present but unmeasurable, so the limit cannot be applied.",
            })
            continue

        worst = max(sized)
        if worst >= rule.min_mm:
            fired.append(rule)
            checks.append({
                "id": rule.id, "title": rule.title, "status": "fired",
                "verdict": rule.verdict.label,
                "detail": f"largest {worst:.1f} mm, limit {rule.min_mm:.1f} mm",
                "reason": rule.reason,
            })
        else:
            checks.append({
                "id": rule.id, "title": rule.title, "status": "clear",
                "verdict": Verdict.APPROVE.label,
                "detail": f"largest {worst:.1f} mm, under {rule.min_mm:.1f} mm",
            })

    # An unmeasurable sized-rule hit is at least REWORK: someone must look.
    verdict = max(
        [r.verdict for r in fired] + ([Verdict.REWORK] if unmeasured else []),
        default=Verdict.APPROVE,
    )

    return {
        "verdict": verdict.label,
        "fired": [r.id for r in fired],
        # titles as well as ids: scoring.py composes one headline across the
        # fatal rules AND the tunable ones, and it needs the words
        "fired_titles": [r.title for r in fired] + list(unmeasured),
        "headline": _headline(verdict, fired, unmeasured),
        "checks": checks,
        # what was seen but is acceptable on presence -- shown so an APPROVE does
        # not look like "nothing was found"
        "noted": sorted(
            label for label in present
            if label in ACCEPTABLE and present[label]
        ),
    }


def _size(d: dict) -> float | None:
    """Largest lateral dimension in mm, when depth gave us one."""
    w, h = d.get("width_mm"), d.get("height_mm")
    vals = [v for v in (w, h) if isinstance(v, (int, float))]
    return max(vals) if vals else None


def _headline(verdict: Verdict, fired: list[Rule], unmeasured: list[str]) -> str:
    if verdict is Verdict.APPROVE:
        return "No rejectable defects found"
    names = [r.title.lower() for r in fired] + [u.lower() for u in unmeasured]
    joined = names[0] if len(names) == 1 else ", ".join(names[:-1]) + f" and {names[-1]}"
    return ("Rejected: " if verdict is Verdict.REJECT else "Rework: ") + joined
