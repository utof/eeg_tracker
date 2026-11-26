"""What you were doing in a recording: the laptop's reader of the phone's spans files (Record first, DECISIONS 880-899).

usage: python3 scripts/spans.py [--local _local] list          one plain line per span of every recording
       python3 scripts/spans.py [--local _local] show ID       the spans of one recording (its id, e.g. 2026-11-21-110200)

The phone keeps `files/spans/<recording id>.spans.jsonl` (docs/data-format.md, "What you were doing in a recording");
Export data and Share on Wi-Fi copy the folder to `<local>/phone/spans/`. This is the twin of the phone's reader
(`app/lib/spans/span.dart`, `readSpans`): both are checked against the golden files in `tests/contract/spans/`.

  read(path)                      -> SpansFile  (spans, removed, reviewed, sets, hides, skipped)
  folder(local)                   -> <local>/phone/spans
  for_recording(local, id)        -> SpansFile  (empty when the recording has no file)
  all(local)                      -> {recording id: SpansFile}  (the id is the file name minus `.spans.jsonl`)
  sleep_spans(spans_file)         the spans of kind `sleep` or `nap`
  rode_on_recording(session)      True when a session file's JSON has a `span` (it rode on a recording)
  span_of(session, files)         -> the Span a session file rode on (its `recording` + `span`), or None
  window(span)                    -> (start, end) unix seconds of the span (end None while open): the samples of the
                                  recording to take for that activity's raw signal
  session_window(session, files)  -> window(span_of(...)), or None
  own_raw(session)                -> the stem of the session's own raw set, None when it rode on a recording
  no_sleep_sets(local)            -> the file sets (stems) that "Not sleep" says are no sleep, over all files
  hidden_nights(local)            -> the evening dates whose report "Not sleep" hides, over all files
  taken_ids(local)                -> the ids of the spans taken away (or filed again elsewhere), over all files
  report_all_taken(report, ids)   True for a sleep report made only from spans that were taken away since

The rules, as the format doc has them: the last line with a given `span` id is the span; spans are listed in the order
they first appear; a line that is not a JSON object, has a `v` other than 1, or is neither a span nor a `reviewed`
line is skipped and counted (a half last line from a kill, too); a kind this reader does not know is kept. A span
needs `span`, `kind`, `source` (non-empty text), a `start` that parses and an `end` that is null, absent or a time.
`reviewed` lines: the last one counts; `sets` and `hides` come from that last line and are empty when it says `sleep`.
A span whose last line says `"removed": true` was taken away by the owner ("Not sleep", "Remove this mark") or filed
again under another recording (`moved_to`): it is not in `spans`, so nothing counts it (nights, naps, truth rows,
spans.tsv); it is listed in `removed`, in the order of first appearance. A later line without `removed` puts it back.

Choices the format doc leaves open (both readers must do the same): a blank line is skipped without being counted; a
`reviewed` word other than `no_sleep` or `sleep` makes the line skipped; a time without an offset is read as this
laptop's local time; a `paused` pair that does not parse is dropped (the span is kept); `started_recording` that is
not `true` reads as false; text fields that are not text read as None.

Standard library only (the recorder hub imports night_files, which imports this, and must never import numpy).
"""
from __future__ import annotations

import argparse, json, sys
from builtins import all as builtins_all  # this module's own `all(local)` is the documented name
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

SUFFIX = ".spans.jsonl"
SLEEP_KINDS = ("sleep", "nap")
REVIEWED = ("no_sleep", "sleep")
DEFAULT_LOCAL = Path(__file__).resolve().parent.parent / "_local"


@dataclass(frozen=True)
class Span:
    span: str  # `<recording id>-<n>`
    kind: str  # sleep, nap, work, ... or a kind this reader does not know
    label: str | None
    start_unix: int | float
    end_unix: int | float | None  # None while the span is open
    source: str  # owner_button, owner_confirmed, auto_start, auto_resume, ...
    started_recording: bool = False
    ended_by: str | None = None
    session: str | None = None
    paused: tuple[tuple[int | float, int | float | None], ...] = ()
    estimate: str | None = None
    made_unix: int | float | None = None  # when the last line of the span was written (not in the golden files)
    removed: bool = False  # the owner took it away, or it was filed again under another recording (`moved_to`)
    moved_to: str | None = None  # the id of the span that took its place in another recording's file

    @property
    def closed(self) -> bool:
        return self.end_unix is not None

    @property
    def is_sleep(self) -> bool:
        return self.kind in SLEEP_KINDS

    @property
    def minutes(self) -> float | None:
        return None if self.end_unix is None else (self.end_unix - self.start_unix) / 60

    @property
    def paused_minutes(self) -> float:
        """Minutes of the pauses; a pause still open when the span closed ends with it, one in an open span is left out."""
        total = 0.0
        for a, b in self.paused:
            b = self.end_unix if b is None else b
            if b is not None and b > a:
                total += (b - a) / 60
        return total

    def to_json(self) -> dict:
        """The golden files' shape (`*.expected.json`)."""
        return dict(span=self.span, kind=self.kind, label=self.label, start_unix=self.start_unix,
                    end_unix=self.end_unix, source=self.source, started_recording=self.started_recording,
                    ended_by=self.ended_by, session=self.session, paused=[list(p) for p in self.paused],
                    estimate=self.estimate)

    def to_json_removed(self) -> dict:
        """The golden files' shape of a span in `removed`."""
        return dict(self.to_json(), moved_to=self.moved_to)


@dataclass
class SpansFile:
    spans: list[Span] = field(default_factory=list)  # in the order each span first appeared; without the removed
    removed: list[Span] = field(default_factory=list)  # the spans taken away or moved, in the same order
    reviewed: str | None = None  # `no_sleep` or `sleep` from the last reviewed line; None without one
    sets: list[str] = field(default_factory=list)
    hides: list[str] = field(default_factory=list)
    skipped: int = 0  # lines skipped

    def to_json(self) -> dict:
        return dict(spans=[s.to_json() for s in self.spans], removed=[s.to_json_removed() for s in self.removed],
                    reviewed=self.reviewed, sets=list(self.sets),
                    hides=list(self.hides), skipped=self.skipped)


# ---- reading ------------------------------------------------------------------------------------------------------

def _time(v: object) -> int | float | None:
    """Unix seconds of an ISO time (no offset: local time); None when it does not parse."""
    if not isinstance(v, str):
        return None
    try:
        t = datetime.fromisoformat(v).timestamp()
    except ValueError:
        return None
    return int(t) if t == int(t) else t


def _text(v: object) -> str | None:
    return v if isinstance(v, str) else None


def _need(v: object) -> str | None:
    return v if isinstance(v, str) and v else None


def _span(d: dict) -> Span | None:
    span, kind, source, start = _need(d.get("span")), _need(d.get("kind")), _need(d.get("source")), _time(d.get("start"))
    end = d.get("end")
    end_unix = None if end is None else _time(end)
    if span is None or kind is None or source is None or start is None or (end is not None and end_unix is None):
        return None
    pauses = []
    for p in d.get("paused") if isinstance(d.get("paused"), list) else []:
        if isinstance(p, list) and len(p) == 2 and (a := _time(p[0])) is not None and (p[1] is None or _time(p[1]) is not None):
            pauses.append((a, None if p[1] is None else _time(p[1])))
    return Span(span, kind, _text(d.get("label")), start, end_unix, source, d.get("started_recording") is True,
                _text(d.get("ended_by")), _text(d.get("session")), tuple(pauses), _text(d.get("estimate")),
                _time(d.get("made")), d.get("removed") is True, _text(d.get("moved_to")) if d.get("removed") is True else None)


def _strings(v: object) -> list[str]:
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []


def parse(text: str) -> SpansFile:
    """The spans in the text of a spans file."""
    by_id: dict[str, Span] = {}  # a dict keeps the order of first appearance; a later line replaces the value
    out = SpansFile()
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        v = d.get("v") if isinstance(d, dict) else None
        if not isinstance(d, dict) or isinstance(v, bool) or v != 1:
            out.skipped += 1
            continue
        if "reviewed" in d:
            if d["reviewed"] not in REVIEWED:
                out.skipped += 1
                continue
            out.reviewed = d["reviewed"]
            out.sets, out.hides = ([], []) if d["reviewed"] == "sleep" else (_strings(d.get("sets")),
                                                                              _strings(d.get("hides")))
            continue
        s = _span(d)
        if s is None:
            out.skipped += 1
        else:
            by_id[s.span] = s
    out.spans = [s for s in by_id.values() if not s.removed]
    out.removed = [s for s in by_id.values() if s.removed]
    return out


def read(path: Path | str) -> SpansFile:
    """The spans file at `path`; a missing or unreadable file is an empty one."""
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return SpansFile()
    return parse(text)


# ---- the folder ---------------------------------------------------------------------------------------------------

def folder(local: Path | str) -> Path:
    return Path(local) / "phone" / "spans"


def in_folder(where: Path | str) -> dict[str, SpansFile]:
    """Every spans file of a spans folder, by recording id (its file name minus `.spans.jsonl`), oldest id first."""
    out: dict[str, SpansFile] = {}
    for p in sorted(Path(where).glob(f"*{SUFFIX}")):
        if p.is_file():
            out[p.name[: -len(SUFFIX)]] = read(p)
    return out


def for_recording(local: Path | str, recording_id: str) -> SpansFile:
    return read(folder(local) / f"{recording_id}{SUFFIX}")


def all(local: Path | str) -> dict[str, SpansFile]:  # noqa: A001 - the documented name
    return in_folder(folder(local))


def sleep_spans(f: SpansFile) -> list[Span]:
    """Spans of kind `sleep` or `nap`: the only ones a sleep report comes from."""
    return [s for s in f.spans if s.is_sleep]


def rode_on_recording(session: object) -> bool:
    """A session file with a `span` field rode on a recording (Record first, step 4): no raw set of its own."""
    return isinstance(session, dict) and _need(session.get("span")) is not None


def span_of(session: object, files: dict[str, SpansFile]) -> Span | None:
    """The span a session file (work, meditation, nap, ...) rode on, from its `recording` and `span` fields."""
    if not rode_on_recording(session):
        return None
    assert isinstance(session, dict)
    rec, sid = _need(session.get("recording")), _need(session.get("span"))
    f = files.get(rec) if rec is not None else None
    return next((s for s in f.spans if s.span == sid), None) if f is not None else None


def window(s: Span) -> tuple[int | float, int | float | None]:
    """The recording's samples between these two times (unix seconds) are the activity's signal; end None: still open."""
    return s.start_unix, s.end_unix


def session_window(session: object, files: dict[str, SpansFile]) -> tuple[int | float, int | float | None] | None:
    s = span_of(session, files)
    return None if s is None else window(s)


def own_raw(session: object) -> str | None:
    """The stem of the raw file set a session wrote itself (`raw`, or `recording` in the older nap, dream catcher and
    sound files); None for a session that rode on a recording, whose `recording` names the day's recording."""
    if not isinstance(session, dict) or rode_on_recording(session):
        return None
    return _need(session.get("raw")) or _need(session.get("recording"))


def no_sleep_of(files: dict[str, SpansFile]) -> set[str]:
    return {x for f in files.values() if f.reviewed == "no_sleep" for x in f.sets}


def hidden_of(files: dict[str, SpansFile]) -> set[str]:
    return {x for f in files.values() if f.reviewed == "no_sleep" for x in f.hides}


def taken_ids(local: Path | str) -> set[str]:
    """The ids of every span that was taken away or filed again elsewhere, over all spans files of the phone's folder."""
    return {s.span for f in all(local).values() for s in f.removed}


def mark_taken(session: object, taken: set[str]) -> bool:
    """A session file (work, meditation, nap coach, ...) whose mark on the recording was taken away ("Remove this
    mark" in the Archive) and not put back: it counts in no table, as on the phone (DECISIONS 1042, 1080). Its file
    stays. [taken]: `taken_ids`."""
    return rode_on_recording(session) and isinstance(session, dict) and session.get("span") in taken


def report_all_taken(report: object, taken: set[str]) -> bool:
    """A sleep report (its JSON) that came from sleep spans every one of which was taken away since: the phone has
    put its own away (`nights/not-sleep/`); a copy of it must not make a night by itself."""
    span = report.get("span") if isinstance(report, dict) else None
    ids = span.get("spans") if isinstance(span, dict) else None
    return isinstance(ids, list) and bool(ids) and builtins_all(i in taken for i in ids)


def no_sleep_sets(local: Path | str) -> set[str]:
    """The file sets (stems) that "Not sleep" says are no sleep, over all spans files of the phone's folder."""
    return no_sleep_of(all(local))


def hidden_nights(local: Path | str) -> set[str]:
    """The evening dates whose report "Not sleep" hides, over all spans files of the phone's folder."""
    return hidden_of(all(local))


# ---- plain lines --------------------------------------------------------------------------------------------------

def _clock(t: int | float | None) -> str:
    return "still open" if t is None else datetime.fromtimestamp(t).astimezone().strftime("%Y-%m-%d %H:%M")


def line(s: Span) -> str:
    """One span in plain words: `2026-11-21-110200-1  work  2026-11-21 11:05 to 2026-11-21 16:30  (owner_button)`."""
    note = "" if not s.paused else f", paused {s.paused_minutes:.0f} min"
    return f"{s.span}  {s.kind}  {_clock(s.start_unix)} to {_clock(s.end_unix)}  ({s.source}{note})"


def describe(rec_id: str, f: SpansFile) -> list[str]:
    out = [f"recording {rec_id}: {len(f.spans)} span(s)" + (f", {f.skipped} line(s) skipped" if f.skipped else "")]
    out += [f"  {line(s)}" for s in f.spans]
    out += [f"  taken away: {line(s)}" + (f", now {s.moved_to}" if s.moved_to else "") for s in f.removed]
    if f.reviewed == "no_sleep":
        out.append(f"  not sleep: sets {' '.join(f.sets) or '-'}; hides nights {' '.join(f.hides) or '-'}")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="the data folder (default: the repo's _local)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="every recording's spans")
    show = sub.add_parser("show", help="one recording's spans")
    show.add_argument("id", help="the recording's id, e.g. 2026-11-21-110200")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        files = all(a.local)
        if not files:
            print(f"no spans files in {folder(a.local)}")
        for rid, f in files.items():
            print("\n".join(describe(rid, f)))
        return 0
    if not (folder(a.local) / f"{a.id}{SUFFIX}").is_file():
        print(f"no spans file for recording {a.id} in {folder(a.local)}", file=sys.stderr)
        return 1
    print("\n".join(describe(a.id, for_recording(a.local, a.id))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
