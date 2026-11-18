"""Join record_night.py recordings (<stamp>.f32 + .idx) into one BDF+ file and print a quality summary.

usage: to_bdf.py <stamp>.f32 [<stamp>.f32 ...] [-o out.bdf]

One night is often several files, because the recorder restarts after a Bluetooth stall. Files are joined in
time order. Missing time, inside a file or between files, is filled by holding the last value and marked with a
"BAD_gap" annotation, so file time equals wall-clock time and 30 s sleep epochs line up with the clock.
The start is moved back to a whole second (pyedflib 0.1.42 mishandles sub-second starts) and the end is padded
to a whole second with the edge value ("BAD_padding"). Review: docs/research/bdf-plus-writing.md section 7.
"""
import argparse
from datetime import datetime
from pathlib import Path

import numpy as np
import pyedflib

FS = 250
NAMES = ["O1", "O2", "T3", "T4"]
LIM = 400_000  # µV; the headband reports +-0.4 V at the rails. int: fits the 8-char header field
MIN_GAP_S = 0.5
IDX_DTYPE = np.dtype([("t", "<f8"), ("i", "<u8")])


def load(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Samples in µV (n x 4) and the batch index (arrival time, first-sample index)."""
    rec = np.fromfile(path, dtype=np.dtype([("pack", "<u4"), ("v", "<f4", 4)]))
    ip = path.with_suffix(".idx")
    idx = np.fromfile(ip, dtype=IDX_DTYPE) if ip.exists() else np.empty(0, dtype=IDX_DTYPE)
    idx = idx[idx["i"] < len(rec)]  # an index row can outlive a crash that lost its samples
    return rec["v"].astype(np.float64) * 1e6, idx


def runs(path: Path) -> list[tuple[float, np.ndarray]]:
    """Split one file into runs of unbroken samples: (wall-clock time of the first sample, µV array)."""
    uv, idx = load(path)
    if not len(uv):
        return []
    if not len(idx):
        return [(datetime.strptime(path.stem, "%Y-%m-%d-%H%M%S").timestamp(), uv)]
    first = idx["i"].astype(np.int64)
    dur = (np.append(first[1:], len(uv)) - first) / FS
    t0 = idx["t"] - dur  # a batch arrives just after its last sample
    out = []; start = 0
    for k in range(1, len(idx)):
        if t0[k] - idx["t"][k - 1] > MIN_GAP_S:  # nothing was sampled between these arrivals
            out.append((t0[start], uv[first[start]:first[k]])); start = k
    out.append((t0[start], uv[first[start]:]))
    if first[0] > 0:  # samples before the first index row (should not happen) join the first run
        out[0] = (out[0][0] - first[0] / FS, np.vstack([uv[:first[0]], out[0][1]]))
    return out


def join(paths: list[Path]) -> tuple[datetime, np.ndarray, list[tuple[float, float, str]]]:
    """One array from all runs; returns (start, µV n x 4, annotations as (onset s, duration s, text))."""
    rs = sorted((r for p in paths for r in runs(p)), key=lambda r: r[0])
    if not rs:
        raise SystemExit("empty recording")
    start = datetime.fromtimestamp(rs[0][0]).replace(microsecond=0)
    parts: list[np.ndarray] = []; notes: list[tuple[float, float, str]] = []; n = 0
    for t, x in rs:
        want = round((t - start.timestamp()) * FS)  # where this run belongs on the clock
        if want > n:
            hold = parts[-1][-1] if parts else x[0]
            parts.append(np.repeat(hold[None, :], want - n, axis=0))
            notes.append((n / FS, (want - n) / FS, "BAD_gap")); n = want
        elif want < n - FS:  # overlap of over a second means the clocks disagree: keep data, say so
            notes.append((n / FS, -1, f"overlap {(n - want) / FS:.1f}s"))
        parts.append(x); n += len(x)
    pad = (-n) % FS
    if pad:
        parts.append(np.repeat(parts[-1][-1][None, :], pad, axis=0))
        notes.append((n / FS, pad / FS, "BAD_padding"))
    return start, np.vstack(parts), notes


def write(dst: Path, start: datetime, uv: np.ndarray, notes: list[tuple[float, float, str]]) -> None:
    w = pyedflib.EdfWriter(str(dst), len(NAMES), file_type=pyedflib.FILETYPE_BDFPLUS)
    try:
        w.setSignalHeaders([dict(label=n, dimension="uV", sample_frequency=FS, physical_min=-LIM, physical_max=LIM,
                                 digital_min=-8388608, digital_max=8388607, transducer="dry electrode", prefilter="")
                            for n in NAMES])
        w.setStartdatetime(start)
        w.setEquipment("BrainBit_Black")  # EDF header fields: ASCII, no spaces
        clipped = np.clip(uv, -LIM, LIM)
        w.writeSamples([np.ascontiguousarray(clipped[:, c]) for c in range(len(NAMES))])
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
    dst = a.out or a.files[0].with_suffix(".bdf")
    start, uv, notes = join(a.files)
    write(dst, start, uv, notes)
    total = len(uv) / FS
    missing = sum(d for _, d, t in notes if t == "BAD_gap")
    epochs = int(total // 30)
    bad = sum(sum(max(0.0, min(o + d, (e + 1) * 30) - max(o, e * 30)) for o, d, t in notes if t.startswith("BAD")) > 5
              for e in range(epochs))
    print(f"{dst}: starts {start:%Y-%m-%d %H:%M:%S}, {total / 3600:.2f} h, {len(a.files)} file(s), "
          f"{sum(t == 'BAD_gap' for _, _, t in notes)} gaps, {missing / 60:.1f} min missing, "
          f"{bad}/{epochs} 30-s epochs miss over 5 s")
    for c, name in enumerate(NAMES):
        x = uv[:, c]; railed = np.mean(np.abs(x) >= LIM * 0.999)
        print(f"  {name}: at the rail {railed:6.1%}   spread {np.std(x - np.median(x)):10.1f} uV")


if __name__ == "__main__":
    main()
