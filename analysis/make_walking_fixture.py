"""Make app/test/fixtures/walking.json: made-up recordings with walking and running in them, and what the Python
reference (`walking.py`) finds there, for the Dart port's cross-check (app/test/walking_cross_check_test.dart).

  uv run --project analysis python analysis/make_walking_fixture.py [OUT.json]

Nothing of anyone's recordings: the signals are drawn here (the helpers below; analysis/tests/test_walking.py uses
them too): background EEG-like noise with an electrode offset and alpha, and each step a short bump on every
channel, a little different between the left and the right foot (the stride, half the step rate, is in real walks
too). Three cases: the BrainBit's four channels walking, stopping, running and with a hole in the signal (and the
phone's step counter for some minutes); eight channels in another layout with one dead and one railed electrode; and
four channels at 500 samples a second. Signals are stored as in detectors.json (gzip-compressed int32 differences,
here in 1 µV steps), so both sides start from the very same numbers.
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
import walking as wk  # noqa: E402

SCALE = 1  # steps per µV
OUT = Path(__file__).resolve().parents[1] / "app" / "test" / "fixtures" / "walking.json"
START_UNIX = 1795190400  # a whole minute (made up)


# ---- made-up signals (also used by analysis/tests/test_walking.py) ----


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


def add_steps(x: np.ndarray, fs: float, start_s: float, end_s: float, spm: float, uv: float, seed: int,
              gains: list[float] | None = None) -> int:
    """Steps from start_s to end_s at spm steps a minute: each a 40 ms bump of about uv on every channel (scaled by
    gains), the right foot's 30 % smaller, timed with 8 ms jitter. Returns the number of steps."""
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


def add_pulse(x: np.ndarray, fs: float, start_s: float, end_s: float, bpm: float, uv: float,
              mix: tuple[float, float, float] = (1.0, 0.3, 1.0)) -> None:
    """A pulse-like rhythm from start_s to end_s: its rate and 2 and 3 times it (weights `mix`) on every channel, as a
    sleeping heart shows in these electrodes; with the third harmonic strong the score's best rate is 3 x bpm."""
    n = x.shape[1]
    a, b = int(start_s * fs), min(n, int(end_s * fs))
    t = np.arange(a, b) / fs
    f0 = bpm / 60
    wave = sum(m * np.sin(2 * math.pi * (k + 1) * f0 * t + k) for k, m in enumerate(mix))
    x[:, a:b] += uv * wave


def phone_readings(start_unix: float, minutes: list[tuple[float, int]], first: int = 52000) -> list[tuple[float, int]]:
    """The step counter's once-a-minute readings: (seconds after start, steps added since the reading before)."""
    out, c = [], first
    for t, add in minutes:
        c += add
        out.append((start_unix + t, c))
    return out


def four_channels() -> tuple[np.ndarray, float, np.ndarray, list[tuple[float, int]], dict[str, Any]]:
    """The BrainBit's four: rest, a walk at 112 a minute, a stop with a small pulse (too small to be steps), a run at
    162 a minute with a 3 s hole, rest."""
    fs = 250.0
    x = background(4, 250, fs, seed=11)
    walked = add_steps(x, fs, 15, 95, 112, 400, seed=12, gains=[1.0, 0.9, 0.6, 0.7])
    add_pulse(x, fs, 100, 155, 57, 12)
    ran = add_steps(x, fs, 160, 240, 162, 600, seed=13, gains=[1.0, 0.9, 0.6, 0.7])
    miss = np.zeros(x.shape[1], dtype=bool)
    a = int(200 * fs)
    miss[a:a + int(3 * fs)] = True
    x[:, a:a + int(3 * fs)] = x[:, a - 1:a]  # a hole is the last value held, as the join fills it
    phone = phone_readings(START_UNIX, [(4, 0), (64, 98), (124, 12), (184, 0), (244, 0)])
    return x, fs, miss, phone, dict(names=["O1", "O2", "T3", "T4"], walked=walked, ran=ran)


def eight_channels() -> tuple[np.ndarray, float, np.ndarray, list[tuple[float, int]], dict[str, Any]]:
    """Eight channels of another layout: rest, a walk at 104 a minute, rest, then a large pulse-like rhythm read at
    three times its rate (no steps: the family at a third and two thirds says so); one electrode dead, one at the
    rails."""
    fs = 250.0
    x = background(8, 115, fs, seed=21, uv=1.5)
    walked = add_steps(x, fs, 10, 70, 104, 500, seed=22, gains=[0.4, 0.5, 0.6, 0.6, 0.8, 0.8, 1.0, 1.0])
    add_pulse(x, fs, 78, 115, 58, 150)
    x[2] = 1500.0  # dead: flat
    x[5, int(30 * fs):int(55 * fs)] = 400000.0  # at the rails for 25 s
    return x, fs, np.zeros(x.shape[1], dtype=bool), [], dict(
        names=["Fp1", "Fp2", "C3", "C4", "P7", "P8", "O1", "O2"], walked=walked, ran=0)


def fast_rate() -> tuple[np.ndarray, float, np.ndarray, list[tuple[float, int]], dict[str, Any]]:
    """Four channels at 500 a second: a walk at 120 a minute."""
    fs = 500.0
    x = background(4, 50, fs, seed=31)
    walked = add_steps(x, fs, 6, 46, 120, 400, seed=32)
    return x, fs, np.zeros(x.shape[1], dtype=bool), [], dict(names=["O1", "O2", "T7", "T8"], walked=walked, ran=0)


CASES = {"four channels: walk, stop, run, a hole, the phone": four_channels,
         "eight channels, one dead, one railed": eight_channels,
         "four channels at 500 a second": fast_rate}


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


def stretch(s: wk.Stretch) -> dict[str, Any]:
    return dict(first=s.first, last=s.last, kind=s.kind, steps=num(s.steps), pace=num(s.pace), score=num(s.score),
                confidence=s.confidence)


EDGES = {"score": (wk.SCORE_WALK, wk.LIKELY_SCORE, wk.SURE_SCORE), "amp": (wk.MIN_SHAKE_UV,), "thirds": (wk.MAX_THIRDS,)}


def case(name: str, make) -> dict[str, Any]:
    x, fs, miss, readings, info = make()
    blob, xq = encode(x)
    found = wk.find(wk.windows(xq, fs, miss))
    for w in found.windows:  # no decision on a knife's edge: the two sides may differ in the last bits
        for k, edges in EDGES.items():
            v = getattr(w, k)
            if w.read and any(abs(v - e) < 1e-6 * max(1.0, abs(e)) for e in edges):
                raise ValueError(f"{name}: {k} {v} is too near a threshold; change the seed")
    phone = wk.phone_minutes(readings)
    rows = wk.minutes(found, START_UNIX, phone)
    chk = wk.check(rows)
    return dict(
        name=name, sample_rate=fs, channels=info["names"], n=int(x.shape[1]), signal=blob, missing=spans(miss),
        start_unix=START_UNIX, readings=[[t, c] for t, c in readings],
        truth=dict(walked=info["walked"], ran=info["ran"]),
        windows=[[num(w.t), w.read, num(w.score), num(w.pace), num(w.amp), w.channels, num(w.thirds), w.walks]
                 for w in found.windows],
        smoothed=found.smoothed,
        moving=[stretch(s) for s in found.moving],
        walks=[dict(stretches=[stretch(s) for s in w.stretches], walking_s=num(w.walking_s), stopped_s=num(w.stopped_s),
                    steps=num(w.steps), pace=num(w.pace)) for w in found.walks],
        phone=[[m, num(v)] for m, v in phone.items()],
        minutes=[[r.t, num(r.walk_s), num(r.run_s), num(r.hb_steps), num(r.hb_pace), num(r.phone), num(r.steps),
                  r.source, num(r.walking_s)] for r in rows],
        check=dict(paired=chk.paired, right=chk.right, hb_steps=num(chk.hb_steps), phone_steps=num(chk.phone_steps),
                   status=chk.status),
    )


def fixture() -> dict[str, Any]:
    return dict(detector=wk.VERSION, scale=SCALE, cases=[case(n, f) for n, f in CASES.items()])


def text() -> str:
    return json.dumps(fixture(), separators=(",", ":")) + "\n"


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT
    out.write_text(text())
    print(out, out.stat().st_size, "bytes")
