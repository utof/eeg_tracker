"""Back-test of the "Unusual for you" card (`unusual.py`) on synthetic histories (laptop only; DECISIONS 290-299).
The owner has only a few days of numbers, so the false-card rate and the detection rate come from made-up people
whose day-to-day wobble is a planning value (below), not measured:

  uv run --project analysis python analysis/validate_unusual.py [--people 200] [--days 365] [--seed 1]

- stable histories (nothing planted): cards per month once the card is on (after the silent 28 days), the share
  of days with a card, and the share of people who would see a card in their first 8 weeks (an average gap
  between false alarms says nothing about early ones; early-warning pass 2, Q1);
- planted changes (shorter sleep, a cold-like week, low mood, slower reactions, less sharp days, slower reactions
  in the day, a change in the headband's numbers only): the share found (a card in the change's days or the day
  after that the same history without the change does not have) and the median days from the change's first day to the card;
- each for the core numbers only (the card) and with the headband's numbers added (the "both ways" test), and for
  three rules: NightSignal's (one number, 2 days in a row), 3 days in a row, and the research's stricter variant
  (2 numbers together, 2 days in a row).

Prints JSON. The made-up people: sleep 7 h 12 min +- 1 h a night (30 min longer on weekend mornings), sleepiness
4 +- 1.3 of 9, mood 3.6 +- 0.7 of 5, tension 2.4 +- 0.8 of 5, reaction time 280 ms +- 7 %, alpha speed 9.8 +-
0.25 Hz, alpha strength and the eyes-closed rise +- 30 % and 25 %, jaw muscle bursts 20 an hour +- 35 %, sharp hours' day numbers (the mean of a day's ratings 3.4 +- 0.5 of 5 on
70 % of days, the median of its reaction tests 290 ms +- 6 % on half the days); each day partly carries over from the day before (0.3-0.5) and odd days are commoner than a bell curve's (Student t, 5
degrees of freedom); 15 % of nights and 30 % of check-ins missing, the reaction test on half the check-ins. The
"noisier" person has 1.4 times the wobble and more missing days.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import unusual as un  # noqa: E402

START = "2026-01-01"  # a Thursday; the weekday only moves the weekend lie-in


@dataclass(frozen=True)
class Profile:
    name: str
    # stream -> (mean, sd, carry-over) on the generating scale: minutes, rating points, log ms, Hz, log units
    streams: dict[str, tuple[float, float, float]] = field(
        default_factory=lambda: {
            "asleep": (432.0, 60.0, 0.3),
            "kss": (4.0, 1.3, 0.4),
            "mood": (3.6, 0.7, 0.5),
            "tension": (2.4, 0.8, 0.4),
            "reaction": (math.log(280.0), 0.07, 0.3),
            # sharp hours' day numbers (DECISIONS 380; planning values): the mean of a day's 1-5 ratings (a mean
            # of about 4 answers moves less than one rating) and the median of the day's reaction tests
            "sharp": (3.4, 0.5, 0.4),
            "dayrt": (math.log(290.0), 0.06, 0.3),
            "iaf": (9.8, 0.25, 0.3),
            "alpha": (math.log(30.0), 0.30, 0.3),
            "rise": (math.log(2.5), 0.25, 0.3),
            "jaw": (math.log(20.0), 0.35, 0.4),
        }
    )
    weekend_min: float = 30.0
    night_missing: float = 0.15
    checkin_missing: float = 0.30
    reaction_missing: float = 0.5  # of the check-ins
    sharp_missing: float = 0.3  # days with no sharp-hours rating answered
    dayrt_missing: float = 0.5  # days with no reaction test
    tail_df: float = 5.0


DEFAULT = Profile("default")
NOISIER = Profile(
    "noisier",
    streams={k: (m, sd * 1.4, phi) for k, (m, sd, phi) in DEFAULT.streams.items()},
    night_missing=0.25,
    checkin_missing=0.45,
    sharp_missing=0.45,
    dayrt_missing=0.65,
)

LOG_STREAMS = {"reaction", "dayrt", "alpha", "rise", "jaw"}
RATINGS = {"kss": (1, 9), "mood": (1, 5), "tension": (1, 5)}
MEAN_RATINGS = {"sharp": (1, 5)}  # a mean of a day's ratings: kept in range, not rounded
DAY_STREAMS = ("dayrt", "sharp")  # drawn after everything else, so the older numbers of a person never move
NIGHT_STREAMS = {"asleep", "jaw"}


@dataclass(frozen=True)
class Change:
    """A planted change: [shifts] added on the generating scale (log streams: a log factor) on [days] days from
    day [start] (0 = the history's first day)."""

    name: str
    start: int
    days: int
    shifts: dict[str, float]


CHANGES: tuple[Change, ...] = (
    Change("short sleep (2 h, 4 nights)", 0, 4, {"asleep": -120}),
    Change("short sleep (1 h 30 min, 4 nights)", 0, 4, {"asleep": -90}),
    Change("short sleep (1 h, 4 nights)", 0, 4, {"asleep": -60}),
    Change("long sleep (2 h, 4 nights)", 0, 4, {"asleep": 120}),
    Change("a cold-like week (sleep -40 min, sleepier +2, mood -1, tension +1; 7 days)", 0, 7,
           {"asleep": -40, "kss": 2, "mood": -1, "tension": 1}),
    Change("low mood (mood -2, tension +1.5; 7 days)", 0, 7, {"mood": -2, "tension": 1.5}),
    Change("sleepier (+3 points, 5 days)", 0, 5, {"kss": 3}),
    Change("slower reactions (+15 %, 5 days)", 0, 5, {"reaction": math.log(1.15)}),
    Change("headband only (alpha speed +0.5 Hz, alpha strength x1.6; 5 days)", 0, 5,
           {"iaf": 0.5, "alpha": math.log(1.6)}),
    # after the others: the draws of the changes before them stay as they were
    Change("less sharp (-1 point, 5 days)", 0, 5, {"sharp": -1.0}),
    Change("slower in the day (+15 %, 5 days)", 0, 5, {"dayrt": math.log(1.15)}),
)

RULES = {
    "NightSignal: 1 number, 2 days in a row": un.Settings(),
    "1 number, 3 days in a row": un.Settings(run_days=3),
    "2 numbers together, 2 days in a row": un.Settings(min_streams=2),
}


def synthetic_history(
    seed: int, days: int, change: Change | None = None, profile: Profile = DEFAULT
) -> dict[str, dict[str, float]]:
    """One made-up person's per-day numbers, the trends page's ids -> {day: value}. The same seed gives the same
    person, missing days and odd days with or without a planted change."""
    rng = np.random.default_rng(seed)
    scale_t = math.sqrt(profile.tail_df / (profile.tail_df - 2))
    older = [k for k in sorted(profile.streams) if k not in DAY_STREAMS]
    noise = {k: rng.standard_t(profile.tail_df, days) / scale_t for k in older}
    night_seen = rng.random(days) >= profile.night_missing
    checkin_seen = rng.random(days) >= profile.checkin_missing
    reaction_seen = checkin_seen & (rng.random(days) >= profile.reaction_missing)
    seen = {k: (night_seen if k in NIGHT_STREAMS else reaction_seen if k == "reaction" else checkin_seen)
            for k in older}
    # sharp hours' day numbers last (DECISIONS 380): the older numbers are the same people as before they existed
    for k, missing in (("dayrt", profile.dayrt_missing), ("sharp", profile.sharp_missing)):
        if k in profile.streams:
            noise[k] = rng.standard_t(profile.tail_df, days) / scale_t
            seen[k] = rng.random(days) >= missing
    out: dict[str, dict[str, float]] = {}
    for k in sorted(profile.streams):
        mean, sd, phi = profile.streams[k]
        x, series = 0.0, {}
        for t in range(days):
            x = phi * x + math.sqrt(1 - phi * phi) * sd * noise[k][t]
            v = mean + x
            day = un.add_days(START, t)
            if k == "asleep" and un._date(day).weekday() >= 5:
                v += profile.weekend_min
            if change is not None and change.start <= t < change.start + change.days:
                v += change.shifts.get(k, 0.0)
            if k in LOG_STREAMS:
                v = math.exp(v)
            if k in RATINGS:
                lo, hi = RATINGS[k]
                v = float(min(hi, max(lo, round(v))))
            if k in MEAN_RATINGS:
                lo, hi = MEAN_RATINGS[k]
                v = float(min(hi, max(lo, v)))
            if seen[k][t]:
                series[day] = v
        out[k] = series
    return out


def _months_on(verdicts: list[un.DayVerdict]) -> float:
    return sum(1 for v in verdicts if v.phase == "on") / 30.44


def _first_switch_on(verdicts: list[un.DayVerdict]) -> str | None:
    return next((v.day for v in verdicts if v.phase == "on"), None)


def back_test(
    people: int = 200,
    days: int = 365,
    seed: int = 1,
    settings: un.Settings = un.Settings(),
    profile: Profile = DEFAULT,
) -> dict[str, Any]:
    """Stable histories and planted changes for one rule and one kind of person."""
    rng = np.random.default_rng(seed + 10_000)
    stable: dict[str, dict[str, list[float]]] = {g: {"cards": [], "months": [], "card_days": [], "early": []}
                                                  for g in ("core", "all")}
    plain: dict[int, list[un.DayVerdict]] = {}
    last = un.add_days(START, days - 1)
    for p in range(people):
        v = un.judge(synthetic_history(seed + p, days, profile=profile), START, last, settings=settings)
        plain[p] = v
        on = _first_switch_on(v)
        for g, key in (("core", "rule_core"), ("all", "rule_all")):
            eps = [e for e in un.episodes(v, key=key) if next(x.phase for x in v if x.day == e[0]) == "on"]
            stable[g]["cards"].append(len(eps))
            stable[g]["months"].append(_months_on(v))
            stable[g]["card_days"].append(sum(1 for x in v if x.phase == "on" and getattr(x, key)))
            stable[g]["early"].append(
                float(on is not None and any(un.days_between(on, e[0]) < 56 for e in eps))
            )
    out: dict[str, Any] = {"people": people, "days": days, "seed": seed, "profile": profile.name, "stable": {}}
    for g, s in stable.items():
        months, on_days = sum(s["months"]), sum(s["months"]) * 30.44
        out["stable"][g] = {
            "cards_per_month": round(sum(s["cards"]) / months, 3) if months else None,
            "share_of_days_with_a_card": round(sum(s["card_days"]) / on_days, 4) if on_days else None,
            "people_with_a_card_in_their_first_8_weeks": round(statistics.fmean(s["early"]), 3),
        }
    out["changes"] = {}
    for c in CHANGES:
        res: dict[str, dict[str, list[float]]] = {g: {"found": [], "delay": []} for g in ("core", "all")}
        for p in range(people):
            start = int(rng.integers(70, days - 20))
            planted = dataclasses.replace(c, start=start)
            v = un.judge(synthetic_history(seed + p, days, change=planted, profile=profile), START, last,
                         settings=settings)
            window = range(start, start + c.days + 1)
            for g, key in (("core", "rule_core"), ("all", "rule_all")):
                new = [t for t in window if getattr(v[t], key) and not getattr(plain[p][t], key)]
                res[g]["found"].append(float(bool(new)))
                if new:
                    res[g]["delay"].append(new[0] - start)
        out["changes"][c.name] = {
            g: {
                "found": round(statistics.fmean(r["found"]), 3),
                "median_days_to_card": statistics.median(r["delay"]) if r["delay"] else None,
            }
            for g, r in res.items()
        }
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--people", type=int, default=200)
    ap.add_argument("--days", type=int, default=365)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)
    report: dict[str, Any] = {"planning_values": "synthetic people; the wobble is assumed, not measured", "rules": {}}
    for rule, settings in RULES.items():
        report["rules"][rule] = {
            prof.name: back_test(a.people, a.days, a.seed, settings, prof) for prof in (DEFAULT, NOISIER)
        }
    json.dump(report, sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
