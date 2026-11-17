"""Convert a record_night.py recording (<stamp>.f32 + .idx) to BDF+ and print a quality summary.

usage: to_bdf.py <stamp>.f32 [out.bdf]
Gaps found from batch arrival times are written as annotations; samples stay contiguous.
"""
import struct, sys
from datetime import datetime
from pathlib import Path

import numpy as np
import pyedflib

FS = 250
NAMES = ["O1", "O2", "T3", "T4"]


def load(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    rec = np.fromfile(path, dtype=np.dtype([("pack", "<u4"), ("v", "<f4", 4)]))
    idx = np.fromfile(path.with_suffix(".idx"), dtype=np.dtype([("t", "<f8"), ("i", "<u8")])) \
        if path.with_suffix(".idx").exists() else np.empty(0, dtype=[("t", "<f8"), ("i", "<u8")])
    return rec["v"].astype(np.float64) * 1e6, rec["pack"], idx  # microvolts


def gaps(idx: np.ndarray, min_s: float = 0.5) -> list[tuple[float, float]]:
    """(onset in file seconds, missing seconds) where arrivals paused longer than min_s."""
    if len(idx) < 2:
        return []
    dt = np.diff(idx["t"]); out = []
    for k in np.nonzero(dt > min_s)[0]:
        got = (idx["i"][k + 1] - idx["i"][k]) / FS
        out.append((idx["i"][k + 1] / FS, float(dt[k] - got)))
    return out


def main() -> None:
    src = Path(sys.argv[1]); dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".bdf")
    uv, _pack, idx = load(src)
    if not len(uv):
        raise SystemExit("empty recording")
    lim = 400_000.0  # the headband reports +-0.4 V at the rails
    w = pyedflib.EdfWriter(str(dst), len(NAMES), file_type=pyedflib.FILETYPE_BDFPLUS)
    w.setSignalHeaders([dict(label=n, dimension="uV", sample_frequency=FS, physical_min=-lim, physical_max=lim,
                             digital_min=-8388608, digital_max=8388607, transducer="dry electrode", prefilter="")
                        for n in NAMES])
    w.setStartdatetime(datetime.fromtimestamp(idx["t"][0]) if len(idx) else datetime.strptime(src.stem, "%Y-%m-%d-%H%M%S"))
    w.setEquipment("BrainBit Black")
    w.writeSamples([np.clip(uv[:, c], -lim, lim) for c in range(4)])
    g = gaps(idx)
    for onset, missing in g:
        w.writeAnnotation(onset, -1, f"gap {missing:.1f}s")
    w.close()
    dur = len(uv) / FS
    print(f"{dst}: {dur / 60:.1f} min, {len(g)} gaps, {sum(m for _, m in g):.1f} s missing")
    for c, n in enumerate(NAMES):
        x = uv[:, c]; railed = np.mean(np.abs(x) >= lim * 0.999)
        print(f"  {n}: at the rail {railed:6.1%}   spread {np.std(x - np.median(x)):10.1f} uV")


if __name__ == "__main__":
    main()
