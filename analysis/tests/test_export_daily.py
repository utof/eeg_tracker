"""The daily summary for utof_tracker (scripts/day_summary.py, scripts/export_events.py --daily; DECISIONS 550-559,
docs/utof-interface.md). A made-up `_local/` with every kind of file; the expected numbers are worked out by hand
from the Trends rules (app/lib/trends/, work/days.dart, sharp/hours.dart), not by the code under test."""
import json
import re
from datetime import datetime
from pathlib import Path

import day_summary as ds
import export_events as ex

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime.fromisoformat("2026-11-25T12:00:00+03:00")


def _w(p: Path, obj) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj))


def _jl(p: Path, rows: list, tail: str = "") -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(json.dumps(r) + "\n" for r in rows) + tail)


def _report(night_of, start, end, asleep, light, deep, dream, wakeups, awake, *, extras=None, drift=None,
            stages=None, wearer=None, scored=True, model="anysleep-mid-fusion-3runs@88e13e3 onnx-f16"):
    r = dict(version=2, night_of=night_of, data_start=start, data_end=end, scored=scored, model=model,
             total=dict(asleep_min=asleep, light_min=light, deep_min=deep, dream_min=dream, wake_ups=wakeups),
             periods=[dict(start=start, end=end, asleep_min=asleep, awake_min=awake, confidence=0.8)] if scored else [],
             extras=extras, drift_off=drift)
    if stages:
        r["stages"] = stages
    if wearer:
        r["wearer"] = dict(answer=wearer, at=end)
    return r


def _morning(start, ratings=None, back=None, **extra):
    b = dict(alpha_ec_uv2=40.0, alpha_eo_uv2=10.0, ec_rise=4.0, iaf_hz=9.8, aperiodic_slope_ec=-1.4, clean_share=0.9)
    b.update(back or {})
    ch = dict(alpha_ec_uv2=40.0, alpha_eo_uv2=10.0, ec_rise=4.0, iaf_hz=9.8, iaf_peak_hz=9.8, alpha_peak_present=True,
              aperiodic_slope_ec=-1.4, clean_share_ec=0.9, clean_share_eo=0.9)
    return dict(version="morning-v1", source="x.f32", start=start, end=start, date=start[:10],
                phase_s=dict(eyes_closed=120.0, eyes_open=120.0), channels=dict(O1=ch, O2=ch), back=b,
                ratings=ratings, **extra)


def _epochs(t0: str, levels: list[str]) -> list[dict]:
    t = datetime.fromisoformat(t0)
    return [dict(at=(t.fromtimestamp(t.timestamp() + 30 * i, t.tzinfo)).isoformat(), s=30 * i, level=lv,
                 eyes_closed=False) for i, lv in enumerate(levels)]


def make_local(tmp: Path) -> Path:
    loc = tmp / "_local"
    ph = loc / "phone"
    stages = "WW" + "1" * 20 + "2" * 200 + "3" * 80 + "R" * 100 + "W" * 20 + "2" * 100 + "WW"
    # a night woken from on 11-20 (noisy or missing 50 of 400 minutes asleep); lights off by the button
    _w(ph / "nights/2026-11-19.report.json", _report(
        "2026-11-19", "2026-11-19T23:30:00+03:00", "2026-11-20T07:10:00+03:00", 400.0, 200.0, 60.0, 140.0, 3, 12.5,
        extras=dict(asleep=dict(min=400.0, degraded_min=40.0, missing_min=10.0, jaw_bursts=20, jaw_per_hour=3.0)),
        drift=dict(source="button", model_onset_min=14.5), stages=stages))
    # an afternoon nap the same day: the laptop's report wins over the phone's copy, the phone's answer is kept
    nap = dict(extras=dict(asleep=dict(min=90.0, degraded_min=0.0, missing_min=0.0, jaw_bursts=3, jaw_per_hour=2.0)),
               drift=dict(source="night start", model_onset_min=5.0))
    _w(loc / "nights/2026-11-20.report.json", _report(
        "2026-11-20", "2026-11-20T13:00:00+03:00", "2026-11-20T14:50:00+03:00", 90.0, 70.0, 20.0, 0.0, 0, 4.0, **nap))
    _w(ph / "nights/2026-11-20.report.json", _report(
        "2026-11-20", "2026-11-20T13:00:00+03:00", "2026-11-20T14:50:00+03:00", 50.0, 50.0, 0.0, 0.0, 0, 4.0,
        wearer="me", **nap))
    _w(ph / "nights/2026-11-21.report.json", _report(  # someone else
        "2026-11-21", "2026-11-21T23:00:00+03:00", "2026-11-22T07:00:00+03:00", 420.0, 200.0, 80.0, 140.0, 1, 5.0,
        stages="W" + "2" * 100 + "W", wearer="someone else"))
    _w(ph / "nights/2026-11-22.report.json", _report(  # noisy: (120 + 60) / 300 = 0.6
        "2026-11-22", "2026-11-22T23:00:00+03:00", "2026-11-23T07:00:00+03:00", 300.0, 200.0, 50.0, 50.0, 2, 5.0,
        extras=dict(asleep=dict(min=300.0, degraded_min=120.0, missing_min=60.0, jaw_bursts=0, jaw_per_hour=0.0))))
    _w(ph / "nights/2026-11-23.report.json", _report(  # under 5 minutes: unscored
        "2026-11-23", "2026-11-23T23:00:00+03:00", "2026-11-24T00:30:00+03:00", 0, 0, 0, 0, 0, 0, scored=False))
    _w(ph / "nights/damaged.report.json", {"night_of": 3})
    # check-ins: the phone's first (no tension), the laptop's later one gives tension; a noisy one; someone else's
    _w(ph / "mornings/2026-11-20-071500.morning.json", _morning(
        "2026-11-20T07:15:00+03:00", dict(kss=6, mood=3, tension=None), app="phone",
        habits=dict(caffeine_cups=2, alcohol_drinks=0, caffeine_late=False), reaction=dict(median_ms=312)))
    _w(loc / "recordings/2026-11-20-090000.morning.json", _morning(
        "2026-11-20T09:00:00+03:00", dict(kss=3, mood=5, tension=4), back=dict(iaf_hz=10.4)))
    _w(loc / "recordings/2026-11-21-080000.morning.json", _morning(
        "2026-11-21T08:00:00+03:00", dict(kss=7, mood=2, tension=3), back=dict(clean_share=0.3)))
    _w(ph / "mornings/2026-11-22-080000.morning.json", _morning(
        "2026-11-22T08:00:00+03:00", dict(kss=1, mood=1, tension=1), wearer=dict(answer="someone else", at="x")))
    sh = ph / "sharp-hours"
    r = dict(version=1, scale="1-5", prompt=None, shown=None, test_asked=False)
    _jl(sh / "ratings.jsonl", [dict(r, at="2026-11-20T10:00:00+03:00", sharp=4),
                               dict(r, at="2026-11-20T14:00:00+03:00", sharp=2),
                               dict(r, at="2026-11-21T03:30:00+03:00", sharp=3),  # before 04:00: still 11-20
                               dict(r, at="2026-11-20T15:00:00+03:00", sharp=7)],  # not on the scale
        tail='{"version":1,"scale":"1-5","at":"2026-11-20T16:00:00+03:00","sharp":1}')  # no newline: mid-write
    t = dict(version=1, at="2026-11-20T10:01:00+03:00", length_s=60, false_starts=0)
    _jl(sh / "reactions.jsonl", [dict(t, rating_at="2026-11-20T10:00:00+03:00", times_ms=[300, 310, 320, 330, 340, 351]),
                                 dict(t, rating_at="2026-11-20T10:30:00+03:00", times_ms=[400, 410, 420, 430]),
                                 dict(t, rating_at="2026-11-20T14:00:00+03:00", times_ms=[200, 210, 220, 230, 240]),
                                 dict(t, rating_at="2026-11-20T14:30:00+03:00", times_ms=[900] * 5,  # refused whole,
                                      false_starts=-1)])  # as the phone does
    _jl(sh / "focus-2026-11.jsonl", [dict(version=1, day="2026-11-20", sessions=2, blocks={}, list=[], through="x",
                                          rule="focus-v1 min=35 switch=3")])
    _jl(ph / "study-review/log.jsonl", [dict(version=1, at="2026-11-20T08:00:00+03:00", kind="morning", recall="well"),
                                        dict(version=1, at="2026-11-20T09:00:00+03:00", kind="morning", recall="some"),
                                        dict(version=1, at="2026-11-20T22:00:00+03:00", kind="evening", studied=True)])
    lv = ["unknown"] * 4 + ["alert"] * 60 + ["drowsy"] * 10
    _w(ph / "work-sessions/2026-11-20-100000.work.json", dict(
        version=1, kind="work_session", start="2026-11-20T10:00:00+03:00", end="2026-11-20T11:00:00+03:00",
        epochs=_epochs("2026-11-20T10:00:00+03:00", lv),
        breaks=[dict(start="2026-11-20T10:40:00+03:00", end="2026-11-20T10:50:00+03:00", source="tapped")],
        hints=[dict(at="2026-11-20T10:30:00+03:00", taken=True), dict(at="2026-11-20T10:35:00+03:00", taken=False)],
        ratings=[dict(at="2026-11-20T10:31:00+03:00", value=4), dict(at="2026-11-20T10:36:00+03:00", value=3)]))
    _w(ph / "work-sessions/2026-11-21-100000.work.json", dict(  # 10 readable minutes: no work numbers
        version=1, kind="work_session", start="2026-11-21T10:00:00+03:00",
        epochs=_epochs("2026-11-21T10:00:00+03:00", ["alert"] * 20)))
    _w(ph / "work-sessions/2026-11-22-100000.work.json", dict(
        version=1, kind="work_session", start="2026-11-22T10:00:00+03:00", wearer=dict(answer="someone else"),
        epochs=_epochs("2026-11-22T10:00:00+03:00", ["alert"] * 100)))
    _w(ph / "meditations/2026-11-20-200000.meditation.json",
       dict(version=1, kind="meditation", start="2026-11-20T20:00:00+03:00", runS=600, settledS=300))
    _w(ph / "alpha-theta/2026-11-20-210000.alphatheta.json",
       dict(version=1, kind="alpha-theta", start="2026-11-20T21:00:00+03:00", runS=300, settledS=100))
    return loc


def days_by_key(loc: Path) -> dict:
    return {d["day"]: d for d in ds.day_events(loc, NOW)}


def test_the_numbers_of_a_full_day(tmp_path):
    d = days_by_key(make_local(tmp_path))["2026-11-20"]
    n = d["numbers"]
    assert n["asleep"] == 490.0 and n["deep"] == 80.0 and n["dream"] == 140.0 and n["light"] == 270.0
    assert n["wakeups"] == 3.0 and n["awake_in_sleep"] == 16.5
    assert n["fall_asleep"] == 14.5  # the button night; the nap's lights off is the recording's start: not counted
    assert n["jaw"] == 2.8  # (20 + 3) bursts over (400 + 90) / 60 hours = 2.816, to 0.1
    assert (n["kss"], n["mood"], n["tension"]) == (6.0, 3.0, 4.0)  # the first of the day that has each one
    assert n["iaf"] == 9.8 and n["alpha"] == 40.0 and n["rise"] == 4.0
    assert (n["reaction"], n["caffeine"], n["alcohol"]) == (312.0, 2.0, 0.0)
    assert n["sharp"] == 3.0  # (4 + 2 + 3) / 3; 7 is off the scale, the unfinished line is not read
    assert n["dayrt"] == 272.5  # the median of the two tests' medians, 325 and 220 (4 taps: no median)
    assert n["recall"] == 2.5 and n["focus"] == 2.0
    assert n["worktime"] == 35.0 and n["workdrowsy"] == 14.29 and n["workfirst"] == 34.0
    assert (n["workhints"], n["workfollowed"], n["workbreaks"], n["worksharp"]) == (2.0, 1.0, 1.0, 3.5)
    assert n["practice"] == 15.0 and n["settled"] == 50.0
    assert d["counts"] == dict(checkins=2, nights=2, practice_sessions=2, sharp_ratings=3, sharp_tests=2,
                               work_sessions=1)
    assert d["quality"] == dict(checkin_clean_share=0.9, night_noisy_share=0.102)  # (40 + 10) / (400 + 90)
    assert d["excluded"] == [] and d["sources"] == ["laptop", "phone"] and d["complete"] is True
    assert set(n) <= set(ds.MEASURE_IDS)


def test_a_test_with_an_even_number_of_taps_rounds_its_middle_half_up(tmp_path):
    # sharp/store.dart `_medianInt`: the middle two's mean, Dart's round() (half away from zero): 325.5 -> 326
    loc = tmp_path / "_local"
    _jl(loc / "phone/sharp-hours/reactions.jsonl", [dict(
        version=1, at="2026-11-20T10:01:00+03:00", length_s=60, false_starts=0, rating_at="2026-11-20T10:00:00+03:00",
        times_ms=[300, 310, 320, 331, 340, 351])])
    assert days_by_key(loc)["2026-11-20"]["numbers"] == dict(dayrt=326.0)


def test_what_is_left_out_and_why(tmp_path):
    days = days_by_key(make_local(tmp_path))
    assert days["2026-11-21"]["numbers"] == dict(kss=7.0, mood=2.0, tension=3.0)  # the ratings stay
    assert days["2026-11-21"]["excluded"] == [
        dict(what="check-in", id="2026-11-21-080000", why="noisy: headband numbers left out", clean_share=0.3),
        dict(what="work", why="under 30 readable minutes", minutes=10.0)]
    assert days["2026-11-22"]["numbers"] == {}
    assert sorted(x["what"] for x in days["2026-11-22"]["excluded"]) == ["check-in", "night", "work session"]
    assert all(x["why"] == "someone else" for x in days["2026-11-22"]["excluded"])
    assert days["2026-11-23"]["excluded"] == [
        dict(what="night", id="2026-11-22", why="noisy", noisy_share=0.6),
        dict(what="night", id="2026-11-23", why="unscored: under 5 minutes recorded")]
    assert days["2026-11-23"]["quality"] == dict(night_noisy_share=0.6)


def test_the_day_still_going_on_is_not_complete(tmp_path):
    loc = make_local(tmp_path)
    days = {d["day"]: d for d in ds.day_events(loc, datetime.fromisoformat("2026-11-21T03:00:00+03:00"))}
    assert days["2026-11-20"]["complete"] is False  # 03:00 on the 21st still belongs to the 20th


def _events(root: Path) -> list[dict]:
    return [json.loads(x) for f in sorted((root / "events").glob("*/*.jsonl")) for x in f.read_text().splitlines()]


def test_daily_export_is_idempotent_and_corrections_replace(tmp_path):
    loc = make_local(tmp_path)
    root = tmp_path / "export"
    counts = ex.export_daily(ex.Folder(root), loc, NOW)
    assert counts["eeg_measure_set"]["new"] == 1
    assert counts["eeg_sleep_night"]["new"] == 2  # the reports with stages: 11-19 and 11-21 (someone else)
    assert counts["eeg_morning_check"]["new"] == 4
    assert counts["eeg_day"]["new"] == 4  # 11-20 .. 11-23
    first = _events(root)
    assert all(e["v"] == 1 and e["id"].startswith("eeg:") for e in first)
    assert len({e["id"] for e in first}) == len(first)
    assert [e["seq"] for e in first] == list(range(1, len(first) + 1))  # one month file
    again = ex.export_daily(ex.Folder(root), loc, NOW)
    assert all(c["new"] == c["replaced"] == 0 for c in again.values())
    assert _events(root) == first
    # a new rating on 11-20: only that day is written again, replacing the old one
    sh = loc / "phone" / "sharp-hours" / "ratings.jsonl"
    sh.write_text(sh.read_text().rsplit("\n", 1)[0] + "\n" + json.dumps(dict(
        version=1, scale="1-5", at="2026-11-20T18:00:00+03:00", sharp=5)) + "\n")
    third = ex.export_daily(ex.Folder(root), loc, NOW)
    assert third["eeg_day"] == dict(new=0, replaced=1, unchanged=3)
    evs = _events(root)
    old = next(e for e in first if e["type"] == "eeg_day" and e["data"]["day"] == "2026-11-20")
    new = evs[-1]
    assert new["data"]["replaces"] == old["id"] and new["data"]["numbers"]["sharp"] == 3.5
    assert new["ts"] == "2026-11-20T04:00:00+03:00"


def test_night_events_from_the_phones_stages_and_the_answer(tmp_path):
    loc = make_local(tmp_path)
    root = tmp_path / "export"
    ex.export_daily(ex.Folder(root), loc, NOW)
    nights = {e["data"]["night_of"]: e["data"] for e in _events(root) if e["type"] == "eeg_sleep_night"}
    a = nights["2026-11-19"]
    assert a["start"] == "2026-11-19T23:30:00+03:00"  # the first scored epoch (awake counts as scored)
    assert a["total_sleep_min"] == 250.0 and a["stage_min"]["N3"] == 40.0 and a["model"].endswith("onnx-f16")
    assert a["confidence"] == 0.8 and a["validated"] is False and "wearer" not in a
    assert nights["2026-11-21"]["wearer"] == "someone else"
    assert "2026-11-20" not in nights  # the laptop nap has neither stages nor a sleep.json beside it


def test_a_laptop_report_with_its_sleep_json_keeps_the_old_id(tmp_path):
    loc = tmp_path / "_local"
    ep = [dict(t="2026-11-18T01:58:25", anysleep=s, yasa=s) for s in ["W", "N2", "N3", "R", "W"]]
    res = dict(source="n.bdf", start="2026-11-18T01:58:25", epoch_s=30, epochs=ep,
               summary=dict(stage_min=dict(W=1.0, N1=0, N2=0.5, N3=0.5, R=0.5), recorded_min=2.5))
    _w(loc / "nights/2026-11-17.sleep.json", res)
    _w(loc / "nights/2026-11-17.report.json", dict(_report(
        "2026-11-17", "2026-11-18T01:58:25+03:00", "2026-11-18T02:01:00+03:00", 1.5, 0.5, 0.5, 0.5, 0, 0.0),
        sleep_json="2026-11-17.sleep.json"))
    root = tmp_path / "export"
    folder = ex.Folder(root)
    ex.add_night(folder, *ex.night_event(res))  # the old single-file export
    assert ex.export_daily(ex.Folder(root), loc, NOW)["eeg_sleep_night"] == dict(new=0, replaced=0, unchanged=1)


def test_the_measure_list_covers_the_phones_trends_and_the_notes():
    ids = ds.MEASURE_IDS
    dart = (ROOT / "app/lib/trends/trends.dart").read_text()
    trends = re.findall(r"MeasureSpec\(\s*id: '(\w+)'", dart)
    assert trends and set(trends) <= set(ids), set(trends) - set(ids)
    order = ["none", "weak", "some", "strong"]
    for m in ds.MEASURES:
        assert m["status"] == "seen together"
        note = ROOT / m["evidence_note"]
        grade = re.search(r"^## Evidence for this headband: (\w+)", note.read_text(), re.M).group(1)
        if m["source"] == "headband":
            assert m["evidence"] in order and order.index(m["evidence"]) <= order.index(grade), m["id"]
        else:
            assert m["evidence"] is None, m["id"]  # not a headband measure
    assert len(set(ids)) == len(ids)
