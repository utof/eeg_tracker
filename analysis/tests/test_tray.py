"""scripts/tray.py: the thin GTK/AppIndicator layer and the D-Bus notifier, driven through fakes (no display, no
session bus). The decisions themselves are tested in test_laptop_work.py."""
import json, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import laptop_work as lw  # noqa: E402
import tray  # noqa: E402

TZ = timezone(timedelta(hours=3))
T0 = datetime(2026, 11, 18, 9, 0, tzinfo=TZ)


# ---------- fake GTK, AppIndicator, GLib ----------

class Item:
    def __init__(self, label=""):
        self.label = label; self.visible = True; self.sensitive = True; self.active = False; self.radio = False
        self.handlers = []; self.submenu = None

    def connect(self, sig, fn):
        assert sig == "activate"; self.handlers.append(fn)

    def set_label(self, x): self.label = x
    def set_visible(self, x): self.visible = x
    def set_sensitive(self, x): self.sensitive = x
    def set_submenu(self, m): self.submenu = m
    def set_draw_as_radio(self, x): self.radio = x

    def set_active(self, x):           # GTK: a change of state also emits "activate"
        if x != self.active:
            self.active = x
            for fn in self.handlers:
                fn(self)

    def click(self):
        if isinstance(self, Check):
            self.active = not self.active
        for fn in self.handlers:
            fn(self)


class Check(Item):
    pass


class Menu:
    def __init__(self): self.children = []
    def append(self, x): self.children.append(x)
    def show_all(self): pass


class FakeGtk:
    Menu, MenuItem, CheckMenuItem = Menu, Item, Check
    quit_called = 0

    class SeparatorMenuItem(Item):
        pass

    @classmethod
    def main_quit(cls): cls.quit_called += 1


class Indicator:
    def __init__(self, name, icon, cat):
        self.icon = icon; self.title = ""; self.menu = None; self.status = None

    @classmethod
    def new(cls, name, icon, cat): return cls(name, icon, cat)
    def set_status(self, s): self.status = s
    def set_title(self, t): self.title = t
    def set_menu(self, m): self.menu = m
    def set_icon_full(self, icon, desc): self.icon = icon; self.desc = desc


class FakeAI:
    Indicator = Indicator

    class IndicatorCategory:
        APPLICATION_STATUS = 0

    class IndicatorStatus:
        ACTIVE = 1


class FakeGLib:
    @staticmethod
    def idle_add(fn, *args):
        fn(*args)


class Notes:
    def __init__(self): self.shown = []; self.closed = []; self.all_closed = 0
    def show(self, key, title, body, actions, answer, low=False): self.shown.append((key, answer))
    def close(self, key): self.closed.append(key)
    def close_all(self): self.all_closed += 1


def find(menu: Menu, label: str) -> Item:
    for x in menu.children:
        if x.label == label:
            return x
        if x.submenu is not None:
            try:
                return find(x.submenu, label)
            except KeyError:
                pass
    raise KeyError(label)


class App:
    def __init__(self, tmp: Path, afk=None, window=None, pair=lambda: None):
        afk = afk if afk is not None else [{"timestamp": "2026-11-18T06:00:00Z", "duration": 7200,
                                            "data": {"status": "not-afk"}}]
        self.notes = Notes(); self.launched = []; self.t = T0
        self.ctl = lw.WorkTray(lw.Replay(afk, window or []), self.notes, lw.Records(tmp / "work"), lw.MemoryHintLog(),
                               lw.SettingsStore(tmp / "tray.json"), tmp, tmp / "autostart" / lw.AUTOSTART_NAME)
        self.menu = tray.TrayMenu(self.ctl, FakeGtk, FakeGLib, FakeAI, launch=self.launched.append,
                                  now=lambda: self.t, spawn=lambda fn: fn(), pair=pair, data_dir=tmp / "work",
                                  python="/usr/bin/python3")
        self.root = self.menu.ind.menu

    def visible(self) -> set[str]:
        return {k for k, x in self.menu.items.items() if x.visible}

    def lines(self) -> list[str]:
        return [x.label for x in self.menu.lines if x.visible]


# ---------- the menu ----------

def test_menu_shows_the_state_and_start_stop_work(tmp_path):
    a = App(tmp_path)
    a.menu.tick()
    assert a.lines()[0] == "Not in a work session" and a.menu.ind.icon.endswith("eeg-tray-idle.svg")
    assert {"start", "folder", "pair", "quit"} <= a.visible() and "stop" not in a.visible()
    assert a.menu.ind.title == "Not in a work session"
    find(a.root, "Start work session").click()
    assert a.ctl.session is not None and a.menu.ind.icon.endswith("eeg-tray-working.svg")
    assert {"stop", "break"} <= a.visible() and "start" not in a.visible()
    assert a.lines()[0].startswith("Working since")
    find(a.root, "On a break").click()
    assert a.menu.ind.icon.endswith("eeg-tray-break.svg") and "back" in a.visible()
    find(a.root, "Back from the break").click()
    find(a.root, "Stop work session").click()
    assert a.ctl.session is None and json.loads(sorted((tmp_path / "work").glob("*.work.json"))[0].read_text())[
        "ended"] == "stopped"


def test_settings_toggles_save_and_draw_as_radio(tmp_path):
    a = App(tmp_path); a.menu.render()
    modes = {m: find(a.root, text) for m, text in tray.MODES}
    assert all(x.radio for x in modes.values()) and modes["ask"].active and not modes["auto"].active
    modes["auto"].click()
    assert a.ctl.s.auto_start == "auto" and json.loads((tmp_path / "tray.json").read_text())["auto_start"] == "auto"
    assert modes["auto"].active and not modes["ask"].active and not modes["off"].active
    find(a.root, "Notifications").click()
    assert a.ctl.s.notifications is False and not find(a.root, "Notifications").active
    find(a.root, "Never").click()
    assert a.ctl.s.end_after_away_min == 0 and find(a.root, "Never").active and not find(a.root, "30 min").active


def test_start_at_login_writes_and_removes_the_desktop_file(tmp_path):
    a = App(tmp_path); a.menu.render()
    item = find(a.root, "Start at login"); f = tmp_path / "autostart" / lw.AUTOSTART_NAME
    assert not item.active and not f.exists()                          # off by default
    item.click()
    assert f.exists() and item.active and "tray.py" in f.read_text() and "Exec=/usr/bin/python3 " in f.read_text()
    item.click()
    assert not f.exists() and not item.active


def test_activitywatch_down_is_said_and_the_icon_stays(tmp_path):
    a = App(tmp_path)

    def down(now):
        raise lw.af.NoActivityWatch("ActivityWatch is not reachable")
    a.ctl.source.read = down
    a.menu.tick()
    assert a.lines()[0].startswith("ActivityWatch is not answering") and not a.menu.busy


def test_a_question_and_its_answer_in_the_menu(tmp_path):
    afk = [{"timestamp": "2026-11-18T06:00:00Z", "duration": 3600, "data": {"status": "not-afk"}}]
    win = [{"id": 1, "timestamp": "2026-11-18T06:00:00Z", "duration": 3600, "data": {"app": "Code", "title": "x"}}]
    a = App(tmp_path, afk, win); a.t = T0 + timedelta(minutes=6)
    a.menu.tick()
    assert {"yes", "no"} <= a.visible() and a.menu.ind.icon.endswith("eeg-tray-attention.svg")
    assert a.notes.shown[0][0] == "ask"
    find(a.root, "Yes, a work session").click()
    assert a.ctl.session is not None and a.ctl.session.started_by == "asked" and "ask" in a.notes.closed


def test_folder_pair_and_quit(tmp_path):
    a = App(tmp_path, pair=lambda: ["x-terminal-emulator", "-e", "python3", "phone_link.py"])
    a.menu.render()
    find(a.root, "Open data folder").click()
    assert a.launched[-1] == ["xdg-open", str(tmp_path / "work")] and (tmp_path / "work").is_dir()
    find(a.root, "Pair phone…").click()
    assert a.launched[-1][-1] == "phone_link.py"
    find(a.root, "More settings (opens the file)…").click()
    assert a.launched[-1] == ["xdg-open", str(tmp_path / "tray.json")] and (tmp_path / "tray.json").exists()
    find(a.root, "Start work session").click()
    q = FakeGtk.quit_called
    find(a.root, "Quit").click()
    assert FakeGtk.quit_called == q + 1 and a.notes.all_closed == 1
    f = json.loads(sorted((tmp_path / "work").glob("*.work.json"))[0].read_text())
    assert f["ended"] == "quit"


def test_pair_phone_waits_for_the_script(tmp_path):
    a = App(tmp_path, pair=lambda: None); a.menu.render()
    item = a.menu.items["pair"]
    assert not item.sensitive and "phone_link.py" in item.label


# ---------- the D-Bus notifier, on a fake bus ----------

class Variant:
    def __init__(self, sig, value): self.sig, self.value = sig, value
    def unpack(self): return self.value


class Bus:
    def __init__(self):
        self.calls = []; self.subs = {}; self.next_id = 41

    def signal_subscribe(self, sender, iface, member, path, arg0, flags, fn, data):
        self.subs[member] = fn

    def call_sync(self, name, path, iface, method, params, reply, flags, timeout, cancel):
        self.calls.append((method, params.value if params is not None else None))
        if method == "GetCapabilities":
            return Variant("(as)", (["actions", "body"],))
        if method == "Notify":
            self.next_id += 1
            return Variant("(u)", (self.next_id,))
        return None

    def emit(self, member, *args):
        self.subs[member](None, None, None, None, member, Variant("", args), None)


class FakeGio:
    class BusType:
        SESSION = 0

    class DBusSignalFlags:
        NONE = 0

    class DBusCallFlags:
        NONE = 0

    bus = None

    @classmethod
    def bus_get_sync(cls, kind, cancel):
        return cls.bus


class FakeGLibV:
    Variant = Variant

    class Error(Exception):
        pass

    @staticmethod
    def VariantType(s):
        return s


def test_dbus_notifier_buttons_answers_and_close():
    FakeGio.bus = bus = Bus()
    n = tray.DbusNotifier(FakeGio, FakeGLibV)
    got = []
    n.show("hint", "A short break?", "body", [("snooze", "Snooze 20 min"), ("ok", "OK")], got.append, low=True)
    method, (app, replaces, icon, title, body, actions, hints, timeout) = bus.calls[-1]
    assert method == "Notify" and actions == ["snooze", "Snooze 20 min", "ok", "OK"] and hints["urgency"].value == 0
    nid = n.ids["hint"]
    bus.emit("ActionInvoked", nid, "default")           # a click on the body: not an answer
    assert got == [] and "hint" not in n.ids
    n.show("hint", "A short break?", "body", [("snooze", "Snooze 20 min")], got.append)
    bus.emit("ActionInvoked", n.ids["hint"], "snooze")
    assert got == ["snooze"]
    n.show("ask", "Started working?", "b", [("yes", "Yes")], got.append)
    nid = n.ids["ask"]
    n.close("ask")
    assert bus.calls[-1] == ("CloseNotification", (nid,)) and "ask" not in n.ids
    bus.emit("ActionInvoked", nid, "yes")
    assert got == ["snooze"]                             # closed: a late click does nothing
    n.show("x", "t", "b", [("a", "A")], got.append); n.show("x", "t", "b", [("a", "A")], got.append)
    assert bus.calls[-1][1][1] == n.ids["x"] - 1         # the second replaces the first
    n.close_all()
    assert n.ids == {}
