"""Which recordings make up a night, whether its sleep report is up to date, and the hub's side of the report job.

Standard library only: the recorder hub (record_night.py) imports this and must never import numpy.
scripts/sleep_report.py builds the reports; record_night.py serves GET/POST /sleep-report and GET /hypnogram.png
with job_state(), start_job() and hypnogram(), and GET/POST /morning-report (scripts/morning_check.py) with
morning_state() and start_morning(). Job is the lock and progress file both analysis scripts hold while they work.

A night is a chain of recordings (<stamp>.f32 from record_night.py) in time order: a recording joins the night of
the one before it when it starts less than 3 hours after that one's last data, or when it has the same evening
date (its start minus 12 hours, like night_of in export_events.py); a night never takes a recording that starts
24 hours or more after the night's first one. The night is named after the evening date of its first recording,
so the owner's night and a late-morning sleep after it land in one report. The chain always starts from the
oldest recording in the folder, so the same files always give the same nights.

A recording's record size and rate are its own (scripts/recording.py: its <stamp>.header.json, else its .log's
format line, else the BrainBit's 20 bytes at 250 Hz), so minutes are right for any number of channels. A recording
whose header names a session that is not sleep (the phone's work session, `session: work`, DECISIONS 683) is no
recording of a night: recordings() leaves it out, so it is never chained, scored or reported as sleep.

Record first (DECISIONS 880-899, scripts/spans.py): a file set whose header has `recording` belongs to that
recording and is never chained by the 3-hour rule above. What was sleep in it is said by the spans file of that
recording (<spans>/<recording id>.spans.jsonl): each closed span of kind `sleep` or `nap` is a time window.
  - Sleep spans (source owner_button, owner_confirmed or auto_start) are joined into nights by the same rule applied
    to spans: the next span starts less than 3 hours after the last one's end, or has the same evening date, within 24
    hours of the first. The night is named by the evening date of its first span and reads only the samples inside
    its spans (`Night.windows`, unix seconds). An auto_start span is taken as a night span here: the "10 minutes
    asleep" rule is applied by whoever scores it. Open spans (no end) and spans of other sources give nothing yet.
  - `nap` spans never join a night; naps() lists them, each named by its start stamp YYYY-MM-DD-HHMMSS.
  - A recording whose headers have `recording` and that has no sleep span (or no spans file) gives no night.
  - An old file set (no `recording`) chains exactly as before, except the sets a spans file lists as "Not sleep"
    (spans.no_sleep_sets): those join no night.
  - An old chain and a span night with the same evening date are one night: the files of both, the windows of the
    span night plus each old file as a whole, and the span night's span ids and `span_from`.
  - `span_from`: `pressed` (an owner_button span among them), else `confirmed`, else `auto`; `migrated` for an old chain.
Where the spans are: `spans_dir`; by default (AUTO) the sibling `spans/` of the recordings folder when that folder is
named `recordings` (the phone's layout copied to <local>/phone/recordings), else none.
"""
from __future__ import annotations

import json, os, re, shutil, struct, subprocess, sys, threading, time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable, Collection

sys.path.insert(0, str(Path(__file__).resolve().parent))
import packed  # noqa: E402  (a raw file packed after a day, <stamp>.f32.xz, reads as the plain one)
import recording  # noqa: E402  (what a .f32 holds: its header, or what files from before the header held)
import spans as spans_mod  # noqa: E402  (what you did in a recording: the sleep spans make the nights)

VERSION = 2  # of <night>.report.json; a report of another version is rebuilt (2: adds `extras`)
FS = 250  # the BrainBit's; a recording's own rate is Rec.fs
REC_BYTES = 20  # one <I4f record in a BrainBit .f32; a recording's own record size is Rec.rec_bytes
IDX = struct.Struct("<dQ")
CHAIN_GAP_S = 3 * 3600
MAX_SPAN_S = 24 * 3600
NEW_DATA_MIN = 10  # a report is out of date once this many minutes of new samples exist
WINDOW_H = 20  # the hub looks at nights with data in the last 20 hours
LOCK, STATUS, LOG = "sleep-report.lock", "sleep-report.status.json", "sleep-report.log"  # the sleep job's
MEMORY_MAX = "3500M"
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Rec:
    path: Path  # <stamp>.f32 by its plain name, also when it is packed (open it with packed.open_raw)
    start: float  # unix time from the file name
    end: float  # arrival time of the last batch in the .idx
    size: int  # bytes of the .f32 (unpacked)
    rec_bytes: int = REC_BYTES  # bytes of one record: 4 + 4 per channel (recording.read)
    fs: float = FS  # samples a second
    recording: str | None = None  # the header's `recording`: the id of the recording this set belongs to; None: old

    @property
    def stem(self) -> str:
        return self.path.stem

    @property
    def samples(self) -> int:
        return self.size // self.rec_bytes

    @property
    def minutes(self) -> float:
        return self.samples / self.fs / 60


@dataclass
class Night:
    name: str  # evening date, YYYY-MM-DD (a nap: its start stamp, YYYY-MM-DD-HHMMSS)
    recs: list[Rec]
    windows: list[tuple[float, float]] | None = None  # unix seconds read from the files; None = the whole files
    recording_ids: list[str] = field(default_factory=list)  # the recordings the spans belong to (empty: old chain)
    span_ids: list[str] = field(default_factory=list)
    span_from: str = "migrated"  # pressed | confirmed | auto | migrated (an old chain)

    @property
    def start(self) -> float:
        return self.windows[0][0] if self.windows else self.recs[0].start

    @property
    def end(self) -> float:
        return max(b for _, b in self.windows) if self.windows else max(r.end for r in self.recs)

    @property
    def recorded_s(self) -> float:
        """Seconds of samples the night reads: all of its files, or those inside its windows."""
        if self.windows is None:
            return sum(r.samples / r.fs for r in self.recs)
        return sum(max(0.0, min(r.start + r.samples / r.fs, b) - max(r.start, a)) for r in self.recs
                   for a, b in self.windows)


def stamp_time(path: Path) -> float | None:
    try:
        return datetime.strptime(path.stem, "%Y-%m-%d-%H%M%S").timestamp()
    except ValueError:
        return None


def evening_date(t: float) -> str:
    return (datetime.fromtimestamp(t) - timedelta(hours=12)).date().isoformat()


_ends: dict[tuple[str, int, int, int, float], float] = {}


def _end(path: Path, start: float, size: int, rec_bytes: int = REC_BYTES, fs: float = FS) -> float:
    """Arrival time of the last batch (last .idx row); start + samples / rate without an index."""
    ip = path.with_suffix(".idx")
    try:
        isize = ip.stat().st_size
    except OSError:
        isize = 0
    key = (str(path), size, isize, rec_bytes, fs)
    if key not in _ends:
        end = start + size // rec_bytes / fs
        if isize >= IDX.size:
            with open(ip, "rb") as f:
                f.seek((isize // IDX.size - 1) * IDX.size)
                t, _ = IDX.unpack(f.read(IDX.size))
            if start <= t < start + 7 * 86400:
                end = t
        _ends[key] = end
    return _ends[key]


def recordings(folder: Path, on_bad: Callable[[Path, Exception], None] | None = None) -> list[Rec]:
    """Every recording of sleep with at least one sample, oldest first; a packed one by its plain name. A work
    session's (its header's `session`) is left out. A recording whose header is damaged is an error naming the file
    (recording.HeaderError), never a guess at its record size; with `on_bad` it is handed over (path, error) and left
    out instead."""
    out = []
    for p in packed.raw_files(folder):
        start = stamp_time(p)
        if start is None:
            continue
        try:
            size = packed.size(p)
        except OSError:
            continue
        try:
            h = recording.read(p)
        except recording.HeaderError as e:
            if on_bad is None:
                raise
            on_bad(p, e)
            continue
        if not h.is_sleep:
            continue
        if size >= h.record_bytes:
            out.append(Rec(p, start, _end(p, start, size, h.record_bytes, h.sample_rate), size, h.record_bytes,
                           h.sample_rate, h.recording))
    return sorted(out, key=lambda r: (r.start, r.path.name))


def nights(recs: list[Rec], no_sleep: Collection[str] = (), include_recorded: bool = False) -> list[Night]:
    """The old chain over the sets without a `recording` field, minus the sets in `no_sleep` (stems that "Not sleep"
    named). A set with `recording` is never chained here (span_nights() makes its nights) unless `include_recorded`
    (phone_night_check, which reads the recorders' logs, not spans)."""
    out: list[Night] = []
    for r in recs:
        if (r.recording is not None and not include_recorded) or r.stem in no_sleep:
            continue
        if out:
            n = out[-1]
            near = r.start - n.end < CHAIN_GAP_S or evening_date(r.start) == n.name
            if near and r.start - n.start < MAX_SPAN_S:
                n.recs.append(r)
                continue
        out.append(Night(evening_date(r.start), [r]))
    return out


AUTO = None  # spans_dir: the sibling `spans/` of a folder named `recordings`, else none
SPAN_FROM = {"owner_button": "pressed", "owner_confirmed": "confirmed", "auto_start": "auto"}  # source -> span_from


def spans_folder(folder: Path, spans_dir: Path | None = AUTO) -> Path | None:
    """Where the spans files of the recordings in `folder` are (None: nowhere)."""
    if spans_dir is not None:
        return Path(spans_dir)
    folder = Path(folder)
    return folder.parent / "spans" if folder.name == "recordings" else None


def _usable(files: dict[str, spans_mod.SpansFile], nap: bool) -> list[tuple[str, spans_mod.Span]]:
    """(recording id, span) of every closed sleep (or nap) span a report may come from, oldest first."""
    want = "nap" if nap else "sleep"
    out = [(rid, s) for rid, f in files.items() for s in f.spans
           if s.kind == want and s.source in SPAN_FROM and s.end_unix is not None and s.end_unix > s.start_unix]
    return sorted(out, key=lambda x: (x[1].start_unix, x[1].span))


def _overlapping(recs: list[Rec], rid: str, a: float, b: float) -> list[Rec]:
    return [r for r in recs if r.recording == rid and r.start < b and r.end > a]


def _from_word(sources: list[str]) -> str:
    words = [SPAN_FROM[x] for x in sources]
    return next((w for w in ("pressed", "confirmed", "auto") if w in words), "auto")


def span_nights(recs: list[Rec], files: dict[str, spans_mod.SpansFile]) -> list[Night]:
    """Nights from closed sleep spans (module docstring); a span with no file set under it gives nothing."""
    out: list[tuple[Night, list[str]]] = []
    for rid, s in _usable(files, nap=False):
        under = _overlapping(recs, rid, s.start_unix, s.end_unix)
        if not under:
            continue
        if out:
            n, sources = out[-1]
            near = s.start_unix - n.end < CHAIN_GAP_S or evening_date(s.start_unix) == n.name
            if near and s.start_unix - n.start < MAX_SPAN_S:
                n.windows.append((s.start_unix, s.end_unix))  # type: ignore[union-attr]
                n.recs.extend(r for r in under if r not in n.recs)
                n.span_ids.append(s.span)
                if rid not in n.recording_ids:
                    n.recording_ids.append(rid)
                sources.append(s.source)
                continue
        out.append((Night(evening_date(s.start_unix), list(under), [(s.start_unix, s.end_unix)], [rid], [s.span]),
                    [s.source]))
    for n, sources in out:
        n.recs.sort(key=lambda r: (r.start, r.path.name))
        n.span_from = _from_word(sources)
    return [n for n, _ in out]


def naps(folder: Path, spans_dir: Path | None = AUTO, on_bad: Callable[[Path, Exception], None] | None = None
         ) -> list[Night]:
    """Nap spans, one Night each (never joined), named by the span's start stamp YYYY-MM-DD-HHMMSS."""
    sdir = spans_folder(folder, spans_dir)
    if sdir is None:
        return []
    recs, files = recordings(folder, on_bad), spans_mod.in_folder(sdir)
    out = []
    for rid, s in _usable(files, nap=True):
        under = _overlapping(recs, rid, s.start_unix, s.end_unix)
        if under:
            name = datetime.fromtimestamp(s.start_unix).strftime("%Y-%m-%d-%H%M%S")
            out.append(Night(name, under, [(s.start_unix, s.end_unix)], [rid], [s.span], _from_word([s.source])))
    return out


def _merge(old: Night, new: Night) -> Night:
    """An old chain and a span night of one evening date: one night (module docstring)."""
    wins = sorted([(r.start, r.end) for r in old.recs] + list(new.windows or []))
    merged: list[tuple[float, float]] = []
    for a, b in wins:
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    recs = sorted({r.path: r for r in old.recs + new.recs}.values(), key=lambda r: (r.start, r.path.name))
    return Night(new.name, recs, merged, new.recording_ids, new.span_ids, new.span_from)


def all_nights(folder: Path, spans_dir: Path | None = AUTO,
               on_bad: Callable[[Path, Exception], None] | None = None) -> list[Night]:
    """Every night in `folder`, oldest first: the old chain of the sets without a `recording` field (minus the sets
    "Not sleep" named) and the nights of the closed sleep spans."""
    recs = recordings(folder, on_bad)
    sdir = spans_folder(folder, spans_dir)
    files = spans_mod.in_folder(sdir) if sdir is not None else {}
    by_name = {n.name: n for n in nights(recs, spans_mod.no_sleep_of(files))}
    for n in span_nights(recs, files):
        by_name[n.name] = _merge(by_name[n.name], n) if n.name in by_name else n
    return sorted(by_name.values(), key=lambda n: (n.start, n.name))


def recent_nights(folder: Path, now: float, hours: float = WINDOW_H, spans_dir: Path | None = AUTO) -> list[Night]:
    """Nights with data in the last `hours` hours, oldest first."""
    return [n for n in all_nights(folder, spans_dir) if n.end >= now - hours * 3600 and n.start <= now]


def read_json(path: Path) -> dict | None:
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def read_report(nights_dir: Path, name: str) -> dict | None:
    return read_json(Path(nights_dir) / f"{name}.report.json")


def is_stale(night: Night, report: dict | None) -> bool:
    """True when the night has no report, an older kind of report (another version, or version 2 from before
    `drift_off`, the dream sleep check `rem_check` or the walking veto `walking`), or 10+ minutes of samples the
    report lacks."""
    if (report is None or report.get("version") != VERSION or "drift_off" not in report or "rem_check" not in report
            or "walking" not in report):
        return True
    if night.windows is not None:  # the sleep spans fix what is read: a growing file around them changes nothing
        sp = report.get("span")
        return not isinstance(sp, dict) or sp.get("spans") != night.span_ids or \
            sp.get("windows") != [list(w) for w in night.windows]
    done = {i.get("file"): int(i.get("bytes", 0)) for i in report.get("inputs", []) if isinstance(i, dict)}
    now = {r.path.name: r.size for r in night.recs}
    if set(done) - set(now) or any(now[f] < b for f, b in done.items()):
        return True  # a file went away or shrank: the report no longer matches the files
    new_s = sum((r.size - done.get(r.path.name, 0)) // r.rec_bytes / r.fs for r in night.recs)
    return new_s >= NEW_DATA_MIN * 60


# ---- lights off and the drift-off check (DECISIONS 180-184; analysis/night_drift.py, app/lib/sleep/drift.dart) ----

LIGHTS_OFF_MARKER = "lights off"  # written by the phone's Lights off button
CHECK_NIGHTS, CHECK_NEEDED = 5, 4  # the drift-off detector is trusted at 4 of the newest 5 counted nights


def lights_off_from(text: str) -> str | None:
    """The app's marker texts that mean lights off, by who gave it; None for any other marker."""
    if text == LIGHTS_OFF_MARKER:
        return "button"
    if text.startswith("dream catcher: lights off"):
        return "dream catcher"
    if text == "sound: quiet minute (eyes closed)":
        return "sound"
    return None


def lights_off(night: Night) -> tuple[float, str] | None:
    """The latest lights-off marker (by its unix time) in the night's .markers.jsonl files; None without one. Lines
    that are not markers are skipped."""
    best: tuple[float, str] | None = None
    for r in night.recs:
        try:
            lines = r.path.with_suffix(".markers.jsonl").read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if not isinstance(m, dict) or not isinstance(m.get("text"), str):
                continue
            t, src = m.get("t"), lights_off_from(m["text"])
            if src and isinstance(t, (int, float)) and not isinstance(t, bool) and t == t and abs(t) != float("inf"):
                if best is None or t >= best[0]:
                    best = (float(t), src)
    return best


def drift_check(reports: list[dict]) -> tuple[int, int]:
    """(agree, nights) over the newest 5 nights that count (`drift_off.counted`: lights off given, sleep found)."""
    counted = sorted(((r.get("night_of", ""), r["drift_off"].get("agree") is True) for r in reports
                      if isinstance(r.get("drift_off"), dict) and r["drift_off"].get("counted") is True), reverse=True)
    newest = counted[:CHECK_NIGHTS]
    return sum(1 for _, a in newest if a), len(newest)


def drift_check_line(agree: int, nights: int) -> str:
    if nights == 0:
        return "drift-off check: no night with lights off yet (trusted at 4 of 5 nights within 5 minutes)"
    head = f"drift-off check: {agree} of {nights} night{'' if nights == 1 else 's'} within 5 minutes of the sleep model"
    if nights < CHECK_NIGHTS:
        return f"{head} so far (trusted at 4 of 5)"
    return f"{head} (the newest 5): {'trusted' if agree >= CHECK_NEEDED else 'not yet trusted (needs 4 of 5)'}"


def stale_nights(rec_dir: Path, nights_dir: Path, now: float, hours: float = WINDOW_H,
                 spans_dir: Path | None = AUTO) -> list[Night]:
    return [n for n in recent_nights(rec_dir, now, hours, spans_dir) if is_stale(n, read_report(nights_dir, n.name))]


def reports(nights_dir: Path) -> list[Path]:
    """Report files, newest night first."""
    return sorted((p for p in Path(nights_dir).glob("*.report.json") if DATE.match(p.name[:-12])), reverse=True)


# ---- one run at a time: the lock and the progress file, shared by the hub and the analysis scripts ----
# A job kind is "sleep-report" (scripts/sleep_report.py) or "morning-report" (scripts/morning_check.py); its
# <kind>.lock, <kind>.status.json and <kind>.log live in the nights folder.
SCRIPTS = {"sleep-report": "sleep_report.py", "morning-report": "morning_check.py"}


class Job:
    """Held by the analysis script while it works: <kind>.lock (flock + PID) and <kind>.status.json for the pages."""

    def __init__(self, folder: Path, kind: str) -> None:
        self.folder, self.kind = Path(folder), kind
        self.d: dict = dict(state="running", step="Starting", started=time.time(), pid=os.getpid(), error=None)
        self._lock = threading.Lock(); self._f = None

    def acquire(self) -> bool:
        """False when another run holds the lock."""
        import fcntl
        self.folder.mkdir(parents=True, exist_ok=True)
        f = open(self.folder / f"{self.kind}.lock", "a+")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            f.close()
            return False
        f.seek(0); f.truncate(); f.write(str(os.getpid())); f.flush()
        self._f = f; self.write()
        return True

    def write(self, **kw: object) -> None:
        with self._lock:
            self.d.update(kw, updated=time.time())
            tmp = self.folder / f"{self.kind}.status.tmp"
            tmp.write_text(json.dumps(self.d)); os.replace(tmp, self.folder / f"{self.kind}.status.json")

    def step(self, text: str) -> None:
        print(f"{datetime.now():%H:%M:%S} {text}", flush=True)
        self.write(step=text)

    def release(self) -> None:
        import fcntl
        if self._f:
            self._f.seek(0); self._f.truncate(); self._f.flush()
            fcntl.flock(self._f, fcntl.LOCK_UN); self._f.close(); self._f = None


def running_pid(nights_dir: Path, kind: str = "sleep-report") -> int | None:
    """PID of a live run of this kind holding the lock, or None."""
    try:
        pid = int((Path(nights_dir) / f"{kind}.lock").read_text().strip() or 0)
        cmd = Path(f"/proc/{pid}/cmdline").read_bytes() if pid > 0 else b""
    except (OSError, ValueError):
        return None
    return pid if SCRIPTS[kind].encode() in cmd else None


# ---- the hub's side: started detached and memory-capped, so the recorder never waits for a job ----

_procs: dict = {}
_start_lock = threading.Lock()


def job_running(nights_dir: Path, kind: str = "sleep-report") -> bool:
    p = _procs.get(kind)
    return (p is not None and p.poll() is None) or running_pid(nights_dir, kind) is not None


def _uv() -> str | None:
    found = shutil.which("uv")
    if found:
        return found
    for p in (Path.home() / ".local/bin/uv", Path.home() / ".cargo/bin/uv"):
        if p.is_file():
            return str(p)
    return None


def _start(kind: str, args: list[str], nights_dir: Path, root: Path) -> dict:
    with _start_lock:
        if job_running(nights_dir, kind):
            return {"running": True, "started": False, "now": time.time()}
        uv = _uv()
        if uv is None:
            return {"running": False, "started": False, "error": "uv not found"}
        nights_dir = Path(nights_dir); nights_dir.mkdir(parents=True, exist_ok=True)
        cmd = [uv, "run", "--project", "analysis", "python", f"scripts/{SCRIPTS[kind]}", *args]
        runner = shutil.which("systemd-run")
        if runner:
            cmd = [runner, "--user", "--scope", "-q", "-p", f"MemoryMax={MEMORY_MAX}", *cmd]
        # the recorder's own environment (its uv venv, the fake SDK, the SDK's libc++) is not the analysis one
        env = {k: v for k, v in os.environ.items()
               if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "LD_LIBRARY_PATH", "UV_PROJECT_ENVIRONMENT")}
        now = time.time()
        tmp = nights_dir / f"{kind}.status.tmp"
        tmp.write_text(json.dumps({"state": "starting", "step": "Starting", "started": now}))
        os.replace(tmp, nights_dir / f"{kind}.status.json")
        with open(nights_dir / f"{kind}.log", "ab") as log:
            log.write(f"\n{datetime.now().isoformat(timespec='seconds')} hub starts: {' '.join(cmd)}\n".encode())
            log.flush()
            _procs[kind] = subprocess.Popen(cmd, cwd=root, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                            stderr=subprocess.STDOUT, start_new_session=True)
        return {"running": True, "started": True, "now": now}


def start_job(rec_dir: Path, nights_dir: Path, export_dir: Path, root: Path = ROOT) -> dict:
    """POST /sleep-report: start scripts/sleep_report.py unless one is running."""
    return _start("sleep-report", ["--recordings", str(Path(rec_dir).resolve()), "--nights",
                                   str(Path(nights_dir).resolve()), "--export", str(Path(export_dir).resolve())],
                  nights_dir, root)


def start_morning(rec_dir: Path, nights_dir: Path, export_dir: Path, root: Path = ROOT) -> dict:
    """POST /morning-report: start scripts/morning_check.py on the recordings (it exports the event) unless running."""
    return _start("morning-report", [str(Path(rec_dir).resolve()), "--export", str(Path(export_dir).resolve()),
                                     "--job-dir", str(Path(nights_dir).resolve())], nights_dir, root)


def _log_tail(nights_dir: Path, kind: str) -> str:
    try:
        with open(Path(nights_dir) / f"{kind}.log", "rb") as f:
            f.seek(max(0, f.seek(0, 2) - 2000))
            lines = [ln for ln in f.read().decode("utf-8", "replace").splitlines() if ln.strip()]
    except OSError:
        return ""
    return lines[-1][:300] if lines else ""


def _progress(nights_dir: Path, kind: str, now: float) -> dict:
    """running, the job's progress file, why the last job failed (if it did), and the hub's clock."""
    running = job_running(nights_dir, kind)
    status = read_json(Path(nights_dir) / f"{kind}.status.json")
    body: dict = dict(running=running, progress=status, now=now)
    if not running and status:
        if status.get("state") == "failed":
            body["failed"] = status.get("error") or "the last run failed"
        elif status.get("state") in ("starting", "running"):
            body["failed"] = "the last run stopped before it finished: " + (_log_tail(nights_dir, kind) or "no log")
    return body


def job_state(rec_dir: Path, nights_dir: Path, now: float | None = None, hours: float = WINDOW_H) -> dict:
    """GET /sleep-report: running, stale (newer recordings than the reports), the newest report, other reports of
    the last `hours` hours, the newest report's file time, the job's progress, and why the last job failed."""
    now = time.time() if now is None else now
    files = reports(nights_dir)
    newest = read_report(nights_dir, files[0].name[:-12]) if files else None
    recent = []
    for p in files[1:4]:
        r = read_json(p)
        try:
            end = datetime.fromisoformat(r["data_end"]).timestamp() if r else 0.0
        except (KeyError, TypeError, ValueError):
            end = 0.0
        if r and end >= now - hours * 3600:
            recent.append(r)
    body = _progress(nights_dir, "sleep-report", now)
    body.update(stale=bool(stale_nights(rec_dir, nights_dir, now, hours)), report=newest, recent=recent,
                updated=files[0].stat().st_mtime if files else None)
    return body


def morning_state(rec_dir: Path, nights_dir: Path, now: float | None = None) -> dict:
    """GET /morning-report: running, the newest <start>.morning.json in the recordings folder (or null) and its
    file time, the job's progress, and why the last job failed."""
    now = time.time() if now is None else now
    files = sorted(p for p in Path(rec_dir).glob("*.morning.json") if DATE.match(p.name[:10]))
    body = _progress(nights_dir, "morning-report", now)
    body.update(report=read_json(files[-1]) if files else None, updated=files[-1].stat().st_mtime if files else None)
    return body


def hypnogram(nights_dir: Path, date: str | None = None) -> Path | None:
    """The chart of night `date`, else of the newest report, else the newest chart."""
    nights_dir = Path(nights_dir)
    if date:
        p = nights_dir / f"{date}.hypnogram.png"
        return p if DATE.match(date) and p.is_file() else None
    files = reports(nights_dir)
    if files:
        p = nights_dir / f"{files[0].name[:-12]}.hypnogram.png"
        if p.is_file():
            return p
    pngs = sorted(nights_dir.glob("*.hypnogram.png"), key=lambda p: p.stat().st_mtime)
    return pngs[-1] if pngs else None
