"""The phone's confirmation questions on the laptop (DECISIONS 860-869): answers become truth rows (`present` 1 for a
Yes, 0 for a No), the data book lists every estimate, and the detectors are scored against a No as well. The golden
file `packages/shared_labels/test/fixtures/confirm/` is the one the app's own export is tested with (packages/shared_labels/test, app/test/confirm_test.dart): the
phone and the laptop must make the same rows from the same two files.
"""
from __future__ import annotations

import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import data_book as db  # noqa: E402
import truth  # noqa: E402
from test_truth import SLEEPY, T0, by_id, iso, output, row, truth_of, vd, write_hand  # noqa: E402

FIXTURE = ROOT / "packages" / "shared_labels" / "test" / "fixtures" / "confirm"
VOCAB = truth.read_vocabulary()


def phone(local: Path) -> Path:
    """The fixture as the phone link leaves it: <local>/phone/confirm/."""
    to = local / truth.CONFIRM_FOLDER
    to.mkdir(parents=True)
    for name in ("estimates.jsonl", "answers.jsonl"):
        shutil.copy(FIXTURE / name, to / name)
    return to


def test_the_laptop_makes_the_rows_the_phone_exports(tmp_path: Path) -> None:
    phone(tmp_path)
    got = truth.Read()
    truth.confirm_rows(tmp_path, VOCAB, got)
    assert got.rejected == []
    rows = sorted(got.rows, key=lambda r: (truth.parse_time(r["start"]), r["label_id"]))
    assert truth.to_tsv(rows, truth.COLUMNS) == (FIXTURE / "labels.tsv").read_text(encoding="utf-8")


def test_the_laptops_estimates_table_is_the_phones(tmp_path: Path) -> None:
    phone(tmp_path)
    assert db.tsv(db.ESTIMATE_COLUMNS, db.estimate_rows(tmp_path)) == (FIXTURE / "estimates.tsv").read_text(
        encoding="utf-8")


def test_the_golden_file_is_a_truth_file_pandas_reads_typed(tmp_path: Path) -> None:
    assert truth.main(["check", str(FIXTURE / "labels.tsv")], out=lambda _s: None) == 0
    df = pd.read_csv(FIXTURE / "labels.tsv", sep="\t", parse_dates=["start", "end", "created"], keep_default_na=False)
    assert list(df.columns) == truth.COLUMNS and str(df["start"].dtype).startswith("datetime64")
    assert df["present"].tolist() == [1, 1, 0, 1, 0] and df["present"].dtype.kind == "i"
    assert df["label"].tolist() == ["nap", "walking", "asleep", "asleep", "walking"]
    assert set(df["source"]) == {"owner_app_prompt", "owner_stop_sheet"} and set(df["source"]) <= set(VOCAB.sources)
    assert df["confidence"].tolist() == ["certain", "certain", "certain", "likely", "certain"]
    assert df.loc[2, "owner_words"] == 'No: I was "walking" then'  # the quotes survive
    assert (df["estimate_id"].str.replace("est:", "confirm:") == df["label_id"]).all()


def test_yes_no_and_not_sure_and_undo_read_as_the_app_reads_them(tmp_path: Path) -> None:
    phone(tmp_path)
    got = {c.estimate["label"] + " " + c.estimate["start"][5:16]: c for c in truth.read_confirm(tmp_path)}
    assert len(got) == 7
    assert got["nap 11-20T15:59"].answer == "yes" and got["asleep 11-20T19:20"].answer == "no"  # the first answer stands
    assert got["walking 11-20T19:08"].note == "walked to the shop and back"
    assert (got["asleep 11-20T23:41"].via, got["walking 11-21T08:10"].answer) == ("notification", "skip")
    undone = got["walking 11-21T09:00"]
    assert (undone.answer, undone.via, undone.at) == ("no", "stop_sheet", "2026-11-21T09:45:00+03:00")
    assert got["nap 11-21T13:00"].answer == ""
    assert truth.confirm_row(got["walking 11-21T08:10"]) is None and truth.confirm_row(got["nap 11-21T13:00"]) is None


def test_the_truth_table_takes_the_answers_and_old_files_still_read(tmp_path: Path) -> None:
    local = tmp_path / "local"
    phone(local)
    old = [c for c in truth.COLUMNS if c not in truth.ADDED_LATER]  # the hand file as written before these columns
    write_hand(local, [row("tl-1", label="awake")], old)
    rows, rejected, counts = truth.build(local)
    assert rejected == [] and counts == {"hand": 1, "files": 0, "archive": 0, "confirm": 5, "spans": 0}
    hand = next(r for r in rows if r["label_id"] == "tl-1")
    assert (hand["present"], hand["estimate_id"]) == ("1", "")
    no = [r for r in rows if r["present"] == "0"]
    assert [r["label"] for r in no] == ["asleep", "walking"] and all(r["active"] == "1" for r in rows)
    assert all(r["origin"] == "phone/confirm/answers.jsonl" for r in rows if r["label_id"] != "tl-1")


def test_present_is_checked(tmp_path: Path) -> None:
    write_hand(tmp_path, [row("a", present="2"), row("b", present="0"), row("c", label="kss", value="7", unit="1-9",
                                                                             present="0"),
                          row("d", estimate_id="not an id")])
    rows, rejected, _ = truth.build(tmp_path)
    assert [r["label_id"] for r in rows] == ["b"]
    why = {r.label_id: r.why for r in rejected}
    assert "not 1 (it happened) or 0" in why["a"] and "no meaning for a rating" in why["c"] and "estimate_id" in why["d"]


def test_the_data_book_lists_estimates_and_labels(tmp_path: Path) -> None:
    local = tmp_path / "local"
    phone(local)
    book = db.build(local, local / "data", datetime.now().astimezone(), say=lambda _s: None)
    assert book["rows"]["estimates.tsv"] == 7 and book["rows"]["truth.tsv"] == 5
    assert book["truth_from"]["confirm"] == 5 and book["truth_rejected"] == []
    est = pd.read_csv(local / "data" / "estimates.tsv", sep="\t", parse_dates=["start", "end"], keep_default_na=False)
    assert list(est.columns) == db.ESTIMATE_COLUMNS and str(est["start"].dtype).startswith("datetime64")
    assert est["answer"].tolist() == ["yes", "yes", "no", "yes", "skip", "no", ""]
    assert est["detector"].tolist()[:3] == ["sleep-periods", "walking", "sleep-periods"]
    assert est.loc[2, "confidence"] == "0.555" and est.loc[5, "confidence"] == ""
    assert (est["label_id"] != "").tolist() == [True, True, True, True, False, True, False]
    tr = pd.read_csv(local / "data" / "truth.tsv", sep="\t", keep_default_na=False)
    assert set(est.loc[est["label_id"] != "", "label_id"]) == set(tr["label_id"])
    assert set(tr["estimate_id"]) <= set(est["estimate_id"])
    labels = pd.read_csv(local / "data" / "labels.tsv", sep="\t", keep_default_na=False)
    mine = labels[labels["source"] == "confirm"]
    assert sorted(mine["value"]) == ["asleep", "nap", "not asleep", "not sure", "not walking", "walking"]
    assert set(mine["how_asked"]) == {"question (card)", "question (notification)", "question (stop_sheet)"}
    assert "walking walk-v2" in set(mine["detector_version"])
    # a second run adds nothing: answers are append-only on the phone and the ids are stable
    again = db.build(local, local / "data", datetime.now().astimezone(), say=lambda _s: None)
    assert again["labels_added"] == 0 and again["labels_removed"] == 0
    assert "estimates.tsv" in (local / "data" / "README.md").read_text()


def test_a_no_scores_the_detector_that_said_yes() -> None:
    # 10 minutes of output; the app asked "Did you sleep?" about the first 5 and the owner said No
    o = output("yyyyyyynnn" + "nnnnnnnnnn")
    not_asleep = row("confirm:x", T0, 5, "asleep", present="0", source="owner_app_prompt")
    asleep = row("confirm:y", T0 + timedelta(minutes=5), 5, "asleep", present="1")
    not_awake = row("z", T0, 5, "awake", present="0")  # says nothing about sleep: not compared
    got = by_id(vd.binary_rows(SLEEPY, truth_of([not_asleep, asleep, not_awake]), [o]))
    x, y = got["confirm:x"], got["confirm:y"]
    assert (x["truth_present"], x["truth_expects"], x["false_pos_min"], x["agreement_pct"]) == ("0", "no", 3.5, 30.0)
    assert (y["truth_present"], y["truth_expects"], y["false_neg_min"]) == ("1", "yes", 5.0)
    assert "z" not in got
    totals = [r for r in vd.binary_rows(SLEEPY, truth_of([not_asleep, asleep]), [o]) if r["scope"] == "all"]
    assert [(r["label"], r["truth_present"], r["periods"]) for r in totals] == [("asleep", "1", 1), ("asleep", "0", 1)]
    md = vd.summary(totals, dict(truth=2, uncovered=[], seen={}, problems=[]), iso(T0), None)
    assert "during not asleep (5 min compared) it falsely said asleep for 3.5 min" in md
    assert SLEEPY.expects("nap", "0") == "no" and SLEEPY.expects("walking", "0") is None


def test_the_shared_package_holds_the_vocabulary_as_it_is_now() -> None:
    """packages/shared_labels' generated vocabulary is what scripts/truth_vocabulary.tsv gives (run
    `python3 scripts/gen_shared_labels.py` after changing the TSV), the two sources the app writes exist, and the
    package's label columns are the truth schema's."""
    import gen_shared_labels as gen
    assert gen.OUT.read_text(encoding="utf-8") == gen.source(VOCAB), "run python3 scripts/gen_shared_labels.py"
    assert gen.main(["--check"]) == 0
    assert {"owner_app_prompt", "owner_stop_sheet"} <= set(VOCAB.sources)
    labels_dart = (ROOT / "packages" / "shared_labels" / "lib" / "src" / "labels.dart").read_text(encoding="utf-8")
    columns = re.findall(r"'(\w+)'", labels_dart.split("labelColumns = [", 1)[1].split("];", 1)[0])
    assert columns == truth.COLUMNS
    asked = (ROOT / "packages" / "shared_labels" / "lib" / "src" / "vocabulary.dart").read_text(encoding="utf-8")
    for word in re.findall(r"^  '(\w+)': '", asked, flags=re.M):  # every label with question words is a label
        assert word in VOCAB.labels or word == "night_sleep", word
