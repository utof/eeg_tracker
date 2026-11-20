"""The dream sleep (REM) check of a night's sleep report (DECISIONS 740-749). Measurement only: nothing here changes
a stage. It makes later scoring fixes checkable: on the owner's two phone nights REM came out at 7-10 % of sleep
against a usual 20-25 %, and the report kept only the stage letters (research note
`_local/research/2026-11-20-15-sleep-scoring-no-fit.md`, ranked step 0).

The Python reference for the phone's `app/lib/sleep/rem_check.dart`: the same rules give the same numbers and the same
sentences (`app/test/rem_check_cross_check_test.dart`, fixture made by `analysis/make_rem_fixture.py`).

- `probs`: the sleep model's per-epoch stage probabilities, kept in the report next to `stages`: permille (0-1000)
  as little-endian uint16, 5 per epoch in the order W N1 N2 N3 R, epoch-major, base64 (`encode_probs`,
  `decode_probs`; docs/data-format.md).
- The eye-movement detector: side-to-side eye movements from a left-right pair of channels near the eyes, taken from
  the recording's header (`eye_pair`: T3-T4 on the BrainBit; any count and placement of electrodes), counted per 30 s
  epoch (`eye_epochs`). Its thresholds are the research note's, chosen once on night 11-19 and not tuned: planning
  values, not validated.
- The night's numbers (`night_check`, the report's `rem_check`) and their words (`check_lines`).

Standard library only, except `eye_epochs` (numpy and scipy, imported when called), so scripts/phone_night_check.py
can read and word a report without numpy. Numbers are rounded with integer arithmetic (halves up), so Dart gets the
very same values.
"""

from __future__ import annotations

import base64
import math
import struct
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import recording  # noqa: E402  (channel names and 10-10 sites; standard library only)

VERSION = 1  # of the report's `rem_check` object
RULES = "measurement only; planning values (DECISIONS 740-749)"
EPOCH_S = 30
ASLEEP = ("N1", "N2", "N3", "R")
GAP = "gap"

# ---- the probabilities in the report ----
PROB_ORDER = "W N1 N2 N3 R"
PROB_PER = 1000  # permille: the precision of the laptop's sleep.json (3 decimals)

# ---- the eye-movement detector (planning values: the research note's, chosen once and not tuned) ----
EYE_LOW_HZ = 0.5  # the pair's signals: 2nd-order Butterworth high-pass at 0.5 Hz ...
EYE_HIGH_HZ = 5.0  # ... and low-pass at 5 Hz, forward only from the first value (the shared detectors' filters)
EYE_SWING_UV = 40.0  # an eye-movement second: left minus right swings more than this peak to peak ...
EYE_MAX_R = -0.3  # ... while left and right move in opposite directions (their correlation in that second below this)
ARTEFACT_HP_HZ = 0.3  # an epoch where either channel, high-passed at 0.3 Hz, goes past ARTEFACT_UV is not measured
ARTEFACT_UV = 1500.0  # (rails, a loose electrode, gross movement)
MEASURED_S = 27  # an epoch is measured when at least this many of its 30 seconds have no missing sample
DENSE_S = 4  # an epoch with at least this many eye-movement seconds is "dense"

# ---- which pair (DECISIONS 743) ----
# 10-10 pairs that see side-to-side eye movements, nearest the eyes first; matched by name or site as the sleep tools
# match theirs (T3 and T4 are T7 and T8)
EYE_PAIRS = (("F7", "F8"), ("F9", "F10"), ("AF7", "AF8"), ("FT9", "FT10"), ("FT7", "FT8"), ("T9", "T10"), ("T7", "T8"))
# electrodes placed by hand, not at a 10-10 site, with their direction in the header (x right, y front, z up): a
# left-right pair whose left one lies within EYE_CORNER_MAX of the left outer eye corner (polar 105, azimuth -40
# degrees: an estimate) and whose right one is within MIRROR_MAX of its mirror image
EYE_CORNER = (-0.621, 0.740, -0.259)
EYE_CORNER_MAX = 0.6
MIRROR_MAX = 0.2
NO_PAIR = "not available on this layout (no left-right pair of electrodes near the eyes)"

# ---- the words: usual values for adults (textbook; the research note), a red flag and never a target ----
USUAL_SHARE_PCT = (20, 25)
USUAL_FIRST_H = (1, 2)
CLOSE_MIN = 5.0  # the model's REM likelihood counts as "about" what it scored within this many minutes ...
CLOSE_SHARE = 0.15  # ... or this share of it, whichever is more

_DIGITS = "0123456789abcdefghijklmnopqrstu"  # eye-movement seconds of an epoch, 0-30, one character; `-` not measured


def _half_up(a: int, b: int) -> int:
    """a / b rounded to the nearest integer, halves up (a >= 0, b > 0)."""
    return (2 * a + b) // (2 * b)


def _share(a: int, b: int) -> float | None:
    """a / b to 3 decimals, halves up; None when b is 0."""
    return None if b == 0 else _half_up(1000 * a, b) / 1000


# ---- probabilities ----------------------------------------------------------------------------------------------------

def permille(p: float) -> int:
    """A probability as an integer 0-1000, halves up (the phone rounds the same way)."""
    return min(PROB_PER, max(0, math.floor(p * PROB_PER + 0.5)))


def encode_probs(probs: Sequence[Sequence[float]]) -> dict[str, Any]:
    """The report's `probs` from per-epoch probabilities (each W N1 N2 N3 R)."""
    flat = [permille(v) for row in probs for v in row]
    if any(len(row) != 5 for row in probs):
        raise ValueError("five probabilities per epoch (W N1 N2 N3 R)")
    return {"order": PROB_ORDER, "per": PROB_PER, "data": base64.b64encode(struct.pack(f"<{len(flat)}H", *flat)).decode()}


def decode_probs(obj: object) -> list[list[int]] | None:
    """Permille per epoch (W N1 N2 N3 R) from a report's `probs`; None when missing or not one."""
    if not isinstance(obj, dict) or obj.get("order") != PROB_ORDER or obj.get("per") != PROB_PER:
        return None
    try:
        raw = base64.b64decode(str(obj.get("data")), validate=True)
    except ValueError:
        return None
    if len(raw) % 10:
        return None
    v = struct.unpack(f"<{len(raw) // 2}H", raw)
    if any(x > PROB_PER for x in v):
        return None
    return [list(v[i:i + 5]) for i in range(0, len(v), 5)]


# ---- the eye pair -----------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class EyePair:
    left: int  # in the record
    right: int
    names: tuple[str, str]

    @property
    def label(self) -> str:
        return f"{self.names[0]}-{self.names[1]}"


def _dist(a: Sequence[float], b: Sequence[float]) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def eye_pair(header: recording.Header) -> EyePair | None:
    """The left-right pair of channels the eye-movement detector reads, or None (NO_PAIR): the first of EYE_PAIRS the
    recording holds, else two electrodes placed by hand at the eye corners (see EYE_CORNER)."""
    for left, right in EYE_PAIRS:
        try:
            i, j = recording.pick(header, [left, right], "the eye-movement check")
        except recording.MissingChannels:
            continue
        if i != j:
            return EyePair(i, j, (header.channels[i].name, header.channels[j].name))
    placed = [(k, c.xyz) for k, c in enumerate(header.channels) if c.xyz is not None and c.site is None]
    best: tuple[float, int, int] | None = None
    for i, a in placed:
        if a[0] >= 0 or _dist(a, EYE_CORNER) > EYE_CORNER_MAX:
            continue
        for j, b in placed:
            if b[0] <= 0 or _dist((-a[0], a[1], a[2]), b) > MIRROR_MAX:
                continue
            d = _dist(a, EYE_CORNER) + _dist(b, (-EYE_CORNER[0], EYE_CORNER[1], EYE_CORNER[2]))
            if best is None or d < best[0]:
                best = (d, i, j)
    if best is None:
        return None
    return EyePair(best[1], best[2], (header.channels[best[1]].name, header.channels[best[2]].name))


# ---- the detector -----------------------------------------------------------------------------------------------------

def eye_seconds(left: Sequence[float], right: Sequence[float], fs: int = 250) -> tuple[Any, Any, Any]:
    """Per whole second: the swing (peak to peak, µV) of left minus right and the correlation of left and right, both
    band-passed (EYE_LOW_HZ-EYE_HIGH_HZ), and the larger |value| of the two high-passed at ARTEFACT_HP_HZ."""
    import numpy as np  # noqa: PLC0415  (the rest of this module is standard library only)

    import eeg_detectors as det  # noqa: PLC0415

    lv, rv = np.asarray(left, dtype=np.float64), np.asarray(right, dtype=np.float64)
    if lv.shape != rv.shape or lv.ndim != 1:
        raise ValueError("left and right: two equal 1-d arrays")
    n_s = len(lv) // fs
    if n_s == 0:
        return np.zeros(0), np.zeros(0), np.zeros(0)
    band = [det.highpass(EYE_LOW_HZ, fs=fs), det.lowpass(EYE_HIGH_HZ, fs=fs)]
    hp = [det.highpass(ARTEFACT_HP_HZ, fs=fs)]
    m = n_s * fs
    a = det.run_chain(band, lv)[:m].reshape(n_s, fs)
    b = det.run_chain(band, rv)[:m].reshape(n_s, fs)
    big = np.maximum(np.abs(det.run_chain(hp, lv)[:m]), np.abs(det.run_chain(hp, rv)[:m])).reshape(n_s, fs).max(1)
    d = a - b
    swing = d.max(1) - d.min(1)
    ac, bc = a - a.mean(1, keepdims=True), b - b.mean(1, keepdims=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        r = (ac * bc).sum(1) / np.sqrt((ac * ac).sum(1) * (bc * bc).sum(1))
    return swing, r, big


def eye_epochs(left: Sequence[float], right: Sequence[float], missing: Sequence[bool] | None = None, fs: int = 250
               ) -> list[int | None]:
    """Eye-movement seconds per 30 s epoch from the first sample (the stages' epochs), None for an epoch not measured
    (a gross artefact, or under MEASURED_S seconds without a missing sample). `left` and `right`: the pair's channels
    in µV as the night is joined (held over gaps, `missing` set there; scripts/to_bdf.py)."""
    import numpy as np  # noqa: PLC0415

    swing, r, big = eye_seconds(left, right, fs)
    n_s = len(swing)
    miss = np.zeros(len(left), bool) if missing is None else np.asarray(missing, dtype=bool)
    gap_s = miss[: n_s * fs].reshape(n_s, fs).any(1) if n_s else np.zeros(0, bool)
    moved = (swing > EYE_SWING_UV) & (r < EYE_MAX_R)
    out: list[int | None] = []
    for e in range(n_s // EPOCH_S):
        s = slice(e * EPOCH_S, (e + 1) * EPOCH_S)
        ok = ~gap_s[s]
        if (big[s] > ARTEFACT_UV).any() or int(ok.sum()) < MEASURED_S:
            out.append(None)
        else:
            out.append(int((moved[s] & ok).sum()))
    return out


def eye_text(epochs: Sequence[int | None]) -> str:
    """One character per epoch: 0-9 then a-u for 10-30 eye-movement seconds, `-` not measured."""
    return "".join("-" if n is None else _DIGITS[n] for n in epochs)


def eye_from_text(text: object) -> list[int | None] | None:
    if not isinstance(text, str) or any(c != "-" and c not in _DIGITS for c in text):
        return None
    return [None if c == "-" else _DIGITS.index(c) for c in text]


# ---- the night's numbers ----------------------------------------------------------------------------------------------

def eye_measured(pair: str, epochs: Sequence[int | None]) -> dict[str, Any]:
    """What `night_check` takes for a night whose eye movements were measured."""
    return {"pair": pair, "why": None, "epochs": list(epochs)}


def eye_not(why: str) -> dict[str, Any]:
    """... and for one whose were not (no pair on this layout, or the signal pass failed)."""
    return {"pair": None, "why": why, "epochs": []}


def night_check(stages: Sequence[str], periods: Sequence[tuple[int, int]],
                probs: Sequence[Sequence[int]] | None = None, eye: dict[str, Any] | None = None) -> dict[str, Any]:
    """The report's `rem_check` from the stages (W N1 N2 N3 R or gap per 30 s epoch), the sleep periods (first and last
    epoch, inclusive), the model's probabilities in permille (decode_probs; None for a report without them) and the
    eye movements (eye_measured / eye_not; None for a report from before the check). Only epochs inside the sleep
    periods count, as the report's totals count them."""
    n = len(stages)
    inside = [False] * n
    for a, b in periods:
        for e in range(max(0, a), min(n - 1, b) + 1):
            inside[e] = True
    asleep = [inside[e] and stages[e] in ASLEEP for e in range(n)]
    rem = [inside[e] and stages[e] == "R" for e in range(n)]
    n_asleep, n_rem = sum(asleep), sum(rem)
    out: dict[str, Any] = {"version": VERSION, "rules": RULES, "validated": False,
                           "asleep_min": n_asleep / 2, "rem_min": n_rem / 2, "rem_share": _share(n_rem, n_asleep)}
    first_rem = thirds = None
    if periods and n_asleep:
        i0 = min(a for a, _ in periods)
        i1 = min(n - 1, max(b for _, b in periods))
        hit = next((e for e in range(i0, n) if rem[e]), None)
        first_rem = None if hit is None else (hit - i0) / 2
        span = i1 - i0 + 1
        edge = [i0 + t * span // 3 for t in range(4)]
        thirds = [sum(rem[edge[t]:edge[t + 1]]) / 2 for t in range(3)]
    out["first_rem_min"] = first_rem
    out["thirds_rem_min"] = thirds
    prob = None
    if probs is not None and len(probs) >= n:
        mass = sum(probs[e][4] for e in range(n) if inside[e] and stages[e] != GAP)
        prob = _half_up(mass, 200) / 10  # permille x 0.5 min = mass / 2000 min, to 0.1 min
    out["rem_prob_min"] = prob
    out["eye"] = None if eye is None else _eye_numbers(stages, asleep, eye)
    return out


def _eye_numbers(stages: Sequence[str], asleep: list[bool], eye: dict[str, Any]) -> dict[str, Any]:
    if eye.get("pair") is None:
        return {"pair": None, "why": eye.get("why") or NO_PAIR}
    ep = list(eye.get("epochs") or [])
    n = len(stages)
    ep = (ep + [None] * n)[:n]
    measured = {s: 0 for s in ASLEEP}
    seconds = {s: 0 for s in ASLEEP}
    dense = {s: 0 for s in ASLEEP}
    for e in range(n):
        v = ep[e]
        if asleep[e] and v is not None:
            st = stages[e]
            measured[st] += 1
            seconds[st] += v
            dense[st] += v >= DENSE_S
    all_m, all_s = sum(measured.values()), sum(seconds.values())
    other_m = all_m - measured["R"]
    other_s = all_s - seconds["R"]
    return {
        "pair": eye["pair"], "why": None, "epochs": eye_text(ep),
        "measured_min": all_m / 2,
        "in_rem_share": _share(seconds["R"], all_s),
        "rem_epoch_share": _share(measured["R"], all_m),
        "rem_per_min": None if measured["R"] == 0 else _half_up(20 * seconds["R"], measured["R"]) / 10,
        "other_per_min": None if other_m == 0 else _half_up(20 * other_s, other_m) / 10,
        "dense_share": {s: _share(dense[s], measured[s]) for s in ASLEEP if measured[s]},
    }


def check_of_report(rep: dict) -> dict[str, Any] | None:
    """A report's `rem_check`, or for a report from before it the stage-only check (no probabilities, no eye
    movements) from its `stages` and periods; None when the report has neither (an older laptop report)."""
    rc = rep.get("rem_check")
    if isinstance(rc, dict) and rc.get("version") == VERSION:
        return rc
    stages = stages_of(rep.get("stages"))
    if stages is None or not rep.get("scored"):
        return None
    return night_check(stages, periods_of(rep), decode_probs(rep.get("probs")), None)


_CHAR = {"W": "W", "1": "N1", "2": "N2", "3": "N3", "R": "R", "-": GAP}


def stages_of(text: object) -> list[str] | None:
    """A report's `stages` (W 1 2 3 R -, one per 30 s) as stage names; None when missing."""
    if not isinstance(text, str) or not text:
        return None
    return [_CHAR.get(c, GAP) for c in text]


def periods_of(rep: dict) -> list[tuple[int, int]]:
    """A report's sleep periods as (first, last) epochs from `data_start`."""
    from datetime import datetime  # noqa: PLC0415

    t0 = datetime.fromisoformat(rep["data_start"])
    at = lambda s: round((datetime.fromisoformat(s) - t0).total_seconds() / EPOCH_S)  # noqa: E731
    return [(at(p["start"]), at(p["end"]) - 1) for p in rep.get("periods") or [] if isinstance(p, dict)]


# ---- the words --------------------------------------------------------------------------------------------------------

def duration(minutes: float) -> str:
    """`43 min`, `2 h 05 min` (as the app's durationText, halves up)."""
    total = math.floor(minutes + 0.5)
    return f"{total} min" if total < 60 else f"{total // 60} h {total % 60:02d} min"


def _pct(share: float) -> int:
    return math.floor(share * 100 + 0.5)


def check_lines(c: dict[str, Any]) -> list[str]:
    """The night report's "Dream sleep check" in words, not a score (the phone shows the same lines)."""
    asleep, rem = c["asleep_min"], c["rem_min"]
    if not asleep:
        return ["No sleep was scored, so there is no dream sleep to check."]
    lo, hi = USUAL_SHARE_PCT
    pct = _half_up(round(rem * 2) * 100, round(asleep * 2))
    note = ("this headband's scorer may under-count it." if pct < lo else
            "this night is within it." if pct <= hi else "this night is above it.")
    out = [f"Dream sleep {duration(rem)} ({pct} %). Usual for adults is {lo}-{hi} %; {note}"]
    first, thirds = c.get("first_rem_min"), c.get("thirds_rem_min")
    if first is None or not thirds:
        out.append("No dream sleep was scored inside the sleep periods.")
    else:
        out.append(f"First dream sleep {duration(first)} after falling asleep (usual: {USUAL_FIRST_H[0]}-"
                   f"{USUAL_FIRST_H[1]} h). Last third of the night {duration(thirds[2])}, first third "
                   f"{duration(thirds[0])}; usually the last third has the most.")
    prob = c.get("rem_prob_min")
    if prob is not None:
        head = f"The scorer's own dream-sleep likelihood adds up to {duration(prob)}"
        if abs(prob - rem) <= max(CLOSE_MIN, CLOSE_SHARE * rem):
            out.append(f"{head}, about the {duration(rem)} it scored: it was seldom unsure, so a different cut-off "
                       f"would add little.")
        elif prob > rem:
            out.append(f"{head}, more than the {duration(rem)} it scored: some stretches were close calls.")
        else:
            out.append(f"{head}, less than the {duration(rem)} it scored.")
    eye = c.get("eye")
    if eye is None:
        out.append("This report is older than the check: score the night again to add the scorer's likelihood and "
                   "the eye movements.")
    elif eye.get("pair") is None:
        out.append(f"Eye movements: {eye.get('why') or NO_PAIR}.")
    elif not eye.get("measured_min"):
        out.append(f"Side-to-side eye movements ({eye['pair']}): no clean stretch of sleep to measure.")
    elif eye.get("rem_per_min") is None:
        out.append(f"Side-to-side eye movements ({eye['pair']}): {eye['other_per_min']:.1f} seconds a minute with "
                   f"them in sleep; none of the measured sleep was scored as dream sleep.")
    else:
        out.append(f"Side-to-side eye movements ({eye['pair']}): {_pct(eye['in_rem_share'] or 0)} % of them fell in "
                   f"dream sleep, which is {_pct(eye['rem_epoch_share'])} % of the measured sleep; "
                   f"{eye['rem_per_min']:.1f} seconds a minute with them in dream sleep, {eye['other_per_min'] or 0:.1f} "
                   f"in other sleep.")
        out.append("Dream sleep usually holds the most of them: many in light sleep next to dream sleep can mean it "
                   "was cut short.")
    return out
