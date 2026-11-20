"""Walking, pace and estimated steps in a recording, on the laptop: the phone's walking pass (app/lib/walking/) with
the Python reference (analysis/walking.py), writing the same `<id>.walk.json` (docs/data-format.md "Walking").

  uv run --project analysis python scripts/walks.py REC.f32 [REC2.f32 ...] [--out _local/walking]
      the files are one recording (joined on the clock, every channel its header names); id = the first's stem
  uv run --project analysis python scripts/walks.py --all [--local _local]
      every recording in <local>/recordings/ without an up-to-date walk file, grouped as the phone's Archive groups
      them (a set starting under 15 minutes after the one before ended, up to 24 hours from the first)

The phone's step counter lines in the recordings' `.log` files (`phone steps N`, written once a minute while
recording) give the phone's steps per minute; where it counted, its steps win. Reads only; writes the walk files.
scripts/export_events.py --daily puts them into each day's `eeg_day` (docs/utof-interface.md).
"""
from __future__ import annotations

import argparse, json, math, os, re, sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
import night_files as nf  # noqa: E402
import packed  # noqa: E402
import recording  # noqa: E402
import to_bdf  # noqa: E402
import walking as wk  # noqa: E402

FORMAT, VERSION = "eeg-tracker-walking", 1
LIMIT_UV = 400_000.0  # the joined signal is clipped here, as the phone's join holds it
CHAIN_GAP_S = 15 * 60  # the Archive's rule (DECISIONS 701): a set under 15 minutes after the one before joins it
MAX_SPAN_S = 24 * 3600
STEP_LINE = re.compile(r"^(\S+) phone steps (\d+)\s*$")
STATE_LINE = re.compile(r"^\S+ phone step counter: (.+?)\s*$")


def log_steps(logs: list[Path]) -> tuple[list[tuple[float, int]], str | None]:
    """The step counter's readings (unix seconds, steps since the phone started) and its last state line ("on",
    "no permission", ...), from the recording's `.log` files."""
    readings: list[tuple[float, int]] = []
    state = None
    for p in logs:
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = STEP_LINE.match(line)
            if m:
                try:
                    readings.append((datetime.fromisoformat(m.group(1)).timestamp(), int(m.group(2))))
                except ValueError:
                    pass
                continue
            s = STATE_LINE.match(line)
            if s:
                state = s.group(1)
    return sorted(readings), state


def iso(t: float) -> str:
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def r1(v: float | None) -> float | None:
    return None if v is None or (isinstance(v, float) and math.isnan(v)) else round(float(v), 1)


def result(rec_id: str, start_unix: float, names: list[str], fs: float, found: wk.Found,
           rows: list[wk.Minute], phone_state: str | None) -> dict:
    """The walk file's content (docs/data-format.md "Walking"): the same fields as the phone's."""
    ws = found.windows
    hop = wk.HOP_S

    def at(i: int, end: bool = False) -> str:
        return iso(start_unix + ws[i].t + (hop / 2 if end else -hop / 2))

    def stretch(s: wk.Stretch) -> dict:
        return dict(kind=s.kind, start=at(s.first), end=at(s.last, True), min=r1(s.seconds() / 60),
                    steps=round(s.steps), pace=r1(s.pace), score=r1(s.score), confidence=s.confidence)

    walks = []
    for w in found.walks:
        walks.append(dict(start=at(w.stretches[0].first), end=at(w.stretches[-1].last, True),
                          walking_min=r1(w.walking_s / 60), stopped_min=r1(w.stopped_s / 60), steps=round(w.steps),
                          pace=r1(w.pace), stops=sum(1 for s in w.stretches if s.kind == "stopped"),
                          stretches=[stretch(s) for s in w.stretches]))
    moving = [i for s in found.moving for i in range(s.first, s.last + 1)]
    clear = [i for i in moving if ws[i].walks]
    score = wk.det.median([ws[i].score for i in clear]) if clear else None
    chk = wk.check(rows)
    by = {"phone": 0.0, "headband": 0.0}
    for r in rows:
        if r.source:
            by[r.source] += r.steps
    return dict(
        format=FORMAT, version=VERSION, detector=wk.VERSION, recording=rec_id,
        start=iso(start_unix), end=iso(start_unix + (ws[-1].t + wk.WINDOW_S / 2 if ws else 0)),
        channels=names, sample_rate=fs, windows=len(ws), read_windows=sum(1 for w in ws if w.read),
        phone_counter=phone_state,
        walking_min=r1(sum(s.seconds() for s in found.moving) / 60),
        running_min=r1(sum(s.seconds() for s in found.moving if s.kind == "running") / 60),
        headband_steps=round(sum(s.steps for s in found.moving)),
        pace=r1(wk.det.median([ws[i].pace for i in clear]) if clear else None),
        confidence=None if score is None else wk.confidence(score),
        steps=round(by["phone"] + by["headband"]), steps_phone=round(by["phone"]), steps_headband=round(by["headband"]),
        check=dict(paired=chk.paired, right=chk.right, headband_steps=r1(chk.hb_steps), phone_steps=r1(chk.phone_steps)),
        walks=walks,
        minutes=[[r.t, r1(r.walk_s), r1(r.run_s), r1(r.hb_steps), r1(r.hb_pace), r1(r.phone), r1(r.steps), r.source,
                  r1(r.walking_s)] for r in rows],
    )


def missing_mask(n: int, fs: float, notes: list[tuple[float, float, str]]) -> np.ndarray:
    miss = np.zeros(n, dtype=bool)
    for onset, dur, text in notes:
        if text in ("BAD_gap", "BAD_padding") and dur > 0:
            a = round(onset * fs)
            miss[a:a + round(dur * fs)] = True
    return miss


def walk_files(paths: list[Path]) -> dict:
    """The walk file of one recording: its `.f32` files (oldest first), every channel of their headers."""
    head = to_bdf.night_header(paths)
    start, uv, notes = to_bdf.join(paths)
    np.clip(uv, -LIMIT_UV, LIMIT_UV, out=uv)
    x = np.ascontiguousarray(uv.T)
    found = wk.find(wk.windows(x, head.sample_rate, missing_mask(x.shape[1], head.sample_rate, notes)))
    readings, state = log_steps([packed.logical(Path(p)).with_suffix(".log") for p in paths])
    rows = wk.minutes(found, start.timestamp(), wk.phone_minutes(readings))
    return result(packed.logical(Path(paths[0])).stem, start.timestamp(), list(head.names), head.sample_rate, found,
                  rows, state)


def key_of(paths: list[Path]) -> str:
    """What a walk file was made from: each raw file's and log's name, size and modified time, and the detector."""
    parts = [wk.VERSION]
    for p in paths:
        plain = packed.logical(Path(p))
        for f in (packed.on_disk(plain) or plain,
                  plain.with_suffix(".idx"), plain.with_suffix(".log")):
            try:
                st = f.stat()
                parts.append(f"{f.name} {st.st_size} {st.st_mtime_ns}")
            except OSError:
                pass
    return "\n".join(parts)


def groups(folder: Path) -> list[list[nf.Rec]]:
    """Every file set of the folder (sleep or not), grouped as the phone's Archive groups them (DECISIONS 701)."""
    recs = []
    for p in packed.raw_files(folder):
        start = nf.stamp_time(p)
        if start is None:
            continue
        try:
            size, h = packed.size(p), recording.read(p)
        except (OSError, recording.RecordingError):
            continue
        if size >= h.record_bytes:
            recs.append(nf.Rec(p, start, nf._end(p, start, size, h.record_bytes, h.sample_rate), size,
                               h.record_bytes, h.sample_rate))
    recs.sort(key=lambda r: (r.start, r.path.name))
    out: list[list[nf.Rec]] = []
    for r in recs:
        if out and r.start - max(x.end for x in out[-1]) < CHAIN_GAP_S and r.start - out[-1][0].start < MAX_SPAN_S:
            out[-1].append(r)
        else:
            out.append([r])
    return out


def write(out_dir: Path, data: dict, key: str) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    f = out_dir / f"{data['recording']}.walk.json"
    tmp = f.with_name(f".{f.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({**data, "key": key}, ensure_ascii=False, separators=(",", ":")) + "\n")
    tmp.replace(f)
    return f


def summary_line(d: dict) -> str:
    walks = d["walks"]
    if not walks:
        return f"{d['recording']}: no walking found ({d['windows']} windows)"
    return (f"{d['recording']}: {d['walking_min']} min walking in {len(walks)} walk(s), {d['steps']} steps "
            f"(phone {d['steps_phone']}, headband {d['steps_headband']}), pace {d['pace']} steps/min, "
            f"{d['confidence']}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--all", action="store_true", help="every recording in <local>/recordings/")
    ap.add_argument("--local", type=Path, default=ROOT / "_local")
    ap.add_argument("--out", type=Path, help="where the walk files go (default <local>/walking)")
    a = ap.parse_args()
    out = a.out or a.local / "walking"
    if a.files:
        paths = sorted((packed.logical(p) for p in a.files), key=lambda p: p.name)
        d = walk_files(paths)
        print(summary_line(d), "->", write(out, d, key_of(paths)))
        return
    if not a.all:
        ap.error("give the .f32 files of one recording, or --all")
    for g in groups(a.local / "recordings"):
        paths = [r.path for r in g]
        key = key_of(paths)
        f = out / f"{paths[0].stem}.walk.json"
        try:
            if json.loads(f.read_text()).get("key") == key:
                continue
        except (OSError, ValueError):
            pass
        try:
            d = walk_files(paths)
        except (recording.RecordingError, ValueError, OSError, SystemExit) as e:
            print(f"{paths[0].stem}: not read: {e}")
            continue
        print(summary_line(d), "->", write(out, d, key))


if __name__ == "__main__":
    main()
