"""Night extras: what the shared detectors saw over a scored night, for the sleep report (ROADMAP row 9,
DECISIONS 140-145). The Python reference for the phone's `app/lib/sleep/extras.dart`: the same rules give the same
numbers (`app/test/night_extras_cross_check_test.dart`, fixture made by `analysis/make_extras_fixture.py`).

  uv run --project analysis python analysis/night_extras.py RECORDINGS NIGHT NIGHT.sleep.json [--out OUT.json]

runs the detectors over a night's recordings joined as `scripts/to_bdf.py` joins them (the same samples the phone
reads, before the BDF's 24-bit rounding) with the stages of a laptop `sleep.json`, and prints the extras with
every event, the time taken and the peak memory, for comparing with `app/tool/night_extras.dart`.

What it counts (the report's `extras`, docs/data-format.md):
- per 30 s epoch from the first sample: the detectors' signal quality, good / degraded / missing (`g d m`);
- muscle bursts at T3/T4 by kind (jaw = both sides, one-sided, movement inside) and movement spans (3+ channels
  jumping at once), each counted in the epoch where it starts; events after the last whole epoch are dropped;
- the same per clock hour (the first and last hours partial) and over the asleep epochs inside the sleep periods,
  with jaw bursts and movements per hour asleep (a trend to compare nights, not a bruxism count: DECISIONS 65).
"""

from __future__ import annotations

import argparse
import json
import resource
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402

VERSION = 1
EPOCH_S = det.EPOCH_S
HOUR_S = 3600
ASLEEP = frozenset({"N1", "N2", "N3", "R"})
QUALITY_CHAR = {"good": "g", "degraded": "d", "missing": "m"}
KINDS = {"jaw": "jaw_bursts", "one-sided": "one_sided_bursts", "movement": "movement_bursts"}
LIMIT_UV = 400_000.0  # the BDF's range (scripts/to_bdf.py LIM): the phone clips its samples the same way
RULES = "shared detectors, DECISIONS 85-87 (planning values)"

Burst = tuple[int, int, str]  # first second, last second, kind
Span = tuple[int, int]  # first second, last second


def first_edge_s(start: datetime) -> int:
    """Seconds from a night's first sample (a whole second, local clock) to the next whole clock hour; 0 on the hour."""
    return (HOUR_S - (start.minute * 60 + start.second)) % HOUR_S


def missing_mask(n: int, notes: list[tuple[float, float, str]]) -> det.Bools:
    """Held samples from `to_bdf.join`'s notes: every `BAD_gap` and `BAD_padding`, onsets rounded to samples."""
    miss = np.zeros(n, bool)
    for onset, dur, text in notes:
        if text.startswith("BAD") and dur > 0:
            lo = round(onset * det.FS)
            miss[lo : lo + round(dur * det.FS)] = True
    return miss


def see(uv: np.ndarray, notes: list[tuple[float, float, str]], *, in_place: bool = False) -> det.Seen:
    """Every detector over a joined night: `uv` (n x 4, µV) and `notes` as `to_bdf.join` returns them, clipped to
    the BDF's ±400 000 µV as the phone reads them. in_place: clip `uv` itself (float64) instead of a copy, so a
    24-hour night is not held twice (scripts/sleep_report.py, whose BDF clips to the same range anyway)."""
    u = np.asarray(uv, dtype=np.float64)
    x = np.clip(u, -LIMIT_UV, LIMIT_UV, out=u if in_place else None).T
    return det.detect(x, missing_mask(x.shape[1], notes))


def events(seen: det.Seen) -> tuple[list[str], list[Burst], list[Span]]:
    """The parts of the detectors' output the extras use: epoch quality, bursts, movement spans."""
    return ([e.quality for e in seen.epochs], [(b.start, b.end, b.kind) for b in seen.bursts],
            [(a, b) for a, b in seen.movement])


def asleep_mask(stages: list[str], periods: list[tuple[int, int]]) -> list[bool]:
    """Asleep epochs inside the sleep periods (first, last inclusive): stray sleep outside them does not count."""
    inside = [False] * len(stages)
    for a, b in periods:
        for e in range(a, b + 1):
            inside[e] = True
    return [inside[e] and stages[e] in ASLEEP for e in range(len(stages))]


def per_hour(count: int, epochs: int) -> float | None:
    """count per hour over `epochs` 30-s epochs, to 0.1 with halves up, in integers (so Dart gets the same)."""
    if epochs == 0:
        return None
    return (2 * count * 1200 + epochs) // (2 * epochs) / 10


def _tally() -> dict[str, Any]:
    return {"min": 0.0, "good_min": 0.0, "degraded_min": 0.0, "missing_min": 0.0,
            "jaw_bursts": 0, "one_sided_bursts": 0, "movement_bursts": 0, "moves": 0}


def _hour_of(epoch: int, first_edge: int) -> int:
    s = epoch * EPOCH_S
    if first_edge == 0:
        return s // HOUR_S
    return 0 if s < first_edge else 1 + (s - first_edge) // HOUR_S


def _hour_from(h: int, first_edge: int) -> int:
    if first_edge == 0:
        return h * HOUR_S
    return 0 if h == 0 else first_edge + (h - 1) * HOUR_S


def summary(quality: list[str], bursts: list[Burst], moves: list[Span], stages: list[str],
            periods: list[tuple[int, int]], first_edge: int) -> dict[str, Any]:
    """The report's `extras` (without the hours' clock times): see the module docstring."""
    n = len(stages)
    if len(quality) != n:
        raise ValueError(f"{len(quality)} quality epochs for {n} stages")
    asleep = asleep_mask(stages, periods)
    hours: list[dict[str, Any]] = []
    night, sleep = _tally(), _tally()
    for e in range(n):
        h = _hour_of(e, first_edge)
        while len(hours) <= h:
            hours.append({"from_s": _hour_from(len(hours), first_edge), **_tally(), "asleep_min": 0.0})
        q = f"{quality[e]}_min"
        for t in (hours[h], night) + ((sleep,) if asleep[e] else ()):
            t["min"] += 0.5
            t[q] += 0.5
        if asleep[e]:
            hours[h]["asleep_min"] += 0.5

    def add(second: int, key: str) -> None:
        e = second // EPOCH_S
        if e >= n:
            return
        for t in (hours[_hour_of(e, first_edge)], night) + ((sleep,) if asleep[e] else ()):
            t[key] += 1

    for a, _, kind in bursts:
        add(a, KINDS[kind])
    for a, _ in moves:
        add(a, "moves")
    asleep_epochs = sum(asleep)
    sleep["jaw_per_hour"] = per_hour(sleep["jaw_bursts"], asleep_epochs)
    sleep["moves_per_hour"] = per_hour(sleep["moves"], asleep_epochs)
    return {
        "version": VERSION,
        "rules": RULES,
        "validated": False,
        "epoch_s": EPOCH_S,
        "quality": "".join(QUALITY_CHAR[q] for q in quality),
        "night": night,
        "asleep": sleep,
        "hours": hours,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("recordings", type=Path)
    ap.add_argument("night", help="the night's name, e.g. 2026-11-17 (scripts/night_files.py)")
    ap.add_argument("sleep_json", type=Path, help="a laptop <night>.sleep.json with the same start")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
    import night_files as nf  # noqa: PLC0415
    import sleep_report as sr  # noqa: PLC0415
    import to_bdf  # noqa: PLC0415

    nights = [n for n in nf.nights(nf.recordings(a.recordings)) if n.name == a.night]
    if not nights:
        raise SystemExit(f"no night {a.night} in {a.recordings}")
    t0 = time.time()
    start, uv, notes = to_bdf.join([r.path for r in nights[0].recs])
    t_join = time.time() - t0
    seen = see(uv, notes)
    del uv
    t_see = time.time() - t0 - t_join
    scored = json.loads(a.sleep_json.read_text())
    if datetime.fromisoformat(scored["start"]) != start:
        raise SystemExit(f"{a.sleep_json} starts at {scored['start']}, the recordings at {start}")
    stages = [str(e["anysleep"]) for e in scored["epochs"]]
    found, _ = sr.periods(stages)
    periods = [(p["first"], p["last"]) for p in found]
    quality, bursts, moves = events(seen)
    out = summary(quality, bursts, moves, stages, periods, first_edge_s(start))
    res = {
        "night": a.night, "recordings": len(nights[0].recs), "epochs": len(stages), "first_edge_s": first_edge_s(start),
        "periods": periods, "join_s": round(t_join, 1), "detectors_s": round(t_see, 1),
        "peak_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024),
        "extras": out, "bursts": bursts, "moves": moves,
    }
    text = json.dumps(res, indent=1)
    if a.out:
        a.out.write_text(text)
    print(json.dumps({k: v for k, v in res.items() if k not in ("bursts", "moves")} | {"extras": {k: v for k, v in out.items() if k not in ("quality", "hours")}}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
