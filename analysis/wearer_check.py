"""'Was this you?': a soft question when a night or a check-in does not look like the owner's usual brain signal
(DECISIONS rows 370-379; the research: `docs/evidence/was-this-you.md`). The Python reference for the phone's
line-by-line port `app/lib/wearer/check.dart`, checked against a fixture made here (`make_wearer_fixture.py`,
`app/test/wearer_cross_check_test.dart`).

The signal of a recording: three of the most repeatable eyes-closed numbers at the back of the head (O1 and O2
combined, the morning check-in's own measures, `scripts/morning_check.py`):
- alpha speed (`iaf`, Hz): the centre of gravity of the alpha peak above the 1/f line;
- alpha strength (`alpha`): log10 of the 8-13 Hz power (µV²);
- the 1/f slope (`slope`): the background's log-log slope, 2-40 Hz without 7-14 Hz.
A check-in gives them from its 2 minutes with eyes closed; a night from its awake 30 s epochs (by the full-night
sleep model) in the 10 minutes after Lights off. Either needs a minute of clean signal on both back channels and a
clear alpha peak, or the recording is not checked.

The profile: the newest 20 recordings of the same kind (check-ins and nights apart) that were accepted. Silent
until 10 were accepted on at least 5 different days. The distance: each number's z-score against the profile's
mean, with the profile's spread (SD) widened by a floor and for the mean's own uncertainty, combined as their root
mean square. Over 2.5 the recording "does not look like you": the phone asks "Was it you?". A recording joins the
profile while learning, when it looked like you, or when you said it was you; never when you said someone else.

No library beyond NumPy and the morning check-in's own code. Planning values throughout (rows 372-374); the
synthetic back-test is `validate_wearer.py`.
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import morning_check as mc  # noqa: E402

VERSION = 1
FS = mc.FS
EPOCH_S = 30

FEATURES = ("iaf", "alpha", "slope")
# The smallest spread each number may have in a profile (planning values, about half the within-person spreads the
# research implies for wet lab caps): alpha speed in Hz, alpha strength in log10 units (0.08 = about 20 %), the slope.
FLOORS = {"iaf": 0.25, "alpha": 0.08, "slope": 0.10}

N_ENROL = 10  # accepted recordings before it speaks
MIN_DAYS = 5  # ... on at least this many different days
PROFILE_MAX = 20  # the newest accepted recordings of the kind
THRESHOLD = 2.5  # root mean square z over which a recording does not look like you
MIN_CLEAN_S = 60.0  # seconds of clean eyes-closed signal on each back channel
NIGHT_WINDOW_S = 600  # the minutes after Lights off that may be used

WHY_LIGHTS = "no lights off"
WHY_CLEAN = "too little clean signal"
WHY_PEAK = "no alpha peak"

KINDS = ("check-in", "night")


# ---------------------------------------------------------------- the signal of one recording

def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None


def checkin_signal(m: dict) -> tuple[dict[str, float] | None, str | None]:
    """The three numbers of a check-in result (`<start>.morning.json`), or (None, why)."""
    ch = m.get("channels") if isinstance(m.get("channels"), dict) else {}
    clean = [_num((ch.get(n) or {}).get("clean_s_ec")) if isinstance(ch.get(n), dict) else None for n in mc.BACK]
    if any(c is None or c < MIN_CLEAN_S for c in clean):
        return None, WHY_CLEAN
    back = m.get("back") if isinstance(m.get("back"), dict) else {}
    iaf, alpha, slope = (_num(back.get(k)) for k in ("iaf_hz", "alpha_ec_uv2", "aperiodic_slope_ec"))
    if iaf is None or alpha is None or alpha <= 0 or slope is None:
        return None, WHY_PEAK
    return {"iaf": iaf, "alpha": math.log10(alpha), "slope": slope}, None


def night_epochs(stages: list[str], lights_off_s: int, missing: np.ndarray | None, n: int) -> list[int]:
    """The awake epochs, with no filled-in sample, among the 20 from the epoch of Lights off (a multiple of 30 s)."""
    e0 = lights_off_s // EPOCH_S
    out = []
    for e in range(e0, min(e0 + NIGHT_WINDOW_S // EPOCH_S, len(stages))):
        a, b = e * EPOCH_S * FS, (e + 1) * EPOCH_S * FS
        if stages[e] != "W" or b > n:
            continue
        if missing is not None and bool(missing[a:b].any()):
            continue
        out.append(e)
    return out


def night_signal(o1: np.ndarray, o2: np.ndarray, stages: list[str], lights_off_s: int | None,
                 missing: np.ndarray | None) -> tuple[dict[str, float] | None, dict[str, Any]]:
    """The three numbers of a night's first minutes after Lights off (µV from the night's first sample; `stages` one
    per 30 s from it: W N1 N2 N3 R or gap; `missing`: filled-in samples), and the report's `wearer_signal` object."""
    info: dict[str, Any] = {"version": VERSION, "from_s": lights_off_s, "epochs": 0, "clean_s": None,
                            "iaf_hz": None, "alpha_uv2": None, "slope": None, "why": None}
    if lights_off_s is None:
        info["why"] = WHY_LIGHTS
        return None, info
    eps = night_epochs(stages, lights_off_s, missing, min(len(o1), len(o2)))
    info["epochs"] = len(eps)
    if not eps:
        info.update(clean_s=0.0, why=WHY_CLEAN)
        return None, info
    idx = np.concatenate([np.arange(e * EPOCH_S * FS, (e + 1) * EPOCH_S * FS) for e in eps])
    ch = {"O1": mc.channel_measures(np.asarray(o1)[idx], None), "O2": mc.channel_measures(np.asarray(o2)[idx], None)}
    back = mc.back_summary(ch)
    info["clean_s"] = min(ch["O1"]["clean_s_ec"], ch["O2"]["clean_s_ec"])
    info.update(iaf_hz=back["iaf_hz"], alpha_uv2=back["alpha_ec_uv2"], slope=back["aperiodic_slope_ec"])
    if info["clean_s"] < MIN_CLEAN_S:
        info["why"] = WHY_CLEAN
        return None, info
    if back["iaf_hz"] is None or back["alpha_ec_uv2"] is None or back["alpha_ec_uv2"] <= 0:
        info["why"] = WHY_PEAK
        return None, info
    return {"iaf": back["iaf_hz"], "alpha": math.log10(back["alpha_ec_uv2"]),
            "slope": back["aperiodic_slope_ec"]}, info


def report_signal(ws: Any) -> tuple[dict[str, float] | None, str | None]:
    """The three numbers from a night report's `wearer_signal` object, or (None, why)."""
    if not isinstance(ws, dict) or ws.get("version") != VERSION:
        return None, None
    if isinstance(ws.get("why"), str):
        return None, ws["why"]
    iaf, alpha, slope = (_num(ws.get(k)) for k in ("iaf_hz", "alpha_uv2", "slope"))
    if iaf is None or alpha is None or alpha <= 0 or slope is None:
        return None, WHY_PEAK
    return {"iaf": iaf, "alpha": math.log10(alpha), "slope": slope}, None


# ---------------------------------------------------------------- the distance

def _mean(v: list[float]) -> float:
    return sum(v) / len(v)


def _sd(v: list[float]) -> float:
    """Sample SD (n - 1); 0 for one value."""
    if len(v) < 2:
        return 0.0
    m = _mean(v)
    return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1))


def distance(profile: list[dict[str, float]], x: dict[str, float]) -> tuple[float, dict[str, float]]:
    """Root mean square of the three z-scores of x against the profile, and the z-scores."""
    n = len(profile)
    z = {}
    for f in FEATURES:
        v = [p[f] for p in profile]
        scale = math.sqrt(_sd(v) ** 2 + FLOORS[f] ** 2) * math.sqrt(1 + 1 / n)
        z[f] = (x[f] - _mean(v)) / scale
    return math.sqrt(sum(z[f] ** 2 for f in FEATURES) / len(FEATURES)), z


# ---------------------------------------------------------------- judging a history

@dataclass
class Recording:
    """A night (`id` = its date) or a check-in (`id` = its file stem): when (ISO), its day, the signal or why not,
    and the owner's answer (`me`, `someone else` or None)."""

    id: str
    kind: str
    time: str
    day: str
    signal: dict[str, float] | None
    why: str | None = None
    answer: str | None = None


@dataclass
class Verdict:
    """What the check says of one recording. state: `unchecked` (why), `learning` (have of N_ENROL, days of
    MIN_DAYS), `like you` or `not like you` (distance, z, profile_n, the usual values and the biggest difference)."""

    id: str
    kind: str
    state: str
    why: str | None = None
    have: int = 0
    days: int = 0
    distance: float | None = None
    z: dict[str, float] = field(default_factory=dict)
    profile_n: int = 0
    usual: dict[str, float] = field(default_factory=dict)
    biggest: str | None = None


def judge(recordings: list[Recording]) -> list[Verdict]:
    """Every recording in time order (ties by id), each against the profile of the earlier accepted ones of its kind."""
    out = []
    accepted: dict[str, list[dict[str, float]]] = {k: [] for k in KINDS}
    days: dict[str, set[str]] = {k: set() for k in KINDS}
    for r in sorted(recordings, key=lambda r: (r.time, r.id)):
        acc, dd = accepted.setdefault(r.kind, []), days.setdefault(r.kind, set())
        if r.signal is None:
            out.append(Verdict(r.id, r.kind, "unchecked", why=r.why, have=len(acc), days=len(dd)))
            continue
        if len(acc) < N_ENROL or len(dd) < MIN_DAYS:
            out.append(Verdict(r.id, r.kind, "learning", have=len(acc), days=len(dd)))
            join = r.answer != "someone else"
        else:
            prof = acc[-PROFILE_MAX:]
            d, z = distance(prof, r.signal)
            state = "not like you" if d > THRESHOLD else "like you"
            usual = {f: _mean([p[f] for p in prof]) for f in FEATURES}
            biggest = max(FEATURES, key=lambda f: abs(z[f]))
            out.append(Verdict(r.id, r.kind, state, have=len(acc), days=len(dd), distance=d, z=z,
                               profile_n=len(prof), usual=usual, biggest=biggest))
            join = r.answer == "me" or (state == "like you" and r.answer != "someone else")
        if join:
            acc.append(r.signal)
            dd.add(r.day)
    return out


def verdict_json(v: Verdict) -> dict[str, Any]:
    """A verdict as the fixture and the phone's log hold it."""
    return {"id": v.id, "kind": v.kind, "state": v.state, "why": v.why, "have": v.have, "days": v.days,
            "distance": v.distance, "z": v.z or None, "profile_n": v.profile_n, "usual": v.usual or None,
            "biggest": v.biggest}
