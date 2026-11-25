"""Record first, slice 3 (spec test 14): the stop sheet's tags and the pressed spans as truth rows, the `within`
confidence scored only as "did the detector fire at all", and the golden files `tests/contract/labels/` the app's stop
sheet is tested against (the phone's export and the laptop make the same rows from the same tags).
"""
from __future__ import annotations

import csv
import io
import json
import sys
from datetime import timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import data_book as db  # noqa: E402
import gen_shared_labels as gen  # noqa: E402
import truth  # noqa: E402
from test_truth import SLEEPY, T0, VOCAB, by_id, iso, output, row, truth_of, vd  # noqa: E402

GOLDEN = ROOT / "tests" / "contract" / "labels"
WORDS = 'Felt "good"\tthen tired'
RECORDING = "2026-11-21-110200"


def put_tags(local: Path, tags: list[dict], rid: str = RECORDING) -> None:
    d = local / "phone" / "archive"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{rid}.tags.json").write_text(json.dumps({"version": 1, "id": rid, "tags": tags}), encoding="utf-8")


def tag(label: str, **kw: object) -> dict:
    return {"start": "2026-11-21T11:02:00+03:00", "end": "2026-11-21T19:40:00+03:00", "label": label,
            "made": "2026-11-21T19:41:00+03:00", "truth": True, **kw}


def stop_sheet(label: str, confidence: str, words: str = WORDS, **kw: object) -> dict:
    return tag(label, source="owner_stop_sheet", confidence=confidence, words=words, **kw)


def test_stop_sheet_tags_of_each_confidence_keep_their_words_verbatim(tmp_path: Path) -> None:
    put_tags(tmp_path, [stop_sheet("awake", "certain"), stop_sheet("walking", "likely"),
                        stop_sheet("eating", "within"), stop_sheet("other", "within")])
    rows, rejected, counts = truth.build(tmp_path)
    assert rejected == [] and counts["archive"] == 4
    got = {r["label"]: r for r in rows}
    assert {k: (v["source"], v["confidence"], v["context"]) for k, v in got.items()} == {
        "awake": ("owner_stop_sheet", "certain", "stop sheet"), "walking": ("owner_stop_sheet", "likely", "stop sheet"),
        "eating": ("owner_stop_sheet", "within", "stop sheet"), "other": ("owner_stop_sheet", "within", "stop sheet")}
    assert {r["owner_words"] for r in rows} == {WORDS} and got["other"]["kind"] == "activity"


def test_words_with_a_tab_a_newline_and_quotes_survive_the_table_and_the_checker(tmp_path: Path) -> None:
    words = 'line one\r\nline "two"\tafter a tab\n'
    put_tags(tmp_path, [stop_sheet("other", "within", words)])
    rows, rejected, _ = truth.build(tmp_path)
    assert rejected == [] and rows[0]["owner_words"] == words
    out = tmp_path / "truth-out.tsv"
    with open(out, "w", encoding="utf-8", newline="") as f:  # a truth file in the schema's columns
        f.write(truth.to_tsv(rows, truth.COLUMNS))
    table = tmp_path / "truth.tsv"
    truth.write_table(table, rows)  # the data book's table: no newline changes either
    cells = list(csv.reader(io.StringIO(table.read_bytes().decode("utf-8"), newline=""), delimiter="\t"))
    assert cells[1][cells[0].index("owner_words")] == words
    again = truth.Read()
    truth.read_file(out, "truth-out.tsv", VOCAB, again)  # the checker reads the written table
    assert again.rejected == [] and again.rows[0]["owner_words"] == words


def test_a_tag_without_source_stays_an_app_tag_and_a_bad_confidence_is_refused(tmp_path: Path) -> None:
    put_tags(tmp_path, [tag("walk"), stop_sheet("eating", "maybe")])
    rows, rejected, _ = truth.build(tmp_path)
    assert [(r["source"], r["confidence"], r["owner_words"]) for r in rows] == [("owner_app_tag", "certain", "walk")]
    assert len(rejected) == 1 and "confidence 'maybe'" in rejected[0].why


def test_the_vocabulary_has_the_new_words_once() -> None:
    assert {"night_sleep", "other", "neurofeedback", "taking_medicine", "stressed", "at_home", "away"} <= set(
        VOCAB.labels)
    assert VOCAB.labels["taking_medicine"].kind == "event" and VOCAB.labels["taking_medicine"].unit == "doses"
    assert {"owner_stop_sheet", "owner_activity_button", "owner_utof", "device_utof"} <= set(VOCAB.sources)
    assert "within" in VOCAB.confidences
    text = (ROOT / "scripts" / "truth_vocabulary.tsv").read_text(encoding="utf-8").splitlines()[1:]
    ids = [tuple(line.split("\t")[:2]) for line in text if line]
    assert len(ids) == len(set(ids))


def put_spans(local: Path, rid: str, *lines: dict) -> None:
    d = local / "phone" / "spans"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{rid}.spans.jsonl").write_text("\n".join(json.dumps({"v": 1, **ln}) for ln in lines) + "\n",
                                          encoding="utf-8")


def span(n: int, kind: str, label: str | None, source: str, start: str, end: str | None) -> dict:
    d = {"span": f"{RECORDING}-{n}", "kind": kind, "start": start, "end": end, "source": source,
         "made": end or start}
    if label:
        d["label"] = label
    return d


def test_closed_pressed_spans_with_a_label_become_rows_and_the_rest_do_not(tmp_path: Path) -> None:
    put_spans(tmp_path, RECORDING,
              span(1, "work", "working", "owner_button", "2026-11-21T11:05:00+03:00", "2026-11-21T12:40:00+03:00"),
              span(2, "meditate", "meditating", "owner_confirmed", "2026-11-21T12:45:00+03:00",
                   "2026-11-21T13:00:00+03:00"),
              span(3, "work", "working", "owner_button", "2026-11-21T14:05:00+03:00", None),  # open
              span(4, "sleep", "night_sleep", "auto_start", "2026-11-21T15:00:00+03:00", "2026-11-21T16:00:00+03:00"),
              span(5, "sound", None, "owner_button", "2026-11-21T16:00:00+03:00", "2026-11-21T16:10:00+03:00"))
    rows, rejected, counts = truth.build(tmp_path)
    assert rejected == [] and counts["spans"] == 2
    assert [(r["label_id"], r["label"], r["source"], r["confidence"], r["recording"], r["context"]) for r in rows] == [
        (f"span:{RECORDING}-1", "working", "owner_activity_button", "likely", RECORDING, "activity button: work"),
        (f"span:{RECORDING}-2", "meditating", "owner_activity_button", "likely", RECORDING,
         "activity button: meditate")]
    assert (rows[0]["start"], rows[0]["end"], rows[0]["present"]) == (
        "2026-11-21T11:05:00+03:00", "2026-11-21T12:40:00+03:00", "1")
    again, _, _ = truth.build(tmp_path)
    assert [r["label_id"] for r in again] == [r["label_id"] for r in rows]  # stable ids
    book = db.build(tmp_path, tmp_path / "data", db.datetime.now().astimezone(), say=lambda _s: None)
    assert book["truth_from"]["spans"] == 2 and book["rows"]["truth.tsv"] == 2


def test_a_span_made_by_a_yes_to_an_estimate_is_no_row_of_its_own(tmp_path: Path) -> None:
    """Review finding 4: a plain Yes to "Did you sleep 15:59-17:49?" says it happened, not that the times are right. Its
    span (`owner_confirmed` with the estimate's id) is there for the report; as truth it is the `confirm:` row, which
    knows whether the times were set. A span row beside it would say `times_confirmed` 1 for the detector's times."""
    yes = span(1, "sleep", "in_bed", "owner_confirmed", "2026-11-21T15:59:00+03:00", "2026-11-21T17:49:00+03:00")
    yes["estimate"] = "est:0123456789abcdef"
    put_spans(tmp_path, RECORDING, yes,
              span(2, "sleep", "in_bed", "owner_confirmed", "2026-11-21T23:00:00+03:00", "2026-11-22T07:00:00+03:00"))
    rows, rejected, counts = truth.build(tmp_path)
    assert rejected == []
    # the stop sheet's "Slept 23:00-07:00" (owner_confirmed, no estimate) are the owner's own times: still a row
    assert [(r["label_id"], r["times_confirmed"]) for r in rows] == [(f"span:{RECORDING}-2", "1")]
    assert counts["spans"] == 1


def test_an_end_the_owner_did_not_make_is_not_confirmed_times(tmp_path: Path) -> None:
    """Review finding 9: Work marked at 14:00, the app closed at 15:00, Stop at 23:00. The span's end is the
    recording's, not the owner's: its row says "at some point in this stretch" (`within`, `times_confirmed` 0), not
    "working 14:00-23:00". The same for an end made by the 60-minute rule, a phone restart or the next activity. A
    night's sleep ended by Stop is the owner's own press."""
    def ended(n: int, kind: str, label: str, by: str | None) -> dict:
        d = span(n, kind, label, "owner_button", f"2026-11-21T{10 + n}:00:00+03:00", f"2026-11-21T{10 + n}:30:00+03:00")
        if by:
            d["ended_by"] = by
        return d

    put_spans(tmp_path, RECORDING,
              ended(1, "work", "working", "owner"), ended(2, "meditate", "meditating", "activity"),
              ended(3, "work", "working", "left_open"), ended(4, "work", "working", "recording_stopped"),
              ended(5, "work", "working", "headband_off"), ended(6, "work", "working", "phone_restart"),
              ended(7, "work", "working", "other_activity"), ended(8, "sleep", "in_bed", "recording_stopped"),
              ended(9, "sleep", "in_bed", "headband_off"), ended(10, "work", "working", None),
              # taken away with Undo: no length, no row
              {**span(11, "sleep", "in_bed", "auto_resume", "2026-11-21T22:00:00+03:00", "2026-11-21T22:00:00+03:00"),
               "ended_by": "undone"},
              {**span(12, "work", "working", "owner_button", "2026-11-21T22:10:00+03:00", "2026-11-21T22:10:00+03:00"),
               "ended_by": "headband_off"})
    rows, rejected, _ = truth.build(tmp_path)
    assert rejected == []
    assert [(r["label_id"].rsplit("-", 1)[1], r["confidence"], r["times_confirmed"]) for r in rows] == [
        ("1", "likely", "1"), ("2", "likely", "1"), ("3", "within", "0"), ("4", "within", "0"), ("5", "within", "0"),
        ("6", "within", "0"), ("7", "within", "0"), ("8", "likely", "1"), ("9", "within", "0"), ("10", "likely", "1")]


def test_a_span_with_a_label_the_vocabulary_lacks_is_left_out_with_a_reason(tmp_path: Path) -> None:
    put_spans(tmp_path, RECORDING, span(1, "work", "dozing", "owner_button", "2026-11-21T11:05:00+03:00",
                                        "2026-11-21T12:40:00+03:00"))
    rows, rejected, _ = truth.build(tmp_path)
    assert rows == [] and len(rejected) == 1 and "dozing" in rejected[0].why


def test_a_within_row_is_scored_only_as_fired_at_all() -> None:
    # 20 minutes of output: the detector says yes for one epoch in the middle of the nap span
    o = output("n" * 19 + "y" + "n" * 20)
    nap = row("w1", T0, 20, "nap", confidence="within")
    rows = vd.binary_rows(SLEEPY, truth_of([nap]), [o])
    got = by_id(rows)
    assert got["w1"]["truth_expects"] == vd.FIRED and got["w1"]["agreement_pct"] == 100.0
    assert got["w1"]["false_pos_min"] is None and got["w1"]["false_neg_min"] is None
    quiet = by_id(vd.binary_rows(SLEEPY, truth_of([nap]), [output("n" * 40)]))
    assert quiet["w1"]["agreement_pct"] == 0.0
    # a `within` row that expects no, or says present 0, says nothing about the other minutes: not compared
    asleep_no = row("w3", T0, 20, "awake", confidence="within")
    said_no = row("w4", T0, 20, "asleep", confidence="within", present="0")
    assert vd.binary_rows(SLEEPY, truth_of([asleep_no, said_no]), [output("y" * 40)]) == []
    # a certain row of the same label is still scored minute by minute
    sure = by_id(vd.binary_rows(SLEEPY, truth_of([row("c1", T0, 20, "nap", confidence="likely")]), [o]))
    assert sure["c1"]["truth_expects"] == "mostly" and sure["c1"]["agreement_pct"] == 2.5


def test_within_totals_count_periods_as_hits_not_minutes() -> None:
    o = output("n" * 19 + "y" + "n" * 20 + "n" * 40)
    rows = [row("a", T0, 20, "nap", confidence="within"), row("b", T0 + timedelta(minutes=20), 20, "nap",
                                                            confidence="within")]
    total = [r for r in vd.binary_rows(SLEEPY, truth_of(rows), [o]) if r["scope"] == "all"]
    assert [(r["label"], r["truth_expects"], r["periods"], r["agreement_pct"]) for r in total] == [
        ("nap", vd.FIRED, 2, 50.0)]
    md = vd.summary(total, dict(truth=2, uncovered=[], seen={}, problems=[]), iso(T0), None)
    assert "at least once in 50 % of them" in md and "fired at all" in md


def test_the_golden_stop_sheet_tags_make_exactly_the_golden_rows(tmp_path: Path) -> None:
    tags = (GOLDEN / "stop-sheet.tags.json").read_text(encoding="utf-8")
    d = tmp_path / "phone" / "archive"
    d.mkdir(parents=True)
    j = json.loads(tags)
    (d / f"{j['id']}.tags.json").write_text(tags, encoding="utf-8")
    assert [t["confidence"] for t in j["tags"]] == ["certain", "likely", "within", "within"]
    assert {t["words"] for t in j["tags"]} == {WORDS} and j["tags"][3]["label"] == "other"
    rows, rejected, _ = truth.build(tmp_path)
    assert rejected == []
    golden = (GOLDEN / "stop-sheet.truth.tsv").read_text(encoding="utf-8")
    assert truth.to_tsv(rows, truth.COLUMNS) == golden
    assert (GOLDEN / "stop-sheet.labels.tsv").read_text(encoding="utf-8") == golden  # the shared package's layout
    assert truth.main(["check", str(GOLDEN / "stop-sheet.truth.tsv")], out=lambda _s: None) == 0
    got = truth.Read()
    truth.read_file(GOLDEN / "stop-sheet.truth.tsv", "golden", VOCAB, got)
    assert got.rejected == [] and len(got.rows) == 4
    for r in got.rows:
        assert r["label"] in VOCAB.labels and r["source"] in VOCAB.sources and r["confidence"] in VOCAB.confidences


def test_the_generated_dart_vocabulary_is_the_tsv_now() -> None:
    assert gen.OUT.read_text(encoding="utf-8") == gen.source(VOCAB), "run python3 scripts/gen_shared_labels.py"
    assert gen.main(["--check"]) == 0
