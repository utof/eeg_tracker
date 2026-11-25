"""Truth labels: what really happened, typed, so the detectors can be scored against it (DECISIONS 820-829).

usage: python3 scripts/truth.py check [FILE ...]      check truth files against the schema (default: the hand file and
                                                      every <local>/truth/*.tsv); exit 1 on any bad row
       python3 scripts/truth.py vocabulary            print the controlled vocabularies

The owner (2026-11-20): "make sure they're easily readable by e.g. pandas, not just AI agents or humans. Imagine hundreds
of thousands of rows -- we don't want just free text; ideally labels", collected slowly or quickly over months; and free
text matters too, for agents, beside the typed columns. docs/data-format.md "Truth labels" describes every column.

A truth file is tab-separated text with a header row, one label per row: a stretch of clock time (or a moment) with a
word from the vocabulary (`scripts/truth_vocabulary.tsv`: kinds, labels, sources, confidences), never tied to an
electrode or a device's layout. Typed columns are what programs filter on; `owner_words` (verbatim) and `context` are free
text for people and agents, never required and never a key. Cells holding a tab, a newline or a double quote are
quoted the way pandas and Python's csv read by default (wrapped in double quotes, inner ones doubled). Rows are only
ever added: a correction is a new row naming the old one in `supersedes` (`withdrawn` takes one back with nothing in its
place); the newest row of a chain is the active one.

The truth table (`_local/data/truth.tsv`, written by scripts/data_book.py) is built from:
  - the hand file `<local>/analyses/truth-labels.tsv` (rows the assistant writes from chat, or the owner by hand);
  - every `<local>/truth/*.tsv` in the same schema (a watch's pulse readings converted to rows, any later importer);
  - the Archive's tags marked "This is what I was doing" on the phone (`<local>/phone/archive/*.tags.json`, `truth`
    true), their word matched to a label by its id or the vocabulary's `also` words. A tag may carry `source`,
    `confidence` and `words` (the stop sheet's: source `owner_stop_sheet`): the row takes them, `words` verbatim;
  - the phone's spans (`<local>/phone/spans/*.spans.jsonl`, scripts/spans.py): each closed span the owner pressed or
    confirmed, with a label, is one row (source `owner_activity_button`, confidence `likely`).
  - the phone's confirmation questions (`<local>/phone/confirm/`, DECISIONS 860-869): a Yes to "Did you walk
    19:08-21:14?" is a row over the detector's stretch, a No the same row with `present` 0 (it did not happen: the
    detector was wrong there), both naming the estimate in `estimate_id`; Not sure and a question nobody answered
    make no row. `times_confirmed` 0 on a row: its start and end are the detector's, not the owner's (a plain Yes says
    "it happened", not "these times are right"): do not train or score edges on it.
Rows that break the schema are left out of the table and listed with the reason. Standard library only.
"""
from __future__ import annotations

import argparse, csv, hashlib, io, json, math, os, re, sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import spans as spans_mod  # noqa: E402  (the phone's spans files)

VOCABULARY = HERE / "truth_vocabulary.tsv"
HAND_FILE = Path("analyses") / "truth-labels.tsv"  # from <local>
IMPORT_FOLDER = Path("truth")  # from <local>: more truth files in the same schema
COLUMNS = ["label_id", "start", "end", "recording", "kind", "label", "value", "unit", "source", "confidence", "created",
           "supersedes", "owner_words", "context",
           "present", "estimate_id", "times_confirmed"]
# a file written before these columns reads with these values (the times of a row written by hand, or of a tag, are the
# owner's own: confirmed)
ADDED_LATER = {"present": "1", "estimate_id": "", "times_confirmed": "1"}
TABLE_COLUMNS = COLUMNS + ["origin", "active", "superseded_by"]  # truth.tsv: where each row came from, and its state
FREE_TEXT = ("owner_words", "context")
NUMBERED_KINDS = ("rating", "measurement")  # value and unit required
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,79}")
RECORDING = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
SCALE = re.compile(r"(\d+)-(\d+)")
ARCHIVE_CONTEXT = 'Archive tag marked "This is what I was doing"'
STOP_SHEET, STOP_SHEET_CONTEXT = "owner_stop_sheet", "stop sheet"
BUTTON_SOURCE, BUTTON_SPANS = "owner_activity_button", ("owner_button", "owner_confirmed")
OWNER_ENDS = ("owner", "activity")  # a span's `ended_by` when its end is a time the owner (or their timed session) made


# ---- the vocabulary -------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Label:
    id: str
    kind: str
    unit: str | None
    also: tuple[str, ...]
    description: str


@dataclass(frozen=True)
class Vocabulary:
    kinds: dict[str, str]
    labels: dict[str, Label]
    sources: dict[str, str]
    confidences: dict[str, str]

    def match(self, word: str) -> Label | None:
        """The label a free word names (an Archive tag): its id or one of its `also` words, in any case and spacing."""
        w = normal(word)
        for lab in self.labels.values():
            if w == lab.id or w in (normal(a) for a in lab.also):
                return lab
        return None


def normal(word: str) -> str:
    """A word as the vocabulary compares it: lower case, any run of other characters one `_`."""
    return re.sub(r"[^a-z0-9]+", "_", word.strip().lower()).strip("_")


def read_vocabulary(path: Path = VOCABULARY) -> Vocabulary:
    kinds: dict[str, str] = {}
    labels: dict[str, Label] = {}
    sources: dict[str, str] = {}
    confidences: dict[str, str] = {}
    with open(path, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            fld, i, desc = row["field"], row["id"], row["description"]
            if fld == "kind":
                kinds[i] = desc
            elif fld == "label":
                labels[i] = Label(i, row["kind"], row["unit"] or None, tuple(row["also"].split()), desc)
            elif fld == "source":
                sources[i] = desc
            elif fld == "confidence":
                confidences[i] = desc
            else:
                raise ValueError(f"{path}: unknown field {fld!r}")
    bad = [lab.id for lab in labels.values() if lab.kind not in kinds or normal(lab.id) != lab.id]
    if bad:
        raise ValueError(f"{path}: labels with an unknown kind or not a lower-case word: {bad}")
    return Vocabulary(kinds, labels, sources, confidences)


# ---- reading and checking rows --------------------------------------------------------------------------------------

def parse_time(v: str) -> datetime | None:
    """An ISO 8601 time with its UTC offset; None for anything else (a time without an offset is not accepted)."""
    try:
        t = datetime.fromisoformat(v)
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo is not None else None


def _number(v: str) -> float | None:
    try:
        x = float(v)
    except ValueError:
        return None
    return x if math.isfinite(x) else None


def row_errors(r: dict[str, str], vocab: Vocabulary) -> list[str]:
    """What is wrong with one row by itself (ids across rows are checked by `check_rows`)."""
    errs = []
    if not ID.fullmatch(r["label_id"]):
        errs.append(f"label_id {r['label_id']!r} is not an id (letters, digits, . _ : -, up to 80)")
    start, end, made = parse_time(r["start"]), parse_time(r["end"]), parse_time(r["created"])
    for name, t in (("start", start), ("end", end), ("created", made)):
        if t is None:
            errs.append(f"{name} {r[name]!r} is not an ISO time with its UTC offset")
    if start and end and end < start:
        errs.append("end is before start")
    if r["recording"] and not RECORDING.fullmatch(r["recording"]):
        errs.append(f"recording {r['recording']!r} is not a recording id")
    lab = vocab.labels.get(r["label"])
    if lab is None:
        errs.append(f"label {r['label']!r} is not in the vocabulary")
    elif r["kind"] != lab.kind:
        errs.append(f"kind {r['kind']!r}: the label {lab.id!r} is a {lab.kind!r}")
    if r["source"] not in vocab.sources:
        errs.append(f"source {r['source']!r} is not in the vocabulary")
    if r["confidence"] not in vocab.confidences:
        errs.append(f"confidence {r['confidence']!r} is not one of {', '.join(vocab.confidences)}")
    errs += _value_errors(r, lab)
    if r["present"] not in ("1", "0"):
        errs.append(f"present {r['present']!r} is not 1 (it happened) or 0 (it did not)")
    if r["estimate_id"] and not ID.fullmatch(r["estimate_id"]):
        errs.append(f"estimate_id {r['estimate_id']!r} is not an id")
    if r["times_confirmed"] not in ("1", "0"):
        errs.append(f"times_confirmed {r['times_confirmed']!r} is not 1 (the owner set or checked the times) or 0 "
                    "(the times are a detector's)")
    if r["present"] == "0" and lab is not None and lab.kind in NUMBERED_KINDS + ("correction",):
        errs.append(f"present 0 has no meaning for a {lab.kind}")
    if r["supersedes"] == r["label_id"]:
        errs.append("a row cannot supersede itself")
    if lab is not None and lab.kind == "correction" and not r["supersedes"]:
        errs.append(f"{lab.id!r} needs the row it takes back in supersedes")
    return errs


def _value_errors(r: dict[str, str], lab: Label | None) -> list[str]:
    if not r["value"]:
        if r["unit"]:
            return ["a unit without a value"]
        return [f"{lab.id!r} needs a value in {lab.unit}"] if lab and lab.kind in NUMBERED_KINDS else []
    v = _number(r["value"])
    if v is None:
        return [f"value {r['value']!r} is not a number"]
    if lab is None:
        return []
    if lab.unit is None:
        return [f"{lab.id!r} takes no value"]
    if r["unit"] != lab.unit:
        return [f"unit {r['unit']!r}: {lab.id!r} is measured in {lab.unit!r}"]
    scale = SCALE.fullmatch(lab.unit)
    if scale and not (v == int(v) and int(scale[1]) <= v <= int(scale[2])):
        return [f"value {r['value']} is not a whole number on the {lab.unit} scale"]
    if lab.kind == "measurement" and v < 0:
        return [f"value {r['value']} is negative"]
    return []


@dataclass
class Rejected:
    origin: str
    line: int  # 0: not from a file's line (an Archive tag)
    label_id: str
    why: str

    def text(self) -> str:
        where = f"{self.origin}:{self.line}" if self.line else self.origin
        return f"{where} {self.label_id or '(no id)'}: {self.why}"


@dataclass
class Read:
    rows: list[dict[str, str]] = field(default_factory=list)  # each with `origin`
    rejected: list[Rejected] = field(default_factory=list)
    ids: set[str] = field(default_factory=set)  # every id seen, valid or not (a correction may name a bad row)


def read_file(path: Path, origin: str, vocab: Vocabulary, out: Read) -> None:
    """One truth file's rows into `out`: the header must hold every column (in any order; others are an error)."""
    try:
        text = path.read_bytes().decode("utf-8-sig")  # a spreadsheet may save a byte-order mark; no newline changes
    except (OSError, UnicodeDecodeError) as e:
        out.rejected.append(Rejected(origin, 0, "", f"cannot be read ({type(e).__name__})"))
        return
    reader = csv.reader(io.StringIO(text, newline=""), delimiter="\t")
    head = next(reader, None)
    if head is None:
        return
    missing, extra = set(COLUMNS) - set(head) - set(ADDED_LATER), set(head) - set(COLUMNS)
    if missing or extra or len(set(head)) != len(head):
        out.rejected.append(Rejected(origin, 1, "", f"the header is not the truth schema (missing {sorted(missing)}, "
                                                    f"unknown {sorted(extra)})"))
        return
    for cells in reader:
        line = reader.line_num
        if not cells or cells == [""]:
            continue
        if len(cells) != len(head):
            out.rejected.append(Rejected(origin, line, cells[0] if cells else "",
                                         f"{len(cells)} cells, the header has {len(head)}"))
            continue
        r = {**ADDED_LATER, **dict(zip(head, cells))}
        r["present"] = r["present"] or "1"
        r["times_confirmed"] = r["times_confirmed"] or "1"
        out.ids.add(r["label_id"])
        errs = row_errors(r, vocab)
        if errs:
            out.rejected.append(Rejected(origin, line, r["label_id"], "; ".join(errs)))
            continue
        out.rows.append(dict(r, origin=origin))


def archive_rows(local: Path, vocab: Vocabulary, out: Read) -> None:
    """The phone's Archive tags marked as truth (`"truth": true`, DECISIONS 824): one row each, its id the same as the
    tag's row in labels.tsv (`archive:` and 16 hex of the SHA-1 of the tag as written)."""
    for f in sorted((local / "phone" / "archive").glob("*.tags.json")):
        rel = f.relative_to(local).as_posix()
        try:
            j = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            continue
        if not isinstance(j, dict) or not isinstance(j.get("tags"), list):
            continue
        for t in j["tags"]:
            if not (isinstance(t, dict) and t.get("truth") is True):
                continue
            tid = "archive:" + hashlib.sha1(json.dumps(t, sort_keys=True).encode()).hexdigest()[:16]
            word = t.get("label") if isinstance(t.get("label"), str) else ""
            lab = vocab.match(word)
            out.ids.add(tid)
            if lab is None or lab.kind in NUMBERED_KINDS + ("correction",):
                out.rejected.append(Rejected(rel, 0, tid, f"the tag {word!r} is not a label of the vocabulary (add it "
                                                          "to a label's `also` words in scripts/truth_vocabulary.tsv)"))
                continue
            r = dict(label_id=tid, start=_iso(t.get("start")), end=_iso(t.get("end")),
                     recording=str(j.get("id") or ""), kind=lab.kind, label=lab.id, value="", unit="",
                     source="owner_app_tag", confidence="certain", created=_iso(t.get("made")), supersedes="",
                     owner_words=word, context=ARCHIVE_CONTEXT, present="1", estimate_id="",
                     times_confirmed="1")
            if isinstance(t.get("source"), str):  # the stop sheet's tags: their own source, confidence and words
                words = t.get("words")
                r.update(source=t["source"], owner_words=words if isinstance(words, str) else "",
                         context=STOP_SHEET_CONTEXT if t["source"] == STOP_SHEET else ARCHIVE_CONTEXT)
                if isinstance(t.get("confidence"), str):
                    r["confidence"] = t["confidence"]
                    # "at some point in this recording": the row's times are the recording's, not the label's own
                    r["times_confirmed"] = "0" if t["confidence"] == "within" else "1"
            errs = row_errors(r, vocab)
            if errs:
                out.rejected.append(Rejected(rel, 0, tid, "; ".join(errs)))
                continue
            out.rows.append(dict(r, origin=rel))


def span_rows(local: Path, vocab: Vocabulary, out: Read) -> None:
    """The phone's spans as truth: one row per closed span the owner pressed or confirmed that has a label (its id
    `span:<span id>`, the `recording` column the recording's id). Open spans and `auto_start` / `auto_resume` spans
    give no row; a span the owner took away is not in the reader's `spans` at all. Neither does a span made by a Yes to an estimate (`owner_confirmed` with `estimate`): that Yes is the
    `confirm:` row, which says whether the times were set; the span's times after a plain Yes are the detector's."""
    for rid, f in spans_mod.all(local).items():
        rel = (spans_mod.folder(local) / f"{rid}{spans_mod.SUFFIX}").relative_to(local).as_posix()
        for s in f.spans:
            if s.source not in BUTTON_SPANS or s.end_unix is None or not s.label or s.estimate:
                continue
            if s.end_unix <= s.start_unix:
                continue  # no length: taken away with Undo, or ended by the 60-minute rule before any data
            tid = f"span:{s.span}"
            out.ids.add(tid)
            lab = vocab.labels.get(s.label)
            # an end the owner did not make (the app was closed and Stop came hours later, the 60-minute rule, a phone
            # restart, the next activity) is not a time: "at some point in this stretch". Stop of the recording under
            # a sleep stretch is the owner's own press.
            own_end = (s.ended_by in OWNER_ENDS or s.ended_by is None
                       or (s.ended_by == "recording_stopped" and s.kind in ("sleep", "nap")))
            r = dict(label_id=tid, start=_unix_iso(s.start_unix), end=_unix_iso(s.end_unix), recording=rid,
                     kind=lab.kind if lab else "", label=s.label, value="", unit="", source=BUTTON_SOURCE,
                     confidence="likely" if own_end else "within", created=_unix_iso(s.made_unix if s.made_unix is not None else s.end_unix),
                     supersedes="", owner_words="", context=f"activity button: {s.kind}", present="1",
                     estimate_id="", times_confirmed="1" if own_end else "0")
            errs = row_errors(r, vocab)
            if errs:
                out.rejected.append(Rejected(rel, 0, tid, "; ".join(errs)))
                continue
            out.rows.append(dict(r, origin=rel))


def _unix_iso(t: int | float) -> str:
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def _jsonl(path: Path) -> list[dict]:
    """A phone file's lines that are JSON objects (a line cut short by a killed app is left out)."""
    out = []
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return out
    for line in text.splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if isinstance(j, dict):
            out.append(j)
    return out


CONFIRM_FOLDER = Path("phone") / "confirm"
# the words kept after "Saved:" (packages/shared_labels/lib/src/store.dart); `skip` is the older word for `not_sure`
CONFIRM_ANSWERS = {"yes": "Yes", "no": "No", "not_sure": "Not sure", "said": "Said"}
CONFIRM_WHY_NOT = ("dismissed", "expired", "never_seen", "short_and_old")
CONFIRM_CLOSES = tuple(w for w in CONFIRM_WHY_NOT if w != "dismissed")  # the question is closed: asked no more
ONE_QUESTION = {"asleep", "nap", "night_sleep"}  # vocabulary.dart `sameAs`: the clock tells these apart, not the owner


@dataclass
class Confirmed:
    """One estimate of the phone's confirmation questions and what the owner answered (DECISIONS 860-869, 960-979).

    `answer` is yes, no, not_sure (its own answer: never a label), said (a blind card: `said` is the label picked,
    `words` the owner's own), not_answered (no answer came, `why_not` says why: never read as a Yes or a No), or ""
    (still waiting). `times_confirmed` is True only when the owner set the times himself (`start`, `end`): a plain Yes
    says it happened, not that the detector's times are right."""
    estimate: dict
    answer: str = ""
    at: str = ""
    via: str = ""
    note: str = ""
    card: str = ""  # normal, blind, or "" (no card was shown)
    said: str = ""
    words: str = ""
    times_confirmed: bool = False
    start: str = ""
    end: str = ""
    shown: str = ""
    seconds: float | None = None
    age_min: int | None = None
    why_not: str = ""

    @property
    def agrees(self) -> bool | None:
        """A blind card: whether what the owner said is what the detector thought; None when it cannot be told."""
        if self.answer != "said" or not self.said:
            return None
        guess = self.estimate["label"]
        return self.said == guess or {self.said, guess} <= ONE_QUESTION


def clean_note(words: str) -> str:
    """A note as the app keeps it: one line, single spaces, at most 200 characters."""
    return re.sub(r"\s+", " ", words).strip()[:200].rstrip()


def _not_negative(v: object) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None


def _answer_line(c: Confirmed, a: dict, labels: set[str]) -> bool:
    """Fills `c` from one answer line as packages/shared_labels/lib/src/store.dart reads it; False for a line that says
    nothing (a blind answer with neither a known label nor words)."""
    answer = "not_sure" if a["answer"] == "skip" else a["answer"]
    said = a["said"] if answer == "said" and a.get("said") in labels else ""
    words = clean_note(a["words"]) if answer == "said" and isinstance(a.get("words"), str) else ""
    if answer == "said" and not said and not words:
        return False
    c.answer, c.at, c.said, c.words = answer, a["at"], said, words
    c.via = a["via"] if isinstance(a.get("via"), str) else "card"
    c.card = a["card"] if a.get("card") in ("normal", "blind") else ""
    s, e = parse_time(a.get("start")), parse_time(a.get("end"))
    c.times_confirmed = bool(answer == "yes" and a.get("times_confirmed") is True and s and e and e > s)
    c.start, c.end = (a["start"], a["end"]) if c.times_confirmed else ("", "")
    c.shown = a["shown"] if parse_time(a.get("shown")) else ""
    c.seconds = _not_negative(a.get("seconds"))
    age = _not_negative(a.get("age_min"))
    c.age_min = None if age is None else round(age)
    return True


def read_confirm(local: Path, vocab: Vocabulary | None = None) -> list[Confirmed]:
    """The phone's estimates (`estimates.jsonl`, the first line of an id counts) with their standing answers
    (`answers.jsonl`: the first yes, no, not_sure or said stands, `undo` takes it back, a `note` adds the owner's
    words, `not_answered` is kept apart and gives way to any answer), in the order registered. The same reading as
    packages/shared_labels/lib/src/store.dart."""
    labels = set((vocab or read_vocabulary()).labels)
    got: dict[str, Confirmed] = {}
    for j in _jsonl(local / CONFIRM_FOLDER / "estimates.jsonl"):
        if isinstance(j.get("id"), str) and isinstance(j.get("label"), str):
            got.setdefault(j["id"], Confirmed(j))
    notes: dict[str, str] = {}
    answers: dict[str, Confirmed] = {}
    silent: dict[str, dict] = {}
    for j in _jsonl(local / CONFIRM_FOLDER / "answers.jsonl"):
        i = j.get("estimate_id")
        if not isinstance(i, str):
            continue
        if isinstance(j.get("note"), str):
            notes[i] = clean_note(j["note"])
        elif j.get("answer") == "undo":
            answers.pop(i, None)
            notes.pop(i, None)
        elif not parse_time(j.get("at")):
            continue
        elif j.get("answer") == "not_answered":
            if j.get("why") in CONFIRM_WHY_NOT:
                silent[i] = j
        elif j.get("answer") in (*CONFIRM_ANSWERS, "skip") and i not in answers and i in got:
            c = Confirmed(got[i].estimate)
            if _answer_line(c, j, labels):
                answers[i] = c
    for i, c in answers.items():
        c.note = notes.get(i, "")
        got[i] = c
    for i, j in silent.items():
        if i in got and i not in answers:
            c = got[i]
            c.answer, c.why_not, c.at = "not_answered", j["why"], j["at"]
            c.via = j["via"] if isinstance(j.get("via"), str) else "card"
    return list(got.values())


def confirm_row(c: Confirmed, vocab: Vocabulary | None = None) -> dict[str, str] | None:
    """An answered estimate as a truth row (the columns of COLUMNS); None for Not sure, for no answer, and for a blind
    card's words that name no label. A Yes says it happened (`present` 1), a No that it did not (`present` 0), a blind
    card's answer is a row of the label the owner picked. `times_confirmed` 0: the start and end are the detector's (a
    plain Yes does not confirm them, so the row is `likely`); 1: the owner set them, and the row carries his. The same
    row packages/shared_labels/lib/src/labels.dart writes into the phone's own `confirm/labels.tsv`; one golden file
    checks both."""
    if c.answer not in ("yes", "no") and not (c.answer == "said" and c.said):
        return None
    e = c.estimate
    label, kind = e["label"], str(e.get("kind") or "")
    if c.answer == "said":
        label, kind = c.said, (vocab or read_vocabulary()).labels[c.said].kind
    conf = e.get("confidence")
    sure = f", confidence {conf:.2f}" if isinstance(conf, (int, float)) and not isinstance(conf, bool) else ""
    means = e.get("yes_means") if e.get("yes_means") in ("certain", "likely") else "certain"
    word = (c.words or label) if c.answer == "said" else ("Yes, with my times" if c.times_confirmed
                                                          else CONFIRM_ANSWERS[c.answer])
    asked = "the app asked without showing its guess" if c.answer == "said" else "the app asked"
    return dict(label_id="confirm:" + e["id"][4:], start=_iso(c.start if c.times_confirmed else e.get("start")),
                end=_iso(c.end if c.times_confirmed else e.get("end")),
                recording=e.get("recording") or "", kind=kind, label=label, value="", unit="",
                source="owner_stop_sheet" if c.via == "stop_sheet" else "owner_app_prompt",
                confidence="certain" if c.answer == "no" else (means if c.times_confirmed else "likely"),
                created=_iso(c.at), supersedes="", owner_words=f"{word}: {c.note}" if c.note else word,
                context=f"{asked}; {e.get('detector')} ({e.get('version')}) said {e['label']}{sure}",
                present="0" if c.answer == "no" else "1", estimate_id=e["id"],
                times_confirmed="1" if c.times_confirmed else "0")


def confirm_rows(local: Path, vocab: Vocabulary, out: Read) -> None:
    """The phone's answered confirmation questions as truth rows (`<local>/phone/confirm/`)."""
    rel = (CONFIRM_FOLDER / "answers.jsonl").as_posix()
    # a Yes whose sleep stretch the owner took away afterwards ("Not sleep" in the Archive) is no truth any more
    taken = {s.estimate for f in spans_mod.all(local).values() for s in f.removed if s.estimate and not s.moved_to}
    for c in read_confirm(local, vocab):
        r = confirm_row(c, vocab)
        if r is None or (c.answer == "yes" and c.estimate.get("id") in taken):
            continue
        out.ids.add(r["label_id"])
        errs = row_errors(r, vocab)
        if errs:
            out.rejected.append(Rejected(rel, 0, r["label_id"], "; ".join(errs)))
            continue
        out.rows.append(dict(r, origin=rel))


def _iso(v: object) -> str:
    """A phone time as the table keeps it: ISO with its offset, to the second (local when it has none)."""
    if not isinstance(v, str):
        return ""
    try:
        t = datetime.fromisoformat(v)
    except ValueError:
        return v
    return (t if t.tzinfo else t.astimezone()).isoformat(timespec="seconds")


def check_rows(got: Read) -> list[dict[str, str]]:
    """Across rows: a repeated id keeps its first row; `supersedes` must name an id seen in some truth source, and no
    chain may loop. Sets `active` (1: nothing supersedes it) and `superseded_by` (the row that does)."""
    seen: dict[str, dict[str, str]] = {}
    for r in got.rows:
        if r["label_id"] in seen:
            got.rejected.append(Rejected(r["origin"], 0, r["label_id"], "the id is already used by an earlier row"))
            continue
        seen[r["label_id"]] = r
    keep = []
    for r in seen.values():
        if r["supersedes"] and r["supersedes"] not in got.ids:
            got.rejected.append(Rejected(r["origin"], 0, r["label_id"], f"supersedes {r['supersedes']!r}, an unknown id"))
            continue
        keep.append(r)
    by_old: dict[str, str] = {}
    for r in sorted(keep, key=lambda x: (x["created"], x["label_id"])):
        if r["supersedes"]:
            by_old.setdefault(r["supersedes"], r["label_id"])  # two corrections of one row: the first made wins
    loops = {i for i in by_old if _loops(i, by_old)}
    out = []
    for r in keep:
        if r["label_id"] in loops:
            got.rejected.append(Rejected(r["origin"], 0, r["label_id"], "its supersedes chain comes back to it"))
            continue
        nxt = by_old.get(r["label_id"])
        out.append(dict(r, active="0" if nxt else "1", superseded_by=nxt or ""))
    return sorted(out, key=lambda x: (_sort_time(x["start"]), x["label_id"]))


def _loops(start: str, nxt: dict[str, str]) -> bool:
    seen, i = {start}, nxt.get(start)
    while i is not None:
        if i in seen:
            return True
        seen.add(i)
        i = nxt.get(i)
    return False


def _sort_time(v: str) -> float:
    t = parse_time(v)
    return t.timestamp() if t else math.inf


def sources_of(local: Path) -> list[tuple[Path, str]]:
    """The truth files under `local`: the hand file first, then <local>/truth/*.tsv."""
    files = [(local / HAND_FILE, HAND_FILE.as_posix())]
    files += [(p, p.relative_to(local).as_posix()) for p in sorted((local / IMPORT_FOLDER).glob("*.tsv"))]
    return [(p, rel) for p, rel in files if p.is_file()]


def build(local: Path, vocab: Vocabulary | None = None) -> tuple[list[dict[str, str]], list[Rejected], dict[str, int]]:
    """The truth table's rows from every truth source under `local`, what was left out, and rows per source kind."""
    vocab = vocab or read_vocabulary()
    got = Read()
    for p, rel in sources_of(local):
        read_file(p, rel, vocab, got)
    archive_rows(local, vocab, got)
    confirm_rows(local, vocab, got)
    span_rows(local, vocab, got)
    rows = check_rows(got)
    counts = {"hand": 0, "files": 0, "archive": 0, "confirm": 0, "spans": 0}
    for r in rows:
        counts[origin_kind(r["origin"])] += 1
    return rows, got.rejected, counts


def origin_kind(origin: str) -> str:
    """`hand` (the hand file), `archive` (a phone tag), `confirm` (an answer), `spans` (a pressed activity) or `files`
    (<local>/truth/)."""
    if origin == HAND_FILE.as_posix():
        return "hand"
    if origin.startswith("phone/confirm/"):
        return "confirm"
    if origin.startswith("phone/spans/"):
        return "spans"
    return "archive" if origin.startswith("phone/archive/") else "files"


def to_tsv(rows: Iterable[dict[str, str]], columns: list[str] = TABLE_COLUMNS) -> str:
    """Rows as TSV: a header, `\\n` line ends, a cell with a tab, newline or double quote quoted (csv's minimal rule,
    which pandas reads by default)."""
    buf = io.StringIO()
    w = csv.writer(buf, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    w.writerow(columns)
    for r in rows:
        w.writerow([r.get(c, "") for c in columns])
    return buf.getvalue()


def write_table(path: Path, rows: list[dict[str, str]]) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="") as f:  # no newline changes: a cell keeps its own line ends
        f.write(to_tsv(rows))
    os.replace(tmp, path)


# ---- the command line -----------------------------------------------------------------------------------------------

def main(argv: list[str] | None = None, out=print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=HERE.parent / "_local", help="the data folder (default: the repo's)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="check truth files (default: the hand file and <local>/truth/*.tsv)")
    c.add_argument("files", nargs="*", type=Path)
    sub.add_parser("vocabulary", help="print the controlled vocabularies")
    a = ap.parse_args(argv)
    vocab = read_vocabulary()
    if a.cmd == "vocabulary":
        out("kinds: " + ", ".join(vocab.kinds))
        for k in vocab.kinds:
            labs = [lab.id + (f" ({lab.unit})" if lab.unit else "") for lab in vocab.labels.values() if lab.kind == k]
            out(f"  {k}: {', '.join(labs)}")
        out("sources: " + ", ".join(vocab.sources))
        out("confidence: " + ", ".join(vocab.confidences))
        return 0
    local = a.local.resolve()
    files = [(p, str(p)) for p in a.files] if a.files else sources_of(local)
    got = Read()
    for p, name in files:
        read_file(p, name, vocab, got)
    rows = check_rows(got)
    for r in got.rejected:
        out("BAD " + r.text())
    out(f"{len(rows)} good rows ({sum(r['active'] == '1' for r in rows)} active), {len(got.rejected)} bad, "
        f"in {len(files)} file(s)")
    return 1 if got.rejected else 0


if __name__ == "__main__":
    sys.exit(main())
