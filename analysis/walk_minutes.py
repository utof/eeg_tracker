"""The walking minute rules, standard library only (DECISIONS 800-809): the phone's step counter per clock minute, the
check of the headband's pace against it, and the day numbers. Shared by the detector's reference (walking.py) and the
laptop's export (scripts/day_summary.py, which runs with no numpy); the phone's port is app/lib/walking/detector.dart
(the minutes and the check) and app/lib/walking/days.dart (the days).

A walk file (`<recording>.walk.json`, docs/data-format.md "Walking") keeps one row per clock minute with walking or
phone steps: [t, walk_s, run_s, hb_steps, hb_pace, phone, steps, source, walking_s].
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta

PHONE_WALK_STEPS = 60  # a minute in which the phone counted this many steps is a walking minute
PHONE_MAX_GAP_S = 180.0  # step counter readings further apart than this say nothing about the time between
CHECK_MIN_MINUTES = 10  # paired minutes (both walked the whole minute) before the check says anything
CHECK_PACE_SHARE = 0.05  # a minute's pace is right within this share of the phone's
CHECK_RIGHT_SHARE = 0.8  # right in at least this share of the paired minutes (8 of 10)...
CHECK_TOTAL_SHARE = 0.15  # ... and the totals within this share of the phone's
DAY_START_HOUR = 4  # a day runs 04:00 to 04:00 (the phone's Trends)
WALK_FORMAT, WALK_VERSION = "eeg-tracker-walking", 1


def median(values: list[float]) -> float:
    """Linear interpolation between the sorted values (eeg_detectors.median, features.dart `median`)."""
    s = sorted(float(v) for v in values)
    if not s:
        return math.nan
    i = (len(s) - 1) * 0.5
    lo = math.floor(i)
    return s[lo] + (s[lo + 1] - s[lo]) * (i - lo) if lo + 1 < len(s) else s[lo]


def phone_minutes(readings: list[tuple[float, int]]) -> dict[int, float]:
    """Steps per clock minute (key: unix seconds of the minute's start) from the step counter's readings (unix
    seconds, steps since the phone started; one a minute while recording). The steps between two readings at most
    PHONE_MAX_GAP_S apart go to the minute holding the middle of that time (a longer time in equal minute-long parts,
    each to the minute of its middle), so a minute is never split into fractions of a step. A counter that went down
    (the phone restarted) says nothing until the next reading. Minutes no reading covers are absent (not known)."""
    rs = sorted(readings)
    steps: dict[int, float] = {}
    for (t0, c0), (t1, c1) in zip(rs, rs[1:]):
        if t1 <= t0 or t1 - t0 > PHONE_MAX_GAP_S or c1 < c0:
            continue
        parts = max(1, round((t1 - t0) / 60))
        for j in range(parts):
            mid = t0 + (j + 0.5) * (t1 - t0) / parts
            m = int(math.floor(mid / 60)) * 60
            steps[m] = steps.get(m, 0.0) + (c1 - c0) / parts
    return {m: steps[m] for m in sorted(steps)}


@dataclass
class Minute:
    t: int  # unix seconds of the clock minute's start
    walk_s: float  # headband walking seconds (running included)
    run_s: float  # of them running
    hb_steps: float  # the headband's steps (clear windows of its stretches)
    hb_pace: float | None  # median pace of those windows
    phone: float | None  # the phone's steps; None: no step counter for that minute
    steps: float  # the minute's steps: the phone's when it counted any, else the headband's
    source: str  # "phone", "headband" or "" (no steps)
    walking_s: float  # the minute's walking seconds: 60 when the phone counted PHONE_WALK_STEPS, else walk_s

    def row(self) -> list:
        """The walk file's row (numbers to 0.1)."""
        def r1(v: float | None) -> float | None:
            return None if v is None or (isinstance(v, float) and math.isnan(v)) else round(float(v), 1)
        return [self.t, r1(self.walk_s), r1(self.run_s), r1(self.hb_steps), r1(self.hb_pace), r1(self.phone),
                r1(self.steps), self.source, r1(self.walking_s)]

    @staticmethod
    def of_row(r: object) -> Minute | None:
        """A walk file's row; None when it cannot be read."""
        if not (isinstance(r, list) and len(r) >= 9 and isinstance(r[0], int) and isinstance(r[7], str)):
            return None

        def f(v: object) -> float | None:
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
        return Minute(r[0], f(r[1]) or 0.0, f(r[2]) or 0.0, f(r[3]) or 0.0, f(r[4]), f(r[5]), f(r[6]) or 0.0, r[7],
                      f(r[8]) or 0.0)


@dataclass
class Check:
    paired: int  # minutes both walked the whole of: the headband all 60 s, the phone PHONE_WALK_STEPS or more
    right: int  # of them with the headband's pace within CHECK_PACE_SHARE of the phone's steps
    hb_steps: float  # the paired minutes' totals
    phone_steps: float
    status: str  # "unchecked" (under CHECK_MIN_MINUTES), "passed" or "failed"


def check(rows: list[Minute]) -> Check:
    """Does the headband's pace hold against the phone's step counter (the research note's gate)?"""
    paired = [r for r in rows if r.walk_s >= 60 and r.hb_pace is not None and r.phone is not None
              and r.phone >= PHONE_WALK_STEPS]
    right = sum(1 for r in paired if abs(r.hb_pace - r.phone) <= CHECK_PACE_SHARE * r.phone)
    hb, ph = sum(r.hb_steps for r in paired), sum(r.phone for r in paired)
    if len(paired) < CHECK_MIN_MINUTES:
        status = "unchecked"
    elif right >= CHECK_RIGHT_SHARE * len(paired) and abs(hb - ph) <= CHECK_TOTAL_SHARE * ph:
        status = "passed"
    else:
        status = "failed"
    return Check(len(paired), right, hb, ph, status)


# ------------------------------------------------------------------------------------------------------- the days


def day_of(t: int) -> str:
    """The 04:00-04:00 day of unix time t, on this computer's clock."""
    return (datetime.fromtimestamp(t).astimezone() - timedelta(hours=DAY_START_HOUR)).date().isoformat()


def unique_minutes(walks: list[dict], not_mine: list[tuple[float, float]] = ()) -> list[Minute]:
    """The minutes of the walk files once each: the longest recording's first (most windows; then the recording's
    name), outside the not_mine spans (unix seconds: nights someone else wore the headband for)."""
    taken: dict[int, Minute] = {}
    for w in sorted(walks, key=lambda w: (-int(w.get("windows") or 0), str(w.get("recording")))):
        for r in w.get("minutes") or []:
            m = Minute.of_row(r)
            if m is None or m.t in taken or any(a <= m.t < b for a, b in not_mine):
                continue
            taken[m.t] = m
    return [taken[k] for k in sorted(taken)]


@dataclass
class WalkDays:
    minutes: dict[str, float]  # day -> walking minutes (days with at least 1)
    steps: dict[str, float]  # day -> steps counted (the headband's left out while the check has failed)
    phone: dict[str, float]  # day -> the phone's steps
    headband: dict[str, float]  # day -> the headband's steps
    check: Check

    def source(self, day: str) -> str:
        p, h = self.phone.get(day, 0) > 0, self.headband.get(day, 0) > 0 and self.check.status != "failed"
        return "phone and headband" if p and h else "phone" if p else "headband" if h else "none"


def walk_days(rows: list[Minute]) -> WalkDays:
    """Walking minutes and steps per day from unique minutes (the phone's walking/days.dart rules)."""
    chk = check(rows)
    walking: dict[str, float] = {}
    phone: dict[str, float] = {}
    headband: dict[str, float] = {}
    for m in rows:
        d = day_of(m.t)
        walking[d] = walking.get(d, 0.0) + m.walking_s / 60
        if m.source == "phone":
            phone[d] = phone.get(d, 0.0) + m.steps
        elif m.source == "headband":
            headband[d] = headband.get(d, 0.0) + m.steps
    hidden = chk.status == "failed"
    steps = {}
    for d in sorted(set(phone) | set(headband)):
        s = phone.get(d, 0.0) + (0.0 if hidden else headband.get(d, 0.0))
        if s > 0:
            steps[d] = s
    return WalkDays({d: v for d, v in walking.items() if v >= 1}, steps, phone, headband, chk)
