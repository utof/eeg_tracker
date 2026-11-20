"""scripts/after_pull.py: the laptop's jobs after files came from the phone (packing, the daily export, the data book),
and when scripts/phone_link.py --keep starts them (DECISIONS 768). Nothing real runs: the steps are small commands."""
from __future__ import annotations

import json
import subprocess
import sys
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import after_pull as ap  # noqa: E402
import phone_link as pl  # noqa: E402
import pull_phone as pp  # noqa: E402

PY = sys.executable


class Clock:
    def __init__(self, t: float = 1_800_000_000.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t


class FakeProc:
    def __init__(self) -> None:
        self.done = False

    def poll(self) -> int | None:
        return 0 if self.done else None


def test_the_steps_run_in_order_and_a_failure_does_not_stop_the_next(tmp_path: Path) -> None:
    todo = [("pack", [PY, "-c", "print('packed 2 files')"]),
            ("export", [PY, "-c", "import sys; print('no export'); sys.exit(3)"]),
            ("book", [PY, "-c", "print('data book: nights.tsv 3')"])]
    assert ap.main(["--local", str(tmp_path)], todo=todo) == 1
    log = (tmp_path / ap.LOG).read_text()
    assert log.index("pack: exit 0") < log.index("export: exit 3") < log.index("book: exit 0")
    assert "  packed 2 files" in log and "  data book: nights.tsv 3" in log
    state = json.loads((tmp_path / ap.STATE).read_text())
    assert state["finished"] >= state["started"] and state["pid"] is None
    assert {k: v["exit"] for k, v in state["steps"].items()} == {"pack": 0, "export": 3, "book": 0}
    assert ap.main(["--local", str(tmp_path), "--skip", "export"], todo=todo) == 0


def test_one_run_at_a_time(tmp_path: Path) -> None:
    import fcntl
    with open(tmp_path / ap.LOCK, "a+") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        assert ap.main(["--local", str(tmp_path)], todo=[("pack", [PY, "-c", "print(1)"])]) == 0
    assert "another run is going on" in (tmp_path / ap.LOG).read_text()
    assert not (tmp_path / ap.STATE).exists()


def test_a_step_that_hangs_is_stopped(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(ap.TIMEOUT_S, "book", 1)
    assert ap.main(["--local", str(tmp_path)], todo=[("book", [PY, "-c", "import time; time.sleep(30)"])]) == 1
    log = (tmp_path / ap.LOG).read_text()
    assert "book: failed in" in log and "stopped after 1 s" in log


def test_the_real_steps_are_packing_the_export_and_the_data_book(tmp_path: Path) -> None:
    steps = dict(ap.steps(tmp_path))
    assert steps["pack"][1:] == [str(ROOT / "scripts" / "pack_old.py"), "--local", str(tmp_path)]
    assert steps["export"][1:] == [str(ROOT / "scripts" / "export_events.py"), "--daily", "--local", str(tmp_path),
                                   "--root", str(tmp_path / "export")]
    book = steps["book"]
    assert str(ROOT / "scripts" / "data_book.py") in book and "--quiet" in book
    if "systemd-run" in book[0]:
        assert f"MemoryMax={ap.MEMORY_MAX}" in book


def test_when_the_jobs_start(tmp_path: Path) -> None:
    clock, started = Clock(), []

    def start(cmd: list[str]) -> FakeProc:
        started.append(cmd)
        return FakeProc()

    k = ap.Kicker(tmp_path, clock=clock, start=start)
    assert k(False) is True  # never ran: due at once (the daily run)
    assert started[0][1:] == [str(ROOT / "scripts" / "after_pull.py"), "--local", str(tmp_path)]
    assert k(True) is False  # still running
    k.proc.done = True
    clock.t += 60
    assert k(True) is False  # something new, but it ran a minute ago
    clock.t += ap.MIN_GAP_S
    assert k(False) is False  # nothing new and not a day yet
    assert k(True) is True  # something new, 30 minutes on
    k.proc.done = True
    clock.t += ap.DAILY_S
    assert k(False) is True  # a day without anything new
    assert len(started) == 3


def test_a_run_by_hand_counts_as_the_last_run(tmp_path: Path) -> None:
    clock = Clock()
    (tmp_path / ap.STATE).write_text(json.dumps(dict(started=clock.t - 60)))
    k = ap.Kicker(tmp_path, clock=clock, start=lambda cmd: FakeProc())
    assert k(True) is False
    clock.t += ap.MIN_GAP_S
    assert k(True) is True


def test_the_mirror_loop_tells_the_jobs_whether_a_pass_brought_something(tmp_path: Path,
                                                                           monkeypatch: pytest.MonkeyPatch) -> None:
    passes = [pp.Pass(new=["recordings/a.f32"]), None, pp.Pass(same=3)]
    seen: list[bool] = []
    stop = threading.Event()

    def fake_pass(*_a: object, **_k: object) -> pp.Pass | None:
        rep = passes.pop(0) if passes else None
        if not passes:
            stop.set()
        return rep

    def after(changed: bool) -> bool:
        seen.append(changed)
        return changed

    class Link:
        changed = threading.Event()

    monkeypatch.setattr(pl, "mirror_pass", fake_pass)
    lines: list[str] = []
    pl.mirror_loop(Link(), tmp_path, 0.0001, pl.Say(lines.append), stop, after=after)  # type: ignore[arg-type]
    assert seen == [True, False, False]
    assert sum("After-pull jobs started" in x for x in lines) == 1


def test_keep_starts_the_kicker_unless_told_not_to() -> None:
    a = pl.parse(["--keep", "--no-after-pull"])
    assert a.no_after_pull is True and pl.parse(["--keep"]).no_after_pull is False
    out = subprocess.run([PY, str(ROOT / "scripts" / "after_pull.py"), "--help"], capture_output=True, text=True)
    assert out.returncode == 0 and "--skip" in out.stdout
