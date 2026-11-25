"""Eating (chewing) from the headband's own signal: the jaw muscles under the temple electrodes (the Python reference).

Chewing tightens the jaw muscles about once or twice a second, for minutes. The temple electrodes (T3/T4 and their
neighbours) sit on those muscles, so their fast "muscle band" swells and fades at the chewing rate, on both sides
together, and the moving jaw shifts the skin under them. Talking makes short uneven bursts, a clench a steady one,
a step shakes every electrode alike: none of those is this picture. This finds it:

1. Temple channels are picked by name (TEMPLE_SITES, any letter case, the old names T3/T4 too); every other channel
   is a "back" channel. Any number of channels, any layout. With no temple channel, or a sample rate under 150 Hz
   (the muscle band needs it), nothing is read and `Found.not_read` says why.
2. Muscle: each channel through mains notches (50, 60, 100 Hz) and a 20-70 Hz band-pass (two high-pass and two
   low-pass RBJ biquads, fourth-order Butterworth each way), run forward only from the channel's first value (the
   shared detectors' convention, eeg_detectors.run_chain), so the phone's port gets the same numbers. Its size is
   the mean of |value| over each tenth of a second: a 10 Hz "envelope" in µV.
3. Jaw movement: each channel band-passed 0.7-20 Hz the same way; its size is the range within each second.
4. Windows of 10 s every 5 s. A window is not read with over 1 s missing or no usable temple channel (flat or at the
   rails). It chews when all of these hold:
   - level: the usable temples' mean envelope is at least 4 µV (the owner's quiet sitting: 2-4; chewing: 6-30);
   - rhythm: the temples' mean envelope, mean removed, Hann window, 1024-point spectrum; the highest bin from 1.0
     to 2.5 Hz is at least 8 times the median bin from 0.3 to 5 Hz (an envelope with no rhythm gives about 4),
     and at least a fifth of the 0.3-5 Hz power lies within 0.25 Hz of that rate or of twice it (one steady
     rate; the uneven bursts of talking spread their power out);
   - depth: that envelope's standard deviation is at least 0.4 of its mean (bursts with rests between them, not
     a steady clench or hum);
   - both sides: with temples on the left and on the right, their envelopes rise and fall together (correlation
     at least 0.3); skipped with one side only;
   - temples, not everything: the temples' jaw movement (median over the window's seconds) is at least 1.5 times
     the back channels'. A step shakes all electrodes alike (ratio about 1), a chewing jaw moves the temples 2-6
     times more. Skipped without a usable back channel (then walking can look like chewing: `Found.no_back`).
5. A majority of 7 windows (35 s) smooths that; runs under 3 minutes apart are one meal (bites have pauses), and a
   meal needs at least 60 s of chewing runs. Each meal gets a confidence word from how much chewing it holds.
6. Per 30 s epoch from the first sample: eating (inside a meal), not eating, or not read (`epochs`).

Every threshold is a planning value set on the owner's two labelled meals (2026-11-20, 3 and 5 labelled minutes), his
walk of the same day and three nights and a nap: far too little to trust (_local/work/eating/NOTES.md). No talking
was labelled: the rhythm rules are set against made-up uneven bursts only.
Pure functions on arrays: nothing here reads files, clocks or devices.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from numpy.typing import NDArray

import eeg_detectors as det

VERSION = "eat-v1"

MIN_FS = 150  # sample rates under this are refused: too little of the muscle band is left under half the rate
TEMPLE_SITES = ("T3", "T4", "T7", "T8", "F7", "F8", "FT7", "FT8", "TP7", "TP8", "FT9", "FT10", "T9", "T10")
#   the sites over the jaw-closing muscles (temporalis); T3/T4 are the old names of T7/T8. The mastoids (TP9, TP10)
#   are left out: behind the ear, mostly neck muscle.
MUSCLE_LO_HZ, MUSCLE_HI_HZ = 20.0, 70.0  # the muscle band (its top at most 0.4 x the sample rate)
MOVE_LO_HZ, MOVE_HI_HZ = 0.7, 20.0  # the jaw-movement band (walking.py's band)
BUTTER_Q = (1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8)))  # fourth order: two biquads
NOTCHES_HZ = (50.0, 60.0, 100.0)  # mains, both kinds, and the 50 Hz kind's harmonic (each only below 0.45 x the rate)
NOTCH_Q = 8.0
ENV_HZ = 10  # envelope points a second (each the mean |muscle band| of a tenth of a second)
WINDOW_S = 10
HOP_S = 5
NFFT = 1024  # the envelope spectrum's points: bins of 10/1024 Hz
RATE_LO_HZ, RATE_HI_HZ = 1.0, 2.5  # chewing rates looked for (60-150 chews a minute)
FLOOR_LO_HZ, FLOOR_HI_HZ = 0.3, 5.0  # the rhythm is measured against the median bin of this range
MIN_LEVEL_UV = 4.0  # a chewing window's temple envelope is at least this on average...
MIN_RHYTHM = 8.0  # ... its best chewing-rate bin at least this many times the median bin...
FOCUS_HZ = 0.25  # ... with the power gathered this close to that rate and to twice it:
MIN_FOCUS = 0.2  # at least this share of the 0.3-5 Hz power (uneven bursts, as in talking, spread theirs out)...
MIN_DEPTH = 0.4  # ... the envelope's standard deviation at least this share of its mean...
MIN_TOGETHER = 0.3  # ... left and right temples' envelopes correlated at least this (when both sides exist)...
MIN_JAW_RATIO = 1.5  # ... and the temples' jaw movement at least this many times the back channels'
SMOOTH_WINDOWS = 7  # majority over this many windows (35 s)
MEAL_GAP_S = 180.0  # chewing runs closer than this are one meal
MIN_CHEW_S = 60.0  # a meal holds at least this much chewing (its smoothed runs)
MAX_MISSING_S = 1.0  # a window with more missing time than this is not read
FLAT_UV = 1.0  # a channel whose raw window spans less than this is not used (dead or flat)
RAIL_UV = 390_000.0  # nor one at the converter's or the file's limit (eeg_detectors.RAIL_UV)
SURE_CHEW_S, LIKELY_CHEW_S = 180.0, 90.0  # a meal's chewing time: sure from 3 minutes, likely from 1.5, else unsure
EPOCH_S = 30

Floats = NDArray[np.float64]
Bools = NDArray[np.bool_]


# -------------------------------------------------------------------------------------------------- the channels


def site(name: str) -> str:
    """A channel name as its site is compared: trimmed, upper case."""
    return name.strip().upper()


def is_temple(name: str) -> bool:
    return site(name) in TEMPLE_SITES


def side(name: str) -> int:
    """0 for a left site (odd number), 1 for a right one (even)."""
    digits = "".join(ch for ch in site(name) if ch.isdigit())
    return 1 if digits and int(digits) % 2 == 0 else 0


def pick(names: list[str]) -> tuple[list[int], list[int]]:
    """Where the temple channels and the back channels (all the others) are in `names`."""
    temples = [i for i, n in enumerate(names) if is_temple(n)]
    return temples, [i for i in range(len(names)) if i not in temples]


def refusal(names: list[str], fs: float) -> str | None:
    """Why a recording cannot be read at all, in plain words; None when it can."""
    if fs != round(fs) or fs < MIN_FS:
        return f"sample rate under {MIN_FS} Hz (or not whole): the muscle band cannot be read"
    if not pick(names)[0]:
        return "no temple channel (T3, T4 or a neighbour): chewing cannot be read"
    return None


# --------------------------------------------------------------------------------------------------- the signals


def muscle_chain(fs: int) -> list[list[float]]:
    """The muscle band: the mains notches below 0.45 fs, two high-pass and two low-pass biquads."""
    hi = min(MUSCLE_HI_HZ, 0.4 * fs)
    return ([det.notch(f, NOTCH_Q, fs) for f in NOTCHES_HZ if f < 0.45 * fs]
            + [det.highpass(MUSCLE_LO_HZ, q, fs) for q in BUTTER_Q]
            + [det.lowpass(hi, q, fs) for q in BUTTER_Q])


def move_chain(fs: int) -> list[list[float]]:
    return ([det.highpass(MOVE_LO_HZ, q, fs) for q in BUTTER_Q]
            + [det.lowpass(MOVE_HI_HZ, q, fs) for q in BUTTER_Q])


def envelope(row: Floats, fs: int) -> Floats:
    """The muscle band's size, ENV_HZ points a second: point k is the mean |value| of samples
    k x fs // ENV_HZ up to (k + 1) x fs // ENV_HZ (whole-number edges, so any whole rate works)."""
    y = np.abs(det.run_chain(muscle_chain(fs), row))
    n = len(row) * ENV_HZ // fs
    edges = np.arange(n + 1) * fs // ENV_HZ
    cum = np.concatenate([[0.0], np.cumsum(y)])
    return (cum[edges[1:]] - cum[edges[:-1]]) / (edges[1:] - edges[:-1])


def second_ranges(row: Floats, fs: int, chain: list[list[float]] | None) -> Floats:
    """Highest minus lowest value within each whole second of the row (through `chain` first, when given)."""
    y = row if chain is None else det.run_chain(chain, row)
    n = len(row) // fs
    blocks = y[:n * fs].reshape(n, fs)
    return blocks.max(axis=1) - blocks.min(axis=1)


def hann(n: int) -> Floats:
    """The periodic Hann window, written out so Dart computes the same."""
    return 0.5 - 0.5 * np.cos(2 * math.pi * np.arange(n) / n)


def rhythm(e: Floats) -> tuple[float, float, float]:
    """(score, rate in Hz, focus) of one window's envelope. Score: its highest spectrum bin from RATE_LO_HZ to
    RATE_HI_HZ over the median bin from FLOOR_LO_HZ to FLOOR_HI_HZ. Focus: the share of the power from FLOOR_LO_HZ
    to FLOOR_HI_HZ that lies within FOCUS_HZ of that rate or of twice it. (0, nan, 0) for a flat envelope."""
    spec = np.fft.rfft((e - e.sum() / len(e)) * hann(len(e)), n=NFFT)
    p = spec.real * spec.real + spec.imag * spec.imag
    bin_hz = ENV_HZ / NFFT
    lo, hi = math.ceil(RATE_LO_HZ / bin_hz), math.floor(RATE_HI_HZ / bin_hz)
    f_lo, f_hi = math.ceil(FLOOR_LO_HZ / bin_hz), math.floor(FLOOR_HI_HZ / bin_hz)
    floor = det.median(p[f_lo:f_hi + 1])
    if not floor > 0:
        return 0.0, math.nan, 0.0
    k = lo + int(np.argmax(p[lo:hi + 1]))
    half = math.floor(FOCUS_HZ / bin_hz)
    near = 0.0
    for a, b in ((k - half, k + half), (2 * k - half, 2 * k + half)):  # the two ranges never overlap: k > 2 x half
        near += float(p[max(a, f_lo):min(b, f_hi) + 1].sum())
    return float(p[k] / floor), k * bin_hz, near / float(p[f_lo:f_hi + 1].sum())


def correlation(a: Floats, b: Floats) -> float:
    """Pearson's correlation of two equally long series; 0 when either is flat."""
    da, db = a - a.sum() / len(a), b - b.sum() / len(b)
    den = math.sqrt(float((da * da).sum()) * float((db * db).sum()))
    return float((da * db).sum()) / den if den > 0 else 0.0


# --------------------------------------------------------------------------------------------------- the windows


@dataclass
class Window:
    t: float  # its centre, seconds from the recording's first sample
    read: bool  # False: too much missing time, or no usable temple channel
    level: float = math.nan  # the usable temples' mean envelope, µV
    score: float = math.nan  # the rhythm: best chewing-rate bin over the median bin
    rate: float = math.nan  # that bin, Hz
    focus: float = math.nan  # the share of the envelope's 0.3-5 Hz power near that rate and twice it
    depth: float = math.nan  # the envelope's standard deviation over its mean
    together: float | None = None  # left and right temples' correlation; None with one side only
    jaw_ratio: float | None = None  # temples' jaw movement over the back channels'; None without a usable back one
    temples: int = 0  # usable temple channels
    backs: int = 0  # usable back channels

    @property
    def chews(self) -> bool:
        return (self.read and self.level >= MIN_LEVEL_UV and self.score >= MIN_RHYTHM
                and self.focus >= MIN_FOCUS and self.depth >= MIN_DEPTH
                and (self.together is None or self.together >= MIN_TOGETHER)
                and (self.jaw_ratio is None or self.jaw_ratio >= MIN_JAW_RATIO))


@dataclass
class Meal:
    first: int  # window indices, inclusive
    last: int
    chew_s: float  # the time of its chewing runs
    rate: float | None  # median chewing rate of its chewing windows, chews a minute
    score: float | None  # their median rhythm score
    confidence: str  # sure | likely | unsure

    def start_s(self, ws: list[Window]) -> float:
        return ws[self.first].t - HOP_S / 2

    def end_s(self, ws: list[Window]) -> float:
        return ws[self.last].t + HOP_S / 2


@dataclass
class Found:
    """What the detector found in a recording: its windows, the smoothed chewing flag and the meals."""
    windows: list[Window]
    smoothed: list[bool] = field(default_factory=list)
    meals: list[Meal] = field(default_factory=list)
    not_read: str | None = None  # why nothing was read (no temple channel, sample rate too low)
    no_back: bool = False  # no back channel: the temples-against-the-back rule was skipped


def _mean(values: list[float]) -> float:
    return sum(values) / len(values)


@dataclass
class _Signals:
    """What every window is cut from: per temple channel the envelope, per channel and second the jaw movement,
    the raw range and the highest |raw value|."""
    names: list[str]
    temples: list[int]
    backs: list[int]
    env: dict[int, Floats]
    move: list[Floats]
    span: list[Floats]
    peak: list[Floats]


def _signals(x: Floats, fs: int, names: list[str]) -> _Signals:
    temples, backs = pick(names)
    chain = move_chain(fs)
    return _Signals(names, temples, backs, {c: envelope(x[c], fs) for c in temples},
                    [second_ranges(row, fs, chain) for row in x], [second_ranges(row, fs, None) for row in x],
                    [_second_peaks(row, fs) for row in x])


def _second_peaks(row: Floats, fs: int) -> Floats:
    """The highest |value| within each whole second of the row."""
    n = len(row) // fs
    return np.abs(row[:n * fs]).reshape(n, fs).max(axis=1)


def _window(sig: _Signals, t: float, s0: int) -> Window:
    """The window starting at whole second s0 (its envelope points start at s0 x ENV_HZ)."""
    secs = slice(s0, s0 + WINDOW_S)
    ok = [c for c in range(len(sig.names))
          if sig.span[c][secs].max() >= FLAT_UV and sig.peak[c][secs].max() < RAIL_UV]
    ts = [c for c in sig.temples if c in ok]
    bs = [c for c in sig.backs if c in ok]
    if not ts:
        return Window(t, False)
    es = {c: sig.env[c][s0 * ENV_HZ:(s0 + WINDOW_S) * ENV_HZ] for c in ts}
    e = sum(es.values()) / len(ts)
    level = float(e.sum()) / len(e)
    score, best, focus = rhythm(e)
    d = e - level
    depth = math.sqrt(float((d * d).sum()) / len(e)) / level if level > 0 else 0.0
    left = [es[c] for c in ts if side(sig.names[c]) == 0]
    right = [es[c] for c in ts if side(sig.names[c]) == 1]
    together = correlation(sum(left) / len(left), sum(right) / len(right)) if left and right else None
    jaw = None
    if bs:
        back = _mean([det.median(sig.move[c][secs]) for c in bs])
        temple = _mean([det.median(sig.move[c][secs]) for c in ts])
        jaw = temple / back if back > 0 else math.inf
    return Window(t, True, level, score, best, focus, depth, together, jaw, len(ts), len(bs))


def windows(x: Floats, fs: float, names: list[str], missing: Bools | None = None) -> list[Window]:
    """The 10 s windows every 5 s of x (channels x samples, µV, every channel of the recording, `names` in the same
    order), from its first sample; missing marks samples that were filled in (gaps). Every window is unread when
    `refusal` gives a reason."""
    n = x.shape[1]
    win, hop = round(WINDOW_S * fs), round(HOP_S * fs)
    centres = [(s + win / 2) / fs for s in range(0, n - win + 1, hop)]
    if refusal(names, fs) is not None:
        return [Window(t, False) for t in centres]
    sig = _signals(x, int(fs), names)
    miss = np.zeros(n, dtype=bool) if missing is None else missing
    cum = np.concatenate([[0], np.cumsum(miss)])
    out: list[Window] = []
    for i, t in enumerate(centres):
        if cum[i * hop + win] - cum[i * hop] > MAX_MISSING_S * fs:
            out.append(Window(t, False))
        else:
            out.append(_window(sig, t, i * HOP_S))  # HOP_S and the rate are whole: the window starts on a second
    return out


# ----------------------------------------------------------------------------------------------------- the meals


def majority(flags: list[bool]) -> list[bool]:
    """Each flag replaced by the majority of the SMOOTH_WINDOWS around it (fewer at the ends)."""
    half = SMOOTH_WINDOWS // 2
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


def confidence(chew_s: float) -> str:
    return "sure" if chew_s >= SURE_CHEW_S else "likely" if chew_s >= LIKELY_CHEW_S else "unsure"


def find(ws: list[Window], names: list[str] | None = None, fs: float | None = None) -> Found:
    """The meals in the windows (see the top of the file). `names` and `fs`, when given, fill in why nothing was
    read and whether the back channels were missing."""
    found = Found(ws)
    if names is not None and fs is not None:
        found.not_read = refusal(names, fs)
        found.no_back = found.not_read is None and not pick(names)[1]
    found.smoothed = majority([w.chews for w in ws])
    gap_windows = MEAL_GAP_S / HOP_S
    groups: list[list[tuple[int, int]]] = []
    for a, b in runs(found.smoothed):
        between = range(groups[-1][-1][1] + 1, a) if groups else range(0)
        if groups and len(between) < gap_windows and all(ws[i].read for i in between):
            groups[-1].append((a, b))
        else:
            groups.append([(a, b)])
    for g in groups:
        chew_s = sum((b - a + 1) * HOP_S for a, b in g)
        if chew_s < MIN_CHEW_S:
            continue
        clear = [ws[i] for a, b in g for i in range(a, b + 1) if ws[i].chews]
        found.meals.append(Meal(g[0][0], g[-1][1], float(chew_s),
                                det.median([w.rate * 60 for w in clear]) if clear else None,
                                det.median([w.score for w in clear]) if clear else None, confidence(chew_s)))
    return found


def detect(x: Floats, fs: float, names: list[str], missing: Bools | None = None) -> Found:
    """windows() then find(): everything about one recording."""
    return find(windows(x, fs, names, missing), names, fs)


# ---------------------------------------------------------------------------------------------------- per epoch


def epochs(found: Found, count: int) -> list[bool | None]:
    """Per 30 s epoch from the first sample (`count` of them): True when at least half of it is inside a meal,
    False when not, None when none of the windows centred in it was read."""
    ws = found.windows
    inside = [False] * len(ws)
    for m in found.meals:
        for i in range(m.first, m.last + 1):
            inside[i] = True
    groups: list[list[int]] = [[] for _ in range(count)]
    for i, w in enumerate(ws):
        k = int(w.t // EPOCH_S)
        if k < count:
            groups[k].append(i)
    out: list[bool | None] = []
    for idx in groups:
        if not any(ws[i].read for i in idx):
            out.append(None)
        else:
            out.append(sum(inside[i] for i in idx) * 2 >= len(idx))
    return out
