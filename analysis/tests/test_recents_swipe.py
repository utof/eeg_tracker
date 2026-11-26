"""The Recents swipe of the emulator checks (app/tool/recents_swipe.py, record_check's step L1).

On the laptop's emulator the step failed every run with "swiped False" because (1) the first quick swipe after Recents
opens is mostly ignored there and (2) a task removed while Recents is open leaves only about a second after Home, which
the old check did not wait for. The fixtures are real screens and lists read from that emulator (Android 16, Pixel
launcher, gesture navigation, 2026-11-26); the retry logic runs against a small fake device, no emulator."""
from __future__ import annotations

from pathlib import Path

import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app" / "tool"))
import recents_swipe as rs  # noqa: E402

FIX = ROOT / "analysis" / "tests" / "fixtures" / "recents"
PKG = "io.github.utof.eeg_tracker"
ACTIVITY = f"{PKG}/.MainActivity"
SCREEN = (1080, 2400)
APP_SCREEN = '<?xml version="1.0"?><hierarchy rotation="0"><node resource-id="android:id/content" class="x" bounds="[0,0][1080,2400]" /></hierarchy>'


def fixture(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


ONE_CARD = fixture("laptop_emulator_one_card.xml")
STACK = fixture("am_stack_list_laptop_two_apps.txt")
RECENTS = fixture("dumpsys_recents_laptop_two_apps.txt")


# ---- reading the device ----------------------------------------------------------------------------------------------


def test_the_apps_task_and_its_root_task_come_from_the_stack_list() -> None:
    assert rs.app_tasks(STACK, PKG) == [rs.AppTask(root=23, task=23)]
    assert rs.app_tasks(STACK, "com.android.settings") == [rs.AppTask(root=21, task=21)]


def test_a_task_that_sits_in_another_root_task_is_removed_by_the_root_ids() -> None:
    # the launcher's task 6 lives in root task 1: `am stack remove` takes the root id, not the task id
    assert rs.app_tasks(STACK, "com.google.android.apps.nexuslauncher") == [rs.AppTask(root=1, task=6)]


def test_no_task_when_the_app_is_not_in_the_stack_list() -> None:
    assert rs.app_tasks(STACK.replace(PKG, "io.github.other"), PKG) == []
    assert rs.app_tasks("", PKG) == []


def test_a_package_that_only_starts_like_the_app_is_not_the_app() -> None:
    assert rs.app_tasks(STACK.replace(f"taskId=23: {PKG}/", f"taskId=23: {PKG}2/"), PKG) == []


def test_the_recents_list_names_the_app() -> None:
    assert rs.in_recents(RECENTS, PKG)
    assert not rs.in_recents(RECENTS.replace(PKG, "io.github.other"), PKG)
    assert not rs.in_recents("", PKG)


def test_a_recents_entry_with_the_affinity_only_counts_too() -> None:
    assert rs.in_recents(f"  * Recent #0: Task{{4d8cfae #23 type=standard A=10216:{PKG}}}", PKG)
    assert not rs.in_recents(f"  * Recent #0: Task{{4d8cfae #23 type=standard A=10216:{PKG}.other}}", PKG)


# ---- the card on the screen ------------------------------------------------------------------------------------------


def test_the_card_is_found_in_the_dump_from_the_laptop_emulator() -> None:
    card = rs.find_card(ONE_CARD, "EEG Tracker")
    assert card == rs.Card(173, 207, 907, 2006, "EEG Tracker")
    assert (card.cx, card.cy) == (540, 1106)


def test_the_first_run_tip_does_not_hide_the_card() -> None:
    card = rs.find_card(fixture("laptop_emulator_one_card_with_tip.xml"), "EEG Tracker")
    assert card == rs.Card(173, 207, 907, 2006, "EEG Tracker")


def test_with_two_cards_the_one_named_for_the_app_is_chosen_and_the_other_is_clipped_to_the_screen() -> None:
    dump = fixture("laptop_emulator_two_cards.xml")
    assert [c.label for c in rs.cards(dump)] == ["Settings", "EEG Tracker"]
    assert rs.find_card(dump, "EEG Tracker") == rs.Card(173, 207, 907, 2006, "EEG Tracker")
    assert rs.find_card(dump, "Settings") == rs.Card(0, 207, 131, 2006, "Settings")


def test_with_two_cards_and_no_name_match_no_card_is_taken() -> None:
    assert rs.find_card(fixture("laptop_emulator_two_cards.xml"), "Something else") is None


def test_a_lone_card_is_the_apps_even_when_its_label_differs() -> None:
    assert rs.find_card(ONE_CARD, "Another name") is not None


def test_a_screen_that_is_not_recents_has_no_card() -> None:
    assert rs.cards(APP_SCREEN) == []
    assert rs.find_card(APP_SCREEN, "EEG Tracker") is None
    assert rs.find_card("", "EEG Tracker") is None
    assert rs.find_card("<?xml not xml </hierarchy>", "EEG Tracker") is None


def test_the_screen_size_is_read_from_the_dump() -> None:
    assert rs.screen_size(ONE_CARD) == SCREEN
    assert rs.screen_size("", (720, 1280)) == (720, 1280)


# ---- the gestures ----------------------------------------------------------------------------------------------------


def test_every_gesture_starts_inside_the_card_and_ends_on_the_screen() -> None:
    card = rs.find_card(ONE_CARD, "EEG Tracker")
    assert card is not None
    tries = rs.gestures(card, *SCREEN)
    assert len(tries) >= 3
    for g in tries:
        assert card.left <= g.x0 <= card.right and card.top <= g.y0 <= card.bottom, g
        assert 0 <= g.x1 < SCREEN[0] and 0 <= g.y1 < SCREEN[1], g


def test_the_first_gestures_are_quick_flings_up_a_slow_drag_does_not_dismiss_a_card_there() -> None:
    first, second, third, *rest = rs.gestures(rs.find_card(ONE_CARD, "EEG Tracker"), *SCREEN)
    assert first.command == "input swipe 540 1106 540 107 120"
    assert second.command == "input swipe 540 1106 540 107 80"
    assert first.y1 < first.y0 and first.ms <= 120 and second.ms <= 120
    assert not first.fresh and not second.fresh
    assert third.fresh and (third.x0, third.y0, third.x1, third.y1, third.ms) == (first.x0, first.y0, first.x1, first.y1, first.ms)
    assert any(g.ms >= 250 for g in rest) and any(g.y1 == g.y0 for g in rest), "a slower one, and one sideways, come last"


def test_without_a_card_the_gestures_start_at_the_middle_of_the_screen() -> None:
    first = rs.gestures(None, *SCREEN)[0]
    assert (first.x0, first.y0) == (540, 1200)
    assert first.y1 == 200


# ---- the retry logic, against a fake device --------------------------------------------------------------------------


class FakeDevice:
    """A device whose app task leaves at the first swipe from the `takes_on`-th on (None: never) that is made over a
    Recents session numbered `works_from_session` or later, or when
    `am stack remove` has been called and Home was pressed 0.7 s ago (as measured on the laptop's emulator)."""

    def __init__(self, takes_on: int | None, *, removal_works: bool = True, has_task: bool = True, card: bool = True,
                 works_from_session: int = 1) -> None:
        self.commands: list[str] = []
        self.now = 0.0
        self.swipes = 0
        self.takes_on = takes_on
        self.removal_works = removal_works
        self.task = has_task
        self.card = card
        self.recents_open = False
        self.removed = False
        self.remove_at: float | None = None
        self.closes_on_swipe: int | None = None  # that swipe closes Recents instead (a tap landed on the card)
        self.sessions = 0  # App switch presses: a "stuck" Recents session ignores every swipe (seen 1 in 5 on the laptop)
        self.works_from_session = works_from_session

    def alive(self) -> bool:
        if self.removed and self.remove_at is not None and self.now >= self.remove_at:
            self.task = False
        return self.task

    def shell(self, command: str) -> str:
        self.commands.append(command)
        if command == rs.APP_SWITCH:
            self.recents_open = True
            self.sessions += 1
        elif command == rs.HOME:
            self.recents_open = False
            if self.removed and self.remove_at is None:
                self.remove_at = self.now + 0.7
        elif command.startswith("input swipe"):
            self.swipes += 1
            if (self.recents_open and self.sessions >= self.works_from_session
                    and self.takes_on is not None and self.swipes >= self.takes_on):
                self.task = False
            if self.recents_open and self.swipes == self.closes_on_swipe:
                self.recents_open = False
        elif command.startswith("am stack remove") and self.removal_works:
            self.removed = True
        elif command == "am stack list":
            return STACK if self.alive() else STACK.replace(PKG, "io.github.other")
        elif command == "dumpsys activity recents":
            return RECENTS if self.alive() else RECENTS.replace(PKG, "io.github.other")
        return ""

    def dump(self) -> str:
        return ONE_CARD if self.recents_open and self.card else APP_SCREEN

    def size(self) -> tuple[int, int]:
        return SCREEN

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def swipe(dev: FakeDevice) -> rs.Swipe:
    return rs.swipe_away(dev, PKG, "EEG Tracker", ACTIVITY)


def test_a_first_swipe_that_takes_is_the_recents_swipe() -> None:
    dev = FakeDevice(takes_on=1)
    result = swipe(dev)
    assert result.gone and result.how == "the Recents swipe"
    assert dev.swipes == 1
    assert not any(c.startswith("am stack remove") for c in dev.commands)


def test_a_first_swipe_that_is_ignored_is_followed_by_a_second_and_the_card_is_looked_up_again() -> None:
    dev = FakeDevice(takes_on=2)
    result = swipe(dev)
    assert result.gone
    assert result.how.startswith("the Recents swipe (swipe 2, a quicker swipe up)")
    assert dev.swipes == 2
    assert not any(c.startswith("am stack remove") for c in dev.commands)
    assert any("still there" in n for n in result.notes)


def test_the_swipe_aims_at_the_card_the_dump_shows_not_at_fixed_coordinates() -> None:
    dev = FakeDevice(takes_on=1)
    swipe(dev)
    assert [c for c in dev.commands if c.startswith("input swipe")] == ["input swipe 540 1106 540 107 120"]


def test_the_screen_the_first_swipe_aimed_at_is_kept_as_evidence() -> None:
    assert swipe(FakeDevice(takes_on=1)).dump == ONE_CARD


def test_a_task_removed_while_recents_is_open_counts_once_it_is_gone_after_home() -> None:
    """The old check looked right after Home and saw the task still there (swiped False) although it left a moment later."""
    dev = FakeDevice(takes_on=None)
    result = swipe(dev)
    assert result.gone
    assert result.how == "am stack remove 23 (the Recents swipe did not take)"
    assert dev.swipes == len(rs.gestures(None, *SCREEN))
    assert dev.commands.index("am stack remove 23") < len(dev.commands) - 1
    assert rs.HOME in dev.commands[dev.commands.index("am stack remove 23"):]


def test_when_nothing_gets_the_task_out_the_step_says_it_could_not_swipe() -> None:
    result = swipe(FakeDevice(takes_on=None, removal_works=False))
    assert not result.gone
    assert result.how.startswith("could not swipe (check plumbing)")
    assert "am stack remove" in result.how


def test_an_app_without_a_task_has_nothing_to_swipe_and_says_so() -> None:
    result = swipe(FakeDevice(takes_on=1, has_task=False))
    assert not result.gone
    assert result.how.startswith("could not swipe (check plumbing)")


def test_without_a_card_on_screen_the_swipe_goes_to_the_screen_middle_and_the_notes_say_so() -> None:
    dev = FakeDevice(takes_on=1, card=False)
    result = swipe(dev)
    assert result.gone
    assert [c for c in dev.commands if c.startswith("input swipe")] == ["input swipe 540 1200 540 200 120"]
    assert any("showed no card" in n for n in result.notes)


def test_when_a_gesture_closes_recents_the_app_is_brought_back_and_recents_opened_again() -> None:
    dev = FakeDevice(takes_on=2)
    dev.closes_on_swipe = 1
    result = swipe(dev)
    assert result.gone
    assert f"am start -n {ACTIVITY}" in dev.commands
    assert dev.commands.count(rs.APP_SWITCH) == 2


def test_the_first_look_does_not_touch_the_app_before_recents_opens() -> None:
    dev = FakeDevice(takes_on=1)
    swipe(dev)
    assert not any(c.startswith("am start") for c in dev.commands), "L1 tests the app as it is: no intent sent to it"


def test_a_stuck_recents_session_is_left_and_a_new_one_opened_before_the_third_swipe() -> None:
    dev = FakeDevice(takes_on=1, works_from_session=2)
    result = swipe(dev)
    assert result.gone
    assert result.how.startswith("the Recents swipe (swipe 3, a quick swipe up in a new Recents)")
    assert dev.swipes == 3 and dev.sessions == 2
    first_open = dev.commands.index(rs.APP_SWITCH)
    reopen = dev.commands.index(rs.APP_SWITCH, first_open + 1)
    assert rs.HOME in dev.commands[first_open:reopen] and f"am start -n {ACTIVITY}" in dev.commands[first_open:reopen]
    assert "am stack remove" not in " ".join(dev.commands)


@pytest.mark.parametrize("takes_on", [1, 2, 3, 4, 5, 6])
def test_every_gesture_of_the_list_can_be_the_one_that_takes(takes_on: int) -> None:
    result = swipe(FakeDevice(takes_on=takes_on))
    assert result.gone
    assert "am stack remove" not in result.how
