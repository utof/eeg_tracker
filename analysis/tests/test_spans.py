"""scripts/spans.py: the laptop's reader of the phone's spans files (Record first, spec test 12) and spans.tsv.

The golden files in tests/contract/spans/ are shared with the phone's Dart reader: both must read each one into its
`*.expected.json` (times as unix seconds, `skipped` = lines skipped).
"""
from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
import data_book as db  # noqa: E402
import spans  # noqa: E402

GOLDEN = ROOT / "tests" / "contract" / "spans"
FILES = sorted(GOLDEN.glob("*.spans.jsonl"))


def line(span: str, kind: str, start: str, end: str | None, source: str = "owner_button", **more: object) -> str:
    d = {"v": 1, "span": span, "kind": kind, "start": start, "end": end, "source": source, "made": start, **more}
    return json.dumps(d)


def put(local: Path, rec_id: str, *lines: str) -> Path:
    p = spans.folder(local) / f"{rec_id}{spans.SUFFIX}"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("\n".join(lines) + "\n")
    return p


def test_there_are_golden_files() -> None:
    assert len(FILES) >= 6


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.name)
def test_a_golden_file_reads_as_its_expected_json(path: Path) -> None:
    expected = json.loads(path.with_name(path.name.replace(".spans.jsonl", ".expected.json")).read_text())
    assert spans.read(path).to_json() == expected


def test_the_last_line_per_span_wins_in_first_seen_order() -> None:
    f = spans.parse("\n".join([
        line("r-1", "work", "2026-11-21T10:00:00+03:00", None),
        line("r-2", "nap", "2026-11-21T12:00:00+03:00", None),
        line("r-1", "work", "2026-11-21T10:00:00+03:00", "2026-11-21T11:00:00+03:00", ended_by="owner"),
    ]))
    assert [s.span for s in f.spans] == ["r-1", "r-2"]
    assert f.spans[0].end_unix is not None and f.spans[0].ended_by == "owner" and f.spans[1].end_unix is None


def test_bad_lines_are_skipped_and_counted_but_blank_ones_are_not() -> None:
    good = line("r-1", "work", "2026-11-21T10:00:00+03:00", None)
    f = spans.parse("\n".join([good, "", "{", "[]", '{"v": true, "span": "x"}',
                               line("r-2", "work", "not a time", None),
                               line("r-3", "work", "2026-11-21T10:00:00+03:00", "later"),
                               json.dumps({"v": 1, "reviewed": "maybe"}),
                               json.dumps({"v": 1, "other": 1})]))
    assert [s.span for s in f.spans] == ["r-1"] and f.skipped == 7


def test_the_last_reviewed_line_counts() -> None:
    no = json.dumps({"v": 1, "reviewed": "no_sleep", "sets": ["a", "b"], "hides": ["2026-11-20"]})
    again = json.dumps({"v": 1, "reviewed": "no_sleep", "sets": ["c"], "hides": []})
    undone = json.dumps({"v": 1, "reviewed": "sleep", "sets": ["z"], "hides": ["z"]})
    f = spans.parse(no + "\n" + again)
    assert (f.reviewed, f.sets, f.hides) == ("no_sleep", ["c"], [])
    f = spans.parse(no + "\n" + undone)
    assert (f.reviewed, f.sets, f.hides) == ("sleep", [], [])


def test_a_missing_file_is_an_empty_one(tmp_path: Path) -> None:
    f = spans.read(tmp_path / "nope.spans.jsonl")
    assert f.spans == [] and f.reviewed is None and f.skipped == 0


def test_the_folder_helpers(tmp_path: Path) -> None:
    put(tmp_path, "2026-11-20-221706", json.dumps({"v": 1, "reviewed": "no_sleep", "sets": ["2026-11-20-221706"],
                                                  "hides": ["2026-11-20"]}))
    put(tmp_path, "2026-11-21-110200", line("2026-11-21-110200-1", "sleep", "2026-11-21T23:10:00+03:00", None),
        line("2026-11-21-110200-2", "work", "2026-11-21T11:10:00+03:00", None),
        line("2026-11-21-110200-3", "nap", "2026-11-21T13:00:00+03:00", None))
    assert spans.folder(tmp_path) == tmp_path / "phone" / "spans"
    assert list(spans.all(tmp_path)) == ["2026-11-20-221706", "2026-11-21-110200"]
    f = spans.for_recording(tmp_path, "2026-11-21-110200")
    assert [s.span[-1] for s in spans.sleep_spans(f)] == ["1", "3"]
    assert spans.for_recording(tmp_path, "missing").spans == []
    assert spans.no_sleep_sets(tmp_path) == {"2026-11-20-221706"}
    assert spans.hidden_nights(tmp_path) == {"2026-11-20"}


def test_the_cli_lists_and_shows(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    put(tmp_path, "r1", line("r1-1", "work", "2026-11-21T10:00:00+03:00", "2026-11-21T11:30:00+03:00"))
    assert spans.main(["--local", str(tmp_path), "list"]) == 0
    out = capsys.readouterr().out
    assert "recording r1: 1 span(s)" in out and "r1-1  work" in out and "(owner_button)" in out
    assert spans.main(["--local", str(tmp_path), "show", "r1"]) == 0
    assert "r1-1  work" in capsys.readouterr().out
    assert spans.main(["--local", str(tmp_path), "show", "nope"]) == 1
    assert "no spans file for recording nope" in capsys.readouterr().err
    assert spans.main(["--local", str(tmp_path / "empty"), "list"]) == 0
    assert "no spans files" in capsys.readouterr().out


def test_spans_tsv_has_one_row_per_span(tmp_path: Path) -> None:
    put(tmp_path, "r1", line("r1-1", "work", "2026-11-21T10:00:00+03:00", None),
        line("r1-1", "work", "2026-11-21T10:00:00+03:00", "2026-11-21T12:00:00+03:00", label="working",
             session="work-sessions/x.work.json", ended_by="owner",
             paused=[["2026-11-21T11:00:00+03:00", "2026-11-21T11:15:00+03:00"]]),
        line("r1-2", "sleep", "2026-11-21T23:00:00+03:00", None, started_recording=True))
    put(tmp_path, "r0", line("r0-1", "juggling", "2026-11-20T09:00:00+03:00", "2026-11-20T09:30:00+03:00",
                             "owner_confirmed", estimate="est:1"))
    out = tmp_path / "data"
    msgs: list[str] = []
    assert db.main(["--local", str(tmp_path), "--out", str(out), "--quiet"], out=msgs.append) == 0, msgs
    text = (out / "spans.tsv").read_text()
    assert text.splitlines()[0].split("\t") == db.SPAN_COLUMNS
    rows = list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    assert [r["span_id"] for r in rows] == ["r0-1", "r1-1", "r1-2"]
    r0, work, sleep = rows
    assert (r0["recording"], r0["kind"], r0["label"], r0["minutes"], r0["source"], r0["estimate"]) == \
        ("r0", "juggling", "", "30", "owner_confirmed", "est:1")
    assert (work["label"], work["minutes"], work["paused_minutes"], work["ended_by"], work["session"]) == \
        ("working", "120", "15", "owner", "work-sessions/x.work.json")
    assert work["start"].startswith("2026-11-21T") and work["start"][-6] in "+-"
    assert (sleep["end"], sleep["minutes"], sleep["started_recording"], sleep["paused_minutes"]) == ("", "", "1", "")
    assert json.loads((out / "book.json").read_text())["rows"]["spans.tsv"] == 3
    assert "spans.tsv" in (out / "README.md").read_text()


def test_the_headers_recording_field_reads_back_and_is_checked() -> None:
    import recording as rc
    h = rc.brainbit("t")
    assert h.recording is None and "recording" not in rc.to_json(h)
    j = {**rc.to_json(h), "recording": "2026-11-21-110200"}
    got = rc.parse(j)
    assert got.recording == "2026-11-21-110200" and rc.to_json(got) == j
    for bad in ("", "x" * 33, 5):
        with pytest.raises(rc.HeaderError):
            rc.parse({**j, "recording": bad})


# ---- activities on a recording (Record first, step 4) ---------------------------------------------------------------

ACTIVITIES = GOLDEN / "activities.spans.jsonl"
DAY = "2026-11-25-110200"


def test_a_session_file_with_a_span_field_finds_its_span_and_the_window_of_the_recording() -> None:
    files = {DAY: spans.read(ACTIVITIES)}
    nap = {"recording": DAY, "span": f"{DAY}-2", "start": "2026-11-25T13:00:00+03:00"}
    s = spans.span_of(nap, files)
    assert s is not None and s.kind == "nap" and spans.rode_on_recording(nap)
    assert spans.window(s) == (s.start_unix, s.end_unix) and s.end_unix - s.start_unix == 35 * 60
    assert spans.session_window(nap, files) == (s.start_unix, s.end_unix)
    # the work session: the same recording, its own span
    assert spans.span_of({"recording": DAY, "span": f"{DAY}-1", "raw": DAY}, files).kind == "work"  # type: ignore[union-attr]


def test_an_old_session_file_has_no_span_and_keeps_its_own_raw_set() -> None:
    files = {DAY: spans.read(ACTIVITIES)}
    old = {"recording": "2026-11-20-101500", "start": "2026-11-20T10:15:00+03:00"}
    assert not spans.rode_on_recording(old) and spans.span_of(old, files) is None
    assert spans.own_raw(old) == "2026-11-20-101500"
    assert spans.own_raw({"raw": "2026-11-20-101500"}) == "2026-11-20-101500"
    assert spans.own_raw({"recording": DAY, "span": f"{DAY}-2"}) is None
    assert spans.own_raw({"recording": DAY, "span": f"{DAY}-1", "raw": DAY}) is None


def test_a_span_that_is_not_found_or_a_recording_that_is_null_gives_none() -> None:
    files = {DAY: spans.read(ACTIVITIES)}
    assert spans.span_of({"recording": DAY, "span": f"{DAY}-99"}, files) is None
    assert spans.span_of({"recording": None, "span": "x-1"}, files) is None
    assert spans.span_of({"recording": "other", "span": f"{DAY}-1"}, files) is None
    assert spans.session_window({"recording": None, "span": "x-1"}, files) is None
    for bad in ({"span": 5}, {"span": ""}, {"span": None}):
        assert not spans.rode_on_recording(bad)


def test_the_window_of_an_open_span_has_no_end() -> None:
    s = spans.parse(line("r-1", "work", "2026-11-21T10:00:00+03:00", None)).spans[0]
    assert spans.window(s) == (s.start_unix, None)


def test_spans_tsv_has_active_minutes_and_all_the_activity_kinds(tmp_path: Path) -> None:
    put(tmp_path, DAY, *ACTIVITIES.read_text().splitlines())
    out = tmp_path / "data"
    assert db.main(["--local", str(tmp_path), "--out", str(out), "--quiet"], out=lambda m: None) == 0
    rows = {r["kind"]: r for r in csv.DictReader(io.StringIO((out / "spans.tsv").read_text()), delimiter="\t")}
    assert list(rows) == ["work", "nap", "meditate", "check_in", "calibration", "alpha_theta", "sound", "dream_catcher"]
    w = rows["work"]
    assert (w["minutes"], w["paused_minutes"], w["active_minutes"], w["started_recording"]) == ("325", "35", "290", "1")
    assert w["session"] == "work-sessions/2026-11-25-110502.work.json" and w["ended_by"] == "owner"
    m = rows["meditate"]
    assert (m["minutes"], m["paused_minutes"], m["active_minutes"], m["ended_by"]) == ("20", "", "20", "activity")
    assert rows["dream_catcher"]["ended_by"] == "recording_stopped"
    assert db.SPAN_COLUMNS.index("active_minutes") == db.SPAN_COLUMNS.index("paused_minutes") + 1


def test_sessions_tsv_joins_a_session_to_its_span(tmp_path: Path) -> None:
    phone = tmp_path / "phone"
    (phone / "naps").mkdir(parents=True)
    (phone / "work-sessions").mkdir(parents=True)
    (phone / "sound-states").mkdir(parents=True)
    put(tmp_path, DAY, *ACTIVITIES.read_text().splitlines())
    (phone / "naps" / "2026-11-25-130000.nap.json").write_text(json.dumps(
        {"version": 1, "start": "2026-11-25T13:00:00+03:00", "endS": 2100, "ended": "wake", "stages": "12",
         "recording": DAY, "span": f"{DAY}-2"}))
    (phone / "work-sessions" / "2026-11-25-110502.work.json").write_text(json.dumps(
        {"version": 1, "kind": "work_session", "app": "eeg_tracker work", "start": "2026-11-25T11:05:00+03:00",
         "end": "2026-11-25T16:30:00+03:00", "ended": "stopped", "raw": DAY, "recording": DAY, "span": f"{DAY}-1"}))
    (phone / "sound-states" / "2026-11-20-100000.sound.json").write_text(json.dumps(
        {"version": 1, "start": "2026-11-20T10:00:00+03:00", "endS": 600, "ended": "time",
         "recording": "2026-11-20-100000"}))
    out = tmp_path / "data"
    assert db.main(["--local", str(tmp_path), "--out", str(out), "--quiet"], out=lambda m: None) == 0
    text = (out / "sessions.tsv").read_text()
    head = text.splitlines()[0].split("\t")
    assert "recording" in head and "span" in head
    rows = {r["kind"]: r for r in csv.DictReader(io.StringIO(text), delimiter="\t")}
    assert (rows["nap_coach"]["recording"], rows["nap_coach"]["span"], rows["nap_coach"]["raw"]) == (DAY, f"{DAY}-2", "")
    assert (rows["work"]["recording"], rows["work"]["span"], rows["work"]["raw"]) == (DAY, f"{DAY}-1", "")
    old = rows["sound"]  # an old file: its recording names its own raw set, and there is no span
    assert (old["recording"], old["span"], old["raw"]) == ("", "", "2026-11-20-100000")
    spans_by_id = {r["span_id"] for r in csv.DictReader(io.StringIO((out / "spans.tsv").read_text()), delimiter="\t")}
    assert {rows["nap_coach"]["span"], rows["work"]["span"]} <= spans_by_id


def test_truth_rows_from_the_activities_golden_file(tmp_path: Path) -> None:
    import truth
    put(tmp_path, DAY, *ACTIVITIES.read_text().splitlines())
    rows, rejected, counts = truth.build(tmp_path)
    assert rejected == [] and counts["spans"] == 6
    got = {r["context"].removeprefix("activity button: "): (r["label"], r["source"], r["recording"]) for r in rows}
    assert got == {"work": ("working", "owner_activity_button", DAY), "nap": ("in_bed", "owner_activity_button", DAY),
                   "meditate": ("meditating", "owner_activity_button", DAY),
                   "alpha_theta": ("neurofeedback", "owner_activity_button", DAY),
                   "sound": ("sound_session", "owner_activity_button", DAY),
                   "dream_catcher": ("resting", "owner_activity_button", DAY)}
    assert "check_in" not in got and "calibration" not in got
