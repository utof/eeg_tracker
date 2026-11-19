"""Hands-free gestures on top of the shared detectors (ROADMAP "Hands-free controls"; DECISIONS 240-249).

Two deliberate gestures act as a switch during sessions:

- **double clench**: two short jaw clenches (each 0.2-1 s, 0.3-1.5 s apart), both temple electrodes over the
  clench level at each clench's peak, and no other jaw muscle (both sides up) within 2 s before the first and after
  the second;
- **glance**: look left, then right (or, while left and right are not known, look away and back): two opposite
  steps of T3-T4 of at least the glance size, each within 1.5 s of the one before (an optional third, back to the
  middle), and no other eye movement within 2 s before and after.

Nothing else may happen around a gesture: a second with a Bluetooth hole or movement, or a moment whose muscle
rest level is not yet known (the first 30 s), anywhere from 2 s before to 2 s after, and it does not count.
Very few false triggers matter more than catching every gesture; the numbers are planning values until the
owner's calibration ("clench twice now" and "look left, then right", 3 times each), which tunes the clench level,
the glance size and which way is left (`calibrate`).

Python reference; the phone app has a line-by-line port in `app/lib/detectors/gestures.dart`, checked against a
fixture made by `analysis/make_gesture_fixture.py`. Like the detectors, everything is causal and streaming-shaped:
the recogniser is fed one whole second at a time, as the detectors finish it (not one second later, as their
`onSecond` hands it out: blinks are not needed). A second's input is its ten 0.1 s ticks of 55-120 Hz power at
T3 and T4 (the detectors' muscle filter), each side's rest level (their 20th percentile of the last 2 minutes,
known at the second's start), whether the second has a hole or movement, and the eye movements known by the end
of the second (the detectors find each 0.3 s after the fact). Whether the person is asleep is the caller's
business: the app drops gestures while the drift-off detector says probably asleep.
"""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass, field, replace
from typing import Literal

import numpy as np

import eeg_detectors as det

FS = det.FS
TICK = 25  # samples: 0.1 s
TICKS = FS // TICK  # 10 ticks a second

# ---- double clench (planning values; DECISIONS 241) ----
BUSY_X = det.MUSCLE_X  # a jaw tick: one side over 4x its own rest level and both over 2x (the detectors' jaw rule,
BOTH_X = det.MUSCLE_BOTH_X  # at 0.1 s); one-sided muscle (a pillow, a hand, an electrode rubbing) does not count
CLENCH_X = 10.0  # each clench: both sides over this many times their rest at its strongest tick
CLENCH_X_RANGE = (10.0, 60.0)  # what the calibration may set (under 10x: false triggers awake, DECISIONS 243)
MERGE_TICKS = 1  # a dip of one quiet tick inside a clench does not split it
BURST_TICKS = (2, 10)  # each clench 0.2-1.0 s long
PAUSE_TICKS = (3, 15)  # 0.3-1.5 s between the two
QUIET_TICKS = 20  # nothing else within 2 s before the first clench and after the second

# ---- look left, then right (planning values; DECISIONS 242) ----
GLANCE_UV = 80.0  # each of the first two steps of T3-T4 at least this (the eye-movement detector starts at 40)
GLANCE_UV_RANGE = (70.0, 250.0)
GLANCE_STEP_S = 1.5  # each step within 1.5 s of the one before
GLANCE_QUIET_S = 2.0  # no other eye movement within 2 s before the first step and after the last

# ---- calibration (DECISIONS 243) ----
CAL_SHARE_CLENCH = 0.5  # the clench level: half the weakest calibrated clench's peak
CAL_SHARE_GLANCE = 0.6  # the glance size: 0.6 of the weakest calibrated step
CAL_NEED = 2  # a gesture is usable once at least 2 of its 3 cued tries are recognised with the tuned settings

Kind = Literal["clench", "glance"]
SPOIL_KEEP_TICKS = 100  # spoiled ticks are remembered this long (10 s; a glance is decided at most ~6 s after its start)

_GLANCE_STEP = round(GLANCE_STEP_S * FS)
_GLANCE_QUIET = round(GLANCE_QUIET_S * FS)
_EYE_FOUND_AFTER = round(det.EYE_HALF_S * FS)  # an eye movement at sample i is known once sample i + 75 is in


@dataclass(frozen=True)
class Settings:
    clench_x: float = CLENCH_X
    glance_uv: float = GLANCE_UV
    left_sign: int = 0  # +1 or -1: the sign of T3-T4's step when the eyes go left; 0 = not known (away and back)
    clench_on: bool = True
    glance_on: bool = True


@dataclass(frozen=True)
class Second:
    """One whole second as the recogniser takes it."""

    k: int
    p3: tuple[float, ...]  # ten ticks of mean 55-120 Hz power at T3, µV²
    p4: tuple[float, ...]
    tick_gap: tuple[bool, ...]  # a missing sample in the tick
    rest3: float  # the detectors' rest level for this second (NaN while unknown)
    rest4: float
    movement: bool
    moves: tuple[det.EyeMove, ...]  # eye movements first known during this second


@dataclass(frozen=True)
class Burst:
    start: int  # first tick
    end: int  # last tick (inclusive)
    peak: float  # the strongest tick's weaker side, times its rest


@dataclass(frozen=True)
class Gesture:
    kind: Kind
    start: int  # first tick (clench) or sample (glance) of the gesture
    end: int  # last tick or sample
    at: int  # the second whose end decided it
    level: float  # clench: the weaker clench's peak (x rest); glance: the smaller of the first two steps (µV)


@dataclass
class Cluster:
    """Muscle bursts under 2 s apart, or eye movements under 2 s apart: what a gesture is looked for in."""

    kind: Kind
    bursts: list[Burst] = field(default_factory=list)
    moves: list[det.EyeMove] = field(default_factory=list)
    at: int = -1  # the second it was decided in
    clean: bool = False  # nothing spoiled from 2 s before to 2 s after
    gesture: Gesture | None = None


def _levels(p: float, rest: float) -> float:
    return math.nan if math.isnan(rest) or rest <= 0 else p / rest


class Gestures:
    """The recogniser, fed one whole second at a time (the Dart class has the same steps)."""

    def __init__(self, settings: Settings | None = None, keep_clusters: bool = True) -> None:
        self.settings = settings or Settings()
        self.keep_clusters = keep_clusters
        self.gestures: list[Gesture] = []
        self.clusters: list[Cluster] = []  # every decided cluster (for calibration and validation)
        self._spoiled: list[int] = []  # recent spoiled ticks, ascending
        self._open: Burst | None = None  # the burst being built
        self._bursts: list[Burst] = []  # closed bursts of the cluster being built
        self._last_busy = -(10**9)
        self._moves: list[det.EyeMove] = []
        self._tick = 0  # ticks seen

    # ---- per second ----

    def second(self, s: Second) -> list[Gesture]:
        if len(s.p3) != TICKS or len(s.p4) != TICKS or len(s.tick_gap) != TICKS:
            raise ValueError("a second has ten ticks")
        found: list[Gesture] = []
        for j in range(TICKS):
            t = s.k * TICKS + j
            self._tick = t + 1
            x3, x4 = _levels(s.p3[j], s.rest3), _levels(s.p4[j], s.rest4)
            unknown = math.isnan(x3) or math.isnan(x4)
            if s.tick_gap[j] or s.movement or unknown:
                self._spoiled.append(t)
            busy = not unknown and max(x3, x4) >= BUSY_X and min(x3, x4) >= BOTH_X
            both = 0.0 if unknown else min(x3, x4)
            g = self._clench_tick(t, busy, both, s.k)
            if g is not None:
                found.append(g)
        while self._spoiled and self._spoiled[0] < self._tick - SPOIL_KEEP_TICKS:
            self._spoiled.pop(0)
        cutoff = (s.k + 1) * FS - 1 - _EYE_FOUND_AFTER  # every eye movement up to here is known now
        for m in s.moves:
            g = self._glance_move(m, s.k)
            if g is not None:
                found.append(g)
        if self._moves and cutoff >= self._moves[-1].i + _GLANCE_QUIET:
            g = self._close_glance(s.k)
            if g is not None:
                found.append(g)
        self.gestures.extend(found)
        return found

    def _spoiled_in(self, lo: int, hi: int) -> bool:
        return any(lo <= t <= hi for t in self._spoiled)

    def _log(self, c: Cluster) -> None:
        if self.keep_clusters:
            self.clusters.append(c)

    # ---- double clench ----

    def _clench_tick(self, t: int, busy: bool, both: float, k: int) -> Gesture | None:
        o = self._open
        if busy:
            if o is not None and t - o.end <= MERGE_TICKS + 1:
                self._open = replace(o, end=t, peak=max(o.peak, both))
            else:
                if o is not None:
                    self._bursts.append(o)
                self._open = Burst(t, t, both)
            self._last_busy = t
            return None
        if o is not None and t - o.end > MERGE_TICKS:
            self._bursts.append(o)
            self._open = None
        if self._bursts and t - self._last_busy >= QUIET_TICKS:
            return self._close_clench(t, k)
        return None

    def _close_clench(self, t: int, k: int) -> Gesture | None:
        bursts, self._bursts = self._bursts, []
        c = Cluster("clench", bursts=bursts, at=k)
        c.clean = not self._spoiled_in(bursts[0].start - QUIET_TICKS, t)
        if self.settings.clench_on and clench_why(c, self.settings) == "ok":
            c.gesture = Gesture("clench", bursts[0].start, bursts[-1].end, k, min(b.peak for b in bursts))
        self._log(c)
        return c.gesture

    # ---- glance ----

    def _glance_move(self, m: det.EyeMove, k: int) -> Gesture | None:
        g = None
        if self._moves and m.i - self._moves[-1].i > _GLANCE_QUIET:
            g = self._close_glance(k)
        self._moves.append(m)
        return g

    def _close_glance(self, k: int) -> Gesture | None:
        moves, self._moves = self._moves, []
        c = Cluster("glance", moves=moves, at=k)
        c.clean = not self._spoiled_in((moves[0].i - _GLANCE_QUIET) // TICK, (moves[-1].i + _GLANCE_QUIET) // TICK)
        if self.settings.glance_on and glance_why(c, self.settings) == "ok":
            c.gesture = Gesture("glance", moves[0].i, moves[-1].i, k, min(abs(moves[0].step), abs(moves[1].step)))
        self._log(c)
        return c.gesture


def clench_why(c: Cluster, s: Settings) -> str:
    """Why a muscle cluster is or is not a double clench: 'ok', or the first rule it breaks."""
    b = c.bursts
    if not c.clean:
        return "noisy"  # movement, a lost signal or an unknown rest level within 2 s
    if len(b) != 2:
        return "one" if len(b) == 1 else "many"
    if any(x.end - x.start + 1 > BURST_TICKS[1] for x in b):
        return "long"
    if any(x.end - x.start + 1 < BURST_TICKS[0] for x in b):
        return "short"
    pause = b[1].start - b[0].end - 1
    if pause < PAUSE_TICKS[0]:
        return "close"
    if pause > PAUSE_TICKS[1]:
        return "apart"
    if min(b[0].peak, b[1].peak) < s.clench_x:
        return "weak"
    return "ok"


def glance_why(c: Cluster, s: Settings) -> str:
    """Why an eye-movement cluster is or is not a glance: 'ok', or the first rule it breaks."""
    m = c.moves
    if not c.clean:
        return "noisy"
    if not 2 <= len(m) <= 3:
        return "one" if len(m) == 1 else "many"
    if any(m[n + 1].i - m[n].i > _GLANCE_STEP for n in range(len(m) - 1)):
        return "slow"
    if any(m[n + 1].step * m[n].step >= 0 for n in range(len(m) - 1)):
        return "same"
    if s.left_sign != 0 and m[0].step * s.left_sign <= 0:
        return "way"
    if min(abs(m[0].step), abs(m[1].step)) < s.glance_uv:
        return "small"
    return "ok"


# ---------------------------------------------------------------------------------------------------------
# Inputs from a recording
# ---------------------------------------------------------------------------------------------------------


def tick_power(v: det.Floats) -> det.Floats:
    """Mean of squares per 0.1 s tick, summed in sample order (as the streaming port does)."""
    n_t = v.shape[0] // TICK
    sq = v[: n_t * TICK].reshape(n_t, TICK) ** 2
    out = np.zeros(n_t)
    for j in range(TICK):
        out += sq[:, j]
    return out / TICK


def inputs(x: det.Floats, missing: det.Bools | None = None, sec: det.Seconds | None = None,
           moves: list[det.EyeMove] | None = None) -> list[Second]:
    """The recogniser's input for every whole second of a recording (seconds and eye movements may be passed in
    when they are already computed for the same samples)."""
    a, miss = det._check_input(x, missing)
    sec = sec if sec is not None else det.seconds(a, miss)
    moves = moves if moves is not None else det.eye_moves(a, miss)
    n_s = sec.n
    chain = det.chains()["muscle"]
    p3 = tick_power(det.run_chain(chain, a[2]))
    p4 = tick_power(det.run_chain(chain, a[3]))
    tg = miss[: n_s * FS].reshape(n_s * TICKS, TICK).any(axis=1)
    rest = det.muscle_rest(sec)
    move = sec.movement
    by_second: list[list[det.EyeMove]] = [[] for _ in range(n_s)]
    for m in moves:
        k = math.ceil((m.i + _EYE_FOUND_AFTER + 1) / FS) - 1  # the second whose end first knows it
        if 0 <= k < n_s:
            by_second[k].append(m)
    out = []
    for k in range(n_s):
        sl = slice(k * TICKS, (k + 1) * TICKS)
        out.append(Second(k, tuple(float(v) for v in p3[sl]), tuple(float(v) for v in p4[sl]),
                          tuple(bool(v) for v in tg[sl]), float(rest[0, k]), float(rest[1, k]), bool(move[k]),
                          tuple(by_second[k])))
    return out


def run(seconds: Iterable[Second], settings: Settings | None = None) -> Gestures:
    g = Gestures(settings)
    for s in seconds:
        g.second(s)
    return g


# ---------------------------------------------------------------------------------------------------------
# Calibration: "clench twice now" and "look left, then right", 3 times each
# ---------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Try:
    kind: Kind
    cue: int  # second of the cue
    until: int  # last second the answer may start in (inclusive)


@dataclass(frozen=True)
class TryResult:
    kind: Kind
    cue: int
    level: float | None  # clench: the weaker of the two strongest bursts (x rest); glance: the smaller first step (µV)
    sign: int  # glance: the sign of the first step (0: none)
    why: str  # 'ok' (recognised with the tuned settings), 'none' (nothing seen), or the rule it broke


@dataclass(frozen=True)
class Calibration:
    settings: Settings
    tries: list[TryResult]
    clench_seen: int
    glance_seen: int
    left_known: bool
    others: int  # gestures recognised outside the cued windows (should be 0)


def _why(c: Cluster, s: Settings) -> str:
    return clench_why(c, s) if c.kind == "clench" else glance_why(c, s)


def _clamp(v: float, lo_hi: tuple[float, float]) -> float:
    return min(max(v, lo_hi[0]), lo_hi[1])


def _starts(c: Cluster) -> list[int]:
    """The seconds a cluster's bursts or eye movements start in."""
    return [b.start // TICKS for b in c.bursts] if c.kind == "clench" else [m.i // FS for m in c.moves]


def _try_cluster(g: Gestures, t: Try) -> Cluster | None:
    """The first cluster of the try's kind with a burst or eye movement starting inside its window."""
    return next((c for c in g.clusters if c.kind == t.kind and any(t.cue <= s <= t.until for s in _starts(c))), None)


def _level(c: Cluster | None) -> tuple[float | None, int]:
    """Clench: the second-strongest burst's peak; glance: the first step and the next one the other way, the
    smaller of the two, and the first one's sign."""
    if c is None:
        return None, 0
    if c.kind == "clench":
        peaks = sorted((b.peak for b in c.bursts), reverse=True)
        return (peaks[1] if len(peaks) >= 2 else None), 0
    first = c.moves[0]
    other = next((m for m in c.moves[1:] if m.step * first.step < 0), None)
    return (min(abs(first.step), abs(other.step)) if other is not None else None), (1 if first.step > 0 else -1)


def calibrate(seconds: list[Second], tries: list[Try]) -> Calibration:
    """Tune the clench level, the glance size and which way is left from a calibration run, then say for every
    cued try whether the tuned settings recognise it (and if not, which rule it broke). Only tries that have a
    gesture's shape at any level (timing, quiet around, two opposite steps) set the levels. Clusters do not
    depend on the settings, so one pass finds them all."""
    g = run(seconds, Settings(clench_on=False, glance_on=False))
    loose = Settings(clench_x=0.0, glance_uv=0.0, left_sign=0)
    found = [(t, _try_cluster(g, t)) for t in tries]
    levels = {(t.cue, t.kind): _level(c) for t, c in found}
    shaped = [(t, levels[(t.cue, t.kind)]) for t, c in found if c is not None and _why(c, loose) == "ok"]
    clench = [v for t, (v, _) in shaped if t.kind == "clench" and v is not None]
    glance = [v for t, (v, _) in shaped if t.kind == "glance" and v is not None]
    signs = [sg for t, (_, sg) in shaped if t.kind == "glance"]
    tuned = Settings(
        clench_x=_clamp(CAL_SHARE_CLENCH * min(clench), CLENCH_X_RANGE) if clench else CLENCH_X,
        glance_uv=_clamp(CAL_SHARE_GLANCE * min(glance), GLANCE_UV_RANGE) if glance else GLANCE_UV,
        left_sign=signs[0] if len(signs) >= CAL_NEED and len(set(signs)) == 1 else 0,
    )
    results: list[TryResult] = []
    for t, c in found:
        v, sign = levels[(t.cue, t.kind)]
        why = "none" if c is None else _why(c, tuned)
        results.append(TryResult(t.kind, t.cue, v, sign, why))
    cs = sum(1 for r in results if r.kind == "clench" and r.why == "ok")
    gs = sum(1 for r in results if r.kind == "glance" and r.why == "ok")
    ours = {id(c) for _, c in found if c is not None}
    others = sum(1 for c in g.clusters if id(c) not in ours and _why(c, tuned) == "ok")
    final = replace(tuned, clench_on=cs >= CAL_NEED, glance_on=gs >= CAL_NEED)
    return Calibration(final, results, cs, gs, tuned.left_sign != 0, others)
