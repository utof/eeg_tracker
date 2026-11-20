"""Raw file sets with any number of channels for the tests: <stamp>.f32 (`<I<n>f`, volts), <stamp>.idx (one batch a
second), and, as asked, the <stamp>.header.json (scripts/recording.py), only the .log's format line (a DIY file from
before the header), or neither (a BrainBit file from before it)."""
from datetime import datetime
from pathlib import Path

import numpy as np

import recording as rc

SEED = 20261120
EIGHT = tuple(f"Ch{i}" for i in range(1, 9))
MIXED = ("Fz", "T8", "O2", "C3", "O1", "T7", "C4", "Pz")  # holds O1 O2 T3 T4 by site, out of order


def volts(n: int, channels: int, seed: int = SEED) -> np.ndarray:
    """(n, channels) float32 volts: noise of 20 µV, each channel with its own offset so a swap shows."""
    rng = np.random.default_rng(seed)
    return (rng.normal(0, 20e-6, (n, channels)) + np.arange(channels) * 5e-6).astype("<f4")


def write_set(folder: Path, start: datetime, v: np.ndarray, names: tuple[str, ...], fs: int = 250, how: str = "header",
              header: rc.Header | None = None) -> Path:
    """how: "header" (<stamp>.header.json), "log" (the DIY format line only) or "none"."""
    n, channels = v.shape
    assert channels == len(names)
    rec = np.zeros(n, dtype=[("pack", "<u4"), ("v", "<f4", (channels,))])
    rec["pack"] = np.arange(n); rec["v"] = v
    stem = start.strftime("%Y-%m-%d-%H%M%S")
    f32 = folder / f"{stem}.f32"
    rec.tofile(f32)
    k = np.arange(max(1, n // fs))
    idx = np.zeros(len(k), dtype=[("t", "<f8"), ("i", "<u8")])
    idx["t"] = start.timestamp() + k + 1; idx["i"] = k * fs
    idx.tofile(folder / f"{stem}.idx")
    if how == "header":
        rc.write(f32, header or rc.diy_board(names, fs, layout="test", made_by="analysis/tests/nch_files.py"))
    elif how == "log":
        (folder / f"{stem}.log").write_text(
            f"{start.isoformat(timespec='milliseconds')} driver DIY board (scripts/record_diy.py)\n"
            f"{start.isoformat(timespec='milliseconds')} format .f32 records <I{channels}f: board sequence number, "
            f"then {' '.join(names)} in volts; {fs} Hz\n")
    else:
        assert how == "none"
    return f32
