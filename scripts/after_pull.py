"""The laptop's jobs after files came from the phone: pack old raw recordings, the daily export, the data book.

usage: python3 scripts/after_pull.py [--local _local] [--skip pack|export|book ...]

One step after the other, each its own bounded process; a step that fails does not stop the next (DECISIONS 768):

  pack     python3 scripts/pack_old.py --local <local>             raw .f32 nothing wrote for a day -> .f32.xz
  export   python3 scripts/export_events.py --daily --local <local> --root <local>/export
                                                                    the eeg_day events utof_tracker imports hourly
  book     uv run --project analysis python scripts/data_book.py --local <local> --quiet
                                                                    the data book in <local>/data (numpy: its own
                                                                    environment, lowered priority, memory capped)

Each step's exit status, time and last lines go to <local>/after-pull.log; <local>/after-pull.json keeps when the last
run started and ended and how each step ended. One run at a time (<local>/after-pull.lock): a second one says so and
does nothing.

scripts/phone_link.py --keep (how the laptop tray keeps the phone linked) starts this in the background through
`Kicker`: after a copy that brought something new, at most once every 30 minutes, and once a day without one, so the
export to utof_tracker runs daily even when nothing new came. It is never waited for. Standard library only.
"""
from __future__ import annotations

import argparse, fcntl, json, os, shutil, subprocess, sys, time
from datetime import datetime
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_LOCAL = ROOT / "_local"
MIN_GAP_S = 30 * 60  # after a copy that brought something new, at most this often (a night grows every 2 minutes)
DAILY_S = 24 * 3600  # and at least this often, new files or not
MEMORY_MAX = "3500M"  # the data book's cap, as the sleep report's (night_files.MEMORY_MAX)
TIMEOUT_S = {"pack": 60 * 60, "export": 10 * 60, "book": 60 * 60}
TAIL_LINES = 12
STATE, LOG, LOCK = "after-pull.json", "after-pull.log", "after-pull.lock"


def _uv() -> str | None:
    found = shutil.which("uv")
    if found:
        return found
    for p in (Path.home() / ".local/bin/uv", Path.home() / ".cargo/bin/uv"):
        if p.is_file():
            return str(p)
    return None


def steps(local: Path) -> list[tuple[str, list[str]]]:
    """The commands, in order."""
    py = sys.executable or "python3"
    book = None
    uv = _uv()
    if uv is not None:
        book = [uv, "run", "--project", str(ROOT / "analysis"), "python", str(HERE / "data_book.py"), "--local",
                str(local), "--quiet"]
        runner = shutil.which("systemd-run")
        if runner:
            book = [runner, "--user", "--scope", "-q", "-p", f"MemoryMax={MEMORY_MAX}", *book]
    return [("pack", [py, str(HERE / "pack_old.py"), "--local", str(local)]),
            ("export", [py, str(HERE / "export_events.py"), "--daily", "--local", str(local), "--root",
                        str(local / "export")]),
            ("book", book or [py, "-c", "raise SystemExit('uv not found: the data book needs its environment')"])]


def _env() -> dict[str, str]:
    """This process's environment without another Python environment's settings (the tray's, a recorder's)."""
    return {k: v for k, v in os.environ.items()
            if k not in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "LD_LIBRARY_PATH", "UV_PROJECT_ENVIRONMENT")}


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def run_steps(local: Path, todo: list[tuple[str, list[str]]], log: Callable[[str], None]) -> dict:
    out = {}
    for name, cmd in todo:
        t0 = time.time()
        try:
            r = subprocess.run(cmd, cwd=ROOT, env=_env(), stdin=subprocess.DEVNULL, capture_output=True, text=True,
                               timeout=TIMEOUT_S.get(name, 30 * 60))
            code, text = r.returncode, (r.stdout + r.stderr).strip()
        except subprocess.TimeoutExpired as e:
            code, text = None, f"stopped after {e.timeout:.0f} s"
        except OSError as e:
            code, text = None, f"could not start: {e}"
        secs = round(time.time() - t0, 1)
        tail = text.splitlines()[-TAIL_LINES:]
        log(f"{_now()} {name}: " + (f"exit {code}" if code is not None else "failed") + f" in {secs} s"
            + "".join(f"\n  {ln}" for ln in tail))
        out[name] = dict(exit=code, seconds=secs, at=_now(), last=tail[-1] if tail else "")
    return out


def main(argv: list[str] | None = None, todo: list[tuple[str, list[str]]] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="the data folder (default: the repo's _local)")
    ap.add_argument("--skip", nargs="*", default=[], choices=("pack", "export", "book"), help="steps to leave out")
    a = ap.parse_args(argv)
    local = a.local.resolve()
    local.mkdir(parents=True, exist_ok=True)
    plan = [(n, c) for n, c in (todo if todo is not None else steps(local)) if n not in a.skip]

    def log(text: str) -> None:
        with open(local / LOG, "a", encoding="utf-8") as f:
            f.write(text + "\n")

    with open(local / LOCK, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log(f"{_now()} another run is going on; nothing to do")
            return 0
        started = time.time()
        state = _read_state(local)
        state.update(started=started, finished=None, pid=os.getpid())
        _write_state(local, state)
        result = run_steps(local, plan, log)
        state.update(finished=time.time(), steps=result, pid=None)
        _write_state(local, state)
    return 1 if any(s["exit"] != 0 for s in result.values()) else 0


def _read_state(local: Path) -> dict:
    try:
        d = json.loads((local / STATE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def _write_state(local: Path, d: dict) -> None:
    tmp = local / (STATE + ".tmp")
    tmp.write_text(json.dumps(d, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, local / STATE)


class Kicker:
    """What scripts/phone_link.py --keep calls after each copy pass (`changed`: the pass brought something new): starts
    this script in the background when it is due, never waits for it, and never starts a second one while one runs.
    Due: something new and the last run started MIN_GAP_S ago or more; or the last run started DAILY_S ago or more."""

    def __init__(self, local: Path, *, clock: Callable[[], float] = time.time,
                 start: Callable[[list[str]], subprocess.Popen] | None = None) -> None:
        self.local, self.clock = Path(local), clock
        self.start = start or self._popen
        self.proc: subprocess.Popen | None = None
        self.started = 0.0

    def _popen(self, cmd: list[str]) -> subprocess.Popen:
        return subprocess.Popen(cmd, cwd=ROOT, env=_env(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)

    def last_start(self) -> float:
        s = _read_state(self.local).get("started")
        recorded = float(s) if isinstance(s, (int, float)) and not isinstance(s, bool) else 0.0
        return max(recorded, self.started)

    def __call__(self, changed: bool) -> bool:
        if self.proc is not None and self.proc.poll() is None:
            return False
        since = self.clock() - self.last_start()
        if not ((changed and since >= MIN_GAP_S) or since >= DAILY_S):
            return False
        self.started = self.clock()
        self.proc = self.start([sys.executable or "python3", str(HERE / "after_pull.py"), "--local", str(self.local)])
        return True


if __name__ == "__main__":
    sys.exit(main())
