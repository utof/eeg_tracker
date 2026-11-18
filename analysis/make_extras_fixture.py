"""Make app/test/fixtures/night_extras.json for the phone's cross-check (app/test/night_extras_cross_check_test.dart):
what the Python reference (`night_extras.py`) makes of the same input.

  uv run --project analysis python analysis/make_extras_fixture.py RECORDINGS NIGHT NIGHT.sleep.json OUT.json

Two parts, neither with clock times, dates or device numbers:
- `files`: three recorder runs built from the excerpts of app/test/fixtures/detectors.json (recorded signal), placed
  with a sub-second start and pauses between them, joined as `scripts/to_bdf.py` joins a night and run through the
  detectors: the epochs' quality, the bursts and the movements. The test writes the same files and runs the phone's
  `seeNight` on them.
- `night`: the detectors' events over a whole recorded night (seconds from its start), its AnySleep stages and sleep
  periods, a made-up distance to the first whole hour, and the extras the reference makes of them.
"""

from __future__ import annotations

import base64
import gzip
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "scripts"))
import night_extras as nx  # noqa: E402
import night_files as nf  # noqa: E402
import sleep_report as sr  # noqa: E402
import to_bdf  # noqa: E402

DETECTORS_FIXTURE = HERE.parent / "app" / "test" / "fixtures" / "detectors.json"
T0 = 1795468320.37  # unix s: any time works; the fraction makes the join hold a moment before the first run
RUNS = [  # (excerpt name, pause before it in seconds)
    ("night: a one-sided and a jaw burst", 0.0),
    ("night: a short Bluetooth hole", 3.5),
    ("check-in: eyes close to open, blinks", 1.2),
]
BATCH = 25  # samples per index row, as BrainBit sends them
ARRIVAL_S = 0.004  # a batch's index time: just after its last sample
STAGE_CHAR = {"W": "W", "N1": "1", "N2": "2", "N3": "3", "R": "R", "gap": "-"}
MADE_UP_FIRST_EDGE_S = 1234


def excerpt_uv(e: dict[str, Any], scale: int) -> np.ndarray:
    """(n, 4) µV, decoded as the Dart test decodes it (gzip-compressed int32 differences / scale)."""
    d = np.frombuffer(gzip.decompress(base64.b64decode(e["signal"])), dtype="<i4").reshape(4, e["n"])
    return (np.cumsum(d.astype(np.int64), axis=1) / scale).T


def write_run(folder: Path, name: str, t0: float, uv: np.ndarray) -> Path:
    n = len(uv)
    rec = np.zeros(n, dtype=np.dtype([("pack", "<u4"), ("v", "<f4", 4)]))
    rec["pack"] = np.arange(n) % 2048
    rec["v"] = (uv * 1e-6).astype("<f4")
    first = np.arange(0, n, BATCH)
    last = np.minimum(first + BATCH, n)
    idx = np.zeros(len(first), dtype=to_bdf.IDX_DTYPE)
    idx["t"] = t0 + last / to_bdf.FS + ARRIVAL_S
    idx["i"] = first
    path = folder / f"{name}.f32"
    rec.tofile(path)
    idx.tofile(folder / f"{name}.idx")
    return path


def files_part() -> dict[str, Any]:
    src = json.loads(DETECTORS_FIXTURE.read_text())
    by_name = {e["name"]: e for e in src["excerpts"]}
    runs, t = [], T0
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for k, (name, pause) in enumerate(RUNS):
            uv = excerpt_uv(by_name[name], src["scale"])
            t += pause
            runs.append({"excerpt": name, "t0": t, "file": f"run{k}"})
            paths.append(write_run(Path(tmp), f"run{k}", t, uv))
            t += len(uv) / to_bdf.FS
        _, joined, notes = to_bdf.join(paths)
        quality, bursts, moves = nx.events(nx.see(joined, notes))
    return {"runs": runs, "batch": BATCH, "arrival_s": ARRIVAL_S, "samples": len(joined),
            "quality": quality, "bursts": [list(b) for b in bursts], "moves": [list(m) for m in moves]}


def night_part(recordings: Path, night: str, sleep_json: Path) -> dict[str, Any]:
    found = [n for n in nf.nights(nf.recordings(recordings)) if n.name == night]
    if not found:
        raise SystemExit(f"no night {night} in {recordings}")
    start, uv, notes = to_bdf.join([r.path for r in found[0].recs])
    quality, bursts, moves = nx.events(nx.see(uv, notes))
    del uv
    scored = json.loads(sleep_json.read_text())
    if str(scored["start"]) != start.isoformat():
        raise SystemExit("the sleep.json and the recordings start at different times")
    stages = [str(e["anysleep"]) for e in scored["epochs"]]
    periods = [(p["first"], p["last"]) for p in sr.periods(stages)[0]]
    return {
        "quality": "".join(nx.QUALITY_CHAR[q] for q in quality),
        "bursts": [list(b) for b in bursts],
        "moves": [list(m) for m in moves],
        "stages": "".join(STAGE_CHAR[s] for s in stages),
        "periods": [list(p) for p in periods],
        "first_edge_s": MADE_UP_FIRST_EDGE_S,
        "expected": nx.summary(quality, bursts, moves, stages, periods, MADE_UP_FIRST_EDGE_S),
    }


def main(argv: list[str]) -> None:
    if len(argv) != 4:
        raise SystemExit(__doc__)
    out = {"made_by": "analysis/make_extras_fixture.py", "files": files_part(),
           "night": night_part(Path(argv[0]), argv[1], Path(argv[2]))}
    Path(argv[3]).write_text(json.dumps(out, separators=(",", ":")))
    f = out["files"]
    print(f"files: {f['samples']} samples, quality {f['quality']}, bursts {f['bursts']}, moves {f['moves']}")
    x = out["night"]["expected"]
    print(f"night: {len(out['night']['stages'])} epochs, {len(out['night']['bursts'])} bursts, asleep {x['asleep']}")
    print(f"{argv[3]}: {Path(argv[3]).stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main(sys.argv[1:])
