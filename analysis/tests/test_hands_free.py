"""Tests for analysis/hands_free.py on synthetic signals: the gestures it must catch, the near misses it must
not, and the calibration's tuning (the owner's recordings stay in _local/; validate_hands_free.py counts false
triggers on them).

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

import numpy as np
import pytest
from test_eeg_detectors import noise

import eeg_detectors as det
import hands_free as hf
from make_gesture_fixture import clench, double_clench, glance, step

FS = det.FS


def quiet(seconds: float, seed: int = 1) -> np.ndarray:
    """Four channels of 1/f noise plus a little broadband noise, so the muscle band has a rest level."""
    n = int(seconds * FS)
    rng = np.random.default_rng(seed + 100)
    return noise(n, seed=seed) + rng.normal(0, 1.5, (4, n))


def found(x: np.ndarray, settings: hf.Settings | None = None, missing: np.ndarray | None = None) -> list[hf.Gesture]:
    return hf.run(hf.inputs(x, missing), settings).gestures


# ---- double clench ----


def test_a_double_clench_is_found_once_after_two_quiet_seconds() -> None:
    x = quiet(50)
    double_clench(x, 40.0)
    g = found(x)
    assert [e.kind for e in g] == ["clench"]
    e = g[0]
    assert e.start == 400 and e.end == 413  # 40.0-41.4 s in ticks
    assert e.at == 43  # 2 s of quiet after 41.4 s ends at tick 433: the end of second 43 decides it
    assert e.level > 15


@pytest.mark.parametrize(
    ("name", "make"),
    [
        ("one clench", lambda x: clench(x, 40.0, 0.5)),
        ("three clenches", lambda x: (double_clench(x, 40.0), clench(x, 42.0, 0.4))),
        ("two clenches 2 s apart", lambda x: double_clench(x, 40.0, pause=2.0)),
        ("two clenches 0.2 s apart", lambda x: double_clench(x, 40.0, pause=0.2)),
        ("a long first clench", lambda x: double_clench(x, 40.0, first=1.5)),
        ("a tick-short clench", lambda x: double_clench(x, 40.0, first=0.06)),
        ("other muscle 1.5 s before", lambda x: (clench(x, 38.0, 0.3), double_clench(x, 40.0))),
        ("other muscle 1.8 s after", lambda x: (double_clench(x, 40.0), clench(x, 43.2, 0.3))),
        ("one side only", lambda x: (clench(x, 40.0, 0.4, sides=(2,)), clench(x, 41.0, 0.4, sides=(2,)))),
        ("before the rest level is known (30 s)", lambda x: double_clench(x, 20.0)),
        ("weak clenches", lambda x: double_clench(x, 40.0, uv=4.0)),
    ],
)
def test_near_misses_are_not_a_double_clench(name: str, make) -> None:  # type: ignore[no-untyped-def]
    x = quiet(50)
    make(x)
    assert [e for e in found(x) if e.kind == "clench"] == [], name


def test_a_hole_or_movement_within_2_s_spoils_it() -> None:
    x = quiet(50)
    double_clench(x, 40.0)
    miss = np.zeros(x.shape[1], bool)
    miss[int(42.6 * FS) : int(42.7 * FS)] = True
    assert found(x, missing=miss) == []
    x2 = quiet(50)
    double_clench(x2, 40.0)
    x2[:, int(38.5 * FS) : int(38.8 * FS)] += 400  # three or more channels jump: movement
    assert found(x2) == []


def test_the_clench_level_is_a_setting() -> None:
    x = quiet(50)
    double_clench(x, 40.0, uv=6.0)
    level = found(x, hf.Settings(clench_x=4.0))[0].level
    assert found(x, hf.Settings(clench_x=level * 1.01)) == []
    assert found(x, hf.Settings(clench_x=4.0, clench_on=False)) == []


def test_clusters_are_kept_with_the_rule_they_broke() -> None:
    x = quiet(60)
    double_clench(x, 35.0, pause=2.0)
    double_clench(x, 45.0)
    g = hf.run(hf.inputs(x))
    whys = [hf.clench_why(c, g.settings) for c in g.clusters if c.kind == "clench" and c.bursts[0].start >= 340]
    assert whys == ["one", "one", "ok"] or whys == ["apart", "ok"]


# ---- glance ----


def test_a_glance_one_way_then_the_other_and_back() -> None:
    x = quiet(50)
    glance(x, 40.0, uv=120.0)
    g = found(x)
    assert [e.kind for e in g] == ["glance"]
    assert g[0].level == pytest.approx(120.0, rel=0.25)
    assert g[0].start == pytest.approx(40.0 * FS, abs=15)


def test_left_and_right_once_known() -> None:
    x = quiet(50)
    glance(x, 40.0, uv=120.0)  # the first step is +: left when left_sign = +1
    assert len(found(x, hf.Settings(left_sign=1))) == 1
    assert found(x, hf.Settings(left_sign=-1)) == []
    y = quiet(50)
    glance(y, 40.0, uv=120.0, back=False)  # away and back: two steps
    assert len(found(y)) == 1


@pytest.mark.parametrize(
    ("name", "make"),
    [
        ("one step", lambda x: step(x, 40.0, 150.0)),
        ("small steps", lambda x: glance(x, 40.0, uv=50.0)),
        ("steps 2 s apart", lambda x: (step(x, 40.0, 120.0), step(x, 42.0, -120.0))),
        ("both steps the same way", lambda x: (step(x, 40.0, 120.0), step(x, 40.7, 120.0))),
        ("another glance 1.7 s later", lambda x: (glance(x, 38.0, back=False), glance(x, 40.4, back=False))),
    ],
)
def test_near_misses_are_not_a_glance(name: str, make) -> None:  # type: ignore[no-untyped-def]
    x = quiet(50)
    make(x)
    assert [e for e in found(x) if e.kind == "glance"] == [], name


def test_eye_movements_reach_the_recogniser_in_the_second_that_first_knows_them() -> None:
    x = quiet(40)
    step(x, 35.0, 120.0)  # the move's sample is about 35 s; known 0.3 s later, inside second 35
    s = hf.inputs(x)
    have = [(sec.k, m.i) for sec in s for m in sec.moves]
    assert len(have) == 1
    k, i = have[0]
    assert k == (i + 75) // FS


def test_the_input_is_checked() -> None:
    with pytest.raises(ValueError, match="ten ticks"):
        hf.Gestures().second(hf.Second(0, (0.0,) * 9, (0.0,) * 10, (False,) * 10, 1.0, 1.0, False, ()))


# ---- calibration ----

CUES = (40, 50, 60)  # clench twice now
LOOKS = (70, 80, 90)  # look left, then right


def calibration_run(clench_uv: tuple[float, float, float] = (40.0, 25.0, 30.0),
                    glance_uv: tuple[float, float, float] = (110.0, 130.0, 150.0), seed: int = 3) -> np.ndarray:
    x = quiet(100, seed=seed)
    for at, uv in zip(CUES, clench_uv, strict=True):
        double_clench(x, at + 0.8, uv=uv)
    for at, uv in zip(LOOKS, glance_uv, strict=True):
        glance(x, at + 0.6, uv=uv)
    return x


def tries() -> list[hf.Try]:
    return [hf.Try("clench", c, c + 5) for c in CUES] + [hf.Try("glance", c, c + 5) for c in LOOKS]


def test_calibration_sets_the_levels_from_the_weakest_try_and_sees_all_six() -> None:
    cal = hf.calibrate(hf.inputs(calibration_run()), tries())
    clench_levels = [r.level for r in cal.tries if r.kind == "clench"]
    assert all(v is not None for v in clench_levels)
    weakest = min(v for v in clench_levels if v is not None)
    assert cal.settings.clench_x == pytest.approx(min(max(hf.CAL_SHARE_CLENCH * weakest, 10.0), 60.0))
    sizes = [r.level for r in cal.tries if r.kind == "glance"]
    assert cal.settings.glance_uv == pytest.approx(max(hf.CAL_SHARE_GLANCE * min(v for v in sizes if v is not None), 70.0))
    assert cal.settings.left_sign == 1 and cal.left_known
    assert [r.why for r in cal.tries] == ["ok"] * 6
    assert (cal.clench_seen, cal.glance_seen, cal.others) == (3, 3, 0)
    assert cal.settings.clench_on and cal.settings.glance_on


def test_calibration_says_why_a_try_was_missed_and_needs_two_of_three() -> None:
    x = quiet(100, seed=4)
    double_clench(x, 40.8)
    clench(x, 50.8, 0.5)  # only one clench
    double_clench(x, 60.8, pause=2.5)  # too far apart: two clusters, the first a single clench
    for at in LOOKS:
        glance(x, at + 0.6)
    cal = hf.calibrate(hf.inputs(x), tries())
    assert [r.why for r in cal.tries if r.kind == "clench"] == ["ok", "one", "one"]
    assert cal.clench_seen == 1 and not cal.settings.clench_on
    assert cal.glance_seen == 3 and cal.settings.glance_on


def test_calibration_with_mixed_directions_leaves_left_unknown() -> None:
    x = quiet(100, seed=5)
    for at in CUES:
        double_clench(x, at + 0.8)
    glance(x, 70.6)
    step(x, 80.6, -120.0)  # the other way first
    step(x, 81.3, 240.0)
    step(x, 82.0, -120.0)
    glance(x, 90.6)
    cal = hf.calibrate(hf.inputs(x), tries())
    assert cal.settings.left_sign == 0 and not cal.left_known
    assert cal.glance_seen == 3  # either way counts while left is unknown
