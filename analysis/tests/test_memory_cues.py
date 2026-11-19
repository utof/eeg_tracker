"""Tests for analysis/memory_cues.py: the memory cue rule's hand-worked cases (shared with the Dart port through
app/test/fixtures/memory_cases.json). The owner's nights are replayed by `memory_cues.py replay` (laptop only; the
recordings stay in _local/).

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import memory_cues as mc

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "app/test/fixtures/memory_cases.json"


def cases() -> list[dict]:
    return json.loads(CASES.read_text())["cases"]


@pytest.mark.parametrize("case", cases(), ids=lambda c: c["name"])
def test_the_shared_cases(case: dict) -> None:
    got = mc.run_case(case)
    assert got["cues"] == case["expect"]["cues"]
    assert got["arousals"] == case["expect"]["arousals"]
    assert got["stops"] == case["expect"].get("stops", got["stops"])


def test_the_cases_cover_every_limit() -> None:
    names = " ".join(c["name"] for c in cases())
    for word in ("cue hours", "two in a row", "REM", "confidence", "awake epoch", "lost epoch", "3 minutes", "jaw",
                 "drift-off", "10 s apart", "arousal", "awake epoch", "three arousals", "120 a night", "stale",
                 "new stretch"):
        assert word in names, word


def test_the_level_is_under_the_evening_level_and_never_above() -> None:
    assert mc.gain(0) == 1.0
    assert mc.gain(mc.MARGIN_DB) == pytest.approx(10 ** (-3 / 20))
    assert mc.gain(-6) == 1.0
    assert mc.gain(9) < mc.gain(6) < mc.gain(3)


def test_the_cue_hours_end_before_the_lucid_cue_hours_begin() -> None:
    import lucid_cues as lc

    assert mc.CUES_UNTIL_S <= lc.CUES_FROM_H * 3600
    assert mc.CUES_FROM_S < mc.CUES_UNTIL_S


def test_minutes_to_the_nearest_awake_epoch_look_both_ways() -> None:
    offline = ["N2"] * 10 + ["W"] + ["N3"] * 10
    assert mc.wake_distance_min(offline, 4) == 3.0
    assert mc.wake_distance_min(offline, 14) == 2.0
    assert mc.wake_distance_min(["N2"] * 5, 2) == float("inf")
