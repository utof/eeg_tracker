"""The meditation learning verdict's trend (app/lib/meditation/trend.dart) is checked against
app/test/fixtures/learning_trend.json in app/test/meditation_learning_test.dart. This test says the expected numbers
in that file are SciPy's own: Theil-Sen slope and Sen's 90 % range on the file's series (made by
app/test/fixtures/make_trend_fixture.py), so a hand edit or another SciPy cannot slip in unnoticed.
"""
import json
from pathlib import Path

from scipy import stats

FIXTURE = Path(__file__).resolve().parents[2] / "app" / "test" / "fixtures" / "learning_trend.json"


def test_the_expected_numbers_are_scipys_theilslopes_at_90_percent():
    data = json.loads(FIXTURE.read_text())
    assert data["level"] == 0.9
    assert len(data["cases"]) >= 8
    for c in data["cases"]:
        r = stats.theilslopes(c["y"], c["x"], alpha=data["level"])
        got = (float(r.slope), float(r.low_slope), float(r.high_slope))
        want = (c["slope"], c["low"], c["high"])
        assert all(abs(g - w) <= 1e-12 for g, w in zip(got, want)), (c["name"], got, want)


def test_the_cases_cover_ties_and_both_check_sizes():
    cases = json.loads(FIXTURE.read_text())["cases"]
    assert {len(c["y"]) for c in cases} >= {8, 12}
    assert any(len(set(c["y"])) < len(c["y"]) for c in cases)  # tied values (a share that is often 0)
    assert any(c["low"] > 0 for c in cases) and any(c["high"] < 0 for c in cases)
    assert any(c["low"] <= 0 <= c["high"] for c in cases)
