"""Memory cues in deep sleep (DECISIONS 500-509): the reference for app/lib/memory_cues/rule.dart and its check on a
recorded night.

The protocol is targeted memory reactivation (TMR) as a self-test: in the evening you learn where objects sit on a
board, each half of them with its own soft sound; in the night's first hours one of the two sounds is played softly
again in light or deep NREM sleep (N2/N3), and in the morning both halves are tested. The app plays a sound only when
all of these hold (planning values, `Rule` below):
  - the cue hours: from 30 minutes to 4.5 hours after Lights off (or the night's first sample): deep sleep is mostly
    in the first half of the night, and the lucid dream cues' hours start at 4.5 hours;
  - the live sleep model (live_stager.py: AnySleep every 30 s on the last 60 minutes, 2 minutes behind) read the two
    newest epochs as N2 or N3, each with a top probability of at least 0.6, and that reading is fresh;
  - away from waking: no awake epoch (or lost one: it may hide waking) read in the 5 minutes before the newest epoch;
  - away from stirs: no movement (3+ channels jumping) in the last 3 minutes and no jaw muscle (both temple sides) in
    the last 30 s; the drift-off detector does not say awake;
  - at most one sound every 10 s and 120 a night.
The sound plays 3 dB under the loudness you just heard in the evening and never louder. The lucid cues' stir rule:
the drift-off detector saying awake, or 3 seconds of movement, within 30 s after a sound, or an awake epoch read later
for those 30 s, is an arousal: 3 dB quieter and 5 minutes without sounds; after 3 arousals no more that night.

usage (from the repo root):
  uv run --project analysis python analysis/memory_cues.py cases app/test/fixtures/memory_cases.json
  # when would sounds have played on a recorded night, and where does the full-night scoring put them? The live stages
  # come from a whole-night replay (live_stager.py replay, the model from the night's first sample as the app runs
  # it for these cues); --nap N reads the replay's N-th restart (its --lights-off-min) as a night of its own
  uv run --project analysis python analysis/memory_cues.py replay NIGHT.bdf NIGHT.sleep.json LIVE.npz \\
      [--lights-off HH:MM] [--nap N] [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402
import lucid_cues as lc  # noqa: E402

FS = det.FS
EPOCH_S = 30

# ---- the rule (planning values; DECISIONS 502) ----
CUES_FROM_S = 30 * 60  # after Lights off (or the night's first sample)
CUES_UNTIL_S = 270 * 60  # the cue hours end 4.5 hours after Lights off
NREM_RUN = 2  # the two newest epochs read as N2 or N3
MIN_CONF = 0.6  # each with the model's top probability at least this
BEHIND_EP = 4  # the live model reads 2 minutes behind
STALE_EP = 3  # the newest reading may lag at most this many epochs more than that (else the model has stopped)
WAKE_GUARD_EP = 10  # no awake or lost epoch read in the 5 minutes before the newest epoch
STILL_S = 180  # no movement in the last 3 minutes
JAW_STILL_S = 30  # no jaw muscle in the last 30 s
SPACING_S = 10  # one sound every 10 s at most
PER_NIGHT = 120
AROUSAL_S = 30  # awake, or AROUSAL_MOVES seconds of movement, within 30 s after a sound
AROUSAL_MOVES = 3
AROUSAL_PAUSE_S = 300
AROUSAL_DOWN_DB = 3  # quieter after an arousal
STOP_AFTER_AROUSALS = 3
MARGIN_DB = 3  # under the evening's "just heard" loudness
NREM = ("N2", "N3")


def gain(down_db: int) -> float:
    """The sound's amplitude against the evening's level, [down_db] decibels under it (never above it)."""
    return float(10 ** (-max(down_db, 0) / 20))


@dataclass
class Cue:
    k: int
    down: int  # dB under the evening's level
    period: int  # the stretch of N2/N3 it fell in (from 1)
    aroused: bool = False


@dataclass
class Rule:
    """The cue rule, stepped once a second of signal; the live stages are given as they are handed out."""

    cues_from: int  # second (on this rule's clock) from which sounds may play
    cues_until: int  # second at which the cue hours end
    newest: tuple[int, str, float] | None = None
    prev: tuple[int, str, float] | None = None
    last_wake: int | None = None
    last_moved: int | None = None
    last_jaw: int | None = None
    moves_since_cue: int = 0
    down: int = MARGIN_DB
    period: int = 0
    period_open: bool = False
    pause_until: int = 0
    cues: list[Cue] = field(default_factory=list)
    arousals: list[int] = field(default_factory=list)
    stops: list[list[Any]] = field(default_factory=list)
    done: str | None = None

    def stage(self, epoch: int, stage: str, conf: float, k: int) -> None:
        """Epoch [epoch] read as [stage] (W N1 N2 N3 R or gap) with top probability [conf], known at second k."""
        if stage in ("W", "gap"):
            self.last_wake = epoch if self.last_wake is None else max(self.last_wake, epoch)
        if stage not in NREM:
            self.period_open = False
        self.prev, self.newest = self.newest, (epoch, stage, conf)
        if stage == "W":
            lo, hi = epoch * EPOCH_S, (epoch + 1) * EPOCH_S - 1
            hit = [c for c in self.cues if not c.aroused and c.k <= hi and c.k + AROUSAL_S >= lo]
            if hit:
                for c in hit:
                    c.aroused = True
                self._arousal(k)

    def why_not(self, k: int, drift: str | None) -> str | None:
        """Why no sound may play at second k (None: it may)."""
        if k < self.cues_from:
            return "before"
        if self.done:
            return "done"
        if k < self.pause_until:
            return "pause"
        n, p = self.newest, self.prev
        if n is None or p is None or p[0] != n[0] - 1 or n[1] not in NREM or p[1] not in NREM:
            return "not N2/N3"
        if min(n[2], p[2]) < MIN_CONF:
            return "not N2/N3"
        if n[0] < k // EPOCH_S - BEHIND_EP - STALE_EP:
            return "stale"
        if self.last_wake is not None and n[0] - self.last_wake <= WAKE_GUARD_EP:
            return "waking"
        if self.last_moved is not None and k - self.last_moved <= STILL_S:
            return "moving"
        if self.last_jaw is not None and k - self.last_jaw <= JAW_STILL_S:
            return "jaw"
        if drift == "awake":
            return "awake"
        if self.cues and k - self.cues[-1].k < SPACING_S:
            return "spacing"
        return None

    def second(self, k: int, moved: bool, jaw: bool, drift: str | None) -> Cue | None:
        """Second k: [moved] movement in it (3+ channels jumping), [jaw] jaw muscle, [drift] the drift-off detector's
        state (None: not running). Returns the sound to play now, if any."""
        last = self.cues[-1] if self.cues else None
        if last is not None and 0 < k - last.k <= AROUSAL_S:
            self.moves_since_cue += moved
            if not last.aroused and (drift == "awake" or self.moves_since_cue >= AROUSAL_MOVES):
                last.aroused = True
                self._arousal(k)
        if moved:
            self.last_moved = k
        if jaw:
            self.last_jaw = k
        if k >= self.cues_until and k >= self.cues_from:
            self._stop(k, "hours over")
        if self.why_not(k, drift) is not None:
            return None
        if not self.period_open:
            self.period += 1
            self.period_open = True
        c = Cue(k, self.down, self.period)
        self.cues.append(c)
        self.moves_since_cue = 0
        if len(self.cues) >= PER_NIGHT:
            self._stop(k, "per night")
        return c

    def _arousal(self, k: int) -> None:
        self.arousals.append(k)
        self.down += AROUSAL_DOWN_DB
        self.pause_until = max(self.pause_until, k + AROUSAL_PAUSE_S)
        if len(self.arousals) >= STOP_AFTER_AROUSALS:
            self._stop(k, "three arousals")

    def _stop(self, k: int, why: str) -> None:
        if self.done is None:
            self.done = why
            self.stops.append([k, why])


# ---- the shared hand-worked cases (app/test/fixtures/memory_cases.json) ----


def case_inputs(case: dict[str, Any]) -> tuple[dict[int, list[tuple[int, str, float]]], set[int], set[int], list[str | None]]:
    """Per second: the stages handed out (epoch e known at second (e + 1 + 4) * 30 unless given), the movement and
    jaw seconds and the drift-off state (the lucid cases' format without eye bursts)."""
    stages, moved, jaw, _, drift = lc.case_inputs(case)
    return stages, moved, jaw, drift


def run_case(case: dict[str, Any]) -> dict[str, Any]:
    stages, moved, jaw, drift = case_inputs(case)
    r = Rule(cues_from=int(case["cues_from_s"]), cues_until=int(case.get("cues_until_s", 10**9)))
    for k in range(int(case["seconds"])):
        for e, st, conf in sorted(stages.get(k, [])):
            r.stage(e, st, conf, k)
        r.second(k, k in moved, k in jaw, drift[k])
    return {"cues": [[c.k, c.down, c.period] for c in r.cues], "arousals": r.arousals, "stops": r.stops}


def cmd_cases(a: argparse.Namespace) -> None:
    bad = 0
    for case in json.loads(Path(a.cases).read_text())["cases"]:
        got = run_case(case)
        exp = case["expect"]
        stops = exp.get("stops", got["stops"])
        ok = (got["cues"], got["arousals"], got["stops"]) == (exp["cues"], exp["arousals"], stops)
        bad += not ok
        print(("ok  " if ok else "FAIL") + f" {case['name']}" + ("" if ok else f": got {got}"))
    sys.exit(1 if bad else 0)


# ---- the replay on a recorded night ----


def wake_distance_min(offline: list[str], e: int) -> float:
    """Minutes from epoch e to the nearest epoch the full-night scoring calls awake (either side); inf if none."""
    best = float("inf")
    for j, s in enumerate(offline):
        if s == "W":
            best = min(best, abs(j - e) / 2)
    return best


def replay(x: det.Floats, miss: det.Bools, offline: list[str], live: list[str | None], probs: det.Floats,
           lights_off: int, first: int = 0, last: int | None = None) -> dict[str, Any]:
    """The rule over seconds [first, last) of a night whose live stages ([live], [probs] per epoch, on the night's
    clock) came from a model started at [first]; Lights off at second [lights_off]."""
    sec = det.seconds(x, miss)
    moved = sec.movement
    jaw = lc.jaw_seconds(sec)
    drift = lc.drift_states(sec, x, miss, lights_off)
    end = sec.n if last is None else min(sec.n, last)
    cues_from, cues_until = lights_off + CUES_FROM_S, lights_off + CUES_UNTIL_S
    r = Rule(cues_from=cues_from, cues_until=cues_until)
    handed: dict[int, list[int]] = {}
    for e, st in enumerate(live):
        if st is not None and e * EPOCH_S >= first:
            handed.setdefault((e + 1 + BEHIND_EP) * EPOCH_S, []).append(e)
    reasons: dict[str, int] = {}
    for k in range(first, end):
        for e in handed.get(k, []):
            st = live[e]
            r.stage(e, st, float(np.nanmax(probs[e])) if st != "gap" else 0.0, k)
        r.second(k, bool(moved[k]), bool(jaw[k]), drift[k])
        if cues_from <= k < cues_until and k % EPOCH_S == 0:
            why = r.why_not(k, drift[k]) or "cue"
            reasons[why] = reasons.get(why, 0) + 1

    def off(k: int) -> str:
        e = k // EPOCH_S
        return offline[e] if e < len(offline) else "gap"

    by_stage: dict[str, int] = {}
    for c in r.cues:
        by_stage[off(c.k)] = by_stage.get(off(c.k), 0) + 1
    near = [wake_distance_min(offline, c.k // EPOCH_S) for c in r.cues]
    hours = [e for e in range(cues_from // EPOCH_S, min(cues_until // EPOCH_S, len(offline)))]
    nrem_min = {s: sum(1 for e in hours if offline[e] == s) / 2 for s in ("N2", "N3")}
    return {
        "cues": len(r.cues),
        "cues_by_offline_stage": by_stage,
        "periods": r.period,
        "minutes_to_nearest_awake_epoch": {
            "min": min(near) if near else None,
            "median": float(np.median(near)) if near else None,
            "under_2": sum(1 for d in near if d < 2),
            "under_5": sum(1 for d in near if d < 5),
        },
        "offline_minutes_in_cue_hours": nrem_min,
        "arousals": r.arousals,
        "stops": r.stops,
        "why_no_cue_at_epoch_starts_in_cue_hours": dict(sorted(reasons.items(), key=lambda kv: -kv[1])),
        "cue_list": [dict(k=c.k, down=c.down, period=c.period, offline=off(c.k), aroused=c.aroused) for c in r.cues],
    }


def cmd_replay(a: argparse.Namespace) -> None:
    import live_stager as ls
    import validate_detectors as val

    x, miss, start = val.load_bdf(a.bdf)
    offline, s_start = val.load_stages(a.sleep)
    if s_start != start:
        raise SystemExit("BDF and sleep.json start differ")
    z = np.load(a.live)
    if abs(float(z["start"]) - start.timestamp()) > 1:
        raise SystemExit("the live replay is of another night")
    gap = z["gap"]
    if a.nap is None:
        first = 0
        lag = ls.mask_gappy(z["lag"], gap)
        last = None
    else:
        e0 = int(z[f"nap{a.nap}_ep"])
        first = e0 * EPOCH_S
        nap = ls.mask_gappy(z[f"nap{a.nap}_lag"], gap[e0:])
        n_ep = nap.shape[2]
        lag = np.full((nap.shape[0], nap.shape[1], e0 + n_ep, 5), np.nan, np.float32)
        lag[:, :, e0:] = nap  # the restarted stream's epochs, back on the night's clock
        last = (e0 + n_ep) * EPOCH_S
    probs = lag[:, BEHIND_EP].mean(0)
    live = ls.stages_at(lag, BEHIND_EP, np.concatenate([gap, np.zeros(max(0, lag.shape[2] - len(gap)), bool)]))
    lights_off = first
    if a.lights_off:
        h, m = map(int, a.lights_off.split(":"))
        t = start.replace(hour=h, minute=m, second=0)
        if t < start:
            t += timedelta(days=1)
        lights_off = int((t - start).total_seconds())
    rep = replay(x, miss, offline, live, probs, lights_off, first=first, last=last)
    rep = {
        "night": a.bdf.name,
        "lights_off": lc.clock(start, lights_off),
        "cue_hours": [lc.clock(start, lights_off + CUES_FROM_S), lc.clock(start, lights_off + CUES_UNTIL_S)],
        "rules": {"min_conf": MIN_CONF, "wake_guard_ep": WAKE_GUARD_EP, "still_s": STILL_S, "jaw_still_s": JAW_STILL_S,
                  "spacing_s": SPACING_S, "per_night": PER_NIGHT, "arousal_moves": AROUSAL_MOVES},
        **rep,
        "arousals": [lc.clock(start, k) for k in rep["arousals"]],
        "stops": [[lc.clock(start, k), w] for k, w in rep["stops"]],
        "cue_list": [dict(c, at=lc.clock(start, c.pop("k"))) for c in rep["cue_list"]],
    }
    text = json.dumps(rep, indent=1)
    if a.json:
        Path(a.json).write_text(text)
    print(text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cases")
    c.add_argument("cases", type=Path)
    r = sub.add_parser("replay")
    r.add_argument("bdf", type=Path)
    r.add_argument("sleep", type=Path)
    r.add_argument("live", type=Path)
    r.add_argument("--lights-off")
    r.add_argument("--nap", type=int)
    r.add_argument("--json", type=Path)
    a = ap.parse_args()
    {"cases": cmd_cases, "replay": cmd_replay}[a.cmd](a)


if __name__ == "__main__":
    main()
