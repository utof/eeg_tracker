"""Pack the raw recordings nothing has written for a day: lossless xz, checked before the original goes.

usage: pack_old.py [--local _local] [--hours 24] [--dry-run]

The owner's decision (2026-11-19): raw recordings older than one day are compressed, losslessly. This packs every
`<stamp>.f32` in <local>/recordings/, <local>/recordings-diy/ and <local>/phone/mornings/ (the laptop's own
recordings, the phone's that import_phone.py or pull_phone.py brought, the DIY board's, the phone's check-ins) into
`<stamp>.f32.xz` with scripts/packed.py: written under a temporary name, unpacked again to check that it gives back
the same bytes (length and SHA-256), then put in place with the original's modified time; only then is the `.f32`
removed. Every reader opens either form (packed.py), and the catalog keeps the original's SHA-256.

Left alone: a file written in the last --hours hours (a night still recording, a copy still arriving), a partial copy
pull_phone.py is still continuing (<local>/phone/pull-state.json), a file under 64 KiB, and the `.idx`, `.log` and
`.markers.jsonl` beside it (small, and read often). Running it again packs only what is new; a run that stopped
half-way is finished or undone by the next. One run at a time (<local>/packing.lock). A run that packed something or
failed appends a line to <local>/packing.jsonl: every file with its bytes before and after and the original's SHA-256.

Exit status 1 when a file could not be packed (it stays as it was). Standard library only: `python3
scripts/pack_old.py` daily.
"""
from __future__ import annotations

import argparse, fcntl, json, sys, time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_phone as ip  # noqa: E402  (where the phone's files land on the laptop)
import packed  # noqa: E402

FOLDERS = ("recordings", "recordings-diy", "phone/mornings")
HOURS = 24.0
RATIO = 0.61  # share saved on a real night (DECISIONS 541): only for the dry run's estimate
DEFAULT_LOCAL = Path(__file__).resolve().parents[1] / "_local"


@dataclass
class Run:
    todo: list[Path] = field(default_factory=list)
    done: list[packed.Packed] = field(default_factory=list)
    failed: list[tuple[Path, str]] = field(default_factory=list)
    recent: int = 0  # written in the last --hours
    partial: int = 0  # pull_phone.py is still continuing them
    small: int = 0
    half: int = 0  # found with their packed copy already in place (a run that stopped half-way)

    @property
    def bytes(self) -> int:
        return sum(p.bytes for p in self.done)

    @property
    def packed_bytes(self) -> int:
        return sum(p.packed_bytes for p in self.done)


def partial_copies(local: Path) -> set[Path]:
    """The laptop paths of the phone's files pull_phone.py fetched only in part so far (it appends to them)."""
    try:
        state = json.loads((local / "phone" / "pull-state.json").read_text(encoding="utf-8"))
        keys = state.get("partial", {}) if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return set()
    out = set()
    for k in keys if isinstance(keys, dict) else ():
        try:
            out.add(ip.target_for(local, ip.safe_path(k)))
        except ip.ManifestError:
            continue
    return out


def choose(local: Path, now: float, hours: float = HOURS) -> Run:
    """What to pack: closed raw files whose last write is over [hours] old."""
    run = Run()
    partial = partial_copies(local)
    for folder in FOLDERS:
        for p in sorted((local / folder).glob("*" + packed.RAW)):
            try:
                st = p.stat()
            except OSError:
                continue
            if not p.is_file():
                continue
            if p in partial:
                run.partial += 1
            elif now - st.st_mtime < hours * 3600:
                run.recent += 1
            elif st.st_size < packed.MIN_BYTES:
                run.small += 1
            else:
                run.todo.append(p)
    return run


def _clean_temps(local: Path) -> None:
    """Temporary files of a run that was stopped (pack() removes its own otherwise); only under the lock."""
    for folder in FOLDERS:
        for t in (local / folder).glob(f".*{packed.PACKED}.packing"):
            t.unlink(missing_ok=True)


def pack_all(run: Run, stop: Callable[[], bool] = lambda: False) -> None:
    for p in run.todo:
        if stop():
            break
        try:
            if packed.packed_path(p).exists():
                run.half += 1
                done = packed.finish(p)
                if done is not None:
                    run.done.append(done)
                    continue
            run.done.append(packed.pack(p))
        except (packed.PackError, OSError) as e:
            run.failed.append((p, str(e)))


def _mb(n: float) -> str:
    return f"{n / 1e6:.1f} MB"


def summary(run: Run, local: Path, dry_run: bool) -> list[str]:
    left = [f"{n} {what}" for n, what in ((run.recent, "written in the last day"),
                                         (run.partial, "partial copies still arriving from the phone"),
                                         (run.small, "under 64 KiB")) if n]
    out = []
    if dry_run:
        total = sum(packed.size(p) for p in run.todo)
        out.append(f"Would pack {len(run.todo)} raw file{'' if len(run.todo) == 1 else 's'}, {_mb(total)} "
                   f"(about {_mb(total * (1 - RATIO))} after, at the {RATIO:.0%} a real night saved); nothing changed.")
    elif run.done:
        saved = 1 - run.packed_bytes / run.bytes if run.bytes else 0.0
        out.append(f"Packed {len(run.done)} raw file{'' if len(run.done) == 1 else 's'}: {_mb(run.bytes)} -> "
                   f"{_mb(run.packed_bytes)} ({saved:.0%} smaller), each checked to unpack to the same bytes.")
    else:
        out.append("Nothing to pack.")
    if left:
        out.append(f"  left alone: {', '.join(left)}")
    if run.half:
        out.append(f"  {run.half} found half-way from a stopped run: finished or packed again")
    for p, why in run.failed:
        out.append(f"PROBLEM: {p.relative_to(local)} not packed: {why}")
    return out


def _record(run: Run, local: Path, now: datetime) -> None:
    line = dict(packed=now.isoformat(timespec="seconds"), files=len(run.done), bytes=run.bytes,
                packed_bytes=run.packed_bytes, failed=len(run.failed),
                list=[dict(path=p.path.relative_to(local).as_posix(), bytes=p.bytes, packed_bytes=p.packed_bytes,
                           sha256=p.sha256) for p in run.done],
                problems=[dict(path=p.relative_to(local).as_posix(), why=why) for p, why in run.failed])
    with open(local / "packing.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(line) + "\n")


def main(argv: list[str] | None = None, out: Callable[[str], object] = print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="the data folder (default: the repo's _local)")
    ap.add_argument("--hours", type=float, default=HOURS, help="pack files not written for this long (default 24)")
    ap.add_argument("--dry-run", action="store_true", help="say what would be packed; change nothing")
    a = ap.parse_args(argv)
    local = a.local.resolve()
    if not local.is_dir():
        out(f"no data folder at {local}")
        return 2
    if a.dry_run:
        run = choose(local, time.time(), a.hours)
        for line in summary(run, local, True):
            out(line)
        return 0
    with open(local / "packing.lock", "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            out("another packing run is going; nothing to do")
            return 0
        _clean_temps(local)
        run = choose(local, time.time(), a.hours)
        pack_all(run)
        if run.done or run.failed:
            _record(run, local, datetime.now().astimezone())
    for line in summary(run, local, False):
        out(line)
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
