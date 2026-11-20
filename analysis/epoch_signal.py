"""The data book's signal pass: per 30 s epoch of a joined recording, for any number of channels at any rate.

scripts/data_book.py (DECISIONS 760-769) joins a recording's files as scripts/to_bdf.py does (held values over gaps,
`BAD_gap` notes) and hands the samples here. Per epoch, counted from the recording's origin (a night's sleep report's
`data_start`, so the rows line up with its stages):

- **band mix per channel**: delta 1-4, theta 4-8, alpha 8-12 and beta 12-30 Hz as a share (%) of the power from 1 to
  30 Hz, after a 0.5 Hz high-pass (4th-order Butterworth, forward and back) that takes out the dry electrodes' drift
  (Welch, 4 s Hann windows with half overlap, each window's mean removed): the bands of the hand analysis of the nap
  of 2026-11-20, with beta from 12 Hz so the four add up to 100 %; empty when over 5 s of the epoch is missing or the
  channel has no power there (flat);
- **quality per channel**: the shared detectors' rule for one channel (eeg_detectors.py, DECISIONS 85-87) at the
  recording's own rate: `m` missing (over 5 s of the epoch missing), `b` bad (over 3 s flat, at the rail, or over
  500 µV in a second after a 2 Hz high-pass), `g` good;
- **the epoch's quality, jaw and movement**: where the recording holds O1 O2 T3 T4 (by name or 10-10 site) at
  250 Hz, the shared detectors themselves (the night extras' `g d m`, jaw bursts starting in the epoch, movement
  spans starting in it, movement and muscle seconds); otherwise the same quality rule without muscle (movement: 3 or
  more channels jumping past 200 µV in the same second) and no jaw count.

Each channel is named by the recording's header (scripts/recording.py), so the pass works for the BrainBit's four
channels, the DIY board's eight and the helmet's 8-16 at custom positions alike. Planning values, not validated.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt, welch

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import eeg_detectors as det  # noqa: E402
import recording  # noqa: E402

VERSION = "epoch-signal-v1"  # of this pass: a change of any rule below is a new version (the book recomputes)
EPOCH_S = det.EPOCH_S
BANDS = (("delta", 1.0, 4.0), ("theta", 4.0, 8.0), ("alpha", 8.0, 12.0), ("beta", 12.0, 30.0))
TOTAL_HZ = (1.0, 30.0)
DRIFT_HZ = 0.5  # the band mix's high-pass
WINDOW_S = 4
LIMIT_UV = 400_000.0  # the BDF's range, as the night extras clip
CHUNK = 128  # epochs per Welch call (memory)


@dataclass
class Epochs:
    """The pass over one recording: one entry per whole 30 s epoch from its origin."""
    n: int
    channels: tuple[str, ...]
    bands: dict[str, np.ndarray]  # band -> (n, channels) percent, NaN where not computable
    channel_quality: list[str]  # per epoch: one character per channel, in record order
    quality: list[str]  # per epoch: g d m
    detectors: bool  # O1 O2 T3 T4 at 250 Hz: the shared detectors ran (jaw, muscle)
    jaw: list[int | None]  # jaw bursts starting in the epoch; None without the detectors
    moves: list[int]  # movement spans starting in the epoch
    movement_s: list[int]
    muscle_s: list[int | None]
    bursts: list[tuple[int, int, str]] = field(default_factory=list)  # (first s, last s, kind), for the night extras
    spans: list[tuple[int, int]] = field(default_factory=list)  # movement spans (first s, last s)


def missing_mask(n: int, notes: list[tuple[float, float, str]], fs: float) -> np.ndarray:
    """Held samples from to_bdf.join's notes (every `BAD_gap` and `BAD_padding`), at the recording's rate."""
    miss = np.zeros(n, bool)
    for onset, dur, text in notes:
        if text.startswith("BAD") and dur > 0:
            lo = round(onset * fs)
            miss[lo: lo + round(dur * fs)] = True
    return miss


def align(uv: np.ndarray, miss: np.ndarray, start: datetime, origin: datetime, fs: float
          ) -> tuple[np.ndarray, np.ndarray]:
    """The samples from `origin` on: the ones before it dropped, or time before `start` added as missing (the first
    value held), so epoch 0 starts at `origin`."""
    k = round((origin - start).total_seconds() * fs)
    if k > 0:
        return uv[k:], miss[k:]
    if k < 0:
        head = np.repeat(uv[:1], -k, axis=0) if len(uv) else np.zeros((-k, uv.shape[1]))
        return np.concatenate([head, uv]), np.concatenate([np.ones(-k, bool), miss])
    return uv, miss


def _per_second(v: np.ndarray, fs: int, n_s: int) -> np.ndarray:
    return v[: n_s * fs].reshape(n_s, fs)


def channel_seconds(x: np.ndarray, miss: np.ndarray, fs: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Per whole second: a missing sample (n_s,), each channel bad (flat, railed or extreme; (n_s, channels)) and each
    channel's range after the detectors' 2 Hz high-pass (µV)."""
    n_s = len(x) // fs
    gap = _per_second(miss, fs, n_s).any(axis=1)
    hp = [det.highpass(det.QUALITY_HP_HZ, fs=fs)]
    bad = np.zeros((n_s, x.shape[1]), bool)
    qrange = np.zeros((n_s, x.shape[1]))
    for c in range(x.shape[1]):
        raw = _per_second(x[:, c], fs, n_s)
        q = _per_second(det.run_chain(hp, x[:, c]), fs, n_s)
        qrange[:, c] = np.ptp(q, axis=1)
        bad[:, c] = (np.ptp(raw, axis=1) < det.FLAT_UV) | (np.abs(raw).max(axis=1) >= det.RAIL_UV) | \
            (qrange[:, c] > det.EXTREME_UV)
    return gap, bad, qrange


def band_mix(x: np.ndarray, gap_s: np.ndarray, fs: int, n_ep: int) -> dict[str, np.ndarray]:
    """Each band's share (%) of 1-30 Hz per epoch and channel; NaN for an epoch with over 5 s missing or no power."""
    width = EPOCH_S * fs
    out = {b: np.full((n_ep, x.shape[1]), np.nan) for b, _, _ in BANDS}
    if n_ep == 0:
        return out
    seg = WINDOW_S * fs
    sos = butter(4, DRIFT_HZ, btype="highpass", fs=fs, output="sos")
    for c in range(x.shape[1]):
        v = sosfiltfilt(sos, x[: n_ep * width, c]).reshape(n_ep, width)
        for a in range(0, n_ep, CHUNK):
            f, p = welch(v[a: a + CHUNK], fs=fs, nperseg=seg, noverlap=seg // 2, detrend="constant", axis=-1)
            total = p[:, (f >= TOTAL_HZ[0]) & (f < TOTAL_HZ[1])].sum(axis=1)
            ok = (total > 0) & (gap_s[a: a + CHUNK] <= det.MAX_GAP_S)
            for b, lo, hi in BANDS:
                share = p[:, (f >= lo) & (f < hi)].sum(axis=1) / np.where(total > 0, total, 1.0) * 100
                out[b][a: a + CHUNK, c] = np.where(ok, share, np.nan)
    return out


def _starts(items: list[tuple[int, int]], n_ep: int) -> list[int]:
    out = [0] * n_ep
    for a, _ in items:
        e = a // EPOCH_S
        if e < n_ep:
            out[e] += 1
    return out


def run(uv: np.ndarray, miss: np.ndarray, header: recording.Header) -> Epochs:
    """The pass over one aligned recording: `uv` (samples x channels, µV, in the header's record order), `miss` the
    held samples."""
    fs = int(round(header.sample_rate))
    x = np.clip(np.asarray(uv, dtype=np.float64), -LIMIT_UV, LIMIT_UV)
    n_s = len(x) // fs
    n_ep = n_s // EPOCH_S
    gap, bad, qrange = channel_seconds(x, miss, fs)
    per = slice(0, n_ep * EPOCH_S)
    gap_s = gap[per].reshape(n_ep, EPOCH_S).sum(axis=1)
    bad_s = (bad | gap[:, None])[per].reshape(n_ep, EPOCH_S, -1).sum(axis=1)
    chq = ["".join("m" if gap_s[e] > det.MAX_GAP_S else "b" if b > det.BAD_CHANNEL_S else "g" for b in bad_s[e])
           for e in range(n_ep)]
    bands = band_mix(x, gap_s, fs, n_ep)
    try:
        four = recording.pick(header, list(det.CHANNELS), "the shared detectors") if fs == det.FS else None
    except recording.MissingChannels:
        four = None
    if four is not None:
        sec = det.seconds(x[:, four].T, miss)
        found = det.epoch_quality(sec)[:n_ep]
        bursts = [(b.start, b.end, b.kind) for b in det.bursts(sec)]
        spans = [(a, b) for a, b in det.movement_spans(sec)]
        return Epochs(n_ep, header.names, bands, chq, [e.quality[0] for e in found], True,
                      _starts([(a, b) for a, b, k in bursts if k == "jaw"], n_ep), _starts(spans, n_ep),
                      [e.movement_s for e in found], [e.muscle_s for e in found], bursts, spans)
    moving = ((qrange >= det.MOVE_UV).sum(axis=1) >= det.MOVE_CHANNELS) & ~gap
    spans: list[tuple[int, int]] = []
    for k in np.flatnonzero(moving):
        k = int(k)
        if spans and k - spans[-1][1] <= det.MUSCLE_JOIN_S:
            spans[-1] = (spans[-1][0], k)
        else:
            spans.append((k, k))
    move_s = moving[per].reshape(n_ep, EPOCH_S).sum(axis=1)
    quality = []
    for e in range(n_ep):
        usable = [q == "g" for q in chq[e]]
        if gap_s[e] > det.MAX_GAP_S or not any(usable):
            quality.append("m")
        elif not all(usable) or move_s[e] >= det.DEGRADED_MOVE_S:
            quality.append("d")
        else:
            quality.append("g")
    return Epochs(n_ep, header.names, bands, chq, quality, False, [None] * n_ep, _starts(spans, n_ep),
                  [int(v) for v in move_s], [None] * n_ep, [], spans)
