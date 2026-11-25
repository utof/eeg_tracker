"""The real-time tests are marked, so a suite run on a loaded machine can keep them apart.

They wait on the wall clock (a fake headband's timers, a few seconds of silence) and fail when the desktop is busy
while passing alone. Marked `realtime` (pytest) and tagged `realtime` (Flutter), they run in a second step, alone:
everything else in parallel first (`pytest -n 4 -m "not realtime"`, `flutter test --exclude-tags realtime`), then
`pytest -m realtime` and `flutter test --tags realtime --concurrency=1`. Nothing they check was loosened."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "analysis" / "tests"
APP_TEST = ROOT / "app" / "test"

PYTHON_FILES = ["test_diy_board.py", "test_fake_headband.py", "test_own_ble_driver.py"]
FLUTTER_FILES = [
    "own_ble_controller_test.dart", "own_ble_driver_test.dart", "own_ble_mending_test.dart", "own_ble_probe_test.dart",
    "own_ble_sessions_test.dart", "diy_night_test.dart",
]
FLUTTER_TESTS = {
    "one_connection_test.dart": "Start sleep with nothing live",
    "night_recorder_test.dart": "failed direct tries back off",
}


def test_the_marker_is_registered() -> None:
    assert "realtime" in (TESTS / "conftest.py").read_text()


def test_the_python_real_time_files_are_marked() -> None:
    for name in PYTHON_FILES:
        assert re.search(r"^pytestmark = pytest\.mark\.realtime\b", (TESTS / name).read_text(), re.M), name


def test_the_kept_link_test_is_marked() -> None:
    text = (TESTS / "test_tray_phone.py").read_text()
    assert re.search(r"@pytest\.mark\.realtime\ndef test_a_real_kept_link_starts_and_stops\(", text)


def test_the_flutter_tag_is_declared_and_the_real_time_files_carry_it() -> None:
    assert "realtime:" in (ROOT / "app" / "dart_test.yaml").read_text()
    for name in FLUTTER_FILES:
        assert "@Tags(['realtime'])\nlibrary;" in (APP_TEST / name).read_text(), name


def test_the_single_flutter_tests_carry_it() -> None:
    for name, start in FLUTTER_TESTS.items():
        text = (APP_TEST / name).read_text()
        at = text.index(start)
        after = text.find("\n  test(", at + 1)
        assert "tags: 'realtime'" in text[at : after if after > 0 else len(text)], name
