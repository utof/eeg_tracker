"""What the electrodes see, and when you drift off (the Python reference; ROADMAP next step 3).

Pure functions on arrays: BrainBit channels O1 O2 T3 T4 at 250 Hz in µV, each channel being the
electrode minus the forehead reference (DECISIONS 78). Nothing here reads files, clocks or devices.

The phone app has a line-by-line port in `app/lib/detectors/` with the same constants. To make that
possible, everything here is causal and streaming-shaped even though it runs on whole arrays:

- every filter is a chain of second-order sections (RBJ cookbook formulas, written out below so Dart
  computes the same coefficients) run forward only, starting from the channel's first value;
- decisions happen per sample (blinks, eye movements: a fixed 0.3 s look-ahead) or per whole second
  (quality, muscle, movement, alpha) or per 30 s epoch counted from the start of the input;
- percentiles and medians use the same interpolation as `app/lib/feedback/features.dart`.

Missing samples (Bluetooth gaps) arrive as held values with `missing` set, as in the BDF files; the
second they fall in is a gap second and is never used.

All thresholds are planning values tuned on the owner's first night, morning sleep and check-in
(2026-11-18); `docs/detectors.md` lists what each one is based on and what still needs the setup test.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Literal

import numpy as np
from numpy.typing import NDArray
from scipy.ndimage import minimum_filter1d
from scipy.signal import sosfilt

FS = 250
CHANNELS = ("O1", "O2", "T3", "T4")
BACK = (0, 1)
SIDE = (2, 3)
EPOCH_S = 30

# ---- signal quality, per second and per 30 s epoch ----
FLAT_UV = 1.4  # raw range in a second under this: the channel is flat (dead or saturated)
RAIL_UV = 390_000.0  # |raw| at or above this: at the converter's or the file's limit (BDF range is ±400 mV)
QUALITY_HP_HZ = 2.0  # the quality signal: high-passed at 2 Hz, so deep-sleep slow waves stay small
EXTREME_UV = 500.0  # quality-signal range in a second over this: not brain
CLEAN_BACK_UV = 250.0  # back channel usable for alpha only under this range
MOVE_UV = 200.0  # movement: at least MOVE_CHANNELS channels jump past this in the same second
MOVE_CHANNELS = 3
MAX_GAP_S = 5  # epoch with more gap seconds than this: missing (as `score_sleep.py` marks 'gap')
BAD_CHANNEL_S = 3  # a channel with more bad seconds than this in an epoch is unusable for that epoch
DEGRADED_MOVE_S = 3  # movement seconds that degrade an epoch
DEGRADED_MUSCLE_S = 15  # muscle seconds that degrade an epoch (half of it)

# ---- blinks: a dip on all four channels, cancelled in T3-T4 (DECISIONS 78) ----
BLINK_HP_HZ = 0.5
BLINK_LP_HZ = 15.0
BLINK_HALF_S = 0.3  # a blink is the lowest point of the 4-channel mean within ±0.3 s
BLINK_BASE_S = (0.6, 0.3)  # its baseline: the median of the mean from 0.6 s to 0.3 s before
BLINK_MIN_UV = 50.0  # depth of the 4-channel mean (cued blinks: 80-130 µV; eyes-closed dips: 30-60)
BLINK_EACH_UV = 15.0  # depth on every channel
BLINK_T34_SHARE = 0.5  # |T3 depth - T4 depth| at most this share of the mean depth
BLINK_WIDTH_S = (0.04, 0.2)  # time under half depth (cued blinks: 0.05-0.18 s; eyes-closed dips wider)
BLINK_MAX_UV = 400.0  # range of any channel around it (more is movement)

# ---- horizontal eye movements: a fast step in T3-T4 (blinks cancel there) ----
EYE_STEP_S = 0.1  # the change of T3-T4 over 0.1 s
EYE_HALF_S = 0.3  # the largest change within ±0.3 s
EYE_MIN_UV = 40.0  # planning value: about 15 degrees at 2-3 µV per degree, until the setup test's glances
EYE_COMMON_SHARE = 0.5  # the 4-channel mean may change at most this share of the T3-T4 change
EYE_BALANCE = 0.5  # T3 and T4 move in opposite directions, the smaller at least half the larger
EYE_MAX_UV = 400.0

# ---- slow eye rolls: 0.2-0.7 Hz in T3-T4 ----
SEM_BAND = (0.2, 0.7)
SEM_WINDOW_S = 10
SEM_X = 4.0  # the 10 s mean over 4x the lights-off level

# ---- jaw and muscle: 55-120 Hz at T3/T4, notches at 50 and 100 Hz (DECISIONS 65) ----
MUSCLE_BAND = (55.0, 120.0)
NOTCHES_HZ = (50.0, 100.0)
NOTCH_Q = 8.0
MUSCLE_REST_S = 120  # personal baseline: the 20th percentile of the last 2 minutes
MUSCLE_REST_PCT = 0.2
MUSCLE_REST_MIN_S = 30
MUSCLE_X = 4.0  # a muscle second: T3/T4 power over 4x the baseline (+6 dB)
MUSCLE_JOIN_S = 2  # burst seconds closer than this are one burst
MUSCLE_BOTH_X = 2.0  # a jaw burst: both sides over 2x their baselines in one of its seconds

# ---- alpha and theta at O1/O2 ----
ALPHA_BAND = (8.0, 12.0)
THETA_BAND = (4.0, 7.0)

# ---- drift-off (DECISIONS 62): lights-off baseline, faded alpha, timers ----
BASELINE_S = 60  # the first 60 clean seconds after lights off, eyes closed
FADE_X = 0.5  # alpha under half the baseline
FADE_SHARE = 0.5  # in over half of an epoch's clean seconds
MIN_CLEAN_S = 10  # epochs with fewer clean seconds are skipped: they neither extend nor break a run
DROWSY_EPOCHS = 2  # 1 min of faded alpha
ASLEEP_EPOCHS = 6  # 3 min of faded alpha: "probably asleep"
WAKE_EPOCHS = 2  # 1 min of alpha back: awake again
MOVE_BREAK_S = 3  # an epoch with this much movement is not faded
EYES_OPEN_BLINKS = 2  # an epoch with this many blinks has open eyes: not faded (until asleep)
SOUND_FADE_S = 150  # sleep sounds fade over 2.5 min once probably asleep
SOUND_CAP_S = 45 * 60  # and stop 45 min after lights off whatever the detector says
DREAM_WINDOW_MIN = (10.0, 20.0)  # the usual time to fall asleep before there are 3 own nights (planning)

SQRT1_2 = math.sqrt(0.5)
Q_PAIR = math.sqrt(math.sqrt(2) - 1)  # two equal band-pass stages: -3 dB at lo and hi

Floats = NDArray[np.float64]
Bools = NDArray[np.bool_]
Quality = Literal["good", "degraded", "missing"]
DriftState = Literal["baseline", "awake", "drowsy", "asleep"]
BurstKind = Literal["jaw", "one-sided", "movement"]


# ---------------------------------------------------------------------------------------------------------
# Filters: RBJ audio-EQ cookbook biquads, [b0, b1, b2, a1, a2] divided by a0 (same as features.dart)
# ---------------------------------------------------------------------------------------------------------


def _norm(b0: float, b1: float, b2: float, a0: float, a1: float, a2: float) -> list[float]:
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]


def highpass(f0: float, q: float = SQRT1_2, fs: int = FS) -> list[float]:
    w = 2 * math.pi * f0 / fs
    al, cw = math.sin(w) / (2 * q), math.cos(w)
    return _norm((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + al, -2 * cw, 1 - al)


def lowpass(f0: float, q: float = SQRT1_2, fs: int = FS) -> list[float]:
    w = 2 * math.pi * f0 / fs
    al, cw = math.sin(w) / (2 * q), math.cos(w)
    return _norm((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + al, -2 * cw, 1 - al)


def bandpass(f0: float, q: float, fs: int = FS) -> list[float]:
    """0 dB at f0."""
    w = 2 * math.pi * f0 / fs
    al, cw = math.sin(w) / (2 * q), math.cos(w)
    return _norm(al, 0, -al, 1 + al, -2 * cw, 1 - al)


def notch(f0: float, q: float, fs: int = FS) -> list[float]:
    w = 2 * math.pi * f0 / fs
    al, cw = math.sin(w) / (2 * q), math.cos(w)
    return _norm(1, -2 * cw, 1, 1 + al, -2 * cw, 1 - al)


def band_pair(lo: float, hi: float) -> list[list[float]]:
    """Two equal band-pass stages, -3 dB at about lo and hi."""
    f0 = math.sqrt(lo * hi)
    c = bandpass(f0, Q_PAIR * f0 / (hi - lo))
    return [c, list(c)]


def chains() -> dict[str, list[list[float]]]:
    """Every filter chain the detectors use, by name (the Dart port builds the same list)."""
    return {
        "blink": [highpass(BLINK_HP_HZ), lowpass(BLINK_LP_HZ)],
        "quality": [highpass(QUALITY_HP_HZ)],
        "alpha": band_pair(*ALPHA_BAND),
        "theta": band_pair(*THETA_BAND),
        "muscle": [notch(f, NOTCH_Q) for f in NOTCHES_HZ] + band_pair(*MUSCLE_BAND),
        "sem": band_pair(*SEM_BAND),
    }


def run_chain(chain: list[list[float]], x: Floats) -> Floats:
    """Forward-only filtering, starting from the first value (so a large electrode offset does not ring).

    Same arithmetic as a transposed direct form II biquad updated sample by sample.
    """
    sos = np.array([[c[0], c[1], c[2], 1.0, c[3], c[4]] for c in chain])
    v = np.asarray(x, dtype=np.float64)
    return np.asarray(sosfilt(sos, v - v[0]), dtype=np.float64)


# ---------------------------------------------------------------------------------------------------------
# Small helpers shared with the Dart port
# ---------------------------------------------------------------------------------------------------------


def percentile(values: list[float] | Floats, p: float) -> float:
    """Linear interpolation between the sorted values (features.dart `percentile`)."""
    s = sorted(float(v) for v in values)
    if not s:
        return math.nan
    i = (len(s) - 1) * p
    lo = math.floor(i)
    return s[lo] + (s[lo + 1] - s[lo]) * (i - lo) if lo + 1 < len(s) else s[lo]


def median(values: list[float] | Floats) -> float:
    return percentile(values, 0.5)


def _seconds(v: Floats, n_s: int) -> Floats:
    return v[: n_s * FS].reshape(n_s, FS)


def _mean_sq(v: Floats, n_s: int) -> Floats:
    """Mean of squares per second, summed in sample order (as the streaming port does)."""
    sq = _seconds(v, n_s) ** 2
    out = np.zeros(n_s)
    for j in range(FS):
        out += sq[:, j]
    return out / FS


def _check_input(x: Floats, missing: Bools | None) -> tuple[Floats, Bools]:
    a = np.asarray(x, dtype=np.float64)
    if a.ndim != 2 or a.shape[0] != len(CHANNELS):
        raise ValueError(f"x must be (4, n) for {CHANNELS}, got {a.shape}")
    if not np.all(np.isfinite(a)):
        raise ValueError("x has NaN or infinite values; pass held values with `missing` instead")
    m = np.zeros(a.shape[1], bool) if missing is None else np.asarray(missing, dtype=bool)
    if m.shape != (a.shape[1],):
        raise ValueError("missing must have one flag per sample")
    return a, m


# ---------------------------------------------------------------------------------------------------------
# Per-second features
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Seconds:
    """One value per whole second of input (index k = samples k*250 .. k*250+249)."""

    gap: Bools  # (n_s,) a missing sample in this second
    flat: Bools  # (4, n_s)
    railed: Bools  # (4, n_s)
    qrange: Floats  # (4, n_s) range of the 2 Hz high-passed signal, µV
    alpha: Floats  # (2, n_s) O1, O2 mean power 8-12 Hz, µV²
    theta: Floats  # (2, n_s) O1, O2 mean power 4-7 Hz, µV²
    muscle: Floats  # (4, n_s) mean power 55-120 Hz, µV²
    sem: Floats  # (n_s,) T3-T4 mean power 0.2-0.7 Hz, µV²

    @property
    def n(self) -> int:
        return int(self.gap.shape[0])

    @property
    def extreme(self) -> Bools:
        return self.qrange > EXTREME_UV

    @property
    def movement(self) -> Bools:
        """Several channels jump at once (a broadband jump: a turn, a touch, a lifted electrode)."""
        return ((self.qrange >= MOVE_UV).sum(axis=0) >= MOVE_CHANNELS) & ~self.gap

    @property
    def back_clean(self) -> Bools:
        """(2, n_s) back channel usable for alpha."""
        bad = self.flat[list(BACK)] | self.railed[list(BACK)] | (self.qrange[list(BACK)] >= CLEAN_BACK_UV)
        return ~bad & ~self.gap

    def back_alpha(self) -> tuple[Floats, Bools]:
        """Alpha per second, the mean of the usable back channels, and whether any was usable."""
        ok = self.back_clean
        cnt = ok.sum(axis=0)
        total = np.where(ok[0], self.alpha[0], 0.0) + np.where(ok[1], self.alpha[1], 0.0)
        return np.where(cnt > 0, total / np.maximum(cnt, 1), 0.0), cnt > 0


def seconds(x: Floats, missing: Bools | None = None) -> Seconds:
    """Per-second features of a recording (whole seconds only)."""
    a, miss = _check_input(x, missing)
    n_s = a.shape[1] // FS
    ch = chains()
    raw = [_seconds(a[c], n_s) for c in range(4)]
    flat = np.stack([np.ptp(r, axis=1) < FLAT_UV for r in raw])
    railed = np.stack([np.abs(r).max(axis=1) >= RAIL_UV for r in raw])
    qrange = np.stack([np.ptp(_seconds(run_chain(ch["quality"], a[c]), n_s), axis=1) for c in range(4)])
    alpha = np.stack([_mean_sq(run_chain(ch["alpha"], a[b]), n_s) for b in BACK])
    theta = np.stack([_mean_sq(run_chain(ch["theta"], a[b]), n_s) for b in BACK])
    muscle = np.stack([_mean_sq(run_chain(ch["muscle"], a[c]), n_s) for c in range(4)])
    sem = _mean_sq(run_chain(ch["sem"], a[2] - a[3]), n_s)
    gap = _seconds(miss.astype(np.float64), n_s).max(axis=1) > 0
    return Seconds(gap, flat, railed, qrange, alpha, theta, muscle, sem)


# ---------------------------------------------------------------------------------------------------------
# Blinks and eye movements (sample events)
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Blink:
    i: int  # sample of the lowest point
    depth: float  # µV, the 4-channel mean
    t34: float  # µV, T3 depth minus T4 depth (near 0 for a blink)


@dataclass(frozen=True)
class EyeMove:
    i: int  # sample of the fastest change
    step: float  # µV change of T3-T4 over 0.1 s; the sign is the direction (left or right: setup test)


def _blink_filtered(a: Floats) -> Floats:
    ch = chains()["blink"]
    return np.stack([run_chain(ch, a[c]) for c in range(4)])


def _first_extreme(v: Floats, half: int, lowest: bool) -> NDArray[np.int64]:
    """Indexes i where v[i] is the first lowest (or highest) value of v[i-half .. i+half]: lower than every
    value before it in the window and not higher than any after it."""
    n = v.shape[0]
    if n < 2 * half + 1:
        return np.zeros(0, np.int64)
    w = v if lowest else -v
    full = minimum_filter1d(w, 2 * half + 1, mode="nearest")
    left = np.full(n, np.inf)
    # min of w[i-half .. i-1]: scipy's window of `half` values at j covers j - half // 2 onwards
    shift = half - half // 2
    left[shift:] = minimum_filter1d(w, half, mode="nearest")[: n - shift]
    i = np.arange(n)
    ok = (w == full) & (w < left) & (i >= half) & (i < n - half)
    return np.flatnonzero(ok).astype(np.int64)


def _under_half(m: Floats, i: int, level: float, half: int) -> int:
    """Samples around i (within ±half) where m stays under level, counted outwards until it is not."""
    k = 1
    j = i - 1
    while j >= i - half and m[j] < level:
        k += 1
        j -= 1
    j = i + 1
    while j <= i + half and m[j] < level:
        k += 1
        j += 1
    return k


def blinks(x: Floats, missing: Bools | None = None) -> list[Blink]:
    """Blink-like dips: the lowest point of the 4-channel mean within ±0.3 s, deep on all four channels,
    near zero in T3-T4. Runs while awake only: in sleep the same shape comes from slow waves."""
    a, miss = _check_input(x, missing)
    f = _blink_filtered(a)
    return _blinks_from(f, miss)


def _blinks_from(f: Floats, miss: Bools) -> list[Blink]:
    m = (f[0] + f[1] + f[2] + f[3]) / 4
    half = round(BLINK_HALF_S * FS)
    b0, b1 = round(BLINK_BASE_S[0] * FS), round(BLINK_BASE_S[1] * FS)
    wlo, whi = round(BLINK_WIDTH_S[0] * FS), round(BLINK_WIDTH_S[1] * FS)
    out: list[Blink] = []
    for i in _first_extreme(m, half, lowest=True):
        i = int(i)
        if i < b0 or i + half >= m.shape[0] or miss[i - b0 : i + half + 1].any():
            continue
        base = [median(f[c, i - b0 : i - b1]) for c in range(4)]
        depth = [base[c] - f[c, i] for c in range(4)]
        dm = (depth[0] + depth[1] + depth[2] + depth[3]) / 4
        if dm < BLINK_MIN_UV or min(depth) < BLINK_EACH_UV:
            continue
        t34 = depth[2] - depth[3]
        if abs(t34) > BLINK_T34_SHARE * dm:
            continue
        seg = f[:, i - b0 : i + half + 1]
        if float(np.ptp(seg, axis=1).max()) > BLINK_MAX_UV:
            continue
        base_m = (base[0] + base[1] + base[2] + base[3]) / 4
        width = _under_half(m, i, base_m - dm / 2, half)
        if not wlo <= width <= whi:
            continue
        out.append(Blink(i, dm, t34))
    return out


def eye_moves(x: Floats, missing: Bools | None = None) -> list[EyeMove]:
    """Fast sideways eye movements: the largest 0.1 s change of T3-T4 within ±0.3 s, with little change in
    the 4-channel mean (a blink or a movement moves all four)."""
    a, miss = _check_input(x, missing)
    return _eye_moves_from(_blink_filtered(a), miss)


def _eye_moves_from(f: Floats, miss: Bools) -> list[EyeMove]:
    d = f[2] - f[3]
    m = (f[0] + f[1] + f[2] + f[3]) / 4
    k = round(EYE_STEP_S * FS)
    half = round(EYE_HALF_S * FS)
    s = np.zeros_like(d)
    s[k:] = d[k:] - d[:-k]
    sa = np.abs(s)
    out: list[EyeMove] = []
    for i in _first_extreme(sa, half, lowest=False):
        i = int(i)
        if i < half + k or i + half >= d.shape[0] or sa[i] < EYE_MIN_UV or miss[i - half - k : i + half + 1].any():
            continue
        if abs(m[i] - m[i - k]) > EYE_COMMON_SHARE * sa[i]:
            continue
        d3, d4 = f[2, i] - f[2, i - k], f[3, i] - f[3, i - k]
        if d3 * d4 >= 0 or min(abs(d3), abs(d4)) < EYE_BALANCE * max(abs(d3), abs(d4)):
            continue
        if float(np.ptp(f[:, i - half - k : i + half + 1], axis=1).max()) > EYE_MAX_UV:
            continue
        out.append(EyeMove(i, float(s[i])))
    return out


# ---------------------------------------------------------------------------------------------------------
# Muscle (jaw) and movement bursts, per second
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Burst:
    start: int  # first second
    end: int  # last second (inclusive)
    kind: BurstKind
    peak_x: float  # highest T3 or T4 power against its baseline


def muscle_rest(sec: Seconds) -> Floats:
    """Personal muscle baseline per second for T3 and T4, (2, n_s): the 20th percentile of the channel's
    previous 2 minutes of non-gap seconds (NaN until 30 of them exist). A clench shorter than about a
    minute and a half does not lift it."""
    rest = np.full((2, sec.n), np.nan)
    for j, c in enumerate(SIDE):
        hist: list[float] = []
        for k in range(sec.n):
            if len(hist) >= MUSCLE_REST_MIN_S:
                rest[j, k] = percentile(hist, MUSCLE_REST_PCT)
            if not sec.gap[k]:
                hist.append(float(sec.muscle[c, k]))
                if len(hist) > MUSCLE_REST_S:
                    hist.pop(0)
    return rest


def muscle_seconds(sec: Seconds) -> tuple[Bools, Floats]:
    """Whether each second has a muscle burst at T3 or T4 (over 4x its own baseline), and the power of T3 and
    T4 against their baselines, (2, n_s), NaN while a baseline is unknown."""
    rest = muscle_rest(sec)
    with np.errstate(invalid="ignore", divide="ignore"):
        x = np.where(np.isnan(rest) | (rest <= 0), np.nan, sec.muscle[list(SIDE)] / rest)
    top = np.where(np.isnan(x), -1.0, x).max(axis=0)
    on = (top >= MUSCLE_X) & ~sec.gap
    return on, x


def bursts(sec: Seconds) -> list[Burst]:
    """Muscle bursts at T3/T4: seconds over 4x the personal baseline on either side, joined when under 2 s
    apart. 'movement' if movement falls inside (a turn or a touch also lights up 55-120 Hz); 'jaw' if both
    sides rose (both over 2x) in one of its seconds, as a clench does; otherwise 'one-sided' (a pillow, a
    hand, one electrode rubbing)."""
    on, x = muscle_seconds(sec)
    move = sec.movement
    spans: list[tuple[int, int]] = []
    last_gap = -1
    for k in range(sec.n):
        if sec.gap[k]:
            last_gap = k
        if not on[k]:
            continue
        if spans and k - spans[-1][1] <= MUSCLE_JOIN_S and last_gap < spans[-1][1]:
            spans[-1] = (spans[-1][0], k)
        else:
            spans.append((k, k))
    out: list[Burst] = []
    for a, b in spans:
        xs = x[:, a : b + 1]
        kind: BurstKind = "jaw"
        if bool(move[a : b + 1].any()):
            kind = "movement"
        elif not bool(np.any(np.nan_to_num(xs, nan=0.0).min(axis=0) >= MUSCLE_BOTH_X)):
            kind = "one-sided"
        out.append(Burst(a, b, kind, float(np.nanmax(xs))))
    return out


def movement_spans(sec: Seconds) -> list[tuple[int, int]]:
    """Movement seconds joined into spans (first, last second), joined when under 2 s apart."""
    mv = sec.movement
    out: list[tuple[int, int]] = []
    for k in np.flatnonzero(mv):
        k = int(k)
        if out and k - out[-1][1] <= MUSCLE_JOIN_S:
            out[-1] = (out[-1][0], k)
        else:
            out.append((k, k))
    return out


# ---------------------------------------------------------------------------------------------------------
# Per-epoch quality
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Epoch:
    index: int
    quality: Quality
    gap_s: int
    bad_s: tuple[int, int, int, int]  # per channel: flat, railed, extreme or gap seconds
    usable: tuple[bool, bool, bool, bool]
    movement_s: int
    muscle_s: int


def epoch_quality(sec: Seconds, origin: int = 0) -> list[Epoch]:
    """Good / degraded / missing per 30 s epoch, epochs counted from second `origin` (whole epochs only).

    missing: over 5 gap seconds, or no channel usable; degraded: a channel unusable (over 3 bad seconds),
    3 or more movement seconds, or muscle in half the epoch; good otherwise.
    """
    bad = sec.flat | sec.railed | sec.extreme | sec.gap[None, :]
    move = sec.movement
    musc, _ = muscle_seconds(sec)
    out: list[Epoch] = []
    for e in range((sec.n - origin) // EPOCH_S):
        s = slice(origin + e * EPOCH_S, origin + (e + 1) * EPOCH_S)
        gap_s = int(sec.gap[s].sum())
        bad_s = tuple(int(v) for v in bad[:, s].sum(axis=1))
        usable = tuple(b <= BAD_CHANNEL_S for b in bad_s)
        mv, mu = int(move[s].sum()), int(musc[s].sum())
        q: Quality
        if gap_s > MAX_GAP_S or not any(usable):
            q = "missing"
        elif not all(usable) or mv >= DEGRADED_MOVE_S or mu >= DEGRADED_MUSCLE_S:
            q = "degraded"
        else:
            q = "good"
        out.append(Epoch(e, q, gap_s, bad_s, usable, mv, mu))  # type: ignore[arg-type]
    return out


# ---------------------------------------------------------------------------------------------------------
# Drift-off: lights off, a 60 s eyes-closed baseline, faded alpha, timers
# ---------------------------------------------------------------------------------------------------------


@dataclass
class DriftEpoch:
    index: int  # epoch number from lights off
    start: int  # first second (from the start of the input)
    clean_s: int
    faded_share: float | None  # share of clean seconds with alpha under half the baseline
    faded: bool | None  # None = skipped (under 10 clean seconds, or before the baseline)
    rolls: bool  # slow eye rolls seen in this epoch
    blinks: int
    state: DriftState  # after this epoch


@dataclass
class Drift:
    lights_off: int  # second
    baseline_alpha: float | None
    baseline_sem: float | None
    baseline_done: int | None  # second when the 60 clean seconds were complete
    epochs: list[DriftEpoch] = field(default_factory=list)
    drowsy_at: int | None = None  # second the app first knew "drowsy"
    onset: int | None = None  # first second of the first "probably asleep" run
    asleep_at: int | None = None  # second the app knew it (end of the run's 6th epoch)
    onsets: list[tuple[int, int]] = field(default_factory=list)  # every (onset, known) incl. after waking
    wakes: list[int] = field(default_factory=list)  # seconds "awake again" was known


class DriftOff:
    """The drift-off detector, fed one second at a time (the Dart class has the same steps).

    Before lights off nothing happens. After it, the first 60 clean seconds give the baseline (eyes
    closed: the person is told so). Then every 30 s epoch counted from lights off is faded or not, and the
    state follows runs of faded epochs: 2 = drowsy, 6 = probably asleep, 2 unfaded = awake again.
    """

    def __init__(self, lights_off: int) -> None:
        self.result = Drift(lights_off, None, None, None)
        self._base_a: list[float] = []
        self._base_s: list[float] = []
        self._ep: list[tuple[float, bool, bool, float, int]] = []  # alpha, clean, movement, sem10, blinks
        self._run = 0
        self._unfaded = 0
        self._run_start = 0
        self.state: DriftState = "baseline"
        self._sem: list[float] = []

    def second(self, k: int, alpha: float, clean: bool, movement: bool, sem: float, blinks: int = 0) -> DriftState:
        """Second k (counted from the start of the input, k >= lights_off): back alpha (µV²), whether it was
        clean, movement, T3-T4 slow-roll power (µV²) and the blinks found in it."""
        r = self.result
        if not clean or movement:
            self._sem = []
        else:
            self._sem.append(sem)
            if len(self._sem) > SEM_WINDOW_S:
                self._sem.pop(0)
        sem10 = sum(self._sem) / len(self._sem) if len(self._sem) == SEM_WINDOW_S else math.nan
        if r.baseline_alpha is None and clean and not movement and blinks == 0:
            self._base_a.append(alpha)
            self._base_s.append(sem)
            if len(self._base_a) == BASELINE_S:
                r.baseline_alpha = median(self._base_a)
                r.baseline_sem = median(self._base_s)
                r.baseline_done = k
                self.state = "awake"
        self._ep.append((alpha, clean, movement, sem10, blinks))
        if len(self._ep) == EPOCH_S:
            self._end_epoch(k - EPOCH_S + 1)
            self._ep = []
        return self.state

    def _end_epoch(self, start: int) -> None:
        r = self.result
        idx = (start - r.lights_off) // EPOCH_S
        base = r.baseline_alpha
        clean = [e[0] for e in self._ep if e[1]]
        moved = sum(1 for e in self._ep if e[2])
        blinked = sum(e[4] for e in self._ep)
        rolls = bool(
            r.baseline_sem is not None
            and any(not math.isnan(e[3]) and e[3] > SEM_X * r.baseline_sem for e in self._ep)
        )
        if base is None or len(clean) < MIN_CLEAN_S:
            r.epochs.append(DriftEpoch(idx, start, len(clean), None, None, rolls, blinked, self.state))
            return
        share = sum(1 for a in clean if a < FADE_X * base) / len(clean)
        eyes_open = blinked >= EYES_OPEN_BLINKS and self.state != "asleep"
        faded = share > FADE_SHARE and moved < MOVE_BREAK_S and not eyes_open
        end = start + EPOCH_S - 1
        if faded:
            self._run += 1
            self._unfaded = 0
            if self._run == 1:
                self._run_start = start
            if self.state in ("awake",) and self._run >= DROWSY_EPOCHS:
                self.state = "drowsy"
                if r.drowsy_at is None:
                    r.drowsy_at = end
            if self.state == "drowsy" and self._run >= ASLEEP_EPOCHS:
                self.state = "asleep"
                r.onsets.append((self._run_start, end))
                if r.onset is None:
                    r.onset, r.asleep_at = self._run_start, end
        else:
            self._run = 0
            self._unfaded += 1
            if self.state == "drowsy":
                self.state = "awake"
            elif self.state == "asleep" and self._unfaded >= WAKE_EPOCHS:
                self.state = "awake"
                r.wakes.append(end)
        r.epochs.append(DriftEpoch(idx, start, len(clean), share, faded, rolls, blinked, self.state))


def blinks_per_second(found: list[Blink], n_s: int) -> NDArray[np.int64]:
    out = np.zeros(n_s, np.int64)
    for b in found:
        if b.i // FS < n_s:
            out[b.i // FS] += 1
    return out


def drift_off(sec: Seconds, lights_off: int, found: list[Blink] | None = None, until: int | None = None) -> Drift:
    """Run the drift-off detector over per-second features from `lights_off` (second) on."""
    alpha, clean = sec.back_alpha()
    move = sec.movement
    bl = blinks_per_second(found or [], sec.n)
    det = DriftOff(lights_off)
    for k in range(lights_off, sec.n if until is None else min(until, sec.n)):
        det.second(k, float(alpha[k]), bool(clean[k]), bool(move[k]), float(sec.sem[k]), int(bl[k]))
    return det.result


@dataclass(frozen=True)
class Timers:
    sound_fade_from: int  # seconds after lights off: start fading sleep sounds
    sound_off_at: int  # seconds after lights off: sound silent
    dream_cue_at: int  # seconds after lights off: the dream catcher asks


def timers(drift: Drift, earlier_latencies_min: list[float], u: float) -> Timers:
    """Both timers (DECISIONS 62). Sound: fade over 2.5 min once probably asleep, silent by 45 min after
    lights off at the latest. Dream catcher: right when drowsy is known, or, if that never comes, at a
    random moment (u in 0..1) inside the usual time to fall asleep (the middle half of earlier nights'
    onset latencies once there are 3, else 10-20 min)."""
    if not 0 <= u <= 1:
        raise ValueError("u must be in 0..1")
    lo_min, hi_min = DREAM_WINDOW_MIN
    if len(earlier_latencies_min) >= 3:
        lo_min, hi_min = percentile(earlier_latencies_min, 0.25), percentile(earlier_latencies_min, 0.75)
    fallback = math.floor((lo_min + (hi_min - lo_min) * u) * 60 + 0.5)  # halves up, as in the Dart port
    fade = SOUND_CAP_S - SOUND_FADE_S
    if drift.asleep_at is not None:
        fade = min(fade, drift.asleep_at - drift.lights_off + 1)
    cue = fallback
    if drift.drowsy_at is not None:
        cue = min(cue, drift.drowsy_at - drift.lights_off + 1)
    return Timers(fade, min(SOUND_CAP_S, fade + SOUND_FADE_S), cue)


# ---------------------------------------------------------------------------------------------------------
# Everything at once
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Seen:
    seconds: Seconds
    epochs: list[Epoch]
    blinks: list[Blink]
    eye_moves: list[EyeMove]
    bursts: list[Burst]
    movement: list[tuple[int, int]]


def detect(x: Floats, missing: Bools | None = None) -> Seen:
    """Every detector over one recording (epochs counted from its first sample)."""
    a, miss = _check_input(x, missing)
    sec = seconds(a, miss)
    f = _blink_filtered(a)
    return Seen(sec, epoch_quality(sec), _blinks_from(f, miss), _eye_moves_from(f, miss), bursts(sec), movement_spans(sec))
