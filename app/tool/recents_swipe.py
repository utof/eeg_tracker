"""Takes the app's card out of Android's Recents the way the owner's swipe does (record_check's step L1).

What the laptop's emulator (Android 16, Pixel launcher, gesture navigation) was measured to do on 2026-11-26:
  * the launcher dismisses a card only for a quick fling: of six Recents sessions each, a swipe of 120 ms took in 5,
    80 ms in 4, 200 ms in 3, 300 ms in 2; a slow drag, however long, in none (0 of 8). The card follows a slow finger
    and snaps back.
  * the first swipe of a Recents session is mostly ignored, and some sessions ignore every swipe (five in a row, in
    about 1 session in 5); a new session (Home, the app to the front, App switch) usually takes the next swipe. With
    the plan below, 10 of 10 trials took the card out by a swipe (the 1st swipe once, the 2nd to 4th otherwise).
  * a task taken out with `am stack remove` while Recents is open is removed only when Recents closes, about 0.7 s
    after the Home key: a look at the task list right after Home still saw it (the old check did exactly that, and
    its one swipe at 200 ms mostly missed, so the step failed with "swiped False" every run).
The desktop's emulator takes the first swipe, which is why the step passed there.

So: find the app's card in a uiautomator dump of Recents (not at fixed coordinates), swipe it away with quick flings,
look for the task to leave the task list and the Recents list, open a new Recents session after two misses, and only
after all gestures remove the task with Android's own call (what a swipe ends in). A task that is still there after
that is "could not swipe (check plumbing)": the app was never tested, so it must not read as an app failure.

Pure parsing and the retry logic only: the adb calls come in through `Device`, so the tests need no emulator.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Protocol

BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")
HOME = "input keyevent KEYCODE_HOME"
APP_SWITCH = "input keyevent KEYCODE_APP_SWITCH"
CANT = "could not swipe (check plumbing)"
LOOK_S = 3.0  # after a gesture: how long the task may take to leave (a swipe that takes shows within a second)
AFTER_HOME_S = 10.0  # after Home: a task removed while Recents was open leaves about a second later


class Device(Protocol):
    def shell(self, command: str) -> str:
        """`adb shell command`; an overloaded emulator's hang is an empty or short answer, never an exception."""
        ...

    def dump(self) -> str:
        """The screen as a uiautomator dump ('' when it could not be read)."""
        ...

    def size(self) -> tuple[int, int]:
        """The screen's width and height (for a dump that could not be read)."""
        ...

    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class Card:
    left: int
    top: int
    right: int
    bottom: int
    label: str = ""

    @property
    def cx(self) -> int:
        return (self.left + self.right) // 2

    @property
    def cy(self) -> int:
        return (self.top + self.bottom) // 2

    @property
    def height(self) -> int:
        return self.bottom - self.top


@dataclass(frozen=True)
class Gesture:
    name: str
    x0: int
    y0: int
    x1: int
    y1: int
    ms: int
    fresh: bool = False  # a new Recents session first: Home, the app to the front, App switch

    @property
    def command(self) -> str:
        return f"input swipe {self.x0} {self.y0} {self.x1} {self.y1} {self.ms}"


@dataclass(frozen=True)
class AppTask:
    root: int  # the id `am stack remove` takes
    task: int


@dataclass
class Swipe:
    gone: bool
    how: str  # one phrase for the step's words; when not gone, it starts with CANT
    notes: list[str] = field(default_factory=list)  # one line per thing tried, for the details
    dump: str = ""  # the Recents screen the first swipe was aimed at (evidence, and a fixture for the tests)


# ---- reading the device -------------------------------------------------------------------------------------------


def app_tasks(stack_list: str, pkg: str) -> list[AppTask]:
    """The app's tasks in `am stack list`: a `RootTask id=N` line, then its `taskId=M: pkg/...` lines."""
    out: list[AppTask] = []
    root = 0
    for line in stack_list.splitlines():
        head = re.match(r"\s*(?:RootTask|Stack) id=(\d+)", line)
        if head:
            root = int(head.group(1))
            continue
        task = re.match(rf"\s*taskId=(\d+): {re.escape(pkg)}[/ ]", line)
        if task:
            out.append(AppTask(root or int(task.group(1)), int(task.group(1))))
    return out


def in_recents(recents: str, pkg: str) -> bool:
    """True when `dumpsys activity recents` lists a task of the app: `Recent #1: Task{... I=pkg/.Activity}`, or with
    the affinity only (`A=10216:pkg`) when the task keeps no intent."""
    name = re.escape(pkg)
    return re.search(rf"Recent #\d+:.*\b(?:I={name}/|A=(?:\d+:)?{name}[}}\s])", recents) is not None


def _bounds(node: ET.Element) -> tuple[int, int, int, int] | None:
    m = BOUNDS.fullmatch(node.get("bounds", ""))
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))) if m else None


def _root(dump: str) -> ET.Element | None:
    start, end = dump.find("<?xml"), dump.rfind("</hierarchy>")
    if start < 0 or end < 0:
        return None
    try:
        return ET.fromstring(dump[start : end + len("</hierarchy>")])
    except ET.ParseError:
        return None


def screen_size(dump: str, default: tuple[int, int] = (1080, 2400)) -> tuple[int, int]:
    """The screen's width and height: the widest bounds in the dump."""
    root = _root(dump)
    if root is None:
        return default
    w = h = 0
    for node in root.iter("node"):
        b = _bounds(node)
        if b:
            w, h = max(w, b[2]), max(h, b[3])
    return (w, h) if w and h else default


def _label(node: ET.Element) -> str:
    """What names a card: the description of its snapshot (the Pixel launcher), else any text or description inside."""
    inside = list(node.iter("node"))
    for n in inside:
        if n.get("resource-id", "").endswith("/snapshot") and n.get("content-desc"):
            return n.get("content-desc", "")
    for n in inside:
        if n.get("content-desc") or n.get("text"):
            return n.get("content-desc") or n.get("text", "")
    return ""


def cards(dump: str) -> list[Card]:
    """The task cards of a dump of Recents: the Pixel launcher's `task_view*` nodes, clipped to the screen. An empty
    list when the screen is not Recents (or not a launcher that names its cards that way)."""
    root = _root(dump)
    if root is None:
        return []
    w, h = screen_size(dump)
    found: list[Card] = []
    for node in root.iter("node"):
        if not node.get("resource-id", "").split("/")[-1].startswith("task_view"):
            continue
        b = _bounds(node)
        if b is None:
            continue
        left, top, right, bottom = max(b[0], 0), max(b[1], 0), min(b[2], w), min(b[3], h)
        if right > left and bottom > top:
            found.append(Card(left, top, right, bottom, _label(node)))
    return found


def find_card(dump: str, label: str) -> Card | None:
    """The app's card: the one named [label]; the only card when there is one; else None (never another app's card)."""
    shown = cards(dump)
    named = [c for c in shown if label.lower() in c.label.lower()]
    if named:
        return max(named, key=lambda c: (c.right - c.left) * c.height)
    return shown[0] if len(shown) == 1 else None


def gestures(card: Card | None, w: int, h: int) -> list[Gesture]:
    """The tries, in order: two quick flings up (120 and 80 ms), the same two in a new Recents session, then, in a third,
    one slower and one sideways (for a launcher that dismisses sideways). Every start is inside the card, every end
    on the screen."""
    cx, cy = (card.cx, card.cy) if card else (w // 2, h // 2)
    top = card.top if card else h // 6
    far = max(top - 100, h // 40) if card else h // 12  # (without a card: where the old check swiped to)
    side = max((card.left if card else 0) + 20, 1)
    return [
        Gesture("a quick swipe up from the card's middle", cx, cy, cx, far, 120),
        Gesture("a quicker swipe up", cx, cy, cx, far, 80),
        Gesture("a quick swipe up in a new Recents", cx, cy, cx, far, 120, fresh=True),
        Gesture("a quicker swipe up", cx, cy, cx, far, 80),
        Gesture("a slower swipe up in a new Recents", cx, cy, cx, far, 300, fresh=True),
        Gesture("a swipe sideways", cx, cy, side, cy, 250),
    ]


# ---- doing it -----------------------------------------------------------------------------------------------------


def present(dev: Device, pkg: str) -> bool:
    """The app still has a task, or Recents still lists it."""
    return bool(app_tasks(dev.shell("am stack list"), pkg)) or in_recents(dev.shell("dumpsys activity recents"), pkg)


def left_within(dev: Device, pkg: str, seconds: float, every: float = 1.0) -> bool:
    """True when the task is gone now or within [seconds]."""
    waited = 0.0
    while present(dev, pkg):
        if waited >= seconds:
            return False
        dev.sleep(every)
        waited += every
    return True


def open_recents(dev: Device, label: str, notes: list[str], bring: str = "", settle: float = 3.0, limit: float = 15.0) -> tuple[Card | None, str]:
    """The App switch key is pressed (after [bring], a command that brings the app to the front, when Recents was lost
    on the way), and the screen is read until the app's card shows. (None, last dump) when it never did."""
    if bring:
        dev.shell(bring)
        dev.sleep(2)
    dev.shell(APP_SWITCH)
    dev.sleep(settle)
    waited, dump = 0.0, ""
    while True:
        dump = dev.dump()
        card = find_card(dump, label)
        if card is not None:
            return card, dump
        if waited >= limit:
            notes.append(f"Recents showed no card for '{label}' within {limit:.0f} s ({len(cards(dump))} cards on screen)")
            return None, dump
        dev.sleep(1.5)
        waited += 1.5


def swipe_away(dev: Device, pkg: str, label: str, activity: str, settle: float = 3.0) -> Swipe:
    """Takes the app's task out of Recents. `gone` is True when the task is out of the task list and the Recents list."""
    notes: list[str] = []
    if not app_tasks(dev.shell("am stack list"), pkg):
        return Swipe(False, f"{CANT}: the app has no task, nothing to swipe", notes)
    size = dev.size()
    card, dump = open_recents(dev, label, notes, settle=settle)
    first_dump = dump
    plan = gestures(None, *size)
    for n, planned in enumerate(plan):
        if planned.fresh:  # the session ignored the last swipes: Home, the app to the front, Recents again
            dev.shell(HOME)
            card, dump = open_recents(dev, label, notes, f"am start -n {activity}", settle=settle)
        g = gestures(card, *screen_size(dump, size))[n]
        dev.shell(g.command)
        if left_within(dev, pkg, LOOK_S):
            dev.shell(HOME)
            if left_within(dev, pkg, AFTER_HOME_S):
                notes.append(f"swipe {n + 1} ({g.name}): the task left")
                return Swipe(True, "the Recents swipe" + ("" if n == 0 else f" (swipe {n + 1}, {g.name})"), notes, first_dump)
        notes.append(f"swipe {n + 1} ({g.name}): the task is still there after {LOOK_S:.0f} s")
        dump = dev.dump()
        card = find_card(dump, label)
        if card is None:  # Recents closed (the gesture was a tap, or the launcher went home): open it over the app again
            card, dump = open_recents(dev, label, notes, f"am start -n {activity}", settle=2.0)
    return _remove_task(dev, pkg, notes, first_dump, len(plan))


def _remove_task(dev: Device, pkg: str, notes: list[str], dump: str, tries: int) -> Swipe:
    """The swipes did not take: Android's own removal of the task, which is what a swipe ends in. It finishes only
    when Recents closes, so Home goes first and the look is long."""
    tasks = app_tasks(dev.shell("am stack list"), pkg)
    if not tasks:
        dev.shell(HOME)
        return Swipe(not present(dev, pkg), f"{CANT}: the task went by itself, but Recents still lists it", notes, dump)
    for t in tasks:
        dev.shell(f"am stack remove {t.root}")
    dev.shell(HOME)
    ids = ", ".join(str(t.root) for t in tasks)
    if left_within(dev, pkg, AFTER_HOME_S):
        notes.append(f"am stack remove {ids}: the task left (the Recents swipe did not take)")
        return Swipe(True, f"am stack remove {ids} (the Recents swipe did not take)", notes, dump)
    notes.append(f"am stack remove {ids}: the task is still there after {AFTER_HOME_S:.0f} s")
    return Swipe(False, f"{CANT}: the app's task stayed in Recents after {tries} swipes and am stack remove", notes, dump)
