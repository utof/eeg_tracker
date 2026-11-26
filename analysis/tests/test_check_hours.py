"""The emulator checks of the questions (app/tool/confirm_check.py, asking_check.py) at every hour of the day.

Both seed their stretches relative to the device's clock. The app's day runs 04:00 to 04:00: a stretch that ended
before 04:00 is worded to the half hour once it is past 04:00 and loses "Yes, but the times are off" (DECISIONS 965).
The checks expected the minute wording at every hour and were red between 04:00 and about 05:30 (the runs of
2026-11-26 04:20-05:00, DECISIONS 1090). The expected words here are written out by hand, not worked out by the
checks' own helpers."""
from __future__ import annotations

import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "app" / "tool"


def _tool(name: str) -> ModuleType:
    """A check of app/tool under a name of its own: `asking_check` is also the monthly self-check of scripts/, which
    another test file imports under that name."""
    spec = importlib.util.spec_from_file_location(f"tool_{name}", TOOL / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    held = {k: sys.modules.get(k) for k in ("asking_check", "confirm_check")}
    sys.path.insert(0, str(TOOL))
    try:
        for k in held:  # the two checks import each other by their plain names
            sys.modules.pop(k, None)
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(TOOL))
        for k, v in held.items():
            sys.modules.pop(k, None)
            if v is not None:
                sys.modules[k] = v
    return module


ac = _tool("asking_check")
cc = _tool("confirm_check")


@pytest.fixture(autouse=True)
def _the_tools_own_names(monkeypatch: pytest.MonkeyPatch) -> None:
    """confirm_check.py imports asking_check when it seeds: that must be the tool's, not the one of scripts/."""
    monkeypatch.setitem(sys.modules, "asking_check", ac)
    monkeypatch.setitem(sys.modules, "confirm_check", cc)


MSK = timezone(timedelta(hours=3))


def at(hour: int, minute: int) -> datetime:
    return datetime(2026, 11, 26, hour, minute, 17, tzinfo=MSK)


def test_a_stretch_keeps_its_minutes_only_on_its_own_day() -> None:
    sleep = (at(1, 3), at(2, 55))
    assert ac.card_words(*sleep, at(3, 59)) == "01:03-02:55"
    assert ac.card_words(*sleep, at(4, 28)) == "about 01:00 to 03:00"
    assert ac.card_words(at(3, 46), at(4, 7), at(4, 28)) == "03:46-04:07"
    assert ac.card_words(at(22, 25) - timedelta(days=1), at(0, 15), at(1, 45)) == "22:25-00:15"
    evening = (at(21, 50) - timedelta(days=1), at(23, 40) - timedelta(days=1))
    assert ac.card_words(*evening, at(1, 10)) == "yesterday 21:50-23:40"
    assert ac.card_words(*evening, at(8, 0)) == "yesterday, about 22:00 to 23:30"
    assert ac.card_words(at(10, 50), at(11, 10), at(12, 0) + timedelta(days=1)) == "yesterday, about 11:00"


def test_at_a_quarter_to_two_every_card_is_to_the_minute(tmp_path: Path) -> None:
    _, want = ac.made_up(tmp_path / "a", at(1, 45))
    assert want["sleep"].endswith("-00:15. The headband thinks you slept. Did you?")
    assert want["sleep"][:2] == "22" and want["sleep_title"] == want["sleep"].split(". ")[0]
    assert want["walk"].endswith("-01:00. The headband thinks you walked. Did you?") and want["walk"][:3] == "00:"
    assert want["blind"].startswith("What were you doing 01:") and "about" not in want["blind"]
    assert want["links"] == ["sleep", "walk"]
    _, questions = cc.made_up(tmp_path / "c", at(1, 45))
    assert [q.split(". ")[0][-5:] for q in questions] == ["00:15", "01:00", "01:30"]
    assert not any("bout" in q for q in questions)


def test_at_ten_past_five_the_sleep_is_to_the_half_hour_and_has_no_times_link(tmp_path: Path) -> None:
    _, want = ac.made_up(tmp_path / "a", at(5, 10))  # sleep to 03:40, the sure walk to 04:25, the blind one after it
    assert want["sleep"] == "About 02:00 to 03:30. The headband thinks you slept. Did you?"
    assert want["sleep_title"] == "About 02:00 to 03:30"
    assert want["walk"].endswith("-04:25. The headband thinks you walked. Did you?") and want["walk"][:3] == "03:"
    assert want["blind"].startswith("What were you doing 04:")
    assert want["links"] == ["walk"]
    _, questions = cc.made_up(tmp_path / "c", at(5, 10))
    assert questions[0] == "About 02:00 to 03:30. The headband thinks you slept. Did you?"
    assert [q.split(". ")[0][-5:] for q in questions[1:]] == ["04:25", "04:55"]


def test_the_clock_is_put_forward_only_where_the_check_cannot_run() -> None:
    assert ac.clock_for_the_check(at(4, 28)) == datetime(2026, 11, 26, 4, 50, tzinfo=MSK)
    assert ac.clock_for_the_check(at(3, 30)) == datetime(2026, 11, 26, 4, 50, tzinfo=MSK)
    assert ac.clock_for_the_check(at(3, 29)) is None
    assert ac.clock_for_the_check(at(4, 50)) is None
    assert ac.clock_for_the_check(at(0, 20)) == datetime(2026, 11, 26, 1, 2, tzinfo=MSK)
    assert ac.clock_for_the_check(at(23, 45)) == datetime(2026, 11, 27, 1, 2, tzinfo=MSK)
    assert ac.clock_for_the_check(at(13, 0)) is None


def test_at_every_minute_of_the_day_the_check_has_what_it_needs(tmp_path: Path) -> None:
    """After the clock rule: the sure walk can have its times corrected, and neither midnight nor 04:00 comes within the
    half hour a run takes (it would change the cards' words under the check)."""
    run = timedelta(minutes=30)
    for minute in range(24 * 60):
        asked = datetime(2026, 11, 26, tzinfo=MSK) + timedelta(minutes=minute, seconds=41)
        now = ac.clock_for_the_check(asked) or asked
        assert now >= asked and ac.clock_for_the_check(now) is None, asked
        assert (now + run).date() == now.date(), asked
        assert (now + run - timedelta(hours=4)).date() == (now - timedelta(hours=4)).date(), asked
        if minute % 7 == 0:  # the seeding itself, every seventh minute (it writes files)
            _, want = ac.made_up(tmp_path / "a", now)
            assert "walk" in want["links"], asked
            assert "bout" not in want["walk"] and "bout" not in want["blind"], asked
            assert now - want["earlier"] >= timedelta(minutes=61) and want["earlier"].date() == now.date(), asked
            _, questions = cc.made_up(tmp_path / "c", now)
            assert len(set(questions)) == 3, asked
