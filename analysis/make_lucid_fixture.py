"""Make app/test/fixtures/lucid_signals.json: excerpts of the owner's recorded night with synthetic dream signals drawn
over them, and what the Python reference (`lucid_signals.py`, `lucid_cues.quiet_back`) finds in them, for the Dart
port's cross-check (app/test/lucid_signals_test.dart).

  uv run --project analysis python analysis/make_lucid_fixture.py NIGHT.bdf NIGHT.sleep.json OUT.json

Nobody made a dream signal in the owner's recordings, so the signals are drawn on top (`lrlr` below; the tests use it
too). The excerpts carry no clock times, names or device numbers; signals are stored as in detectors.json (0.05 µV
steps, gzip-compressed int32 differences), so both sides start from the very same numbers.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import lucid_cues as lc  # noqa: E402
import lucid_signals as ls  # noqa: E402
import make_detector_fixture as mdf  # noqa: E402
from make_gesture_fixture import double_clench, g9, step  # noqa: E402

FS = det.FS


def lrlr(x: np.ndarray, at_s: float, uv: float = 120.0, pairs: int = 2, every_s: float = 0.6) -> None:
    """Left-right [pairs] times from the middle: out by +uv, across by -2 uv and +2 uv, back to the middle."""
    step(x, at_s, uv)
    sign = -1.0
    for j in range(2 * pairs - 1):
        step(x, at_s + every_s * (j + 1), sign * 2 * uv)
        sign = -sign
    step(x, at_s + every_s * 2 * pairs, sign * uv)


def case(name: str, x: det.Floats, miss: det.Bools, sweep: float, clench_x: float | None) -> dict[str, Any]:
    blob, xq = mdf.encode(x)
    moves = det.eye_moves(xq, miss)
    quiet = lc.quiet_back(xq, moves)
    sig = ls.signals(moves, sweep)
    out: dict[str, Any] = {
        "name": name,
        "n": int(x.shape[1]),
        "signal": blob,
        "missing": mdf.spans(miss),
        "sweep": sweep,
        "clenchX": clench_x,
        "moves": [[m.i, g9(m.step)] for m in moves],
        "quiet": quiet,
        "bursts": lc.burst_seconds(quiet),
        "signals": [[s.start, s.end, s.sweeps, g9(s.size)] for s in sig],
        "clenches": [] if clench_x is None else [[g.start, g.end, g.at] for g in ls.clenches(xq, miss, clench_x)],
    }
    return out


def first(stages: list[str], want: str, from_epoch: int, run: int) -> int:
    """The first epoch from [from_epoch] that starts [run] epochs of [want] in a row."""
    for e in range(from_epoch, len(stages) - run):
        if all(s == want for s in stages[e : e + run]):
            return e
    raise SystemExit(f"no {run} epochs of {want}")


def main(argv: list[str]) -> None:
    if len(argv) != 3:
        raise SystemExit(__doc__)
    import validate_detectors as val

    bdf, sleep, out = (Path(a) for a in argv)
    x, miss, _ = val.load_bdf(bdf)
    stages, _ = val.load_stages(sleep)
    late = int(lc.CUES_FROM_H * 120)
    cases: list[dict[str, Any]] = []

    e = first(stages, "R", late, 4)
    a, n = e * lc.EPOCH_S * FS, 70 * FS
    y, m = x[:, a : a + n].copy(), miss[a : a + n].copy()
    lrlr(y, 30.0, uv=110.0)
    lrlr(y, 50.0, uv=110.0, pairs=3)
    cases.append(case("dream sleep: its own eye movements, then LRLR and LRLRLR drawn", y, m, ls.SWEEP_UV, None))

    e = first(stages, "N3", 0, 4)
    a = e * lc.EPOCH_S * FS
    y, m = x[:, a : a + n].copy(), miss[a : a + n].copy()
    lrlr(y, 30.0, uv=110.0)
    cases.append(case("deep sleep: its own waves, then an LRLR drawn over them", y, m, ls.SWEEP_UV, None))

    e = first(stages, "N2", late, 4)
    a = e * lc.EPOCH_S * FS
    y, m = mdf.with_hole(x[:, a : a + n], miss[a : a + n], 20 * FS, 40)
    lrlr(y, 15.0, uv=40.0)
    lrlr(y, 30.0, uv=40.0, every_s=0.5)
    double_clench(y, 50.0, uv=30.0)
    cases.append(case("light sleep: small LRLRs for a calibrated look size, a hole, and a double clench", y, m, 60.0, 20.0))
    del x

    out.write_text(json.dumps({"version": 1, "fs": FS, "scale": mdf.SCALE, "cases": cases}, separators=(",", ":")))
    print(out, out.stat().st_size // 1024, "KB;", [(c["name"][:20], len(c["moves"]), c["signals"], c["clenches"]) for c in cases])


if __name__ == "__main__":
    main(sys.argv[1:])
