"""Makes the fixture for app/test/sleep_prep_test.dart: two synthetic recorder runs and what the laptop's own code
makes of them (scripts/to_bdf.py's join, scripts/score_sleep.py's gap_mask and prepare), so the phone's Dart
preprocessing is checked against the Python it copies.

usage (from the repo root):  uv run --project analysis python app/test/fixtures/make_sleep_fixture.py

Writes app/test/fixtures/sleep_night/: the two file sets (<stamp>.f32 + .idx, the recorder's format), expected.json
(join layout, gap flags, filter taps, the high-passed and the resampled signal at every 40th / 20th sample, the
percentiles) and model_input.bin (the model's input, float32 little-endian, time x 4 channels). The BDF round trip
of the laptop (24-bit storage, 0.05 uV steps) is left out on purpose: it is the one step the phone does not copy.
"""
import json
import sys
from datetime import datetime
from fractions import Fraction
from pathlib import Path

import mne
import numpy as np
from scipy.signal import firwin, resample_poly

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import score_sleep  # noqa: E402
import to_bdf  # noqa: E402

OUT = Path(__file__).resolve().parent / "sleep_night"
FS = 250
BATCH = 25  # samples per batch, as BrainBit sends them about every 0.1 s


def run(rng: np.random.Generator, t0: float, seconds: float, pause_at: float | None, pause_s: float,
        first_pack: int) -> tuple[np.ndarray, np.ndarray]:
    """Samples (<I4f records) and index rows (<dQ) of one recorder run that starts sampling at unix time t0;
    sampling stops for pause_s seconds after pause_at seconds (a hole inside the file)."""
    n = int(seconds * FS)
    k = np.arange(n)
    t = t0 + k / FS + (pause_s if pause_at is not None else 0) * (k >= int((pause_at or 0) * FS))
    rel = t - t0
    offsets = np.array([0.012, -0.008, 0.020, -0.015])  # volts: dry electrodes sit tens of mV off
    v = offsets[None, :] + 3e-5 * rel[:, None]  # slow drift
    v[:, :2] += 20e-6 * np.sin(2 * np.pi * 10 * rel)[:, None]  # alpha at the back
    v[:, 2:] += 30e-6 * np.sin(2 * np.pi * 0.8 * rel + 1.0)[:, None]  # slow waves at the side
    v += 8e-6 * rng.standard_normal((n, 4))
    for i in rng.choice(n - 50, size=6, replace=False):  # movement spikes beyond 20 x IQR: clipped later
        v[i:i + 20] += rng.choice([-1, 1]) * 2e-3
    rec = np.zeros(n, dtype=np.dtype([("pack", "<u4"), ("v", "<f4", 4)]))
    rec["pack"] = (first_pack + k) % 2048
    rec["v"] = v.astype(np.float32)
    rows = []
    for b in range(0, n, BATCH):
        last = min(n, b + BATCH) - 1
        rows.append((t[last] + 0.03 + 0.02 * rng.random(), b))  # a batch arrives just after its last sample
    return rec, np.array(rows, dtype=to_bdf.IDX_DTYPE)


def main() -> None:
    rng = np.random.default_rng(20261118)
    OUT.mkdir(exist_ok=True)
    for p in OUT.glob("*"):
        p.unlink()
    t_a = 1795468320.37  # 2026-11-24 00:12:00.37 MSK; the sub-second start makes a short gap at the start
    rec_a, idx_a = run(rng, t_a, 70, 30, 1.3, 100)
    t_b = t_a + 70 + 1.3 + 9.0  # the second run starts 9 s after the first one's last sample
    rec_b, idx_b = run(rng, t_b, 90, None, 0, 7)
    idx_b = np.append(idx_b, np.array([(t_b + 95, len(rec_b))], dtype=to_bdf.IDX_DTYPE))  # outlived its samples
    paths = []
    for t, rec, idx in ((t_a, rec_a, idx_a), (t_b, rec_b, idx_b)):
        stem = OUT / f"{datetime.fromtimestamp(int(t)):%Y-%m-%d-%H%M%S}"  # local start; the .idx gives the times
        rec.tofile(f"{stem}.f32"); idx.tofile(f"{stem}.idx")
        paths.append(Path(f"{stem}.f32"))

    start, uv, notes = to_bdf.join(paths)
    raw = mne.io.RawArray(uv.T * 1e-6, mne.create_info(to_bdf.NAMES, FS, "eeg"), verbose="error")
    bad = [(o, d, s) for o, d, s in notes if s.startswith("BAD")]
    raw.set_annotations(mne.Annotations([o for o, _, _ in bad], [d for _, d, _ in bad], [s for _, _, s in bad]))
    n_ep = int(raw.n_times / raw.info["sfreq"] // score_sleep.EPOCH)
    gap = score_sleep.gap_mask(raw, n_ep)
    x = score_sleep.prepare(raw)

    # the same steps one by one, for the intermediate checks
    filt = raw.copy().pick(score_sleep.CHANNELS).filter(score_sleep.HIGH_PASS_HZ, None, verbose="error").get_data()
    hp = mne.filter.create_filter(None, FS, score_sleep.HIGH_PASS_HZ, None, verbose="error")
    f = Fraction(score_sleep.MODEL_HZ, FS)
    res = resample_poly(filt, f.numerator, f.denominator, axis=1)
    lp = firwin(2 * 10 * max(f.numerator, f.denominator) + 1, 1 / max(f.numerator, f.denominator), window=("kaiser", 5.0))
    pct = np.percentile(res, [25, 50, 75], axis=1).T
    iqr = pct[:, 2] - pct[:, 0]
    assert np.array_equal(x, (np.clip(res, -20 * iqr[:, None], 20 * iqr[:, None]) - pct[:, 1:2]) / iqr[:, None])
    model_input = np.ascontiguousarray(x[:, : n_ep * 3840].T).astype("<f4")
    model_input.tofile(OUT / "model_input.bin")

    expected = dict(
        made_by="app/test/fixtures/make_sleep_fixture.py",
        files=[p.name for p in paths],
        start_unix=start.timestamp(), samples=len(uv), n_ep=n_ep, gap=[bool(g) for g in gap],
        bad=[dict(onset_samples=round(o * FS), samples=round(d * FS), text=s) for o, d, s in bad],
        uv_every_500=[[round(float(v), 6) for v in row] for row in uv[::500]],
        high_pass=dict(taps=len(hp), first=hp[:3].tolist(), centre=float(hp[len(hp) // 2]), sum_abs=float(np.abs(hp).sum())),
        resample=dict(up=f.numerator, down=f.denominator, taps=len(lp), centre=float(lp[len(lp) // 2]),
                      first=lp[:3].tolist(), sum_abs=float(np.abs(lp).sum())),
        filtered_uv_every_40=[[float(v) for v in col] for col in (filt[:, ::40] * 1e6)],
        resampled_uv_every_20=[[float(v) for v in col] for col in (res[:, ::20] * 1e6)],
        resampled_samples=res.shape[1],
        percentiles_uv=[[float(v) for v in row] for row in pct * 1e6],
        model_input="model_input.bin", model_input_shape=list(model_input.shape),
    )
    (OUT / "expected.json").write_text(json.dumps(expected))
    print(f"{len(uv)} samples, {n_ep} epochs, gaps {gap.tolist()}, bad {[(round(o, 3), round(d, 3), s) for o, d, s in bad]}")


if __name__ == "__main__":
    main()
