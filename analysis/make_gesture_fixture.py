"""Make app/test/fixtures/gestures.json: recorded excerpts with synthetic gestures laid over them, and what the Python
reference (`hands_free.py`) finds in them, for the Dart port's cross-check (app/test/gestures_cross_check_test.dart).

  uv run --project analysis python analysis/make_gesture_fixture.py NIGHT.bdf CHECKIN.f32 CHECKIN.markers.jsonl OUT.json

Nobody made a gesture in the owner's recordings, so the gestures are drawn on top: broadband muscle noise on T3 and
T4 for a clench, opposite steps of T3 and T4 for a glance (the helpers below; the tests use them too). The
excerpts carry no clock times, names or device numbers; signals are stored as in detectors.json (0.05 µV steps,
gzip-compressed int32 differences), so both sides start from the very same numbers.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import hands_free as hf  # noqa: E402
import make_detector_fixture as mdf  # noqa: E402
import validate_detectors as val  # noqa: E402

FS = det.FS


# ---- synthetic gestures (also used by analysis/tests/test_hands_free.py) ----


def clench(x: np.ndarray, at_s: float, length_s: float, uv: float = 15.0, sides: tuple[int, ...] = (2, 3), seed: int = 7) -> None:
    """Broadband muscle noise on the temple channels (a clench), with 20 ms ramps."""
    rng = np.random.default_rng(seed + int(at_s * 10))
    a, n = int(at_s * FS), int(length_s * FS)
    ramp = np.minimum(1.0, np.minimum(np.arange(n) + 1, n - np.arange(n)) / 5)
    for c in sides:
        x[c, a : a + n] += rng.normal(0, uv, n) * ramp


def double_clench(x: np.ndarray, at_s: float, uv: float = 15.0, first: float = 0.4, pause: float = 0.6, second: float = 0.4) -> None:
    clench(x, at_s, first, uv)
    clench(x, at_s + first + pause, second, uv)


def step(x: np.ndarray, at_s: float, uv: float) -> None:
    """A sideways eye movement: T3-T4 changes by uv within about 50 ms and stays (T3 up, T4 down for +uv)."""
    t = np.arange(x.shape[1]) / FS - at_s
    s = uv * 0.5 * (1 + np.tanh(t / 0.02))
    x[2] += s / 2
    x[3] -= s / 2


def glance(x: np.ndarray, at_s: float, uv: float = 120.0, back: bool = True) -> None:
    """Look one way (+uv), then the other (-2 uv) 0.7 s later, then back to the middle."""
    step(x, at_s, uv)
    step(x, at_s + 0.7, -2 * uv)
    if back:
        step(x, at_s + 1.4, uv)


# ---- the fixture ----


def g9(v: float) -> float | None:
    """Nine significant digits (the Dart side compares within 1e-8); NaN as null."""
    return None if v != v else float(f"{v:.9g}")


def settings_json(s: hf.Settings) -> dict[str, Any]:
    return {"clenchX": s.clench_x, "glanceUv": s.glance_uv, "leftSign": s.left_sign, "clenchOn": s.clench_on, "glanceOn": s.glance_on}


def case(name: str, x: det.Floats, miss: det.Bools, settings: hf.Settings, tries: list[hf.Try] | None = None) -> dict[str, Any]:
    blob, xq = mdf.encode(x)
    seconds = hf.inputs(xq, miss)
    g = hf.run(seconds, settings)
    out: dict[str, Any] = {
        "name": name,
        "n": int(x.shape[1]),
        "signal": blob,
        "missing": mdf.spans(miss),
        "settings": settings_json(settings),
        "seconds": [[s.k, [g9(v) for v in s.p3], [g9(v) for v in s.p4], [int(v) for v in s.tick_gap], g9(s.rest3),
                     g9(s.rest4), int(s.movement), [[m.i, g9(m.step)] for m in s.moves]] for s in seconds],
        "gestures": [[e.kind, e.start, e.end, e.at, e.level] for e in g.gestures],
        "clusters": [[c.kind, c.at, c.clean, [[b.start, b.end, b.peak] for b in c.bursts], [m.i for m in c.moves],
                      hf.clench_why(c, settings) if c.kind == "clench" else hf.glance_why(c, settings)] for c in g.clusters],
    }
    if tries is not None:
        cal = hf.calibrate(seconds, tries)
        out["calibration"] = {
            "tries": [[t.kind, t.cue, t.until] for t in tries],
            "settings": settings_json(cal.settings),
            "results": [[r.kind, r.cue, r.level, r.sign, r.why] for r in cal.tries],
            "clenchSeen": cal.clench_seen,
            "glanceSeen": cal.glance_seen,
            "leftKnown": cal.left_known,
            "others": cal.others,
        }
    return out


def main(argv: list[str]) -> None:
    if len(argv) != 4:
        raise SystemExit(__doc__)
    night, f32, markers, out = (Path(a) for a in argv)
    cases: list[dict[str, Any]] = []

    x, miss = val.load_run(f32)
    pos = np.flatnonzero(~miss)
    lines = [json.loads(m) for m in markers.read_text().splitlines()]
    closed = int(pos[next(int(m["i"]) for m in lines if m["text"] == "morning:eyes_closed:start")]) + 5 * FS
    opened = int(pos[next(int(m["i"]) for m in lines if m["text"] == "morning:eyes_open:start")]) + 5 * FS

    # eyes open: a double clench, a glance, then a near miss (a single clench, and two steps the same way)
    a, n = opened, 56 * FS
    y, m = x[:, a : a + n].copy(), miss[a : a + n].copy()
    double_clench(y, 34.0, uv=25.0)
    glance(y, 40.0, uv=140.0)
    clench(y, 46.0, 0.5, uv=25.0)
    step(y, 50.0, 130.0)
    step(y, 50.6, 130.0)
    cases.append(case("check-in eyes open: a double clench, a glance and two near misses", y, m, hf.Settings(left_sign=1)))

    # eyes closed: a calibration (3 double clenches, 3 glances on cues), one clench try only a single clench
    a, n = closed, 82 * FS
    y, m = x[:, a : a + n].copy(), miss[a : a + n].copy()
    for at, uv in ((33, 30.0), (41, 22.0), (49, 26.0)):
        double_clench(y, at + 0.8, uv=uv)
    for at, uv in ((57, 120.0), (65, 150.0), (73, 110.0)):
        glance(y, at + 0.6, uv=uv)
    tries = [hf.Try("clench", c, c + 5) for c in (33, 41, 49)] + [hf.Try("glance", c, c + 5) for c in (57, 65, 73)]
    cases.append(case("check-in eyes closed: a calibration run", y, m, hf.Settings(), tries))
    del x

    x, miss, _ = val.load_bdf(night)
    sec = det.seconds(x, miss)
    k = mdf.pick_jaw(x, miss, sec)
    a, n = k * FS, 50 * FS
    y, m = x[:, a : a + n].copy(), miss[a : a + n].copy()
    double_clench(y, 41.0, uv=30.0)
    glance(y, 31.0, uv=150.0)
    cases.append(case("night: real jaw bursts and a double clench drawn after them", y, m, hf.Settings()))
    a = (k + 50) * FS
    y, m = mdf.with_hole(x[:, a : a + 46 * FS], miss[a : a + 46 * FS], 38 * FS + 137, 30)
    double_clench(y, 36.0, uv=30.0)
    double_clench(y, 41.5, uv=30.0)
    cases.append(case("night: a double clench spoiled by a short Bluetooth hole after it, then one that is not", y, m, hf.Settings()))
    del x

    out.write_text(json.dumps({"version": 1, "fs": FS, "scale": mdf.SCALE, "cases": cases}, separators=(",", ":")))
    print(out, out.stat().st_size // 1024, "KB;", [(c["name"], [g[0] for g in c["gestures"]]) for c in cases])


if __name__ == "__main__":
    main(sys.argv[1:])
