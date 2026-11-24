"""Make app/test/fixtures/pulse.json: made-up recordings with a pulse in them, and what the Python reference
(`pulse.py`) finds there, for the Dart port's cross-check (app/test/pulse_cross_check_test.dart).

  uv run --project analysis python analysis/make_pulse_fixture.py [OUT.json]

Nothing of anyone's recordings: the signals are drawn here (the helpers below; analysis/tests/test_pulse.py uses them
too): background EEG-like noise with an electrode offset and alpha, a pulse wave (its rate and three harmonics, the
rate swinging a little with each breath) strongest on one or two electrodes, steps (short bumps on every channel, one
foot a little different from the other), mains hum and a hole in the signal. Five cases: a pulse under a walk on soft
steps (the walking detector's veto); the BrainBit's four channels
(a pulse, a hole, a movement, a weaker pulse, steps); eight channels in another layout with one dead and one railed
electrode and loud hum; four channels at 500 samples a second; one channel at 256. Signals are stored as in
detectors.json (gzip-compressed int32 differences, here in 1 µV steps), so both sides start from the very same numbers.
"""

from __future__ import annotations

import base64
import gzip
import json
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pulse as pl  # noqa: E402
import walking as wk  # noqa: E402

SCALE = 1  # steps per µV
OUT = Path(__file__).resolve().parents[1] / "app" / "test" / "fixtures" / "pulse.json"
START_UNIX = 1795190400  # a whole minute (made up)
WEAK_UV = 2.0  # the weaker pulse


# ---- made-up signals (also used by analysis/tests/test_pulse.py) ----


def background(channels: int, seconds: float, fs: float, seed: int, uv: float = 1.5) -> np.ndarray:
    """EEG-like noise: a slow wander, white noise, 10 Hz alpha on the first two channels and an electrode offset."""
    rng = np.random.default_rng(seed)
    n = int(round(seconds * fs))
    x = rng.normal(0, uv, (channels, n))
    wander = np.cumsum(rng.normal(0, 0.3, (channels, n)), axis=1)
    x += wander - np.linspace(0, 1, n) * wander[:, -1:]
    t = np.arange(n) / fs
    for c in range(min(2, channels)):
        x[c] += 8 * np.sin(2 * math.pi * 10.2 * t + c)
    x += rng.uniform(-20000, 20000, (channels, 1))
    return x


def add_pulse(x: np.ndarray, fs: float, start_s: float, end_s: float, bpm: float, uv: float, gains: list[float],
              breath_s: float = 4.6, swing: float = 0.03, drift_bpm: float = 0.0) -> None:
    """A pulse wave from start_s to end_s at about bpm a minute: its rate and 2, 3 and 4 times it (a smooth beat with a
    later notch), the rate swinging by `swing` with each breath and drifting by drift_bpm over the stretch; each
    channel gets uv x its gain."""
    n = x.shape[1]
    a, b = int(start_s * fs), min(n, int(end_s * fs))
    t = np.arange(b - a) / fs
    rate = (bpm + drift_bpm * t / max(t[-1], 1e-9)) / 60 * (1 + swing * np.sin(2 * math.pi * t / breath_s))
    phase = 2 * math.pi * np.cumsum(rate) / fs
    wave = (np.sin(phase) + 0.45 * np.sin(2 * phase + 0.7) + 0.25 * np.sin(3 * phase + 1.3)
            + 0.12 * np.sin(4 * phase + 2.1))
    for c, g in enumerate(gains):
        x[c, a:b] += uv * g * wave


def add_steps(x: np.ndarray, fs: float, start_s: float, end_s: float, spm: float, uv: float, seed: int,
              gains: list[float] | None = None) -> int:
    """Steps from start_s to end_s at spm steps a minute: each a 40 ms bump of about uv on every channel (scaled by
    gains), the other foot's 30 % smaller, timed with 8 ms jitter (the walking lane's made-up steps). Returns the
    number of steps."""
    rng = np.random.default_rng(seed)
    gains = gains or [1.0] * x.shape[0]
    n = x.shape[1]
    t = np.arange(n) / fs
    at, k = start_s, 0
    while at < end_s:
        tk = at + rng.normal(0, 0.008)
        a = int(max(0, (tk - 0.2) * fs)), int(min(n, (tk + 0.2) * fs))
        u = t[a[0]:a[1]] - tk
        shape = np.exp(-0.5 * (u / 0.04) ** 2) - 0.3 * np.exp(-0.5 * ((u - 0.1) / 0.06) ** 2)
        size = uv * (1.0 if k % 2 == 0 else 0.7)
        for c in range(x.shape[0]):
            x[c, a[0]:a[1]] += size * gains[c] * shape
        k += 1
        at += 60 / spm
    return k


def add_hum(x: np.ndarray, fs: float, uv: float, gains: list[float], hz: float = 50.0) -> None:
    """Mains hum: hz and its 2nd and 3rd harmonics (folded back where they pass half the rate, as a converter without
    a filter would), its loudness swaying slowly."""
    n = x.shape[1]
    t = np.arange(n) / fs
    sway = 1 + 0.3 * np.sin(2 * math.pi * t / 7.0)
    hum = np.sin(2 * math.pi * hz * t) + 0.3 * np.sin(2 * math.pi * 2 * hz * t + 0.4) + 0.2 * np.sin(
        2 * math.pi * 3 * hz * t + 1.0)
    for c, g in enumerate(gains):
        x[c] += uv * g * sway * hum


def hole(x: np.ndarray, miss: np.ndarray, fs: float, at_s: float, seconds: float) -> None:
    """A hole: the last value held, as the join fills it, and marked missing."""
    a = int(at_s * fs)
    b = a + int(seconds * fs)
    miss[a:b] = True
    x[:, a:b] = x[:, a - 1:a]


def four_channels() -> tuple[np.ndarray, float, np.ndarray, dict[str, Any]]:
    """The BrainBit's four, 7 minutes: a pulse at 57 strongest on T4 for 3 minutes, a 3 s hole, a movement, a weaker
    pulse at 63 for 1.5 minutes, half a minute of nothing, steps at 110 a minute too small for the movement rule."""
    fs = 250.0
    x = background(4, 420, fs, seed=41)
    add_pulse(x, fs, 0, 185, 57, 14, [0.1, 0.1, 0.45, 1.0])
    add_pulse(x, fs, 90, 120, 88, 40, [1.0, 0.0, 0.0, 0.0])  # another rhythm for half a minute: the odd one out
    miss = np.zeros(x.shape[1], dtype=bool)
    hole(x, miss, fs, 196, 3)
    add_steps(x, fs, 216, 222, 60, 900, seed=42)  # a movement: a few big swings
    add_pulse(x, fs, 240, 330, 63, WEAK_UV, [0.6, 0.3, 0.2, 0.5], drift_bpm=2)
    add_pulse(x, fs, 240, 270, 63, 1.5, [0.6, 0.3, 0.2, 0.5], drift_bpm=2 / 3)  # clearer in its first half minute
    add_steps(x, fs, 365, 420, 110, 45, seed=43, gains=[1.0, 0.9, 0.6, 0.7])
    return x, fs, miss, dict(names=["O1", "O2", "T3", "T4"], bpm=[57, 63])


def eight_channels() -> tuple[np.ndarray, float, np.ndarray, dict[str, Any]]:
    """Eight channels of another layout, 2 minutes: a pulse at 66 on P8 alone, loud 50 Hz hum on Fp1 and Fp2; one
    electrode dead, one at the rails for a minute."""
    fs = 250.0
    x = background(8, 120, fs, seed=51)
    add_pulse(x, fs, 0, 120, 66, 12, [0, 0, 0, 0, 0.2, 1.0, 0, 0])
    add_hum(x, fs, 3000, [1.0, 0.8, 0, 0, 0, 0.05, 0, 0])
    x[2] = 1500.0  # dead: flat
    x[3, int(30 * fs):int(90 * fs)] = 400000.0  # at the rails for a minute
    return x, fs, np.zeros(x.shape[1], dtype=bool), dict(
        names=["Fp1", "Fp2", "C3", "C4", "P7", "P8", "O1", "O2"], bpm=[66])


def fast_rate() -> tuple[np.ndarray, float, np.ndarray, dict[str, Any]]:
    """Four channels at 500 a second, 1.5 minutes: a pulse at 74."""
    fs = 500.0
    x = background(4, 90, fs, seed=61)
    add_pulse(x, fs, 0, 90, 74, 12, [0.2, 0.2, 1.0, 0.5])
    return x, fs, np.zeros(x.shape[1], dtype=bool), dict(names=["O1", "O2", "T7", "T8"], bpm=[74])


def one_channel() -> tuple[np.ndarray, float, np.ndarray, dict[str, Any]]:
    """One channel at 256 a second, 2 minutes: a pulse at 50."""
    fs = 256.0
    x = background(1, 120, fs, seed=71)
    add_pulse(x, fs, 0, 120, 50, 10, [1.0])
    return x, fs, np.zeros(x.shape[1], dtype=bool), dict(names=["Fpz"], bpm=[50])


def soft_walk() -> tuple[np.ndarray, float, np.ndarray, dict[str, Any]]:
    """Four channels, 4 minutes: a pulse at 60 throughout, and from 1:02 to 2:50 a walk at 112 steps a minute on soft
    steps (a shake of about 325 µV: walking-sized, under the movement rule): the walking detector's epochs are `w`."""
    fs = 250.0
    x = background(4, 240, fs, seed=81)
    add_pulse(x, fs, 0, 240, 60, 14, [0.1, 0.1, 0.45, 1.0])
    add_steps(x, fs, 62, 170, 112, 300, seed=82, gains=[1.0, 0.9, 0.6, 0.7])
    return x, fs, np.zeros(x.shape[1], dtype=bool), dict(names=["O1", "O2", "T3", "T4"], bpm=[60])


CASES = {"four channels: a pulse, a hole, a movement, a weaker pulse, steps": four_channels,
         "four channels: a pulse and a walk on soft steps": soft_walk,
         "eight channels, one dead, one railed, loud hum": eight_channels,
         "four channels at 500 a second": fast_rate,
         "one channel at 256 a second": one_channel}


# ---- the fixture ----


def encode(x: np.ndarray) -> tuple[str, np.ndarray]:
    q = np.round(x * SCALE).astype(np.int64)
    d = np.diff(q, axis=1, prepend=0)
    if np.abs(d).max() >= 2**31:
        raise ValueError("difference too large for int32")
    blob = base64.b64encode(gzip.compress(d.astype("<i4").tobytes(), 9, mtime=0)).decode()
    return blob, q / SCALE


def num(v: float | None) -> float | None:
    """Numbers to 12 significant digits (the Dart side compares within 1e-9)."""
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    return float(f"{float(v):.12g}")


def spans(mask: np.ndarray) -> list[list[int]]:
    out, i, n = [], 0, len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append([i, j])
            i = j
        else:
            i += 1
    return out


def edges_of(ep: pl.Epoch) -> list[tuple[str, float, float]]:
    """(what, value, threshold) of every decision of an epoch, to keep each clear of its threshold."""
    out: list[tuple[str, float, float]] = []
    if ep.channels and not math.isnan(ep.conf):
        out.append(("confidence", ep.conf, pl.sure_for(ep.channels)))
        out.append(("confidence", ep.conf, pl.NEAR_CONF))
    for q, _, _ in ep.peaks or []:
        out.append(("peak", q, pl.NEAR_CONF))
    return out


def case(name: str, make) -> dict[str, Any]:
    x, fs, miss, info = make()
    blob, xq = encode(x)
    eps = pl.epochs(xq, fs, miss)
    for e, ep in enumerate(eps):  # no decision on a knife's edge: the two sides may differ in the last bits
        for what, v, t in edges_of(ep):
            if abs(v - t) < 1e-6 * max(1.0, abs(t)):
                raise ValueError(f"{name}: epoch {e} {what} {v} is too near {t}; change the seed")
    bpm = [ep.bpm if ep.read else None for ep in eps]
    stages = [("N2", "R", "W", "N3")[e % 4] for e in range(len(eps))]  # made up: the summaries' arithmetic only
    a = pl.asleep([None if b is None else round(b, 1) for b in bpm], stages)
    return dict(
        name=name, sample_rate=fs, channels=info["names"], n=int(x.shape[1]), signal=blob, missing=spans(miss),
        start_unix=START_UNIX, truth=info["bpm"],
        epochs=[[ep.code, num(ep.bpm), num(ep.conf), ep.channel, num(ep.best), ep.channels] for ep in eps],
        stages=stages, walking=wk.epoch_flags(wk.windows(xq, fs, miss, quick=True), len(eps)),
        asleep=dict(epochs=a.epochs, read=a.read, median=num(a.median), lowest=num(a.lowest)),
    )


def fixture() -> dict[str, Any]:
    return dict(detector=pl.VERSION, scale=SCALE, cases=[case(n, f) for n, f in CASES.items()])


def text() -> str:
    return json.dumps(fixture(), separators=(",", ":")) + "\n"


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT
    out.write_text(text())
    print(out, out.stat().st_size, "bytes")
