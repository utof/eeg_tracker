"""Make app/test/fixtures/wearer.json: what the Python reference (`wearer_check.py`) makes of made-up signals and
histories, for the Dart port's cross-check (app/test/wearer_cross_check_test.dart).

  uv run --project analysis python analysis/make_wearer_fixture.py app/test/fixtures/wearer.json

Made-up numbers only; no one's EEG (the owner's signal is itself a fingerprint). Cases:
- night signals: 6 minutes of a made-up night (O1, O2: a 10 Hz rhythm while awake, 6 Hz in light sleep, a swing
  over 150 µV, a loud and a flat stretch) under several sleep-model readings, Lights off moments and filled-in
  samples; 2 minutes of noise without an alpha peak; a night without Lights off. Signals are rounded to 0.05 µV and
  stored as gzip-compressed int32 differences (value = integer / 20), as in the morning check-in's fixture;
- check-in results and report objects with good, short, missing and odd fields;
- histories: made-up owners from `validate_wearer.py` (with someone else every 10th day and truthful answers), and
  hand-written ones for the learning count, the kinds kept apart, time ties, unchecked recordings and the cap of
  20. Values are written with Python's shortest round-trip form, so both sides start from the very same doubles.
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
import validate_wearer as vw  # noqa: E402
import wearer_check as wc  # noqa: E402

SCALE = 20  # steps per µV
FS = wc.FS


def encode(x: np.ndarray) -> tuple[str, np.ndarray]:
    """One channel as gzip-compressed int32 differences in base64, and the rounded values it stands for."""
    q = np.round(x * SCALE).astype(np.int64)
    d = np.diff(q, prepend=0)
    blob = base64.b64encode(gzip.compress(d.astype("<i4").tobytes(), 9, mtime=0)).decode()
    return blob, q / SCALE


def rhythm(seconds: float, hz: float, amp: float, rng: np.random.Generator) -> np.ndarray:
    t = np.arange(int(seconds * FS)) / FS
    walk = np.cumsum(rng.normal(0, 0.8, t.size))
    walk -= np.convolve(walk, np.ones(FS) / FS, mode="same")
    return amp * np.sin(2 * np.pi * hz * t + rng.uniform(0, 6)) + 1.5 * walk + rng.normal(0, 1.5, t.size)


def made_up_night(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """6 minutes (12 epochs): epoch 0 settling (8 Hz), 1-6 awake (10 Hz, O2 a little weaker), 7-11 light sleep
    (6 Hz); a 400 µV swing in epoch 2, loud noise in epoch 3, a flat second in epoch 5."""
    o1, o2 = [], []
    for e in range(12):
        hz = 8.0 if e == 0 else (10.0 if e <= 6 else 6.0)
        o1.append(rhythm(30, hz, 14.0, rng))
        o2.append(rhythm(30, hz, 11.0, rng))
    a, b = np.concatenate(o1), np.concatenate(o2)
    t = np.arange(2 * FS) / FS
    s2 = 2 * 30 * FS + 10 * FS
    a[s2 : s2 + 2 * FS] += 400 * np.exp(-((t - 1.0) ** 2) / 0.02)
    s3 = 3 * 30 * FS + 4 * FS
    b[s3 : s3 + 4 * FS] += rng.normal(0, 45, 4 * FS)
    s5 = 5 * 30 * FS + 20 * FS
    a[s5 : s5 + FS] = a[s5]
    return a, b


def night_case(name: str, o1: np.ndarray, o2: np.ndarray, stages: list[str], lights: int | None,
               missing: list[int]) -> dict[str, Any]:
    miss = None
    if missing:
        miss = np.zeros(len(o1), bool)
        miss[missing] = True
    s, info = wc.night_signal(o1, o2, stages, lights, miss)
    return {"name": name, "stages": stages, "lights_off_s": lights, "missing": missing, "signal": s, "info": info}


def night_cases() -> dict[str, Any]:
    rng = np.random.default_rng(11)
    raw1, raw2 = made_up_night(rng)
    b1, q1 = encode(raw1)
    b2, q2 = encode(raw2)
    w = ["W"] * 7 + ["N1"] * 2 + ["N2"] * 3
    noise_rng = np.random.default_rng(12)
    n1 = noise_rng.normal(0, 6, 120 * FS)
    n2 = noise_rng.normal(0, 6, 120 * FS)
    nb1, nq1 = encode(n1)
    nb2, nq2 = encode(n2)
    cases = [
        night_case("awake epochs after lights off", q1, q2, w, 30, []),
        night_case("lights off at the first sample", q1, q2, w, 0, []),
        night_case("lights off late: past the data", q1, q2, w, 300, []),
        night_case("a filled-in sample leaves its epoch out", q1, q2, w, 30, [2 * 30 * FS + 5, 4 * 30 * FS]),
        night_case("asleep at once", q1, q2, ["W"] + ["N1"] + ["N2"] * 10, 30, []),
        night_case("a gap epoch is not awake", q1, q2, ["W", "W", "gap", "W", "W", "R", "W", "N1", "N2", "N2",
                                                         "N2", "N2"], 0, []),
        night_case("no lights off", q1, q2, w, None, []),
    ]
    noise = [night_case("no alpha peak", nq1, nq2, ["W"] * 4, 0, [])]
    return {"scale": SCALE, "night": {"o1": b1, "o2": b2, "cases": cases},
            "noise": {"o1": nb1, "o2": nb2, "cases": noise}}


def checkin_cases() -> list[dict[str, Any]]:
    def m(o1: Any = 110.0, o2: Any = 112.0, **back: Any) -> dict[str, Any]:
        b = {"iaf_hz": 9.615, "alpha_ec_uv2": 31.31, "aperiodic_slope_ec": -1.542}
        b.update(back)
        return {"channels": {"O1": {"clean_s_ec": o1}, "O2": {"clean_s_ec": o2}}, "back": b}

    inputs = [m(), m(o1=60.0), m(o2=59.9), m(iaf_hz=None), m(alpha_ec_uv2=0.0), m(aperiodic_slope_ec=None),
              m(o1=True), m(o1="110"), {"back": {}}, {}, {"channels": [], "back": []}, m(iaf_hz=10)]
    out = []
    for i in inputs:
        s, why = wc.checkin_signal(i)
        out.append({"input": i, "signal": s, "why": why})
    return out


def report_cases() -> list[dict[str, Any]]:
    good = {"version": 1, "from_s": 30, "epochs": 6, "clean_s": 150.0, "iaf_hz": 9.9, "alpha_uv2": 40.5,
            "slope": -1.61, "why": None}
    inputs: list[Any] = [good, {**good, "why": wc.WHY_CLEAN}, {**good, "iaf_hz": None}, {**good, "version": 2},
                         None, [], {**good, "alpha_uv2": -1.0}, {**good, "why": None, "slope": "x"}]
    out = []
    for i in inputs:
        s, why = wc.report_signal(i)
        out.append({"input": i, "signal": s, "why": why})
    return out


def rec_json(r: wc.Recording) -> dict[str, Any]:
    return {"id": r.id, "kind": r.kind, "time": r.time, "day": r.day, "signal": r.signal, "why": r.why,
            "answer": r.answer}


def history_case(name: str, recs: list[wc.Recording]) -> dict[str, Any]:
    return {"name": name, "recordings": [rec_json(r) for r in recs],
            "verdicts": [wc.verdict_json(v) for v in wc.judge(recs)]}


def hand(i: int, kind: str = "check-in", day: int | None = None, iaf: float = 10.0, answer: str | None = None,
         signal: bool = True, minute: int | None = None) -> wc.Recording:
    d = i if day is None else day
    mm = i % 60 if minute is None else minute
    return wc.Recording(
        id=f"{kind}-{i:03d}", kind=kind, time=f"2026-12-{1 + d:02d}T08:{mm:02d}:00+03:00", day=f"2026-12-{1 + d:02d}",
        signal={"iaf": iaf + 0.1 * (i % 3 - 1), "alpha": 1.5 + 0.02 * (i % 4), "slope": -1.5 - 0.03 * (i % 5)}
        if signal else None, why=None if signal else wc.WHY_CLEAN, answer=answer)


def history_cases() -> list[dict[str, Any]]:
    out = []
    for seed, headband in ((5, "lab"), (6, "dry")):
        rng = np.random.default_rng(seed)
        recs, others = vw.history(rng, 120, headband)
        vw.run_owner(recs, others)  # sets the truthful answers
        out.append(history_case(f"made-up owner ({headband}), someone else every 10th day", recs))
    n = wc.N_ENROL
    out.append(history_case("three a day: learning until the fifth day",
                            [hand(i, day=i // 3) for i in range(16)]))
    out.append(history_case("someone else while learning, a far one, answered and not",
                            [hand(i, answer="someone else" if i == 2 else None) for i in range(n + 1)]
                            + [hand(n + 1, iaf=8.0), hand(n + 2, iaf=8.2, answer="me"), hand(n + 3),
                               hand(n + 4, iaf=12.5, answer="someone else"), hand(n + 5)]))
    out.append(history_case("kinds apart, unchecked ones, ties in time ordered by id",
                            [hand(i) for i in range(n)] + [hand(i, kind="night") for i in range(4)]
                            + [hand(50, day=3, signal=False), hand(51, day=n + 1, minute=0),
                               hand(52, day=n + 1, minute=0, iaf=7.5), hand(53, kind="night", signal=False)]))
    out.append(history_case("a lasting change answered 'it was me' until the profile follows",
                            [hand(i, iaf=12.0 if i < 10 else 10.0, answer=None if i < 10 else "me")
                             for i in range(32)]))
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        raise SystemExit(__doc__.split("\n\n")[1])
    fixture = {
        "made_by": "analysis/make_wearer_fixture.py",
        "rules": {"n_enrol": wc.N_ENROL, "min_days": wc.MIN_DAYS, "profile_max": wc.PROFILE_MAX,
                  "threshold": wc.THRESHOLD, "floors": wc.FLOORS, "min_clean_s": wc.MIN_CLEAN_S,
                  "night_window_s": wc.NIGHT_WINDOW_S},
        "signals": night_cases(),
        "checkins": checkin_cases(),
        "reports": report_cases(),
        "histories": history_cases(),
    }
    Path(argv[0]).write_text(json.dumps(fixture, indent=None, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
