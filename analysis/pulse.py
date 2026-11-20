"""Pulse (heart rate) from the headband's own signal, with no pulse sensor (the Python reference).

Each heartbeat moves the head and the skin under the electrodes a little (the temple artery runs under T3/T4; the back
of the head presses on the pillow), and that shows in the EEG as a slow wave at the heart rate with its harmonics
(research: docs/evidence/pulse.md; the 2026-11-20 prototype found it in 3-12 % of 30 s epochs of two recordings).
This finds it, per 30 s epoch counted from the recording's first sample:

1. Every channel the recording's header names (any number, any layout) is band-passed 0.5-20 Hz (two high-pass and
   two low-pass RBJ biquads, fourth-order Butterworth each way) after 50 Hz and 60 Hz notches, run forward only from
   the channel's first value (the shared detectors' convention, eeg_detectors.run_chain), so the phone's port gets
   the same numbers. Mains hum never reaches the spectrum or the movement check.
2. An epoch is not read when over 1 s of it is missing (a gap), when no channel is usable (flat or at the rails), or
   when the head moved: the usable channels' median band-passed range over 400 µV (the prototype's rule).
3. Per usable channel: the power spectrum of 8 s Hann segments every 4 s (Welch), zero-padded to 0.061 Hz bins
   (4096 points at 250 Hz), "whitened" by dividing each bin by the mean of the 15 bins around it (0.92 Hz), so a broad
   hump does not look like a rhythm.
4. The harmonic score of each candidate rate f0 from 0.7 to 2.0 Hz (42-120 a minute, 0.005 Hz apart): the mean of the
   whitened power at f0, 2 f0, 3 f0 and 4 f0. A channel's confidence is its best score over the median of all
   candidates. The pulse usually shows on one or two electrodes, not all, so the epoch takes the channel with the
   highest confidence (on the owner's three recordings that read about twice as many epochs as the prototype's sum
   over channels at the same rate of chance readings; DECISIONS 811).
5. It is a reading when that confidence is at least 2.2 + 0.1 per doubling of the usable channels (2.4 with four):
   the best of more channels is more often high by chance. Not when the best rate is at the edge of the range (the
   true peak may be outside it), and not when it looks like steps (DECISIONS 813): at 84 a minute or more with power
   at half the rate (the stride: one foot differs from the other; under 84 that is unclear instead, a pulse under 42
   showing at twice its rate); at 45-72 with the even harmonics (the steps
   themselves) stronger than the odd ones; or at any rate with strong 5th to 8th harmonics (a step is a short bump,
   a pulse a smooth wave).
6. The pulse changes slowly, so the neighbours count (DECISIONS 812): a reading 12 a minute or more away from two or
   more readings within 1.5 minutes that agree with each other (within 6) is dropped as the odd one out; an unclear
   epoch whose own spectrum has a peak of confidence 1.8 or more within 4 a minute of the readings within 1 minute
   becomes a reading "with its neighbours". Those never carry another epoch.

Every epoch says why it has no reading: g gap, x no usable channel, m moving, s steps, u unclear, o the odd one out;
r is a reading, n a reading with its neighbours. Every threshold is a planning value set on the owner's three
recordings (2026-11-17, -19, -20) and his walk of 2026-11-20, with no reference heart rate yet: scripts/compare_pulse.py
checks it against a watch's export.
The phone has a line-by-line port in app/lib/pulse/ (pulse_cross_check_test.dart compares them).
Pure functions on arrays: nothing here reads files, clocks or devices.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

import eeg_detectors as det

VERSION = "pulse-v1"

EPOCH_S = 30.0
HIGH_PASS_HZ = 0.5
LOW_PASS_HZ = 20.0
BUTTER_Q = (1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8)))  # fourth order: two biquads
NOTCHES_HZ = (50.0, 60.0)  # mains, both kinds (each only below 0.45 x the sample rate)
NOTCH_Q = 8.0
SEGMENT_S = 8.0  # Welch segments...
SEGMENT_HOP_S = 4.0  # ... every 4 s: six in an epoch
BIN_HZ = 250 / 4096  # spectrum bins at most this wide (4096 points at 250 Hz)
WHITEN_HZ = 15 * BIN_HZ  # the whitening's mean spans this (15 bins at 250 Hz)
RATE_LO_HZ, RATE_STEP_HZ, RATES = 0.7, 0.005, 261  # candidate pulse rates 0.7, 0.705, ... 2.0 Hz (42-120 a minute)
HARMONICS = 4  # f0, 2 f0, 3 f0, 4 f0
MAX_MISSING_S = 1.0  # an epoch with more missing time than this is not read
FLAT_UV = 1.0  # a channel whose band-passed epoch spans less than this is not used (dead or flat)
RAIL_UV = 390_000.0  # nor one at the converter's or the file's limit (eeg_detectors.RAIL_UV)
MOVING_UV = 400.0  # the usable channels' median band-passed range over this: moving, not read
SURE_ONE = 2.2  # a reading's confidence with one usable channel...
SURE_PER_DOUBLING = 0.1  # ... plus this for each doubling of the usable channels (2.4 with four)
STEP_RATE_HZ = 1.4  # a rate at or over this (84 a minute) could be steps...
HALF_MAX = 1.5  # ... and is, when the mean whitened power at half and one and a half times it reaches this (under
#                   it: unclear, a rhythm slower than the range shows at twice its rate)
STRIDE_LO_HZ, STRIDE_HI_HZ = 0.75, 1.2  # a rate in this range (45-72) could be the stride under steps of twice it...
ODD_EVEN_MIN = 0.8  # ... and is, when f0 + 3 f0 is under this share of 2 f0 + 4 f0
SHARP = (5, 6, 7, 8)  # any rate is steps when the mean whitened power at these multiples of it...
SHARP_MAX = 2.5  # ... reaches this: a smooth pulse wave has little past its 4th harmonic, a step is a short bump
ODD_EPOCHS = 3  # the odd one out: within this many epochs (1.5 minutes)...
ODD_NEIGHBOURS = 2  # ... at least this many readings...
ODD_AGREE_BPM = 6.0  # ... that agree within this...
ODD_BPM = 12.0  # ... and the reading this far from their median
NEAR_EPOCHS = 2  # with its neighbours: readings within this many epochs (1 minute)...
NEAR_BPM = 4.0  # ... and a peak of its own within this of their median...
NEAR_CONF = 1.8  # ... of at least this confidence

READ = ("r", "n")
MIN_NIGHT_READINGS = 10  # a night's median while asleep needs this many readings (5 minutes)
LOW_WINDOW = 10  # the lowest 5 minutes: windows of 10 epochs...
LOW_MIN_READINGS = 5  # ... with at least this many readings while asleep
ASLEEP = ("N1", "N2", "N3", "R")

Floats = NDArray[np.float64]
Bools = NDArray[np.bool_]


# ------------------------------------------------------------------------------------------------- the spectrum


def nfft_for(fs: float) -> int:
    """The smallest power of two whose bins are at most BIN_HZ wide (4096 at 250 Hz)."""
    n = 1
    while fs / n > BIN_HZ * (1 + 1e-12):
        n *= 2
    return n


def whiten_bins(fs: float) -> int:
    """The odd number of bins nearest to WHITEN_HZ (15 at 250 Hz)."""
    return 2 * round((WHITEN_HZ / (fs / nfft_for(fs)) - 1) / 2) + 1


def rates() -> Floats:
    """The candidate pulse rates in Hz: RATE_LO_HZ + i x RATE_STEP_HZ."""
    return np.array([RATE_LO_HZ + i * RATE_STEP_HZ for i in range(RATES)])


def hann(n: int) -> Floats:
    """The periodic Hann window (scipy's for spectra), written out so Dart computes the same."""
    return 0.5 - 0.5 * np.cos(2 * math.pi * np.arange(n) / n)


def interp(x: Floats, bin_hz: float, w: Floats) -> Floats:
    """Linear interpolation of the spectrum w (bin k at k x bin_hz) at each x (np.interp's formula, written out)."""
    j = np.floor(x / bin_hz).astype(np.int64)
    j = np.where((j + 1) * bin_hz <= x, j + 1, np.where(j * bin_hz > x, j - 1, j))
    x0, x1 = j * bin_hz, (j + 1) * bin_hz
    return (w[j + 1] - w[j]) / (x1 - x0) * (x - x0) + w[j]


def chain_for(fs: float) -> list[list[float]]:
    """The band-pass chain: the mains notches below 0.45 fs, two high-pass and two low-pass biquads."""
    lo = min(LOW_PASS_HZ, 0.4 * fs)
    return ([det.notch(f, NOTCH_Q, fs) for f in NOTCHES_HZ if f < 0.45 * fs]  # type: ignore[arg-type]
            + [det.highpass(HIGH_PASS_HZ, q, fs) for q in BUTTER_Q]  # type: ignore[arg-type]
            + [det.lowpass(lo, q, fs) for q in BUTTER_Q])  # type: ignore[arg-type]


def filter_channels(x: Floats, fs: float) -> Floats:
    """Each row of x (channels x samples, µV) band-passed, forward only from its first value."""
    chain = chain_for(fs)
    return np.vstack([det.run_chain(chain, row) for row in x]) if len(x) else np.zeros_like(x)


def whitened(seg: Floats, fs: float, top: int) -> Floats:
    """Bins 0..top of the whitened Welch spectrum of one channel's epoch (band-passed samples)."""
    nfft = nfft_for(fs)
    length, hop = round(SEGMENT_S * fs), round(SEGMENT_HOP_S * fs)
    h = hann(length)
    p = np.zeros(nfft // 2 + 1)
    for s in range(0, len(seg) - length + 1, hop):
        v = seg[s:s + length]
        spec = np.fft.rfft((v - v.sum() / length) * h, n=nfft)
        p += spec.real * spec.real + spec.imag * spec.imag
    wb = whiten_bins(fs)
    half = wb // 2
    w = np.zeros(top + 1)
    for k in range(top + 1):  # each bin over the mean of the wb around it (zeros below bin 0)
        w[k] = p[k] / (p[max(0, k - half):k + half + 1].sum() / wb)
    return w


def top_bin(fs: float) -> int:
    """The highest bin read: the highest multiple of the fastest rate the steps check reads, plus one."""
    return int(math.floor(SHARP[-1] * (RATE_LO_HZ + (RATES - 1) * RATE_STEP_HZ) / (fs / nfft_for(fs)))) + 2


def scores(w: Floats, fs: float) -> Floats:
    """The harmonic score of every candidate rate: the mean of the whitened power at f0, 2 f0, ... HARMONICS f0."""
    bin_hz = fs / nfft_for(fs)
    f = rates()
    acc = interp(f, bin_hz, w)
    for k in range(2, HARMONICS + 1):
        acc = acc + interp(k * f, bin_hz, w)
    return acc / HARMONICS


def at(w: Floats, fs: float, x: float) -> float:
    return float(interp(np.array([x]), fs / nfft_for(fs), w)[0])


def sure_for(channels: int) -> float:
    """The confidence a reading needs with this many usable channels."""
    return SURE_ONE + SURE_PER_DOUBLING * math.log2(channels)


def doubt(w: Floats, fs: float, f0: float) -> str | None:
    """Why a strong rhythm at f0 is no pulse reading (DECISIONS 813): "s" it looks like steps, "u" it may be twice a
    rhythm slower than the range; None: it is a reading."""
    if (at(w, fs, 0.5 * f0) + at(w, fs, 1.5 * f0)) / 2 >= HALF_MAX:
        return "s" if f0 >= STEP_RATE_HZ else "u"
    if STRIDE_LO_HZ <= f0 <= STRIDE_HI_HZ:
        odd = at(w, fs, f0) + at(w, fs, 3 * f0)
        even = at(w, fs, 2 * f0) + at(w, fs, 4 * f0)
        if odd < ODD_EVEN_MIN * even:
            return "s"
    sharp = 0.0
    for k in SHARP:
        sharp += at(w, fs, k * f0)
    return "s" if sharp / len(SHARP) >= SHARP_MAX else None


# ------------------------------------------------------------------------------------------------------ epochs


@dataclass
class Epoch:
    code: str  # r reading, n reading with its neighbours; g gap, x no usable channel, m moving, s steps, u unclear,
    #            o the odd one out
    bpm: float  # a minute; nan without a reading
    conf: float  # the reading's confidence; for u, s, o the best channel's; nan for g, x, m
    channel: int  # the channel read (index in the recording's channels); -1 without a reading
    best: float = math.nan  # the best channel's rate before the neighbours' rules, a minute (nan for g, x, m)
    channels: int = 0  # usable channels
    peaks: list[tuple[float, int, int]] | None = None  # (confidence, channel, rate index) of every channel's local
    #                                                       peaks of confidence NEAR_CONF or more (u and o only)

    @property
    def read(self) -> bool:
        return self.code in READ


def _peaks(curve: Floats, med: float, c: int) -> list[tuple[float, int, int]]:
    out = []
    for i in range(1, len(curve) - 1):
        if curve[i] >= curve[i - 1] and curve[i] >= curve[i + 1]:
            q = float(curve[i] / med)
            if q >= NEAR_CONF:
                out.append((q, c, i))
    return out


def epoch(y: Floats, raw: Floats, fs: float, missing_s: float) -> Epoch:
    """One epoch before the neighbours' rules: y band-passed and raw as recorded, channels x samples."""
    if missing_s > MAX_MISSING_S:
        return Epoch("g", math.nan, math.nan, -1)
    usable: list[int] = []
    ranges: list[float] = []
    for c in range(y.shape[0]):
        rng = float(y[c].max() - y[c].min())
        if rng < FLAT_UV or float(np.abs(raw[c]).max()) >= RAIL_UV:
            continue
        usable.append(c)
        ranges.append(rng)
    if not usable:
        return Epoch("x", math.nan, math.nan, -1)
    if det.median(ranges) > MOVING_UV:
        return Epoch("m", math.nan, math.nan, -1, channels=len(usable))
    top = top_bin(fs)
    f = rates()
    best: tuple[float, int, int] | None = None  # (confidence, channel, rate index)
    curves: list[tuple[int, Floats, float]] = []
    spectra: dict[int, Floats] = {}
    for c in usable:
        w = whitened(y[c], fs, top)
        s = scores(w, fs)
        med = det.median(s)
        i = int(np.argmax(s))
        q = float(s[i] / med)
        curves.append((c, s, med))
        spectra[c] = w
        if best is None or q > best[0]:
            best = (q, c, i)
    assert best is not None
    q, c, i = best
    bpm = float(f[i] * 60)
    n = len(usable)

    def peaks() -> list[tuple[float, int, int]]:
        return [p for cc, s, med in curves for p in _peaks(s, med, cc)]

    if q >= sure_for(n) and 0 < i < RATES - 1:
        why = doubt(spectra[c], fs, float(f[i]))
        if why == "s":
            return Epoch("s", math.nan, q, -1, best=bpm, channels=n)
        if why is None:
            return Epoch("r", bpm, q, c, best=bpm, channels=n, peaks=peaks())
    return Epoch("u", math.nan, q, -1, best=bpm, channels=n, peaks=peaks())


def neighbours(eps: list[Epoch]) -> None:
    """The neighbours' rules, in place: the odd one out, then readings with their neighbours (see the top)."""
    strong = {e: ep.bpm for e, ep in enumerate(eps) if ep.code == "r"}
    for e, b in strong.items():
        nb = [strong[j] for j in range(e - ODD_EPOCHS, e + ODD_EPOCHS + 1) if j != e and j in strong]
        if len(nb) >= ODD_NEIGHBOURS and max(nb) - min(nb) <= ODD_AGREE_BPM and abs(b - det.median(nb)) >= ODD_BPM:
            ep = eps[e]
            ep.code, ep.bpm, ep.channel = "o", math.nan, -1
    accepted = {e: ep.bpm for e, ep in enumerate(eps) if ep.code == "r"}
    f = rates()
    for e, ep in enumerate(eps):
        if ep.code not in ("u", "o"):
            continue
        nb = [accepted[j] for j in range(e - NEAR_EPOCHS, e + NEAR_EPOCHS + 1) if j != e and j in accepted]
        if not nb:
            continue
        target = det.median(nb)
        found: tuple[float, int, int] | None = None
        for q, c, i in ep.peaks or []:
            if abs(f[i] * 60 - target) <= NEAR_BPM and (found is None or q > found[0]):
                found = (q, c, i)
        if found is not None:
            ep.code, ep.bpm, ep.conf, ep.channel = "n", float(f[found[2]] * 60), found[0], found[1]


def epochs(x: Floats, fs: float, missing: Bools | None = None) -> list[Epoch]:
    """Every whole 30 s epoch of x (channels x samples, µV, every channel of the recording) from its first sample;
    missing marks samples that were filled in (gaps)."""
    n = x.shape[1]
    size = round(EPOCH_S * fs)
    y = filter_channels(x, fs)
    miss = np.zeros(n, dtype=bool) if missing is None else missing
    out = []
    for e in range(n // size):
        a = e * size
        out.append(epoch(y[:, a:a + size], x[:, a:a + size], fs, float(miss[a:a + size].sum()) / fs))
    neighbours(out)
    return out


# ---------------------------------------------------------------------------------------------------- summaries


def coverage(eps: list[Epoch]) -> float:
    """The share of epochs with a reading."""
    return sum(ep.read for ep in eps) / len(eps) if eps else 0.0


def aligned(start: float, bpm: list[float | None], at_start: float, n: int, epoch_s: float = EPOCH_S
            ) -> list[float | None]:
    """The readings of a pass whose epochs start at `start` (unix seconds), on another clock of n epochs from
    `at_start` (a sleep report's): each reading goes to the epoch holding its middle."""
    out: list[float | None] = [None] * n
    for j, b in enumerate(bpm):
        if b is None or (isinstance(b, float) and math.isnan(b)):
            continue
        e = math.floor((start + j * epoch_s + epoch_s / 2 - at_start) / epoch_s)
        if 0 <= e < n:
            out[e] = b
    return out


@dataclass
class Asleep:
    epochs: int  # asleep (N1 N2 N3 R)
    read: int  # of them with a reading
    median: float | None  # the readings' median, with at least MIN_NIGHT_READINGS
    lowest: float | None  # the lowest median of LOW_WINDOW epochs with at least LOW_MIN_READINGS readings asleep

    @property
    def share(self) -> float:
        return self.read / self.epochs if self.epochs else 0.0


def asleep(bpm: list[float | None], stages: list[str]) -> Asleep:
    """Pulse while asleep: bpm aligned with stages (aligned())."""
    n = min(len(bpm), len(stages))
    vals: list[float | None] = [bpm[i] if stages[i] in ASLEEP else None for i in range(n)]
    read = [v for v in vals if v is not None]
    lowest = None
    for a in range(0, n - LOW_WINDOW + 1):
        w = [v for v in vals[a:a + LOW_WINDOW] if v is not None]
        if len(w) >= LOW_MIN_READINGS:
            m = det.median(w)
            lowest = m if lowest is None else min(lowest, m)
    return Asleep(sum(s in ASLEEP for s in stages[:n]), len(read),
                  det.median(read) if len(read) >= MIN_NIGHT_READINGS else None, lowest)


def by_stage(bpm: list[float | None], stages: list[str]) -> dict[str, tuple[int, int, float | None]]:
    """Per stage: (epochs, readings, median reading)."""
    out: dict[str, tuple[int, int, float | None]] = {}
    for s in ("W", "N1", "N2", "N3", "R"):
        idx = [i for i in range(min(len(bpm), len(stages))) if stages[i] == s]
        r = [bpm[i] for i in idx if bpm[i] is not None]
        out[s] = (len(idx), len(r), det.median(r) if r else None)  # type: ignore[arg-type]
    return out
