"""Tests for analysis/wearer_check.py, the reference for the phone's "Was this you?" check (DECISIONS rows 370-379):
the signal from a check-in and from the first minutes after Lights off, the distance to your profile, the learning
phase, which recordings join the profile, and the two kinds kept apart.

Run: uv run --project analysis --with pytest pytest -q analysis/tests/test_wearer_check.py
"""

from __future__ import annotations

import math

import numpy as np
import pytest

import wearer_check as wc

FS = wc.FS


def morning(clean_o1: float = 110.0, clean_o2: float = 112.0, iaf: float | None = 9.8, alpha: float = 30.0,
            slope: float = -1.5) -> dict:
    ch = {"clean_s_ec": clean_o1}
    return {"channels": {"O1": ch, "O2": {"clean_s_ec": clean_o2}},
            "back": {"iaf_hz": iaf, "alpha_ec_uv2": alpha, "aperiodic_slope_ec": slope}}


# ---- the signal of one recording ----


def test_a_check_in_gives_alpha_speed_strength_on_a_log_scale_and_slope() -> None:
    s, why = wc.checkin_signal(morning())
    assert why is None
    assert s == {"iaf": 9.8, "alpha": pytest.approx(math.log10(30.0)), "slope": -1.5}


def test_a_check_in_needs_a_minute_of_clean_eyes_closed_signal_on_both_back_channels() -> None:
    assert wc.checkin_signal(morning(clean_o2=58.0)) == (None, wc.WHY_CLEAN)
    assert wc.checkin_signal(morning(iaf=None)) == (None, wc.WHY_PEAK)
    assert wc.checkin_signal({"back": {}}) == (None, wc.WHY_CLEAN)


def alpha_noise(seconds: float, hz: float, amp: float, seed: int) -> np.ndarray:
    """A rhythm at hz (µV amplitude amp) over brown-ish noise: a made-up eyes-closed back channel."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * FS)) / FS
    walk = np.cumsum(rng.normal(0, 1.0, t.size))
    walk -= np.convolve(walk, np.ones(FS) / FS, mode="same")  # keep it near zero
    return amp * np.sin(2 * np.pi * hz * t + rng.uniform(0, 6)) + 2.0 * walk + rng.normal(0, 2.0, t.size)


def test_the_night_signal_uses_only_awake_epochs_of_the_ten_minutes_after_lights_off() -> None:
    lights = 60  # seconds from the night's first sample, on an epoch edge
    n = (lights + 900) * FS
    o1, o2 = np.zeros(n), np.zeros(n)
    stages = ["W"] * 2 + ["W"] * 8 + ["N1"] * 4 + ["N2"] * 18
    # awake epochs carry a 10 Hz rhythm, the light-sleep ones a 6 Hz one, the first two minutes (before lights off)
    # an 8 Hz one: only 10 Hz may come through
    for e, st in enumerate(stages):
        hz = 8.0 if e < 2 else (10.0 if st == "W" else 6.0)
        a, b = e * 30 * FS, (e + 1) * 30 * FS
        if b > n:
            break
        o1[a:b] = alpha_noise(30, hz, 20.0, e)
        o2[a:b] = alpha_noise(30, hz, 18.0, 100 + e)
    s, info = wc.night_signal(o1, o2, stages, lights, missing=None)
    assert info["why"] is None
    assert info["epochs"] == 8
    assert info["clean_s"] >= 120
    assert s is not None and s["iaf"] == pytest.approx(10.0, abs=0.3)


def test_a_night_epoch_with_a_missing_sample_is_left_out_and_too_little_signal_says_so() -> None:
    lights = 0
    n = 600 * FS
    o1 = alpha_noise(600, 10.0, 20.0, 1)
    o2 = alpha_noise(600, 10.0, 20.0, 2)
    stages = ["W"] * 1 + ["N2"] * 19
    missing = np.zeros(n, bool)
    s, info = wc.night_signal(o1, o2, stages, lights, missing=missing)
    assert s is None and info["why"] == wc.WHY_CLEAN and info["epochs"] == 1
    stages = ["W"] * 4 + ["N2"] * 16
    missing[45 * FS] = True  # one filled-in sample in epoch 1
    s, info = wc.night_signal(o1, o2, stages, lights, missing=missing)
    assert info["epochs"] == 3 and info["why"] is None
    assert s is not None and wc.MIN_CLEAN_S <= info["clean_s"] <= 90


def test_no_lights_off_means_no_night_check() -> None:
    o = alpha_noise(700, 10.0, 20.0, 3)
    s, info = wc.night_signal(o, o, ["W"] * 23, None, missing=None)
    assert s is None and info["why"] == wc.WHY_LIGHTS


# ---- the distance ----


def test_the_distance_is_the_root_mean_square_of_three_z_scores_with_a_floor_under_each_spread() -> None:
    prof = [{"iaf": 10.0, "alpha": 1.5, "slope": -1.5}] * 8
    # identical profile: every spread is its floor, widened for a mean of 8
    k = math.sqrt(1 + 1 / 8)
    d, z = wc.distance(prof, {"iaf": 10.0 + wc.FLOORS["iaf"] * k * 3, "alpha": 1.5, "slope": -1.5})
    assert z["iaf"] == pytest.approx(3.0)
    assert z["alpha"] == 0 and z["slope"] == 0
    assert d == pytest.approx(math.sqrt(9 / 3))


def test_the_spread_combines_the_profile_sd_and_the_floor() -> None:
    prof = [{"iaf": v, "alpha": 1.5, "slope": -1.5} for v in (9.0, 10.0, 11.0)]
    sd = 1.0  # sample SD of 9, 10, 11
    scale = math.sqrt(sd**2 + wc.FLOORS["iaf"] ** 2) * math.sqrt(1 + 1 / 3)
    _, z = wc.distance(prof, {"iaf": 12.0, "alpha": 1.5, "slope": -1.5})
    assert z["iaf"] == pytest.approx(2.0 / scale)


# ---- judging a history ----


def rec(i: int, kind: str = "check-in", day: int | None = None, iaf: float = 10.0, answer: str | None = None,
        signal: bool = True) -> wc.Recording:
    d = i if day is None else day
    return wc.Recording(
        id=f"{kind}-{i:03d}", kind=kind, time=f"2026-12-{1 + d:02d}T08:{i % 60:02d}:00+03:00",
        day=f"2026-12-{1 + d:02d}", signal={"iaf": iaf + 0.1 * (i % 3 - 1), "alpha": 1.5, "slope": -1.5} if signal else None,
        why=None if signal else wc.WHY_CLEAN, answer=answer)


N = wc.N_ENROL


def test_the_planning_values() -> None:
    assert (wc.N_ENROL, wc.MIN_DAYS, wc.PROFILE_MAX, wc.THRESHOLD) == (10, 5, 20, 2.5)


def test_silent_while_learning_then_speaks_after_ten_recordings_on_five_days() -> None:
    rs = [rec(i, day=i // 3) for i in range(14)]  # 3 a day: 10 accepted after day 3, the 5th day after 12
    v = wc.judge(rs)
    assert [x.state for x in v[:13]] == ["learning"] * 13
    assert v[10].have == 10 and v[10].days == 4
    assert v[12].have == 12 and v[12].days == 4
    assert v[13].state == "like you" and v[13].have == 13 and v[13].days == 5


def test_a_recording_far_from_the_profile_does_not_look_like_you_and_stays_out_unless_you_say_it_was_you() -> None:
    rs = [rec(i) for i in range(N)] + [rec(N, iaf=8.0), rec(N + 1)]
    v = wc.judge(rs)
    assert v[N].state == "not like you" and v[N].distance > wc.THRESHOLD
    assert v[N + 1].profile_n == N  # the flagged one did not join
    rs[N] = rec(N, iaf=8.0, answer="me")
    v = wc.judge(rs)
    assert v[N].state == "not like you" and v[N + 1].profile_n == N + 1


def test_someone_else_never_joins_the_profile_even_while_learning() -> None:
    rs = [rec(i, answer="someone else" if i == 2 else None) for i in range(N + 2)]
    v = wc.judge(rs)
    assert v[2].state == "learning"
    assert v[N].state == "learning" and v[N].have == N - 1  # one of those before it left out
    assert v[N + 1].state == "like you" and v[N + 1].have == N


def test_unchecked_recordings_say_why_and_do_not_count() -> None:
    rs = [rec(i) for i in range(N)] + [rec(50, day=3, signal=False)]
    v = {x.id: x for x in wc.judge(rs)}
    assert v["check-in-050"].state == "unchecked" and v["check-in-050"].why == wc.WHY_CLEAN
    assert v["check-in-050"].have == 4
    assert v[f"check-in-{N - 1:03d}"].have == N - 1


def test_nights_and_check_ins_learn_separately() -> None:
    rs = [rec(i) for i in range(N)] + [rec(i, kind="night") for i in range(3)] + [rec(N + 1)]
    v = {x.id: x for x in wc.judge(rs)}
    assert v[f"check-in-{N + 1:03d}"].state == "like you"
    assert v["night-002"].state == "learning" and v["night-002"].have == 2


def test_the_profile_is_the_newest_twenty_accepted() -> None:
    # a lasting change (a new headband, a new medicine): flagged until "it was me" answers bring it into the profile
    rs = [rec(i, iaf=12.0 if i < 10 else 10.0, answer=None if i < 10 else "me") for i in range(31)]
    v = wc.judge(rs)
    assert v[10].state == "not like you"
    assert v[30].profile_n == wc.PROFILE_MAX
    assert v[30].usual["iaf"] == pytest.approx(10.0, abs=0.05)  # the old 12 Hz ones have aged out
    assert v[30].state == "like you"


def test_judge_orders_by_time() -> None:
    rs = [rec(i) for i in range(10)]
    assert [x.id for x in wc.judge(list(reversed(rs)))] == [r.id for r in rs]


def test_the_largest_difference_is_named() -> None:
    rs = [rec(i) for i in range(N)] + [rec(N, iaf=8.0)]
    v = wc.judge(rs)[N]
    assert v.biggest == "iaf"
    assert v.usual["iaf"] == pytest.approx(10.0, abs=0.05)
