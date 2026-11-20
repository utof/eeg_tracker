"""Back-test of the "Was this you?" check (`wearer_check.py`; DECISIONS rows 370-379) on made-up people, and an
optional look at the owner's own recordings (laptop only; nothing personal is written to the repository):

  uv run --project analysis python analysis/validate_wearer.py [--people 400] [--days 180] [--seed 1] [--out F]
  uv run --project analysis python analysis/validate_wearer.py --self CHECKIN.morning.json ... --night NIGHT.bdf ...

No other people's EEG is on this laptop, so the other wearers are made up the way the brief allows: the owner's
own numbers moved by a between-person spread. That spread comes from the research's test-retest numbers (ICC: the
share of all variation that is between people): alpha speed 0.84 (eyes closed, 5 years), alpha strength 0.87, the
1/f slope 0.60. With a planning between-person spread (alpha speed 0.8 Hz, alpha strength a factor of 2, i.e. 0.30
log10 units, slope 0.20) the ICCs fix each person's day-to-day spread: 0.35 Hz, 0.116 log10 units (about 30 %) and
0.16. Only the ratio of the two spreads matters for the check, so the planning values change nothing as long as the
ICCs hold. Two headbands:

- `lab`: the ICCs as published (wet lab caps, an upper bound for this headband);
- `dry`: each person's day-to-day spread 1.5 times larger (dry contacts; the ICCs fall to 0.70, 0.75 and 0.40).

Each made-up owner records once a day for `--days` days: their own value, a day-to-day wobble that partly carries
over (0.3) and has heavier tails than a bell curve (Student t, 5 degrees of freedom), and 1 day in 10 an "off" day
(late night or alcohol: alpha speed 0.5 Hz slower, alpha 25 % stronger). From day 31, every 10th recording is
someone else's (a person drawn with the between-person spread, with the same kind of wobble). The owner answers
truthfully: "it was me" to a false question, "someone else" to a right one. Reported: false questions to the owner
(share of the owner's checked recordings, and a month of daily recordings), other wearers missed, and the same for
other enrolment sizes and thresholds (the choice of rows 372-373). Prints JSON; `--out` also writes it.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wearer_check as wc  # noqa: E402

ICC_LAB = {"iaf": 0.84, "alpha": 0.87, "slope": 0.60}
BETWEEN = {"iaf": 0.8, "alpha": 0.30, "slope": 0.20}  # planning values; only the ratio to the wobble matters
MEAN = {"iaf": 10.0, "alpha": math.log10(30.0), "slope": -1.5}
CARRY = 0.3
TAIL_DF = 5.0
OFF_SHARE = 0.10
OFF_SHIFT = {"iaf": -0.5, "alpha": math.log10(1.25), "slope": 0.0}
OTHER_FROM_DAY = 30
OTHER_EVERY = 10
START = np.datetime64("2026-01-01")


def within_sd(headband: str) -> dict[str, float]:
    """Each person's day-to-day spread for a headband (`lab` or `dry`)."""
    k = 1.5 if headband == "dry" else 1.0
    return {f: k * BETWEEN[f] * math.sqrt((1 - ICC_LAB[f]) / ICC_LAB[f]) for f in wc.FEATURES}


def _wobble(rng: np.random.Generator, n: int, sd: float) -> np.ndarray:
    """A day-to-day wobble with spread sd: Student t (scaled to sd), partly carried over (AR(1))."""
    t = rng.standard_t(TAIL_DF, n) * math.sqrt((TAIL_DF - 2) / TAIL_DF)
    out = np.empty(n)
    prev = 0.0
    for i in range(n):
        prev = CARRY * prev + math.sqrt(1 - CARRY**2) * t[i]
        out[i] = prev
    return out * sd


def person_days(rng: np.random.Generator, n: int, sd: dict[str, float], centre: dict[str, float]) -> list[dict]:
    """n daily signals of one person around `centre`."""
    w = {f: _wobble(rng, n, sd[f]) for f in wc.FEATURES}
    off = rng.random(n) < OFF_SHARE
    return [{f: centre[f] + w[f][i] + (OFF_SHIFT[f] if off[i] else 0.0) for f in wc.FEATURES} for i in range(n)]


def history(rng: np.random.Generator, days: int, headband: str) -> tuple[list[wc.Recording], set[str]]:
    """A made-up owner's daily check-ins with someone else's recording every 10th day from day 31 (their ids)."""
    sd = within_sd(headband)
    owner = {f: MEAN[f] + rng.normal(0, BETWEEN[f]) for f in wc.FEATURES}
    own = person_days(rng, days, sd, owner)
    recs, others = [], set()
    for i in range(days):
        day = str(START + np.timedelta64(i, "D"))
        s = own[i]
        rid = f"d{i:04d}"
        if i >= OTHER_FROM_DAY and i % OTHER_EVERY == 0:
            centre = {f: owner[f] + rng.normal(0, math.sqrt(2) * BETWEEN[f]) for f in wc.FEATURES}
            s = person_days(rng, 1, sd, centre)[0]
            others.add(rid)
        recs.append(wc.Recording(id=rid, kind="check-in", time=f"{day}T08:00:00+03:00", day=day, signal=s))
    return recs, others


def run_owner(recs: list[wc.Recording], others: set[str]) -> list[wc.Verdict]:
    """Judges the history the way the phone would, with truthful answers to every question (one pass per question:
    an answer changes only what comes after it)."""
    by_id = {r.id: r for r in recs}
    while True:
        changed = False
        for v in wc.judge(recs):
            r = by_id[v.id]
            if v.state == "not like you" and r.answer is None:
                r.answer = "someone else" if r.id in others else "me"
                changed = True
                break
        if not changed:
            return wc.judge(recs)


def tally(verdicts: list[wc.Verdict], others: set[str]) -> dict[str, int]:
    on = [v for v in verdicts if v.state in ("like you", "not like you")]
    own = [v for v in on if v.id not in others]
    oth = [v for v in on if v.id in others]
    return {"own_checked": len(own), "own_flagged": sum(v.state == "not like you" for v in own),
            "others": len(oth), "others_caught": sum(v.state == "not like you" for v in oth),
            "others_while_learning": sum(1 for v in verdicts if v.id in others and v.state == "learning")}


def back_test(people: int, days: int, seed: int, headband: str) -> dict[str, Any]:
    rng = np.random.default_rng(seed)
    t = {"own_checked": 0, "own_flagged": 0, "others": 0, "others_caught": 0, "others_while_learning": 0}
    people_with_false = 0
    first_8_weeks = 0
    for _ in range(people):
        recs, others = history(rng, days, headband)
        v = run_owner(recs, others)
        c = tally(v, others)
        for k in t:
            t[k] += c[k]
        flagged = [x for x in v if x.state == "not like you" and x.id not in others]
        people_with_false += bool(flagged)
        first_8_weeks += any(int(x.id[1:]) < 56 for x in flagged)
    return {
        "headband": headband,
        "within_sd": {f: round(s, 3) for f, s in within_sd(headband).items()},
        "false_questions_share": round(t["own_flagged"] / t["own_checked"], 4),
        "false_questions_a_month": round(30 * t["own_flagged"] / t["own_checked"], 3),
        "people_with_a_false_question": round(people_with_false / people, 3),
        "people_with_one_in_first_8_weeks": round(first_8_weeks / people, 3),
        "others_caught": round(t["others_caught"] / t["others"], 3),
        "others_missed": round(1 - t["others_caught"] / t["others"], 3),
        "counts": t,
    }


def grid(people: int, days: int, seed: int, headband: str) -> list[dict[str, Any]]:
    """The same back-test for other enrolment sizes and thresholds (the choice of rows 372-373)."""
    rows = []
    base = (wc.N_ENROL, wc.MIN_DAYS, wc.THRESHOLD)
    try:
        for n_enrol, min_days in ((5, 2), (10, 5), (14, 7)):
            for thr in (2.0, 2.5, 3.0):
                wc.N_ENROL, wc.MIN_DAYS, wc.THRESHOLD = n_enrol, min_days, thr
                r = back_test(people, days, seed, headband)
                rows.append({"n_enrol": n_enrol, "min_days": min_days, "threshold": thr,
                             "false_questions_a_month": r["false_questions_a_month"],
                             "people_with_one_in_first_8_weeks": r["people_with_one_in_first_8_weeks"],
                             "others_caught": r["others_caught"]})
    finally:
        wc.N_ENROL, wc.MIN_DAYS, wc.THRESHOLD = base
    return rows


# ---------------------------------------------------------------- the owner's own recordings (printed only)

def self_look(mornings: list[Path], nights: list[Path]) -> dict[str, Any]:
    """The signal of each of the owner's recordings, and how far apart they are in floor units. Too few for a
    profile (8 are needed), so this only shows whether they are near each other. Night: the awake epochs of its
    first 10 minutes (laptop nights have no Lights off: the night's start stands in)."""
    out: dict[str, Any] = {"recordings": [], "halves": []}
    sigs = []
    for p in mornings:
        m = json.loads(p.read_text())
        s, why = wc.checkin_signal(m)
        out["recordings"].append({"kind": "check-in", "signal": s, "why": why})
        if s:
            sigs.append(("check-in", s))
        f32 = p.parent / str(m.get("source", ""))
        if f32.is_file():
            out["halves"].append(checkin_halves(f32))
    for p in nights:
        import pyedflib  # noqa: PLC0415

        sj = json.loads(p.with_suffix(".sleep.json").read_text())
        stages = [e["anysleep"] for e in sj["epochs"]]
        stages = [{"gap": "gap"}.get(x, x) for x in stages]
        with pyedflib.EdfReader(str(p)) as f:
            names = f.getSignalLabels()
            n = min(f.getNSamples()[0], (wc.NIGHT_WINDOW_S + 60) * wc.FS)
            o1 = f.readSignal(names.index("O1"), 0, n)
            o2 = f.readSignal(names.index("O2"), 0, n)
        s, info = wc.night_signal(o1, o2, stages, 0, missing=None)
        out["recordings"].append({"kind": "night start", "signal": s, "why": info["why"], "epochs": info["epochs"],
                                  "clean_s": info["clean_s"]})
        if s:
            sigs.append(("night start", s))
    out["pairs_in_floor_units"] = [
        {"a": a[0], "b": b[0], **{f: round(abs(a[1][f] - b[1][f]) / wc.FLOORS[f], 2) for f in wc.FEATURES}}
        for i, a in enumerate(sigs) for b in sigs[i + 1:]
    ]
    return out


def checkin_halves(f32: Path) -> dict[str, Any]:
    """The check-in's eyes-closed minutes cut in two halves (each a little under a minute, so the one-minute rule
    is not applied): how far apart the halves are, in floor units. Within one sitting: says nothing about days."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
    mc = wc.mc
    _, sess = mc.find_latest([f32], "morning")
    uv, _ = mc.load_sites(f32, mc.NAMES, "the wearer check")  # O1 O2 T3 T4 by name, whatever else the file holds
    i0, i1, _t0, _t1 = mc.morning_windows(sess)["win"]["eyes_closed"]
    a, b = i0 + int(mc.SKIP_START_S * wc.FS), min(i1 - int(mc.SKIP_END_S * wc.FS), len(uv))
    mid = (a + b) // 2
    halves = []
    for lo, hi in ((a, mid), (mid, b)):
        ch = {n: mc.channel_measures(uv[lo:hi, mc.NAMES.index(n)], None) for n in mc.BACK}
        bk = mc.back_summary(ch)
        halves.append({"iaf": bk["iaf_hz"], "alpha": math.log10(bk["alpha_ec_uv2"]), "slope": bk["aperiodic_slope_ec"]})
    return {f: round(abs(halves[0][f] - halves[1][f]) / wc.FLOORS[f], 2) for f in wc.FEATURES}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--people", type=int, default=400)
    ap.add_argument("--days", type=int, default=180)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--self", dest="mornings", nargs="*", type=Path, default=[])
    ap.add_argument("--night", dest="nights", nargs="*", type=Path, default=[])
    a = ap.parse_args(argv)
    if a.mornings or a.nights:
        json.dump(self_look(a.mornings, a.nights), sys.stdout, indent=1)
        print()
        return 0
    report = {
        "what": "made-up people (no one's data); see validate_wearer.py's docstring for the model",
        "rules": {"n_enrol": wc.N_ENROL, "min_days": wc.MIN_DAYS, "profile_max": wc.PROFILE_MAX,
                  "threshold": wc.THRESHOLD, "floors": wc.FLOORS},
        "people": a.people, "days": a.days, "seed": a.seed,
        "icc_lab": ICC_LAB, "between_sd": BETWEEN,
        "results": [back_test(a.people, a.days, a.seed, h) for h in ("lab", "dry")],
        "grid_lab": grid(a.people // 4, a.days, a.seed, "lab"),
        "grid_dry": grid(a.people // 4, a.days, a.seed, "dry"),
    }
    text = json.dumps(report, indent=1)
    print(text)
    if a.out:
        a.out.write_text(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
