"""Make app/test/fixtures/rem_check.json for the phone's cross-check (app/test/rem_check_cross_check_test.dart): what
the Python reference (`rem_check.py`) makes of the same input. Made-up signals and nights only: the owner's EEG never
goes into the repository.

  uv run --project analysis python analysis/make_rem_fixture.py [OUT.json]

Parts:
- `probs`: probabilities and the report's `probs` the reference encodes from them.
- `pairs`: recording headers (as `<stamp>.header.json` holds them) and the eye pair the reference picks, or null.
- `signal`: a synthetic left-right pair (µV x 10 as int32 differences, gzip, base64) with glances, a movement on both
  sides, one on one side, missing seconds and a gross artefact; each second's swing, correlation and artefact level,
  and the eye-movement seconds per epoch.
- `files`: the same signal as T3 and T4 of a BrainBit recording cut into two recorder runs with a pause between them,
  joined as `scripts/to_bdf.py` joins a night; the eye-movement seconds per epoch over the joined night. The test
  writes the same files and runs the phone's `seeNight` on them.
- `nights`: made-up nights (stages, periods, probabilities in permille, eye movements) with the check and its words.
"""

from __future__ import annotations

import base64
import gzip
import json
import math
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "scripts"))
import night_extras as nx  # noqa: E402
import recording  # noqa: E402
import rem_check as rc  # noqa: E402
import to_bdf  # noqa: E402

OUT = HERE.parent / "app" / "test" / "fixtures" / "rem_check.json"
FS = 250
SCALE = 10  # the signal in 0.1 µV
EPOCHS = 4
T0 = 1795468320.37  # unix s: any time works; the fraction makes the join hold a moment before the first run
CUT = 15000 + 1234  # the second run starts here, after a pause
PAUSE_S = 3.5
BATCH = 25
ARRIVAL_S = 0.004


def _glance(x: np.ndarray, second: int, size: float, at: int = 50) -> None:
    """A side-to-side glance: a 0.1 s step of `size` µV and back 0.5 s later."""
    ramp = np.linspace(0, size, 25)
    a = second * FS + at
    x[a:a + 25] += ramp
    x[a + 25:a + 125] += size
    x[a + 125:a + 150] += ramp[::-1]


def signal() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(left, right, missing) over EPOCHS epochs, quantized to 0.1 µV."""
    n = EPOCHS * 30 * FS
    rng = np.random.default_rng(20261120)
    left, right = 20_000 + rng.normal(0, 2, n), -5_000 + rng.normal(0, 2, n)
    eyes, both, one = np.zeros(n), np.zeros(n), np.zeros(n)
    for s in (2, 5, 9, 10, 14, 20, 26):  # epoch 0: glances of 50 µV, two in a row
        _glance(eyes, s, 50)
    for s in (33, 37, 41):  # epoch 1: movements on both sides alike, and on one side
        _glance(both, s, 120)
    for s in (45, 49, 53):
        _glance(one, s, 120)
    for s in (62, 66, 80, 84):  # epoch 2: big glances (they count twice) around 3 missing seconds
        _glance(eyes, s, 100)
    for s in (92, 95, 99):  # epoch 3: glances, and a jump of 3 mV on one electrode
        _glance(eyes, s, 50)
    left += eyes / 2 + both + one
    right += -eyes / 2 + both + one / 5
    left[110 * FS:] += 3_000
    missing = np.zeros(n, bool)
    missing[70 * FS:73 * FS] = True
    q = lambda v: np.round(v * SCALE) / SCALE  # noqa: E731
    return q(left), q(right), missing


def _pack(*channels: np.ndarray) -> str:
    d = np.concatenate([np.diff(np.round(c * SCALE).astype(np.int64), prepend=0) for c in channels]).astype("<i4")
    return base64.b64encode(gzip.compress(d.tobytes(), mtime=0)).decode()


def _floats(v: np.ndarray) -> list[float | None]:
    return [None if not math.isfinite(x) else float(x) for x in v]


def signal_part() -> dict[str, Any]:
    left, right, missing = signal()
    swing, r, big = rc.eye_seconds(left, right)
    held = np.flatnonzero(missing)
    return {"n": len(left), "scale": SCALE, "signal": _pack(left, right),
            "missing": [int(held[0]), int(held[-1]) + 1],
            "swing": _floats(swing), "r": _floats(r), "big": _floats(big),
            "epochs": rc.eye_epochs(left, right, missing)}


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
    """The pair as T3 T4 (and O1 O2: the same values) of two BrainBit runs, joined and counted as sleep_report.py does."""
    left, right, _ = signal()
    four = np.stack([left, right, left, right], axis=1)
    with tempfile.TemporaryDirectory() as tmp:
        a = write_run(Path(tmp), "run0", T0, four[:CUT])
        t1 = T0 + CUT / FS + PAUSE_S
        b = write_run(Path(tmp), "run1", t1, four[CUT:])
        head = to_bdf.night_header([a, b])
        pair = rc.eye_pair(head)
        _, joined, notes = to_bdf.join([a, b])
        lim = nx.LIMIT_UV
        eye = rc.eye_epochs(np.clip(joined[:, pair.left], -lim, lim), np.clip(joined[:, pair.right], -lim, lim),
                            nx.missing_mask(len(joined), notes))
    return {"runs": [{"file": "run0", "t0": T0, "from": 0, "to": CUT}, {"file": "run1", "t0": t1, "from": CUT,
                                                                         "to": len(left)}],
            "batch": BATCH, "arrival_s": ARRIVAL_S, "samples": len(joined), "pair": pair.label, "epochs": eye}


def probs_part() -> dict[str, Any]:
    rows = [[0.1, 0.2, 0.3, 0.3, 0.1], [0.0004, 0.0005, 0.9991, 0.0, 0.0], [1.0, 0.0, 0.0, 0.0, 0.0],
            [0.12345, 0.23456, 0.0015, 0.6405, 0.00049]]
    return {"rows": rows, "encoded": rc.encode_probs(rows), "decoded": rc.decode_probs(rc.encode_probs(rows))}


def pairs_part() -> list[dict[str, Any]]:
    loc, roc = (-0.62, 0.74, -0.26), (0.63, 0.73, -0.27)
    made = [
        ("BrainBit", recording.brainbit()),
        ("a helmet with F7 F8 and T7 T8", recording.diy_board(("O1", "T8", "F8", "Cz", "T7", "F7", "O2", "Fz"), 250)),
        ("T7 and T8 only", recording.diy_board(("O1", "T8", "Cz", "T7"), 250)),
        ("the breadboard's plan", recording.diy_board(("O1", "O2", "Fz", "Fp1"), 250)),
        ("left sides only", recording.diy_board(("F7", "O1", "O2", "T7"), 250)),
        ("electrodes at the eye corners", recording.Header(
            (recording.Channel("O1", "O1"), recording.Channel("LOC", None, loc), recording.Channel("ROC", None, roc)),
            250, recording.SEQUENCE_NUMBER)),
        ("not mirrored", recording.Header(
            (recording.Channel("LOC", None, loc), recording.Channel("X", None, (0.25, 0.92, -0.30))),
            250, recording.SEQUENCE_NUMBER)),
    ]
    out = []
    for what, h in made:
        p = rc.eye_pair(h)
        out.append({"what": what, "header": recording.to_json(h),
                    "pair": None if p is None else {"left": p.left, "right": p.right, "label": p.label}})
    return out


def _night(what: str, stages: list[str], periods: list[tuple[int, int]], probs: list[list[int]] | None,
           eye: dict[str, Any] | None) -> dict[str, Any]:
    c = rc.night_check(stages, periods, probs, eye)
    return {"what": what, "stages": stages, "periods": [list(p) for p in periods], "probs": probs, "eye": eye,
            "check": c, "lines": rc.check_lines(c)}


def nights_part() -> list[dict[str, Any]]:
    W, N1, N2, N3, R, GAP = "W", "N1", "N2", "N3", "R", "gap"  # noqa: N806
    rng = np.random.default_rng(7)
    out = []
    st = [W] * 10 + [N2] * 297 + [R] * 86 + [N2] * 300 + [R] * 20 + [N3] * 130
    ep: list[int | None] = [int(x) for x in rng.integers(0, 12, len(st))]
    for e in range(0, len(st), 37):
        ep[e] = None
    probs = [[int(x) for x in rng.integers(0, 200, 5)] for _ in st]
    out.append(_night("little dream sleep", st, [(10, len(st) - 1)], probs, rc.eye_measured("T3-T4", ep)))
    st = ([W] * 20 + [N1] * 4 + [N2] * 60 + [R] * 10 + [GAP] * 3 + [N2] * 20 + [N3] * 10 + [R] * 20 + [W] * 150
          + [N2] * 30 + [R] * 6 + [W] * 4 + [R] * 2)
    probs = [[int(x) for x in rng.integers(0, 1000, 5)] for _ in st]
    ep = [int(x) for x in rng.integers(0, 31, len(st))]
    periods = [(20, 146), (297, 332)]
    out.append(_night("two periods, a gap, stray dream sleep", st, periods, probs, rc.eye_measured("LOC-ROC", ep)))
    out.append(_night("much dream sleep, no eye pair", [N2] * 70 + [R] * 30, [(0, 99)], [[0, 0, 0, 0, 900]] * 100,
                      rc.eye_not(rc.NO_PAIR)))
    out.append(_night("within the usual share, an older report", [N2] * 78 + [R] * 22, [(0, 99)], None, None))
    out.append(_night("no dream sleep", [N2] * 100, [(0, 99)], [[0, 0, 1000, 0, 0]] * 100,
                      rc.eye_measured("T3-T4", [2] * 100)))
    out.append(_night("nothing measured", [N2] * 50 + [R] * 50, [(0, 99)], None, rc.eye_measured("T3-T4", [None] * 100)))
    out.append(_night("the signal pass failed", [N2] * 50 + [R] * 50, [(0, 99)], None,
                      rc.eye_not("not measured: the signal pass failed (see extras_error)")))
    out.append(_night("no sleep", [W] * 40, [], None, rc.eye_measured("T3-T4", [0] * 40)))
    out.append(_night("a likelihood far above", [N2] * 90 + [R] * 10, [(0, 99)], [[0, 0, 0, 0, 1000]] * 100,
                      rc.eye_measured("T3-T4", [0] * 90 + [8] * 10)))
    return out


def main(argv: list[str]) -> int:
    out = Path(argv[0]) if argv else OUT
    fixture = {"made_by": "analysis/make_rem_fixture.py", "constants": {
        "swing_uv": rc.EYE_SWING_UV, "max_r": rc.EYE_MAX_R, "artefact_uv": rc.ARTEFACT_UV, "measured_s": rc.MEASURED_S,
        "dense_s": rc.DENSE_S, "low_hz": rc.EYE_LOW_HZ, "high_hz": rc.EYE_HIGH_HZ, "artefact_hp_hz": rc.ARTEFACT_HP_HZ},
        "probs": probs_part(), "pairs": pairs_part(), "signal": signal_part(), "files": files_part(),
        "nights": nights_part()}
    out.write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
    s, f = fixture["signal"], fixture["files"]
    print(f"wrote {out}: signal epochs {s['epochs']}, files ({f['pair']}) epochs {f['epochs']}, "
          f"{len(fixture['nights'])} nights, {out.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
