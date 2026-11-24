"""Eating (chewing) from the temple channels' muscle band (analysis/eating.py), on made-up signals only."""
import math

import numpy as np

import eating as eat

FOUR = ["O1", "O2", "T3", "T4"]


def chew_envelope(n: int, fs: int, rate_hz: float) -> np.ndarray:
    """Bursts at the chewing rate: on for 40 % of every cycle, smooth edges."""
    phase = (np.arange(n) / fs * rate_hz) % 1.0
    return np.clip(np.sin(2 * math.pi * (phase - 0.05)) * 2.0, 0.0, 1.0)


def talk_envelope(n: int, fs: int, rng: np.random.Generator) -> np.ndarray:
    """Uneven bursts: each 0.15-1.2 s long, 0.2-3 s apart."""
    e = np.zeros(n)
    i = 0
    while i < n:
        i += int(rng.uniform(0.2, 3.0) * fs)
        length = int(rng.uniform(0.15, 1.2) * fs)
        e[i:i + length] = rng.uniform(0.5, 1.0)
    return e


def recording(names: list[str], fs: int, seconds: int, seed: int = 1) -> tuple[np.ndarray, np.random.Generator]:
    """Every channel: 4 µV of noise on a slow 20 µV drift and a 100 µV offset."""
    rng = np.random.default_rng(seed)
    n = seconds * fs
    t = np.arange(n) / fs
    x = rng.normal(0.0, 4.0, (len(names), n)) + 100.0 + 20.0 * np.sin(2 * math.pi * 0.05 * t)
    return x, rng


def add_jaw(x: np.ndarray, names: list[str], fs: int, a: int, b: int, env: np.ndarray,
            rng: np.random.Generator, uv: float = 40.0) -> None:
    """Jaw muscle from second a to b: noise shaped by `env` at the temples (a fifth of it elsewhere, as through a
    shared reference), and the skin under the temples moving with it."""
    s = slice(a * fs, b * fs)
    for c, name in enumerate(names):
        share = 1.0 if eat.is_temple(name) else 0.2
        x[c, s] += share * (uv * rng.normal(0.0, 1.0, len(env)) * env + 300.0 * env)


def found_of(x: np.ndarray, fs: int, names: list[str], missing: np.ndarray | None = None) -> eat.Found:
    return eat.detect(x, fs, names, missing)


# ---- the method ---------------------------------------------------------------------------------------------------

def test_minutes_of_chewing_are_one_meal_with_its_rate() -> None:
    fs = 250
    x, rng = recording(FOUR, fs, 420)
    add_jaw(x, FOUR, fs, 120, 300, chew_envelope(180 * fs, fs, 1.6), rng)
    found = found_of(x, fs, FOUR)
    (meal,) = found.meals
    ws = found.windows
    assert abs(meal.start_s(ws) - 120) <= 15 and abs(meal.end_s(ws) - 300) <= 15
    assert meal.rate is not None and abs(meal.rate - 96) <= 3  # 1.6 Hz = 96 chews a minute
    assert meal.confidence == "sure" and found.not_read is None and not found.no_back
    flags = eat.epochs(found, 14)
    assert flags[:3] == [False] * 3 and flags[5:9] == [True] * 4 and flags[11:] == [False] * 3
    quiet = [w for w in ws if w.t < 100]
    assert all(w.read and not w.chews for w in quiet)


def test_chewing_with_pauses_between_bites_is_one_meal() -> None:
    fs = 250
    x, rng = recording(FOUR, fs, 480)
    for a in (60, 150, 260):  # three 50 s runs, 40 s and 60 s apart
        add_jaw(x, FOUR, fs, a, a + 50, chew_envelope(50 * fs, fs, 1.3), rng)
    (meal,) = found_of(x, fs, FOUR).meals
    assert meal.chew_s >= 120 and meal.confidence in ("likely", "sure")


def test_a_short_chew_is_no_meal() -> None:
    fs = 250
    x, rng = recording(FOUR, fs, 240)
    add_jaw(x, FOUR, fs, 100, 130, chew_envelope(30 * fs, fs, 1.6), rng)
    assert found_of(x, fs, FOUR).meals == []


def test_quiet_talking_and_a_steady_clench_are_no_meal() -> None:
    fs = 250
    x, _ = recording(FOUR, fs, 300)
    quiet = found_of(x, fs, FOUR)
    assert quiet.meals == [] and not any(quiet.smoothed) and all(w.read for w in quiet.windows)

    x, rng = recording(FOUR, fs, 600, seed=2)
    add_jaw(x, FOUR, fs, 60, 540, talk_envelope(480 * fs, fs, rng), rng)
    talk = found_of(x, fs, FOUR)
    busy = [w for w in talk.windows if 70 < w.t < 530]
    assert talk.meals == [] and sum(w.level >= eat.MIN_LEVEL_UV for w in busy) > len(busy) * 0.8

    x, rng = recording(FOUR, fs, 300, seed=3)
    add_jaw(x, FOUR, fs, 60, 240, np.ones(180 * fs), rng)
    clench = found_of(x, fs, FOUR)
    held = [w for w in clench.windows if 70 < w.t < 230]
    assert clench.meals == [] and all(w.level >= eat.MIN_LEVEL_UV and w.depth < eat.MIN_DEPTH for w in held)


def test_a_walking_shake_on_every_channel_is_no_meal() -> None:
    fs = 250
    x, rng = recording(FOUR, fs, 360, seed=4)
    n = 240 * fs
    step = chew_envelope(n, fs, 1.9)  # a bump 1.9 times a second, the same on every electrode
    for c in range(4):
        x[c, 60 * fs:300 * fs] += 30.0 * rng.normal(0.0, 1.0, n) * step + 400.0 * step
    found = found_of(x, fs, FOUR)
    shaken = [w for w in found.windows if 70 < w.t < 290]
    assert found.meals == []
    assert all(w.score >= eat.MIN_RHYTHM and w.jaw_ratio is not None and w.jaw_ratio < eat.MIN_JAW_RATIO
               for w in shaken)  # the rhythm is there; the temples do not move more than the back


def test_a_hole_is_not_read() -> None:
    fs = 250
    x, rng = recording(FOUR, fs, 420)
    add_jaw(x, FOUR, fs, 60, 360, chew_envelope(300 * fs, fs, 1.6), rng)
    missing = np.zeros(x.shape[1], dtype=bool)
    missing[200 * fs:260 * fs] = True
    x[:, 200 * fs:260 * fs] = x[:, [200 * fs - 1]]  # held values, as the files' gaps are
    found = found_of(x, fs, FOUR, missing)
    holes = [w for w in found.windows if not w.read]
    assert holes and all(190 < w.t < 270 and not w.chews and math.isnan(w.level) for w in holes)
    assert len(found.meals) == 2  # a meal never runs across unread windows
    flags = eat.epochs(found, 14)
    assert flags[7] is None and flags[3] is True and flags[10] is True


# ---- any layout ---------------------------------------------------------------------------------------------------

def test_eight_channels_at_500_hz_with_a_dead_and_a_railed_electrode() -> None:
    names = ["Fp1", "Fp2", "t7", "T8", "Oz", "Pz", "FT7", "F8"]  # any letter case; FT7 dead, F8 at the rail
    fs = 500
    x, rng = recording(names, fs, 300, seed=5)
    add_jaw(x, names, fs, 60, 240, chew_envelope(180 * fs, fs, 2.0), rng)
    x[6] = 0.0
    x[7] = 400_000.0
    assert eat.pick(names) == ([2, 3, 6, 7], [0, 1, 4, 5])
    found = found_of(x, fs, names)
    (meal,) = found.meals
    assert meal.rate is not None and abs(meal.rate - 120) <= 3
    assert all(w.read and w.temples == 2 and w.backs == 4 for w in found.windows)


def test_one_temple_channel_and_no_back_channel() -> None:
    fs = 250
    x, rng = recording(["T4"], fs, 300, seed=6)
    add_jaw(x, ["T4"], fs, 60, 240, chew_envelope(180 * fs, fs, 1.6), rng)
    found = found_of(x, fs, ["T4"])
    assert len(found.meals) == 1 and found.no_back
    assert all(w.together is None and w.jaw_ratio is None for w in found.windows)


def test_no_temple_channel_or_a_slow_sample_rate_is_not_read() -> None:
    fs = 250
    names = ["O1", "O2", "Cz"]
    x, _ = recording(names, fs, 120)
    found = found_of(x, fs, names)
    assert found.not_read is not None and "no temple channel" in found.not_read
    assert found.meals == [] and found.windows and not any(w.read for w in found.windows)
    assert eat.epochs(found, 4) == [None] * 4

    x, _ = recording(FOUR, 125, 120)
    slow = found_of(x, 125, FOUR)
    assert slow.not_read is not None and "sample rate" in slow.not_read and not any(w.read for w in slow.windows)
    assert eat.refusal(FOUR, 150) is None and eat.refusal(FOUR, 250) is None


def test_the_sites_and_sides() -> None:
    assert all(eat.is_temple(n) for n in ("T3", "t4", " T7 ", "T8", "F7", "FT8", "TP7"))
    assert not any(eat.is_temple(n) for n in ("O1", "Cz", "Fp1", "TP9", "Ch3"))
    assert [eat.side(n) for n in ("T3", "T4", "FT7", "FT10")] == [0, 1, 0, 1]


def test_the_envelope_at_a_rate_ten_does_not_divide() -> None:
    fs = 256
    rng = np.random.default_rng(7)
    e = eat.envelope(rng.normal(0.0, 10.0, 10 * fs), fs)
    assert len(e) == 100 and bool(np.all(e > 0))
