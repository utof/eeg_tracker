"""Make app/test/fixtures/detectors.json: short excerpts of recorded signal with what the Python reference
(`eeg_detectors.py`) finds in them, for the Dart port's cross-check (app/test/detectors_cross_check_test.dart).

  uv run --project analysis python analysis/make_detector_fixture.py NIGHT.bdf CHECKIN.f32 CHECKIN.markers.jsonl \
      MORNING.bdf OUT.json

The excerpts carry no clock times, names or device numbers: samples are counted from each excerpt's start.
Signals are rounded to 0.05 µV and stored as gzip-compressed int32 differences, so both sides start from the
very same numbers (value = integer / 20).
"""

from __future__ import annotations

import base64
import gzip
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import validate_detectors as val  # noqa: E402

SCALE = 20  # steps per µV


def encode(x: det.Floats) -> tuple[str, det.Floats]:
    q = np.round(x * SCALE).astype(np.int64)
    d = np.diff(q, axis=1, prepend=0)
    if np.abs(d).max() >= 2**31:
        raise ValueError("difference too large for int32")
    blob = base64.b64encode(gzip.compress(d.astype("<i4").tobytes(), 9, mtime=0)).decode()
    return blob, q / SCALE


def spans(mask: det.Bools) -> list[list[int]]:
    out: list[list[int]] = []
    i = 0
    n = mask.shape[0]
    while i < n:
        if mask[i]:
            j = i
            while j < n and mask[j]:
                j += 1
            out.append([i, j])
            i = j
        else:
            i += 1
    return out


def fl(v: Any) -> Any:
    return [fl(a) for a in v] if isinstance(v, (list, tuple, np.ndarray)) else (float(v) if not isinstance(v, (bool, np.bool_)) else bool(v))


def excerpt(name: str, x: det.Floats, miss: det.Bools) -> dict[str, Any]:
    blob, xq = encode(x)
    seen = det.detect(xq, miss)
    s = seen.seconds
    return {
        "name": name,
        "n": int(x.shape[1]),
        "signal": blob,
        "missing": spans(miss),
        "seconds": {
            "gap": [bool(v) for v in s.gap],
            "flat": [[bool(v) for v in r] for r in s.flat.T],
            "railed": [[bool(v) for v in r] for r in s.railed.T],
            "qrange": fl(s.qrange.T),
            "alpha": fl(s.alpha.T),
            "theta": fl(s.theta.T),
            "muscle": fl(s.muscle.T),
            "sem": fl(s.sem),
        },
        "blinks": [[b.i, b.depth, b.t34] for b in seen.blinks],
        "eyeMoves": [[e.i, e.step] for e in seen.eye_moves],
        "bursts": [[b.start, b.end, b.kind, b.peak_x] for b in seen.bursts],
        "movement": [list(m) for m in seen.movement],
        "epochs": [[e.quality, e.gap_s, list(e.bad_s), list(e.usable), e.movement_s, e.muscle_s] for e in seen.epochs],
    }


def drift_case(name: str, sec: det.Seconds, found: list[det.Blink], lights_off: int, length: int) -> dict[str, Any]:
    alpha, clean = sec.back_alpha()
    bl = det.blinks_per_second(found, sec.n)
    rows = []
    for k in range(lights_off, min(sec.n, lights_off + length)):
        rows.append([float(f"{alpha[k]:.6g}"), int(clean[k]), int(sec.movement[k]), float(f"{sec.sem[k]:.6g}"), int(bl[k])])
    d = det.DriftOff(0)
    for k, (a, c, m, s, b) in enumerate(rows):
        d.second(k, a, bool(c), bool(m), s, b)
    r = d.result
    return {
        "name": name,
        "seconds": rows,
        "expect": {
            "baselineAlpha": r.baseline_alpha,
            "baselineSem": r.baseline_sem,
            "baselineDone": r.baseline_done,
            "epochs": [[e.index, e.start, e.clean_s, e.faded_share, e.faded, e.rolls, e.blinks, e.state] for e in r.epochs],
            "drowsyAt": r.drowsy_at,
            "onset": r.onset,
            "asleepAt": r.asleep_at,
            "onsets": [list(o) for o in r.onsets],
            "wakes": r.wakes,
        },
    }


def pick_jaw(x: det.Floats, miss: det.Bools, sec: det.Seconds) -> int:
    """A 50 s stretch without gaps whose own detection has a jaw burst and as many other kinds as found."""
    best, best_n = -1, 0
    for b in det.bursts(sec):
        k = b.start - 35
        if b.kind != "jaw" or k < 0 or sec.gap[k : k + 50].any():
            continue
        s = det.seconds(x[:, k * det.FS : (k + 50) * det.FS])
        kinds = {r.kind for r in det.bursts(s)}
        if "jaw" in kinds and len(kinds) > best_n:
            best, best_n = k, len(kinds)
            if best_n == 3:
                break
    if best < 0:
        raise SystemExit("no stretch with a jaw burst")
    return best


def with_hole(x: det.Floats, miss: det.Bools, at: int, length: int) -> tuple[det.Floats, det.Bools]:
    """The same stretch with a hole of `length` samples filled as to_bdf.py fills one: the last value held."""
    y, m = x.copy(), miss.copy()
    y[:, at : at + length] = y[:, at - 1 : at]
    m[at : at + length] = True
    return y, m


def main(argv: list[str]) -> None:
    if len(argv) != 5:
        raise SystemExit(__doc__)
    night, f32, markers, morning, out = (Path(a) for a in argv)
    cases: list[dict[str, Any]] = []

    x, miss = val.load_run(f32)
    pos = np.flatnonzero(~miss)
    opened = next(int(json.loads(m)["i"]) for m in markers.read_text().splitlines() if "eyes_open:start" in m)
    a = int(pos[opened]) - 5 * det.FS
    cases.append(excerpt("check-in: eyes close to open, blinks", x[:, a : a + 35 * det.FS], miss[a : a + 35 * det.FS]))

    x, miss, _ = val.load_bdf(night)
    sec = det.seconds(x, miss)
    k = pick_jaw(x, miss, sec)
    cases.append(excerpt("night: a one-sided and a jaw burst", x[:, k * det.FS : (k + 50) * det.FS], miss[k * det.FS : (k + 50) * det.FS]))
    k += 50  # the 30 s after the jaw stretch, with a 0.6 s hole 20 s in
    y, m = with_hole(x[:, k * det.FS : (k + 30) * det.FS], miss[k * det.FS : (k + 30) * det.FS], 20 * det.FS + 37, 150)
    cases.append(excerpt("night: a short Bluetooth hole", y, m))
    found = det.blinks(x, miss)
    drift = [drift_case("night: lights off 4 min before sleep", sec, found, 1920, 1320)]
    del x

    x, miss, _ = val.load_bdf(morning)
    sec = det.seconds(x, miss)
    found = det.blinks(x, miss)
    drift.append(drift_case("morning sleep: lights off 3.5 min before sleep", sec, found, 3660, 1200))
    drift.append(drift_case("morning: lights off, then 20 min of eye tests (blinks keep it awake)", sec, found, 0, 1200))
    del x

    out.write_text(json.dumps({"version": 1, "fs": det.FS, "scale": SCALE, "excerpts": cases, "drift": drift}, separators=(",", ":")))
    print(out, out.stat().st_size // 1024, "KB;", [(c["name"], len(c["blinks"]), len(c["bursts"])) for c in cases])


if __name__ == "__main__":
    main(sys.argv[1:])
