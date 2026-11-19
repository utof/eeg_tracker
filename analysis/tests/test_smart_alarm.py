"""The smart alarm's rule (analysis/smart_alarm.py) on the hand-worked cases shared with the phone app
(app/test/fixtures/smart_alarm_cases.json, read by app/test/alarm_rule_test.dart too)."""
import json
from pathlib import Path

import pytest

import smart_alarm as sa

FIXTURE = json.loads((Path(__file__).resolve().parents[2] / "app/test/fixtures/smart_alarm_cases.json").read_text())
STAGE = {"W": "W", "1": "N1", "2": "N2", "3": "N3", "R": "R", "-": "gap"}


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=[c["name"] for c in FIXTURE["cases"]])
def test_the_shared_cases(case):
    stages = [STAGE[c] for c in case["stages"]]
    handed = sa.handed_s(len(stages), FIXTURE["behind"], FIXTURE["min_epochs"])
    ep, why, at = sa.wake(stages, handed, tuple(case["window"]))
    want = case["expect"]
    assert (ep, why, at) == (want["epoch"], want["why"], want["at_s"])


def test_hand_out_times_follow_the_first_call_then_one_epoch_behind():
    assert sa.handed_s(12) == [300] * 6 + [330, 360, 390, 420, 450, 480]


def test_never_scored_epochs_count_as_lost():
    stages = [None] * 20 + ["N2"] * 20
    assert sa.wake(stages, sa.handed_s(40), (0, 2000)) == (20, "light", 750)


def test_summary_compares_with_a_plain_alarm_only_for_windows_ending_asleep():
    rows = [dict(offline_at_end="N3", offline_at_wake="N2", why="light", min_before_end=12.0),
            dict(offline_at_end="N3", offline_at_wake="N3", why="window end", min_before_end=0.0),
            dict(offline_at_end="W", offline_at_wake="W", why="awake", min_before_end=30.0)]
    s = sa.summary(rows)
    assert (s["windows"], s["ending_asleep"], s["smart_wake_in_deep"], s["plain_alarm_in_deep"]) == (3, 2, 1, 2)
    assert s["median_min_early"] == 6.0
