"""Lucid dream cues (DECISIONS 300-309): the reference for app/lib/lucid/rule.dart and its check on a recorded night.

The protocol is targeted lucidity reactivation (TLR): before sleep a soft cue is paired with "am I dreaming?"; during
dream sleep (REM) the same cue is played softly again, in the hope that it reaches the dream and reminds you that you
are dreaming. The app plays it only when all of these hold (planning values, `rule` below):
  - the night's second half: from 4.5 hours after Lights off (or the night's first sample);
  - the live sleep model (live_stager.py: AnySleep every 30 s on the last 60 minutes, 2 minutes behind) read the two
    newest epochs as dream sleep (R), each with a top probability of at least 0.6, and that reading is fresh;
  - no deep sleep (N3) read in the 10 minutes before the newest epoch;
  - eyes moving, as in the eye-movement part of dream sleep that the lab studies cue in: an eye burst (two sideways eye
    movements of the detectors, eeg_detectors.py, within 2 s, each with the back of the head quiet: the 0.5-15 Hz
    mean of O1 and O2 within 80 µV from 1 s before to 1 s after) ended in the last 2 minutes;
  - lying still: no movement (3+ channels jumping) in the last minute and no jaw muscle (both temple sides) in the
    last 15 s (dream sleep has short muscle twitches: on the owner's night jaw muscle came in 38 % of 30 s stretches
    of dream sleep);
  - the drift-off detector does not say awake;
  - at most one cue every 30 s, 10 in a dream-sleep period, 30 a night.
The first cue is at the loudness you just heard in the evening practice; each cue is 1 dB louder, up to +6 dB. The
drift-off detector saying awake, or 3 seconds of movement, within 30 s after a cue, or an awake epoch read later for
those 30 s, is an arousal: 3 dB quieter and 5 minutes without cues; after 3 arousals no more cues that night. A
period ends after 2 epochs in a row read as something other than dream sleep.

usage (from the repo root):
  uv run --project analysis python analysis/lucid_cues.py cases app/test/fixtures/lucid_cases.json
  # when would cues have played on a recorded night, and in which stage does the full-night scoring put them? The live
  # stages come from a whole-night replay (live_stager.py replay; its scorer ran all night, a little more context in
  # the first hour than the app's, which starts the model an hour before the cue hours)
  uv run --project analysis python analysis/lucid_cues.py replay NIGHT.bdf NIGHT.sleep.json LIVE.npz \\
      [--lights-off HH:MM] [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402

FS = det.FS
EPOCH_S = 30

# ---- the rule (planning values; DECISIONS 302) ----
CUES_FROM_H = 4.5  # hours after Lights off (or the night's first sample)
MODEL_BEFORE_S = 3600  # the live model and the eye bursts start an hour before, so the model has its full window
REM_RUN = 2  # the two newest epochs read as dream sleep
MIN_CONF = 0.6  # each with the model's top probability at least this
BEHIND_EP = 4  # the live model reads 2 minutes behind
STALE_EP = 3  # the newest reading may lag at most this many epochs more than that (else the model has stopped)
DEEP_GUARD_EP = 20  # no deep sleep read for the 10 minutes before the newest epoch
EYE_RECENT_S = 120  # an eye burst ended within the last 2 minutes
STILL_S = 60  # no movement in the last minute
JAW_STILL_S = 15  # no jaw muscle in the last 15 s
SPACING_S = 30  # one cue every 30 s at most
PER_PERIOD = 10  # cues in one dream-sleep period
PER_NIGHT = 30
PERIOD_END_EP = 2  # a period ends after 2 epochs in a row that are not dream sleep
AROUSAL_S = 30  # awake, or AROUSAL_MOVES seconds of movement, within 30 s after a cue
AROUSAL_MOVES = 3
AROUSAL_PAUSE_S = 300
AROUSAL_DOWN = 3  # steps (dB) quieter after an arousal
STOP_AFTER_AROUSALS = 3
MAX_STEPS = 6  # +6 dB over the evening's level at most
STEP_DB = 1.0

# ---- eye bursts ----
BURST_GAP = 2 * FS  # two sideways eye movements at most 2 s apart
BACK_HALF = FS  # the back of the head is looked at from 1 s before to 1 s after each movement
BACK_QUIET_UV = 80.0


def gain(step: int) -> float:
    """The cue's amplitude against the evening's level: +1 dB a step, at most +6 dB."""
    return float(10 ** (min(max(step, 0), MAX_STEPS) * STEP_DB / 20))


def back_signal(x: det.Floats) -> det.Floats:
    """The mean of O1 and O2 through the blink chain (0.5 Hz high-pass, 15 Hz low-pass), as the phone filters it."""
    return det.run_chain(det.chains()["blink"], (x[0] + x[1]) / 2)


def quiet_back(x: det.Floats, moves: list[det.EyeMove], back: det.Floats | None = None) -> list[int]:
    """The eye movements (their samples) with the back of the head quiet: the filtered O1/O2 mean within
    BACK_QUIET_UV peak to peak from BACK_HALF before to BACK_HALF after. Deep-sleep waves reach O1/O2 through the
    forehead reference and also tip T3-T4 over, so they make "eye movements" in deep sleep; dream sleep's back of the
    head is quiet."""
    b = back_signal(x) if back is None else back
    out = []
    for m in moves:
        lo, hi = m.i - BACK_HALF, m.i + BACK_HALF
        if lo < 0 or hi >= b.shape[0]:
            continue
        if float(np.ptp(b[lo : hi + 1])) < BACK_QUIET_UV:
            out.append(m.i)
    return out


def burst_seconds(quiet: list[int]) -> list[int]:
    """The seconds in which an eye burst becomes known: a quiet-back movement at most BURST_GAP samples after the
    previous one, known once its back-of-head span is in (sample i + BACK_HALF)."""
    return [(b + BACK_HALF) // FS for a, b in zip(quiet, quiet[1:]) if b - a <= BURST_GAP]


@dataclass
class Cue:
    k: int
    step: int
    period: int
    aroused: bool = False


@dataclass
class Rule:
    """The cue rule, stepped once a second of signal; the live stages are given as they are handed out."""

    cues_from: int  # second (on this rule's clock) from which cues may play
    newest: tuple[int, str, float] | None = None
    prev: tuple[int, str, float] | None = None
    last_n3: int | None = None
    not_r_run: int = 0
    last_burst: int | None = None
    last_moved: int | None = None
    last_jaw: int | None = None
    moves_since_cue: int = 0
    step: int = 0
    period: int = 0
    period_open: bool = False
    period_cues: int = 0
    pause_until: int = 0
    cues: list[Cue] = field(default_factory=list)
    arousals: list[int] = field(default_factory=list)
    stops: list[list[Any]] = field(default_factory=list)
    done: str | None = None

    def stage(self, epoch: int, stage: str, conf: float, k: int) -> None:
        """Epoch [epoch] read as [stage] (W N1 N2 N3 R or gap) with top probability [conf], known at second k."""
        if stage == "N3":
            self.last_n3 = epoch if self.last_n3 is None else max(self.last_n3, epoch)
        self.prev, self.newest = self.newest, (epoch, stage, conf)
        self.not_r_run = 0 if stage == "R" else self.not_r_run + 1
        if self.period_open and self.not_r_run >= PERIOD_END_EP:
            self.period_open = False
        if stage == "W":
            lo, hi = epoch * EPOCH_S, (epoch + 1) * EPOCH_S - 1
            hit = [c for c in self.cues if not c.aroused and c.k <= hi and c.k + AROUSAL_S >= lo]
            if hit:
                for c in hit:
                    c.aroused = True
                self._arousal(k)

    def why_not(self, k: int, drift: str | None) -> str | None:
        """Why no cue may play at second k (None: it may)."""
        if k < self.cues_from:
            return "before"
        if self.done:
            return "done"
        if k < self.pause_until:
            return "pause"
        n, p = self.newest, self.prev
        if n is None or p is None or p[0] != n[0] - 1 or n[1] != "R" or p[1] != "R" or min(n[2], p[2]) < MIN_CONF:
            return "no dream sleep"
        if n[0] < k // EPOCH_S - BEHIND_EP - STALE_EP:
            return "stale"
        if self.last_n3 is not None and n[0] - self.last_n3 <= DEEP_GUARD_EP:
            return "deep sleep"
        if self.last_burst is None or k - self.last_burst > EYE_RECENT_S:
            return "eyes"
        if self.last_moved is not None and k - self.last_moved <= STILL_S:
            return "moving"
        if self.last_jaw is not None and k - self.last_jaw <= JAW_STILL_S:
            return "jaw"
        if drift == "awake":
            return "awake"
        if self.period_open and self.period_cues >= PER_PERIOD:
            return "period full"
        if self.cues and k - self.cues[-1].k < SPACING_S:
            return "spacing"
        return None

    def second(self, k: int, moved: bool, jaw: bool, burst: bool, drift: str | None) -> Cue | None:
        """Second k: [moved] movement in it (3+ channels jumping), [jaw] jaw muscle, [burst] an eye burst became known
        in it, [drift] the drift-off detector's state (None: not running). Returns the cue to play now, if any."""
        if burst:
            self.last_burst = k
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
        if self.why_not(k, drift) is not None:
            return None
        if not self.period_open:
            self.period += 1
            self.period_open = True
            self.period_cues = 0
        c = Cue(k, self.step, self.period)
        self.cues.append(c)
        self.moves_since_cue = 0
        self.period_cues += 1
        self.step = min(self.step + 1, MAX_STEPS)
        if len(self.cues) >= PER_NIGHT:
            self._stop(k, "per night")
        return c

    def _arousal(self, k: int) -> None:
        self.arousals.append(k)
        self.step = max(0, self.step - AROUSAL_DOWN)
        self.pause_until = max(self.pause_until, k + AROUSAL_PAUSE_S)
        if len(self.arousals) >= STOP_AFTER_AROUSALS:
            self._stop(k, "three arousals")

    def _stop(self, k: int, why: str) -> None:
        if self.done is None:
            self.done = why
            self.stops.append([k, why])


# ---- the shared hand-worked cases (app/test/fixtures/lucid_cases.json) ----


def _expand(items: list[Any]) -> list[int]:
    out: list[int] = []
    for it in items:
        if isinstance(it, list):
            a, b, every = it
            out.extend(range(a, b + 1, every))
        else:
            out.append(int(it))
    return out


def case_inputs(
    case: dict[str, Any],
) -> tuple[dict[int, list[tuple[int, str, float]]], set[int], set[int], set[int], list[str | None]]:
    """Per second: the stages handed out (epoch e known at second (e + 1 + 4) * 30 unless given), the movement, jaw and
    burst seconds and the drift-off state."""
    n = int(case["seconds"])
    stages: dict[int, list[tuple[int, str, float]]] = {}
    for e0, e1, st, conf in case.get("runs", []):
        for e in range(e0, e1 + 1):
            stages.setdefault((e + 1 + BEHIND_EP) * EPOCH_S, []).append((e, st, float(conf)))
    for known, e, st, conf in case.get("stages", []):
        stages.setdefault(int(known), []).append((int(e), st, float(conf)))
    moved = {k for a, b in case.get("moved", []) for k in range(a, b + 1)}
    jaw = {k for a, b in case.get("jaw", []) for k in range(a, b + 1)}
    burst = set(_expand(case.get("bursts", [])))
    drift: list[str | None] = ["asleep"] * n
    for k0, state in case.get("drift", []):
        for k in range(k0, n):
            drift[k] = state
    return stages, moved, jaw, burst, drift


def run_case(case: dict[str, Any]) -> dict[str, Any]:
    stages, moved, jaw, burst, drift = case_inputs(case)
    r = Rule(cues_from=int(case["cues_from_s"]))
    for k in range(int(case["seconds"])):
        for e, st, conf in sorted(stages.get(k, [])):
            r.stage(e, st, conf, k)
        r.second(k, k in moved, k in jaw, k in burst, drift[k])
    return {"cues": [[c.k, c.step, c.period] for c in r.cues], "arousals": r.arousals, "stops": r.stops}


def cmd_cases(a: argparse.Namespace) -> None:
    bad = 0
    for case in json.loads(Path(a.cases).read_text())["cases"]:
        got = run_case(case)
        exp = case["expect"]
        ok = (got["cues"], got["arousals"]) == (exp["cues"], exp["arousals"]) and got["stops"] == exp.get("stops", got["stops"])
        bad += not ok
        print(("ok  " if ok else "FAIL") + f" {case['name']}" + ("" if ok else f": got {got}"))
    sys.exit(1 if bad else 0)


# ---- the replay on a recorded night ----


def jaw_seconds(sec: det.Seconds) -> det.Bools:
    """Seconds with jaw muscle: one temple side over 4x its rest and both over 2x (the detectors' jaw rule)."""
    on, x = det.muscle_seconds(sec)
    both = np.nan_to_num(x, nan=0.0).min(axis=0) >= det.MUSCLE_BOTH_X
    return on & both


def drift_states(sec: det.Seconds, x: det.Floats, miss: det.Bools, lights_off: int) -> list[str | None]:
    f = det._blink_filtered(x)
    found = det._blinks_from(f, miss)
    del f
    alpha, clean = sec.back_alpha()
    bl = det.blinks_per_second(found, sec.n)
    d = det.DriftOff(lights_off)
    out: list[str | None] = [None] * sec.n
    for k in range(lights_off, sec.n):
        out[k] = d.second(k, float(alpha[k]), bool(clean[k]), bool(sec.movement[k]), float(sec.sem[k]), int(bl[k]))
    return out


def clock(start: datetime, s: float) -> str:
    return (start + timedelta(seconds=s)).strftime("%H:%M:%S")


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
    lag = ls.mask_gappy(z["lag"], gap)
    probs = lag[:, BEHIND_EP].mean(0)
    live = ls.stages_at(lag, BEHIND_EP, gap)

    lights_off = 0
    if a.lights_off:
        h, m = map(int, a.lights_off.split(":"))
        t = start.replace(hour=h, minute=m, second=0)
        if t < start:
            t += timedelta(days=1)
        lights_off = int((t - start).total_seconds())
    sec = det.seconds(x, miss)
    moves = det.eye_moves(x, miss)
    quiet = quiet_back(x, moves)
    bursts = set(burst_seconds(quiet))
    moved = sec.movement
    jaw = jaw_seconds(sec)
    drift = drift_states(sec, x, miss, lights_off)
    del x

    cues_from = lights_off + int(CUES_FROM_H * 3600)
    r = Rule(cues_from=cues_from)
    handed: dict[int, list[int]] = {}
    for e, st in enumerate(live):
        if st is not None:
            handed.setdefault((e + 1 + BEHIND_EP) * EPOCH_S, []).append(e)
    reasons: dict[str, int] = {}
    for k in range(sec.n):
        for e in handed.get(k, []):
            r.stage(e, live[e], float(np.nanmax(probs[e])) if live[e] != "gap" else 0.0, k)
        r.second(k, bool(moved[k]), bool(jaw[k]), k in bursts, drift[k])
        if k >= cues_from and k % EPOCH_S == 0:
            why = r.why_not(k, drift[k]) or "cue"
            reasons[why] = reasons.get(why, 0) + 1

    def off(k: int) -> str:
        e = k // EPOCH_S
        return offline[e] if e < len(offline) else "gap"

    cues = [dict(at=clock(start, c.k), step=c.step, period=c.period, offline=off(c.k), aroused=c.aroused,
                 live=live[r_e] if (r_e := c.k // EPOCH_S - BEHIND_EP - 1) >= 0 else None) for c in r.cues]
    by_stage: dict[str, int] = {}
    for c in cues:
        by_stage[c["offline"]] = by_stage.get(c["offline"], 0) + 1
    rem_after = [e for e in range(cues_from // EPOCH_S, len(offline)) if offline[e] == "R"]
    periods: list[list[int]] = []
    for e in rem_after:
        if periods and e - periods[-1][-1] <= 10:
            periods[-1].append(e)
        else:
            periods.append([e])
    rep = {
        "night": a.bdf.name,
        "lights_off": clock(start, lights_off),
        "cues_from": clock(start, cues_from),
        "rules": {"min_conf": MIN_CONF, "eye_recent_s": EYE_RECENT_S, "back_quiet_uv": BACK_QUIET_UV,
                  "still_s": STILL_S,
                  "jaw_still_s": JAW_STILL_S, "arousal_moves": AROUSAL_MOVES,
                  "spacing_s": SPACING_S, "per_period": PER_PERIOD, "per_night": PER_NIGHT},
        "cues": len(cues),
        "cues_by_offline_stage": by_stage,
        "arousals": [clock(start, k) for k in r.arousals],
        "stops": [[clock(start, k), w] for k, w in r.stops],
        "offline_rem_periods_in_cue_hours": [
            dict(start=clock(start, p[0] * EPOCH_S), end=clock(start, (p[-1] + 1) * EPOCH_S), rem_min=len(p) / 2,
                 cues=sum(1 for c in r.cues if p[0] * EPOCH_S <= c.k < (p[-1] + 1) * EPOCH_S + 120))
            for p in periods
        ],
        "eye_bursts_per_offline_stage_per_hour": {
            s: round(sum(1 for k in bursts if off(k) == s) / max(1e-9, sum(1 for o in offline if o == s) / 120), 1)
            for s in ("W", "N1", "N2", "N3", "R")
        },
        "why_no_cue_at_epoch_starts_in_cue_hours": dict(sorted(reasons.items(), key=lambda kv: -kv[1])),
        "cue_list": cues,
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
    r.add_argument("--json", type=Path)
    a = ap.parse_args()
    {"cases": cmd_cases, "replay": cmd_replay}[a.cmd](a)


if __name__ == "__main__":
    main()
