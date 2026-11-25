"""The laptop tray icon: work sessions found from ActivityWatch, with break hints (docs/laptop-tray.md).

usage: python3 scripts/tray.py              the icon in the panel (the system python3, which has python3-gi)
       python3 scripts/tray.py --once       one look at ActivityWatch now: what the tray would say; writes nothing
       python3 scripts/tray.py --dry-run    the last 24 h replayed minute by minute: what each auto-start setting
                                            would have done; writes nothing

The logic is in scripts/laptop_work.py (tested in analysis/tests/test_laptop_work.py); this file is only the icon, its
menu and the desktop notifications (tested with fake GTK in analysis/tests/test_tray.py). DECISIONS 570-579; meetings
(a call app holding the microphone, or a meeting window in front, is work, never a break): 660-669; the paired phone
and its headband (a ring around the icon, the menu's phone lines, the phone link kept running): 670-679.
Settings: ~/.config/eeg_tracker/tray.json; records: <repo>/_local/laptop/work/. Nothing leaves the laptop but the
paired phone's work signal and the looks at its /state, on the local network.
"""
from __future__ import annotations

import argparse, os, socket, sys, threading
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import laptop_work as lw  # noqa: E402

HERE = Path(__file__).resolve()
ICONS = HERE.parent / "tray-icons"
POLL_S = 60          # ActivityWatch is read this often
RENDER_S = 20        # the menu's clock lines are redrawn this often
N_LINES = 5
N_PHONE = 4          # the phone's lines: the phone, when it sent its files by itself, the headband, a break
ICON_WORDS = {"working": "Working", "break": "On a break", "idle": "Not in a work session",
              "attention": "Waiting for an answer"}
RING_WORDS = {"none": "", "dashed": "; phone not reachable", "amber": "; headband not recording",
              "green": "; headband recording on the phone"}
LABELS = {"yes": "Yes, a work session", "no": "Not work", "start": "Start work session",
          "stop": "Stop work session", "notwork": "Not work (end it, mark it not work)", "break": "On a break",
          "back": "Back from the break", "snooze": "Snooze the hint 20 min", "dismiss": "OK, no break now",
          "folder": "Open data folder", "pair": "Pair phone…", "quit": "Quit",
          "pairtop": "Phone not paired: Pair phone…", "forget": "Forget the phone…",
          "forget_yes": "Yes, forget it (Pair phone… pairs again)"}
TOP = ("yes", "no", "start", "stop", "notwork", "break", "back", "snooze", "dismiss")
MODES = (("off", "Off: only when I press Start"), ("ask", "Ask me first"), ("auto", "Automatic when sure"))
AWAY = ((30.0, "30 min"), (60.0, "1 hour"), (0.0, "Never"))


def icon_path(name: str, ring: str = "none") -> str:
    """The icon of a state, with the phone's ring around it (DECISIONS 672): green, amber, dashed or none."""
    return str(ICONS / (f"eeg-tray-{name}.svg" if ring == "none" else f"eeg-tray-{name}-{ring}.svg"))


class DbusNotifier:
    """Desktop notifications with buttons over D-Bus (org.freedesktop.Notifications: the protocol notify-send speaks),
    answered in the GTK main loop: no threads, and a notification can be closed when it is answered in the menu."""

    def __init__(self, Gio: Any, GLib: Any, app: str = "EEG tracker"):
        self.Gio, self.GLib, self.app = Gio, GLib, app
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.ids: dict[str, int] = {}; self.answers: dict[int, tuple[Callable[[str], None], set[str]]] = {}
        for sig, fn in (("ActionInvoked", self._action), ("NotificationClosed", self._closed)):
            self.bus.signal_subscribe(None, "org.freedesktop.Notifications", sig, "/org/freedesktop/Notifications",
                                      None, Gio.DBusSignalFlags.NONE, fn, None)
        try:
            self.buttons = "actions" in self._call("GetCapabilities", None, "(as)")[0]
        except GLib.Error:
            self.buttons = False

    def _call(self, method: str, params: Any, reply: str | None) -> Any:
        r = self.bus.call_sync("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                               "org.freedesktop.Notifications", method, params,
                               self.GLib.VariantType(reply) if reply else None, self.Gio.DBusCallFlags.NONE, 3000,
                               None)
        return r.unpack() if r is not None else None

    def show(self, key: str, title: str, body: str, actions: list[tuple[str, str]],
             answer: Callable[[str], None], low: bool = False) -> None:
        old = self.ids.get(key, 0)
        flat = [x for k, label in actions for x in (k, label)] if self.buttons else []
        hints = {"urgency": self.GLib.Variant("y", 0 if low else 1)}
        try:
            nid = self._call("Notify", self.GLib.Variant("(susssasa{sv}i)", (
                self.app, old, icon_path("attention"), title, body, flat, hints, -1)), "(u)")[0]
        except self.GLib.Error as e:
            print(f"notification failed: {e}", flush=True); return
        self.answers.pop(old, None); self.ids[key] = nid; self.answers[nid] = (answer, {k for k, _ in actions})

    def close(self, key: str) -> None:
        nid = self.ids.pop(key, None)
        if nid is None:
            return
        self.answers.pop(nid, None)
        try:
            self._call("CloseNotification", self.GLib.Variant("(u)", (nid,)), None)
        except self.GLib.Error:
            pass

    def close_all(self) -> None:
        for k in list(self.ids):
            self.close(k)

    def _forget(self, nid: int) -> tuple[Callable[[str], None], set[str]] | None:
        for k, v in list(self.ids.items()):
            if v == nid:
                del self.ids[k]
        return self.answers.pop(nid, None)

    def _action(self, _c: Any, _s: Any, _p: Any, _i: Any, _n: Any, params: Any, _d: Any) -> None:
        nid, key = params.unpack()
        got = self._forget(nid)
        if got is not None and key in got[1]:      # (a click on the body sends "default": not an answer)
            got[0](key)

    def _closed(self, _c: Any, _s: Any, _p: Any, _i: Any, _n: Any, params: Any, _d: Any) -> None:
        self._forget(params.unpack()[0])


class TrayMenu:
    """The icon and its menu, drawn from WorkTray.view(); every click goes to a WorkTray method."""

    def __init__(self, ctl: lw.WorkTray, Gtk: Any, GLib: Any, AI: Any, *,
                 launch: Callable[[list[str]], None], now: Callable[[], datetime] = lambda: datetime.now().astimezone(),
                 spawn: Callable[[Callable[[], None]], None] = lambda fn: threading.Thread(target=fn, daemon=True).start(),
                 pair: Callable[[], list[str] | None] = lw.pair_command, data_dir: Path = lw.LOCAL / "laptop" / "work",
                 python: str = sys.executable):
        self.ctl, self.Gtk, self.GLib = ctl, Gtk, GLib
        self.launch, self.now, self.spawn, self.pair, self.data_dir, self.python = launch, now, spawn, pair, data_dir, python
        self.rendering = False; self.busy = False; self.phone_busy = False
        self.ind = AI.Indicator.new("eeg-tracker-tray", icon_path("idle"), AI.IndicatorCategory.APPLICATION_STATUS)
        self.ind.set_status(AI.IndicatorStatus.ACTIVE); self.ind.set_title("EEG tracker: work sessions")
        menu = Gtk.Menu()
        self.items = {"pairtop": self._item(menu, LABELS["pairtop"], "pairtop")}   # first, while no phone is paired
        self.lines = [self._item(menu, "", None) for _ in range(N_LINES)]
        self.phone_lines = [self._item(menu, "", None) for _ in range(N_PHONE)]
        for x in self.lines + self.phone_lines:
            x.set_sensitive(False)
        menu.append(Gtk.SeparatorMenuItem())
        self.items.update({k: self._item(menu, LABELS[k], k) for k in TOP})
        menu.append(Gtk.SeparatorMenuItem())
        top = Gtk.MenuItem(label="Settings"); sub = Gtk.Menu(); top.set_submenu(sub); menu.append(top)
        self.checks: dict[tuple[str, object], Any] = {}
        self._check(sub, "Notifications", ("notifications", True))
        self._heading(sub, "Start a work session by itself:")
        for m, text in MODES:
            self._check(sub, text, ("mode", m), radio=True)
        self._heading(sub, "End the session after this long away:")
        for v, text in AWAY:
            self._check(sub, text, ("away", v), radio=True)
        sub.append(Gtk.SeparatorMenuItem())
        self._check(sub, "Start at login", ("autostart", True))
        self._item(sub, "More settings (opens the file)…", "settings_file")
        menu.append(Gtk.SeparatorMenuItem())
        for k in ("folder", "pair"):
            self.items[k] = self._item(menu, LABELS[k], k)
        forget = Gtk.MenuItem(label=LABELS["forget"]); ask = Gtk.Menu(); forget.set_submenu(ask); menu.append(forget)
        self.items["forget"] = forget; self.items["forget_yes"] = self._item(ask, LABELS["forget_yes"], "forget_yes")
        self.items["quit"] = self._item(menu, LABELS["quit"], "quit")
        menu.show_all(); self.ind.set_menu(menu)

    # --- building
    def _item(self, menu: Any, label: str, key: str | None) -> Any:
        x = self.Gtk.MenuItem(label=label)
        if key is not None:
            x.connect("activate", lambda _w, k=key: self.do(k))
        menu.append(x)
        return x

    def _heading(self, menu: Any, label: str) -> None:
        menu.append(self.Gtk.SeparatorMenuItem())
        x = self.Gtk.MenuItem(label=label); x.set_sensitive(False); menu.append(x)

    def _check(self, menu: Any, label: str, key: tuple[str, object], radio: bool = False) -> None:
        x = self.Gtk.CheckMenuItem(label=label)
        if radio:
            x.set_draw_as_radio(True)
        x.connect("activate", lambda _w, k=key: self.toggle(*k))
        menu.append(x); self.checks[key] = x

    # --- clicks
    def do(self, key: str) -> None:
        now = self.now(); c = self.ctl
        acts: dict[str, Callable[[], object]] = {
            "start": lambda: c.start(now), "stop": lambda: c.stop(now), "notwork": lambda: c.not_work(now),
            "break": lambda: c.on_break(now), "back": lambda: c.back(now), "snooze": lambda: c.snooze(now),
            "dismiss": lambda: c.answer_hint("ok", now), "yes": lambda: c.answer_question(True, now),
            "no": lambda: c.answer_question(False, now), "folder": self.open_folder, "pair": self.open_pair,
            "pairtop": self.open_pair, "forget_yes": lambda: c.forget_phone(now),
            "settings_file": self.open_settings, "quit": self.quit}
        acts[key]()
        if key != "quit":
            self.render()

    def toggle(self, kind: str, value: object) -> None:
        if self.rendering:      # set_active() while drawing also fires "activate"
            return
        now = self.now(); c = self.ctl
        if kind == "notifications":
            c.set_setting(now, notifications=not c.s.notifications)
        elif kind == "mode":
            c.set_setting(now, auto_start=value)
        elif kind == "away":
            c.set_setting(now, end_after_away_min=value)
        elif kind == "autostart" and c.autostart is not None:
            c.set_autostart(not lw.autostart_on(c.autostart),
                            lw.autostart_text(self.python, HERE, Path(icon_path("working"))))
        self.render()

    def open_folder(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True); self.launch(["xdg-open", str(self.data_dir)])

    def open_settings(self) -> None:
        st = self.ctl.store
        if st.path is not None:
            if not st.path.exists():
                st.save(self.ctl.s)
            self.launch(["xdg-open", str(st.path)])

    def open_pair(self) -> None:
        cmd = self.pair()
        if cmd is not None:
            self.launch(cmd)

    def quit(self) -> None:
        self.ctl.quit(self.now())
        close_all = getattr(self.ctl.notifier, "close_all", None)
        if close_all is not None:
            close_all()
        self.Gtk.main_quit()

    # --- the loop
    def tick(self) -> bool:
        """Reads ActivityWatch in a thread (it can take a second), then decides in the main loop."""
        if not self.busy:
            self.busy = True; now = self.now()

            def work() -> None:
                try:
                    self.ctl.fetch(now); err = None
                except lw.af.NoActivityWatch as e:
                    err = str(e)
                except Exception as e:  # noqa: BLE001  (keep the icon alive; say what failed)
                    err = f"{type(e).__name__}: {e}"
                self.GLib.idle_add(self._fetched, now, err)
            self.spawn(work)
        return True

    def phone_tick(self) -> bool:
        """Looks at the paired phone in a thread (up to its timeout), keeping the phone link running first; the answer
        is taken in the main loop. Nothing is asked over the network while no phone is paired."""
        now = self.now()
        if not self.phone_busy and self.ctl.phone_due(now):
            self.phone_busy = True

            def work() -> None:
                try:
                    look = self.ctl.phone_fetch(now)
                except Exception as e:  # noqa: BLE001  (keep the icon alive; say what failed, never a token)
                    print(f"phone: the look failed: {type(e).__name__}", flush=True); look = None
                self.GLib.idle_add(self._phone_looked, look, now)
            self.spawn(work)
        return True

    def _phone_looked(self, look: lw.PhoneLook | None, now: datetime) -> bool:
        self.phone_busy = False
        self.ctl.phone_seen(look, now)
        self.render()
        return False

    def _fetched(self, now: datetime, err: str | None) -> bool:
        self.busy = False
        if err is None:
            self.ctl.apply(now)
        else:
            self.ctl.aw_error = err
        self.render()
        return False

    def render(self) -> bool:
        v = self.ctl.view(self.now())
        self.rendering = True
        try:
            for i, x in enumerate(self.lines):
                x.set_visible(i < len(v.lines))
                if i < len(v.lines):
                    x.set_label(v.lines[i])
            for i, x in enumerate(self.phone_lines):
                x.set_visible(i < len(v.phone))
                if i < len(v.phone):
                    x.set_label(v.phone[i])
            for k in TOP:
                self.items[k].set_visible(k in v.show)
            cmd = self.pair()
            for k in ("pair", "pairtop"):
                self.items[k].set_sensitive(cmd is not None)
            self.items["pair"].set_label(LABELS["pair"] if cmd else "Pair phone… (needs scripts/phone_link.py)")
            self.items["pairtop"].set_visible(v.phone_kind == "unpaired")
            self.items["forget"].set_visible("forget" in v.show)
            s = v.settings
            for (kind, val), x in self.checks.items():
                on = {"notifications": s.notifications, "mode": s.auto_start == val,
                      "away": s.end_after_away_min == val, "autostart": v.autostart}[kind]
                x.set_active(bool(on))
            self.ind.set_icon_full(icon_path(v.icon, v.ring), ICON_WORDS[v.icon] + RING_WORDS[v.ring])
            self.ind.set_title(v.lines[0] if v.lines else "EEG tracker")
        finally:
            self.rendering = False
        return True


# ---------- running ----------

def single_instance() -> object | None:
    """A lock in the user's runtime folder: a second tray (login + by hand) says so and leaves."""
    import fcntl
    folder = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/eeg-tracker-{os.getuid()}")
    folder.mkdir(parents=True, exist_ok=True)
    f = open(folder / "eeg-tracker-tray.lock", "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close(); return None
    return f


def tell_phone(local: Path, working: bool, send: Callable[..., str] = lw.phone_work_signal,
               meeting: bool | None = None) -> threading.Thread:
    """The paired phone hears that a work session started or ended (Share on Wi-Fi's POST /work, DECISIONS 603), and
    whether it is in a meeting (DECISIONS 666), in a thread of its own so the menu never waits for the network; the
    answer goes to the tray's output."""
    def run() -> None:
        said = send(local, working) if meeting is None else send(local, working, meeting=meeting)
        print(f"phone: work {'started' if working else 'ended'}: {said}", flush=True)
    t = threading.Thread(target=run, name="tell-phone", daemon=True)
    t.start()
    return t


def run_tray(a: argparse.Namespace) -> int:
    try:
        import gi
        gi.require_version("Gtk", "3.0"); gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AI, Gio, GLib, Gtk
    except (ImportError, ValueError) as e:
        print(f"tray.py needs the system python3 with python3-gi and AyatanaAppIndicator3 ({e})"); return 2
    lock = single_instance()
    if lock is None:
        print("The tray is already running."); return 0
    store = lw.SettingsStore(a.config)
    hints = lw.FileHintLog(a.export)
    ctl = lw.WorkTray(lw.ActivityWatch(a.host), DbusNotifier(Gio, GLib), lw.Records(a.local / "laptop" / "work"),
                      hints, store, a.local, lw.autostart_path(), lambda now: lw.look_at_phone(a.local, now),
                      work_signal=lambda working: tell_phone(a.local, working,
                                                             meeting=working and ctl.meeting_now is not None),
                      mic=lw.pactl_meeting, keeper=lw.LinkKeeper(a.local))
    for p in store.problems:
        print("settings:", p, flush=True)
    ctl.resume(datetime.now().astimezone())

    def launch(argv: list[str]) -> None:
        GLib.spawn_async(argv, flags=GLib.SpawnFlags.SEARCH_PATH)
    menu = TrayMenu(ctl, Gtk, GLib, AI, launch=launch, data_dir=a.local / "laptop" / "work",
                    pair=lambda: lw.pair_command(local=a.local))
    for sig in (15, 2, 1):   # SIGTERM (logout), SIGINT (Ctrl+C), SIGHUP: close the session file first
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, lambda *_: (menu.quit(), False)[1])
    menu.render(); GLib.idle_add(lambda: (menu.tick(), False)[1]); GLib.idle_add(lambda: (menu.phone_tick(), False)[1])
    GLib.timeout_add_seconds(POLL_S, menu.tick); GLib.timeout_add_seconds(RENDER_S, menu.render)
    GLib.timeout_add_seconds(int(lw.PHONE_POLL_S), menu.phone_tick)
    print(f"tray: records in {a.local / 'laptop' / 'work'}, settings in {store.path}", flush=True)
    Gtk.main()
    return 0


def once(a: argparse.Namespace, out: Callable[[str], object] = print) -> int:
    """One tick against ActivityWatch now; prints what the menu would say. Reads the settings; writes nothing."""
    store = lw.SettingsStore(a.config); s = store.load()
    ctl = lw.WorkTray(lw.ActivityWatch(a.host), lw.QueueNotifier({}), lw.Records(None),
                      lw.MemoryHintLog(lw.read_only_history(a.export)), lw.SettingsStore(None), a.local, None,
                      lambda now: lw.look_at_phone(a.local, now), mic=lw.pactl_meeting)   # no link kept: read only
    ctl.s = s; now = datetime.now().astimezone()
    ctl.tick(now)
    if ctl.aw_error:
        out(f"tray --once: {ctl.aw_error}"); return 1
    v = ctl.view(now); r = ctl.run
    out(f"now {now:%H:%M}, auto-start {s.auto_start}, icon {v.icon}, "
        + (f"in a meeting ({ctl.meeting_now})" if ctl.meeting_now else "not in a meeting"))
    out("\n".join("  " + x for x in v.lines))
    out(f"phone: {v.phone_kind}, ring {v.ring}" + ("".join("\n  " + x for x in v.phone) if v.phone else
                                                  ("\n  Phone not paired: Pair phone…" if v.phone_kind == "unpaired" else "")))
    if r is not None:
        out(f"current run: {r.family}, {r.work_min:.1f} min {'in it' if r.family == 'meeting' else 'in work apps'} since {lw.hm(r.start)}, {r.away_min:.1f} min "
            f"elsewhere, clear {r.clear_min:.1f} min, in it now: {r.now_in}; verdict: {lw.verdict(r, s) or 'nothing yet'}")
    out(f"menu offers: {', '.join(sorted(v.show))}")
    return 0


def dry_run(a: argparse.Namespace, out: Callable[[str], object] = print) -> int:
    now = datetime.now().astimezone(); lo = now - timedelta(hours=a.hours)
    try:
        ab, wb = lw.af.pick_bucket("aw-watcher-afk", a.host), lw.af.pick_bucket("aw-watcher-window", a.host)
        afk, win = lw.af.fetch(ab, lo - timedelta(hours=12), now), lw.af.fetch(wb, lo - timedelta(hours=6), now)
    except lw.af.NoActivityWatch as e:
        out(f"tray --dry-run: {e}"); return 1
    s = lw.SettingsStore(a.config).load(); hist = lw.read_only_history(a.export)
    out(f"The last {a.hours:g} h replayed minute by minute ({len(afk)} AFK and {len(win)} window events; titles read in "
        "memory only). Questions answered Yes, auto-starts kept (OK), hints not answered. Nothing written.")
    for mode in ("ask", "auto"):
        r = lw.simulate(afk, win, lo, now, replace(s, auto_start=mode), hist)
        name = {"ask": "Ask first", "auto": "Automatic when sure"}[mode]
        out(f"\n{name}: {r['asked']} question(s), {r['auto_started']} auto-start(s), {r['sessions']} session(s), "
            f"{r['session_min']} min in sessions ({r['active_min']} active), {r['breaks']} break(s), "
            f"{r['ended_by_away']} ended by being away, {r['hints']} hint(s), {r['hints_taken']} followed by a break")
        if a.verbose:
            out("\n".join("  " + x for x in r["log"]))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--once", action="store_true", help="one look now; prints what the tray would say; writes nothing")
    ap.add_argument("--dry-run", action="store_true", help="replay the last --hours; counts only; writes nothing")
    ap.add_argument("--hours", type=float, default=24, help="with --dry-run: how far back (default 24)")
    ap.add_argument("-v", "--verbose", action="store_true", help="with --dry-run: list each start, end and hint")
    ap.add_argument("--local", type=Path, default=lw.LOCAL, help="the _local folder (default: <repo>/_local)")
    ap.add_argument("--export", type=Path, help="break hints' event folder (default: <local>/export)")
    ap.add_argument("--config", type=Path, default=lw.settings_path(),
                    help="the settings file (default ~/.config/eeg_tracker/tray.json)")
    ap.add_argument("--host", default=socket.gethostname(), help="whose ActivityWatch buckets (default: this host)")
    a = ap.parse_args(argv)
    a.export = a.export or a.local / "export"
    if a.once:
        return once(a)
    if a.dry_run:
        return dry_run(a)
    return run_tray(a)


if __name__ == "__main__":
    sys.exit(main())
