"""Tests for analysis/night_extras.py: the sleep report's night extras (jaw, movement and signal quality per hour)
from the shared detectors' events and the night's stages. Hand-made inputs with counts worked out by hand.

Run: uv run --project analysis --with pytest pytest -q analysis/tests/test_night_extras.py
"""

from __future__ import annotations

from datetime import datetime

import numpy as np
import pytest

import eeg_detectors as det
import night_extras as nx

W, N1, N2, N3, R, GAP = "W", "N1", "N2", "N3", "R", "gap"


def test_first_edge_is_the_way_to_the_next_whole_clock_hour():
    assert nx.first_edge_s(datetime(2026, 11, 18, 1, 58, 25)) == 95
    assert nx.first_edge_s(datetime(2026, 11, 18, 2, 0, 0)) == 0
    assert nx.first_edge_s(datetime(2026, 11, 18, 23, 0, 1)) == 3599


def test_hours_follow_the_clock_and_count_events_by_the_epoch_they_start_in():
    # 2 epochs before the first whole hour (edge at 50 s: epochs starting at 0 and 30 s), then 120 epochs
    # (one hour), then 8 epochs; asleep from epoch 4 to 125, one period
    stages = [W] * 4 + [N2] * 60 + [N3] * 30 + [R] * 32 + [W] * 4
    quality = ["good"] * 130
    quality[0] = "missing"
    quality[5:9] = ["degraded"] * 4
    quality[124] = "degraded"
    bursts = [
        (10, 12, "jaw"),  # second 10: epoch 0, awake, hour 0
        (125, 125, "jaw"),  # epoch 4: asleep, hour 1
        (300, 301, "one-sided"),  # epoch 10, asleep
        (1800, 1805, "movement"),  # epoch 60, asleep
        (3700, 3702, "jaw"),  # epoch 123: asleep, hour 2 (from 3650 s)
        (3899, 3899, "jaw"),  # epoch 129: awake, hour 2
        (3900, 3901, "jaw"),  # epoch 130: past the scored epochs, dropped
    ]
    moves = [(29, 31), (600, 600), (3680, 3681), (3901, 3903)]  # epochs 0, 20, 122, 130 (dropped)
    out = nx.summary(quality, bursts, moves, stages, [(4, 125)], first_edge=50)
    assert out["quality"] == "m" + "g" * 4 + "dddd" + "g" * 115 + "d" + "g" * 5
    assert [(h["from_s"], h["min"]) for h in out["hours"]] == [(0, 1.0), (50, 60.0), (3650, 4.0)]
    h0, h1, h2 = out["hours"]
    assert (h0["asleep_min"], h0["good_min"], h0["degraded_min"], h0["missing_min"]) == (0.0, 0.5, 0.0, 0.5)
    assert (h0["jaw_bursts"], h0["moves"]) == (1, 1)
    assert (h1["asleep_min"], h1["good_min"], h1["degraded_min"], h1["missing_min"]) == (59.0, 58.0, 2.0, 0.0)
    assert (h1["jaw_bursts"], h1["one_sided_bursts"], h1["movement_bursts"], h1["moves"]) == (1, 1, 1, 1)
    assert (h2["asleep_min"], h2["jaw_bursts"], h2["moves"], h2["degraded_min"]) == (2.0, 2, 1, 0.5)
    night = out["night"]
    assert (night["min"], night["good_min"], night["degraded_min"], night["missing_min"]) == (65.0, 62.0, 2.5, 0.5)
    assert (night["jaw_bursts"], night["one_sided_bursts"], night["movement_bursts"], night["moves"]) == (4, 1, 1, 3)
    asleep = out["asleep"]
    assert (asleep["min"], asleep["good_min"], asleep["degraded_min"], asleep["missing_min"]) == (61.0, 58.5, 2.5, 0.0)
    assert (asleep["jaw_bursts"], asleep["one_sided_bursts"], asleep["movement_bursts"], asleep["moves"]) == (2, 1, 1, 2)
    assert (asleep["jaw_per_hour"], asleep["moves_per_hour"]) == (2.0, 2.0)  # 2 in 61 min: 1.967 -> 2.0
    assert out["validated"] is False and out["epoch_s"] == 30 and out["version"] == nx.VERSION


def test_asleep_means_inside_a_sleep_period_and_rates_round_half_up():
    # a stray 3-minute nap at the start is not a period, so its burst is not "asleep"
    stages = [N2] * 6 + [W] * 200 + [N2] * 480 + [W] * 10
    bursts = [(30, 31, "jaw"), (6200, 6201, "jaw")]  # epoch 1 (stray sleep), epoch 206 (in the period)
    out = nx.summary(["good"] * len(stages), bursts, [], stages, [(206, 685)], first_edge=0)
    asleep = out["asleep"]
    assert (asleep["min"], asleep["jaw_bursts"]) == (240.0, 1)
    assert asleep["jaw_per_hour"] == 0.3  # 1 in 4 h = 0.25: half up
    assert asleep["moves_per_hour"] == 0.0
    assert [h["from_s"] for h in out["hours"]] == [0, 3600, 7200, 10800, 14400, 18000]
    assert out["night"]["jaw_bursts"] == 2


def test_no_sleep_gives_no_rates():
    out = nx.summary(["good"] * 20, [(5, 6, "jaw")], [], [W] * 20, [], first_edge=0)
    assert out["asleep"]["min"] == 0.0 and out["asleep"]["jaw_per_hour"] is None
    assert out["asleep"]["moves_per_hour"] is None and out["night"]["jaw_bursts"] == 1


def test_stages_and_quality_must_cover_the_same_epochs():
    with pytest.raises(ValueError):
        nx.summary(["good"] * 9, [], [], [W] * 10, [], first_edge=0)


def test_see_marks_held_time_missing_and_clips_like_the_bdf():
    n = 40 * det.FS
    rng = np.random.default_rng(3)
    uv = rng.normal(0, 8, (n, 4)) + 80_000.0
    uv[: 3 * det.FS, 2] = 450_000.0  # T3 past the file's range for 3 s: clipped to 400 000 µV, railed
    notes = [(10.0, 6.0, "BAD_gap"), (12.5, -1, "overlap 1.0s"), (39.6, 0.4, "BAD_padding")]
    seen = nx.see(uv, notes)
    gap = seen.seconds.gap
    assert list(np.flatnonzero(gap)) == [10, 11, 12, 13, 14, 15, 39]
    assert list(np.flatnonzero(seen.seconds.railed[2])) == [0, 1, 2]
    assert seen.epochs[0].quality == "missing"  # 6 gap seconds, over 5


def test_see_in_place_sees_the_same_without_a_copy_of_the_night():
    """sleep_report.py clips the joined night itself (its BDF clips to the same range), so a 24-hour night does not
    hold a second copy while the detectors run (DECISIONS 312)."""
    n = 90 * det.FS
    rng = np.random.default_rng(5)
    uv = rng.normal(0, 30, (n, 4)) + 1000.0
    uv[200:900, 1] = -460_000.0
    notes = [(20.0, 7.0, "BAD_gap")]
    want = nx.see(uv.copy(), notes)
    got = nx.see(uv, notes, in_place=True)
    assert np.array_equal(uv, np.clip(uv, -nx.LIMIT_UV, nx.LIMIT_UV)) and uv[200, 1] == -nx.LIMIT_UV  # clipped in place
    assert got.epochs == want.epochs and got.blinks == want.blinks and got.eye_moves == want.eye_moves
    assert got.bursts == want.bursts and got.movement == want.movement
    for field in ("gap", "flat", "railed", "qrange", "alpha", "theta", "muscle", "sem"):
        assert np.array_equal(getattr(got.seconds, field), getattr(want.seconds, field)), field


def test_missing_mask_rounds_onsets_to_samples():
    m = nx.missing_mask(1000, [(123457 / 250 - 493, 0.004, "BAD_gap")])  # 0.828 s: sample 207, one sample long
    assert list(np.flatnonzero(m)) == [207]
