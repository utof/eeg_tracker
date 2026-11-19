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
"""
from __future__ import annotations

import json, os, re, shutil, struct, subprocess, sys, threading, time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import packed  # noqa: E402  (a raw file packed after a day, <stamp>.f32.xz, reads as the plain one)

VERSION = 2  # of <night>.report.json; a report of another version is rebuilt (2: adds `extras`)
FS = 250
REC_BYTES = 20  # one <I4f record in a .f32
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

    @property
    def minutes(self) -> float:
        return self.size // REC_BYTES / FS / 60


@dataclass
class Night:
    name: str  # evening date, YYYY-MM-DD
    recs: list[Rec]

    @property
    def start(self) -> float:
        return self.recs[0].start

    @property
    def end(self) -> float:
        return max(r.end for r in self.recs)


def stamp_time(path: Path) -> float | None:
    try:
        return datetime.strptime(path.stem, "%Y-%m-%d-%H%M%S").timestamp()
    except ValueError:
        return None


def evening_date(t: float) -> str:
    return (datetime.fromtimestamp(t) - timedelta(hours=12)).date().isoformat()


_ends: dict[tuple[str, int, int], float] = {}


def _end(path: Path, start: float, size: int) -> float:
    """Arrival time of the last batch (last .idx row); start + samples / 250 without an index."""
    ip = path.with_suffix(".idx")
    try:
        isize = ip.stat().st_size
    except OSError:
        isize = 0
    key = (str(path), size, isize)
    if key not in _ends:
        end = start + size // REC_BYTES / FS
        if isize >= IDX.size:
            with open(ip, "rb") as f:
                f.seek((isize // IDX.size - 1) * IDX.size)
                t, _ = IDX.unpack(f.read(IDX.size))
            if start <= t < start + 7 * 86400:
                end = t
        _ends[key] = end
    return _ends[key]


def recordings(folder: Path) -> list[Rec]:
    """Every recording with at least one sample, oldest first; a packed one by its plain name."""
    out = []
    for p in packed.raw_files(folder):
        start = stamp_time(p)
        try:
            size = packed.size(p)
        except OSError:
            continue
        if start is not None and size >= REC_BYTES:
            out.append(Rec(p, start, _end(p, start, size), size))
    return sorted(out, key=lambda r: (r.start, r.path.name))


def nights(recs: list[Rec]) -> list[Night]:
    out: list[Night] = []
    for r in recs:
        if out:
            n = out[-1]
            near = r.start - n.end < CHAIN_GAP_S or evening_date(r.start) == n.name
            if near and r.start - n.start < MAX_SPAN_S:
                n.recs.append(r)
                continue
        out.append(Night(evening_date(r.start), [r]))
    return out


def recent_nights(folder: Path, now: float, hours: float = WINDOW_H) -> list[Night]:
    """Nights with data in the last `hours` hours, oldest first."""
    return [n for n in nights(recordings(folder)) if n.end >= now - hours * 3600 and n.start <= now]


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
    `drift_off`), or 10+ minutes of samples the report lacks."""
    if report is None or report.get("version") != VERSION or "drift_off" not in report:
        return True
    done = {i.get("file"): int(i.get("bytes", 0)) for i in report.get("inputs", []) if isinstance(i, dict)}
    now = {r.path.name: r.size for r in night.recs}
    if set(done) - set(now) or any(now[f] < b for f, b in done.items()):
        return True  # a file went away or shrank: the report no longer matches the files
    new = sum(size - done.get(f, 0) for f, size in now.items()) // REC_BYTES
    return new >= NEW_DATA_MIN * 60 * FS


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


def stale_nights(rec_dir: Path, nights_dir: Path, now: float, hours: float = WINDOW_H) -> list[Night]:
    return [n for n in recent_nights(rec_dir, now, hours) if is_stale(n, read_report(nights_dir, n.name))]


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
