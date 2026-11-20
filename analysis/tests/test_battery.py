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


# ---- the one stuck rule and the charge by wear time (DECISIONS 766) -------------------------------------------------

def streaming(start: float, minutes: float, value: int | list[int], every_s: float = 10) -> list[tuple[float, int]]:
    """Readings every 10 s while the headband streams, one value or one per reading."""
    n = int(minutes * 60 / every_s)
    vals = value if isinstance(value, list) else [value] * n
    return [(start + k * every_s, vals[k]) for k in range(n)]


def test_any_value_unchanged_for_an_hour_of_streaming_is_stuck() -> None:
    t0 = NOW - 3 * 3600
    pts = [(t0, 99)] + streaming(t0 + 30, 61, 6)  # the 2026-11-19 night: 99 % at connect, then 6 % for good
    assert battery.stuck_values(pts) == battery.STUCK | {6}
    assert battery.believable(pts) == [(t0, 99)]
    assert battery.stuck_values([(t0, 99)] + streaming(t0 + 30, 50, 6)) == battery.STUCK  # 50 min: not yet


def test_a_stuck_value_stays_stuck_across_a_reconnect_and_only_streaming_time_counts() -> None:
    t0 = NOW - 6 * 3600
    a = streaming(t0, 40, 6)
    b = streaming(a[-1][0] + 2 * 3600, 25, 6)  # two hours off the stream, then the same frozen value
    assert battery.stuck_values(a + b) == battery.STUCK | {6}  # 40 + 25 min streamed
    c = streaming(a[-1][0] + 2 * 3600, 15, 6)
    assert 6 not in battery.stuck_values(a + c)  # 55 min streamed: the two hours off do not count
    # readings ten minutes apart are not streaming: a slow real fall is never stuck
    assert battery.stuck_values(series([50] * 12)) == battery.STUCK


def test_a_real_fall_is_never_stuck() -> None:
    t0 = NOW - 3 * 3600
    vals = [96 - k // 33 for k in range(2 * 360)]  # about 11 %/h in 10 s readings, 5.5 min per point
    assert battery.stuck_values(streaming(t0, 120, vals)) == battery.STUCK


def test_the_charge_by_wear_time() -> None:
    t0 = NOW - 4 * 3600
    pts = [(t0, 99)] + streaming(t0 + 10, 120, 6)
    est = battery.wear_estimate(pts, pts[-1][0])
    assert est["full"] == 99 and est["since"] == t0 and est["hours"] == 2.0
    assert est["pct"] == round(99 - battery.DRAIN_PER_H * 2)
    # a full reading after a short drop is not a charge (the gauge read 100 % after 5.3 h on 2026-11-20) ...
    later = pts + [(pts[-1][0] + 20, 100)] + streaming(pts[-1][0] + 30, 30, 6)
    assert battery.wear_estimate(later, later[-1][0])["full"] == 99
    # ... one after 30 minutes or more off the stream may be
    charged = pts + [(pts[-1][0] + 31 * 60, 100)] + streaming(pts[-1][0] + 31 * 60 + 10, 30, 100)
    est = battery.wear_estimate(charged, charged[-1][0])
    assert est["full"] == 100 and est["hours"] == 0.5 and est["pct"] == round(100 - battery.DRAIN_PER_H / 2)
    assert battery.wear_estimate(streaming(t0, 30, 70), NOW) is None  # no full reading: no estimate
    long = [(t0, 99)] + streaming(t0 + 10, 600, 6)
    assert battery.wear_estimate(long, long[-1][0])["pct"] == 0  # never below 0


def test_the_live_note_shows_a_stuck_gauge_and_the_estimate() -> None:
    t0 = NOW - 2 * 3600
    pts = [(t0, 98)] + streaming(t0 + 10, 70, 6)
    r = battery.estimate(pts, pts[-1][0])
    assert r["level"] is None
    left = round(98 - battery.DRAIN_PER_H * 70 / 60)
    assert r["text"] == f"gauge stuck (reads 6%); about {left}% by wear time (estimate)"
