"""'Unusual for you': the reference for the phone's card (DECISIONS rows 290-299). The phone's
`app/lib/unusual/detector.dart` is its line-by-line port, checked against a fixture this file makes
(`make_unusual_fixture.py`, `app/test/unusual_cross_check_test.dart`); `validate_unusual.py` back-tests it on
synthetic histories.

The design is NightSignal's (Alavi et al. 2022, Nat Med 28:175-184; code: StanfordBioinformatics/wearable-infection,
`nightsignal.py`, Apache-2.0): one number a day compared with your own running median, a fixed threshold in the
number's own units, and an alert only when it is beyond it on two days in a row (NightSignal's "red" rule; a lone
day is never one), with at most one missing day filled in. NightSignal used the overnight resting heart rate; the
headband gives none, so the inputs are the trends page's per-day numbers, and the research's updates are taken in
(early-warning pass 2, Q1 and Q4):

- the usual is the median of the 28 days with a value that end a week before the day judged (Whoop's lagged
  baseline: a change that starts slowly does not drag the usual along), and needs 14 of them;
- "beyond" is the trends page's arrow rule (app/lib/trends/usual.dart, DECISIONS 122): at least 2 robust spreads
  (1.4826 x MAD) AND the measure's smallest change that matters (sleep 1 h, ratings 2 points, reaction time 10 %);
- each number is judged in one direction where the research names one (sleepier, lower mood, more tense, slower)
  and both ways for sleep length and for every number from the headband's signal (two-sided tests for EEG: illness
  can raise the alpha frequency while sleepiness lowers it);
- the headband's signal numbers (alpha speed, alpha strength, eyes-closed rise, jaw muscle bursts) are judged and
  kept apart: the card uses the core numbers only (sleep, ratings, reaction time) unless a back-test supports them;
- silent for the first 28 days with a core number (it only records what it would have said); a gap of more than
  14 days without any number starts the usual again; "feeling ill" pauses it for 14 days and keeps those days out
  of the usual (the body takes one to two weeks to settle after an illness, Levi 2026).

Days are `YYYY-MM-DD` keys as on the phone (a day runs 04:00 to 04:00; the trends page makes them).
"""

from __future__ import annotations

import bisect
import datetime as dt
import math
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field

MAD_TO_SD = 1.4826
USUAL_MIN = 7  # usual.dart: a usual from 7 values


@dataclass(frozen=True)
class Scale:
    """How a number is judged (usual.dart's Scale)."""

    name: str
    min_change: float = 0.0
    rel_change: float = 0.0
    log: bool = False


SCALES = {
    "minutes": Scale("minutes", min_change=60),
    "rating": Scale("rating", min_change=2),
    "reaction": Scale("reaction", rel_change=0.10),
    "rate": Scale("rate", rel_change=0.25),
    "log": Scale("log", log=True),
    "plain": Scale("plain"),
}


@dataclass(frozen=True)
class Stream:
    id: str  # the trends page's measure id
    scale: Scale
    direction: str  # "both", "up" or "down": which way counts
    group: str  # "core" (in the card) or "headband" (judged and logged, not in the card)


STREAMS: tuple[Stream, ...] = (
    Stream("asleep", SCALES["minutes"], "both", "core"),
    Stream("kss", SCALES["rating"], "up", "core"),
    Stream("mood", SCALES["rating"], "down", "core"),
    Stream("tension", SCALES["rating"], "up", "core"),
    Stream("reaction", SCALES["reaction"], "up", "core"),
    Stream("iaf", SCALES["plain"], "both", "headband"),
    Stream("alpha", SCALES["log"], "both", "headband"),
    Stream("rise", SCALES["log"], "both", "headband"),
    Stream("jaw", SCALES["rate"], "up", "headband"),
)


@dataclass(frozen=True)
class Settings:
    lag_days: int = 7  # the usual ends this many days before the day judged
    window: int = 28  # values in the usual, at most
    min_baseline: int = 14  # values the usual needs before a day is judged
    spreads: float = 2.0
    run_days: int = 2  # days in a row beyond the usual (NightSignal: 2)
    bridge: int = 1  # missing days a run may span (NightSignal fills in one)
    min_streams: int = 1  # numbers that must be in a run together (the research's stricter variant: 2)
    silent_days: int = 28  # days with a core number before the card shows
    restart_gap: int = 14  # more missing days than this start the usual again
    pause_days: int = 14  # "feeling ill" pauses it this long after the tap


@dataclass(frozen=True)
class Ill:
    """'Feeling ill' tapped on [tapped] for a card that began on [start]: the days from [start] to [pause_days]
    after the tap (or to the day before [resumed]) are paused and kept out of the usual."""

    start: str
    tapped: str
    resumed: str | None = None


@dataclass(frozen=True)
class Usual:
    days: int
    median: float
    spread: float
    half: float
    centre: float


@dataclass
class StreamDay:
    value: float | None = None
    n: int = 0  # values in the usual
    usual: float | None = None  # its median (from 7 values)
    spread: float | None = None
    half: float | None = None
    state: str = "none"  # none (no value), unjudged (under min_baseline), in, up, down
    off: bool = False  # beyond the usual in a direction that counts
    run: int = 0  # days beyond the usual in a row up to this one (0 when not off)
    run_start: str | None = None


@dataclass
class DayVerdict:
    day: str
    phase: str  # silent, on, paused
    valid_before: int  # days before this one with a core number
    epoch_start: str | None  # the first day the usual may use
    streams: dict[str, StreamDay] = field(default_factory=dict)
    active: dict[str, tuple[int, str, str]] = field(default_factory=dict)  # id -> (run, direction, run start)
    on_core: list[str] = field(default_factory=list)
    on_all: list[str] = field(default_factory=list)
    rule_core: bool = False
    rule_all: bool = False
    _baseline: dict[str, list[str]] = field(default_factory=dict, repr=False)

    @property
    def shown(self) -> bool:
        return self.phase == "on" and self.rule_core

    def baseline_days(self, stream: str) -> list[str]:
        return self._baseline.get(stream, [])


# ---- days ----


def _date(key: str) -> dt.date:
    return dt.date.fromisoformat(key)


def add_days(key: str, n: int) -> str:
    return (_date(key) + dt.timedelta(days=n)).isoformat()


def days_between(a: str, b: str) -> int:
    return (_date(b) - _date(a)).days


# ---- the usual (usual.dart's maths) ----


def _median(v: Sequence[float]) -> float:
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def usual_of_values(values: Sequence[float], scale: Scale) -> Usual | None:
    """The usual of a window's values (usual.dart's usualOf after it picked the window); None under 7 values."""
    vals = [v for v in values if math.isfinite(v) and (not scale.log or v > 0)]
    if len(vals) < USUAL_MIN:
        return None
    judged = [math.log(v) for v in vals] if scale.log else vals
    centre = _median(judged)
    spread = MAD_TO_SD * _median([abs(v - centre) for v in judged])
    usual = math.exp(centre) if scale.log else centre
    half = max(2.0 * spread, max(scale.min_change, scale.rel_change * abs(usual)))
    return Usual(days=len(vals), median=usual, spread=spread, half=half, centre=centre)


def arrow(u: Usual, value: float, scale: Scale) -> str:
    """up, down or none (usual.dart's Usual.arrow, without the 14-day check the caller does)."""
    if u.half <= 0 or (scale.log and value <= 0):
        return "none"
    d = (math.log(value) if scale.log else value) - u.centre
    if abs(d) < u.half:
        return "none"
    return "up" if d > 0 else "down"


# ---- the detector ----


def _clean(values: Mapping[str, float], scale: Scale) -> dict[str, float]:
    return {k: float(v) for k, v in values.items() if math.isfinite(v) and (not scale.log or v > 0)}


def _paused_days(ill: Iterable[Ill], settings: Settings) -> set[str]:
    out: set[str] = set()
    for e in ill:
        end = add_days(e.tapped, settings.pause_days)  # first day no longer paused
        if e.resumed is not None and e.resumed < end:
            end = e.resumed
        d = e.start
        while d < end:
            out.add(d)
            d = add_days(d, 1)
    return out


def _epoch_starts(data_days: Sequence[str], gap: int) -> list[str]:
    starts: list[str] = []
    for i, d in enumerate(data_days):
        if i == 0 or days_between(data_days[i - 1], d) - 1 > gap:
            starts.append(d)
    return starts


def judge(
    series: Mapping[str, Mapping[str, float]],
    first: str,
    last: str,
    ill: Sequence[Ill] = (),
    settings: Settings = Settings(),
    streams: Sequence[Stream] = STREAMS,
) -> list[DayVerdict]:
    """Every day from [first] to [last], oldest first, as the card would have judged it with these numbers."""
    clean = {s.id: _clean(series.get(s.id, {}), s.scale) for s in streams}
    valued = {s.id: sorted(clean[s.id]) for s in streams}
    data_days = sorted({d for s in streams for d in clean[s.id]})
    core_days = sorted({d for s in streams if s.group == "core" for d in clean[s.id]})
    starts = _epoch_starts(data_days, settings.restart_gap)
    paused = _paused_days(ill, settings)
    # each stream's verdict on each valued day, then its runs
    per: dict[str, dict[str, StreamDay]] = {}
    used: dict[str, dict[str, list[str]]] = {}
    for s in streams:
        days = valued[s.id]
        out: dict[str, StreamDay] = {}
        used[s.id] = {}
        prev: str | None = None
        for d in days:
            sd, window = _stream_day(s, clean[s.id], days, d, starts, paused, settings)
            used[s.id][d] = window
            if sd.off:
                p = out.get(prev) if prev is not None else None
                if p is not None and p.off and p.state == sd.state and days_between(prev, d) <= settings.bridge + 1:
                    sd.run, sd.run_start = p.run + 1, p.run_start
                else:
                    sd.run, sd.run_start = 1, d
            out[d] = sd
            prev = d
        per[s.id] = out
    verdicts: list[DayVerdict] = []
    d = first
    while d <= last:
        verdicts.append(_day(d, streams, per, valued, used, core_days, starts, paused, settings))
        d = add_days(d, 1)
    return verdicts


def _stream_day(
    s: Stream,
    values: Mapping[str, float],
    days: Sequence[str],
    d: str,
    starts: Sequence[str],
    paused: set[str],
    settings: Settings,
) -> tuple[StreamDay, list[str]]:
    sd = StreamDay(value=values[d])
    i = bisect.bisect_right(starts, d) - 1
    epoch = starts[i] if i >= 0 else d
    end = add_days(d, -settings.lag_days)
    window: list[str] = []
    k = bisect.bisect_right(days, end) - 1
    while k >= 0 and len(window) < settings.window and days[k] >= epoch:
        if days[k] not in paused:
            window.append(days[k])
        k -= 1
    window.reverse()
    sd.n = len(window)
    u = usual_of_values([values[x] for x in window], s.scale)
    if u is not None:
        sd.usual, sd.spread, sd.half = u.median, u.spread, u.half
    if u is None or sd.n < settings.min_baseline:
        sd.state = "unjudged"
        return sd, window
    a = arrow(u, values[d], s.scale)
    sd.state = "in" if a == "none" else a
    sd.off = a != "none" and s.direction in ("both", a)
    return sd, window


def _day(
    d: str,
    streams: Sequence[Stream],
    per: Mapping[str, Mapping[str, StreamDay]],
    valued: Mapping[str, Sequence[str]],
    used: Mapping[str, Mapping[str, list[str]]],
    core_days: Sequence[str],
    starts: Sequence[str],
    paused: set[str],
    settings: Settings,
) -> DayVerdict:
    i = bisect.bisect_right(starts, d) - 1
    v = DayVerdict(
        day=d,
        phase="on",
        valid_before=bisect.bisect_left(core_days, d),
        epoch_start=starts[i] if i >= 0 else None,
    )
    if d in paused:
        v.phase = "paused"
    elif v.valid_before < settings.silent_days:
        v.phase = "silent"
    for s in streams:
        v.streams[s.id] = per[s.id].get(d, StreamDay())
        if d in used[s.id]:
            v._baseline[s.id] = used[s.id][d]
        days = valued[s.id]
        k = bisect.bisect_right(days, d) - 1
        if k < 0 or days_between(days[k], d) > settings.bridge:
            continue
        last = per[s.id][days[k]]
        if last.run > 0 and last.run_start is not None:
            v.active[s.id] = (last.run, last.state, last.run_start)
            if last.run >= settings.run_days:
                v.on_all.append(s.id)
                if s.group == "core":
                    v.on_core.append(s.id)
    v.rule_core = len(v.on_core) >= settings.min_streams
    v.rule_all = len(v.on_all) >= settings.min_streams
    return v


def episodes(verdicts: Sequence[DayVerdict], key: str = "rule_core", shown_only: bool = False) -> list[tuple[str, str]]:
    """Runs of days with the rule, as (first day, last day); shown_only: only those that began while on."""
    out: list[tuple[str, str]] = []
    start: str | None = None
    prev: DayVerdict | None = None
    for v in verdicts:
        if getattr(v, key):
            if start is None:
                start = v.day
        elif start is not None and prev is not None:
            out.append((start, prev.day))
            start = None
        prev = v
    if start is not None and prev is not None:
        out.append((start, prev.day))
    if shown_only:
        phase = {v.day: v.phase for v in verdicts}
        out = [e for e in out if phase[e[0]] == "on"]
    return out
