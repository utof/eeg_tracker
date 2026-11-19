"""Tests for analysis/lucid_signals.py on synthetic signals: left-right-left-right eye signals it must find, the near
misses it must not, and double clenches with a calibrated line. The owner's recorded night (no signals made) is
counted by `lucid_signals.py night` (laptop only).

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

import numpy as np
from test_lucid_cues import quiet

import eeg_detectors as det
import lucid_signals as ls
from make_gesture_fixture import double_clench, step
from make_lucid_fixture import lrlr

FS = det.FS


def test_lrlr_from_the_middle_is_one_signal_of_two_pairs() -> None:
    x = quiet(40)
    lrlr(x, 20.0)
    s = ls.find(x)
    assert len(s) == 1
    assert s[0].sweeps == 3 and s[0].pairs == 2
    assert abs(s[0].start - 20.6 * FS) < 30 and abs(s[0].end - 21.8 * FS) < 30
    assert s[0].size > 200


def test_three_pairs_are_one_longer_signal() -> None:
    x = quiet(40)
    lrlr(x, 20.0, pairs=3)
    s = ls.find(x)
    assert [(e.sweeps, e.pairs) for e in s] == [(5, 3)]


def test_a_glance_out_across_and_back_is_not_a_signal() -> None:
    x = quiet(40)
    step(x, 20.0, 120.0)
    step(x, 20.6, -240.0)
    step(x, 21.2, 120.0)
    assert ls.find(x) == []


def test_an_uneven_pace_is_not_a_signal() -> None:
    x = quiet(40)
    for at, uv in ((20.0, 120.0), (20.6, -240.0), (20.9, 240.0), (22.2, -240.0), (22.8, 120.0)):
        step(x, at, uv)
    assert ls.find(x) == []


def test_uneven_sweeps_are_not_a_signal() -> None:
    x = quiet(40)
    for at, uv in ((20.0, 60.0), (20.6, -120.0), (21.2, 300.0), (21.8, -300.0), (22.4, 120.0)):
        step(x, at, uv)
    assert ls.find(x) == []


def test_small_steps_need_a_smaller_sweep_size() -> None:
    x = quiet(40)
    lrlr(x, 20.0, uv=30.0)  # steps across of 60 µV
    assert ls.find(x) == []
    assert len(ls.find(x, sweep=50.0)) == 1


def test_waves_at_the_back_of_the_head_do_not_hide_it() -> None:
    x = quiet(40)
    lrlr(x, 20.0)
    t = np.arange(x.shape[1]) / FS
    x[0] += 70 * np.sin(2 * np.pi * t)
    x[1] += 70 * np.sin(2 * np.pi * t)
    assert len(ls.find(x)) == 1


def test_two_signals_in_a_row_are_two() -> None:
    x = quiet(60)
    lrlr(x, 20.0)
    lrlr(x, 35.0)
    assert len(ls.find(x)) == 2


def test_runs_break_where_the_direction_does_not_change() -> None:
    m = [det.EyeMove(1000, 100.0), det.EyeMove(1150, -200.0), det.EyeMove(1300, -200.0), det.EyeMove(1450, 200.0)]
    assert [len(r) for r in ls.runs(m)] == [2, 2]


def test_a_double_clench_with_the_calibrated_line() -> None:
    x = quiet(60)
    double_clench(x, 40.0, uv=15.0)
    assert [g.kind for g in ls.clenches(x, None, 10.0)] == ["clench"]
    assert ls.clenches(x, None, 60.0) == []
