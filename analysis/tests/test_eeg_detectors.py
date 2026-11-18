"""Tests for analysis/eeg_detectors.py on synthetic signals (the owner's recordings stay in _local/;
analysis/validate_detectors.py runs the detectors on them).

Run: uv run --project analysis --with pytest pytest -q analysis/tests
"""

from __future__ import annotations

import math

import numpy as np
import pytest

import eeg_detectors as det

FS = det.FS
OFFSET_UV = np.array([85_000.0, 82_000.0, 78_000.0, 79_000.0])  # electrode offsets like the headband's


def noise(n: int, uv: float = 6.0, seed: int = 1) -> np.ndarray:
    """Four channels of 1/f noise around the headband's offsets."""
    rng = np.random.default_rng(seed)
    spec = rng.normal(size=(4, n // 2 + 1)) + 1j * rng.normal(size=(4, n // 2 + 1))
    f = np.fft.rfftfreq(n, 1 / FS)
    f[0] = f[1]
    x = np.fft.irfft(spec / np.sqrt(f), n, axis=1)
    return x / x.std(axis=1, keepdims=True) * uv + OFFSET_UV[:, None]


def dip(n: int, at_s: float, depth: float, width_s: float) -> np.ndarray:
    """A blink-shaped dip: fast fall, slower return."""
    t = np.arange(n) / FS - at_s
    rise, fall = width_s * 0.35, width_s * 0.65
    shape = np.where(t < 0, np.exp(-((t / rise) ** 2)), np.exp(-((t / fall) ** 2)))
    return -depth * shape


def sine(n: int, hz: float, uv: float) -> np.ndarray:
    return uv * np.sin(2 * np.pi * hz * np.arange(n) / FS)


# ---- filters and helpers ----


def test_band_pair_passes_its_centre_and_halves_power_at_its_edges() -> None:
    n = 20 * FS
    for lo, hi in (det.ALPHA_BAND, det.MUSCLE_BAND):
        chain = det.band_pair(lo, hi)
        centre = math.sqrt(lo * hi)
        y = det.run_chain(chain, sine(n, centre, 10.0))[-5 * FS :]
        assert np.mean(y**2) == pytest.approx(50.0, rel=0.03)
    y = det.run_chain(det.band_pair(*det.ALPHA_BAND), sine(n, 8.0, 10.0))[-5 * FS :]
    assert np.mean(y**2) == pytest.approx(25.0, rel=0.05)


def test_notches_remove_mains_from_the_muscle_band() -> None:
    n = 20 * FS
    y = det.run_chain(det.chains()["muscle"], sine(n, 50.0, 100.0) + sine(n, 100.0, 100.0))[-5 * FS :]
    assert np.mean(y**2) < 0.01 * 5000


def test_run_chain_starts_from_the_first_value() -> None:
    y = det.run_chain(det.chains()["quality"], np.full(500, 85_000.0))
    assert np.abs(y).max() == 0


def test_percentile_matches_numpy_linear() -> None:
    rng = np.random.default_rng(3)
    for n in (1, 2, 7, 120):
        v = rng.normal(size=n)
        for p in (0.0, 0.2, 0.5, 1.0):
            assert det.percentile(v, p) == pytest.approx(float(np.percentile(v, p * 100)), abs=1e-12)
    assert math.isnan(det.percentile([], 0.5))


def test_input_is_checked() -> None:
    with pytest.raises(ValueError, match=r"\(4, n\)"):
        det.seconds(np.zeros((3, 500)))
    x = noise(500)
    x[1, 10] = np.nan
    with pytest.raises(ValueError, match="NaN"):
        det.seconds(x)
    with pytest.raises(ValueError, match="one flag per sample"):
        det.seconds(noise(500), np.zeros(10, bool))


# ---- blinks and eye movements ----


def test_blinks_are_found_on_all_four_channels_and_cancel_in_t3_t4() -> None:
    n = 30 * FS
    x = noise(n)
    times = [3.0, 7.5, 12.2, 18.0, 25.4]
    for t in times:
        x += dip(n, t, 90.0, 0.15)[None, :]
    found = det.blinks(x)
    assert [round(b.i / FS, 1) for b in found] == pytest.approx(times, abs=0.15)
    assert all(70 < b.depth < 110 and abs(b.t34) < 15 for b in found)


def test_slow_or_one_sided_dips_are_not_blinks() -> None:
    n = 30 * FS
    x = noise(n)
    x += dip(n, 5.0, 90.0, 0.8)[None, :]  # a slow roll of the closed eyes
    x[:2] += dip(n, 12.0, 120.0, 0.15)[None, :]  # back channels only
    x[2] += dip(n, 20.0, 90.0, 0.15)  # T3 down, T4 up: an eye movement, not a blink
    x[3] -= dip(n, 20.0, 90.0, 0.15)
    x += dip(n, 26.0, 35.0, 0.15)[None, :]  # too shallow
    assert det.blinks(x) == []


def test_sideways_glances_show_as_steps_in_t3_minus_t4() -> None:
    n = 20 * FS
    x = noise(n)
    step = np.where(np.arange(n) >= 6 * FS, 35.0, 0.0) - np.where(np.arange(n) >= 13 * FS, 35.0, 0.0)
    x[2] += step
    x[3] -= step
    moves = det.eye_moves(x)
    assert [round(m.i / FS) for m in moves] == [6, 13]
    assert moves[0].step > det.EYE_MIN_UV and moves[1].step < -det.EYE_MIN_UV


def test_a_step_on_all_channels_or_one_channel_is_not_an_eye_movement() -> None:
    n = 20 * FS
    x = noise(n)
    x += np.where(np.arange(n) >= 6 * FS, 80.0, 0.0)[None, :]
    x[3] += np.where(np.arange(n) >= 13 * FS, 80.0, 0.0)
    assert det.eye_moves(x) == []


# ---- muscle, movement, quality ----


def muscle_noise(n: int, start_s: float, end_s: float, uv: float, seed: int = 5) -> np.ndarray:
    rng = np.random.default_rng(seed)
    y = det.run_chain(det.band_pair(60.0, 110.0), rng.normal(size=n) * uv)
    t = np.arange(n) / FS
    return np.where((t >= start_s) & (t < end_s), y, 0.0)


def test_a_clench_on_both_sides_is_a_jaw_burst() -> None:
    n = 80 * FS
    x = noise(n)
    for c in det.SIDE:
        x[c] += muscle_noise(n, 50.0, 53.0, 40.0, seed=c)
    b = det.bursts(det.seconds(x))
    assert [(r.start, r.end, r.kind) for r in b] == [(50, 52, "jaw")]
    assert b[0].peak_x > 10


def test_muscle_on_one_side_or_with_movement_is_not_a_jaw_burst() -> None:
    n = 120 * FS
    x = noise(n)
    x[3] += muscle_noise(n, 50.0, 53.0, 40.0)
    for c in range(4):
        x[c] += muscle_noise(n, 90.0, 92.0, 40.0, seed=10 + c)
        x[c] += np.where((np.arange(n) >= 90.5 * FS) & (np.arange(n) < 91 * FS), 600.0, 0.0)
    kinds = [(r.start, r.kind) for r in det.bursts(det.seconds(x))]
    assert kinds[0] == (50, "one-sided")
    assert (90, "movement") in kinds or (89, "movement") in kinds
    assert all(k != "jaw" for _, k in kinds)


def test_no_burst_before_the_baseline_exists_or_from_mains_hum() -> None:
    n = 80 * FS
    x = noise(n)
    for c in det.SIDE:
        x[c] += muscle_noise(n, 10.0, 12.0, 40.0, seed=c)  # under 30 s of history: no baseline yet
        x[c] += sine(n, 50.0, 30.0) * (np.arange(n) > 60 * FS)  # mains hum switching on
    assert det.bursts(det.seconds(x)) == []


def test_epoch_quality_good_degraded_missing() -> None:
    n = 4 * det.EPOCH_S * FS
    x = noise(n)
    miss = np.zeros(n, bool)
    x[0, 30 * FS : 60 * FS] = x[0, 30 * FS]  # epoch 1: O1 flat
    miss[60 * FS : 70 * FS] = True  # epoch 2: 10 s missing
    for k in range(5):  # epoch 3: five movements
        x[:, (95 + 4 * k) * FS : (95 + 4 * k) * FS + 50] += 220.0  # over 200 µV, under the 500 µV "extreme"
    ep = det.epoch_quality(det.seconds(x, miss))
    assert [e.quality for e in ep] == ["good", "degraded", "missing", "degraded"]
    assert ep[1].usable == (False, True, True, True)
    assert ep[2].gap_s == 10
    assert ep[3].movement_s >= 3


def test_railed_channel_is_unusable() -> None:
    n = det.EPOCH_S * FS
    x = noise(n)
    x[3] = 400_000.0
    ep = det.epoch_quality(det.seconds(x))
    assert ep[0].usable == (True, True, True, False) and ep[0].quality == "degraded"


def test_detectors_are_causal() -> None:
    """Cutting the end changes nothing earlier: the phone port can run sample by sample."""
    n = 90 * FS
    x = noise(n)
    for t in (10.0, 40.0, 70.0):
        x += dip(n, t, 90.0, 0.15)[None, :]
    for c in det.SIDE:
        x[c] += muscle_noise(n, 55.0, 57.0, 40.0, seed=c)
    full, cut = det.detect(x), det.detect(x[:, : 60 * FS])
    assert [b for b in full.blinks if b.i < 60 * FS - 80] == cut.blinks
    assert np.array_equal(full.seconds.alpha[:, :60], cut.seconds.alpha)
    assert np.array_equal(full.seconds.muscle[:, :60], cut.seconds.muscle)
    assert full.epochs[:2] == cut.epochs


# ---- drift-off ----


def feed(alpha: list[float], blinks: dict[int, int] | None = None, unclean: set[int] | None = None,
         moving: set[int] | None = None) -> det.Drift:
    d = det.DriftOff(0)
    for k, a in enumerate(alpha):
        d.second(k, a, k not in (unclean or set()), k in (moving or set()), 1.0, (blinks or {}).get(k, 0))
    return d.result


def test_drift_off_baseline_then_faded_alpha_means_asleep_after_3_minutes() -> None:
    alpha = [20.0] * 60 + [15.0] * 300 + [5.0] * 600  # lights off, awake 5 min, then alpha fades at 360 s
    r = feed(alpha)
    assert r.baseline_alpha == 20.0 and r.baseline_done == 59
    assert r.drowsy_at == 360 + 2 * 30 - 1
    assert r.onset == 360 and r.asleep_at == 360 + 6 * 30 - 1
    assert [e.state for e in r.epochs][12:19] == ["awake", "drowsy", "drowsy", "drowsy", "drowsy", "asleep", "asleep"]


def test_drift_off_open_eyes_movement_and_alpha_bursts_break_the_run() -> None:
    base = [20.0] * 60 + [15.0] * 60
    faded = [5.0] * 240
    blink_epoch = {120 + 30 * 3 + 5: 1, 120 + 30 * 3 + 20: 1}  # 2 blinks in the 4th faded epoch: eyes open
    r = feed(base + faded, blinks=blink_epoch)
    assert r.onset is None and r.drowsy_at is not None
    move = {120 + 30 * 2 + k for k in range(3)}
    assert feed(base + faded, moving=move).onset is None
    burst = base + [5.0] * 90 + [20.0] * 30 + [5.0] * 120
    assert feed(burst).onset is None


def test_drift_off_skips_epochs_without_enough_clean_signal() -> None:
    alpha = [20.0] * 60 + [5.0] * 240
    unclean = set(range(60 + 60, 60 + 90))  # the 3rd faded epoch is all bad contact
    r = feed(alpha, unclean=unclean)
    assert r.epochs[4].faded is None
    assert r.onset == 60 and r.asleep_at == 60 + 7 * 30 - 1  # one epoch later, the run not broken


def test_drift_off_wakes_after_a_minute_of_alpha_and_finds_the_next_onset() -> None:
    alpha = [20.0] * 60 + [5.0] * 240 + [20.0] * 60 + [5.0] * 210
    r = feed(alpha)
    assert r.onsets[0][0] == 60 and r.wakes == [60 + 240 + 59]
    assert r.onsets[1][0] == 360 and len(r.onsets) == 2


def test_timers_fall_back_to_the_cap_and_the_usual_onset_window() -> None:
    nothing = feed([20.0] * 3000)
    t = det.timers(nothing, [], 0.0)
    assert t.sound_off_at == det.SOUND_CAP_S and t.dream_cue_at == 10 * 60
    assert det.timers(nothing, [8.0, 12.0, 14.0, 30.0], 1.0).dream_cue_at == round(det.percentile([8, 12, 14, 30], 0.75) * 60)
    asleep = feed([20.0] * 60 + [5.0] * 300)
    t = det.timers(asleep, [], 0.5)
    assert t.sound_fade_from == asleep.asleep_at + 1 and t.sound_off_at == t.sound_fade_from + det.SOUND_FADE_S
    assert t.dream_cue_at == asleep.drowsy_at + 1
    with pytest.raises(ValueError):
        det.timers(asleep, [], 1.5)


def test_drift_off_end_to_end_on_a_signal_whose_alpha_fades() -> None:
    n = 9 * 60 * FS
    x = noise(n, uv=3.0)
    t = np.arange(n) / FS
    amp = np.where(t < 4 * 60, 12.0, 2.0)  # eyes-closed alpha, then it fades at 4 min
    for b in det.BACK:
        x[b] += amp * np.sin(2 * np.pi * 10 * t)
    r = det.drift_off(det.seconds(x), 0)
    assert r.onset == 240 and r.asleep_at == 240 + 179
