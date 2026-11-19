"""Tests for analysis/lucid_cues.py: the cue rule's hand-worked cases (shared with the Dart port through
app/test/fixtures/lucid_cases.json) and the eye bursts on synthetic signals. The owner's night is replayed by
`lucid_cues.py replay` (laptop only; the recordings stay in _local/).

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
from test_eeg_detectors import noise

import eeg_detectors as det
import lucid_cues as lc
from make_gesture_fixture import step

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "app/test/fixtures/lucid_cases.json"
FS = det.FS


def cases() -> list[dict]:
    return json.loads(CASES.read_text())["cases"]


@pytest.mark.parametrize("case", cases(), ids=lambda c: c["name"])
def test_the_shared_cases(case: dict) -> None:
    got = lc.run_case(case)
    assert got["cues"] == case["expect"]["cues"]
    assert got["arousals"] == case["expect"]["arousals"]
    assert got["stops"] == case["expect"].get("stops", got["stops"])


def test_the_cases_cover_every_limit() -> None:
    names = " ".join(c["name"] for c in cases())
    for word in ("second half", "two REM", "confidence", "deep", "eye", "still", "awake", "spacing", "per period",
                 "per night", "arousal", "ramp", "new period", "three arousals"):
        assert word in names, word


def test_the_level_is_whole_decibels_above_the_threshold_and_capped() -> None:
    assert lc.gain(0) == 1.0
    assert lc.gain(6) == pytest.approx(10 ** (6 / 20))
    assert lc.gain(99) == lc.gain(lc.MAX_STEPS)


def quiet(seconds: float, seed: int = 3) -> np.ndarray:
    n = int(seconds * FS)
    rng = np.random.default_rng(seed + 50)
    return noise(n, seed=seed) + rng.normal(0, 1.0, (4, n))


def test_two_eye_movements_with_a_quiet_back_make_a_burst() -> None:
    x = quiet(30)
    step(x, 10.0, 120.0)
    step(x, 11.0, -120.0)
    moves = det.eye_moves(x)
    assert len(moves) == 2
    kept = lc.quiet_back(x, moves)
    assert kept == [m.i for m in moves]
    assert lc.burst_seconds(kept) == [(kept[1] + lc.BACK_HALF) // FS]


def test_a_busy_back_of_the_head_spoils_the_burst() -> None:
    x = quiet(30)
    step(x, 10.0, 120.0)
    step(x, 11.0, -120.0)
    t = np.arange(x.shape[1]) / FS
    x[0] += 70 * np.sin(2 * np.pi * 1.0 * t)  # deep-sleep-sized slow waves on O1 and O2
    x[1] += 70 * np.sin(2 * np.pi * 1.0 * t)
    assert lc.quiet_back(x, det.eye_moves(x)) == []


def test_movements_too_far_apart_are_no_burst() -> None:
    assert lc.burst_seconds([1000, 1000 + 2 * FS + 1]) == []
    assert lc.burst_seconds([1000, 1000 + 2 * FS]) == [(1000 + 2 * FS + lc.BACK_HALF) // FS]
