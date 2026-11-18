"""Makes the fixture for app/test/live_prep_test.dart: what the live scorer's Python reference
(analysis/live_stager.py) makes of a synthetic headband stream, call by call, with a 6-epoch window from the 4th
epoch on (the app uses 120 and 10; the rules are the same).

usage (from the repo root):  uv run --project analysis python app/test/fixtures/make_live_fixture.py

The stream is made from a formula that the Dart test repeats sample by sample (`liveFixtureRow` in
test/live_prep_test.dart), so no recording is stored: electrode offsets of tens of mV, a slow drift, alpha at the
back, slow waves at the sides, integer-hash noise, a movement spike every 16 s, and two holes held at the last
value (7 s: one epoch over 5 s held; 3 s: scored). Writes app/test/fixtures/live_night.json: the high-pass
coefficients and start state, the filtered signal (every 10th of the first 3000 samples), the resampled signal
(every 41st), the gap epochs, and for every call its window, gap flags, percentiles and scaled input (every 151st
value of the time x 4 block).
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy.signal import sosfilt_zi

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "analysis"))
import live_stager as ls  # noqa: E402

OUT = HERE / "live_night.json"
WINDOW, MIN_EP = 6, 4
SAMPLES = 9 * 60 * ls.FS + 40
HOLES = [(25000, 1750), (60000, 750)]  # (first held sample, samples held)
OFFSETS = [12000.0, -8000.0, 20000.0, -15000.0]  # µV: dry electrodes sit tens of mV off


def noise(k: np.ndarray, c: int) -> np.ndarray:
    """Uniform noise with unit variance from an integer hash of (sample, channel); the Dart test does the same."""
    h = ((k * 4 + c) * 2654435761) % (1 << 32)
    return (h / float(1 << 32) - 0.5) * np.sqrt(12.0)


def stream() -> tuple[np.ndarray, np.ndarray]:
    k = np.arange(SAMPLES, dtype=np.int64)
    t = k / ls.FS
    uv = np.empty((SAMPLES, 4))
    for c in range(4):
        wave = 20 * np.sin(2 * np.pi * 10 * t) if c < 2 else 30 * np.sin(2 * np.pi * 0.8 * t + 1)
        uv[:, c] = OFFSETS[c] + 30 * t + wave + 8 * noise(k, c)
        spike = (k % 4000) < 20
        uv[spike, c] += 2000 if c % 2 == 0 else -2000
    missing = np.zeros(SAMPLES, bool)
    for at, n in HOLES:
        uv[at:at + n] = uv[at - 1]
        missing[at:at + n] = True
    return np.clip(uv, -ls.LIM, ls.LIM), missing


def main() -> None:
    uv, missing = stream()
    filt = ls.causal_highpass(uv)
    res = ls.resample(filt)
    n_ep = ls.ready_epochs(len(uv))
    gap = ls.gap_epochs(missing, n_ep)
    calls = []
    for e in range(MIN_EP, n_ep + 1):
        w0 = max(0, e - WINDOW)
        win = res[w0 * ls.EPS:e * ls.EPS]
        x = ls.scale(win).astype(np.float32).reshape(-1)  # time-major, 4 channels
        calls.append(dict(first=w0, end=e, gap=[bool(g) for g in gap[w0:e]],
                          percentiles_uv=np.percentile(win, [25, 50, 75], axis=0).T.tolist(),
                          scaled_every_151=x[::151].tolist(), scaled_len=len(x)))
    sos = ls.highpass_sos()
    expected = dict(
        made_by="app/test/fixtures/make_live_fixture.py",
        samples=SAMPLES, holes=HOLES, offsets=OFFSETS, n_ep=n_ep, gap=[bool(g) for g in gap],
        window=WINDOW, min_epochs=MIN_EP,
        sos=sos[0].tolist(), zi_per_unit=sosfilt_zi(sos)[0].tolist(),
        input_every_997=uv[::997].tolist(),
        filtered_every_10=filt[:3000:10].tolist(),
        resampled_every_41=res[: ls.ready_model_samples(SAMPLES)][::41].tolist(),
        ready_model_samples=ls.ready_model_samples(SAMPLES),
        calls=calls,
    )
    OUT.write_text(json.dumps(expected))
    print(f"{SAMPLES} samples, {n_ep} epochs, gaps at {np.flatnonzero(gap).tolist()}, {len(calls)} calls, "
          f"{OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
