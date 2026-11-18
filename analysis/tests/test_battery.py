"""scripts/battery.py: stuck gauge values, trend, time left, reading the recorder's logs."""
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import battery  # noqa: E402

NOW = datetime(2026, 11, 18, 9, 0).timestamp()


def series(levels: list[int], step_min: float = 10) -> list[tuple[float, int]]:
    n = len(levels)
    return [(NOW - (n - 1 - i) * step_min * 60, v) for i, v in enumerate(levels)]


def test_stuck_values_are_not_shown_as_a_level() -> None:
    for v in (1, 2, 100):
        r = battery.estimate(series([40, 39, v]), NOW)
        assert r["level"] is None and r["text"] == f"gauge stuck (reads {v}%)"


def test_too_little_data_shows_only_the_level() -> None:
    r = battery.estimate(series([37, 36], step_min=5), NOW)
    assert r == dict(level=36, per_hour=None, hours_left=None, text="36%")


def test_steady_drain_gives_time_left() -> None:
    r = battery.estimate(series([40, 39, 38, 37, 36, 35, 34], step_min=10), NOW)  # 6 % an hour
    assert r["per_hour"] == 6.0 and r["hours_left"] == round(34 / 6, 1)
    assert r["text"] == "34% · about 6 h left"  # whole hours from 3 h up


def test_stuck_readings_in_between_are_ignored() -> None:
    r = battery.estimate(series([40, 100, 39, 2, 38, 37, 1, 36, 35, 34]), NOW)
    assert r["level"] == 34 and r["per_hour"] is not None and 3.5 < r["per_hour"] < 4.5  # 6 % in 90 min


def test_a_charge_restarts_the_trend() -> None:
    r = battery.estimate(series([30, 25, 20, 80, 80, 79], step_min=10), NOW)
    assert r["level"] == 79 and r["per_hour"] is None  # only 20 min and 1 % since the charge


def test_from_logs_reads_battery_lines(tmp_path: Path) -> None:
    t = lambda m: datetime(2026, 11, 18, 8, m).isoformat(timespec="milliseconds")  # noqa: E731
    (tmp_path / "2026-11-18-081036.log").write_text(
        f"{t(10)} connected BB Black x serial y battery 37% signal -56 dBm\n"
        f"{t(11)} contact ohms O1=1\n"
        f"{t(20)} samples 1 (+1) battery 36%\n"
        f"{t(30)} stopped, battery 35%\n")
    assert [v for _, v in battery.from_logs(tmp_path, NOW)] == [37, 36, 35]
    assert battery.from_logs(tmp_path, NOW + 4 * 3600) == []  # older than 3 hours
