"""False triggers of the hands-free gestures (`hands_free.py`) on the owner's recordings (laptop only; nothing is
written next to the data). Nobody made a gesture in these recordings, so every gesture found is a false one.

  uv run --project analysis python analysis/validate_hands_free.py night NIGHT.bdf NIGHT.sleep.json
  uv run --project analysis python analysis/validate_hands_free.py run RUN.f32 [RUN.markers.jsonl ...]

night: gestures per hour awake and asleep (AnySleep's stages; gap epochs left out), with and without the drift-off
       detector's gate (from the night's first sample, as the night recorder runs it), at the planning settings
       and a sweep of clench levels and glance sizes.
run:   gestures per hour in recorder runs (awake: the morning check-in, eye tests, sound sessions); the
       check-in's markers split it into its phases.
Prints JSON.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import hands_free as hf  # noqa: E402
import validate_detectors as val  # noqa: E402

CLENCH_SWEEP = (4.0, 8.0, 10.0, 15.0, 20.0, 30.0, 40.0, 60.0)
GLANCE_SWEEP = (40.0, 60.0, 70.0, 80.0, 100.0, 150.0)


def drift_states(sec: det.Seconds, found: list[det.Blink]) -> list[str]:
    """The drift-off detector's state after every second, lights off at the first sample."""
    alpha, clean = sec.back_alpha()
    bl = det.blinks_per_second(found, sec.n)
    d = det.DriftOff(0)
    return [d.second(k, float(alpha[k]), bool(clean[k]), bool(sec.movement[k]), float(sec.sem[k]), int(bl[k]))
            for k in range(sec.n)]


def per_hour(n: int, seconds: float) -> float | None:
    return round(n / (seconds / 3600), 2) if seconds > 0 else None


def clusters_seen(g: hf.Gestures) -> dict[str, Any]:
    """What the recogniser looked at: muscle and eye clusters, how many were clean, and the near misses."""
    cl = [c for c in g.clusters if c.kind == "clench"]
    gl = [c for c in g.clusters if c.kind == "glance"]
    two = [c for c in cl if c.clean and len(c.bursts) == 2]
    pairs = [c for c in gl if c.clean and 2 <= len(c.moves) <= 3]
    return {
        "muscle_clusters": len(cl),
        "muscle_clean": sum(1 for c in cl if c.clean),
        "clean_two_bursts": len(two),
        "clean_two_bursts_levels": sorted(round(min(b.peak for b in c.bursts), 1) for c in two)[-12:],
        "eye_clusters": len(gl),
        "eye_clean": sum(1 for c in gl if c.clean),
        "clean_two_or_three_moves": len(pairs),
    }


def sweep(seconds: list[hf.Second], keep: list[bool], hours: float) -> dict[str, Any]:
    """Gestures per hour over the kept seconds, for a range of clench levels and glance sizes (left unknown, and
    left as either sign)."""
    out: dict[str, Any] = {"clench_x": {}, "glance_uv": {}}
    for cx in CLENCH_SWEEP:
        g = hf.run(seconds, hf.Settings(clench_x=cx, glance_on=False))
        out["clench_x"][str(cx)] = per_hour(sum(1 for e in g.gestures if keep[e.at]), hours * 3600)
    for gu in GLANCE_SWEEP:
        row = {}
        for left in (0, 1, -1):
            g = hf.run(seconds, hf.Settings(glance_uv=gu, left_sign=left, clench_on=False))
            row[{0: "either way", 1: "left = +", -1: "left = -"}[left]] = per_hour(sum(1 for e in g.gestures if keep[e.at]), hours * 3600)
        out["glance_uv"][str(gu)] = row
    return out


def night(bdf: Path, sleep: Path) -> dict[str, Any]:
    x, miss, start = val.load_bdf(bdf)
    stages, s_start = val.load_stages(sleep)
    if s_start != start:
        raise ValueError("BDF and sleep.json start differ")
    sec = det.seconds(x, miss)
    f = det._blink_filtered(x)
    found = det._blinks_from(f, miss)
    moves = det._eye_moves_from(f, miss)
    del f
    seconds = hf.inputs(x, miss, sec, moves)
    del x
    states = drift_states(sec, found)
    n = len(seconds)

    def stage(k: int) -> str:
        e = k // det.EPOCH_S
        return stages[e] if e < len(stages) else "gap"

    awake = [stage(k) == "W" for k in range(n)]
    asleep = [stage(k) not in ("W", "gap") for k in range(n)]
    gate = [s != "asleep" for s in states]
    g = hf.run(seconds, hf.Settings())
    h_awake, h_asleep = sum(awake) / 3600, sum(asleep) / 3600
    h_asleep_open = sum(1 for k in range(n) if asleep[k] and gate[k]) / 3600

    def count(keep: list[bool]) -> dict[str, int]:
        found_k = [e for e in g.gestures if keep[e.at]]
        return {"clench": sum(1 for e in found_k if e.kind == "clench"), "glance": sum(1 for e in found_k if e.kind == "glance")}

    awake_n = count(awake)
    asleep_n = count(asleep)
    asleep_gated = count([asleep[k] and gate[k] for k in range(n)])
    return {
        "recording": bdf.name,
        "hours": {"awake": round(h_awake, 2), "asleep": round(h_asleep, 2), "asleep, gate open": round(h_asleep_open, 2),
                  "gap": round(sum(1 for k in range(n) if stage(k) == "gap") / 3600, 2)},
        "planning settings": {"clench_x": hf.CLENCH_X, "glance_uv": hf.GLANCE_UV, "left": "either way"},
        "awake": {**awake_n, "per_hour": {k: per_hour(v, h_awake * 3600) for k, v in awake_n.items()}},
        "asleep, no gate": {**asleep_n, "per_hour": {k: per_hour(v, h_asleep * 3600) for k, v in asleep_n.items()}},
        "asleep, drift-off gate": {**asleep_gated,
                                   "per_hour of all sleep": {k: per_hour(v, h_asleep * 3600) for k, v in asleep_gated.items()}},
        "gestures": [(e.kind, e.at, stage(e.at), states[e.at], round(e.level, 1)) for e in g.gestures],
        "clusters": clusters_seen(g),
        "sweep awake": sweep(seconds, awake, h_awake),
        "sweep asleep, gated": sweep(seconds, [asleep[k] and gate[k] for k in range(n)], h_asleep),
    }


def runs(paths: list[Path]) -> dict[str, Any]:
    out: list[dict[str, Any]] = []
    for p in paths:
        if p.suffix != ".f32":
            continue
        x, miss = val.load_run(p)
        seconds = hf.inputs(x, miss)
        n = len(seconds)
        g = hf.run(seconds, hf.Settings())
        row: dict[str, Any] = {
            "run": p.name,
            "minutes": round(n / 60, 1),
            "clench": sum(1 for e in g.gestures if e.kind == "clench"),
            "glance": sum(1 for e in g.gestures if e.kind == "glance"),
            "gestures": [(e.kind, e.at, round(e.level, 1)) for e in g.gestures],
            "clusters": clusters_seen(g),
            "sweep": sweep(seconds, [True] * n, n / 3600),
        }
        markers = p.with_suffix(".markers.jsonl")
        if markers.exists():
            row["markers"] = [json.loads(line)["text"] for line in markers.read_text().splitlines()][:20]
        out.append(row)
    total_s = sum(r["minutes"] * 60 for r in out)
    total = {k: sum(r[k] for r in out) for k in ("clench", "glance")}
    return {"runs": out, "total_minutes": round(total_s / 60, 1), "total": total,
            "per_hour": {k: per_hour(v, total_s) for k, v in total.items()}}


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    if argv[0] == "night" and len(argv) == 3:
        res = night(Path(argv[1]), Path(argv[2]))
    elif argv[0] == "run":
        res = runs([Path(a) for a in argv[1:]])
    else:
        raise SystemExit(__doc__)
    print(json.dumps(res, indent=1, default=str))


if __name__ == "__main__":
    main(sys.argv[1:])
