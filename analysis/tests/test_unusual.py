"""Tests for analysis/unusual.py, the reference for the phone's "Unusual for you" card (DECISIONS rows 290-299):
the lagged usual, the two-day rule, the one bridged day, the directions, the silent start, the restart after a
break, "feeling ill", the headband streams kept apart, and the back-test's synthetic histories.

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

from collections.abc import Callable

import pytest

import unusual as un
import validate_unusual as vu

START = "2026-01-01"


def series(n: int, value: Callable[[int], float | None], start: str = START) -> dict[str, float]:
    """Day k (0 = start) -> value(k); None leaves the day out."""
    out: dict[str, float] = {}
    for k in range(n):
        v = value(k)
        if v is not None:
            out[un.add_days(start, k)] = float(v)
    return out


def wobble(base: float, step: float) -> Callable[[int], float]:
    """A steady value with a small regular wobble (spread step x 1.4826 / 2 or so)."""
    return lambda k: base + step * ((k % 3) - 1)


def day(k: int) -> str:
    return un.add_days(START, k)


def verdicts(s: dict[str, dict[str, float]], n: int, **kw) -> dict[str, un.DayVerdict]:
    return {v.day: v for v in un.judge(s, START, day(n - 1), **kw)}


# ---- the usual (the same maths as app/lib/trends/usual.dart) ----


def test_the_usual_is_the_median_and_the_spread_a_robust_sd() -> None:
    u = un.usual_of_values([400.0 + 5 * k for k in range(10)], un.SCALES["minutes"])
    assert u is not None
    assert u.median == 422.5
    assert u.spread == pytest.approx(1.4826 * 12.5)
    # the band: 2 spreads or the hour that counts, whichever is larger
    assert u.half == 60
    assert un.usual_of_values([1.0] * 6, un.SCALES["minutes"]) is None


def test_log_measures_are_judged_on_a_log_scale() -> None:
    u = un.usual_of_values([10.0, 20.0, 40.0] * 5, un.SCALES["log"])
    assert u is not None
    assert u.median == pytest.approx(20.0)
    # the spread is 1.4826 x ln 2 on the log scale: 2 spreads are a factor of about 7.8 either way
    assert un.arrow(u, 20.0 * 7.5, un.SCALES["log"]) == "none"
    assert un.arrow(u, 20.0 * 8, un.SCALES["log"]) == "up"
    assert un.arrow(u, 20.0 / 8, un.SCALES["log"]) == "down"
    assert un.arrow(u, 0.0, un.SCALES["log"]) == "none"


# ---- the lagged baseline ----


def test_the_baseline_ends_a_week_before_the_day_and_needs_14_days() -> None:
    s = {"asleep": series(40, wobble(420, 10))}
    v = verdicts(s, 40)
    # day 20: days 0-13 are at least 7 days back: 14 values, judged
    assert v[day(20)].streams["asleep"].n == 14
    assert v[day(20)].streams["asleep"].state == "in"
    assert v[day(19)].streams["asleep"].n == 13
    assert v[day(19)].streams["asleep"].state == "unjudged"
    # at most the last 28 values
    assert v[day(39)].streams["asleep"].n == 28


def test_the_last_week_never_moves_the_baseline() -> None:
    base = series(40, wobble(420, 10))
    for k in range(34, 40):
        base[day(k)] = 200.0  # six very short nights just before day 40's baseline would see them
    v = verdicts({"asleep": base}, 40)
    assert v[day(39)].streams["asleep"].usual == 420.0


# ---- the two-day rule (NightSignal's red rule) ----


def short_nights(at: list[int], n: int = 45, minutes: float = 300) -> dict[str, dict[str, float]]:
    s = series(n, wobble(420, 10))
    for k in at:
        s[day(k)] = minutes
    return {"asleep": s}


def test_one_short_night_is_not_a_card_two_in_a_row_are() -> None:
    v = verdicts(short_nights([35, 36]), 45)
    assert v[day(35)].streams["asleep"].state == "down"
    assert v[day(35)].streams["asleep"].run == 1
    assert not v[day(35)].rule_core
    assert v[day(36)].streams["asleep"].run == 2
    assert v[day(36)].rule_core
    assert v[day(36)].on_core == ["asleep"]
    assert v[day(36)].active["asleep"] == (2, "down", day(35))


def test_one_missing_night_is_bridged_two_are_not() -> None:
    s = short_nights([35, 37])
    del s["asleep"][day(36)]
    v = verdicts(s, 45)
    assert v[day(36)].active["asleep"] == (1, "down", day(35))  # the run stays open through one missing day
    assert v[day(37)].streams["asleep"].run == 2
    assert v[day(37)].rule_core
    s = short_nights([35, 38])
    del s["asleep"][day(36)], s["asleep"][day(37)]
    v = verdicts(s, 45)
    assert v[day(37)].active.get("asleep") is None
    assert v[day(38)].streams["asleep"].run == 1
    assert not v[day(38)].rule_core


def test_a_card_stays_one_day_without_a_value_then_goes() -> None:
    s = short_nights([35, 36])
    del s["asleep"][day(37)], s["asleep"][day(38)]
    v = verdicts(s, 45)
    assert v[day(37)].rule_core
    assert not v[day(38)].rule_core


def test_a_run_must_keep_its_direction() -> None:
    s = short_nights([35])
    s["asleep"][day(36)] = 560.0
    v = verdicts(s, 45)
    assert v[day(36)].streams["asleep"].state == "up"
    assert v[day(36)].streams["asleep"].run == 1
    assert not v[day(36)].rule_core


def test_directions_sleep_both_ways_mood_only_down_sleepiness_only_up() -> None:
    n = 45
    s = {
        "asleep": series(n, wobble(420, 10)),
        "mood": series(n, lambda k: 3.0),
        "kss": series(n, lambda k: 4.0),
    }
    for k in (35, 36):
        s["asleep"][day(k)] = 560.0  # 2 h 20 min longer
        s["mood"][day(k)] = 5.0  # better
        s["kss"][day(k)] = 2.0  # more alert
    v = verdicts(s, n)[day(36)]
    assert v.streams["mood"].state == "up" and not v.streams["mood"].off
    assert v.streams["kss"].state == "down" and not v.streams["kss"].off
    assert v.on_core == ["asleep"]


def test_ratings_need_two_points() -> None:
    n = 45
    s = {"mood": series(n, lambda k: 4.0)}
    s["mood"][day(35)] = s["mood"][day(36)] = 3.0
    assert not verdicts(s, n)[day(36)].rule_core
    s["mood"][day(35)] = s["mood"][day(36)] = 2.0
    assert verdicts(s, n)[day(36)].on_core == ["mood"]


def test_two_streams_rule_when_asked() -> None:
    n = 45
    s = short_nights([35, 36]) | {"kss": series(n, lambda k: 4.0)}
    one = verdicts(s, n)[day(36)]
    two = verdicts(s, n, settings=un.Settings(min_streams=2))[day(36)]
    assert one.rule_core and not two.rule_core
    s["kss"][day(35)] = s["kss"][day(36)] = 7.0
    two = verdicts(s, n, settings=un.Settings(min_streams=2))[day(36)]
    assert two.rule_core and two.on_core == ["asleep", "kss"]


# ---- the headband's streams are judged, logged, and kept out of the card ----


def test_headband_streams_count_only_in_the_with_headband_rule() -> None:
    n = 45
    s = {"asleep": series(n, wobble(420, 10)), "iaf": series(n, wobble(9.8, 0.05))}
    s["iaf"][day(35)] = s["iaf"][day(36)] = 10.6
    v = verdicts(s, n)[day(36)]
    assert v.streams["iaf"].state == "up"
    assert not v.rule_core and v.on_core == []
    assert v.rule_all and v.on_all == ["iaf"]


# ---- silent first, then on ----


def test_silent_for_the_first_28_days_with_a_number() -> None:
    n = 45
    s = short_nights([22, 23], n=n)
    v = verdicts(s, n)
    assert v[day(23)].rule_core
    assert v[day(23)].phase == "silent"
    assert v[day(27)].valid_before == 27 and v[day(27)].phase == "silent"
    assert v[day(28)].valid_before == 28 and v[day(28)].phase == "on"


def test_days_without_any_number_do_not_count_toward_the_28() -> None:
    s = {"asleep": series(60, lambda k: None if k % 2 else 420.0)}
    v = verdicts(s, 60)
    assert v[day(55)].valid_before == 28
    assert v[day(55)].phase == "on"
    assert v[day(54)].phase == "silent"


def test_headband_numbers_alone_do_not_count_as_a_day() -> None:
    s = {"iaf": series(40, lambda k: 9.8)}
    assert verdicts(s, 40)[day(39)].valid_before == 0


# ---- a long break restarts the usual ----


def test_more_than_14_days_without_numbers_restart_the_usual() -> None:
    s = {"asleep": series(40, wobble(420, 10)) | series(30, wobble(420, 10), start=un.add_days(START, 55))}
    v = verdicts(s, 85)
    assert v[day(55)].epoch_start == day(55)
    assert v[day(55)].streams["asleep"].state == "unjudged"
    assert v[day(39)].epoch_start == START
    # 14 missing days exactly do not restart it
    s = {"asleep": series(40, wobble(420, 10)) | series(30, wobble(420, 10), start=un.add_days(START, 54))}
    v = verdicts(s, 85)
    assert v[day(54)].epoch_start == START


# ---- feeling ill ----


def test_feeling_ill_pauses_for_two_weeks_and_keeps_those_days_out_of_the_usual() -> None:
    n = 80
    s = short_nights([40, 41, 42], n=n)
    ill = [un.Ill(start=day(41), tapped=day(42))]
    v = verdicts(s, n, ill=ill)
    assert v[day(40)].phase == "on"
    assert v[day(41)].phase == "paused" and v[day(55)].phase == "paused"
    assert v[day(56)].phase == "on"
    # the paused days are not in a later usual; the day before them is
    assert all(day(k) not in v[day(70)].baseline_days("asleep") for k in range(41, 56))
    assert day(40) in v[day(70)].baseline_days("asleep")


def test_resuming_ends_the_pause_early() -> None:
    n = 80
    s = short_nights([40, 41], n=n)
    v = verdicts(s, n, ill=[un.Ill(start=day(41), tapped=day(41), resumed=day(45))])
    assert v[day(44)].phase == "paused"
    assert v[day(45)].phase == "on"


# ---- episodes ----


def test_episodes_are_runs_of_days_with_the_rule() -> None:
    v = un.judge(short_nights([33, 34, 35, 40, 41]), START, day(44))
    # a night back in range ends a card at once
    assert un.episodes(v) == [(day(34), day(35)), (day(41), day(41))]
    early = un.judge(short_nights([24, 25, 40, 41]), START, day(44))
    assert un.episodes(early) == [(day(25), day(25)), (day(41), day(41))]
    assert un.episodes(early, shown_only=True) == [(day(41), day(41))]


# ---- the back-test's synthetic histories ----


def test_synthetic_histories_are_repeatable_and_on_their_scales() -> None:
    a = vu.synthetic_history(seed=3, days=120)
    b = vu.synthetic_history(seed=3, days=120)
    assert a == b
    assert set(a) == {s.id for s in un.STREAMS}
    assert all(1 <= v <= 9 and v == int(v) for v in a["kss"].values())
    assert all(1 <= v <= 5 and v == int(v) for v in a["mood"].values())
    assert 0.7 * 120 < len(a["asleep"]) < 120


def test_a_planted_change_shifts_only_its_days() -> None:
    plain = vu.synthetic_history(seed=5, days=120)
    planted = vu.synthetic_history(seed=5, days=120, change=vu.Change("short sleep", start=80, days=4, shifts={"asleep": -120}))
    for d, v in plain["asleep"].items():
        k = un.days_between(START, d)
        assert planted["asleep"][d] == pytest.approx(v - 120 if 80 <= k < 84 else v)
    assert planted["mood"] == plain["mood"]


def test_back_test_nightsignal_rule_stays_under_a_card_a_month_and_finds_planted_changes() -> None:
    r = vu.back_test(people=40, days=240, seed=11)
    assert r["stable"]["core"]["cards_per_month"] < 1.0
    # the headband's numbers add false cards (they are judged both ways and kept out of the card)
    assert r["stable"]["all"]["cards_per_month"] > r["stable"]["core"]["cards_per_month"]
    ch = r["changes"]
    assert ch["low mood (mood -2, tension +1.5; 7 days)"]["core"]["found"] >= 0.7
    assert ch["short sleep (2 h, 4 nights)"]["core"]["found"] >= 0.5
    # a change in the headband's numbers alone never reaches the card, but the with-headband rule sees it
    eeg = ch["headband only (alpha speed +0.5 Hz, alpha strength x1.6; 5 days)"]
    assert eeg["core"]["found"] == 0.0
    assert eeg["all"]["found"] >= 0.5
