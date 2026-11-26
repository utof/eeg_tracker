"""The data book's guesses table (DECISIONS 1113): one row per mark of the phone's "What happened" files
(`phone/activity/*.guesses.json`), with the numbers the phone kept, the numbers the laptop can add from the same
copy (the screen and the step counter from the recordings' logs, the laptop's work word from the watcher's log), the
question asked about it and the owner's answer, and the truth label that covers it. No model reads it."""
from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import data_book as db  # noqa: E402

REC = "2026-11-26-130000"


def mark(what: str, start: str, end: str, sure: str, **numbers: object) -> dict:
    return dict(what=what, start=f"2026-11-26T{start}+03:00", end=f"2026-11-26T{end}+03:00", sure=sure, **numbers)


def phone(local: Path) -> None:
    act = local / "phone" / "activity"
    act.mkdir(parents=True)
    (act / f"{REC}.guesses.json").write_text(json.dumps(dict(
        version=1, recording=REC, made="2026-11-26T15:00:00+03:00", key="k", marks=[
            mark("eyes_closed_resting", "13:02:00", "13:06:00", "strong", minutes_from_bedtime=-598,
                 in_bedtime_window=False, eyes_closed_share=1, good_signal_share=0.875, jaw_bursts_per_min=0,
                 movement_s_per_min=0.5, back_alpha=2.5),
            mark("walking", "13:20:00", "13:30:00", "good", minutes_from_bedtime=-580, in_bedtime_window=False,
                 eyes_closed_share=0, good_signal_share=0.5, jaw_bursts_per_min=1, movement_s_per_min=12,
                 back_alpha=None),
            mark("no_signal", "13:40:00", "13:41:00", "near certain"),
        ])))
    (act / "other-version.guesses.json").write_text(json.dumps(dict(version=99, recording="x", marks=[{}])))
    (act / "broken.guesses.json").write_text("{not json")
    rec = local / "phone" / "recordings"
    rec.mkdir(parents=True)
    (rec / f"{REC}.log").write_text(
        "2026-11-26T13:00:00.000 eeg_tracker wifi connected; default route wifi; screen on; idle no; lock held\n"
        "2026-11-26T13:03:00.000 eeg_tracker wifi connected; default route wifi; screen off; idle no; lock held\n"
        "2026-11-26T13:19:30.000 phone steps 1000\n"
        "2026-11-26T13:25:00.000 phone steps 1500\n"
        "2026-11-26T13:29:50.000 phone steps 2000\n")
    auto = local / "phone" / "auto-start"
    auto.mkdir(parents=True)
    (auto / "log.jsonl").write_text(
        json.dumps(dict(version=1, at="2026-11-26T12:50:00+03:00", event="laptop", working=True)) + "\n"
        + json.dumps(dict(version=1, at="2026-11-26T13:10:00+03:00", event="laptop", working=False)) + "\n")
    conf = local / "phone" / "confirm"
    conf.mkdir(parents=True)
    est = dict(id="est:rest", detector="eyes-closed-rest", version="rest-v1", confidence=1.0,
               start="2026-11-26T13:02:00+03:00", end="2026-11-26T13:06:00+03:00", recording=REC, kind="state",
               label="eyes_closed", yes_means="certain", made="2026-11-26T15:00:00+03:00")
    walk = dict(id="est:walk", detector="walking", version="walk-v2", confidence=0.9,
                start="2026-11-26T13:19:00+03:00", end="2026-11-26T13:31:00+03:00", recording=REC, kind="activity",
                label="walking", yes_means="certain", made="2026-11-26T15:00:00+03:00")
    (conf / "estimates.jsonl").write_text(json.dumps(est) + "\n" + json.dumps(walk) + "\n")
    (conf / "answers.jsonl").write_text(json.dumps(dict(
        estimate_id="est:rest", answer="said", at="2026-11-26T15:05:00+03:00", via="card", card="choice",
        said="meditating")) + "\n")


def test_guesses_tsv_has_one_row_per_mark_with_its_numbers_and_the_answer(tmp_path: Path) -> None:
    phone(tmp_path)
    out = tmp_path / "data"
    msgs: list[str] = []
    assert db.main(["--local", str(tmp_path), "--out", str(out), "--quiet"], out=msgs.append) == 0, msgs
    text = (out / "guesses.tsv").read_text()
    assert text.splitlines()[0].split("\t") == db.GUESS_COLUMNS
    rest, walk, gone = list(csv.DictReader(io.StringIO(text), delimiter="\t"))
    assert (rest["recording"], rest["what"], rest["sure"], rest["minutes"]) == (REC, "eyes_closed_resting", "strong", "4")
    assert rest["start"] == "2026-11-26T13:02:00+03:00" and rest["guess_id"] == f"{REC}/eyes_closed_resting/13:02:00"
    # the phone's numbers, as they are
    assert (rest["minutes_from_bedtime"], rest["in_bedtime_window"], rest["eyes_closed_share"], rest["back_alpha"],
            rest["jaw_bursts_per_min"], rest["movement_s_per_min"], rest["good_signal_share"]) == \
        ("-598", "0", "1", "2.5", "0", "0.5", "0.875")
    # the laptop's: the screen was on for 1 of the 4 minutes; the laptop said "working" at 12:50; no step reading
    assert (rest["screen_on_share"], rest["laptop_working"], rest["phone_steps_per_min"]) == ("0.25", "1", "")
    assert rest["charging"] == "", "the phone does not write it down during a recording yet"
    # the question about it and the answer; the truth label that covers it
    assert (rest["estimate_id"], rest["answer"], rest["said"]) == ("est:rest", "said", "meditating")
    assert (rest["truth_label"], rest["truth_present"]) == ("meditating", "1")
    # a walk: steps from the phone's counter (1000 at 13:19:30 to 2000 at 13:29:50 over 10 minutes), the laptop said
    # "not working" at 13:10, its question is still open, nothing covers it
    assert (walk["what"], walk["phone_steps_per_min"], walk["laptop_working"], walk["screen_on_share"]) == \
        ("walking", "100", "0", "0")
    assert (walk["estimate_id"], walk["answer"], walk["truth_label"], walk["back_alpha"]) == ("est:walk", "", "", "")
    # a mark the pass gave no numbers for: empty, not 0
    assert (gone["what"], gone["eyes_closed_share"], gone["minutes_from_bedtime"], gone["estimate_id"]) == \
        ("no_signal", "", "", "")
    book = json.loads((out / "book.json").read_text())
    assert book["rows"]["guesses.tsv"] == 3
    assert "guesses.tsv" in (out / "README.md").read_text() and "guesses.tsv" in db.TABLES


def test_no_guesses_files_is_an_empty_table(tmp_path: Path) -> None:
    out = tmp_path / "data"
    assert db.main(["--local", str(tmp_path), "--out", str(out), "--quiet"], out=lambda _s: None) == 0
    assert (out / "guesses.tsv").read_text().splitlines() == ["\t".join(db.GUESS_COLUMNS)]
