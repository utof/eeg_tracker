"""Join record_night.py recordings (<stamp>.f32 + .idx) into one BDF+ file and print a quality summary.

usage: to_bdf.py <stamp>.f32 [<stamp>.f32 ...] [-o out.bdf]

A recording packed after a day (<stamp>.f32.xz, scripts/packed.py) is read the same; either name may be given.

Any number of channels (docs/data-format.md "The recording header"): the channels, their names and the rate come
from each file's <stamp>.header.json (scripts/recording.py; files from before the header read as they did: the DIY
board's by its .log's format line, else the BrainBit's O1 O2 T3 T4 at 250 Hz). The BDF has one signal per channel,
labelled with the channel's name. Files that do not hold the same channels at the same rate are not joined.

One night is often several files, because the recorder restarts after a Bluetooth stall. Files are joined in
time order. Missing time, inside a file or between files, is filled by holding the last value and marked with a
"BAD_gap" annotation, so file time equals wall-clock time and 30 s sleep epochs line up with the clock.
The start is moved back to a whole second (pyedflib 0.1.42 mishandles sub-second starts) and the end is padded
to a whole second with the edge value ("BAD_padding"). Review: docs/research/bdf-plus-writing.md section 7.
"""
import argparse, json, math, sys
from datetime import datetime
from pathlib import Path
from typing import Sequence

import numpy as np
import pyedflib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import packed  # noqa: E402
import recording  # noqa: E402

FS = 250  # the BrainBit's rate; a file's own is in its header
NAMES = ["O1", "O2", "T3", "T4"]  # the BrainBit's channels; a file's own are in its header
LIM = 400_000  # µV; the headband reports +-0.4 V at the rails. int: fits the 8-char header field
MIN_GAP_S = 0.5
LABEL_MAX = 16  # characters of a BDF signal label
IDX_DTYPE = np.dtype([("t", "<f8"), ("i", "<u8")])
REC_DTYPE = np.dtype([("pack", "<u4"), ("v", "<f4", 4)])  # the BrainBit's record


def rec_dtype(n: int) -> np.dtype:
    """One .f32 record of n channels: the uint32 counter, then n float32 volts (`<I<n>f`)."""
    return np.dtype([("pack", "<u4"), ("v", "<f4", (n,))])


def load(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Samples in µV (n x channels, every channel in record order) and the batch index (arrival time, first-sample
    index). [path] is the .f32, plain or packed (by either name)."""
    path = packed.logical(Path(path))
    dtype = rec_dtype(recording.read(path).n)
    raw = packed.read_bytes(path)
    rec = np.frombuffer(raw, dtype=dtype, count=len(raw) // dtype.itemsize)
    ip = path.with_suffix(".idx")
    idx = np.fromfile(ip, dtype=IDX_DTYPE) if ip.exists() else np.empty(0, dtype=IDX_DTYPE)
    idx = idx[idx["i"] < len(rec)]  # an index row can outlive a crash that lost its samples
    return rec["v"].astype(np.float64) * 1e6, idx


def runs(path: Path) -> list[tuple[float, np.ndarray]]:
    """Split one file into runs of unbroken samples: (wall-clock time of the first sample, µV array)."""
    return [(t, x) for t, x, _ in _runs_ends(path)]


def _runs_ends(path: Path) -> list[tuple[float, np.ndarray, float]]:
    """runs(), each with the arrival time of its last batch (by its length when the file has no index)."""
    path = packed.logical(Path(path))
    fs = recording.read(path).sample_rate
    uv, idx = load(path)
    if not len(uv):
        return []
    if not len(idx):
        t = datetime.strptime(path.stem, "%Y-%m-%d-%H%M%S").timestamp()
        return [(t, uv, t + len(uv) / fs)]
    first = idx["i"].astype(np.int64)
    dur = (np.append(first[1:], len(uv)) - first) / fs
    t0 = idx["t"] - dur  # a batch arrives just after its last sample
    out = []; start = 0
    for k in range(1, len(idx)):
        if t0[k] - idx["t"][k - 1] > MIN_GAP_S:  # nothing was sampled between these arrivals
            out.append((t0[start], uv[first[start]:first[k]], float(idx["t"][k - 1]))); start = k
    out.append((t0[start], uv[first[start]:], float(idx["t"][-1])))
    if first[0] > 0:  # samples before the first index row (should not happen) join the first run
        out[0] = (out[0][0] - first[0] / fs, np.vstack([uv[:first[0]], out[0][1]]), out[0][2])
    return out


def chains(paths: Sequence[Path]) -> list[tuple[float, np.ndarray]]:
    """Every run of the files, sorted by start, with the runs that follow each other without a gap made one. A run
    is joined to the one before it when it is the first of a file set that goes on from the set before: the same
    recording (both headers name it) and its first sample within MIN_GAP_S of the arrival of that set's last batch,
    the rule that says what is unbroken inside one file. That is a roll-over (the phone closes a file set after 4 hours
    and goes on in a new one on the same connection, DECISIONS 1036): the headband never stopped, so no time is missing
    and nothing is held between the two. After a drop the next set starts seconds later, never this close. The phone's
    twin: app/lib/sleep/night_signal.dart `chainsOf`."""
    found = []
    for p in paths:
        p = packed.logical(Path(p))
        rec = recording.read(p).recording
        for k, (t, x, end) in enumerate(_runs_ends(p)):
            found.append((t, x, end, rec, p, k == 0))
    found.sort(key=lambda r: r[0])
    groups: list[list[tuple]] = []
    for r in found:
        prev = groups[-1][-1] if groups else None
        goes_on = (prev is not None and prev[4] != r[4] and r[5] and r[3] is not None and r[3] == prev[3]
                   and abs(r[0] - prev[2]) <= MIN_GAP_S)
        if goes_on:
            groups[-1].append(r)
        else:
            groups.append([r])
    return [(g[0][0], g[0][1] if len(g) == 1 else np.vstack([r[1] for r in g])) for g in groups]


def night_header(paths: Sequence[Path]) -> recording.Header:
    """What the files hold, when they all hold the same channels (names in the same order) at the same rate: the
    first file's header. Otherwise a recording.RecordingError that names two files that differ."""
    if not paths:
        raise SystemExit("empty recording")
    heads = [(packed.logical(Path(p)), recording.read(p)) for p in paths]
    p0, h0 = heads[0]
    for p, h in heads[1:]:
        if h.names != h0.names or h.sample_rate != h0.sample_rate:
            raise recording.RecordingError(
                f"these recordings do not hold the same channels, so they are not joined: {p0.name} has "
                f"{' '.join(h0.names)} at {h0.sample_rate:g} Hz, {p.name} has {' '.join(h.names)} at "
                f"{h.sample_rate:g} Hz; join each kind by itself")
    return h0


def clip_runs(rs: list[tuple[float, np.ndarray]], windows: Sequence[tuple[float, float]], fs: float
              ) -> list[tuple[float, np.ndarray]]:
    """The parts of the runs inside any of the windows (unix seconds): samples outside every window are dropped, so a
    scorer that scales over its whole input never sees the awake hours around a sleep span."""
    out = []
    for t, x in rs:
        for a, b in windows:
            i0, i1 = max(0, math.ceil((a - t) * fs)), min(len(x), math.floor((b - t) * fs))
            if i1 > i0:
                out.append((t + i0 / fs, x[i0:i1]))
    return out


def join(paths: list[Path], windows: Sequence[tuple[float, float]] | None = None
         ) -> tuple[datetime, np.ndarray, list[tuple[float, float, str]]]:
    """One array from all runs; returns (start, µV n x channels, annotations as (onset s, duration s, text)). The
    files must hold the same channels at the same rate (night_header, which also names them). With `windows` (unix
    seconds: the sleep spans of a night) only the samples inside them are read; the time between two windows is a
    BAD_gap, as any other gap."""
    fs = night_header(paths).sample_rate
    rs = chains(paths)  # sorted by start; a roll-over's two sides are one run
    if windows is not None:
        rs = sorted(clip_runs(rs, windows, fs), key=lambda r: r[0])
    if not rs:
        raise SystemExit("empty recording")
    start = datetime.fromtimestamp(rs[0][0]).replace(microsecond=0)
    parts: list[np.ndarray] = []; notes: list[tuple[float, float, str]] = []; n = 0
    for t, x in rs:
        want = round((t - start.timestamp()) * fs)  # where this run belongs on the clock
        if want > n:
            hold = parts[-1][-1] if parts else x[0]
            parts.append(np.repeat(hold[None, :], want - n, axis=0))
            notes.append((n / fs, (want - n) / fs, "BAD_gap")); n = want
        elif want < n - fs:  # overlap of over a second means the clocks disagree: keep data, say so
            notes.append((n / fs, -1, f"overlap {(n - want) / fs:.1f}s"))
        parts.append(x); n += len(x)
    for p in paths:  # page markers (scripts/web/ pages POST /marker) become annotations at their clock time
        mf = packed.logical(Path(p)).with_suffix(".markers.jsonl")
        for line in (mf.read_text().splitlines() if mf.exists() else []):
            try: m = json.loads(line)
            except json.JSONDecodeError: continue
            if windows is not None and not any(a <= m["t"] <= b for a, b in windows):
                continue
            notes.append((max(0.0, round(m["t"] - start.timestamp(), 3)), -1, str(m.get("text", "marker"))))
    pad = (-n) % round(fs)
    if pad:
        parts.append(np.repeat(parts[-1][-1][None, :], pad, axis=0))
        notes.append((n / fs, pad / fs, "BAD_padding"))
    return start, np.vstack(parts), notes


def join_sites(paths: list[Path], wanted: Sequence[str], who: str, fs: int = FS
               ) -> tuple[datetime, np.ndarray, list[tuple[float, float, str]]]:
    """join() for a feature that reads particular sites at one rate (the detectors: O1 O2 T3 T4 at 250 Hz): only the
    `wanted` channels, in that order, found by name or 10-10 site (recording.pick). A recording without one, or at
    another rate, is a recording.RecordingError in words, raised before any sample is read."""
    h = night_header(paths)
    where = recording.pick(h, wanted, who)
    if h.sample_rate != fs:
        raise recording.RecordingError(f"{who} reads {fs:g} Hz; this recording ({h.describe()}) is {h.sample_rate:g} Hz")
    start, uv, notes = join(paths)
    return start, (uv if where == list(range(uv.shape[1])) else np.ascontiguousarray(uv[:, where])), notes


def equipment(h: recording.Header) -> str:
    """The BDF's equipment field (ASCII, no spaces): `BrainBit_Black` for the headband, as before."""
    if h.device == recording.BRAINBIT:
        return "BrainBit_Black"
    if not h.device:
        return "unknown"
    return "".join(c if c.isascii() and c.isalnum() else "_" for c in h.device) or "unknown"


def write(dst: Path, start: datetime, uv: np.ndarray, notes: list[tuple[float, float, str]],
          names: Sequence[str] = tuple(NAMES), fs: int | float = FS, device: str = "BrainBit_Black") -> None:
    """The BDF+ file: one signal per column of `uv`, labelled with `names` (the BrainBit's by default)."""
    if len(names) != uv.shape[1]:
        raise recording.RecordingError(f"{dst.name}: {uv.shape[1]} channels of samples but {len(names)} names")
    bad = [n for n in names if len(n) > LABEL_MAX or not n.isascii()]
    if bad:
        raise recording.RecordingError(f"a BDF label holds up to {LABEL_MAX} ASCII characters; cannot write "
                                       f"{', '.join(bad)} to {dst.name}")
    if fs != int(fs):
        raise recording.RecordingError(f"a BDF from this tool needs a whole number of samples a second, not {fs:g}")
    w = pyedflib.EdfWriter(str(dst), len(names), file_type=pyedflib.FILETYPE_BDFPLUS)
    try:
        w.setSignalHeaders([dict(label=n, dimension="uV", sample_frequency=int(fs), physical_min=-LIM, physical_max=LIM,
                                 digital_min=-8388608, digital_max=8388607, transducer="dry electrode", prefilter="")
                            for n in names])
        w.setStartdatetime(start)
        w.setEquipment(device)  # EDF header fields: ASCII, no spaces
        clipped = np.clip(uv, -LIM, LIM)
        w.writeSamples([np.ascontiguousarray(clipped[:, c]) for c in range(len(names))])
        for onset, dur, text in notes:
            if w.writeAnnotation(onset, dur, text[:40]) != 0:
                raise SystemExit(f"annotation not written: {onset} {text}")
    finally:
        w.close()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("-o", "--out", type=Path)
    a = ap.parse_args()
    a.files = [packed.logical(f) for f in a.files]
    dst = a.out or a.files[0].with_suffix(".bdf")
    try:
        h = night_header(a.files)
        start, uv, notes = join(a.files)
        write(dst, start, uv, notes, h.names, h.sample_rate, equipment(h))
    except recording.RecordingError as e:
        raise SystemExit(str(e)) from e
    fs = h.sample_rate
    total = len(uv) / fs
    missing = sum(d for _, d, t in notes if t == "BAD_gap")
    epochs = int(total // 30)
    bad = sum(sum(max(0.0, min(o + d, (e + 1) * 30) - max(o, e * 30)) for o, d, t in notes if t.startswith("BAD")) > 5
              for e in range(epochs))
    print(f"{dst}: starts {start:%Y-%m-%d %H:%M:%S}, {total / 3600:.2f} h, {len(a.files)} file(s), "
          f"{sum(t == 'BAD_gap' for _, _, t in notes)} gaps, {missing / 60:.1f} min missing, "
          f"{bad}/{epochs} 30-s epochs miss over 5 s")
    for c, name in enumerate(h.names):
        x = uv[:, c]; railed = np.mean(np.abs(x) >= LIM * 0.999)
        print(f"  {name}: at the rail {railed:6.1%}   spread {np.std(x - np.median(x)):10.1f} uV")


if __name__ == "__main__":
    main()
