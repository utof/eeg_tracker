"""Makes app/test/fixtures/learning_trend.json: SciPy's Theil-Sen slope and its 90 % range (Sen 1968) on a few
made-up series, for the meditation learning verdict's trend (app/lib/meditation/trend.dart, checked in
app/test/meditation_learning_test.dart). SciPy is the independent reference; nothing here is the owner's data.

usage (from the repo root):
  uv run --project analysis python app/test/fixtures/make_trend_fixture.py

Cases: 8 and 12 sessions rising, flat, falling; a share that is mostly 0 (many ties, as muscle time often is);
one wild session among 12; numbers rounded to 3 decimals as the session files keep them. x is the session's
number (1, 2, ...), as in the app. Values are written in Python's shortest round-trip form, so both sides start
from the very same doubles.
"""

import json
import sys
from pathlib import Path

import numpy as np
from scipy import stats

LEVEL = 0.90


def _case(name: str, y: list[float]) -> dict[str, object]:
    x = [float(i + 1) for i in range(len(y))]
    r = stats.theilslopes(y, x, alpha=LEVEL)
    return {
        "name": name,
        "x": x,
        "y": y,
        "slope": float(r.slope),
        "low": float(r.low_slope),
        "high": float(r.high_slope),
    }


def main(argv: list[str]) -> int:
    out = Path(argv[0]) if argv else Path(__file__).with_name("learning_trend.json")
    rng = np.random.default_rng(20261119)
    noise = lambda n, sd: rng.normal(0, sd, n)  # noqa: E731
    r3 = lambda v: [round(float(a), 3) for a in v]  # noqa: E731
    cases = [
        _case("8 sessions rising", r3(0.02 * np.arange(8) + noise(8, 0.02))),
        _case("8 sessions flat", r3(noise(8, 0.05))),
        _case("8 sessions falling", r3(0.08 - 0.015 * np.arange(8) + noise(8, 0.01))),
        _case("12 sessions rising slowly", r3(0.05 + 0.006 * np.arange(12) + noise(12, 0.03))),
        _case("12 sessions with one wild session", r3([*(0.01 * np.arange(11) + noise(11, 0.01)), 0.9])),
        _case("a share that is mostly 0 (ties)", [0.0, 0.0, 0.05, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.02]),
        _case("muscle share rising with ties", [0.0, 0.0, 0.01, 0.01, 0.03, 0.02, 0.05, 0.08]),
        _case("9 sessions, exact integers", [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0]),
    ]
    data = {"version": 1, "made_by": "app/test/fixtures/make_trend_fixture.py", "level": LEVEL, "cases": cases}
    out.write_text(json.dumps(data, indent=1) + "\n")
    print(f"{out}: {len(cases)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
