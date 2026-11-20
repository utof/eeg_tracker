"""scripts/laptop_work.py: the laptop tray's logic on made-up ActivityWatch events and a fixed clock (no network, no
GTK). Detection (ask and automatic thresholds, relabelling), break hints on break_hints.py's rules, auto-break and
auto-stop, the session records, settings, the autostart file and the phone hook."""
import json, sys
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import break_hints as bh  # noqa: E402
import laptop_work as lw  # noqa: E402

TZ = timezone(timedelta(hours=3))
D = datetime(2026, 11, 18, 0, 0, tzinfo=TZ)
TERM, EDIT, CHAT, BROWSER = "com.mitchellh.ghostty", "Code", "AyuGramDesktop", "firefox"
TITLE = "SECRET-TITLE project plan"      # must never reach a file


def at(h: int, m: float = 0) -> datetime:
    return D + timedelta(hours=h, minutes=m)


def z(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


_ids = iter(range(1, 10**6))


def win(app: str, start: datetime, minutes: float, title: str = TITLE) -> dict:
    return {"id": next(_ids), "timestamp": z(start), "duration": minutes * 60, "data": {"app": app, "title": title}}


def awake(start: datetime, minutes: float) -> dict:
    return {"id": next(_ids), "timestamp": z(start), "duration": minutes * 60, "data": {"status": "not-afk"}}


def away(start: datetime, minutes: float) -> dict:
    return {"id": next(_ids), "timestamp": z(start), "duration": minutes * 60, "data": {"status": "afk"}}


def spans(afk: list) -> list:
    return bh.active_spans(afk, 3)


def run_at(window: list, afk: list, now: datetime, **kw) -> lw.Run | None:
    rp = lw.Replay(afk, window)
    sp = spans(rp.afk(now))
    return lw.current_run(rp.window_since(D - timedelta(hours=1), now), sp, now, replace(lw.Settings(), **kw))


class FakeNotifier:
    def __init__(self):
        self.shown: list[tuple] = []; self.closed: list[str] = []

    def show(self, key, title, body, actions, answer, low=False):
        self.shown.append((key, title, body, [k for k, _ in actions], answer))

    def close(self, key):
        self.closed.append(key)

    def last(self, key):
        return [s for s in self.shown if s[0] == key][-1]


class Rig:
    """A WorkTray on recorded events, ticking minute by minute; files in tmp."""

    def __init__(self, tmp: Path, afk: list, window: list, **settings):
        self.note = FakeNotifier(); self.rec = lw.Records(tmp / "work"); self.hints = lw.MemoryHintLog()
        self.tray = lw.WorkTray(lw.Replay(afk, window), self.note, self.rec, self.hints)
        self.tray.s = replace(lw.Settings(), **settings)
        self.t = D; self.tray.clock = lambda: self.t

    def until(self, end: datetime, start: datetime | None = None) -> None:
        self.t = start or self.t
        while self.t <= end:
            self.tray.tick(self.t); self.t += timedelta(minutes=1)
        self.t -= timedelta(minutes=1)

    def answer(self, key: str, ans: str) -> None:
        self.note.last(key)[4](ans)

    def file(self) -> dict:
        files = sorted((self.rec.folder).glob("*.work.json"))
        return json.loads(files[-1].read_text())

    def labels(self) -> list[dict]:
        f = self.rec.folder / "labels.jsonl"
        return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


# ---------- detection ----------

def test_ask_after_5_minutes_in_work_apps_and_only_while_in_one():
    w, a = [win(TERM, at(9), 30)], [awake(at(9), 30)]
    assert lw.verdict(run_at(w, a, at(9, 4)), lw.Settings()) is None
    r = run_at(w, a, at(9, 5))
    assert r is not None and round(r.work_min) == 5 and r.start == at(9) and r.app == TERM and r.now_in
    assert lw.verdict(r, lw.Settings()) == "ask"
    assert lw.verdict(r, lw.Settings(auto_start="off")) is None


def test_not_in_a_work_app_now_means_no_question():
    w = [win(TERM, at(9), 10), win(BROWSER, at(9, 10), 20, "a video")]
    assert run_at(w, [awake(at(9), 30)], at(9, 12)) is None          # the last run is the browser's


def test_automatic_needs_12_clear_minutes():
    w, a = [win(EDIT, at(9), 30)], [awake(at(9), 30)]
    auto = lw.Settings(auto_start="auto")
    assert lw.verdict(run_at(w, a, at(9, 11)), auto) is None
    assert lw.verdict(run_at(w, a, at(9, 12)), auto) == "auto"


def test_switches_count_against_sureness_but_not_against_asking():
    # 4 min work, 2 min chat, 4 min work, 2 min chat, 4 min work: one run (each switch is short), 12 min of work
    w = [win(TERM, at(9), 4), win(CHAT, at(9, 4), 2), win(TERM, at(9, 6), 4), win(CHAT, at(9, 10), 2),
         win(TERM, at(9, 12), 4)]
    r = run_at(w, [awake(at(9), 16)], at(9, 16))
    assert r is not None and round(r.work_min) == 12 and round(r.away_min) == 4
    assert round(r.clear_min) == 8    # 09:06-09:16 less the 2 chat minutes: the 2 chats together are over 3 min
    assert lw.verdict(r, lw.Settings(auto_start="auto")) is None
    assert lw.verdict(r, lw.Settings(auto_start="ask")) == "ask"
    r4 = run_at(w, [awake(at(9), 16)], at(9, 16), auto_max_away_min=4)       # both chats allowed: 12 clear min
    assert round(r4.clear_min) == 12 and lw.verdict(r4, lw.Settings(auto_start="auto")) == "auto"


def test_a_long_switch_starts_a_new_run():
    w = [win(TERM, at(9), 10), win(CHAT, at(9, 10), 4), win(TERM, at(9, 14), 3)]
    r = run_at(w, [awake(at(9), 17)], at(9, 17))
    assert r is not None and r.start == at(9, 14) and round(r.work_min) == 3


def test_pauses_under_5_minutes_count_as_work_time_a_break_restarts():
    w = [win(TERM, at(9), 3), win(TERM, at(9, 7), 3)]
    r = run_at(w, [awake(at(9), 3), away(at(9, 3), 4), awake(at(9, 7), 3)], at(9, 10))
    assert r is not None and r.start == at(9) and round(r.work_min) == 10     # clock minutes, the pause included
    w = [win(TERM, at(9), 10), win(TERM, at(9, 16), 2)]
    r = run_at(w, [awake(at(9), 10), away(at(9, 10), 6), awake(at(9, 16), 2)], at(9, 18))
    assert r is not None and r.start == at(9, 16) and round(r.work_min) == 2


def test_documentation_in_the_browser_is_work_a_video_is_not():
    a = [awake(at(9), 10)]
    assert run_at([win(BROWSER, at(9), 10, "Python 3 docs")], a, at(9, 10)).family == "code"
    assert run_at([win(BROWSER, at(9), 10, "a video")], a, at(9, 10)) is None


# ---------- the controller: asking, auto-start, relabelling ----------

def test_ask_yes_starts_the_session_when_the_work_began(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 60)], [win(TERM, at(9), 60)])
    g.until(at(9, 4))
    assert not g.note.shown and g.tray.pending is None
    g.until(at(9, 5))
    key, title, body, buttons, _ = g.note.last("ask")
    assert title == "Started working?" and buttons == ["yes", "no"] and TITLE not in body
    assert g.tray.view(g.t).icon == "attention" and {"yes", "no"} <= g.tray.view(g.t).show
    g.until(at(9, 8)); assert len(g.note.shown) == 1                  # asked once
    g.answer("ask", "yes")
    s = g.tray.session
    assert s is not None and s.started_by == "asked" and s.start == at(9)
    f = g.file()
    assert f["started_by"] == "asked" and datetime.fromisoformat(f["start"]) == at(9)
    assert f["labels"][0]["label"] == "work" and f["detected"]["app"] == TERM
    lab = g.labels()
    assert [x["answer"] for x in lab] == ["yes"] and lab[0]["question"] == "ask" and lab[0]["session"] == s.stamp
    assert lab[0]["rule"].startswith("laptop-detect-v1 ask=5 auto=12")


def test_ask_no_is_a_label_and_the_same_run_is_not_asked_again(tmp_path):
    afk = [awake(at(9), 60), away(at(10), 10), awake(at(10, 10), 60)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 60), win(TERM, at(10, 10), 60)], ask_again_min=30)
    g.until(at(9, 5)); g.answer("ask", "no")
    assert g.tray.session is None and g.labels()[-1]["answer"] == "no"
    g.until(at(9, 59)); assert len(g.note.shown) == 1
    g.until(at(10, 20))                         # a new run after a real break, past the 30 quiet minutes: asked again
    assert len(g.note.shown) == 2 and g.labels()[-1]["answer"] == "no"


def test_start_pressed_while_asked_closes_the_question(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 30)], [win(TERM, at(9), 30)])
    g.until(at(9, 6)); g.tray.start(g.t)
    assert g.tray.session.started_by == "manual" and g.tray.pending is None
    assert g.labels()[-1]["answer"] == "none" and "ask" in g.note.closed


def test_an_unanswered_question_lapses_at_a_real_break(tmp_path):
    afk = [awake(at(9), 7), away(at(9, 7), 10), awake(at(9, 17), 2)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 7), win(BROWSER, at(9, 17), 2, "news")])
    g.until(at(9, 5)); assert g.tray.pending is not None
    g.until(at(9, 18))
    assert g.tray.pending is None and g.labels()[-1]["answer"] == "none" and "ask" in g.note.closed


def test_automatic_start_and_not_work(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 90)], [win(EDIT, at(9), 90)], auto_start="auto")
    g.until(at(9, 11)); assert g.tray.session is None
    g.until(at(9, 12))
    s = g.tray.session
    assert s is not None and s.started_by == "auto" and s.start == at(9)
    key, title, body, buttons, _ = g.note.last("auto")
    assert title == "Work session started" and buttons == ["notwork", "ok"]
    assert "notwork" in g.tray.view(g.t).show
    g.answer("auto", "notwork")
    assert g.tray.session is None
    f = g.file()
    assert f["ended"] == "not_work" and f["labels"][-1]["label"] == "not_work"
    assert g.labels()[-1]["answer"] == "not_work" and g.labels()[-1]["question"] == "auto"
    g.until(at(10, 29)); assert g.tray.session is None             # the same run does not start again


def test_automatic_ok_is_a_work_label_and_no_answer_is_recorded_as_none(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 30)], [win(EDIT, at(9), 30)], auto_start="auto")
    g.until(at(9, 12)); g.answer("auto", "ok")
    assert g.file()["labels"][-1]["label"] == "work" and "notwork" not in g.tray.view(g.t).show
    h = Rig(tmp_path / "b", [awake(at(9), 30)], [win(EDIT, at(9), 30)], auto_start="auto", notifications=False)
    h.until(at(9, 12))
    assert h.tray.session is not None and not h.note.shown          # notifications off: it starts silently
    h.tray.stop(at(9, 20))
    assert h.labels()[-1]["answer"] == "none" and h.file()["labels"] == []


def test_manual_start_and_stop(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 60)], [win(BROWSER, at(9), 60, "news")], auto_start="off")
    g.until(at(9, 10)); g.tray.start(g.t)
    assert g.tray.session.started_by == "manual" and "stop" in g.tray.view(g.t).show
    g.until(at(9, 40)); g.tray.stop(g.t)
    f = g.file()
    assert f["ended"] == "stopped" and datetime.fromisoformat(f["end"]) == at(9, 40) and f["detected"] is None
    assert round(f["active_min"]) == 30


# ---------- breaks and the end of a session ----------

def test_five_minutes_away_is_a_break_thirty_ends_the_session(tmp_path):
    afk = [awake(at(9), 30), away(at(9, 30), 6), awake(at(9, 36), 20), away(at(9, 56), 40), awake(at(10, 36), 5)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 120)], auto_start="off")
    g.tray.start(at(9)); g.until(at(9, 34), at(9))
    assert g.tray.view(g.t).icon == "working"                         # 4 min away: a pause
    g.until(at(9, 35))
    v = g.tray.view(g.t)
    assert v.icon == "break" and v.lines[0].startswith("Away since")
    g.until(at(10, 40))
    f = g.file()
    assert f["ended"] == "away" and datetime.fromisoformat(f["end"]) == at(9, 56)
    assert [(b["source"], datetime.fromisoformat(b["start"])) for b in f["breaks"]] == [("away", at(9, 30))]
    # (the time away that ended it is after its end, not one of its breaks)


def test_never_ending_by_being_away(tmp_path):
    afk = [awake(at(9), 30), away(at(9, 30), 90), awake(at(11), 5)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 130)], auto_start="off", end_after_away_min=0)
    g.tray.start(at(9)); g.until(at(11, 4), at(9))
    assert g.tray.session is not None


def test_tapped_break_pauses_hints_and_ends_on_return(tmp_path):
    afk = [awake(at(9), 50), away(at(9, 50), 8), awake(at(9, 58), 30)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 120)], auto_start="off")
    g.tray.start(at(9)); g.until(at(9, 49), at(9))
    g.tray.on_break(g.t)
    assert g.tray.view(g.t).icon == "break" and "back" in g.tray.view(g.t).show
    g.until(at(10, 0))
    s = g.tray.session
    assert s.open_break() is None and s.tapped[0].end == at(9, 58) and s.tapped[0].ended_by == "returned"
    assert g.tray.view(g.t).icon == "working"


def test_a_short_tapped_break_only_pauses(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 120)], [win(TERM, at(9), 120)], auto_start="off")
    g.tray.start(at(9)); g.until(at(9, 30), at(9))
    g.tray.on_break(g.t); g.until(at(9, 33)); g.tray.back(g.t)
    g.until(at(10, 3))
    assert [h.at for h in g.tray.session.hints] == [at(10, 3)]      # 60 active min: the 3 tapped minutes not counted


# ---------- break hints: break_hints.py's rules ----------

def test_hint_at_60_active_minutes_like_break_hints(tmp_path):
    afk, w = [awake(at(9), 180)], [win(TERM, at(9), 180)]
    g = Rig(tmp_path, afk, w, auto_start="off")
    g.tray.start(at(9)); g.until(at(9, 59), at(9))
    assert not g.tray.session.hints
    assert g.tray.view(g.t).lines[-1].startswith(f"Next break hint about {lw.hm(at(10))}")
    g.until(at(10))
    h = g.tray.session.hints[0]
    assert h.at == at(10) and h.reason == "stretch" and h.threshold_min == 60
    key, title, body, buttons, _ = g.note.last("hint")
    assert title == "A short break?" and buttons == ["snooze", "break", "ok"] and "60 min" in body
    assert [r.kind for r in g.hints.history()] == ["shown"]
    expected = bh.decide(at(10), spans(afk), [], bh.Config())        # the same decision break_hints.py makes
    assert expected.show and expected.active_min == h.active_min
    assert g.tray.view(g.t).icon == "attention"


def test_snooze_brings_one_back_20_minutes_later(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 180)], [win(TERM, at(9), 180)], auto_start="off")
    g.tray.start(at(9)); g.until(at(10), at(9)); g.until(at(10, 2)); g.answer("hint", "snooze")
    assert [r.kind for r in g.hints.history()] == ["shown", "snoozed"]
    g.until(at(10, 22))
    assert [(h.at, h.reason) for h in g.tray.session.hints] == [(at(10), "stretch"), (at(10, 22), "snooze")]
    assert g.tray.session.hints[0].answer == "snoozed"


def test_on_a_break_from_the_hint_then_taken(tmp_path):
    afk = [awake(at(9), 61), away(at(10, 1), 10), awake(at(10, 11), 30)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 120)], auto_start="off")
    g.tray.start(at(9)); g.until(at(10), at(9)); g.answer("hint", "break")
    assert g.tray.session.open_break() is not None and "hint" in g.note.closed
    g.until(at(10, 6))
    kinds = [r.kind for r in g.hints.history()]
    assert kinds == ["shown", "taken"] and g.tray.session.hints[0].taken
    assert g.tray.session.hints[0].answer == "onBreak"


def test_quiet_hours_and_daily_cap_and_status_line(tmp_path):
    late = D.replace(hour=22)
    g = Rig(tmp_path, [awake(late, 120)], [win(TERM, late, 120)], auto_start="off")
    g.tray.start(late); g.t = late; g.until(late + timedelta(minutes=90), late)
    assert not g.tray.session.hints                                   # 23:00-08:00
    assert g.tray.view(g.t).lines[-1] == f"Break hints quiet until {lw.hm(late.replace(hour=8) + timedelta(days=1))}"


def test_no_hints_outside_a_session(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 120)], [win(BROWSER, at(9), 120, "news")], auto_start="off")
    g.until(at(11))
    assert g.tray.session is None and not g.hints.history()


def test_notifications_off_the_hint_waits_in_the_menu(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 120)], [win(TERM, at(9), 120)], auto_start="off", notifications=False)
    g.tray.start(at(9)); g.until(at(10, 1), at(9))
    v = g.tray.view(g.t)
    assert not g.note.shown and v.icon == "attention" and {"snooze", "dismiss", "break"} <= v.show
    assert g.tray.session.hints[0].via == "tray"
    g.tray.answer_hint("ok", g.t)
    assert g.tray.session.hints[0].answer == "notNow" and [r.kind for r in g.hints.history()] == ["shown", "dismissed"]
    g.tray.snooze(g.t)                                                # a snooze after OK still counts
    assert [r.kind for r in g.hints.history()][-1] == "snoozed"


def test_next_hint_follows_spacing_cap_and_breaks():
    cfg = bh.Config()
    sp = spans([awake(at(9), 300)])
    assert lw.next_hint_at(at(9, 30), sp, [], cfg) == at(10)
    hist = [bh.Rec(at(10), "shown", "h1")]
    assert lw.next_hint_at(at(10, 5), sp, hist, cfg) == at(10, 45)   # 45 min apart (threshold 75 reached earlier)
    four = [bh.Rec(at(9 + i), "shown", f"h{i}") for i in range(4)]
    assert lw.next_hint_at(at(13, 5), sp, four, cfg) is None          # 4 a day
    assert lw.next_hint_at(at(14, 10), spans([awake(at(9), 300)]), [], cfg) is None   # on a break (activity ended 14:00)


# ---------- records ----------

def test_the_session_file(tmp_path):
    afk = [awake(at(9), 70), away(at(10, 10), 6), awake(at(10, 16), 30)]
    g = Rig(tmp_path, afk, [win(TERM, at(9), 120)])
    g.until(at(9, 5)); g.answer("ask", "yes"); g.until(at(10, 40)); g.tray.stop(g.t)
    path = sorted(g.rec.folder.glob("*.work.json"))[-1]
    text = path.read_text()
    assert TITLE not in text and "SECRET" not in text                  # window titles are never written
    assert path.name == f"{at(9).astimezone():%Y-%m-%d-%H%M%S}.work.json"
    f = json.loads(text)
    assert set(f) == {"version", "kind", "app", "start", "end", "ended", "started_by", "detected", "active_min",
                      "meeting_min", "hints", "breaks", "meetings", "labels", "events", "settings", "written"}
    assert f["meetings"] == [] and f["meeting_min"] == 0                # (no meeting in it: DECISIONS 660-669)
    assert f["kind"] == "laptop_work_session" and f["version"] == 1 and f["ended"] == "stopped"
    assert all(datetime.fromisoformat(x).utcoffset() is not None for x in (f["start"], f["end"], f["written"]))
    assert set(f["hints"][0]) == {"at", "reason", "active_min", "threshold_min", "via", "answer", "answered_at",
                                  "taken", "event"}
    assert f["hints"][0]["taken"] and f["breaks"][0]["source"] == "away"
    assert f["settings"]["auto_start"] == "ask" and round(f["active_min"]) == 94
    assert not list(g.rec.folder.glob("*.tmp"))


def test_resume_after_a_restart_or_close_as_lost(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 60)], [win(TERM, at(9), 60)], auto_start="off")
    g.tray.start(at(9)); g.until(at(9, 20), at(9)); g.tray.on_break(g.t); g.tray.save(g.t)
    again = Rig(tmp_path, [awake(at(9), 60)], [win(TERM, at(9), 60)], auto_start="off")
    again.tray.resume(at(9, 25))
    s = again.tray.session
    assert s is not None and s.start == at(9) and s.open_break() is not None and s.started_by == "manual"
    late = Rig(tmp_path, [], [], auto_start="off")
    late.tray.resume(at(11))
    assert late.tray.session is None and late.file()["ended"] == "lost"


def test_replay_never_shows_the_future_and_merge_keeps_the_longest():
    rp = lw.Replay([awake(at(9), 60)], [win(TERM, at(9), 60), win(EDIT, at(9, 30), 10)])
    assert [e["duration"] for e in rp.afk(at(9, 10))] == [600]
    assert len(rp.window_since(at(9), at(9, 10))) == 1
    cache: dict = {}
    full = win(TERM, at(9), 30)
    lw.merge_events(cache, [full])
    lw.merge_events(cache, [{**full, "timestamp": z(at(9, 20)), "duration": 600}])     # cut to a later query
    a, b, _ = cache[full["id"]]
    assert a == at(9) and b == at(9, 30)
    lw.merge_events(cache, [{**full, "duration": 40 * 60}])                              # it grew
    assert cache[full["id"]][1] == at(9, 40)


def test_cut_and_away_gaps():
    sp = [(at(9), at(10))]
    assert lw.cut(sp, [(at(9, 10), at(9, 20))]) == [(at(9), at(9, 10)), (at(9, 20), at(10))]
    assert lw.away_gaps([(at(9), at(9, 10)), (at(9, 16), at(9, 20))], at(9), at(9, 40), 5) == \
        [(at(9, 10), at(9, 16)), (at(9, 20), None)]


def test_simulate_counts_a_day():
    afk = [awake(at(9), 70), away(at(10, 10), 40), awake(at(10, 50), 30)]
    w = [win(TERM, at(9), 70), win(BROWSER, at(10, 50), 30, "news")]
    r = lw.simulate(afk, w, at(8), at(12), lw.Settings(auto_start="ask"))
    assert (r["asked"], r["sessions"], r["ended_by_away"], r["hints"], r["hints_taken"]) == (1, 1, 1, 1, 1)
    r = lw.simulate(afk, w, at(8), at(12), lw.Settings(auto_start="auto"))
    assert (r["asked"], r["auto_started"], r["sessions"]) == (0, 1, 1)


# ---------- settings ----------

def test_settings_defaults_bad_values_and_round_trip(tmp_path):
    st = lw.SettingsStore(tmp_path / "eeg_tracker" / "tray.json")
    assert st.load() == lw.Settings() and st.problems == []
    s, problems = lw.settings_from({"auto_start": "always", "ask_after_min": 0, "hint_threshold_min": 75,
                                    "notifications": "yes", "max_hints_per_day": 2.5, "quiet": "22:00-07:00",
                                    "end_after_away_min": float("nan"), "unknown": 1})
    assert (s.auto_start, s.ask_after_min, s.hint_threshold_min, s.notifications, s.max_hints_per_day, s.quiet,
            s.end_after_away_min) == ("ask", 5.0, 75.0, True, 4, "22:00-07:00", 30.0)
    assert len(problems) == 5
    assert lw.settings_from({"quiet": "late"})[0].quiet == "23:00-08:00"
    st.save(replace(lw.Settings(), auto_start="auto", notifications=False))
    assert json.loads(st.path.read_text())["version"] == 1
    assert lw.SettingsStore(st.path).load() == replace(lw.Settings(), auto_start="auto", notifications=False)
    st.path.write_text("{broken")
    other = lw.SettingsStore(st.path)
    assert other.load() == lw.Settings() and other.problems


def test_settings_edited_by_hand_are_picked_up(tmp_path):
    st = lw.SettingsStore(tmp_path / "tray.json"); st.save(lw.Settings())
    tray = lw.WorkTray(lw.Replay([], []), FakeNotifier(), lw.Records(None), lw.MemoryHintLog(), st)
    import os
    st.path.write_text(json.dumps({"auto_start": "off"})); os.utime(st.path, (1, 1))
    tray.tick(at(9))
    assert tray.s.auto_start == "off"
    tray.set_setting(at(9), auto_start="auto")
    assert json.loads(st.path.read_text())["auto_start"] == "auto"


def test_switching_away_from_ask_drops_the_question(tmp_path):
    g = Rig(tmp_path, [awake(at(9), 30)], [win(TERM, at(9), 30)])
    g.until(at(9, 5)); g.tray.set_setting(g.t, auto_start="off")
    assert g.tray.pending is None and g.labels()[-1]["answer"] == "none" and "ask" in g.note.closed


# ---------- start at login ----------

def test_autostart_file(tmp_path):
    p = tmp_path / "autostart" / lw.AUTOSTART_NAME
    text = lw.autostart_text("/usr/bin/python3", Path("/home/a b/eeg $x/scripts/tray.py"), Path("/i.svg"))
    assert 'Exec=/usr/bin/python3 "/home/a b/eeg \\$x/scripts/tray.py"' in text
    assert "[Desktop Entry]" in text and "Type=Application" in text and "Terminal=false" in text
    assert lw._exec_arg("50%") == "50%%"
    assert not lw.autostart_on(p)
    lw.set_autostart(p, True, text)
    assert lw.autostart_on(p) and p.read_text() == text
    lw.set_autostart(p, False, text)
    assert not p.exists() and not lw.autostart_on(p)
    p.parent.mkdir(exist_ok=True); p.write_text(text + "Hidden=true\n")
    assert not lw.autostart_on(p)


def test_autostart_path_follows_xdg(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert lw.autostart_path() == tmp_path / "autostart" / "eeg-tracker-tray.desktop"
    assert lw.settings_path() == tmp_path / "eeg_tracker" / "tray.json"


# ---------- the phone hook ----------

def test_new_code_posts_to_this_laptops_own_port():
    import http.server, threading
    got: list[tuple[str, str, str | None]] = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_a):
            pass

        def do_POST(self):
            got.append((self.command, self.path, self.headers.get("Origin")))
            self.send_response(303); self.send_header("Location", "/"); self.send_header("Content-Length", "0")
            self.end_headers()

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert lw.post_new_code(f"http://127.0.0.1:{srv.server_address[1]}/new") is True
        assert got == [("POST", "/new", None)]
        assert lw.post_new_code("http://127.0.0.1:9/new") is False      # nobody there: no exception
    finally:
        srv.shutdown(); srv.server_close()


def test_pair_command(tmp_path):
    assert lw.pair_command(tmp_path, probe=lambda: None) is None      # no scripts/phone_link.py here
    (tmp_path / "scripts").mkdir(); (tmp_path / "scripts" / "phone_link.py").write_text("")
    cmd = lw.pair_command(tmp_path, "/usr/bin/python3", probe=lambda: None)
    assert cmd is None or cmd[-2:] == ["/usr/bin/python3", str(tmp_path / "scripts" / "phone_link.py")]


def test_pair_phone_runs_the_merged_phone_link(tmp_path):
    """"Pair phone…" (DECISIONS 530-539 and 570-579): phone_link.py in a terminal, copying into the tray's _local;
    while it already runs, its page with the bigger code instead of a second copy that could not take its port."""
    script = lw.REPO / "scripts" / "phone_link.py"
    assert script.is_file()                                           # merged: the item is no longer greyed out
    def which(name):
        return {"x-terminal-emulator": "/usr/bin/x-terminal-emulator"}.get(name)
    assert lw.pair_command(python="/usr/bin/python3", local=tmp_path, probe=lambda: None, which=which) == [
        "/usr/bin/x-terminal-emulator", "-e", "/usr/bin/python3", str(script), "--dest", str(tmp_path)]
    only_gnome = {"gnome-terminal": "/usr/bin/gnome-terminal"}.get
    assert lw.pair_command(python="py", probe=lambda: None, which=only_gnome) == [
        "/usr/bin/gnome-terminal", "--", "py", str(script)]
    assert lw.pair_command(probe=lambda: None, which=lambda _: None) is None   # no terminal program
    posted: list[str] = []
    running = lw.pair_command(local=tmp_path, probe=lambda: {"connected": False}, which=lambda _: None,
                              new_code=posted.append)
    # a code is asked for by POST (a plain link makes none: DECISIONS 750), then its page opens
    assert posted == ["http://127.0.0.1:8771/new"] and running == ["xdg-open", "http://127.0.0.1:8771/"]
    import phone_link
    assert lw.PAIR_PAGE == f"http://127.0.0.1:{phone_link.PORT}/"
    assert 'add_argument("--dest"' in script.read_text(encoding="utf-8")


def test_the_phone_hears_when_a_work_session_starts_and_ends(tmp_path):
    """Automatic recording on the phone (DECISIONS 603) takes "working" from the laptop: a session that starts (by
    hand, after "Yes", or by itself) tells it True, one that ends tells it False; a session taken up again after a
    restart tells it nothing new."""
    told: list[bool] = []
    tray = lw.WorkTray(lw.Replay([], []), FakeNotifier(), lw.Records(tmp_path / "work"), lw.MemoryHintLog(),
                       work_signal=told.append)
    tray.start(at(9))
    tray.start(at(9, 5))                                  # already running: nothing more
    assert told == [True]
    tray.stop(at(10))
    tray.stop(at(10, 5))
    assert told == [True, False]
    def broken(_working):
        raise OSError("no network")
    tray2 = lw.WorkTray(lw.Replay([], []), FakeNotifier(), lw.Records(None), lw.MemoryHintLog(), work_signal=broken)
    tray2.start(at(11))                                   # a phone that cannot be told never stops a session
    assert tray2.session is not None


def test_the_work_signal_goes_to_the_paired_phone_signed(tmp_path):
    """POST /work on the phone's Share on Wi-Fi server, signed with the key from phone_link.py's link.json
    (DECISIONS 755: the phone takes it from nobody else); an answer in words for the log; no secret in it."""
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from test_pull_phone import signed_ok
    key = "6" * 64
    got: list[tuple[str, str | None, bytes, bool]] = []
    code = [202]

    class Phone(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n)
            reply = signed_ok(self, key, body)
            got.append((self.path, self.headers.get("Authorization"), body, reply is not None))
            self.send_response(code[0] if reply else 401)
            if reply:
                self.send_header("X-Eeg-Reply", reply)
            self.send_header("Content-Length", "0"); self.end_headers()

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Phone)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert lw.phone_work_signal(tmp_path, True) == "not paired"
        (tmp_path / "phone").mkdir()
        (tmp_path / "phone" / "link.json").write_text(json.dumps(
            {"version": 2, "key": key, "phone": {"address": "127.0.0.1", "port": srv.server_port}}))
        assert lw.phone_work_signal(tmp_path, True) == "sent"
        assert lw.phone_work_signal(tmp_path, False) == "sent"
        assert got == [("/work", None, b'{"working": true}', True), ("/work", None, b'{"working": false}', True)]
        code[0] = 503                                     # a night records: the phone does not take it
        out = lw.phone_work_signal(tmp_path, True)
        assert out == "refused (503)" and key not in out
    finally:
        srv.shutdown(); srv.server_close()
    assert lw.phone_work_signal(tmp_path, True, timeout=0.5) == "not reachable"
    (tmp_path / "phone" / "link.json").write_text(json.dumps(
        {"version": 2, "key": key, "phone": {"address": "8.8.8.8", "port": 8765}}))
    assert lw.phone_work_signal(tmp_path, True) == "not paired"   # only a local-network phone is ever called
    (tmp_path / "phone" / "link.json").write_text(json.dumps(
        {"version": 1, "laptop_key": "k" * 43, "phone": {"address": "127.0.0.1", "port": 8765, "token": "abcdefgh1234"}}))
    assert lw.phone_work_signal(tmp_path, True) == "not paired"   # an old pairing: one new scan first
