"""scripts/truth.py and scripts/validate_detectors.py: the truth labels' schema, the truth table, and every detector
scored against it (DECISIONS 820-829). Synthetic data only: made-up rows, a made-up report, a made-up book.
"""
from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import data_book as db  # noqa: E402
import truth  # noqa: E402

_spec = importlib.util.spec_from_file_location("validate_detectors_book", ROOT / "scripts" / "validate_detectors.py")
assert _spec is not None and _spec.loader is not None
vd = importlib.util.module_from_spec(_spec)  # by path: analysis/validate_detectors.py has the same module name
sys.modules["validate_detectors_book"] = vd
_spec.loader.exec_module(vd)

MSK = timezone(timedelta(hours=3))
T0 = datetime(2026, 11, 16, 23, 0, 0, tzinfo=MSK)
VOCAB = truth.read_vocabulary()
SEED = 20261120


def iso(t: datetime) -> str:
    return t.isoformat(timespec="seconds")


def row(label_id: str = "tl-1", start: datetime = T0, minutes: float = 10, label: str = "awake", **kw: str) -> dict:
    lab = VOCAB.labels.get(label)
    r = dict(label_id=label_id, start=iso(start), end=iso(start + timedelta(minutes=minutes)), recording="",
             kind=lab.kind if lab else "state", label=label, value="", unit="", source="owner_chat",
             confidence="certain", created=iso(start + timedelta(hours=1)), supersedes="", owner_words="", context="")
    r.update(kw)
    return r


def write_hand(local: Path, rows: list[dict], columns: list[str] = truth.COLUMNS) -> Path:
    p = local / truth.HAND_FILE
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(truth.to_tsv(rows, columns), encoding="utf-8")
    return p


# ---- the vocabulary -------------------------------------------------------------------------------------------------

OWNER_SEED = {"asleep": "state", "awake": "state", "nap": "state", "in_bed": "state", "walking": "activity",
              "running": "activity", "stairs": "activity", "cycling": "activity", "vehicle": "activity",
              "sitting": "posture", "standing": "posture", "lying": "posture", "eating": "activity",
              "drinking_coffee": "event", "drinking_alcohol": "event", "talking": "activity", "meeting": "activity",
              "focused_work": "activity", "exercise": "activity", "meditating": "activity", "headache": "state",
              "ill": "state", "sound_session": "activity", "eyes_closed": "state", "headband_off": "device",
              "headband_adjusted": "device"}


def test_the_vocabulary_holds_the_owners_labels_and_every_detector_names_known_ones() -> None:
    assert {k: VOCAB.labels[k].kind for k in OWNER_SEED} == OWNER_SEED
    assert set(VOCAB.kinds) >= {"state", "activity", "event", "rating", "measurement"}
    assert set(VOCAB.sources) >= {"owner_chat", "owner_app_tag", "owner_checkin", "owner_mark_button", "device_watch",
                                  "device_phone", "observer"}
    assert list(VOCAB.confidences) == ["certain", "likely"]
    assert VOCAB.labels["pulse"].unit == "bpm" and VOCAB.labels["pulse"].kind == "measurement"
    for d in vd.DETECTORS:
        assert (d.yes | d.no | d.mostly) <= set(VOCAB.labels), d.name
        assert not (d.yes & d.no) and not (d.yes & d.mostly) and not (d.no & d.mostly), d.name
    # pandas reads the vocabulary file too
    v = pd.read_csv(truth.VOCABULARY, sep="\t", keep_default_na=False)
    assert len(v[v.field == "label"]) == len(VOCAB.labels)
    # a free word finds its label: the Archive's preset words, any case and spacing
    for word, lab in (("walk", "walking"), ("Sleep", "asleep"), ("meeting", "meeting"), ("meditation", "meditating"),
                      ("rest", "resting"), ("work", "working"), ("Eyes closed", "eyes_closed"), ("heart rate", "pulse")):
        assert (VOCAB.match(word) or truth.Label("?", "", None, (), "")).id == lab, word
    assert VOCAB.match("piano") is None


def test_the_archive_rules_are_the_phones() -> None:
    """The talking and moving rules are the Archive's (app/lib/archive/seen.dart ActivityRule), not a second copy."""
    dart = (ROOT / "app" / "lib" / "archive" / "seen.dart").read_text()
    assert re.search(rf"talkingJaw = {vd.TALKING_JAW};", dart) and re.search(rf"movingS = {vd.MOVING_S};", dart)


# ---- the schema -----------------------------------------------------------------------------------------------------

@pytest.mark.parametrize("change, why", [
    (dict(label="dozing"), "not in the vocabulary"),
    (dict(kind="activity"), "is a 'state'"),
    (dict(start="2026-11-16T23:00:00"), "UTC offset"),
    (dict(start="yesterday evening"), "UTC offset"),
    (dict(end="2026-11-16T22:00:00+03:00"), "end is before start"),
    (dict(created=""), "created"),
    (dict(source="my_phone"), "source 'my_phone'"),
    (dict(confidence="sure"), "confidence 'sure'"),
    (dict(label_id="has space"), "not an id"),
    (dict(label_id=""), "not an id"),
    (dict(value="3"), "takes no value"),
    (dict(unit="bpm"), "a unit without a value"),
    (dict(recording="../x"), "not a recording id"),
    (dict(supersedes="tl-1"), "supersede itself"),
    (dict(label="withdrawn", kind="correction"), "needs the row it takes back"),
    (dict(label="kss", kind="rating"), "needs a value in 1-9"),
    (dict(label="kss", kind="rating", value="10", unit="1-9"), "not a whole number on the 1-9 scale"),
    (dict(label="kss", kind="rating", value="3.5", unit="1-9"), "not a whole number"),
    (dict(label="pulse", kind="measurement", value="61", unit="bpm/min"), "measured in 'bpm'"),
    (dict(label="pulse", kind="measurement", value="fast", unit="bpm"), "not a number"),
    (dict(label="pulse", kind="measurement", value="nan", unit="bpm"), "not a number"),
    (dict(label="pulse", kind="measurement", value="-4", unit="bpm"), "negative"),
])
def test_a_bad_row_is_rejected_with_its_reason(tmp_path: Path, change: dict, why: str) -> None:
    write_hand(tmp_path, [row("tl-0", label="walking"), {**row(), **change}])
    rows, rejected, _ = truth.build(tmp_path)
    assert [r["label_id"] for r in rows] == ["tl-0"]
    assert len(rejected) == 1 and why in rejected[0].why and rejected[0].line == 3
    assert truth.main(["--local", str(tmp_path), "check"], out=lambda _s: None) == 1


def test_good_rows_pass_and_numbers_keep_their_units(tmp_path: Path) -> None:
    good = [row("a"), row("b", label="kss", value="7", unit="1-9"), row("c", label="pulse", value="61.5", unit="bpm"),
            row("d", label="drinking_coffee", minutes=0, value="2", unit="cups"), row("e", label="headband_adjusted",
                                                                                     minutes=0, source="observer")]
    write_hand(tmp_path, good)
    rows, rejected, counts = truth.build(tmp_path)
    assert rejected == [] and counts == {"hand": 5, "files": 0, "archive": 0}
    assert {r["label_id"]: r["kind"] for r in rows} == {"a": "state", "b": "rating", "c": "measurement", "d": "event",
                                                         "e": "device"}
    assert truth.main(["--local", str(tmp_path), "check"], out=lambda _s: None) == 0


def test_a_file_in_another_schema_or_with_a_short_row_is_named(tmp_path: Path) -> None:
    old = [c for c in truth.COLUMNS if c not in truth.FREE_TEXT] + ["note"]
    write_hand(tmp_path, [dict(row(), note="x")], old)
    rows, rejected, _ = truth.build(tmp_path)
    assert rows == [] and "missing ['context', 'owner_words'], unknown ['note']" in rejected[0].why
    p = write_hand(tmp_path, [row("a")])
    p.write_text(p.read_text() + "b\t" + iso(T0) + "\n")
    rows, rejected, _ = truth.build(tmp_path)
    assert [r["label_id"] for r in rows] == ["a"] and "2 cells" in rejected[0].why


def test_a_file_saved_by_a_spreadsheet_reads_the_same(tmp_path: Path) -> None:
    p = write_hand(tmp_path, [row("a"), row("b", T0 + timedelta(minutes=20), context='said "maybe"')])
    p.write_bytes(b"\xef\xbb\xbf" + p.read_bytes().replace(b"\n", b"\r\n"))  # a byte-order mark, CR LF line ends
    rows, rejected, _ = truth.build(tmp_path)
    assert rejected == [] and [r["label_id"] for r in rows] == ["a", "b"] and rows[1]["context"] == 'said "maybe"'


def test_free_text_with_tabs_newlines_and_quotes_survives_pandas_and_the_reader(tmp_path: Path) -> None:
    words = 'I said "no sleep at all"\tthen\nwent out; it\'s fine'
    ctx = "two lines:\nphone in front right pocket\t(owner)"
    write_hand(tmp_path, [row("a", owner_words=words, context=ctx), row("b", T0 + timedelta(minutes=20))])
    rows, rejected, _ = truth.build(tmp_path)
    assert rejected == [] and rows[0]["owner_words"] == words and rows[0]["context"] == ctx
    out = tmp_path / "truth.tsv"
    truth.write_table(out, rows)
    df = pd.read_csv(out, sep="\t", keep_default_na=False, dtype=str)
    assert len(df) == 2 and df.loc[0, "owner_words"] == words and df.loc[0, "context"] == ctx
    assert list(df.columns) == truth.TABLE_COLUMNS


# ---- corrections ----------------------------------------------------------------------------------------------------

def test_corrections_supersede_and_nothing_is_overwritten(tmp_path: Path) -> None:
    rows_in = [
        row("a", label="walking"),
        row("b", label="walking", minutes=12, supersedes="a", created=iso(T0 + timedelta(hours=2))),
        row("c", label="walking", minutes=14, supersedes="b", created=iso(T0 + timedelta(hours=3))),
        row("d", T0 + timedelta(hours=1), label="eating"),
        row("e", T0 + timedelta(hours=1), label="withdrawn", supersedes="d"),
        row("f", label="dozing"),  # rejected...
        row("g", label="asleep", supersedes="f"),  # ... and corrected: a correction may name a rejected row
        row("h", label="awake", supersedes="nobody"),
        row("a", label="awake"),  # the id again: the first row keeps it
    ]
    write_hand(tmp_path, rows_in)
    rows, rejected, _ = truth.build(tmp_path)
    got = {r["label_id"]: (r["active"], r["superseded_by"]) for r in rows}
    assert got == {"a": ("0", "b"), "b": ("0", "c"), "c": ("1", ""), "d": ("0", "e"), "e": ("1", ""),
                   "g": ("1", "")}
    whys = {r.label_id: r.why for r in rejected}
    assert "not in the vocabulary" in whys["f"] and "unknown id" in whys["h"] and "already used" in whys["a"]
    # the hand file is never written by the build
    before = (tmp_path / truth.HAND_FILE).read_bytes()
    truth.write_table(tmp_path / "truth.tsv", rows)
    assert (tmp_path / truth.HAND_FILE).read_bytes() == before


def test_a_loop_of_corrections_is_rejected(tmp_path: Path) -> None:
    write_hand(tmp_path, [row("a", supersedes="b"), row("b", supersedes="a"), row("c")])
    rows, rejected, _ = truth.build(tmp_path)
    assert [r["label_id"] for r in rows] == ["c"] and {r.label_id for r in rejected} == {"a", "b"}


# ---- the sources ----------------------------------------------------------------------------------------------------

def test_archive_tags_marked_truth_and_watch_rows_join_the_hand_file(tmp_path: Path) -> None:
    write_hand(tmp_path, [row("tl-1")])
    tags = [dict(start=iso(T0), end=iso(T0 + timedelta(minutes=30)), label="walk", made=iso(T0 + timedelta(hours=1)),
                 truth=True),
            dict(start=iso(T0), end=iso(T0 + timedelta(minutes=5)), label="rest", made=iso(T0)),  # not marked
            dict(start=iso(T0), end=iso(T0 + timedelta(minutes=5)), label="piano", made=iso(T0), truth=True)]
    arch = tmp_path / "phone" / "archive"
    arch.mkdir(parents=True)
    (arch / "2026-11-16-230000.tags.json").write_text(json.dumps(dict(version=1, id="2026-11-16-230000", tags=tags)))
    watch = tmp_path / "truth" / "watch-2026-11-16.tsv"
    watch.parent.mkdir()
    watch.write_text(truth.to_tsv([row(f"watch:{i}", T0 + timedelta(minutes=i), minutes=0, label="pulse",
                                       value=str(60 + i), unit="bpm", source="device_watch") for i in range(3)],
                                  truth.COLUMNS))
    rows, rejected, counts = truth.build(tmp_path)
    assert counts == {"hand": 1, "files": 3, "archive": 1}
    tag = next(r for r in rows if r["source"] == "owner_app_tag")
    assert tag["label"] == "walking" and tag["kind"] == "activity" and tag["owner_words"] == "walk"
    assert tag["recording"] == "2026-11-16-230000" and tag["origin"] == "phone/archive/2026-11-16-230000.tags.json"
    assert tag["label_id"] == db._lid("archive", tags[0])  # noqa: SLF001 - the same id as its labels.tsv row
    assert [r.why for r in rejected] == [rejected[0].why] and "'piano'" in rejected[0].why


def test_the_data_book_writes_the_truth_table(tmp_path: Path) -> None:
    local = tmp_path / "local"
    write_hand(local, [row("tl-1", label="awake"), row("tl-2", label="dozing")])
    book = db.build(local, local / "data", datetime.now().astimezone(), say=lambda _s: None)
    assert book["rows"]["truth.tsv"] == 1 and book["truth_from"] == {"hand": 1, "files": 0, "archive": 0}
    assert len(book["truth_rejected"]) == 1 and "dozing" in book["truth_rejected"][0]
    df = pd.read_csv(local / "data" / "truth.tsv", sep="\t", parse_dates=["start", "end", "created"])
    assert str(df["start"].dtype).startswith("datetime64") and df.loc[0, "label"] == "awake"
    assert "truth.tsv" in (local / "data" / "README.md").read_text()


# ---- many rows ------------------------------------------------------------------------------------------------------

LABELS_100K = ["awake", "asleep", "walking", "eating", "talking", "sitting", "pulse"]


def many_rows(n: int) -> list[dict]:
    rng = np.random.default_rng(SEED)
    out = []
    for i in range(n):
        lab = LABELS_100K[int(rng.integers(len(LABELS_100K)))]
        start = T0 + timedelta(seconds=37 * i)
        extra = dict(value=str(int(rng.integers(50, 120))), unit="bpm", source="device_watch") if lab == "pulse" else {}
        out.append(row(f"tl-{i:06d}", start, 0 if lab == "pulse" else float(rng.integers(1, 60)), lab,
                       context=f"row {i}", **extra))
    return out


def test_100k_rows_load_in_pandas_in_seconds_and_build_and_validate_quickly(tmp_path: Path) -> None:
    write_hand(tmp_path, many_rows(100_000))
    t0 = time.perf_counter()
    rows, rejected, _ = truth.build(tmp_path)
    build_s = time.perf_counter() - t0
    assert len(rows) == 100_000 and rejected == []
    out = tmp_path / "data"
    out.mkdir()
    truth.write_table(out / "truth.tsv", rows)
    t0 = time.perf_counter()
    df = pd.read_csv(out / "truth.tsv", sep="\t", parse_dates=["start", "end", "created"])
    load_s = time.perf_counter() - t0
    assert len(df) == 100_000 and str(df["start"].dtype).startswith("datetime64")
    starts = T0.timestamp() + 30 * np.arange(200_000)  # 70 days of 30 s epochs
    says = np.random.default_rng(SEED).integers(-1, 2, len(starts)).astype(np.int8)
    det = vd.Detector("fake", "asleep", frozenset({"asleep"}), frozenset({"awake", "walking"}), frozenset(),
                      read=lambda _b: [vd.Output("fake", "fake-v1", starts, says)])
    t0 = time.perf_counter()
    vrows, _ = vd.validate(tmp_path, out, detectors=[det], measurers=[])
    validate_s = time.perf_counter() - t0
    assert len([r for r in vrows if r["scope"] == "label"]) == sum(r["label"] in LABELS_100K[:3] for r in rows)
    assert load_s < 5 and build_s < 20 and validate_s < 30, (load_s, build_s, validate_s)


# ---- the validation math --------------------------------------------------------------------------------------------

def output(says: str, start: datetime = T0, source: str = "s1", version: str = "v1") -> object:
    """Epochs from `start`, one character each: y yes, n no, - not read."""
    m = {"y": vd.YES, "n": vd.NO, "-": vd.UNREAD}
    return vd.Output(source, version, start.timestamp() + 30 * np.arange(len(says)),
                     np.array([m[c] for c in says], np.int8))


def truth_of(rows: list[dict]) -> object:
    return vd.Truth([dict(r, active="1") for r in rows], np.array([truth.parse_time(r["start"]).timestamp()
                                                                    for r in rows]),
                    np.array([truth.parse_time(r["end"]).timestamp() for r in rows]))


SLEEPY = vd.Detector("sleepy", "asleep", frozenset({"asleep"}), frozenset({"awake", "walking"}), frozenset({"nap"}),
                     read=lambda _b: [])


def by_id(rows: list[dict]) -> dict:
    return {r.get("label_id") or ("all", r["label"]): r for r in rows}


def test_agreement_and_false_minutes_by_hand() -> None:
    # 20 epochs from T0: 10 minutes. Awake 0-5 min (epochs 0-9), asleep 5-10 min (epochs 10-19)
    o = output("nnnyy-nnnn" + "yyyynn-yyy")
    tr = truth_of([row("w", T0, 5, "awake"), row("s", T0 + timedelta(minutes=5), 5, "asleep"),
                   row("n", T0, 10, "nap"), row("x", T0, 10, "eating")])  # eating: not one of sleepy's labels
    got = by_id(vd.binary_rows(SLEEPY, tr, [o]))
    w, s, n = got["w"], got["s"], got["n"]
    assert (w["epochs"], w["yes_min"], w["no_min"], w["not_read_min"]) == (9, 1.0, 3.5, 0.5)
    assert (w["false_pos_min"], w["false_neg_min"], w["agreement_pct"]) == (1.0, 0.0, 77.8)  # 7 of 9 right
    assert (s["epochs"], s["false_pos_min"], s["false_neg_min"], s["agreement_pct"]) == (9, 0.0, 1.0, 77.8)
    assert n["truth_expects"] == "mostly" and n["agreement_pct"] == 50.0 and n["false_pos_min"] is None
    assert "x" not in got and w["truth_min"] == 5.0 and w["sources"] == "s1" and w["detector_version"] == "v1"
    assert got[("all", "awake")]["periods"] == 1 and got[("all", "awake")]["false_pos_min"] == 1.0


def test_an_epoch_counts_where_its_middle_lies_and_a_moment_takes_its_epoch() -> None:
    o = output("yyynnn")  # epochs start at 0 30 60 90 120 150 s
    tr = truth_of([row("edge", T0 + timedelta(seconds=14), 1.0, "awake"),  # 14-74 s: middles 15 45 -> epochs 0 1
                   row("late", T0 + timedelta(seconds=16), 1.0, "awake"),  # 16-76 s: middles 45 75 -> epochs 1 2
                   row("moment", T0 + timedelta(seconds=95), 0, "awake"),  # in epoch 3
                   row("after", T0 + timedelta(minutes=10), 1, "awake")])  # after the output: no row
    got = by_id(vd.binary_rows(SLEEPY, tr, [o]))
    assert got["edge"]["false_pos_min"] == 1.0 and got["late"]["false_pos_min"] == 1.0
    assert (got["moment"]["epochs"], got["moment"]["agreement_pct"]) == (1, 100.0)
    assert "after" not in got
    assert got[("all", "awake")]["periods"] == 3 and got[("all", "awake")]["epochs"] == 5


def test_two_sources_of_one_version_never_count_a_minute_twice_and_versions_stay_apart() -> None:
    first = output("yyyy", source="nap report")
    again = output("nnnnnn", T0 + timedelta(minutes=1), source="evening report")  # 1-4 min: 2-3 overlap the first
    other = output("nnnn", source="phone report", version="v2")
    got = vd.binary_rows(SLEEPY, truth_of([row("w", T0, 4, "awake")]), [first, again, other])
    v1 = next(r for r in got if r["detector_version"] == "v1" and r["scope"] == "label")
    v2 = next(r for r in got if r["detector_version"] == "v2" and r["scope"] == "label")
    assert v1["epochs"] == 8 and v1["false_pos_min"] == 2.0 and v1["sources"] == "evening report nap report"
    assert v2["epochs"] == 4 and v2["false_pos_min"] == 0.0


def test_spans_become_epochs_for_detectors_that_give_stretches() -> None:
    a = T0.timestamp()
    o = vd.from_spans("walk.json", "walk-v2", a, a + 300, [(a + 60, a + 130)], unread=[(a + 240, a + 300)])
    assert "".join({1: "y", 0: "n", -1: "-"}[int(v)] for v in o.says) == "nnyynnnn--"


def test_a_measurer_is_scored_by_its_error_in_its_unit() -> None:
    a = T0.timestamp()
    est = vd.Values("pulse.json", "pulse-v1", a + np.arange(0, 600, 5.0), np.full(120, 64.0))
    m = vd.Measurer("pulse", "pulse", "bpm", 30.0, read=lambda _b: [est])
    tr = truth_of([row("p1", T0 + timedelta(minutes=1), 0, "pulse", value="60", unit="bpm"),
                   row("p2", T0 + timedelta(minutes=2), 1, "pulse", value="66", unit="bpm"),
                   row("p3", T0 + timedelta(hours=2), 0, "pulse", value="70", unit="bpm")])  # nothing near it
    got = by_id(vd.measured_rows(m, tr, [est]))
    assert (got["p1"]["mean_error"], got["p1"]["values"]) == (4.0, 13)  # 30 s either side, every 5 s
    assert got["p2"]["mean_error"] == -2.0 and "p3" not in got
    assert (got[("all", "pulse")]["mean_abs_error"], got[("all", "pulse")]["mean_error"]) == (3.0, 1.0)


# ---- the whole run on a made-up book --------------------------------------------------------------------------------

def made_up_book(local: Path) -> Path:
    """A laptop report of a 10-minute night (stages, drift-off, a sleep.json with YASA), its 30 s rows in the book, a
    phone work session, and the truth: awake for the first 5 minutes, talking for the first 2, asleep after."""
    nights = local / "nights"
    nights.mkdir(parents=True)
    stages = "WWWW1WWWWW" + "WWWW222333"  # 20 epochs
    yasa = ["W", "N1", "N1", "W", "W", "W", "W", "W", "W", "W"] + ["N2"] * 10
    rep = dict(version=2, night_of="2026-11-16", data_start=iso(T0), data_end=iso(T0 + timedelta(minutes=10)),
               scored=True, periods=[], total=dict(asleep_min=5.5, recorded_min=10.0), model="anysleep-test@1",
               cross_check=dict(model="yasa-test O1-T3"), stages=stages, sleep_json="2026-11-16.sleep.json",
               drift_off=dict(version=1, source="button", lights_off_s=60, epochs="b" + "a" * 10 + "s" * 7))
    (nights / "2026-11-16.report.json").write_text(json.dumps(rep))
    (nights / "2026-11-16.sleep.json").write_text(json.dumps(dict(
        start=T0.replace(tzinfo=None).isoformat(), epoch_s=30,
        epochs=[dict(t=iso(T0 + timedelta(seconds=30 * i)), anysleep="W", yasa=y) for i, y in enumerate(yasa)])))
    work = local / "phone" / "work-sessions"
    work.mkdir(parents=True)
    start = T0 - timedelta(hours=2)
    (work / "a.work.json").write_text(json.dumps(dict(version=1, app="eeg_tracker work", start=iso(start), epochs=[
        dict(at=iso(start + timedelta(seconds=30 * i)), s=30 * i, eyes_closed=i < 2, alpha=None if i == 3 else 5.0)
        for i in range(6)])))
    out = local / "data"
    out.mkdir()
    head = "\t".join(["recording", "kind", "epoch", "start", "quality", "jaw", "movement_s", "signal_version"])
    body = "".join(f"2026-11-16\tnight\t{i}\t{iso(T0 + timedelta(seconds=30 * i))}\t{'m' if i == 19 else 'g'}\t"
                   f"{3 if i < 3 else 0}\t{5 if i == 1 else 0}\tepoch-signal-v1\n" for i in range(20))
    (out / "epochs.tsv.gz").write_bytes(gzip.compress((head + "\n" + body).encode()))
    rows = [row("tl-awake", T0, 5, "awake"), row("tl-talk", T0, 2, "talking"),
            row("tl-sleep", T0 + timedelta(minutes=5), 5, "asleep"),
            row("tl-eyes", start, 3, "eyes_closed"), row("tl-off", T0 + timedelta(seconds=570), 0.5, "headband_off"),
            row("tl-old", T0, 10, "walking"), row("tl-new", T0, 10, "withdrawn", supersedes="tl-old")]
    write_hand(local, rows)
    trows, _, _ = truth.build(local)
    truth.write_table(out / "truth.tsv", trows)
    return out


def test_every_detector_on_a_made_up_book(tmp_path: Path) -> None:
    out = made_up_book(tmp_path)
    lines: list[str] = []
    assert vd.main(["--local", str(tmp_path), "--book", str(out)], say=lines.append) == 0
    df = pd.read_csv(out / "validation.tsv", sep="\t", keep_default_na=False, dtype=str)
    assert list(df.columns) == vd.COLUMNS
    one = df[df.scope == "label"].set_index(["detector", "label_id"])
    assert one.loc[("anysleep", "tl-awake"), "false_pos_min"] == "0.5"  # the N1 epoch at 2 min
    assert one.loc[("anysleep", "tl-awake"), "detector_version"] == "anysleep-test@1"
    assert one.loc[("anysleep", "tl-sleep"), "false_neg_min"] == "2"  # its first 4 epochs scored W
    assert one.loc[("yasa", "tl-awake"), "false_pos_min"] == "1"  # two N1 epochs
    assert one.loc[("yasa", "tl-awake"), "sources"] == "nights/2026-11-16.sleep.json"
    assert one.loc[("drift_off", "tl-awake"), "epochs"] == "7"  # from lights off at 1 min; `b` not read
    assert one.loc[("drift_off", "tl-sleep"), "false_neg_min"] == "1.5"  # `a` from 5 to 6.5 min
    assert one.loc[("talking", "tl-talk"), "agreement_pct"] == "75"  # 3 of the 4 epochs with jaw bursts
    assert one.loc[("eyes_closed", "tl-eyes"), "false_neg_min"] == "1.5"  # open in 3 of 5 read epochs, 1 not read
    assert one.loc[("eyes_closed", "tl-eyes"), "not_read_min"] == "0.5"
    assert one.loc[("no_signal", "tl-off"), "agreement_pct"] == "100"
    assert "tl-old" not in set(df.label_id) and "tl-new" not in set(df.label_id)  # withdrawn: not compared
    md = (out / "validation.md").read_text()
    assert "anysleep (anysleep-test@1): during awake" in md and "## Totals" in md
    assert any("validation" in x and "rows" in x for x in lines)


def test_walking_pulse_and_the_veto_version_in_the_table(tmp_path: Path) -> None:
    """A walk file's stretches against a walking label (its stop counts as missed) and against sleep (no walking);
    the pulse file's readings wait for a reference, and the table says so; a report made with the walking veto is
    its own detector version."""
    out = made_up_book(tmp_path)
    walk = tmp_path / "walking"
    walk.mkdir()
    a = T0 - timedelta(minutes=30)

    def stretch(kind: str, m0: float, m1: float) -> dict:
        return dict(kind=kind, start=iso(a + timedelta(minutes=m0)), end=iso(a + timedelta(minutes=m1)))
    (walk / "2026-11-16-223000.walk.json").write_text(json.dumps(dict(
        format="eeg-tracker-walking", version=1, detector="walk-v2", recording="2026-11-16-223000", start=iso(a),
        end=iso(T0 + timedelta(minutes=10)),
        walks=[dict(stretches=[stretch("walking", 2, 6), stretch("stopped", 6, 8), stretch("running", 8, 10)])])))
    (walk / "broken.walk.json").write_text(json.dumps(dict(format="eeg-tracker-walking", why="no samples")))
    pulse = tmp_path / "phone" / "pulse"
    pulse.mkdir(parents=True)
    (pulse / "2026-11-16-223000.pulse.json").write_text(json.dumps(dict(
        format="eeg-tracker-pulse", version=1, detector="pulse-v2", start_ms=int(a.timestamp() * 1000), epoch_s=30,
        bpm=[None, 61.0, 62.5, None, 60.0])))
    rep_path = tmp_path / "nights" / "2026-11-16.report.json"
    rep = json.loads(rep_path.read_text())
    rep["walking"] = dict(detector="walk-v2", changed_min=0.0)
    rep_path.write_text(json.dumps(rep))
    rows = [row("tl-walk", a + timedelta(minutes=2), 8, "walking"),
            row("tl-sleep", T0 + timedelta(minutes=5), 5, "asleep"), row("tl-awake", T0, 5, "awake")]
    write_hand(tmp_path, rows)
    trows, _, _ = truth.build(tmp_path)
    truth.write_table(out / "truth.tsv", trows)
    lines: list[str] = []
    assert vd.main(["--local", str(tmp_path), "--book", str(out)], say=lines.append) == 0
    df = pd.read_csv(out / "validation.tsv", sep="\t", keep_default_na=False, dtype=str)
    one = df[df.scope == "label"].set_index(["detector", "label_id"])
    w = one.loc[("walking", "tl-walk")]
    assert (w["detector_version"], w["epochs"], w["yes_min"], w["false_neg_min"], w["agreement_pct"]) == (
        "walk-v2", "16", "6", "2", "75")  # the 2-minute stop is the miss
    assert one.loc[("walking", "tl-sleep"), "false_pos_min"] == "0"
    assert one.loc[("walking", "tl-walk"), "sources"] == "walking/2026-11-16-223000.walk.json"
    assert one.loc[("anysleep", "tl-awake"), "detector_version"] == "anysleep-test@1, walking veto walk-v2"
    assert one.loc[("yasa", "tl-awake"), "detector_version"] == "yasa-test O1-T3, walking veto walk-v2"
    assert "pulse" not in set(df.detector)
    md = (out / "validation.md").read_text()
    assert "pulse: no reference yet. It has 3 readings" in md
    assert "| pulse | pulse-v2 | pulse | value | 0 |  | no reference yet (3 readings wait) |" in md
    assert any("pulse: no reference yet" in x for x in lines)
    # with a watch's reading in its time the pulse is compared like any measurer
    write_hand(tmp_path, rows + [row("tl-watch", a + timedelta(seconds=45), 0, "pulse", value="60", unit="bpm",
                                     source="device_watch")])
    trows, _, _ = truth.build(tmp_path)
    truth.write_table(out / "truth.tsv", trows)
    assert vd.main(["--local", str(tmp_path), "--book", str(out), "--quiet"], say=lambda _s: None) == 0
    df = pd.read_csv(out / "validation.tsv", sep="\t", keep_default_na=False, dtype=str)
    p = df[(df.detector == "pulse") & (df.scope == "label")].iloc[0]
    assert (p["detector_version"], p["values"], p["mean_error"], p["unit"]) == ("pulse-v2", "2", "1.75", "bpm")
    assert "no reference yet" not in (out / "validation.md").read_text()


def test_no_truth_table_is_said_plainly(tmp_path: Path) -> None:
    lines: list[str] = []
    assert vd.main(["--local", str(tmp_path), "--book", str(tmp_path / "data")], say=lines.append) == 1
    assert "build the data book first" in lines[0]


def test_the_hand_files_hash_is_unchanged_by_a_run(tmp_path: Path) -> None:
    out = made_up_book(tmp_path)
    before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in tmp_path.rglob("*") if p.is_file()
              and out not in p.parents}
    vd.main(["--local", str(tmp_path), "--book", str(out), "--quiet"], say=lambda _s: None)
    after = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in tmp_path.rglob("*") if p.is_file()
             and out not in p.parents}
    assert before == after  # only <book>/validation.* are written
