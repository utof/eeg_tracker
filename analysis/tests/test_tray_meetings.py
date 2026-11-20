"""The laptop tray in a meeting (DECISIONS 660-669): a call app holding the microphone, or a meeting window in front,
is work, not a break; the time away from the keyboard in it never ends the session; no notification interrupts it
(hints and questions wait until it ends); a meeting can start a session under the auto-start setting; a break that
was really a meeting is counted as one once the tray sees it. pactl output and ActivityWatch events are made up."""
import json
from datetime import timedelta

import laptop_work as lw
from test_laptop_work import CHAT, TERM, Rig, at, away, awake, win

# ---------- what `pactl list source-outputs` / `sink-inputs` print (LC_ALL=C) ----------

PEAK = """Source Output #13502
\tDriver: protocol-native.c
\tOwner Module: 9
\tClient: 64
\tSource: 1
\tSample Specification: float32le 1ch 25Hz
\tCorked: yes
\tMute: no
\tProperties:
\t\tmedia.name = "Peak detect"
\t\tapplication.name = "cinnamon-sound-applet"
\t\tapplication.process.binary = "cinnamon"
"""
ZOOM_MIC = """Source Output #82087
\tDriver: protocol-native.c
\tCorked: no
\tMute: no
\tProperties:
\t\tapplication.name = "ZOOM VoiceEngine"
\t\tapplication.process.binary = "zoom"
\t\tmedia.name = "recStream"
\t\tmodule-stream-restore.id = "source-output-by-application-name:ZOOM VoiceEngine"
"""
TEAMS_MIC = """Source Output #91
\tCorked: no
\tProperties:
\t\tapplication.name = "teams-for-linux"
\t\tapplication.process.binary = "teams-for-linux"
\t\tmedia.name = "WebRTC"
"""
MEET_MIC = """Source Output #92
\tCorked: no
\tProperties:
\t\tapplication.name = "Google Chrome input"
\t\tapplication.process.binary = "chrome"
\t\tmedia.name = "RecordStream"
"""
TELEGRAM_MIC = """Source Output #93
\tCorked: no
\tProperties:
\t\tapplication.name = "AyuGramDesktop"
\t\tapplication.process.binary = "AyuGram"
\t\tmedia.name = "Telegram Call"
"""
RECORDER_MIC = """Source Output #94
\tCorked: no
\tProperties:
\t\tapplication.name = "ALSA plug-in [arecord]"
\t\tapplication.process.binary = "arecord"
\t\tmedia.name = "ALSA Capture"
"""
ZOOM_SPEAKER = """Sink Input #82094
\tCorked: no
\tProperties:
\t\tapplication.name = "ZOOM VoiceEngine"
\t\tapplication.process.binary = "zoom"
\t\tmedia.name = "playStream"
"""
BROWSER_SPEAKER = """Sink Input #8
\tCorked: no
\tProperties:
\t\tapplication.name = "Firefox"
\t\tapplication.process.binary = "firefox"
\t\tmedia.name = "AudioStream"
"""


def test_a_call_app_holding_the_microphone_is_a_meeting_and_peak_detect_is_not():
    assert lw.meeting_from_pactl(PEAK + "\n" + ZOOM_MIC + "\n" + PEAK.replace("13502", "82108")) == "zoom"
    assert lw.meeting_from_pactl(PEAK) is None                     # the sound applet's level meters
    assert lw.meeting_from_pactl("") is None
    assert lw.meeting_from_pactl(TEAMS_MIC) == "teams"
    assert lw.meeting_from_pactl(MEET_MIC) == "browser"            # Meet, Jitsi, Teams on the web: a call in a browser
    assert lw.meeting_from_pactl(TELEGRAM_MIC) == "telegram"
    assert lw.meeting_from_pactl(RECORDER_MIC) is None             # a recorder is not a call
    assert lw.meeting_from_pactl(ZOOM_MIC.replace("Corked: no", "Corked: yes")) == "zoom"   # muted still counts


def test_a_meeting_apps_sound_counts_but_a_browsers_does_not():
    assert lw.meeting_from_pactl(PEAK, ZOOM_SPEAKER) == "zoom"     # in the meeting with no microphone
    assert lw.meeting_from_pactl(PEAK, BROWSER_SPEAKER) is None    # a video
    assert lw.meeting_from_pactl("", ZOOM_SPEAKER.replace("Corked: no", "Corked: yes")) is None


def test_pactl_is_asked_in_english_and_a_missing_pactl_is_no_meeting():
    calls = []

    class Done:
        def __init__(self, out):
            self.returncode, self.stdout = 0, out

    def run(argv, **kw):
        calls.append((argv, kw["env"].get("LC_ALL"), kw["timeout"]))
        return Done(ZOOM_MIC if argv[-1] == "source-outputs" else "")
    assert lw.pactl_meeting(run) == "zoom"
    assert calls[0] == (["pactl", "list", "source-outputs"], "C", 3)

    def missing(argv, **kw):
        raise FileNotFoundError("pactl")
    assert lw.pactl_meeting(missing) is None


def test_meeting_windows_by_app_and_title_in_memory():
    assert lw.meeting_window("zoom", "Meeting") == "zoom"
    assert lw.meeting_window("zoom", "Zoom Meeting") == "zoom"
    assert lw.meeting_window("zoom", "Zoom Workplace") is None      # the home window is not a meeting
    assert lw.meeting_window("teams-for-linux", "Meeting with Anna | Microsoft Teams") == "teams"
    assert lw.meeting_window("teams-for-linux", "Chat | Microsoft Teams") is None
    assert lw.meeting_window("firefox", "Meet – abc-defg-hij") == "google meet"
    assert lw.meeting_window("Google-chrome", "meet.google.com is sharing your screen") == "google meet"
    assert lw.meeting_window("firefox", "Jitsi Meet") == "jitsi"
    assert lw.meeting_window("firefox", "How to meet deadlines - YouTube") is None
    assert lw.meeting_window(TERM, "zoom meeting notes.md") is None


# ---------- the tray in a meeting ----------

class Mic:
    """The microphone's call app, by the clock: (start, end, app) stretches."""

    def __init__(self, rig: Rig, *calls):
        self.rig, self.calls = rig, calls

    def __call__(self):
        return next((app for a, b, app in self.calls if a <= self.rig.t < b), None)


def meeting_rig(tmp_path, afk, window, calls=(), **settings) -> Rig:
    r = Rig(tmp_path, afk, window, **settings)
    r.tray.mic = Mic(r, *calls)
    return r


def test_away_from_the_keyboard_in_a_meeting_is_neither_a_break_nor_the_end(tmp_path):
    # typing 9:00-9:20, then 50 minutes in a Zoom call without touching anything (30 minutes away ends a session)
    afk = [awake(at(9), 20), away(at(9, 20), 50)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 50, "Zoom Workplace")]
    plain = Rig(tmp_path / "plain", afk, window)
    plain.tray.start(at(9)); plain.until(at(10, 10), at(9))
    assert plain.tray.session is None and plain.file()["ended"] == "away"     # what happened in the owner's meeting
    r = meeting_rig(tmp_path / "meet", afk, window, [(at(9, 21), at(10, 30), "zoom")])
    r.tray.start(at(9)); r.until(at(10, 10), at(9))
    assert r.tray.session is not None and r.tray.meeting_now == "zoom"
    r.tray.save(r.t); f = r.file()
    assert f["ended"] == "running" and f["breaks"] == []
    assert [(m["app"], m["source"]) for m in f["meetings"]] == [("zoom", "mic")]
    assert 48 <= f["meeting_min"] <= 50
    v = r.tray.view(r.t)
    assert v.icon == "working" and any(x.startswith("In a meeting (zoom) since") for x in v.lines)
    assert "Break hints wait until the meeting ends" in v.lines
    assert "zoom" not in json.dumps(f["detected"])                   # (manual: nothing detected)
    assert "SECRET" not in json.dumps(f)                               # titles never written


def test_a_meeting_window_in_front_makes_the_time_away_a_meeting_even_afterwards(tmp_path):
    # the Zoom meeting window in front 9:20-9:32 with nobody touching anything: no break, read from the window bucket
    afk = [awake(at(9), 20), away(at(9, 20), 12), awake(at(9, 32), 10)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 12, "Meeting"), win(TERM, at(9, 32), 10)]
    r = meeting_rig(tmp_path, afk, window)
    r.tray.start(at(9)); r.until(at(9, 40), at(9))
    f = r.file()
    assert f["breaks"] == [] and [(m["app"], m["source"]) for m in f["meetings"]] == [("zoom", "window")]
    assert r.tray.meeting_now is None


def test_after_a_restart_the_stretch_away_running_into_a_meeting_counts_as_it(tmp_path):
    """The owner's case on 2026-11-20: the old tray called the meeting a break. The new tray, taking the session up
    again, counts the time since the last keyboard or mouse use as the meeting the microphone shows now."""
    afk = [awake(at(9), 20), away(at(9, 20), 40)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 40, "Zoom Workplace")]
    old = Rig(tmp_path, afk, window)
    old.tray.start(at(9)); old.until(at(9, 28), at(9))
    assert any(b["source"] == "away" for b in old.file()["breaks"])          # "On a break" in the meeting
    new = meeting_rig(tmp_path, afk, window, [(at(9, 0), at(11), "zoom")])
    new.tray.resume(at(9, 30)); new.until(at(9, 31), at(9, 30))
    f = new.file()
    assert new.tray.session is not None and f["breaks"] == []
    assert lw.iso(at(9, 20)) == f["meetings"][0]["start"]                      # from the last input
    assert any("meeting (zoom)" in e["event"] for e in f["events"])


def test_a_session_the_old_tray_ended_as_away_in_a_meeting_is_taken_up_again(tmp_path):
    afk = [awake(at(9), 20), away(at(9, 20), 60)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 60, "Zoom Workplace")]
    old = Rig(tmp_path, afk, window)
    old.tray.start(at(9)); old.until(at(9, 55), at(9))
    assert old.tray.session is None and old.file()["ended"] == "away"
    new = meeting_rig(tmp_path, afk, window, [(at(9, 0), at(11), "zoom")])
    new.tray.resume(at(10)); new.until(at(10, 1), at(10))
    f = new.file()
    assert new.tray.session is not None and f["ended"] == "running" and f["start"] == lw.iso(at(9))
    assert any("the time away was a meeting" in e["event"] for e in f["events"])
    assert len(list((tmp_path / "work").glob("*.work.json"))) == 1           # the same session, not a new one


def test_a_real_break_after_a_meeting_is_still_a_break(tmp_path):
    afk = [awake(at(9), 20), away(at(9, 20), 40)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 10, "Zoom Workplace"), win(CHAT, at(9, 30), 30)]
    r = meeting_rig(tmp_path, afk, window, [(at(9, 21), at(9, 30), "zoom")])
    r.tray.start(at(9)); r.until(at(9, 45), at(9))
    f = r.file()
    assert [b["source"] for b in f["breaks"]] == ["away"]
    assert f["breaks"][0]["start"] == lw.iso(at(9, 29))                      # the last minute the call was seen


def test_no_hint_interrupts_a_meeting_and_it_comes_after_with_the_meeting_counted(tmp_path):
    # typing 9:00-9:40, a call 9:40-10:30 without typing, typing again from 10:30: the 60-minute hint is due at 10:00
    afk = [awake(at(9), 40), away(at(9, 40), 50), awake(at(10, 30), 30)]
    window = [win(TERM, at(9), 40), win("zoom", at(9, 40), 50, "Zoom Workplace"), win(TERM, at(10, 30), 30)]
    r = meeting_rig(tmp_path, afk, window, [(at(9, 41), at(10, 30), "zoom")])
    r.tray.start(at(9)); r.until(at(10, 29), at(9))
    assert [s for s in r.note.shown if s[0] == "hint"] == [] and r.tray.session.hints == []
    r.until(at(10, 32))
    hints = [s for s in r.note.shown if s[0] == "hint"]
    assert len(hints) == 1 and "1h29, 49 min of it in a meeting" in hints[0][2]      # 9:00-10:29, the call 9:40-10:29


def test_ask_waits_in_the_menu_during_a_meeting_and_pops_up_after(tmp_path):
    afk = [away(at(9), 30), awake(at(9, 30), 10)]
    window = [win("zoom", at(9), 30, "Meeting"), win(CHAT, at(9, 30), 10)]
    r = meeting_rig(tmp_path, afk, window, [(at(9), at(9, 30), "zoom")], auto_start="ask")
    r.until(at(9, 10), at(9))
    v = r.tray.view(r.t)
    assert r.tray.pending is not None and r.tray.pending.family == "meeting" and v.icon == "attention"
    assert {"yes", "no"} <= v.show and [s for s in r.note.shown if s[0] == "ask"] == []
    r.until(at(9, 31))
    asks = [s for s in r.note.shown if s[0] == "ask"]
    assert len(asks) == 1 and "meeting (zoom)" in asks[0][2]
    r.answer("ask", "yes")
    assert r.tray.session is not None and r.tray.session.start == at(9)


def test_automatic_starts_a_session_from_a_meeting_quietly(tmp_path):
    afk = [away(at(9), 40)]
    window = [win("zoom", at(9), 40, "Zoom Workplace")]
    r = meeting_rig(tmp_path, afk, window, [(at(9), at(10), "zoom")], auto_start="auto")
    r.until(at(9, 11), at(9))
    assert r.tray.session is None
    r.until(at(9, 13))
    s = r.tray.session
    assert s is not None and s.started_by == "auto" and s.start == at(9) and s.detected["family"] == "meeting"
    assert r.note.shown == []                                       # said after the meeting, not during it
    off = meeting_rig(tmp_path / "off", afk, window, [(at(9), at(10), "zoom")], auto_start="off")
    off.until(at(9, 30), at(9))
    assert off.tray.session is None and off.tray.pending is None


def test_the_phone_hears_whether_the_session_is_in_a_meeting(tmp_path):
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    got: list[bytes] = []

    class Phone(BaseHTTPRequestHandler):
        def do_POST(self):
            got.append(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers()

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Phone)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        (tmp_path / "phone").mkdir()
        (tmp_path / "phone" / "link.json").write_text(json.dumps(
            {"version": 1, "phone": {"address": "127.0.0.1", "port": srv.server_port, "token": "abcdefgh1234"}}))
        assert lw.phone_work_signal(tmp_path, True, meeting=True) == "sent"
        assert lw.phone_work_signal(tmp_path, False, meeting=False) == "sent"
    finally:
        srv.shutdown(); srv.server_close()
    assert got == [b'{"working": true, "meeting": true}', b'{"working": false, "meeting": false}']


def test_a_session_file_with_meetings_reads_back(tmp_path):
    afk = [awake(at(9), 20), away(at(9, 20), 20)]
    window = [win(TERM, at(9), 20), win("zoom", at(9, 20), 20, "Zoom Workplace")]
    r = meeting_rig(tmp_path, afk, window, [(at(9, 21), at(10), "zoom")])
    r.tray.start(at(9)); r.until(at(9, 35), at(9)); r.tray.save(r.t)
    again = meeting_rig(tmp_path, afk, window)                     # restarted; the microphone is not asked yet
    again.tray.resume(at(9, 36)); again.until(at(9, 36), at(9, 36))
    assert again.tray.session is not None and again.file()["breaks"] == []
    assert again.file()["meetings"][0]["start"] == lw.iso(at(9, 20))
    assert timedelta(0) < again.tray.meetings[0].end - again.tray.meetings[0].start
