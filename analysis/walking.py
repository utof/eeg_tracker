"""Walking, pace and estimated steps from the headband's own signal, with no motion sensor (the Python reference).

Every step shakes the headband a little, and that shows in the EEG as a rhythm at the step rate and its harmonics
(research: _local notes 2026-11-20 "steps and activity from EEG"; docs/evidence/walking.md). This finds it:

1. Every channel the recording's header names (any number, any layout) is band-passed 0.7-20 Hz: two high-pass and
   two low-pass RBJ biquads (fourth-order Butterworth each way), run forward only from the channel's first value,
   the shared detectors' convention (eeg_detectors.run_chain), so the phone's port gets the same numbers.
2. Windows of 10 s every 5 s. Per usable channel (not flat, not at the rails): the window's mean removed, a Hann
   window, the power spectrum (zero-padded to 0.0305 Hz bins, 8192 points at 250 Hz), "whitened" by dividing each
   bin by the mean of the 41 bins around it (1.25 Hz), so a broad hump does not look like a rhythm.
3. The harmonic score of each candidate step rate f from 1.2 to 3.4 Hz (72-204 steps a minute, 0.02 Hz apart):
   W(f) + 0.5 W(2f), averaged over the usable channels. The best rate is the window's pace; the score is its value
   over the median of all candidates (about 1-2 when nothing walks, 6-12 on the owner's walk of 2026-11-20).
4. A window walks when its score is at least 4, its pace 90-200 steps a minute, and it is no pulse: the shake is
   walking-sized (the channels' median band-passed range at least 300 µV; the owner's walk had 420-1100, a sleeping
   pulse 60-450) and the rate is not the 2nd or 3rd harmonic of a slower one (the whitened power at a third and two
   thirds of the pace, the pulse's own family, under 2.5). A majority of 7 windows (35 s)
   smooths that; runs of at least 30 s are walking stretches, and a stretch whose pace holds at 150 or more for at
   least a minute is running there. Gaps of at least 1 minute between stretches are stops; stretches less than
   15 minutes apart are one walk.
5. Steps: each window of a stretch whose own rhythm is clear adds pace x 5 s; the others add nothing (an honest
   floor, not a guess). A confidence word per stretch from its median score.
6. Per clock minute, the phone's own step counter (logged in the recording's `.log` while recording) wins wherever
   it counted steps; each minute says where its steps came from.

Every threshold is a planning value (DECISIONS 800-809), set on the owner's one walk; the phone's minutes check the
pace and the totals (`check`) before the app calls headband steps anything but "not yet checked". The minute rules
(the phone's steps per minute, the check, the day numbers) are in walk_minutes.py, standard library only, so the
laptop's export (scripts/day_summary.py) uses the very same ones.
The phone has a line-by-line port in app/lib/walking/ (walking_cross_check_test.dart compares them).
Pure functions on arrays: nothing here reads files, clocks or devices.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from numpy.typing import NDArray

import eeg_detectors as det
from walk_minutes import (CHECK_MIN_MINUTES, CHECK_PACE_SHARE, CHECK_RIGHT_SHARE, CHECK_TOTAL_SHARE,  # noqa: F401
                          PHONE_MAX_GAP_S, PHONE_WALK_STEPS, Check, Minute, check, phone_minutes)

VERSION = "walk-v2"  # v2: a walking-sized shake and no pulse family (sleep false positives; DECISIONS 801)

WINDOW_S = 10.0
HOP_S = 5.0
HIGH_PASS_HZ = 0.7
LOW_PASS_HZ = 20.0
BUTTER_Q = (1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8)))  # fourth order: two biquads
BIN_HZ = 250 / 8192  # spectrum bins at most this wide (8192 points at 250 Hz)
WHITEN_HZ = 41 * BIN_HZ  # the whitening's mean spans this (41 bins at 250 Hz)
PACE_LO_HZ, PACE_STEP_HZ, PACE_RATES = 1.2, 0.02, 111  # candidate step rates 1.2, 1.22, ... 3.4 Hz
HARMONIC = 0.5  # weight of the second harmonic
SCORE_WALK = 4.0  # a window walks from this score...
PACE_MIN_SPM, PACE_MAX_SPM = 90.0, 200.0  # ... at a pace in this range (steps a minute)...
MIN_SHAKE_UV = 300.0  # ... with a walking-sized shake: the channels' median band-passed range at least this...
MAX_THIRDS = 2.5  # ... and no pulse family: the whitened power at a third and two thirds of the pace under this
SMOOTH_WINDOWS = 7  # majority over this many windows (35 s)
MIN_STRETCH_S = 30.0  # shorter runs are not walking
MIN_STOP_S = 60.0  # a gap of at least this between two stretches of one walk is a stop
WALK_GAP_S = 900.0  # stretches closer than this are one walk (a long bench stop is still the same walk)
RUN_SPM = 150.0  # running: a pace at or over this...
MIN_RUN_S = 60.0  # ... held this long (the same 7-window majority inside a stretch)
MAX_MISSING_S = 1.0  # a window with more missing time than this is not read
FLAT_UV = 1.0  # a channel whose band-passed window spans less than this is not used (dead or flat)
RAIL_UV = 390_000.0  # nor one at the converter's or the file's limit (eeg_detectors.RAIL_UV)
SURE_SCORE, LIKELY_SCORE = 6.0, 5.0  # a stretch's median score: sure from 6, likely from 5, else unsure

Floats = NDArray[np.float64]
Bools = NDArray[np.bool_]


# ------------------------------------------------------------------------------------------------- the spectrum


def nfft_for(fs: float) -> int:
    """The smallest power of two whose bins are at most BIN_HZ wide (8192 at 250 Hz)."""
    n = 1
    while fs / n > BIN_HZ * (1 + 1e-12):
        n *= 2
    return n


def whiten_bins(fs: float) -> int:
    """The odd number of bins nearest to WHITEN_HZ (41 at 250 Hz)."""
    return 2 * round((WHITEN_HZ / (fs / nfft_for(fs)) - 1) / 2) + 1


def pace_rates() -> Floats:
    return PACE_LO_HZ + np.arange(PACE_RATES) * PACE_STEP_HZ


def hann(n: int) -> Floats:
    """The periodic Hann window (scipy's for spectra), written out so Dart computes the same."""
    return 0.5 - 0.5 * np.cos(2 * math.pi * np.arange(n) / n)


def interp(x: float, bin_hz: float, w: Floats) -> float:
    """Linear interpolation of the spectrum w (bin k at k * bin_hz) at x (np.interp's formula, written out)."""
    j = int(math.floor(x / bin_hz))
    if (j + 1) * bin_hz <= x:
        j += 1
    elif j * bin_hz > x:
        j -= 1
    x0, x1 = j * bin_hz, (j + 1) * bin_hz
    return float((w[j + 1] - w[j]) / (x1 - x0) * (x - x0) + w[j])


def filter_channels(x: Floats, fs: float) -> Floats:
    """Each row of x (channels x samples, µV) band-passed 0.7-20 Hz, forward only from its first value."""
    lo = min(LOW_PASS_HZ, 0.4 * fs)
    chain = [det.highpass(HIGH_PASS_HZ, q, fs) for q in BUTTER_Q] + [det.lowpass(lo, q, fs) for q in BUTTER_Q]
    return np.vstack([det.run_chain(chain, row) for row in x]) if len(x) else np.zeros_like(x)


@dataclass
class Window:
    t: float  # its centre, seconds from the recording's first sample
    score: float  # nan when not read
    pace: float  # steps a minute at the best rate; nan when not read
    amp: float  # median band-passed range of the usable channels, µV
    channels: int  # usable channels
    read: bool  # False: too much missing time, or no usable channel
    thirds: float = math.nan  # mean whitened power at a third and two thirds of the pace (a pulse's family)

    @property
    def walks(self) -> bool:
        return (self.read and self.score >= SCORE_WALK and PACE_MIN_SPM <= self.pace <= PACE_MAX_SPM
                and self.amp >= MIN_SHAKE_UV and self.thirds < MAX_THIRDS)


def window_score(y: Floats, raw: Floats, fs: float) -> tuple[float, int, float, int, float]:
    """(score, best rate's index, median range, usable channels, thirds) of one window: y the band-passed samples and
    raw the samples as recorded, channels x window. Score nan without a usable channel."""
    win = y.shape[1]
    nfft = nfft_for(fs)
    bin_hz = fs / nfft
    wb = whiten_bins(fs)
    half = wb // 2
    rates = pace_rates()
    lo = max(0, int(math.floor(rates[0] / 3 / bin_hz)))  # the bins whitened: from a third of the slowest rate...
    hi = int(math.floor(2 * rates[-1] / bin_hz)) + 1  # ... to twice the fastest
    h = hann(win)
    tot = np.zeros(PACE_RATES)
    wsum = np.zeros(hi + 1)
    ranges: list[float] = []
    for c in range(y.shape[0]):
        seg = y[c]
        rng = float(seg.max() - seg.min())
        if rng < FLAT_UV or float(np.abs(raw[c]).max()) >= RAIL_UV:
            continue
        spec = np.fft.rfft((seg - seg.sum() / win) * h, n=nfft)
        p = spec.real * spec.real + spec.imag * spec.imag
        w = np.zeros(hi + 1)
        for k in range(lo, hi + 1):  # each bin over the mean of the wb around it (zeros below bin 0)
            w[k] = p[k] / (p[max(0, k - half):k + half + 1].sum() / wb)
        for i, f in enumerate(rates):
            tot[i] += interp(f, bin_hz, w) + HARMONIC * interp(2 * f, bin_hz, w)
        wsum += w
        ranges.append(rng)
    if not ranges:
        return math.nan, -1, math.nan, 0, math.nan
    tot /= len(ranges)
    k = int(np.argmax(tot))
    f0 = rates[k]
    thirds = (interp(f0 / 3, bin_hz, wsum) + interp(2 * f0 / 3, bin_hz, wsum)) / 2 / len(ranges)
    return float(tot[k] / np.median(tot)), k, det.median(ranges), len(ranges), thirds


def windows(x: Floats, fs: float, missing: Bools | None = None) -> list[Window]:
    """The 10 s windows every 5 s of x (channels x samples, µV, every channel of the recording), from its first
    sample; missing marks samples that were filled in (gaps)."""
    n = x.shape[1]
    win, hop = round(WINDOW_S * fs), round(HOP_S * fs)
    y = filter_channels(x, fs)
    miss = np.zeros(n, dtype=bool) if missing is None else missing
    cum = np.concatenate([[0], np.cumsum(miss)])
    rates = pace_rates()
    out: list[Window] = []
    for s in range(0, n - win + 1, hop):
        t = (s + win / 2) / fs
        if cum[s + win] - cum[s] > MAX_MISSING_S * fs:
            out.append(Window(t, math.nan, math.nan, math.nan, 0, False))
            continue
        score, k, amp, used, thirds = window_score(y[:, s:s + win], x[:, s:s + win], fs)
        if used == 0:
            out.append(Window(t, math.nan, math.nan, math.nan, 0, False))
            continue
        out.append(Window(t, score, float(rates[k] * 60), amp, used, True, thirds))
    return out


# -------------------------------------------------------------------------------------------------- the stretches


def majority(flags: list[bool], width: int = SMOOTH_WINDOWS) -> list[bool]:
    """Each flag replaced by the majority of the `width` around it (fewer at the ends)."""
    half = width // 2
    out = []
    for i in range(len(flags)):
        w = flags[max(0, i - half):i + half + 1]
        out.append(sum(w) * 2 > len(w))
    return out


def runs(flags: list[bool]) -> list[tuple[int, int]]:
    """(first, last) of each run of True."""
    out: list[tuple[int, int]] = []
    a = None
    for i, f in enumerate(flags):
        if f and a is None:
            a = i
        if not f and a is not None:
            out.append((a, i - 1))
            a = None
    if a is not None:
        out.append((a, len(flags) - 1))
    return out


def confidence(score: float) -> str:
    return "sure" if score >= SURE_SCORE else "likely" if score >= LIKELY_SCORE else "unsure"


@dataclass
class Stretch:
    first: int  # window indices, inclusive
    last: int
    kind: str  # walking | running | stopped
    steps: float = 0.0
    pace: float | None = None  # median pace of its clear windows
    score: float | None = None  # their median score
    confidence: str | None = None

    def seconds(self, hop: float = HOP_S) -> float:
        return (self.last - self.first + 1) * hop


@dataclass
class Walk:
    stretches: list[Stretch]  # in time order: walking, running and stopped
    walking_s: float = 0.0  # walking and running
    stopped_s: float = 0.0
    steps: float = 0.0
    pace: float | None = None


@dataclass
class Found:
    """What the detector found in a recording: its windows, the moving stretches and the walks they make."""
    windows: list[Window]
    smoothed: list[bool]  # the walking flag after the majority
    moving: list[Stretch]  # walking and running stretches, in time order
    walks: list[Walk] = field(default_factory=list)


def _summary(ws: list[Window], idx: list[int]) -> tuple[float, float | None, float | None]:
    clear = [i for i in idx if ws[i].walks]
    steps = sum(ws[i].pace / 60 * HOP_S for i in clear)
    if not clear:
        return steps, None, None
    return steps, det.median([ws[i].pace for i in clear]), det.median([ws[i].score for i in clear])


def _stretch(ws: list[Window], a: int, b: int, kind: str) -> Stretch:
    steps, pace, score = _summary(ws, list(range(a, b + 1)))
    return Stretch(a, b, kind, steps, pace, score, None if score is None else confidence(score))


def _split_running(ws: list[Window], a: int, b: int) -> list[Stretch]:
    """A walking stretch cut where its pace held at RUN_SPM or more for at least MIN_RUN_S."""
    fast = majority([ws[i].walks and ws[i].pace >= RUN_SPM for i in range(a, b + 1)])
    min_run = math.ceil(MIN_RUN_S / HOP_S)
    parts: list[Stretch] = []
    at = a
    for r0, r1 in runs(fast):
        if r1 - r0 + 1 < min_run:
            continue
        if a + r0 > at:
            parts.append(_stretch(ws, at, a + r0 - 1, "walking"))
        parts.append(_stretch(ws, a + r0, a + r1, "running"))
        at = a + r1 + 1
    if at <= b:
        parts.append(_stretch(ws, at, b, "walking"))
    return parts


def find(ws: list[Window]) -> Found:
    """The stretches and walks in the windows (see the top of the file)."""
    smoothed = majority([w.walks for w in ws])
    min_len = math.ceil(MIN_STRETCH_S / HOP_S)
    moving: list[Stretch] = []
    for a, b in runs(smoothed):
        if b - a + 1 >= min_len:
            moving.extend(_split_running(ws, a, b))
    found = Found(ws, smoothed, moving)
    gap_windows = WALK_GAP_S / HOP_S
    stop_windows = math.ceil(MIN_STOP_S / HOP_S)
    walk: list[Stretch] = []

    def close() -> None:
        if not walk:
            return
        moved = [s for s in walk if s.kind != "stopped"]
        idx = [i for s in moved for i in range(s.first, s.last + 1)]
        steps, pace, _ = _summary(ws, idx)
        found.walks.append(Walk(list(walk), sum(s.seconds() for s in moved),
                                sum(s.seconds() for s in walk if s.kind == "stopped"), steps, pace))
        walk.clear()

    for s in moving:
        if walk:
            gap = s.first - walk[-1].last - 1
            if gap >= gap_windows:
                close()
            elif gap >= stop_windows and all(ws[i].read for i in range(walk[-1].last + 1, s.first)):
                walk.append(Stretch(walk[-1].last + 1, s.first - 1, "stopped"))
        walk.append(s)
    close()
    return found


# ---------------------------------------------------------------------------------------------------- per minute


def minutes(found: Found, start_unix: float, phone: dict[int, float] | None = None) -> list[Minute]:
    """Per clock minute with walking or phone steps: the headband's and the phone's numbers, and which one counts."""
    phone = phone or {}
    moving = {}
    for s in found.moving:
        for i in range(s.first, s.last + 1):
            moving[i] = s.kind
    rows: dict[int, dict] = {}
    for i, kind in moving.items():
        w = found.windows[i]
        m = int(math.floor((start_unix + w.t) / 60)) * 60
        r = rows.setdefault(m, dict(walk=0.0, run=0.0, steps=0.0, paces=[]))
        r["walk"] += HOP_S
        if kind == "running":
            r["run"] += HOP_S
        if w.walks:
            r["steps"] += w.pace / 60 * HOP_S
            r["paces"].append(w.pace)
    out = []
    for m in sorted(set(rows) | {k for k, v in phone.items() if v > 0}):
        r = rows.get(m, dict(walk=0.0, run=0.0, steps=0.0, paces=[]))
        p = phone.get(m)
        if p is not None and p > 0:
            steps, source = p, "phone"
        elif r["steps"] > 0:
            steps, source = r["steps"], "headband"
        else:
            steps, source = 0.0, ""
        walking = 60.0 if p is not None and p >= PHONE_WALK_STEPS else r["walk"]
        out.append(Minute(m, r["walk"], r["run"], r["steps"], det.median(r["paces"]) if r["paces"] else None, p,
                          steps, source, walking))
    return out
