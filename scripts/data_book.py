"""The data book: tidy tables of every night, nap, session, day, 30 s piece and label on this laptop, for many days.

usage: uv run --project analysis python scripts/data_book.py [--local _local] [--out <local>/data] [--full] [--quiet]

The owner's question (2026-11-20): "are we saving data anywhere on the analysis of the nights and recordings? Later
we'll have hundreds of days and want to understand where stuff comes from". DECISIONS 760-769; every table and column
is in docs/data-format.md ("The data book"). It reads `_local/` and writes only into --out (default `_local/data/`):

  nights.tsv     one row per night or nap and per sleep report of it (the laptop's, the phone's), `counts` marks the
                 one that counts; stages, the dream sleep check, contact, signal quality, batteries, the morning rating,
                 the model and the second opinion, and every source file with its SHA-256
  sessions.tsv   work (phone and laptop), meditation, alpha-theta, nap coach and sound sessions
  days.tsv       one row per day (04:00 to 04:00): sleep (the nights that count), the check-in, work, focus on the laptop
  epochs.tsv.gz  one row per 30 s of every recording: stage and probabilities, band mix and quality per channel, jaw
                 and movement (analysis/epoch_signal.py)
  labels.tsv     append-only, one row per label from eeg_tracker's own stores (Archive tags, auto-start answers,
                 work-session hints and taps, markers, the tray's answers, check-in answers)
  truth.tsv      what really happened, typed (scripts/truth.py): the hand file, <local>/truth/*.tsv and the Archive
                 tags marked "This is what I was doing"; scripts/validate_detectors.py scores the detectors against it
  README.md, book.json   what is there, how it was built (versions, row counts, time)

Built from the files alone, so it can always be built again (delete the folder and run this); nothing reads it back
as input, and it never edits or deletes anything in `_local/` outside --out. Incremental: a recording's 30 s rows are
worked out again only when its files, its sleep report or the signal pass's version changed (`.cache/`); the other
tables are rebuilt whole from small files each run, so a run without new recordings takes seconds. A rebuild never
mixes versions: each row names the model and the detector version it was made with, and a changed one recomputes.

Channels are always the recording's own (its `<stamp>.header.json`, scripts/recording.py): per-channel columns are
named after them, so a helmet's 8-16 channels at custom positions get their own columns. One run at a time (a lock).
The phone link's after-pull jobs run it (scripts/after_pull.py).
"""
from __future__ import annotations

import argparse, fcntl, gzip, hashlib, io, json, os, sys, time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable, Iterable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "analysis"))
import battery  # noqa: E402  (the headband gauge's one rule, DECISIONS 766)
import catalog  # noqa: E402  (which files make up a night, and its hashing)
import day_summary as ds  # noqa: E402  (the 04:00 day, the Trends numbers)
import night_files as nf  # noqa: E402
import packed  # noqa: E402
import phone_night_check as pnc  # noqa: E402  (the recorders' log lines, batteries, contact)
import recording  # noqa: E402
import rem_check as rc  # noqa: E402  (the dream sleep check; standard library part)
import truth  # noqa: E402  (the truth labels' schema and sources, DECISIONS 820-829)

FORMAT, VERSION = "eeg-tracker-data-book", 1  # VERSION: of the tables' columns (docs/data-format.md)
NAP_MAX_MIN = 180  # a sleep with under 3 hours asleep (or recorded, when unscored) is a nap (DECISIONS 761)
MIN_RUN_MIN = 10  # contact at the start: the first reading of a run that recorded this long (as the night check)
STAGE = {"W": "W", "1": "N1", "2": "N2", "3": "N3", "R": "R", "-": "gap"}
PROB_KEYS = ("p_W", "p_N1", "p_N2", "p_N3", "p_R")
QUALITY_WORD = {"g": "good", "d": "degraded", "m": "missing"}
DEFAULT_LOCAL = ROOT / "_local"
TABLES = ("nights.tsv", "sessions.tsv", "days.tsv", "epochs.tsv.gz", "labels.tsv", "truth.tsv")


# ---- cells and files ------------------------------------------------------------------------------------------------

def cell(v: object) -> str:
    """One TSV cell: empty for None, 1/0 for a flag, a float without trailing zeros, text without tabs or newlines."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return ""
        s = f"{v:.3f}".rstrip("0").rstrip(".")
        return "0" if s == "-0" else s
    return str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def tsv(columns: list[str], rows: Iterable[dict]) -> str:
    return "\t".join(columns) + "\n" + "".join("\t".join(cell(r.get(c)) for c in columns) + "\n" for r in rows)


def _write(path: Path, data: bytes) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _gz(text: str) -> bytes:
    """One gzip member with no time in it, so the same rows give the same bytes."""
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, compresslevel=6) as g:
        g.write(text.encode("utf-8"))
    return buf.getvalue()


def _json(p: Path) -> object:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def iso(t: object) -> str | None:
    """An ISO time with its UTC offset, to the second: from a datetime, unix seconds or ISO text (no offset: local)."""
    if t is None:
        return None
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")
    d = t if isinstance(t, datetime) else ds.parse_time(t)
    if d is None:
        return None
    return (d if d.tzinfo else d.astimezone()).isoformat(timespec="seconds")


def _num(v: object) -> float | None:
    return ds._num(v)  # noqa: SLF001 - the same numbers rule as the Trends days


def _r(v: float | None, k: int = 1) -> float | None:
    return None if v is None else round(v, k)


def digest_lines(pairs: Iterable[tuple[str, str]]) -> str:
    """SHA-256 of `path sha256` lines, sorted: one hash for a row's sources (the same files give the same hash)."""
    return hashlib.sha256("".join(f"{p} {s}\n" for p, s in sorted(set(pairs))).encode()).hexdigest()


def sources_text(pairs: Iterable[tuple[str, str]]) -> str:
    return " ".join(f"{p}={s}" for p, s in sorted(set(pairs)))


class Hashes:
    """SHA-256 of files under `local`, kept between runs by size and modified time (`.cache/hashes.json`). A raw `.f32`
    is known by its plain name and the SHA-256 of its samples, packed or not, so packing it changes nothing."""

    def __init__(self, local: Path, store: Path) -> None:
        self.local, self.store = local, store
        old = _json(store)
        self.old: dict[str, list] = old.get("files", {}) if isinstance(old, dict) else {}
        self.now: dict[str, list] = {}

    def _cached(self, key: str, p: Path, work: Callable[[], str]) -> str | None:
        try:
            st = p.stat()
        except OSError:
            return None
        hit = self.old.get(key) or self.now.get(key)
        if hit and hit[0] == st.st_size and hit[1] == st.st_mtime_ns:
            self.now[key] = hit
            return hit[2]
        sha = work()
        self.now[key] = [st.st_size, st.st_mtime_ns, sha]
        return sha

    def sha(self, rel: str) -> str | None:
        p = self.local / rel
        return self._cached(rel, p, lambda: catalog.digest(p, p.stat().st_size)[0])

    def content(self, rel: str) -> str | None:
        """The samples' SHA-256 of a raw .f32 given by its plain name, packed or not."""
        d = packed.on_disk(self.local / rel)
        if d is None:
            return None
        if not packed.is_packed(d):
            return self.sha(rel)

        def unpack() -> str:
            o = packed.info(d)
            return o.sha256 if o.sha256 else packed.unpacked(d).sha256 or ""
        return self._cached("content:" + d.relative_to(self.local).as_posix(), d, unpack)

    def save(self) -> None:
        self.store.parent.mkdir(parents=True, exist_ok=True)
        _write(self.store, json.dumps(dict(version=1, files=self.now), separators=(",", ":")).encode())


# ---- sleep reports --------------------------------------------------------------------------------------------------

@dataclass
class Report:
    night: str
    source: str  # laptop | phone
    rel: str  # from local
    data: dict
    sha: str
    rank: int  # 0 the laptop's in nights/, 1 a laptop report kept in analyses/, 2 the phone's

    @property
    def scored(self) -> bool:
        return self.data.get("scored") is True


def _is_report(r: object) -> bool:
    return (isinstance(r, dict) and isinstance(r.get("night_of"), str) and isinstance(r.get("total"), dict)
            and isinstance(r.get("periods"), list) and ds.parse_time(r.get("data_start")) is not None
            and ds.parse_time(r.get("data_end")) is not None)


def read_reports(local: Path, hashes: Hashes) -> dict[str, list[Report]]:
    """Every sleep report by night, the one that counts first: scored before unscored, then the laptop's in nights/,
    a laptop report kept by hand in analyses/ (the assistant scored a night there with sleep_report.py's code), the
    phone's (DECISIONS 762)."""
    out: dict[str, list[Report]] = defaultdict(list)
    for rank, source, folder in ((0, "laptop", "nights"), (1, "laptop", "analyses"), (2, "phone", "phone/nights")):
        for p in sorted((local / folder).glob("*.report.json")):
            r = _json(p)
            if not _is_report(r) or (rank != 1 and p.name[: -len(".report.json")] != r["night_of"]):
                continue
            rel = p.relative_to(local).as_posix()
            out[r["night_of"]].append(Report(r["night_of"], source, rel, r, hashes.sha(rel) or "", rank))
    for reps in out.values():  # two kept by hand for one night: the earlier start counts, so no sample is dropped from
        reps.sort(key=lambda x: (not x.scored, x.rank, ds.parse_time(x.data["data_start"]), x.rel))  # the 30 s rows
    return out


def sleep_json_of(rep: Report, local: Path) -> str | None:
    """The `<night>.sleep.json` beside a laptop report (path from local): a copy kept by hand under the report's own
    name first (`2026-11-20-awake-truth.sleep.json` beside `2026-11-20-awake-truth.report.json`), else the one the
    report names. None when neither is there."""
    folder = Path(rep.rel).parent
    names = [Path(rep.rel).name[: -len(".report.json")] + ".sleep.json"]
    name = rep.data.get("sleep_json")
    if isinstance(name, str) and "/" not in name:
        names.append(name)
    for n in names:
        if (local / folder / n).is_file():
            return (folder / n).as_posix()
    return None


def wearer_of(reps: list[Report]) -> str | None:
    """`me` / `someone else` from either copy's "Was this you?" answer; someone else wins (as the Trends days)."""
    answers = {w for r in reps if (w := ds._wearer(r.data))}  # noqa: SLF001
    return ds.SOMEONE_ELSE if ds.SOMEONE_ELSE in answers else (next(iter(answers)) if answers else None)


def stages_of(rep: Report, local: Path, hashes: Hashes) -> tuple[list[str] | None, list[list[int]] | None,
                                                                   list[tuple[str, str]]]:
    """The report's stages (W N1 N2 N3 R gap per 30 s from `data_start`) and AnySleep's probabilities in permille,
    from the report itself, else (an older laptop report) from the `<night>.sleep.json` beside it; and the files read
    besides the report."""
    st = rc.stages_of(rep.data.get("stages"))
    if st is not None:
        return st, rc.decode_probs(rep.data.get("probs")), []
    rel = sleep_json_of(rep, local) if rep.scored else None
    if rel is None:
        return None, None, []
    j = _json(local / rel)
    ep = j.get("epochs") if isinstance(j, dict) else None
    if not isinstance(ep, list) or not ep:
        return None, None, []
    stages = [e.get("anysleep") if isinstance(e, dict) and e.get("anysleep") in rc.ASLEEP + ("W", rc.GAP) else rc.GAP
              for e in ep]
    probs = []
    for e in ep:
        p = e.get("p") if isinstance(e, dict) else None
        probs.append([rc.permille(float(v)) for v in p] if isinstance(p, list) and len(p) == 5 else None)
    return stages, (probs if all(p is not None for p in probs) else None), [(rel, hashes.sha(rel) or "")]


# ---- recordings and their 30 s rows ---------------------------------------------------------------------------------

@dataclass
class Group:
    """One recording as the book counts it: a night (night_files.py's chain, the catalog's row) or one file set of a
    session that is no night (a work session's raw EEG, a check-in's visit)."""
    id: str
    kind: str  # night | nap | diy | work | checkin | the header's session word
    f32: list[str]  # plain .f32 paths from local, with samples
    logs: list[str]
    night: dict | None = None  # the catalog's row
    reports: list[Report] = field(default_factory=list)
    start: float = 0.0


RAW_FOLDERS = ("recordings/", "recordings-diy/")


def _with_samples(local: Path, rel: str) -> bool:
    try:
        return packed.size(local / rel) >= recording.read(local / rel).record_bytes
    except (OSError, recording.RecordingError):
        return False


def groups_of(local: Path, nights: list[dict], reports: dict[str, list[Report]], problems: list[str]) -> list[Group]:
    out = []
    for row in nights:
        if not row["raw"]:
            continue
        f32, logs = set(), set()
        for rel, kind in row["paths"]:
            if not rel.startswith(RAW_FOLDERS) or kind != "raw":
                continue
            if rel.endswith((packed.RAW, *packed.PACKED_FORMS)):
                f32.add(packed.logical(Path(rel)).as_posix())
            elif rel.endswith(".log"):
                logs.add(rel)
        f32s = sorted(r for r in f32 if _with_samples(local, r))
        if f32s:
            out.append(Group(row["id"], "diy" if row["source"] == "diy" else "night", f32s, sorted(logs), row,
                             reports.get(row["id"], []), row["start"] or 0.0))
    for folder, kind in (("recordings", None), ("recordings-diy", None), ("phone/mornings", "checkin")):
        for p in packed.raw_files(local / folder):
            try:
                h = recording.read(p)
            except recording.RecordingError as e:
                problems.append(str(e))
                continue
            if kind is None and h.is_sleep:
                continue
            rel = p.relative_to(local).as_posix()
            if not _with_samples(local, rel):
                continue
            log = p.with_suffix(".log")
            out.append(Group(p.stem, kind or str(h.session), [rel],
                             [log.relative_to(local).as_posix()] if log.is_file() else [],
                             start=nf.stamp_time(p) or 0.0))
    return sorted(out, key=lambda g: (g.start, g.id))


def night_kind(rep: Report | None, recorded_min: float | None) -> str:
    """night or nap by length (DECISIONS 761): under 3 hours asleep, or under 3 hours recorded when unscored."""
    if rep is not None and rep.scored:
        return "nap" if (_num(rep.data["total"].get("asleep_min")) or 0) < NAP_MAX_MIN else "night"
    return "nap" if (recorded_min or 0) < NAP_MAX_MIN else "night"


def epoch_inputs(g: Group, local: Path, hashes: Hashes, rep: Report | None, extra: list[tuple[str, str]]
                 ) -> list[tuple[str, str]]:
    pairs = []
    for rel in g.f32:
        pairs.append((rel, hashes.content(rel) or ""))
        for suffix in (".idx", recording.SUFFIX):
            side = rel[: -len(packed.RAW)] + suffix
            if (local / side).is_file():
                pairs.append((side, hashes.sha(side) or ""))
    if rep is not None:
        pairs.append((rep.rel, rep.sha))
    return pairs + extra


def _layout(h: recording.Header) -> str:
    def one(c: recording.Channel) -> str:
        if c.site:
            return f"{c.name}:{c.site}"
        if c.xyz:
            return f"{c.name}:({','.join(f'{v:g}' for v in c.xyz)})"
        return c.name
    return (f"{h.device or h.layout or '?'}: " if (h.device or h.layout) else "") + " ".join(one(c) for c in h.channels)


BASE_EPOCH_COLUMNS = ["recording", "kind", "epoch", "start", "stage", *PROB_KEYS, "model", "quality", "jaw", "moves",
                      "movement_s", "muscle_s", "channels", "signal_version", "inputs_sha256"]
CHANNEL_MEASURES = ("delta_pct", "theta_pct", "alpha_pct", "beta_pct", "quality")


def compute_epochs(g: Group, local: Path, rep: Report | None, stages: list[str] | None,
                   probs: list[list[int]] | None, inputs: str) -> tuple[list[dict], list[str], dict]:
    """The 30 s rows of one recording, its channel names, and what the night extras need (quality, bursts, moves)."""
    import epoch_signal as es  # numpy and scipy: only when a recording is worked out
    import to_bdf

    paths = [local / r for r in g.f32]
    head = to_bdf.night_header(paths)
    start, uv, notes = to_bdf.join(paths)
    fs = head.sample_rate
    miss = es.missing_mask(len(uv), notes, fs)
    origin = ds.parse_time(rep.data["data_start"]) if rep is not None else None
    origin = origin or start.astimezone()
    uv, miss = es.align(uv, miss, start.astimezone(), origin, fs)
    sig = es.run(uv, miss, head)
    del uv
    model = rep.data.get("model") if rep is not None and stages is not None else None
    n = max(sig.n, len(stages or []))
    rows = []
    layout = _layout(head)
    for e in range(n):
        row: dict = dict(recording=g.id, kind=g.kind, epoch=e, start=iso(origin + timedelta(seconds=es.EPOCH_S * e)),
                         channels=layout, signal_version=es.VERSION, inputs_sha256=inputs)
        if stages is not None and e < len(stages):
            row.update(stage=stages[e], model=model)
            if probs is not None and e < len(probs) and probs[e] is not None:
                row.update({k: probs[e][i] / 1000 for i, k in enumerate(PROB_KEYS)})
        if e < sig.n:
            row.update(quality=sig.quality[e], jaw=sig.jaw[e], moves=sig.moves[e], movement_s=sig.movement_s[e],
                       muscle_s=sig.muscle_s[e])
            for c, name in enumerate(sig.channels):
                for b, _, _ in es.BANDS:
                    v = sig.bands[b][e, c]
                    row[f"{name}_{b}_pct"] = None if v != v else round(float(v), 1)
                row[f"{name}_quality"] = sig.channel_quality[e][c]
        rows.append(row)
    extras = dict(quality="".join(sig.quality), detectors=sig.detectors, bursts=sig.bursts, spans=sig.spans,
                  origin=iso(origin), fs=fs, channels=list(head.names))
    return rows, list(head.names), extras


class EpochStore:
    """`.cache/epochs/<id>.json` (what a recording's rows were made from), `<id>.rows.json.gz` (the rows) and
    `<id>.body.gz` (the rows as TSV for the columns of the last book), so an unchanged recording is copied as it is."""

    def __init__(self, folder: Path) -> None:
        self.folder = folder
        folder.mkdir(parents=True, exist_ok=True)

    def _name(self, gid: str) -> str:
        return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in gid)

    def meta(self, gid: str) -> dict | None:
        m = _json(self.folder / f"{self._name(gid)}.json")
        return m if isinstance(m, dict) else None

    def rows(self, gid: str) -> list[dict]:
        with gzip.open(self.folder / f"{self._name(gid)}.rows.json.gz", "rt", encoding="utf-8") as f:
            return json.load(f)

    def put(self, gid: str, meta: dict, rows: list[dict]) -> None:
        _write(self.folder / f"{self._name(gid)}.rows.json.gz", _gz(json.dumps(rows, separators=(",", ":"))))
        (self.folder / f"{self._name(gid)}.body.gz").unlink(missing_ok=True)
        _write(self.folder / f"{self._name(gid)}.json", json.dumps(meta, separators=(",", ":")).encode())

    def body(self, gid: str, columns: list[str]) -> bytes:
        key = hashlib.sha256("\t".join(columns).encode()).hexdigest()
        m = self.meta(gid) or {}
        p = self.folder / f"{self._name(gid)}.body.gz"
        if m.get("body_columns") == key and p.is_file():
            return p.read_bytes()
        rows = self.rows(gid)
        data = _gz("".join("\t".join(cell(r.get(c)) for c in columns) + "\n" for r in rows))
        _write(p, data)
        m["body_columns"] = key
        _write(self.folder / f"{self._name(gid)}.json", json.dumps(m, separators=(",", ":")).encode())
        return data

    def drop_others(self, keep: set[str]) -> None:
        names = {self._name(g) for g in keep}
        for p in self.folder.iterdir():
            if p.name.split(".", 1)[0] not in names:
                p.unlink()


def epochs_pass(groups: list[Group], local: Path, hashes: Hashes, store: EpochStore, full: bool, say: Callable,
                problems: list[str]) -> tuple[dict[str, dict], int]:
    """Every recording's rows, worked out again only when its inputs or the versions changed; returns each group's
    meta (with its extras) and how many were worked out."""
    import epoch_signal as es

    metas: dict[str, dict] = {}
    done = 0
    for g in groups:
        rep = g.reports[0] if g.reports else None
        if rep is not None:
            g.kind = night_kind(rep, _num(rep.data["total"].get("recorded_min"))) if g.kind == "night" else g.kind
        elif g.kind == "night":
            g.kind = night_kind(None, (g.night or {}).get("hours_recorded", 0) * 60)
        stages, probs, extra = stages_of(rep, local, hashes) if rep is not None else (None, None, [])
        inputs = digest_lines(epoch_inputs(g, local, hashes, rep, extra))
        old = store.meta(g.id)
        want = dict(book=VERSION, signal=es.VERSION, inputs=inputs, kind=g.kind)
        if not full and old and all(old.get(k) == v for k, v in want.items()):
            metas[g.id] = old
            continue
        t0 = time.time()
        try:
            rows, names, extras = compute_epochs(g, local, rep, stages, probs, inputs)
        except (recording.RecordingError, OSError, ValueError, SystemExit) as e:
            problems.append(f"{g.id}: no 30 s rows ({type(e).__name__}: {e})")
            continue
        meta = dict(want, id=g.id, rows=len(rows), channels=names, model=rows[0].get("model") if rows else None,
                    start=rows[0]["start"] if rows else None, extras=extras, made=iso(time.time()),
                    seconds=round(time.time() - t0, 1))
        store.put(g.id, meta, rows)
        metas[g.id] = meta
        done += 1
        say(f"  {g.id} ({g.kind}): {len(rows)} rows of 30 s in {time.time() - t0:.1f} s")
    store.drop_others({g.id for g in groups if g.id in metas})
    return metas, done


def write_epochs(out: Path, groups: list[Group], metas: dict[str, dict], store: EpochStore) -> tuple[int, list[str]]:
    """epochs.tsv.gz: a header member, then each recording's rows as their own gzip member (any gzip reader reads them
    as one file). Channel columns in the order their names first appear."""
    names: list[str] = []
    for g in groups:
        for n in (metas.get(g.id) or {}).get("channels", []):
            if n not in names:
                names.append(n)
    columns = BASE_EPOCH_COLUMNS + [f"{n}_{m}" for n in names for m in CHANNEL_MEASURES]
    parts = [_gz("\t".join(columns) + "\n")]
    rows = 0
    for g in groups:
        if g.id in metas:
            parts.append(store.body(g.id, columns))
            rows += metas[g.id]["rows"]
    _write(out / "epochs.tsv.gz", b"".join(parts))
    return rows, columns


# ---- nights.tsv -----------------------------------------------------------------------------------------------------

NIGHT_COLUMNS = [
    "night", "kind", "source", "counts", "scored", "wearer", "start", "end", "sleep_start", "sleep_end",
    "recorded_min", "missing_min", "in_bed_min", "asleep_min", "light_min", "deep_min", "dream_min",
    "awake_in_sleep_min", "wake_ups", "periods", "efficiency_pct", "fall_asleep_min", "lights_off_from",
    "drift_detector_min", "drift_agree",
    "rem_share_pct", "first_rem_min", "rem_third1_min", "rem_third2_min", "rem_third3_min", "rem_prob_min",
    "eye_pair", "eye_in_rem_pct", "eye_rem_epochs_pct", "eye_rem_per_min", "eye_other_per_min", "rem_check_from",
    "good_pct", "degraded_pct", "missing_pct", "asleep_noisy_pct", "jaw_per_h", "moves_per_h", "extras_from",
    "contact_at",
    # contact_<channel>_ohm columns go here, one per channel name (from the recordings' headers and logs)
    "band_battery_start_pct", "band_battery_end_pct", "band_stuck_at", "band_end_est_pct", "band_streamed_h",
    "phone_battery_start_pct", "phone_battery_end_pct", "phone_cost_mah_h", "phone_cost_pct_h", "phone_steady_h",
    "battery_rule",
    "slept_rating", "checkin", "model", "second_opinion", "agree_5_stage_pct", "agree_w_nrem_rem_pct",
    "report_file", "report_sha256", "raw_files", "inputs_sha256", "sources",
]


def _pct(part: object, whole: object) -> float | None:
    a, b = _num(part), _num(whole)
    return None if a is None or not b else round(a / b * 100, 1)


def log_numbers(g: Group | None, local: Path, hashes: Hashes, cache: Path) -> dict:
    """Contact at the start and the batteries from a recording's logs (the recorders' lines, read as
    scripts/phone_night_check.py reads them, by battery.py's one rule); cached by the logs' hashes."""
    if g is None or not g.logs:
        return {}
    rules = f"{battery.RULE}; {pnc.PHONE_COST_RULE}"
    key = digest_lines([(rel, hashes.sha(rel) or "") for rel in g.logs] + [("rules", rules)])
    f = cache / f"{''.join(ch if ch.isalnum() or ch in '-_' else '_' for ch in g.id)}.logs.json"
    hit = _json(f)
    if isinstance(hit, dict) and hit.get("key") == key:
        return hit["numbers"]
    evs = []
    for rel in g.logs:
        try:
            text = (local / rel).read_text(errors="replace")
        except OSError:
            continue
        evs += pnc.parse_log(text, Path(rel).stem)[0]
    evs.sort(key=lambda e: e.t)
    bat = pnc.battery_numbers(evs)
    long = set()
    for rel in g.f32:
        try:
            h = recording.read(local / rel)
            if packed.size(local / rel) // h.record_bytes >= MIN_RUN_MIN * 60 * h.sample_rate:
                long.add(Path(rel).stem)
        except (OSError, recording.RecordingError):
            continue
    readings = [(e.t, pnc.parse_ohms(e.g["ohms"]), e.stem) for e in evs if e.kind == "contact"]
    first = next((r for r in readings if r[2] in long), readings[0] if readings else None)
    band, phone = bat["band"], bat["phone"]
    est = band["estimate"] if band else None
    steady = phone["steady"] if phone else None
    nums = dict(
        contact_at=iso(first[0]) if first else None,
        contact={k: (None if v is None or v != v or v == float("inf") else round(v)) for k, v in first[1].items()}
        if first else {},
        band_battery_start_pct=band["first"] if band else None, band_battery_end_pct=band["last"] if band else None,
        band_stuck_at=" ".join(str(v) for v in band["stuck_at"]) if band and band["stuck"] else None,
        band_end_est_pct=est["pct"] if est else None, band_streamed_h=est["hours"] if est else None,
        phone_battery_start_pct=phone["first"] if phone else None, phone_battery_end_pct=phone["last"] if phone else None,
        phone_cost_mah_h=_r(steady["mah_per_hour"], 0) if steady else None,
        phone_cost_pct_h=_r(steady["per_hour"], 2) if steady else None,
        phone_steady_h=_r(steady["hours"], 1) if steady else None, battery_rule=rules if band or phone else None)
    cache.mkdir(parents=True, exist_ok=True)
    _write(f, json.dumps(dict(key=key, numbers=nums)).encode())
    return nums


def _drift(r: dict) -> dict:
    d = r.get("drift_off") if isinstance(r.get("drift_off"), dict) else None
    if not d:
        return {}
    return dict(fall_asleep_min=_num(d.get("model_onset_min")), lights_off_from=d.get("source"),
                drift_detector_min=_num(d.get("onset_min")),
                drift_agree=d.get("agree") if isinstance(d.get("agree"), bool) else None)


def _rem(rep: Report, stages: list[str] | None, probs: list[list[int]] | None) -> dict:
    """The dream sleep check: the report's own, else the stage-only check worked out here (DECISIONS 763)."""
    c, src = rc.check_of_report(rep.data), "report"
    if c is not None and "rem_check" not in rep.data:
        src = "stage-only, worked out from the report"
    if c is None and stages is not None and rep.scored:
        c, src = rc.night_check(stages, rc.periods_of(rep.data), probs, None), "stage-only, from the sleep.json"
    if c is None:
        return {}
    thirds = c.get("thirds_rem_min") or [None, None, None]
    eye = c.get("eye") or {}
    share = c.get("rem_share")
    return dict(rem_share_pct=None if share is None else round(share * 100, 1), first_rem_min=c.get("first_rem_min"),
                rem_third1_min=thirds[0], rem_third2_min=thirds[1], rem_third3_min=thirds[2],
                rem_prob_min=c.get("rem_prob_min"), eye_pair=eye.get("pair"),
                eye_in_rem_pct=_pct(eye.get("in_rem_share"), 1), eye_rem_epochs_pct=_pct(eye.get("rem_epoch_share"), 1),
                eye_rem_per_min=eye.get("rem_per_min"), eye_other_per_min=eye.get("other_per_min"),
                rem_check_from=src)


def _extras(rep: Report, meta: dict | None, stages: list[str] | None) -> dict:
    """Signal quality, jaw and movement: the report's `extras`, else the same night_extras rules over the book's own
    signal pass (only where the shared detectors ran)."""
    x = rep.data.get("extras") if isinstance(rep.data.get("extras"), dict) else None
    src = "report"
    if x is None and meta and stages is not None and (meta.get("extras") or {}).get("detectors") and rep.scored:
        import night_extras as nx
        e = meta["extras"]
        q = [QUALITY_WORD[c] for c in e["quality"]]
        st = (stages + [rc.GAP] * len(q))[: len(q)]
        start = ds.parse_time(rep.data["data_start"])
        x = nx.summary(q, [tuple(b) for b in e["bursts"]], [tuple(s) for s in e["spans"]], st,
                       rc.periods_of(rep.data), nx.first_edge_s(start))
        src = f"worked out here (night extras v{nx.VERSION} rules over {meta.get('signal')})"
    if x is None:
        return {}
    night, asleep = x.get("night") or {}, x.get("asleep") or {}
    noisy = (_num(asleep.get("degraded_min")) or 0) + (_num(asleep.get("missing_min")) or 0)
    return dict(good_pct=_pct(night.get("good_min"), night.get("min")),
                degraded_pct=_pct(night.get("degraded_min"), night.get("min")),
                missing_pct=_pct(night.get("missing_min"), night.get("min")),
                asleep_noisy_pct=_pct(noisy, asleep.get("min")), jaw_per_h=_num(asleep.get("jaw_per_hour")),
                moves_per_h=_num(asleep.get("moves_per_hour")), extras_from=src)


def _morning(row: dict | None, local: Path, hashes: Hashes) -> tuple[dict, list[tuple[str, str]]]:
    """The check-in after the night (the catalog's attachment): the first one's file and the first sleep rating."""
    files = (row or {}).get("morning") or []
    out: dict = dict(checkin=files[0] if files else None)
    pairs = []
    for rel in files:
        j = _json(local / rel)
        pairs.append((rel, hashes.sha(rel) or ""))
        v = ds._int_in((j.get("ratings") or {}).get("sleep"), 1, 5) if isinstance(j, dict) else None  # noqa: SLF001
        if v is not None and out.get("slept_rating") is None:
            out["slept_rating"] = v
    return out, pairs


def night_rows(local: Path, nights: list[dict], reports: dict[str, list[Report]], groups: list[Group],
               metas: dict[str, dict], hashes: Hashes, cache: Path) -> tuple[list[dict], list[str]]:
    by_id = {g.id: g for g in groups}
    rows, contact_names = [], []
    for nrow in nights:
        g = by_id.get(nrow["id"])
        reps = reports.get(nrow["id"], [])
        logs = log_numbers(g, local, hashes, cache)
        for name in (logs.get("contact") or {}):
            if name not in contact_names:
                contact_names.append(name)
        morning, mpairs = _morning(nrow, local, hashes)
        raw = []
        if g is not None:
            raw = [(rel, hashes.content(rel) or "") for rel in g.f32] + [(rel, hashes.sha(rel) or "") for rel in g.logs]
        wearer = wearer_of(reps)
        for i, rep in enumerate(reps or [None]):
            base: dict = dict(night=nrow["id"], counts=i == 0, wearer=wearer, raw_files=len(g.f32) if g else 0,
                              **{k: v for k, v in logs.items() if k != "contact"}, **morning)
            base.update({f"contact_{k}_ohm": v for k, v in (logs.get("contact") or {}).items()})
            pairs = raw + mpairs
            if rep is None:
                base.update(source=nrow["source"], scored=False, start=iso(nrow["start"]), end=iso(nrow["end"]),
                            recorded_min=_r(nrow["hours_recorded"] * 60), missing_min=nrow["minutes_missing"],
                            kind=night_kind(None, nrow["hours_recorded"] * 60))
            else:
                stages, probs, extra = stages_of(rep, local, hashes)
                pairs += [(rep.rel, rep.sha)] + extra
                base.update(_report_numbers(rep, stages, probs, metas.get(nrow["id"])))
            base.update(inputs_sha256=digest_lines(pairs), sources=sources_text(pairs))
            rows.append(base)
    return rows, contact_names


def _report_numbers(rep: Report, stages: list[str] | None, probs: list[list[int]] | None, meta: dict | None) -> dict:
    r, t = rep.data, rep.data["total"]
    periods = [p for p in r["periods"] if isinstance(p, dict) and ds.parse_time(p.get("start"))
               and ds.parse_time(p.get("end"))]
    drift = r.get("drift_off") if isinstance(r.get("drift_off"), dict) else None
    stay = ds._timing(r, drift) if periods else None  # noqa: SLF001 - the Trends' time in bed
    in_bed = stay[2] if stay else None
    asleep = _num(t.get("asleep_min"))
    cross = r.get("cross_check") if isinstance(r.get("cross_check"), dict) else {}
    out = dict(
        kind=night_kind(rep, _num(t.get("recorded_min"))), source=rep.source, scored=rep.scored,
        start=iso(r["data_start"]), end=iso(r["data_end"]),
        sleep_start=iso(min((p["start"] for p in periods), default=None, key=lambda s: ds.parse_time(s))),
        sleep_end=iso(max((p["end"] for p in periods), default=None, key=lambda s: ds.parse_time(s))),
        recorded_min=_num(t.get("recorded_min")), missing_min=_num(t.get("missing_min")), in_bed_min=_r(in_bed),
        asleep_min=asleep, light_min=_num(t.get("light_min")), deep_min=_num(t.get("deep_min")),
        dream_min=_num(t.get("dream_min")), awake_in_sleep_min=sum(_num(p.get("awake_min")) or 0 for p in periods),
        wake_ups=t.get("wake_ups"), periods=t.get("periods"),
        efficiency_pct=_r(min(100.0, asleep / in_bed * 100)) if asleep is not None and in_bed
        and in_bed >= ds.EFFICIENCY_MIN_IN_BED else None,
        model=r.get("model"), second_opinion=cross.get("model"),
        agree_5_stage_pct=_pct(cross.get("agreement_5_stage"), 1),
        agree_w_nrem_rem_pct=_pct(cross.get("agreement_w_nrem_rem"), 1),
        report_file=rep.rel, report_sha256=rep.sha)
    if rep.scored:
        out.update(_drift(r))
        out.update(_rem(rep, stages, probs))
        out.update(_extras(rep, meta, stages))
    return out


# ---- sessions.tsv ---------------------------------------------------------------------------------------------------

SESSION_COLUMNS = [
    "session", "kind", "start", "end", "minutes", "ended", "started_by", "wearer", "worn_min", "usable_min",
    "talking_min", "meeting_min", "drowsy_min", "eyes_closed_min", "active_min", "settled_min", "asleep_min",
    "breaks", "break_min", "hints", "hints_taken", "sharp_mean", "rating", "plan", "raw", "detector_version",
    "file", "file_sha256",
]
READ_LEVELS, DROWSY_LEVELS = {"alert", "getting_drowsy", "drowsy"}, {"getting_drowsy", "drowsy"}


def _span_min(a: object, b: object) -> float | None:
    x, y = ds.parse_time(a), ds.parse_time(b)
    return None if x is None or y is None else round((y - x).total_seconds() / 60, 1)


def _breaks(j: dict, end: datetime | None) -> tuple[list[tuple[datetime, datetime]], float]:
    out = []
    for b in j.get("breaks") if isinstance(j.get("breaks"), list) else []:
        a = ds.parse_time(b.get("start")) if isinstance(b, dict) else None
        if a is not None:
            out.append((a, ds.parse_time(b.get("end")) or end or a))
    return out, round(sum((b - a).total_seconds() for a, b in out) / 60, 1)


def _phone_work(j: dict) -> dict:
    """A phone work session (docs/data-format.md "Work sessions"): the Trends' readable and drowsy half minutes
    outside breaks and closed eyes; talking = the detectors' muscle seconds (talking, chewing) outside breaks."""
    start, end = ds.parse_time(j.get("start")), ds.parse_time(j.get("end"))
    brk, brk_min = _breaks(j, end)
    usable = drowsy = 0
    muscle = 0.0
    for e in j.get("epochs") if isinstance(j.get("epochs"), list) else []:
        if not isinstance(e, dict) or start is None:
            continue
        t = ds._epoch_time(e, start)  # noqa: SLF001
        if t is None or any(a <= t < b for a, b in brk):
            continue
        muscle += _num(e.get("muscle_s")) or 0
        if e.get("level") in READ_LEVELS and e.get("eyes_closed") is not True:
            usable += 1
            drowsy += e["level"] in DROWSY_LEVELS
    hints = [h for h in j.get("hints") or [] if isinstance(h, dict)]
    taps = [v for r in j.get("ratings") or [] if isinstance(r, dict) and (v := ds._int_in(r.get("value"), 1, 5))]  # noqa: SLF001
    minutes = j.get("minutes") if isinstance(j.get("minutes"), dict) else {}
    return dict(worn_min=_num(j.get("worn_min")), usable_min=usable / 2, drowsy_min=drowsy / 2,
                talking_min=round(muscle / 60, 1), meeting_min=_num(j.get("meeting_min")),
                eyes_closed_min=_num(minutes.get("eyes_closed")), active_min=_num(j.get("active_min")),
                breaks=len(brk), break_min=brk_min, hints=len(hints), hints_taken=sum(h.get("taken") is True for h in hints),
                sharp_mean=_r(sum(taps) / len(taps), 2) if taps else None, raw=j.get("raw"),
                detector_version=f"{j.get('app')} v{j.get('version')}")


def _laptop_work(j: dict) -> dict:
    brk, brk_min = _breaks(j, ds.parse_time(j.get("end")))
    hints = [h for h in j.get("hints") or [] if isinstance(h, dict)]
    settings = j.get("settings") if isinstance(j.get("settings"), dict) else {}
    return dict(active_min=_num(j.get("active_min")), meeting_min=_num(j.get("meeting_min")), breaks=len(brk),
                break_min=brk_min, hints=len(hints), hints_taken=sum(h.get("taken") is True for h in hints),
                started_by=j.get("started_by"),
                detector_version=f"{j.get('app')} v{j.get('version')} hint>={settings.get('hint_threshold_min')} min")


def session_rows(local: Path, hashes: Hashes) -> list[dict]:
    rows = []
    specs = (("phone/work-sessions", ".work.json", "work"), ("laptop/work", ".work.json", "laptop_work"),
             ("phone/meditations", ".meditation.json", "meditation"),
             ("phone/alpha-theta", ".alphatheta.json", "alpha_theta"), ("phone/naps", ".nap.json", "nap_coach"),
             ("phone/sound-states", ".sound.json", "sound"))
    for folder, suffix, kind in specs:
        for f in sorted((local / folder).glob("*" + suffix)):
            j = _json(f)
            if not isinstance(j, dict) or ds.parse_time(j.get("start")) is None:
                continue
            rel = f.relative_to(local).as_posix()
            row = dict(session=f.name[: -len(suffix)], kind=kind, start=iso(j.get("start")), ended=j.get("ended"),
                       wearer=ds._wearer(j), file=rel, file_sha256=hashes.sha(rel))  # noqa: SLF001
            start = ds.parse_time(j["start"])
            if kind == "work" and j.get("kind") == "work_session":
                row.update(_phone_work(j), end=iso(j.get("end")), minutes=_span_min(j.get("start"), j.get("end")))
            elif kind == "laptop_work" and j.get("kind") == "laptop_work_session":
                row.update(_laptop_work(j), end=iso(j.get("end")), minutes=_span_min(j.get("start"), j.get("end")))
            elif kind in ("meditation", "alpha_theta") and _num(j.get("runS")) is not None:
                run = _num(j["runS"]) or 0.0
                row.update(end=iso(start + timedelta(seconds=run)), minutes=round(run / 60, 1),
                           settled_min=_r((_num(j.get("settledS")) or 0) / 60),
                           drowsy_min=_r((_num(j.get("drowsyS")) or 0) / 60), ended=j.get("end"),
                           detector_version=f"{kind} summary v{j.get('version')}")
            elif kind == "nap_coach" and _num(j.get("endS")) is not None:
                stages = j.get("stages") if isinstance(j.get("stages"), str) else ""
                row.update(end=iso(start + timedelta(seconds=_num(j["endS"]) or 0)),
                           minutes=round((_num(j["endS"]) or 0) / 60, 1), ended=j.get("end"), raw=j.get("recording"),
                           asleep_min=sum(stages.count(c) for c in "123R") / 2,
                           detector_version=f"nap coach v{j.get('version')} (live stages)")
            elif kind == "sound":
                end_s = _num(j.get("endS"))
                plan = j.get("plan") if isinstance(j.get("plan"), dict) else {}
                row.update(end=iso(start + timedelta(seconds=end_s)) if end_s is not None else None,
                           minutes=_r(end_s / 60) if end_s is not None else None, ended=j.get("end"),
                           raw=j.get("recording"), rating=j.get("rating"),
                           plan=" ".join(str(plan.get(k)) for k in ("state", "bed", "beat") if plan.get(k)) or None,
                           detector_version=f"sound for states v{j.get('version')}")
            else:
                continue
            rows.append(row)
    return sorted(rows, key=lambda r: (r["start"] or "", r["session"]))


# ---- days.tsv -------------------------------------------------------------------------------------------------------

DAY_COLUMNS = [
    "day", "complete", "nights", "naps", "asleep_min", "nap_asleep_min", "light_min", "deep_min", "dream_min",
    "wake_ups", "efficiency_pct", "fall_asleep_min",
    "kss", "mood", "tension", "slept", "reaction_ms", "caffeine_cups", "alcohol_drinks", "iaf_hz", "alpha_uv2",
    "alpha_rise", "checkin_clean_pct",
    "work_sessions", "work_min", "work_drowsy_pct", "work_first_drowsy_min", "break_hints", "hints_followed",
    "work_breaks", "work_sharp", "laptop_work_min", "meeting_min",
    "sharp", "day_reaction_ms", "recall", "practice_min", "settled_pct", "focus_sessions", "focus_min", "focus_rule",
    "excluded", "measures_version", "inputs_sha256",
]
FROM_TRENDS = {"kss": "kss", "mood": "mood", "tension": "tension", "slept": "slept", "reaction_ms": "reaction",
               "caffeine_cups": "caffeine", "alcohol_drinks": "alcohol", "iaf_hz": "iaf", "alpha_uv2": "alpha",
               "alpha_rise": "rise", "work_min": "worktime", "work_drowsy_pct": "workdrowsy",
               "work_first_drowsy_min": "workfirst", "break_hints": "workhints", "hints_followed": "workfollowed",
               "work_breaks": "workbreaks", "work_sharp": "worksharp", "sharp": "sharp", "day_reaction_ms": "dayrt",
               "recall": "recall", "practice_min": "practice", "settled_pct": "settled"}


def _excluded_text(items: list[dict]) -> str | None:
    return "; ".join(" ".join(str(v) for v in (x.get("what"), x.get("id")) if v) + f": {x.get('why')}"
                     for x in items) or None


def day_rows(local: Path, nights: list[dict], sessions: list[dict], hashes: Hashes, now: datetime) -> list[dict]:
    """One row per 04:00-04:00 day: sleep from the nights.tsv rows that count (a night counts for the day you woke from
    it), the Trends' numbers for the check-in, work, sharpness and practice (scripts/day_summary.py), the laptop's work
    sessions and its ActivityWatch focus sessions (focus-*.jsonl, scripts/aw_focus.py)."""
    trends = ds.summarise(local)
    days: dict[str, dict] = defaultdict(dict)
    inputs: dict[str, set] = defaultdict(set)
    excluded: dict[str, list[dict]] = defaultdict(list)
    stays: dict[str, list] = defaultdict(list)
    for n in nights:
        if not n["counts"] or not n.get("scored"):
            continue
        end = ds.parse_time(n.get("sleep_end") or n.get("end"))
        if end is None:
            continue
        day = ds.day_key(end)
        if n.get("wearer") == ds.SOMEONE_ELSE:
            excluded[day].append(dict(what=n["kind"], id=n["night"], why=ds.SOMEONE_ELSE))
            continue
        if (n.get("asleep_noisy_pct") or 0) > ds.NOISY_NIGHT_SHARE * 100:
            excluded[day].append(dict(what=n["kind"], id=n["night"], why="noisy"))
            continue
        d = days[day]
        inputs[day].add(("night " + n["night"], n["inputs_sha256"]))
        d[n["kind"] + "s"] = d.get(n["kind"] + "s", 0) + 1
        for k in ("asleep_min", "light_min", "deep_min", "dream_min", "wake_ups"):
            if n.get(k) is not None:
                d[k] = d.get(k, 0) + n[k]
        if n["kind"] == "nap":
            d["nap_asleep_min"] = d.get("nap_asleep_min", 0) + (n.get("asleep_min") or 0)
        if n.get("lights_off_from") not in (None, "night start") and n.get("fall_asleep_min") is not None:
            d.setdefault("fall_asleep_min", n["fall_asleep_min"])
        if n.get("in_bed_min") and n["in_bed_min"] >= ds.EFFICIENCY_MIN_IN_BED and n.get("asleep_min") is not None:
            stays[day].append((n["asleep_min"], n["in_bed_min"]))
    for day, s in stays.items():
        days[day]["efficiency_pct"] = round(min(100.0, sum(a for a, _ in s) / sum(b for _, b in s) * 100), 1)
    for day in trends.all_days():
        nums = trends.numbers.get(day, {})
        for col, mid in FROM_TRENDS.items():
            if mid in nums:
                days[day][col] = round(nums[mid], 2)
        counts = trends.counts.get(day, {})
        if counts.get("work_sessions"):
            days[day]["work_sessions"] = counts["work_sessions"]
        clean = trends.quality.get(day, {}).get("checkin_clean_share")
        if clean is not None:
            days[day]["checkin_clean_pct"] = round(clean * 100, 1)
        excluded[day] += [x for x in trends.excluded.get(day, []) if x.get("what") not in ("night",)]
    for s in sessions:
        start = ds.parse_time(s["start"])
        if start is None:
            continue
        day = ds.day_key(start)
        inputs[day].add((s["file"], s["file_sha256"] or ""))
        if s["kind"] == "laptop_work" and s.get("ended") != "not_work" and s.get("active_min") is not None:
            days[day]["laptop_work_min"] = round(days[day].get("laptop_work_min", 0) + s["active_min"], 1)
        if s["kind"] in ("work", "laptop_work") and s.get("meeting_min"):
            days[day]["meeting_min"] = round(days[day].get("meeting_min", 0) + s["meeting_min"], 1)
    for f in sorted((local / "phone" / "sharp-hours").glob("focus-*.jsonl")):
        sha = hashes.sha(f.relative_to(local).as_posix()) or ""
        for j in ds._lines(f):  # noqa: SLF001
            if not (isinstance(j, dict) and j.get("version") == 1 and isinstance(j.get("day"), str)
                    and ds._int_in(j.get("sessions"), 0, 10_000) is not None):  # noqa: SLF001
                continue
            d = days[j["day"]]
            d.update(focus_sessions=j["sessions"], focus_rule=j.get("rule"), focus_min=sum(
                _num(x.get("min")) or 0 for x in j.get("list") or [] if isinstance(x, dict)))
            inputs[j["day"]].add((f.relative_to(local).as_posix(), sha))
    for m in ds.read_mornings(local):
        rel = m["_file"].relative_to(local).as_posix()
        inputs[ds.day_key(m["_start"])].add((rel, hashes.sha(rel) or ""))
    today = ds.day_key(now)
    out = []
    for day in sorted(days):
        d = days[day]
        d.update(day=day, complete=day < today, excluded=_excluded_text(excluded.get(day, [])),
                 measures_version=ds.MEASURES_VERSION, inputs_sha256=digest_lines(inputs[day]))
        out.append(d)
    return out


# ---- labels.tsv (append-only) ---------------------------------------------------------------------------------------

LABEL_COLUMNS = ["id", "start", "end", "kind", "value", "unit", "source", "how_asked", "app_guess",
                 "detector_version", "answered", "origin", "replaces", "added"]


def _lid(store: str, obj: object) -> str:
    """`<store>:` + the first 16 hex of the SHA-1 of the source record as written (stable across runs)."""
    return f"{store}:{hashlib.sha1(json.dumps(obj, sort_keys=True).encode()).hexdigest()[:16]}"


def _label(store: str, obj: object, origin: str, **kw: object) -> dict:
    return dict(id=_lid(store, obj), source=store, origin=origin, **kw)


def _marker_how(text: str) -> tuple[str, str | None]:
    """Who wrote a marker: the owner's tap, or a detector (its version), or the app."""
    if text == "lights off" or "(tapped)" in text:
        return "own tap", None
    if text.startswith("drift-off"):
        return "detector", "drift-off detector (DECISIONS 88)"
    if text.startswith("work: ") or text.startswith("hands-free"):
        return "detector", "work session" if text.startswith("work") else "hands-free"
    return "app", None


def labels_now(local: Path) -> tuple[list[dict], set[str]]:
    """Every label in eeg_tracker's own stores now, and the stores read (a label gone from a store read now gets a
    tombstone row)."""
    out: list[dict] = []
    read: set[str] = set()
    for f in sorted((local / "phone" / "archive").glob("*.tags.json")):
        rel = f.relative_to(local).as_posix()
        j = _json(f)
        read.add(rel)
        for t in (j.get("tags") if isinstance(j, dict) else None) or []:
            if isinstance(t, dict) and ds.parse_time(t.get("start")):
                out.append(_label("archive", t, rel, start=iso(t["start"]), end=iso(t.get("end")), kind="activity",
                                  value=t.get("label"), unit="word", how_asked="own tap", answered=iso(t.get("made"))))
    auto = local / "phone" / "auto-start" / "log.jsonl"
    if auto.is_file():
        rel = auto.relative_to(local).as_posix()
        read.add(rel)
        last_check: dict = {}
        for j in ds._lines(auto):  # noqa: SLF001
            if not isinstance(j, dict):
                continue
            if j.get("event") == "check":
                last_check = j
            elif j.get("event") == "answer" and ds.parse_time(j.get("at")):
                k, a = j.get("kind"), j.get("answer")
                value = {"yes": k, "no": f"not {k}", "none": "no answer"}.get(a, a)
                asked = ds.parse_time(j["at"]) - timedelta(seconds=_num(j.get("after_s")) or 0)
                out.append(_label("auto-start", j, rel, start=iso(asked), end=iso(asked), kind="activity",
                                  value=value, unit="word", how_asked="question", answered=iso(j["at"]),
                                  app_guess=last_check.get("guess"), detector_version="auto-start phase 1 "
                                  f"({last_check.get('trigger', '?')}, choice {last_check.get('choice', '?')})"))
    tray = local / "laptop" / "work" / "labels.jsonl"
    if tray.is_file():
        rel = tray.relative_to(local).as_posix()
        read.add(rel)
        for j in ds._lines(tray):  # noqa: SLF001
            if isinstance(j, dict) and ds.parse_time(j.get("at")):
                a = j.get("answer")
                value = {"yes": "work", "no": "not work", "not_work": "not work", "none": "no answer"}.get(a, a)
                out.append(_label("tray", j, rel, start=iso(j.get("run_start") or j["at"]), end=iso(j["at"]),
                                  kind="activity", value=value, unit="word",
                                  how_asked="question" if j.get("question") == "ask" else "started by itself",
                                  app_guess=" ".join(str(j[k]) for k in ("family", "app") if j.get(k)) or None,
                                  detector_version=j.get("rule"), answered=iso(j["at"])))
    for folder, store in (("phone/work-sessions", "work-session"), ("laptop/work", "laptop-work")):
        for f in sorted((local / folder).glob("*.work.json")):
            rel = f.relative_to(local).as_posix()
            j = _json(f)
            read.add(rel)
            if not isinstance(j, dict):
                continue
            for h in j.get("hints") or []:
                if isinstance(h, dict) and ds.parse_time(h.get("at")):
                    out.append(_label(store, dict(h, kind="hint"), rel, start=iso(h["at"]), end=iso(h["at"]),
                                      kind="break hint", value=h.get("answer") or "no answer", unit="word",
                                      how_asked="hint " + str(h.get("via") or "on the phone"),
                                      app_guess=f"{h.get('reason')} after {h.get('active_min')} min",
                                      detector_version=f"threshold {h.get('threshold_min')} min",
                                      answered=iso(h.get("answered_at"))))
            for r in j.get("ratings") or []:
                if isinstance(r, dict) and ds.parse_time(r.get("at")) and ds._int_in(r.get("value"), 1, 5):  # noqa: SLF001
                    out.append(_label(store, dict(r, kind="rating"), rel, start=iso(r["at"]), end=iso(r["at"]),
                                      kind="sharp", value=r["value"], unit="1-5", how_asked="own tap",
                                      answered=iso(r["at"])))
    for folder in ("recordings", "phone/mornings", "recordings-diy"):
        for f in sorted((local / folder).glob("*.markers.jsonl")):
            rel = f.relative_to(local).as_posix()
            read.add(rel)
            for j in ds._lines(f):  # noqa: SLF001
                if not (isinstance(j, dict) and isinstance(j.get("text"), str) and _num(j.get("t")) is not None):
                    continue
                how, ver = _marker_how(j["text"])
                out.append(_label("marker", dict(j, file=f.name), rel, start=iso(j["t"]), end=iso(j["t"]),
                                  kind="marker", value=j["text"], unit="text", how_asked=how, detector_version=ver))
    for m in ds.read_mornings(local):
        rel = m["_file"].relative_to(local).as_posix()
        read.add(rel)
        ratings = m.get("ratings") if isinstance(m.get("ratings"), dict) else {}
        habits = m.get("habits") if isinstance(m.get("habits"), dict) else {}
        at = iso(m["_start"])
        for key, kind, unit, src in (("kss", "kss", "1-9", ratings), ("mood", "mood", "1-5", ratings),
                                     ("tension", "tension", "1-5", ratings), ("sleep", "slept", "1-5", ratings),
                                     ("caffeine_cups", "caffeine", "cups", habits),
                                     ("alcohol_drinks", "alcohol", "drinks", habits)):
            if isinstance(src.get(key), int) and not isinstance(src.get(key), bool):
                out.append(_label("check-in", dict(file=m["_file"].name, key=key, value=src[key]), rel, start=at,
                                  end=at, kind=kind, value=src[key], unit=unit, how_asked="check-in", answered=at))
    return out, read


def update_labels(path: Path, local: Path, now: datetime) -> tuple[int, int, int]:
    """Append the labels not yet in labels.tsv (oldest first) and a tombstone for each one gone from a store that was
    read (its `replaces` names it); rows already there are never changed. Returns (rows, added, removed)."""
    have: dict[str, dict] = {}
    if path.is_file():
        lines = path.read_text(encoding="utf-8").splitlines()
        head = lines[0].split("\t") if lines else LABEL_COLUMNS
        for ln in lines[1:]:
            r = dict(zip(head, ln.split("\t")))
            if r.get("id"):
                have[r["id"]] = r
    current, read = labels_now(local)
    now_ids = {x["id"] for x in current}
    gone = {r.get("replaces") for r in have.values() if r.get("kind") == "removed"}
    added = [dict(x, added=iso(now)) for x in current if x["id"] not in have]
    removed = [dict(id="removed:" + r["id"], start=r["start"], end=r["end"], kind="removed", value=r["value"],
                    source=r["source"], origin=r["origin"], replaces=r["id"], added=iso(now))
               for r in have.values() if r.get("kind") != "removed" and r["id"] not in now_ids
               and r["id"] not in gone and r.get("origin") in read]
    new = sorted(added, key=lambda x: (x["start"] or "", x["id"])) + removed
    if not path.is_file():
        _write(path, tsv(LABEL_COLUMNS, new).encode())
    elif new:
        with open(path, "a", encoding="utf-8") as f:
            f.write(tsv(LABEL_COLUMNS, new).split("\n", 1)[1])
    return len(have) + len(new), len(added), len(removed)


# ---- the book -------------------------------------------------------------------------------------------------------

README = """# The data book

Tidy tables of everything eeg_tracker measured on this laptop, made by `scripts/data_book.py` from the files in
`_local/` (DECISIONS 760-769). Every table and column is described in `docs/data-format.md`, "The data book".

| File | One row per |
|---|---|
| `nights.tsv` | night or nap and sleep report (`counts` = 1: the one that counts for that night) |
| `sessions.tsv` | work (phone, laptop), meditation, alpha-theta, nap coach and sound session |
| `days.tsv` | day, 04:00 to 04:00 |
| `epochs.tsv.gz` | 30 s of every recording (gzip; spreadsheets and pandas open it as it is or after `gunzip -k`) |
| `labels.tsv` | label from the app's own stores (append-only: rows are only ever added) |
| `truth.tsv` | truth label: what really happened, typed (`active` = 1: not corrected by a later row) |
| `validation.tsv`, `validation.md` | detector against truth label, and its summary (`scripts/validate_detectors.py`) |
| `book.json` | how the last build went: versions, row counts, time, problems |

Open a table in any spreadsheet (tab-separated, UTF-8, times ISO 8601 with their UTC offset) or with
`pandas.read_csv(path, sep="\\t")`. Every derived row names its model or detector version and the SHA-256 of what it
was made from (`inputs_sha256`; nights.tsv lists every source file in `sources`).

Rebuild: `uv run --project analysis python scripts/data_book.py` (only what changed is worked out again; `--full`
works out everything). The phone link runs it after each copy from the phone (`scripts/after_pull.py`), then
`scripts/validate_detectors.py`. Never edit these files by hand: they are rebuilt. A truth label goes into the hand
file `_local/analyses/truth-labels.tsv` (or a file in `_local/truth/`), in the same columns as `truth.tsv` without its
last three; check it with `python3 scripts/truth.py check`. Deleting this folder loses nothing but the labels' `added`
times; the next run makes it again from `_local/`.

Private: this holds sleep, moods and places. It stays on this laptop: never in a pull request, a cloud agent or a
remote test machine.
"""


def build(local: Path, out: Path, now: datetime, full: bool = False, say: Callable[[str], object] = print) -> dict:
    t0 = time.time()
    out.mkdir(parents=True, exist_ok=True)
    cache = out / ".cache"
    hashes = Hashes(local, cache / "hashes.json")
    problems: list[str] = []
    nights = catalog.nights_on(local)
    reports = read_reports(local, hashes)
    for nid, reps in reports.items():  # a report kept by hand whose night's raw files are gone: a row from it alone
        if not any(r["id"] == nid for r in nights):
            nights.append(dict(catalog._row(nid, None, None), source=reps[0].source))  # noqa: SLF001
    nights.sort(key=lambda r: (r["date"], r["id"]))
    groups = groups_of(local, nights, reports, problems)
    store = EpochStore(cache / "epochs")
    metas, worked = epochs_pass(groups, local, hashes, store, full, say, problems)
    n_epochs, ep_columns = write_epochs(out, groups, metas, store)
    nrows, contacts = night_rows(local, nights, reports, groups, metas, hashes, cache / "nights")
    i = NIGHT_COLUMNS.index("contact_at") + 1
    night_columns = NIGHT_COLUMNS[:i] + [f"contact_{c}_ohm" for c in contacts] + NIGHT_COLUMNS[i:]
    _write(out / "nights.tsv", tsv(night_columns, nrows).encode())
    srows = session_rows(local, hashes)
    _write(out / "sessions.tsv", tsv(SESSION_COLUMNS, srows).encode())
    drows = day_rows(local, nrows, srows, hashes, now)
    _write(out / "days.tsv", tsv(DAY_COLUMNS, drows).encode())
    n_labels, added, removed = update_labels(out / "labels.tsv", local, now)
    trows, rejected, from_where = truth.build(local)
    truth.write_table(out / "truth.tsv", trows)
    hashes.save()
    import epoch_signal as es
    book = dict(format=FORMAT, version=VERSION, built=iso(now), seconds=round(time.time() - t0, 1),
                local=str(local), signal_version=es.VERSION, measures_version=ds.MEASURES_VERSION,
                models=sorted({r["model"] for r in nrows if r.get("model")}),
                rows={"nights.tsv": len(nrows), "sessions.tsv": len(srows), "days.tsv": len(drows),
                      "epochs.tsv.gz": n_epochs, "labels.tsv": n_labels, "truth.tsv": len(trows)},
                recordings=len(groups), worked_out=worked, labels_added=added, labels_removed=removed,
                truth_from=from_where, truth_rejected=[r.text() for r in rejected],
                epoch_columns=len(ep_columns), problems=problems)
    _write(out / "book.json", (json.dumps(book, indent=1) + "\n").encode())
    _write(out / "README.md", README.encode())
    return book


def main(argv: list[str] | None = None, out: Callable[[str], object] = print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="the data folder (default: the repo's _local)")
    ap.add_argument("--out", type=Path, help="where the book goes (default: <local>/data)")
    ap.add_argument("--full", action="store_true", help="work out every recording's 30 s rows again")
    ap.add_argument("--quiet", action="store_true", help="only the summary line")
    a = ap.parse_args(argv)
    local = a.local.resolve()
    dest = (a.out or local / "data").resolve()
    dest.mkdir(parents=True, exist_ok=True)
    with open(dest / ".lock", "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            out("another data book run is going on; nothing to do")
            return 0
        try:
            os.nice(10)  # the recorder and the tray come first
        except OSError:
            pass
        book = build(local, dest, datetime.now().astimezone(), a.full, (lambda _s: None) if a.quiet else out)
    rows = ", ".join(f"{k} {v}" for k, v in book["rows"].items())
    out(f"data book {dest}: {rows}; {book['worked_out']} of {book['recordings']} recordings worked out, "
        f"{book['labels_added']} labels added, {book['seconds']} s")
    for p in book["problems"]:
        out(f"PROBLEM: {p}")
    for t in book["truth_rejected"]:
        out(f"TRUTH LEFT OUT: {t}")
    return 1 if book["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
