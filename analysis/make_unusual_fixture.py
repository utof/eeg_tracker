"""Make app/test/fixtures/unusual.json: per-day numbers and what the Python reference (`unusual.py`) makes of every
day, for the Dart port's cross-check (app/test/unusual_cross_check_test.dart).

  uv run --project analysis python analysis/make_unusual_fixture.py app/test/fixtures/unusual.json

Made-up numbers only (`validate_unusual.py`'s synthetic people and a few written by hand); no one's data.
Cases: a synthetic person with a planted cold-like week (sharp hours' day numbers included); the same with the
research's 2-number rule; short nights with "feeling ill" tapped and resumed; a long break that starts the usual
again; log-scale and rating edge cases with missing days; and sharp hours' day numbers, one direction each.
Values are written with Python's shortest round-trip form, so both sides start from the very same doubles.
"""

from __future__ import annotations

import dataclasses
import json
import math
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import unusual as un  # noqa: E402
import validate_unusual as vu  # noqa: E402

START = vu.START


def _hand_nights(n: int, short: dict[int, float], gap: range | None = None) -> dict[str, dict[str, float]]:
    s: dict[str, float] = {}
    for k in range(n):
        if gap is not None and k in gap:
            continue
        s[un.add_days(START, k)] = short.get(k, 420.0 + 10.0 * ((k % 3) - 1))
    mood = {un.add_days(START, k): (4.0 if k % 4 else 3.0) for k in range(n) if k % 5 != 2}
    return {"asleep": s, "mood": mood}


def _edges(n: int) -> dict[str, dict[str, float]]:
    """Log streams with a zero and a negative value, ratings that sit on the 2-point edge, a reaction run that
    bridges a missing day, jaw rates with a quarter-of-usual floor."""
    d = lambda k: un.add_days(START, k)  # noqa: E731
    alpha = {d(k): 30.0 * (1.1 if k % 2 else 0.9) for k in range(n)}
    alpha[d(40)] = 0.0
    alpha[d(41)] = -3.0
    alpha[d(50)] = alpha[d(51)] = 150.0
    rise = {d(k): 2.5 + 0.1 * (k % 3) for k in range(0, n, 2)}
    rise[d(60)] = 0.4
    kss = {d(k): 4.0 for k in range(n)}
    kss[d(44)] = kss[d(45)] = 6.0  # exactly 2 points: beyond
    kss[d(47)] = 5.0  # 1 point: in range
    reaction = {d(k): 280.0 + 4.0 * (k % 5) for k in range(n)}
    for k in (55, 57):
        reaction[d(k)] = 330.0
    del reaction[d(56)]
    jaw = {d(k): 20.0 + (k % 4) for k in range(n)}
    jaw[d(62)] = jaw[d(63)] = 27.0
    return {"alpha": alpha, "rise": rise, "kss": kss, "reaction": reaction, "jaw": jaw}


def _day_numbers(n: int) -> dict[str, dict[str, float]]:
    """Sharp hours' day numbers (DECISIONS 380): a mean rating with a half-point dip (inside), a one-point dip two
    days running (beyond), then a sharper run (a direction that never counts); a day reaction time with a 7 % rise
    (inside), a 12 % rise bridging a missing day (beyond) and a quicker run (never)."""
    d = lambda k: un.add_days(START, k)  # noqa: E731
    sharp = {d(k): 3.5 + 0.1 * ((k % 3) - 1) for k in range(n)}
    sharp[d(40)] = sharp[d(41)] = 3.0
    sharp[d(46)] = sharp[d(47)] = 2.4
    sharp[d(55)] = sharp[d(56)] = 4.9
    dayrt = {d(k): 300.0 + 3.0 * ((k % 3) - 1) for k in range(0, n, 1) if k % 7 != 3}
    dayrt[d(42)] = dayrt[d(43)] = 321.0
    dayrt[d(50)] = dayrt[d(52)] = 340.0
    del dayrt[d(51)]
    dayrt[d(58)] = dayrt[d(59)] = 250.0
    return {"sharp": sharp, "dayrt": dayrt}


def _expected(verdicts: list[un.DayVerdict], with_streams: bool) -> list[dict[str, Any]]:
    out = []
    for v in verdicts:
        streams = {
            k: {
                f: x
                for f, x in (
                    ("n", s.n),
                    ("usual", s.usual),
                    ("spread", s.spread),
                    ("half", s.half),
                    ("state", s.state),
                    ("off", s.off),
                    ("run", s.run),
                    ("run_start", s.run_start),
                )
                if x is not None
            }
            for k, s in v.streams.items()
            if s.value is not None and with_streams
        }
        out.append(
            {
                "day": v.day,
                "phase": v.phase,
                "valid_before": v.valid_before,
                "epoch_start": v.epoch_start,
                "active": {k: list(a) for k, a in v.active.items()},
                "on_core": v.on_core,
                "on_all": v.on_all,
                "rule_core": v.rule_core,
                "rule_all": v.rule_all,
                "streams": streams,
            }
        )
    return out


def _case(name: str, series: dict[str, dict[str, float]], last: str, ill: list[un.Ill] | None = None,
          settings: un.Settings | None = None, with_streams: bool = True) -> dict[str, Any]:
    settings = settings or un.Settings()
    ill = ill or []
    first = min(d for s in series.values() for d in s)
    verdicts = un.judge(series, first, last, ill=ill, settings=settings)
    return {
        "name": name,
        "series": {k: dict(sorted(v.items())) for k, v in series.items()},
        "first": first,
        "last": last,
        "ill": [dataclasses.asdict(e) for e in ill],
        "settings": {"min_streams": settings.min_streams, "run_days": settings.run_days},
        "episodes": [list(e) for e in un.episodes(verdicts)],
        "episodes_all": [list(e) for e in un.episodes(verdicts, key="rule_all")],
        "days": _expected(verdicts, with_streams),
    }


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    cold = vu.Change("cold-like week", 95, 7, {
        "asleep": -90, "kss": 3, "mood": -2, "tension": 2, "iaf": 0.6, "sharp": -1.2, "dayrt": math.log(1.15)})
    person = vu.synthetic_history(7, 130, change=cold)
    day = lambda k: un.add_days(START, k)  # noqa: E731
    cases = [
        _case("a made-up person with a planted cold-like week", person, day(129)),
        _case("the same with the 2-number rule (the rule only)", person, day(129), settings=un.Settings(min_streams=2),
              with_streams=False),
        _case("short nights, feeling ill tapped, then resumed",
              _hand_nights(90, {40: 300.0, 41: 290.0, 42: 310.0, 70: 250.0, 72: 260.0}), day(89),
              ill=[un.Ill(start=day(41), tapped=day(42), resumed=day(50))]),
        _case("a long break starts the usual again",
              _hand_nights(110, {100: 280.0, 101: 270.0}, gap=range(40, 58)), day(109)),
        _case("log scale, ratings on the edge, a bridged reaction run", _edges(70), day(69)),
        _case("sharp hours' day numbers: less sharp and slower count, the other ways and small steps do not",
              _day_numbers(70), day(69)),
    ]
    out = {
        "version": 1,
        "made_by": "analysis/make_unusual_fixture.py",
        "settings": dataclasses.asdict(un.Settings()),
        "cases": cases,
    }
    Path(argv[0]).write_text(json.dumps(out, separators=(",", ":")) + "\n")
    print(f"{argv[0]}: {len(cases)} cases, {sum(len(c['days']) for c in cases)} days")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
