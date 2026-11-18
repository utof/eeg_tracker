"""Make app/test/fixtures/morning.json: short excerpts of a recorded morning check-in and what the laptop's own
analysis (scripts/morning_check.py) makes of them, for the phone's Dart port (app/test/morning_cross_check_test.dart).

  uv run --project analysis python app/test/fixtures/make_morning_fixture.py CHECKIN.f32 OUT.json

CHECKIN.f32 is a recorder file holding a morning check-in (its .markers.jsonl beside it). The excerpts carry no
clock times, names or device numbers: only O1 and O2, 60 s of each phase after the skipped edges, counted from the
excerpt's start. Signals are rounded to 0.05 µV and stored as gzip-compressed int32 differences, so both sides
start from the very same numbers (value = integer / 20), as in the detectors' fixture.

Cases: the real excerpt; the same with artefacts put in (a swing over 150 µV, a noisy stretch, a flat stretch), so
every rejection rule acts; and a short one (too little eyes-closed data, an eyes-open phase under 6 s) for the
empty values and the unfiltered path. Also the comparison rows (`compared`) for a made-up history.
"""

from __future__ import annotations

import base64
import gzip
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
import morning_check as mc  # noqa: E402
from to_bdf import load  # noqa: E402

SCALE = 20  # steps per µV
EXCERPT_S = 60
FS = mc.FS


def encode(x: np.ndarray) -> tuple[str, np.ndarray]:
    """One channel (n,) as gzip-compressed int32 differences in base64, and the rounded values it stands for."""
    q = np.round(x * SCALE).astype(np.int64)
    d = np.diff(q, prepend=0)
    if np.abs(d).max() >= 2**31:
        raise ValueError("difference too large for int32")
    blob = base64.b64encode(gzip.compress(d.astype("<i4").tobytes(), 9, mtime=0)).decode()
    return blob, q / SCALE


def phases(path: Path) -> dict[str, np.ndarray]:
    """The phases of the newest usable check-in in the file, cut as morning_check.analyse cuts them (n x 4 µV)."""
    found = mc.find_latest([path], "morning")
    if not found:
        raise SystemExit("no usable morning check-in in this file")
    _, sess = found
    uv, _ = load(path)
    w = mc.morning_windows(sess)
    out = {}
    for ph, (i0, i1, _t0, _t1) in w["win"].items():
        a, b = i0 + int(mc.SKIP_START_S * FS), min(i1 - int(mc.SKIP_END_S * FS), len(uv))
        out[ph] = uv[a:b]
    return out


def keep_mask(x: np.ndarray) -> list[bool]:
    _, keep = mc.clean_segments(x)
    return [bool(v) for v in keep]


def case(name: str, ec: dict[str, np.ndarray], eo: dict[str, np.ndarray], detail: bool = False) -> dict[str, Any]:
    signals: dict[str, Any] = {}
    channels: dict[str, Any] = {}
    keep: dict[str, Any] = {}
    for n in mc.BACK:
        b_ec, q_ec = encode(ec[n])
        b_eo, q_eo = encode(eo[n])
        signals[n] = {"ec": b_ec, "eo": b_eo, "n_ec": len(q_ec), "n_eo": len(q_eo)}
        channels[n] = mc.channel_measures(q_ec, q_eo)
        keep[n] = {"ec": keep_mask(q_ec), "eo": keep_mask(q_eo)}
    out: dict[str, Any] = {"name": name, "signals": signals, "channels": channels, "back": mc.back_summary(channels),
                           "keep": keep}
    if detail:  # intermediate steps of O1 eyes closed, to find where a difference starts
        _, q = encode(ec["O1"])
        f = mc.bandpass(q, 1.0, 40.0)
        segs, k = mc.clean_segments(q)
        fr, p = mc.spectrum(segs[k])
        slope, icpt = mc.aperiodic(fr, p)
        out["detail"] = {"filtered_every_50": [float(v) for v in f[::50]],
                         "psd_0_to_50hz": [float(v) for v in p[: int(50 / 0.25) + 1]],
                         "slope": slope, "intercept": icpt}
    return out


def with_artefacts(x: np.ndarray, flat_at: int) -> np.ndarray:
    """A 400 µV swing in the 4th segment, a stretch of loud noise in the 10th, a flat 15th (eyes open only)."""
    y = x.copy()
    n = int(mc.SEG_S * FS)
    t = np.arange(n) / FS
    y[3 * n : 4 * n] += 400 * np.exp(-((t - 1.0) ** 2) / 0.02)
    y[9 * n : 10 * n] += np.random.default_rng(7).normal(0, 45, n)
    if flat_at >= 0:
        y[flat_at * n : (flat_at + 1) * n] = y[flat_at * n]
    return y


def comparison() -> dict[str, Any]:
    """compared() for a made-up result and history: values above, below and inside the range, a rating left out."""
    def res(alpha: float | None, rise: float, iaf: float | None, slope: float, clean: float, kss: int | None,
            mood: int, tension: int) -> dict[str, Any]:
        return {"back": {"alpha_ec_uv2": alpha, "ec_rise": rise, "iaf_hz": iaf, "aperiodic_slope_ec": slope,
                         "clean_share": clean},
                "ratings": {"kss": kss, "mood": mood, "tension": tension}}
    past = [res(30.5, 2.4, 9.61, -1.5, 0.95, 5, 3, 2), res(28.25, 2.6, 9.7, -1.45, 0.9, 6, 4, 2),
            res(33.0, 2.2, None, -1.6, 0.97, 4, 3, 3), res(None, 2.5, 9.55, -1.52, 0.6, 7, 2, 1)]
    today = res(41.37, 2.4, 9.42, -1.538, 0.974, None, 4, 2)
    return {"today": today, "past": past, "compared": mc.compared(today, past),
            "first": mc.compared(today, []), "one": mc.compared(today, past[:1])}


def main(argv: list[str]) -> None:
    if len(argv) != 3:
        raise SystemExit(__doc__)
    ph = phases(Path(argv[1]))
    m = EXCERPT_S * FS
    ec = {n: ph["eyes_closed"][:m, mc.NAMES.index(n)] for n in mc.BACK}
    eo = {n: ph["eyes_open"][:m, mc.NAMES.index(n)] for n in mc.BACK}
    if min(len(v) for v in [*ec.values(), *eo.values()]) < m:
        raise SystemExit("the check-in is too short for 60 s excerpts")
    cases = [
        case("real", ec, eo, detail=True),
        case("artefacts", {n: with_artefacts(v, -1) for n, v in ec.items()},
             {n: with_artefacts(v, 14) for n, v in eo.items()}),
        case("short", {n: v[: 15 * FS] for n, v in ec.items()}, {n: v[: 5 * FS] for n, v in eo.items()}),
    ]
    out = {"made_by": "app/test/fixtures/make_morning_fixture.py (scripts/morning_check.py " + mc.VERSION + ")",
           "scale": SCALE, "fs": FS, "cases": cases, "comparison": comparison()}
    Path(argv[2]).write_text(json.dumps(out, ensure_ascii=False, allow_nan=False) + "\n")
    for c in cases:
        print(c["name"], json.dumps(c["back"]))


if __name__ == "__main__":
    main(sys.argv)
