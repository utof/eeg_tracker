"""Dream signals (DECISIONS 304): the reference for app/lib/lucid/signals.dart, and the check on a recorded night.

Lucid dreamers in the lab answer with their eyes: left-right-left-right (LRLR), large and at an even pace, easy to
tell from ordinary dream-sleep eye movements (Konkoly 2021, 2026; Carr 2023). On this headband T3-T4 carries
sideways eye movements (DECISIONS 86), so a signal is a run of the detectors' eye movements (eeg_detectors.py):
  - at least 3 sweeps across, each the other way from the one before (LRLR from the middle is out, 3 sweeps across,
    back; the half-size steps out and back are not needed: the detectors may miss them);
  - each sweep at least the sweep size (80 µV, the hands-free look size, or the owner's calibrated look size), and of
    even size: the largest at most 1.75 times the smallest (a look out and back is half a sweep, so a glance, out,
    across, back, is no signal);
  - each sweep 0.2-1.5 s after the one before, at an even pace: the longest gap at most 2.5 times the shortest.
The back of the head is not checked (unlike the cue rule's eye bursts): on the owner's night no signal came up in 6.5
hours of sleep without that check, deep sleep included, and dream sleep's back of the head is often busy enough to
hide a third of real sweeps.
In a run of alternating movements the longest stretch that passes, from its earliest start, is the signal; the
search goes on after it. Pairs: (sweeps + 1) // 2, so LRLR is 3 sweeps and 2 pairs.
A double clench (hands-free, DECISIONS 241) counts as a signal too when the owner's calibration has one: found on the
night with the calibrated clench line (hands_free.py).
Nobody made a signal on the owner's recorded nights, so the `night` check counts false ones.

usage (from the repo root):
  uv run --project analysis python analysis/lucid_signals.py night NIGHT.bdf NIGHT.sleep.json [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import hands_free as hf  # noqa: E402
import lucid_cues as lc  # noqa: E402

FS = det.FS
SWEEP_UV = 80.0  # the steps across; the owner's calibrated look size replaces it
MIN_SWEEPS = 3  # LRLR: two left-right pairs
GAP = (round(0.2 * FS), round(1.5 * FS))  # samples between sweeps
PACE_EVEN = 2.5  # the longest gap at most this times the shortest
SIZE_EVEN = 1.75  # the largest sweep at most this times the smallest
ANSWER_S = 120  # a signal within 2 minutes after a cue moment answers it


@dataclass(frozen=True)
class Signal:
    start: int  # sample of the first sweep
    end: int  # sample of the last sweep
    sweeps: int
    size: float  # the smallest sweep, µV

    @property
    def pairs(self) -> int:
        return (self.sweeps + 1) // 2


def _ok(w: list[det.EyeMove], sweep: float) -> bool:
    if len(w) < MIN_SWEEPS:
        return False
    sizes = [abs(m.step) for m in w]
    if min(sizes) < sweep or max(sizes) > SIZE_EVEN * min(sizes):
        return False
    gaps = [b.i - a.i for a, b in zip(w, w[1:])]
    return max(gaps) <= PACE_EVEN * min(gaps)


def runs(moves: list[det.EyeMove]) -> list[list[det.EyeMove]]:
    """Runs of eye movements, each the other way from the one before and 0.2-1.5 s after it."""
    out: list[list[det.EyeMove]] = []
    for m in moves:
        if out:
            r = out[-1]
            p = r[-1]
            if p.step * m.step < 0 and GAP[0] <= m.i - p.i <= GAP[1]:
                r.append(m)
                continue
        out.append([m])
    return out


def signals(moves: list[det.EyeMove], sweep: float = SWEEP_UV) -> list[Signal]:
    """The LRLR signals among the eye movements."""
    out: list[Signal] = []
    for r in runs(moves):
        a = 0
        while a + MIN_SWEEPS <= len(r):
            found = False
            for b in range(len(r), a + MIN_SWEEPS - 1, -1):
                w = r[a:b]
                if _ok(w, sweep):
                    out.append(Signal(w[0].i, w[-1].i, len(w), float(min(abs(m.step) for m in w))))
                    a = b
                    found = True
                    break
            if not found:
                a += 1
    return out


def find(x: det.Floats, missing: det.Bools | None = None, sweep: float = SWEEP_UV) -> list[Signal]:
    """Every LRLR signal in a recording (4, n) µV."""
    return signals(det.eye_moves(x, missing), sweep)


def clenches(x: det.Floats, missing: det.Bools | None, clench_x: float) -> list[hf.Gesture]:
    """Double clenches with the clench line [clench_x] (the owner's calibration), looks off."""
    return hf.run(hf.inputs(x, missing), hf.Settings(clench_x=clench_x, glance_on=False)).gestures


def cmd_night(a: argparse.Namespace) -> None:
    import validate_detectors as val

    x, miss, start = val.load_bdf(a.bdf)
    stages, s_start = val.load_stages(a.sleep)
    if s_start != start:
        raise SystemExit("BDF and sleep.json start differ")
    moves = det.eye_moves(x, miss)
    quiet = set(lc.quiet_back(x, moves))

    def stage_at(sample: int) -> str:
        e = sample // FS // lc.EPOCH_S
        return stages[e] if e < len(stages) else "gap"

    hours = {s: sum(1 for t in stages if t == s) / 120 for s in ("W", "N1", "N2", "N3", "R")}
    asleep_h = sum(v for s, v in hours.items() if s != "W")
    rep: dict[str, Any] = {"night": a.bdf.name, "hours": {k: round(v, 2) for k, v in hours.items()},
                           "eye_moves": len(moves), "with_quiet_back": len(quiet), "lrlr": {}, "double_clench": {}}
    for sweep in (60.0, 80.0, 100.0, 120.0):
        for q in (True, False):
            sig = signals([m for m in moves if m.i in quiet] if q else moves, sweep)
            by: dict[str, int] = {}
            for s in sig:
                by[stage_at(s.end)] = by.get(stage_at(s.end), 0) + 1
            asleep = sum(v for s, v in by.items() if s not in ("W", "gap"))
            rep["lrlr"][f"{sweep:g} uV{', only movements with the back quiet' if q else ''}"] = {
                "by_stage": by, "per_hour_asleep": round(asleep / asleep_h, 2) if asleep_h else None,
                "per_hour_dream_sleep": round(by.get("R", 0) / hours["R"], 2) if hours["R"] else None}
    for cx in (10.0, 20.0, 40.0):
        g = clenches(x, miss, cx)
        by = {}
        for e in g:
            s = stage_at(e.at * FS)
            by[s] = by.get(s, 0) + 1
        asleep = sum(v for s, v in by.items() if s not in ("W", "gap"))
        rep["double_clench"][f"{cx:g}x"] = {"by_stage": by, "per_hour_asleep": round(asleep / asleep_h, 2) if asleep_h else None}
    text = json.dumps(rep, indent=1)
    if a.json:
        Path(a.json).write_text(text)
    print(text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("night")
    n.add_argument("bdf", type=Path)
    n.add_argument("sleep", type=Path)
    n.add_argument("--json", type=Path)
    a = ap.parse_args()
    {"night": cmd_night}[a.cmd](a)


if __name__ == "__main__":
    main()
