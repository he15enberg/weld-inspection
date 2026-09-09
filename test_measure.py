"""Millimetre maths against known geometry. No GPU, no model, no phone.

    python test_measure.py

A 40 x 20 mm rectangle at 300 mm from a camera with fx = 1450 must come back as
40 x 20 mm. If it does not, nothing downstream is worth looking at.
"""

import numpy as np

import measure as mm

IMG_W, IMG_H, FX, Z = 1920, 1440, 1450.0, 0.300


def _case(depth=None):
    mm_px = Z / FX * 1000
    w_px, h_px = 40 / mm_px, 20 / mm_px
    mask = np.zeros((IMG_H, IMG_W), bool)
    mask[600:600 + round(h_px), 800:800 + round(w_px)] = True
    xyxy = [800, 600, 800 + w_px, 600 + h_px]
    if depth is None:
        depth = np.full((192, 256), Z, np.float32)
    conf = np.full((192, 256), mm.CONF_HIGH, np.uint8)
    return mm.measure(mask, xyxy, depth, conf, FX, IMG_W), mm_px


def test_known_rectangle():
    r, mm_px = _case()
    assert abs(r["mm_per_px"] - mm_px) < 1e-4
    assert abs(r["width_mm"] - 40) < 0.1
    assert abs(r["height_mm"] - 20) < 0.1
    # area comes from the mask, so it carries pixel-rounding error the box does not
    assert abs(r["area_mm2"] - 800) < 5
    assert r["depth_fill"] == 1.0


def test_edge_uncertainty_dominates():
    """For small features the limit is mask boundary precision, not LiDAR."""
    r, mm_px = _case()
    assert 2 * mm_px > 40 * mm.DEPTH_REL_NOISE * 0.9


def test_no_depth_degrades_rather_than_invents():
    r, _ = _case(depth=np.zeros((192, 256), np.float32))
    assert r["distance_m"] is None
    assert r["width_mm"] is None
    assert r["depth_fill"] == 0.0


def test_partial_depth_is_reported():
    depth = np.full((192, 256), Z, np.float32)
    depth[:, :128] = 0                      # left half of the frame has no reading
    r, _ = _case(depth=depth)
    assert 0 < r["depth_fill"] < 0.5        # the mask sits mostly in the dead half
    assert r["width_mm"] is not None        # but a median still exists


def test_uint16_wire_format_round_trips():
    depth = np.full((192, 256), Z, np.float32)
    raw = (depth * 1000).astype("<u2").tobytes()
    assert np.abs(mm.decode_depth(raw, 256, 192) - depth).max() < 1e-6


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"  ok  {name}")
    print("all passed")
