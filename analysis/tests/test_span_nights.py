"""scripts/night_files.py: nights from sleep spans (Record first, spec test 13; DECISIONS 886 and 888).

Tiny recordings at 1 Hz stand in for the phone's files; spans are written as local clock times. The old rule (no
`recording` in the header) must give what it always gave.
"""
from __future__ import annotations

import csv
import dataclasses
import io
import json
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import data_book as db  # noqa: E402
import night_files as nf  # noqa: E402
import recording as rc  # noqa: E402
import spans  # noqa: E402
from nch_files import volts, write_set  # noqa: E402

NAMES = ("Ch1", "Ch2")


def clock(day: int, hh: int, mm: int = 0) -> datetime:
    return datetime(2026, 11, day, hh, mm)


def make_set(folder: Path, start: datetime, hours: float, recording: str | None, fs: int = 1) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    head = rc.diy_board(NAMES, fs, layout="test")
    head = dataclasses.replace(head, recording=recording)
    return write_set(folder, start, volts(int(hours * 3600 * fs), 2), NAMES, fs=fs, header=head)


def span_line(rid: str, n: int, kind: str, a: datetime, b: datetime | None, source: str = "owner_button") -> str:
    return json.dumps({"v": 1, "span": f"{rid}-{n}", "kind": kind, "source": source, "start": a.isoformat(),
                       "end": None if b is None else b.isoformat(), "made": a.isoformat()})


def put_spans(sdir: Path, rid: str, *lines: str) -> None:
    sdir.mkdir(parents=True, exist_ok=True)
    (sdir / f"{rid}.spans.jsonl").write_text("\n".join(lines) + "\n")


@pytest.fixture
def phone(tmp_path: Path) -> tuple[Path, Path]:
    """<local>/phone/recordings and <local>/phone/spans: the phone's layout."""
    return tmp_path / "phone" / "recordings", tmp_path / "phone" / "spans"


def test_a_header_with_recording_is_never_chained_by_the_old_rule(phone: tuple[Path, Path]) -> None:
    rec, _ = phone
    make_set(rec, clock(21, 22), 1, "2026-11-21-220000")
    make_set(rec, clock(21, 23, 30), 1, "2026-11-21-220000")
    assert nf.nights(nf.recordings(rec)) == []
    assert len(nf.nights(nf.recordings(rec), include_recorded=True)) == 1


def test_nights_come_from_closed_sleep_spans_and_read_only_their_windows(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    rid = "2026-11-21-220000"
    make_set(rec, clock(21, 22), 10, rid)
    put_spans(sdir, rid,
              span_line(rid, 1, "work", clock(21, 22), clock(21, 22, 50)),
              span_line(rid, 2, "sleep", clock(21, 23), clock(22, 3)),
              span_line(rid, 3, "sleep", clock(22, 4), clock(22, 7), "owner_confirmed"),
              span_line(rid, 4, "nap", clock(22, 7, 30), clock(22, 8)),
              span_line(rid, 5, "sleep", clock(22, 8, 10), None))  # open: nothing yet
    got = nf.all_nights(rec)  # AUTO: the sibling spans/ of a folder named `recordings`
    assert [n.name for n in got] == ["2026-11-21"]
    n = got[0]
    assert n.windows == [(clock(21, 23).timestamp(), clock(22, 3).timestamp()),
                         (clock(22, 4).timestamp(), clock(22, 7).timestamp())]
    assert n.span_ids == [f"{rid}-2", f"{rid}-3"] and n.recording_ids == [rid] and n.span_from == "pressed"
    assert [r.stem for r in n.recs] == [rid] and (n.start, n.end) == (n.windows[0][0], n.windows[1][1])
    assert n.recorded_s == 7 * 3600
    assert [(x.name, x.windows, x.span_ids) for x in nf.naps(rec)] == [
        ("2026-11-22-073000", [(clock(22, 7, 30).timestamp(), clock(22, 8).timestamp())], [f"{rid}-4"])]


def test_a_stretch_the_app_resumed_by_itself_is_part_of_the_night_and_an_undone_one_is_not(phone: tuple[Path, Path]) -> None:
    """DECISIONS 1015: the 60-minute rule ended Sleep at 02:00, the headband came back at 03:30 and the app opened a new
    stretch (`auto_resume`): the night's report covers both, the gap stays a gap. One the owner took away with Undo
    ends where it began and gives nothing."""
    rec, sdir = phone
    rid = "2026-11-21-220000"
    make_set(rec, clock(21, 22), 10, rid)
    put_spans(sdir, rid,
              span_line(rid, 1, "sleep", clock(21, 23), clock(22, 2)),
              span_line(rid, 2, "sleep", clock(22, 3, 30), clock(22, 7), "auto_resume"))
    n, = nf.all_nights(rec)
    assert n.windows == [(clock(21, 23).timestamp(), clock(22, 2).timestamp()),
                         (clock(22, 3, 30).timestamp(), clock(22, 7).timestamp())]
    assert n.span_ids == [f"{rid}-1", f"{rid}-2"] and n.span_from == "pressed"
    put_spans(sdir, rid,
              span_line(rid, 1, "sleep", clock(21, 23), clock(22, 2)),
              span_line(rid, 2, "sleep", clock(22, 3, 30), clock(22, 3, 30), "auto_resume"))
    n, = nf.all_nights(rec)
    assert n.span_ids == [f"{rid}-1"]


def test_spans_far_apart_are_two_nights_and_the_source_names_span_from(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    rid = "2026-11-21-220000"
    make_set(rec, clock(21, 5), 30, rid)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(21, 6), clock(21, 7), "auto_start"),
              span_line(rid, 2, "sleep", clock(22, 1), clock(22, 5), "owner_confirmed"))
    got = nf.all_nights(rec)
    assert [(n.name, n.span_from) for n in got] == [("2026-11-20", "auto"), ("2026-11-21", "confirmed")]


def test_an_awake_recording_gives_no_night(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    rid = "2026-11-20-221706"
    make_set(rec, clock(20, 22), 2, rid)
    assert nf.all_nights(rec) == []  # no spans file at all
    put_spans(sdir, rid, span_line(rid, 1, "work", clock(20, 22), clock(20, 23)),
              span_line(rid, 2, "meditate", clock(20, 23), clock(20, 23, 30)))
    assert nf.all_nights(rec) == [] and nf.naps(rec) == []


def test_a_sleep_span_without_its_file_set_gives_nothing(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    make_set(rec, clock(21, 22), 1, "2026-11-21-220000")
    put_spans(sdir, "other", span_line("other", 1, "sleep", clock(21, 23), clock(22, 3)))
    assert nf.all_nights(rec) == []


def test_an_old_folder_gives_what_it_gave_before(tmp_path: Path) -> None:
    rec = tmp_path / "recordings"
    make_set(rec, clock(20, 23), 2, None)
    make_set(rec, clock(21, 1, 30), 2, None)
    make_set(rec, clock(22, 23), 1, None)
    old = nf.nights(nf.recordings(rec))
    got = nf.all_nights(rec)
    assert [(n.name, [r.stem for r in n.recs], n.windows, n.span_from) for n in got] == \
        [(n.name, [r.stem for r in n.recs], None, "migrated") for n in old]
    assert [n.name for n in got] == ["2026-11-20", "2026-11-22"]


def test_no_sleep_removes_a_set_from_the_old_chain(tmp_path: Path) -> None:
    rec, sdir = tmp_path / "phone" / "recordings", tmp_path / "phone" / "spans"
    make_set(rec, clock(20, 22), 2, None)
    make_set(rec, clock(21, 23), 2, None)
    put_spans(sdir, "2026-11-20-220000", json.dumps({"v": 1, "reviewed": "no_sleep", "sets": ["2026-11-20-220000"],
                                                     "hides": ["2026-11-20"]}))
    assert [n.name for n in nf.all_nights(rec)] == ["2026-11-21"]
    assert [n.name for n in nf.all_nights(rec, tmp_path / "nowhere")] == ["2026-11-20", "2026-11-21"]
    put_spans(sdir, "2026-11-20-220000", json.dumps({"v": 1, "reviewed": "sleep"}))
    assert [n.name for n in nf.all_nights(rec)] == ["2026-11-20", "2026-11-21"]


def test_the_spans_folder_is_none_unless_asked_or_beside_recordings(tmp_path: Path) -> None:
    assert nf.spans_folder(tmp_path / "recordings") == tmp_path / "spans"
    assert nf.spans_folder(tmp_path / "recordings-diy") is None
    assert nf.spans_folder(tmp_path / "x", tmp_path / "s") == tmp_path / "s"


def test_an_old_chain_and_a_span_night_of_one_evening_are_one_night(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    make_set(rec, clock(21, 22), 1, None)
    rid = "2026-11-21-233000"
    make_set(rec, clock(21, 23, 30), 6, rid)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(22, 0), clock(22, 5)))
    (n,) = nf.all_nights(rec)
    assert n.name == "2026-11-21" and [r.stem for r in n.recs] == ["2026-11-21-220000", rid]
    assert n.span_ids == [f"{rid}-1"] and n.span_from == "pressed"
    assert n.windows is not None and n.windows[0][0] == clock(21, 22).timestamp()


def test_a_report_with_span_is_stale_only_when_its_spans_change(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    rid = "2026-11-21-220000"
    make_set(rec, clock(21, 22), 10, rid)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(21, 23), clock(22, 3)))
    (n,) = nf.all_nights(rec)
    report = {"version": nf.VERSION, "drift_off": None, "rem_check": None, "walking": None, "inputs": [],
              "span": {"recording": n.recording_ids, "spans": n.span_ids, "windows": [list(w) for w in n.windows or []]}}
    assert not nf.is_stale(n, report)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(21, 23), clock(22, 3)),
              span_line(rid, 2, "sleep", clock(22, 4), clock(22, 6)))
    (n2,) = nf.all_nights(rec)
    assert nf.is_stale(n2, report)
    assert nf.is_stale(n, {k: v for k, v in report.items() if k != "span"})


def test_join_reads_only_the_windows(phone: tuple[Path, Path]) -> None:
    pytest.importorskip("pyedflib")
    import to_bdf
    rec, _ = phone
    f32 = make_set(rec, clock(21, 22), 2, "r")
    a, b = clock(21, 22, 30).timestamp(), clock(21, 23).timestamp()
    start, uv, _ = to_bdf.join([f32], [(a, b)])
    assert start.timestamp() == a and len(uv) == 1800
    whole = to_bdf.join([f32])[1]
    assert np.array_equal(uv, whole[1800:3600])


def make_book_local(root: Path, hidden: bool) -> Path:
    sdir = root / "phone" / "spans"
    rid = "2026-11-21-230000"
    head = dataclasses.replace(rc.brainbit("test"), recording=rid)
    (root / "recordings").mkdir()
    write_set(root / "recordings", clock(21, 23), volts(250 * 60 * 30, 4), rc.BRAINBIT_NAMES, fs=250,
              header=head)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(21, 23, 5), clock(21, 23, 25)))
    rep = {"night_of": "2026-11-20", "total": {"asleep_min": 400.0}, "periods": [],
           "data_start": clock(20, 23).astimezone().isoformat(), "data_end": clock(21, 6).astimezone().isoformat()}
    (root / "phone" / "nights").mkdir(parents=True)
    (root / "phone" / "nights" / "2026-11-20.report.json").write_text(json.dumps(rep))
    if hidden:
        put_spans(sdir, "2026-11-20-221706", json.dumps({"v": 1, "reviewed": "no_sleep", "sets": ["2026-11-20-221706"],
                                                         "hides": ["2026-11-20"]}))
    return root


@pytest.mark.parametrize("hidden", [False, True])
def test_nights_tsv_names_the_spans_and_leaves_out_a_hidden_night(tmp_path: Path, hidden: bool) -> None:
    local = make_book_local(tmp_path, hidden)
    out: list[str] = []
    assert db.main(["--local", str(local), "--out", str(local / "data"), "--quiet"], out=out.append) == 0, out
    rows = list(csv.DictReader(io.StringIO((local / "data" / "nights.tsv").read_text()), delimiter="\t"))
    by = {r["night"]: r for r in rows}
    assert ("2026-11-20" in by) is (not hidden)
    if not hidden:
        assert (by["2026-11-20"]["recording"], by["2026-11-20"]["span_ids"], by["2026-11-20"]["span_from"]) == \
            ("", "", "migrated")
    r = by["2026-11-21"]
    assert (r["recording"], r["span_ids"], r["span_from"]) == ("2026-11-21-230000", "2026-11-21-230000-1", "pressed")


# ---- a stretch taken away, and a short stray one (DECISIONS 1025, 1026): the owner's 2026-11-25 ----------------------

def _removed(line: str, **more: object) -> str:
    return json.dumps({**json.loads(line), "removed": True, **more})


def _the_test_and_tonight(rec: Path) -> tuple[str, str]:
    """Sleep pressed for a 4-minute test at 14:17 (two file sets), and the night that evening in its own recording."""
    test_id, night_id = "2026-11-25-141752", "2026-11-25-233000"
    make_set(rec, datetime(2026, 11, 25, 14, 17, 52), 39 / 3600, test_id)
    make_set(rec, datetime(2026, 11, 25, 14, 19, 30), 119 / 3600, test_id)
    make_set(rec, clock(25, 23, 30), 8, night_id)
    return test_id, night_id


def test_a_short_stray_stretch_hours_before_the_night_is_left_out_of_it(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    test_id, night_id = _the_test_and_tonight(rec)
    stray = span_line(test_id, 1, "sleep", datetime(2026, 11, 25, 14, 17, 52), datetime(2026, 11, 25, 14, 21, 29))
    put_spans(sdir, test_id, stray)
    n, = nf.all_nights(rec)  # before tonight: alone on its evening date it is that night, as before
    assert (n.name, n.span_ids) == ("2026-11-25", [f"{test_id}-1"])
    put_spans(sdir, night_id, span_line(night_id, 1, "sleep", clock(25, 23, 30), clock(26, 7, 30)))
    n, = nf.all_nights(rec)
    assert (n.name, n.span_ids, n.recording_ids) == ("2026-11-25", [f"{night_id}-1"], [night_id])
    assert n.windows == [(clock(25, 23, 30).timestamp(), clock(26, 7, 30).timestamp())]
    assert n.start == clock(25, 23, 30).timestamp() and [r.stem for r in n.recs] == [night_id]


def test_a_short_stretch_hours_after_a_sleep_is_left_out_and_two_long_ones_still_join(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    rid = "2026-11-25-120000"
    make_set(rec, clock(25, 12), 20, rid)
    put_spans(sdir, rid, span_line(rid, 1, "sleep", clock(25, 13), clock(25, 13, 40)),
              span_line(rid, 2, "sleep", clock(25, 20), clock(25, 20, 5)),
              span_line(rid, 3, "sleep", clock(25, 23, 30), clock(26, 7)))
    n, = nf.all_nights(rec)
    assert n.span_ids == [f"{rid}-1", f"{rid}-3"]


def test_a_removed_stretch_is_in_no_night_no_nap_no_truth_row_and_no_spans_row(phone: tuple[Path, Path]) -> None:
    rec, sdir = phone
    test_id, night_id = _the_test_and_tonight(rec)
    stray = span_line(test_id, 1, "sleep", datetime(2026, 11, 25, 14, 17, 52), datetime(2026, 11, 25, 14, 21, 29))
    nap = span_line(test_id, 2, "nap", datetime(2026, 11, 25, 14, 19, 40), datetime(2026, 11, 25, 14, 21))
    put_spans(sdir, test_id, stray, _removed(stray), nap, _removed(nap))
    assert nf.all_nights(rec) == [] and nf.naps(rec) == []
    f = spans.read(sdir / f"{test_id}.spans.jsonl")
    assert f.spans == [] and [s.span for s in f.removed] == [f"{test_id}-1", f"{test_id}-2"]
    local = rec.parent.parent
    assert db.span_rows(local) == []
    # taken back: one more line without `removed`
    put_spans(sdir, test_id, stray, _removed(stray), stray)
    assert [n.span_ids for n in nf.all_nights(rec)] == [[f"{test_id}-1"]]
    assert [r["span_id"] for r in db.span_rows(local)] == [f"{test_id}-1"]


def test_nights_tsv_leaves_out_a_night_whose_only_stretch_was_taken_away(tmp_path: Path) -> None:
    """The phone scored the 20-minute stretch, the laptop copied that report, then the owner said "Not sleep": the
    phone puts its report away, but the laptop's copy stays in phone/nights/. It must not make a night by itself."""
    local = make_book_local(tmp_path, hidden=False)
    rid = "2026-11-21-230000"
    rep = {"night_of": "2026-11-21", "total": {"asleep_min": 15.0}, "periods": [],
           "data_start": clock(21, 23, 5).astimezone().isoformat(), "data_end": clock(21, 23, 25).astimezone().isoformat(),
           "span": {"recording": [rid], "spans": [f"{rid}-1"], "kind": "night", "from": "pressed"}}
    (local / "phone" / "nights" / "2026-11-21.report.json").write_text(json.dumps(rep))

    def nights() -> list[str]:
        out: list[str] = []
        assert db.main(["--local", str(local), "--out", str(local / "data"), "--quiet"], out=out.append) == 0, out
        return [r["night"] for r in csv.DictReader(io.StringIO((local / "data" / "nights.tsv").read_text()), delimiter="\t")]

    assert nights() == ["2026-11-20", "2026-11-21"]
    live = span_line(rid, 1, "sleep", clock(21, 23, 5), clock(21, 23, 25))
    put_spans(local / "phone" / "spans", rid, live, _removed(live))
    assert nights() == ["2026-11-20"]
    put_spans(local / "phone" / "spans", rid, live, _removed(live), live)
    assert nights() == ["2026-11-20", "2026-11-21"]
