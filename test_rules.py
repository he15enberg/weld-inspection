"""The verdict table. No GPU, no model, no network.

If these fail nothing downstream is worth looking at -- the verdict is the one
number a person acts on.
"""

import rules
from rules import Verdict, evaluate


def d(label, w=None, h=None):
    return {"label": label, "width_mm": w, "height_mm": h}


def test_clean_approves():
    r = evaluate([d("workpiece"), d("weld_seam")])
    assert r["verdict"] == "approve"
    assert r["fired"] == []


def test_crack_rejects():
    assert evaluate([d("crack", 2.0, 0.5)])["verdict"] == "reject"


def test_discontinuity_rejects():
    assert evaluate([d("discontinuity", 8.0, 3.0)])["verdict"] == "reject"


def test_undercut_reworks():
    r = evaluate([d("undercut", 0.7, 12.0)])
    assert r["verdict"] == "rework"
    assert r["fired"] == ["R3"]


def test_porosity_and_spatter_approve():
    r = evaluate([d("porosity", 4.2, 4.0), d("spatter", 1.1, 1.0)])
    assert r["verdict"] == "approve"
    # ...but they are still reported, so approve does not read as "nothing seen"
    assert r["noted"] == ["porosity", "spatter"]


def test_worst_outcome_wins():
    """Order of detections must not change the verdict."""
    both = [d("undercut", 0.7), d("crack", 1.0)]
    assert evaluate(both)["verdict"] == "reject"
    assert evaluate(list(reversed(both)))["verdict"] == "reject"


def test_presence_rule_fires_without_a_size():
    """A crack with no depth under it is still a crack."""
    r = evaluate([d("crack")])
    assert r["verdict"] == "reject"


def test_every_rule_gets_a_check_row():
    r = evaluate([d("crack")])
    assert {c["id"] for c in r["checks"]} == {ru.id for ru in rules.RULES}
    fired = [c for c in r["checks"] if c["status"] == "fired"]
    assert len(fired) == 1 and fired[0]["id"] == "R1"


def test_verdict_order_is_load_bearing():
    """max() picks the worst outcome, so the enum order must not be touched."""
    assert Verdict.APPROVE < Verdict.REWORK < Verdict.REJECT


def test_sized_rule_unmeasured_is_not_silently_cleared():
    """A size-limited rule with no depth must escalate, not pass."""
    probe = rules.Rule(id="RX", label="porosity", verdict=Verdict.REJECT,
                       title="Pore", reason="", min_mm=3.0)
    original = rules.RULES
    rules.RULES = (probe,)
    try:
        r = evaluate([d("porosity")])            # present, unmeasurable
        assert r["verdict"] == "rework"
        assert r["checks"][0]["status"] == "unmeasured"

        r = evaluate([d("porosity", 4.0)])        # over the limit
        assert r["verdict"] == "reject"

        r = evaluate([d("porosity", 1.0)])        # under it
        assert r["verdict"] == "approve"
    finally:
        rules.RULES = original


def test_headline_reads_as_a_sentence():
    assert evaluate([])["headline"] == "No rejectable defects found"
    assert evaluate([d("crack")])["headline"] == "Rejected: crack"
    assert evaluate([d("undercut")])["headline"] == "Rework: undercut"
    assert evaluate([d("crack"), d("discontinuity")])["headline"] == \
        "Rejected: crack and discontinuity"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"  ok  {name}")
    print("all passed")
