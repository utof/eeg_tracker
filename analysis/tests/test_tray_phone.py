"""The tray and the paired phone (DECISIONS 670-679): the looks at the phone's /state against a fake phone (paired,
not paired, not reachable, a refused token, stale data, a Work session, a night), the ring around the icon, the menu's
phone lines and "Pair phone…" first while none is paired, the one notification at the start, "Forget the phone", and
the phone link the tray keeps running (phone_link.py --keep)."""
import json, subprocess, sys, threading
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import laptop_work as lw  # noqa: E402
import tray  # noqa: E402
from test_pull_phone import signed_ok  # noqa: E402
from test_tray import FakeAI, FakeGLib, FakeGtk, Notes, find  # noqa: E402

TZ = timezone(timedelta(hours=3))
T0 = datetime(2026, 11, 20, 12, 30, tzinfo=TZ)
TOKEN = "abcdefghjkmn"
KEY = "7" * 64


class FakePhone:
    """The phone's Share on Wi-Fi on loopback: GET /state signed with the pairing's key (DECISIONS 751), answered
    with its reply proof, whatever `state` holds now; `here` "paused" refuses a laptop off its home network."""

    def __init__(self) -> None:
        self.state: dict = {"status": "not recording", "age": 999, "minutes": 0, "session": None}
        self.asked = 0; self.auth: list[str | None] = []
        self.here = "home"
        phone = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_a) -> None:
                pass

            def do_GET(self) -> None:
                phone.asked += 1; phone.auth.append(self.headers.get("Authorization"))
                reply = signed_ok(self, KEY)
                if reply is None:
                    code, body = 401, {"error": "signature"}
                elif phone.here == "paused" and self.headers.get("X-Eeg-Home") == "0":
                    code, body = 403, {"error": "not sharing on this Wi-Fi"}
                elif self.path == "/state":
                    code, body = 200, phone.state
                else:
                    code, body = 404, {"error": "no such route"}
                raw = json.dumps(body).encode()
                self.send_response(code); self.send_header("Content-Type", "application/json")
                if reply:
                    self.send_header("X-Eeg-Reply", reply)
                self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.srv.shutdown(); self.srv.server_close()


@pytest.fixture
def phone():
    p = FakePhone()
    yield p
    p.close()


def pair(local: Path, port: int, key: str = KEY) -> None:
    """link.json as phone_link.py writes it after a pairing (version 2: the key, no token)."""
    (local / "phone").mkdir(parents=True, exist_ok=True)
    (local / "phone" / "link.json").write_text(json.dumps(
        {"version": 2, "key": key, "paired": "2026-11-19T21:00:00+03:00", "home": None,
         "phone": {"address": "127.0.0.1", "port": port}}))


def work(**kw) -> dict:
    s = {"kind": "work", "since": "2026-11-20T09:26:00.000Z", "stage": "running", "level": "alert",
         "signal": "good", "on_break": False, "hint": None, "age": 1.2}
    s.update(kw)
    return {"status": "not recording", "age": 999, "minutes": 0, "session": s}


def look(local: Path, now: datetime = T0) -> lw.PhoneLook:
    return lw.look_at_phone(local, now, probe=lambda: None)


def view_of(local: Path) -> lw.PhoneView:
    lk = look(local)
    return lw.phone_view(lk, lk if lk.result == "ok" else None, 0 if lk.result == "ok" else 1)


# ---------- the looks and what they say ----------

def test_not_paired_asks_nothing(tmp_path, phone):
    assert look(tmp_path).result == "unpaired"
    assert view_of(tmp_path) == lw.PhoneView("unpaired", "none", ())
    (tmp_path / "phone").mkdir(); (tmp_path / "phone" / "link.json").write_text('{"version": 1, "phone": null}')
    assert look(tmp_path).result == "unpaired"
    assert phone.asked == 0


def test_a_work_session_recording_on_the_phone_is_a_green_ring(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = work()
    v = view_of(tmp_path)
    assert v.kind == "reachable" and v.ring == "green"
    assert v.lines == ("Phone: paired, reachable",
                       "Headband: recording on the phone (work session since 12:26, signal good, alert)")
    assert phone.auth == [None]                                  # signed with the key: no token at all
    phone.state = work(level="getting_drowsy")
    assert view_of(tmp_path).lines[2] == "Drowsiness is rising: a break soon may help"
    phone.state = work(level="drowsy", hint={"reason": "drowsy", "at": "2026-11-20T09:50:00Z"})
    assert view_of(tmp_path).lines[1:] == (
        "Headband: recording on the phone (work session since 12:26, signal good, drowsy)",
        "Break hint on the phone since 12:50 (drowsiness)")
    phone.state = work(stage="calibrating", level="unknown")
    assert view_of(tmp_path).lines[1].endswith("signal good, calibrating)")
    assert lw.phone_work_level(work(level="drowsy")) == "drowsy"
    assert lw.phone_work_level(work(stage="calibrating")) is None


def test_connected_but_not_worn_lost_stale_and_on_a_break_are_amber(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = work(signal="off")
    v = view_of(tmp_path)
    assert v.ring == "amber" and v.lines[1] == "Headband: connected, not on the head (work session since 12:26 on the phone)"
    phone.state = work(signal="lost", age=40)
    assert view_of(tmp_path).lines[1].startswith("Headband: signal lost, reconnecting")
    phone.state = work(age=125.0)                    # the phone's screen stopped telling: its data is old
    v = view_of(tmp_path)
    assert v.ring == "amber" and v.lines[1] == "Headband: no data for 2 min (work session since 12:26 on the phone)"
    assert lw.phone_work_level(work(age=125.0)) is None
    phone.state = work(on_break=True)
    assert view_of(tmp_path).lines[1] == "Headband: on a break (work session since 12:26 on the phone)"
    phone.state = work(on_break=True, signal="off")
    assert view_of(tmp_path).ring == "amber"


def test_a_night_another_session_and_nothing(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = {"status": "recording", "age": 0.4, "minutes": 370.2, "session": None}
    v = view_of(tmp_path)
    assert v.ring == "green" and v.lines[1] == "Headband: recording a night on the phone, 6h10 so far"
    phone.state = {"status": "recording", "age": 300, "minutes": 370.2}
    assert view_of(tmp_path).lines[1] == "Headband: a night records, but no data for 5 min"
    phone.state = {"status": "reconnecting", "age": 20, "minutes": 1}
    assert view_of(tmp_path).ring == "amber"
    phone.state = {"status": "session", "age": 1, "minutes": 3}
    assert view_of(tmp_path) == lw.PhoneView("reachable", "green", (
        "Phone: paired, reachable", "Headband: recording on the phone (a session)"))
    phone.state = {"status": "not recording", "age": 999, "minutes": 0, "session": None}
    assert view_of(tmp_path) == lw.PhoneView("reachable", "amber", (
        "Phone: paired, reachable", "Headband: not recording on the phone"))


def test_odd_answers_read_as_missing(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = work(since=12, level="sleepy", signal=None, age="soon", hint={"reason": "x"})
    v = view_of(tmp_path)
    assert v.ring == "amber" and v.lines[1] == "Headband: signal lost, reconnecting (a work session on the phone)"
    phone.state = {"no": "status"}
    assert look(tmp_path).result == "refused" and view_of(tmp_path).lines[0].startswith("Phone: answers, but not as")


def test_unreachable_and_refused(tmp_path, phone):
    pair(tmp_path, phone.port, key="8" * 64)                    # the phone forgot this pairing
    v = view_of(tmp_path)
    assert v.ring == "dashed" and v.lines == (
        "Phone: no longer knows this laptop (Pair phone… again)", "Headband: —")
    pair(tmp_path, phone.port)
    phone.here = "paused"                                       # the phone on another Wi-Fi, not allowed there
    v = view_of(tmp_path)
    assert v.ring == "dashed" and v.lines == (
        "Phone: on another Wi-Fi: sharing paused there", "Headband: —")
    phone.here = "home"
    port = phone.port
    phone.close()
    pair(tmp_path, port)
    lk = lw.look_at_phone(tmp_path, T0, ask=lambda *t: lw.phone_state(*t, timeout=0.5), probe=lambda: None)
    assert lk.result == "unreachable" and lk.address == "127.0.0.1"
    assert lw.phone_view(lk, None, 1) == lw.PhoneView(
        "unreachable", "dashed", ("Phone: not reachable (app asleep, or Share on Wi-Fi off?)", "Headband: —"))
    assert KEY not in repr(lk)


def test_an_old_pairing_asks_for_one_new_scan(tmp_path, phone):
    (tmp_path / "phone").mkdir()
    (tmp_path / "phone" / "link.json").write_text(json.dumps(
        {"version": 1, "laptop_key": "k" * 43, "phone": {"address": "127.0.0.1", "port": phone.port, "token": TOKEN}}))
    lk = look(tmp_path)
    assert lk.result == "repair" and phone.asked == 0
    assert lw.phone_view(lk, None, 1) == lw.PhoneView(
        "repair", "dashed", ("Phone: paired the old way: Pair phone… once more (one scan)",))


def test_the_menu_says_when_the_laptop_last_copied(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = {"status": "not recording", "age": 999, "minutes": 0}
    lk = lw.look_at_phone(tmp_path, T0, probe=lambda: {"connected": True, "last_copy": "2026-11-20T14:05:09+03:00",
                                                       "sharing": "home"})
    assert lw.phone_view(lk, lk, 0).lines[0] == "Phone: sharing on its home Wi-Fi · copied 14:05"
    lk = lw.look_at_phone(tmp_path, T0, probe=lambda: {"connected": False, "last_copy": None, "sharing": "here"})
    assert lw.phone_view(lk, lk, 0).lines[0] == "Phone: sharing on a Wi-Fi allowed by hand"


def test_one_failed_look_keeps_the_last_answer_two_do_not(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = work()
    ok = look(tmp_path)
    miss = lw.PhoneLook(T0 + timedelta(seconds=45), "unreachable", "127.0.0.1")
    assert lw.phone_view(miss, ok, 1).ring == "green"
    assert lw.phone_view(miss, ok, 2).kind == "unreachable"


def test_the_copying_link_shows_on_the_phone_line(tmp_path, phone):
    pair(tmp_path, phone.port)
    lk = lw.look_at_phone(tmp_path, T0, probe=lambda: {"connected": True})
    assert lw.phone_view(lk, lk, 0).lines[0] == "Phone: paired, reachable · copying its files"


# ---------- the tray: icon, menu, notification, forget ----------

class Keeper:
    def __init__(self): self.ticks = 0; self.stopped = 0
    def tick(self, now): self.ticks += 1; return "running"
    def stop(self): self.stopped += 1


class Tray:
    def __init__(self, tmp: Path, *, notifications: bool = True, pair=lambda: ["x-terminal-emulator"]):
        afk = [{"timestamp": "2026-11-20T09:00:00Z", "duration": 7200, "data": {"status": "not-afk"}}]
        self.notes = Notes(); self.t = T0; self.launched = []; self.keeper = Keeper()
        self.ctl = lw.WorkTray(lw.Replay(afk, []), self.notes, lw.Records(tmp / "work"), lw.MemoryHintLog(),
                               lw.SettingsStore(tmp / "tray.json"), tmp, None,
                               phone=lambda now: lw.look_at_phone(tmp, now, probe=lambda: None), keeper=self.keeper)
        self.ctl.s = lw.replace(self.ctl.s, notifications=notifications)
        self.menu = tray.TrayMenu(self.ctl, FakeGtk, FakeGLib, FakeAI, launch=self.launched.append,
                                  now=lambda: self.t, spawn=lambda fn: fn(), pair=pair, data_dir=tmp / "work",
                                  python="/usr/bin/python3")
        self.root = self.menu.ind.menu

    def look(self, after_s: float = 45) -> None:
        self.t += timedelta(seconds=after_s); self.menu.phone_tick()

    def phone_lines(self) -> list[str]:
        return [x.label for x in self.menu.phone_lines if x.visible]


def test_every_icon_has_its_rings_and_they_are_svg():
    for icon in tray.ICON_WORDS:
        for ring in lw.RINGS:
            p = Path(tray.icon_path(icon, ring))
            assert p.exists(), p
            root = ET.parse(p).getroot()
            assert root.get("viewBox") == "0 0 22 22"
    assert tray.icon_path("working") == tray.icon_path("working", "none")
    assert tray.icon_path("idle", "green").endswith("eeg-tray-idle-green.svg")


def test_not_paired_the_menu_starts_with_pair_phone(tmp_path):
    a = Tray(tmp_path)
    a.menu.tick(); a.menu.phone_tick()
    first = a.root.children[0]
    assert first is a.menu.items["pairtop"] and first.visible and first.label == "Phone not paired: Pair phone…"
    assert a.phone_lines() == [] and not a.menu.items["forget"].visible
    assert a.menu.ind.icon.endswith("eeg-tray-idle.svg")       # no ring: nothing to say about a headband
    first.click()
    assert a.launched == [["x-terminal-emulator"]]
    assert a.notes.shown == []                                  # never paired: nothing pops up


def test_paired_the_ring_and_lines_follow_the_phone(tmp_path, phone):
    pair(tmp_path, phone.port)
    phone.state = work()
    a = Tray(tmp_path)
    a.menu.tick(); a.menu.phone_tick()
    assert a.keeper.ticks == 1                                   # the phone link kept running first
    assert not a.menu.items["pairtop"].visible and a.menu.items["forget"].visible
    assert a.menu.ind.icon.endswith("eeg-tray-idle-green.svg") and "headband recording" in a.menu.ind.desc
    assert a.phone_lines() == ["Phone: paired, reachable",
                               "Headband: recording on the phone (work session since 12:26, signal good, alert)"]
    a.ctl.start(a.t); a.menu.tick()
    assert a.menu.ind.icon.endswith("eeg-tray-working-green.svg")
    assert any(x.startswith("Next break hint about") and "(by time:" in x for x in [y.label for y in a.menu.lines])
    a.menu.phone_tick()                                          # not due yet: no second look within 45 s
    assert phone.asked == 1
    phone.state = work(signal="off")
    a.look()
    assert phone.asked == 2 and a.menu.ind.icon.endswith("eeg-tray-working-amber.svg")


def test_a_paired_phone_that_does_not_answer_at_the_start_is_said_once(tmp_path, phone):
    port = phone.port
    phone.close()
    pair(tmp_path, port)
    a = Tray(tmp_path)
    a.menu.phone_tick()
    assert [k for k, _ in a.notes.shown] == ["phone"]
    assert a.menu.ind.icon.endswith("eeg-tray-idle-dashed.svg")
    assert a.phone_lines() == ["Phone: not reachable (app asleep, or Share on Wi-Fi off?)", "Headband: —"]
    a.look(); a.look()
    assert [k for k, _ in a.notes.shown] == ["phone"]           # once, not every look
    quiet = Tray(tmp_path / "q", notifications=False)
    pair(tmp_path / "q", port)
    quiet.menu.phone_tick()
    assert quiet.notes.shown == [] and quiet.phone_lines()[0].startswith("Phone: not reachable")


# ---------- the headband notices the phone made (state["alert"]) ----------

def alert(kind: str = "lost", ago_s: float = 60, **kw) -> dict:
    return {"kind": kind, "at": int(T0.timestamp()) + 45 - ago_s, "title": f"Headband {kind}",
            "text": "Plain words.", **kw}


def shown(a: Tray) -> list[str]:
    return [k for k, _ in a.notes.shown if k == "headband-alert"]


def test_a_new_headband_alert_shows_once_and_back_replaces_lost(tmp_path, phone):
    pair(tmp_path, phone.port)
    a = Tray(tmp_path)
    phone.state = {**work(), "alert": alert("lost")}
    a.look()
    assert shown(a) == ["headband-alert"]
    a.look(); a.look()
    assert shown(a) == ["headband-alert"]                        # the same alert on the next looks: nothing
    phone.state = {**work(), "alert": {**alert("back", ago_s=-90)}}
    a.look()
    assert shown(a) == ["headband-alert"] * 2                    # same key: the newer replaces the older


def test_headband_alert_respects_notifications_and_never_replays(tmp_path, phone):
    pair(tmp_path, phone.port)
    a = Tray(tmp_path, notifications=False)
    phone.state = {**work(), "alert": alert("battery")}
    a.look()
    assert shown(a) == []
    a.ctl.s = lw.replace(a.ctl.s, notifications=True)
    a.look()
    assert shown(a) == []                                        # switching on later does not replay it


def test_stale_malformed_and_unreachable_headband_alerts_show_nothing(tmp_path, phone):
    pair(tmp_path, phone.port)
    a = Tray(tmp_path)
    for bad in (alert(ago_s=31 * 60), alert("other"), {**alert(), "title": 5}, {**alert(), "text": ""},
                {**alert(), "at": "now"}, {**alert(), "at": True}, "lost", [], {"kind": "lost"}):
        phone.state = {**work(), "alert": bad}
        a.look()
    assert shown(a) == []
    phone.state = {**work(), "alert": alert("lost", ago_s=20 * 60)}
    a.look()
    assert shown(a) == ["headband-alert"]                        # 20 minutes old is still shown
    port = phone.port
    phone.close()
    b = Tray(tmp_path / "b"); pair(tmp_path / "b", port)
    b.look()
    assert shown(b) == []
    c = Tray(tmp_path / "c")                                     # not paired
    c.look()
    assert shown(c) == []


def test_headband_alert_texts_are_capped():
    got = lw.headband_alert({"alert": {"kind": "lost", "at": int(T0.timestamp()), "title": "t" * 200,
                                       "text": "x" * 900}})
    assert got is not None and len(got[2]) == 80 and len(got[3]) == 300


def test_forget_the_phone(tmp_path, phone):
    pair(tmp_path, phone.port)
    a = Tray(tmp_path)
    a.menu.phone_tick()
    assert a.menu.items["forget"].visible
    find(a.root, "Yes, forget it (Pair phone… pairs again)").click()
    assert not (tmp_path / "phone" / "link.json").exists() and a.keeper.stopped == 1
    assert a.menu.items["pairtop"].visible and not a.menu.items["forget"].visible
    assert a.menu.ind.icon.endswith("eeg-tray-idle.svg")
    asked = phone.asked
    a.look()
    assert phone.asked == asked                                  # forgotten: nothing asked any more


def test_quit_stops_the_kept_link(tmp_path):
    a = Tray(tmp_path)
    a.menu.quit()
    assert a.keeper.stopped == 1


# ---------- the phone link the tray keeps running (phone_link.py --keep) ----------

class Proc:
    def __init__(self, argv, **kw):
        self.argv, self.kw, self.code, self.terminated = argv, kw, None, False
    def poll(self): return self.code
    def terminate(self): self.terminated = True; self.code = -15
    def wait(self, timeout=None): return self.code
    def kill(self): self.code = -9


def keeper(tmp: Path, probe=lambda: None):
    started: list[Proc] = []
    script = tmp / "phone_link.py"; script.write_text("")

    def popen(argv, **kw):
        started.append(Proc(argv, **kw)); return started[-1]
    return lw.LinkKeeper(tmp, python="/usr/bin/python3", script=script, probe=probe, popen=popen), started


def test_the_keeper_runs_the_link_while_paired_and_again_after_a_restart(tmp_path):
    k, started = keeper(tmp_path)
    assert k.tick(T0) == "off" and started == []                 # nothing paired: nothing runs
    pair(tmp_path, 8765)
    assert k.tick(T0) == "started"
    assert started[0].argv == ["/usr/bin/python3", str(tmp_path / "phone_link.py"), "--keep", "--dest", str(tmp_path)]
    assert started[0].kw["stdin"] == subprocess.DEVNULL and started[0].kw["start_new_session"]
    assert (tmp_path / "phone" / "link-keep.log").exists()
    assert k.tick(T0 + timedelta(minutes=1)) == "running" and len(started) == 1
    started[0].code = 1                                          # it died after a while: started again
    assert k.tick(T0 + timedelta(minutes=10)) == "started" and len(started) == 2
    started[1].code = 1                                          # dies at once: the next try waits longer
    assert k.tick(T0 + timedelta(minutes=10, seconds=30)) == "waiting"
    assert k.tick(T0 + timedelta(minutes=11, seconds=30)) == "waiting"
    assert k.tick(T0 + timedelta(minutes=12, seconds=30)) == "started"
    # the laptop restarted: a new tray, the same link.json, the link runs again at its first look
    k2, started2 = keeper(tmp_path)
    assert k2.tick(T0 + timedelta(hours=9)) == "started" and len(started2) == 1
    # forgotten: its copy is stopped
    lw.forget_phone(tmp_path)
    assert k2.tick(T0 + timedelta(hours=9, minutes=1)) == "off" and started2[0].terminated


def test_the_keeper_leaves_another_running_link_alone(tmp_path):
    k, started = keeper(tmp_path, probe=lambda: {"connected": True})
    pair(tmp_path, 8765)
    assert k.tick(T0) == "other" and started == []              # a "Pair phone…" window, or one an old tray left
    k.stop()


@pytest.mark.realtime
def test_a_real_kept_link_starts_and_stops(tmp_path):
    """The real phone_link.py --keep under the keeper, on a free port: it answers its status on this laptop, and
    ends when the keeper stops it."""
    import socket, time, urllib.request
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    pair(tmp_path, 8765)
    script = tmp_path / "link.py"
    script.write_text("import sys; sys.path.insert(0, %r); import phone_link\n"
                      "sys.exit(phone_link.main(sys.argv[1:] + ['--port', %r, '--address', '127.0.0.1', '--no-pages', "
                      "'--no-mirror']))\n"
                      % (str(lw.REPO / "scripts"), str(port)))
    k = lw.LinkKeeper(tmp_path, python=sys.executable, script=script, probe=lambda: None)
    assert k.tick(T0) == "started"
    try:
        url = f"http://127.0.0.1:{port}/status"
        for _ in range(100):
            try:
                st = json.load(urllib.request.urlopen(url, timeout=1)); break
            except OSError:
                time.sleep(0.05)
        assert st["phone"] == "127.0.0.1:8765" and st["code_valid"] is False
    finally:
        k.stop()
    assert k.proc is None
    log = (tmp_path / "phone" / "link-keep.log").read_text()
    assert "Remembered phone" in log and KEY not in log and "127.0.0.1" not in log
