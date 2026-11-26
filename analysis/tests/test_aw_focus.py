"""scripts/aw_focus.py: focus sessions from made-up ActivityWatch events (no network, fixed clock)."""
import json, sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import aw_focus as af  # noqa: E402
import break_hints as bh  # noqa: E402

TZ = timezone(timedelta(hours=3))
D = datetime(2026, 11, 18, 0, 0, tzinfo=TZ)
LO, HI = D - timedelta(hours=12), D + timedelta(days=2)
CFG = af.FocusConfig()
TERM, EDIT, CHAT, BROWSER = "com.mitchellh.ghostty", "Code", "AyuGramDesktop", "firefox"


def at(h: int, m: int = 0, day: int = 0) -> datetime:
    return D + timedelta(days=day, hours=h, minutes=m)


def z(t: datetime) -> str:
    return t.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def win(app: str, start: datetime, minutes: float, title: str = "x") -> dict:
    return {"timestamp": z(start), "duration": minutes * 60, "data": {"app": app, "title": title}}


def awake(start: datetime, minutes: float) -> dict:
    return {"timestamp": z(start), "duration": minutes * 60, "data": {"status": "not-afk"}}


def away(start: datetime, minutes: float) -> dict:
    return {"timestamp": z(start), "duration": minutes * 60, "data": {"status": "afk"}}


def sessions(window: list, afk: list, cfg: af.FocusConfig = CFG) -> list[af.Session]:
    spans = bh.active_spans(afk, 3)
    return af.find_sessions(af.segments(window, spans), cfg)


def records(window: list, afk: list, cfg: af.FocusConfig = CFG) -> dict:
    return af.compute(window, afk, cfg, TZ, LO, HI, date(2026, 11, 18))


# ---- what is one session ----

def test_a_long_run_in_one_family_is_one_session():
    s = sessions([win(TERM, at(9), 50), win(EDIT, at(9, 50), 40)], [awake(at(9), 90)])
    assert len(s) == 1 and s[0].active_min == 90 and s[0].start == at(9)   # terminal and editor are one family


def test_under_35_minutes_is_not_a_session():
    assert sessions([win(TERM, at(9), 34)], [awake(at(9), 34)]) == []
    assert len(sessions([win(TERM, at(9), 35)], [awake(at(9), 35)])) == 1


def test_a_break_of_5_minutes_splits_and_each_half_must_be_long_enough():
    afk = [awake(at(9), 40), away(at(9, 40), 5), awake(at(9, 45), 40)]
    s = sessions([win(TERM, at(9), 90)], afk)                            # the window watcher runs on while away
    assert [x.start for x in s] == [at(9), at(9, 45)] and [x.active_min for x in s] == [40, 40]
    short = [awake(at(9), 30), away(at(9, 30), 5), awake(at(9, 35), 30)]
    assert sessions([win(TERM, at(9), 65)], short) == []                 # 30 + 30 min do not add up to one


def test_a_pause_under_5_minutes_keeps_the_session_but_is_not_counted():
    afk = [awake(at(9), 20), away(at(9, 20), 4), awake(at(9, 24), 20)]
    s = sessions([win(TERM, at(9), 44)], afk)
    assert len(s) == 1 and s[0].active_min == 40 and s[0].end == at(9, 44)


def test_afk_time_is_not_counted_even_when_the_window_stays_open():
    afk = [awake(at(9), 36), away(at(9, 36), 120)]
    s = sessions([win(TERM, at(9), 156)], afk)
    assert len(s) == 1 and s[0].active_min == 36 and s[0].end == at(9, 36)


# ---- short switches ----

def test_a_short_switch_to_chat_does_not_end_a_session():
    w = [win(TERM, at(9), 20), win(CHAT, at(9, 20), 2), win(TERM, at(9, 22), 20)]
    s = sessions(w, [awake(at(9), 42)])
    assert len(s) == 1 and s[0].active_min == 42 and s[0].app == TERM


def test_a_longer_switch_ends_it():
    w = [win(TERM, at(9), 30), win(CHAT, at(9, 30), 4), win(TERM, at(9, 34), 30)]
    assert sessions(w, [awake(at(9), 64)]) == []                         # 30 + 30, split by 4 min of chat


def test_several_short_switches_add_up_to_a_longer_one():
    w = [win(TERM, at(9), 30), win(CHAT, at(9, 30), 2), win(BROWSER, at(9, 32), 2), win(TERM, at(9, 34), 30)]
    assert sessions(w, [awake(at(9), 64)]) == []                         # 4 min away in total


def test_each_switch_of_3_minutes_is_allowed_one_by_one():
    w = [win(TERM, at(9), 12), win(CHAT, at(9, 12), 3), win(TERM, at(9, 15), 12), win(CHAT, at(9, 27), 3),
         win(TERM, at(9, 30), 12)]
    s = sessions(w, [awake(at(9), 42)])
    assert len(s) == 1 and s[0].active_min == 42


def test_switch_to_unrelated_work_is_not_related_work():
    w = [win(CHAT, at(9), 50)]
    assert sessions(w, [awake(at(9), 50)]) == []                         # a long chat is not focus ...
    assert len(sessions(w, [awake(at(9), 50)], af.FocusConfig(any_app=True))) == 1   # ... unless asked


def test_documentation_in_the_browser_is_related_to_the_terminal_but_other_pages_are_not():
    docs = [win(TERM, at(9), 20), win(BROWSER, at(9, 20), 15, "Flutter docs - Mozilla Firefox"), win(TERM, at(9, 35), 20)]
    assert len(sessions(docs, [awake(at(9), 55)])) == 1 and sessions(docs, [awake(at(9), 55)])[0].active_min == 55
    video = [win(TERM, at(9), 20), win(BROWSER, at(9, 20), 15, "funny cats - YouTube"), win(TERM, at(9, 35), 20)]
    assert sessions(video, [awake(at(9), 55)]) == []


# ---- days and blocks ----

def test_a_session_counts_in_the_2_hour_block_it_started_in():
    r = records([win(TERM, at(9, 50), 130)], [awake(at(9, 50), 130)])["2026-11-18"]
    assert r["sessions"] == 1 and r["blocks"] == {"08-10": 1}            # runs into 10-12 and 12-14, counted once


def test_the_block_edge():
    r = records([win(TERM, at(9, 59), 40), win(TERM, at(12, 0), 40)],
                [awake(at(9, 59), 40), awake(at(12, 0), 40)])["2026-11-18"]
    assert r["blocks"] == {"08-10": 1, "12-14": 1} and r["sessions"] == 2


def test_midnight_the_day_runs_04_to_04():
    w = [win(TERM, at(23, 30), 60), win(TERM, at(0, 45, day=1), 40, "t"), win(TERM, at(3, 50, day=1), 40)]
    afk = [awake(at(23, 30), 60), awake(at(0, 45, day=1), 40), awake(at(3, 50, day=1), 40)]
    r = records(w, afk)
    assert r["2026-11-18"]["blocks"] == {"22-24": 1, "00-02": 1, "02-04": 1}   # all three belong to the 18th
    assert "2026-11-19" not in r or r["2026-11-19"]["sessions"] == 0


def test_a_session_across_midnight_is_one_session_on_the_day_it_started():
    r = records([win(TERM, at(23, 20), 80)], [awake(at(23, 20), 80)])["2026-11-18"]
    assert r["sessions"] == 1 and r["blocks"] == {"22-24": 1} and r["list"][0]["min"] == 80


def test_a_day_with_laptop_time_but_no_session_is_a_zero_and_a_day_without_is_missing():
    r = records([win(TERM, at(9), 20), win(TERM, at(14), 20), win(TERM, at(18), 20, "t")],
                [awake(at(9), 20), awake(at(14), 20), awake(at(18), 20)])
    assert r["2026-11-18"]["sessions"] == 0 and r["2026-11-18"]["blocks"] == {}   # 60 min on, none long enough
    assert "2026-11-19" not in r                                                   # not on: unknown, not zero
    assert records([win(TERM, at(9), 20)], [awake(at(9), 20)]) == {}               # under 35 min on: says nothing


def test_no_data_at_all():
    assert records([], []) == {} and af.segments([], []) == [] and af.find_sessions([]) == []


def test_the_range_start_cuts_nothing_into_a_false_session():
    begin = LO - timedelta(hours=2)                                     # a run already going on when the range starts
    r = af.compute([win(TERM, begin, 240)], [awake(begin, 240)], CFG, TZ, LO, HI, date(2026, 11, 17))
    assert r and all(x["sessions"] == 0 for x in r.values())             # its true start is unknown: not counted


# ---- the file ----

def test_titles_never_reach_the_file(tmp_path):
    w = [win(TERM, at(9), 40, "SECRET-TITLE secrets.txt"), win(BROWSER, at(10), 2, "bank SECRET-TITLE docs")]
    recs = records(w, [awake(at(9), 40), awake(at(10), 2)])
    af.write_days(tmp_path, recs)
    text = (tmp_path / "phone" / "sharp-hours" / "focus-2026-11.jsonl").read_text()
    assert "SECRET" not in text and "secrets" not in text
    line = json.loads(text)
    assert line["day"] == "2026-11-18" and line["sessions"] == 1 and line["list"][0]["app"] == TERM


def test_writing_twice_gives_the_same_file_and_other_days_stay(tmp_path):
    w = [win(TERM, at(9), 40)]
    a = records(w, [awake(at(9), 40)])
    assert af.write_days(tmp_path, a) != []
    f = tmp_path / "phone" / "sharp-hours" / "focus-2026-11.jsonl"
    first = f.read_bytes()
    assert af.write_days(tmp_path, a) == [] and f.read_bytes() == first   # nothing changed: nothing rewritten
    older = {"2026-11-10": dict(version=1, day="2026-11-10", sessions=2, blocks={"10-12": 2}, list=[], through="x",
                                rule="old")}
    af.write_days(tmp_path, older)
    af.write_days(tmp_path, a)
    days = [json.loads(x)["day"] for x in f.read_text().splitlines()]
    assert days == ["2026-11-10", "2026-11-18"]                           # sorted, the old day kept
    b = records([win(TERM, at(9), 40), win(TERM, at(14), 50)], [awake(at(9), 40), awake(at(14), 50)])
    af.write_days(tmp_path, b)
    assert json.loads(f.read_text().splitlines()[-1])["sessions"] == 2   # a recomputed day replaces its own line


def test_a_cut_off_line_is_skipped(tmp_path):
    f = tmp_path / "phone" / "sharp-hours" / "focus-2026-11.jsonl"
    f.parent.mkdir(parents=True)
    f.write_text('{"version":1,"day":"2026-11-09","sessions":1,"blocks":{"10-12":1},"list":[]}\n{"version":1,"da')
    assert list(af.read_days(f)) == ["2026-11-09"]


# ---- the view ----

def _rating(day: str, hh: int, v: float) -> str:
    return json.dumps({"version": 1, "at": f"{day}T{hh:02d}:15:00+03:00", "sharp": v})


def test_view_puts_ratings_and_sessions_in_the_same_blocks(tmp_path):
    d = tmp_path / "phone" / "sharp-hours"; d.mkdir(parents=True)
    (d / "ratings.jsonl").write_text("\n".join([_rating("2026-11-18", 9, 4), _rating("2026-11-18", 9, 2),
                                               _rating("2026-11-18", 15, 3), _rating("2026-11-12", 9, 5)]) + "\nbroken")
    af.write_days(tmp_path, records([win(TERM, at(9), 40), win(TERM, at(16), 40)],
                                    [awake(at(9), 40), awake(at(16), 40)]))
    t = af.block_table(af.read_ratings(tmp_path), af.read_focus(tmp_path))
    rows = {r["block"]: r for r in t["rows"]}
    assert t["days"] == 1                                              # only 11-18 has both; 11-12 has no laptop data
    assert rows["08-10"]["ratings"] == 2 and rows["08-10"]["mean"] == 3.0 and rows["08-10"]["sessions"] == 1
    assert rows["14-16"]["mean"] == 3.0 and rows["14-16"]["sessions"] == 0
    assert rows["16-18"]["sessions"] == 1 and rows["16-18"]["ratings"] == 0
    text = "\n".join(af.show_lines(t))
    assert "Seen together, not tested" in text and "08-10" in text


def _test_line(day: str, hh: int, times: list, **extra) -> str:
    """A 1-minute reaction test the phone kept (docs/data-format.md): it follows the rating of `hh:15`."""
    return json.dumps({"version": 1, "at": f"{day}T{hh:02d}:16:00+03:00", "rating_at": f"{day}T{hh:02d}:15:00+03:00",
                       "length_s": 60, "false_starts": 0, "times_ms": times, **extra})


def test_view_puts_reaction_tests_beside_the_ratings_and_the_sessions(tmp_path):
    """DECISIONS 1135: the tests' medians per 2-hour block of the rating they followed, with the phone's own rules."""
    d = tmp_path / "phone" / "sharp-hours"; d.mkdir(parents=True)
    (d / "ratings.jsonl").write_text("\n".join([_rating("2026-11-18", 9, 4), _rating("2026-11-18", 15, 3)]) + "\n")
    (d / "reactions.jsonl").write_text("\n".join([
        _test_line("2026-11-18", 9, [300, 310, 320, 330, 340]),                  # median 320
        _test_line("2026-11-18", 9, [400, 400, 400, 400, 400, 400]),            # median 400: the block's median is 360
        _test_line("2026-11-18", 15, [250, 260, 270, 280]),                      # 4 taps: no median, not counted
        _test_line("2026-11-18", 15, [50, 300, 300, 300, 300]),                  # a tap under 100 ms: refused whole
        _test_line("2026-11-12", 9, [200] * 5),                                  # a day with no laptop data
        _test_line("2026-11-18", 11, [300, 310, 320, 331, 340, 351]),           # even: 325.5 rounds to 326
    ]) + "\nbroken")
    af.write_days(tmp_path, records([win(TERM, at(9), 40), win(TERM, at(16), 40)], [awake(at(9), 40), awake(at(16), 40)]))
    tests = af.read_reactions(tmp_path)
    assert sorted(m for _, _, m in tests) == [200, 320, 326, 400]      # 4 taps and a refused line are not tests
    t = af.block_table(af.read_ratings(tmp_path), af.read_focus(tmp_path), tests)
    rows = {r["block"]: r for r in t["rows"]}
    assert t["days"] == 1 and t["tests_imported"]
    assert (rows["08-10"]["tests"], rows["08-10"]["median_ms"], rows["08-10"]["sessions"]) == (2, 360.0, 1)
    assert (rows["10-12"]["tests"], rows["10-12"]["median_ms"]) == (1, 326)
    assert (rows["14-16"]["tests"], rows["14-16"]["median_ms"], rows["14-16"]["ratings"]) == (0, None, 1)
    text = "\n".join(af.show_lines(t))
    assert "tests" in text and "360" in text and "326" in text and "Seen together, not tested" in text


def test_view_with_tests_and_sessions_but_no_ratings_and_the_old_view_without_tests(tmp_path):
    d = tmp_path / "phone" / "sharp-hours"; d.mkdir(parents=True)
    (d / "reactions.jsonl").write_text(_test_line("2026-11-18", 9, [300] * 5) + "\n")
    af.write_days(tmp_path, records([win(TERM, at(9), 40)], [awake(at(9), 40)]))
    t = af.block_table(af.read_ratings(tmp_path), af.read_focus(tmp_path), af.read_reactions(tmp_path))
    assert t["days"] == 1 and not t["ratings_imported"] and t["tests_imported"]
    assert {r["block"]: r["tests"] for r in t["rows"]}["08-10"] == 1
    none = af.block_table(af.read_ratings(tmp_path), af.read_focus(tmp_path))      # the two-argument call of before
    assert not none["tests_imported"] and "tests" not in "\n".join(af.show_lines(none))


def test_view_without_ratings_and_without_anything(tmp_path):
    af.write_days(tmp_path, records([win(TERM, at(9), 40)], [awake(at(9), 40)]))
    t = af.block_table(af.read_ratings(tmp_path), af.read_focus(tmp_path))
    assert not t["ratings_imported"] and t["days"] == 1 and "no sharp-hours ratings" in af.show_lines(t)[0]
    empty = af.block_table([], {})
    assert "No days" in af.show_lines(empty)[0]


# ---- the server ----

def test_server_not_running(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(bh, "AW", "http://127.0.0.1:9/api/0")           # nothing listens on port 9
    lines: list[str] = []
    code = af.main(["--dest", str(tmp_path), "--dry-run"], out=lines.append)
    assert code == 1 and "not reachable" in lines[0] and not list(tmp_path.rglob("*"))


def test_main_with_a_fake_server_writes_and_dry_run_does_not(monkeypatch, tmp_path):
    host = "testhost"
    now = at(20)
    w = [win(TERM, at(9), 60), win(CHAT, at(10), 1)]
    k = [awake(at(9), 61)]

    def fake_get(path, **params):
        if path == "/buckets/":
            return {f"aw-watcher-window_{host}": {}, f"aw-watcher-afk_{host}": {}, "aw-watcher-window_other": {}}
        return w if "window" in path else k

    monkeypatch.setattr(bh, "aw_get", fake_get)
    lines: list[str] = []
    args = ["--dest", str(tmp_path), "--host", host, "--since", "2026-11-18"]
    assert af.main(args + ["--dry-run"], out=lines.append, now=now) == 0
    assert not list(tmp_path.rglob("*")) and any("1 session" in x for x in lines)
    assert af.main(args, out=lines.append, now=now) == 0
    assert (tmp_path / "phone" / "sharp-hours" / "focus-2026-11.jsonl").exists()
    again: list[str] = []
    af.main(args, out=again.append, now=now)
    assert not any(x.startswith("wrote") for x in again)                # a second run changes nothing


def test_no_activity_in_range_is_not_an_error(monkeypatch, tmp_path):
    monkeypatch.setattr(bh, "aw_get", lambda path, **p: {"aw-watcher-window_h": {}, "aw-watcher-afk_h": {}}
                        if path == "/buckets/" else [])
    lines: list[str] = []
    assert af.main(["--dest", str(tmp_path), "--host", "h"], out=lines.append, now=at(20)) == 0
    assert "no laptop activity" in lines[0]


def test_since_forms():
    assert af.parse_since("7d", date(2026, 11, 19)) == date(2026, 11, 12)
    assert af.parse_since("2026-11-01", date(2026, 11, 19)) == date(2026, 11, 1)
