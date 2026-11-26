"""eeg_tracker's numbers per day for other apps (utof_tracker first): the contract is docs/utof-interface.md, the
choices are DECISIONS rows 550-559. Standard library only; scripts/export_events.py --daily writes the events.

One number per day and measure, by the phone's own Trends rules (app/lib/trends/, work/days.dart, sharp/hours.dart,
study/store.dart): a day runs 04:00 to 04:00 local time, a night counts for the day you woke from it (the end of its
last sleep period), a check-in's number is the first of the day that has it. Read from the laptop's `_local/`:

  nights/*.report.json              the laptop's sleep reports      phone/nights/*.report.json    the phone's
  recordings/*.morning.json         the laptop's check-ins          phone/mornings/*.morning.json the phone's
  phone/sharp-hours/ratings.jsonl, reactions.jsonl, focus-*.jsonl (the laptop's focus sessions, scripts/aw_focus.py)
  phone/study-review/log.jsonl      phone/work-sessions/*.work.json
  phone/meditations/*.meditation.json, phone/alpha-theta/*.alphatheta.json
  walking/*.walk.json                the laptop's walk files (scripts/walks.py)  phone/walking/*.walk.json  the phone's
  pulse/*.pulse.json                 the laptop's (scripts/compare_pulse.py --out)  phone/pulse/*.pulse.json  the phone's

Left out, and said so in the day's `excluded` list: anything marked "someone else" (nights, check-ins, work
sessions), work and practice sessions whose mark on the recording was removed in the Archive ("mark removed"; put
back, they count again), nights scored from under 5 minutes, the sleep numbers of a night more than half of whose time asleep was
noisy or missing, the headband numbers of a check-in with under half its signal clean, and the work numbers of a day
with under 30 readable minutes. A day's time is the timestamp's own UTC offset (the phone's local time then).
Walking (DECISIONS 800-809) uses the minute rules of analysis/walk_minutes.py (standard library only, shared with the
detector's reference): every clock minute once, minutes inside a night someone else wore the headband for left out.
"""
from __future__ import annotations

import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "analysis"))
import walk_minutes as wm  # noqa: E402  (standard library only)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spans  # noqa: E402  (a session whose mark was removed counts nowhere)

SCHEMA = 1  # of the eeg_day event (docs/utof-interface.md)
MEASURES_VERSION = 4  # of the measure list below (2: sleep efficiency, sleep regularity, the sleep rating,
#                       DECISIONS 658; 3: walking and estimated steps, DECISIONS 800-809; 4: pulse while asleep,
#                       DECISIONS 817)
DAY_START_HOUR = 4
SOMEONE_ELSE = "someone else"
MARK_REMOVED = "mark removed"  # the session's mark on its recording was taken away in the Archive
NOISY_NIGHT_SHARE = 0.5  # planning value (DECISIONS 553): more of the time asleep noisy or missing than this
CLEAN_CHECKIN_SHARE = 0.5  # planning value (DECISIONS 553): less of a check-in's signal kept than this
EFFICIENCY_MIN_IN_BED = 30  # sleep_days.dart efficiencyMinInBedMin (DECISIONS 654): shorter stays say nothing
REGULARITY_DAYS, REGULARITY_MIN_NIGHTS = 7, 5  # sleep_days.dart (DECISIONS 655)
REGULARITY_CAP_MIN = 720.0
PULSE_FORMAT, PULSE_VERSION = "eeg-tracker-pulse", 1  # docs/data-format.md "Pulse"
PULSE_MIN_READINGS = 10  # pulse/detector.dart PulseRule.minNightReadings (DECISIONS 816-817): 5 minutes asleep
ASLEEP_CHARS = "123R"  # a report's `stages` letters for N1 N2 N3 REM
WORK_DAY_MIN_MINUTES = 30  # work/days.dart workDayMinMinutes (DECISIONS 481)
BREAK_MIN, RECENT_EPOCHS, DROWSY_EPOCHS = 5, 12, 8  # work/breaks.dart BreakRule
MORNING_VERSION = "morning-v1"

# Every measure: id (the phone's Trends id where it has one), label, unit, group, when it is about, where it comes
# from, the evidence note and its grade for this headband (docs/evidence/; null = not a headband measure: your own
# rating, a tap test or a laptop count, the note's grade is about the feature), how the day's number is made.
# Status is "seen together" for every one: a number here is only placed next to other things; "tested" needs a
# randomised self-experiment, whose answers are not exported yet (DECISIONS 554).
_M = [
    # id, label, unit, group, about, source, note, grade, rule
    ("asleep", "Asleep", "min", "sleep", "night before", "headband", "sleep-scoring", "some",
     "minutes asleep inside the sleep periods, all the nights that ended that day"),
    ("deep", "Deep sleep (N3)", "min", "sleep", "night before", "headband", "sleep-scoring", "weak",
     "N3 minutes of the same nights; the five-stage detail is the weak part of the sleep model"),
    ("dream", "Dream sleep (REM)", "min", "sleep", "night before", "headband", "sleep-scoring", "some",
     "REM minutes of the same nights"),
    ("light", "Light sleep (N1 + N2)", "min", "sleep", "night before", "headband", "sleep-scoring", "weak",
     "N1 and N2 minutes of the same nights"),
    ("awake_in_sleep", "Awake inside sleep", "min", "sleep", "night before", "headband", "sleep-scoring", "some",
     "minutes scored awake inside the sleep periods"),
    ("wakeups", "Wake-ups", "count", "sleep", "night before", "headband", "sleep-scoring", "some",
     "awake stretches of over 5 minutes inside the sleep periods"),
    ("fall_asleep", "Falling asleep", "min", "sleep", "night before", "headband", "sleep-scoring", "some",
     "minutes from lights off (a tap or a marker, not the recording's start) to the sleep model's onset; first night"),
    ("efficiency", "Sleep efficiency", "%", "sleep", "night before", "headband", "sleep-scoring", "weak",
     "minutes asleep over the minutes from Lights off (a tap or a marker; else the recording's start) to the last "
     "wake-up, all the day's nights together, at most 100; nights under 30 minutes in bed are left out"),
    ("regularity", "Sleep regularity", "min", "sleep", "night before", "headband", "sleep-scoring", "weak",
     "how far the first-sleep times and the last wake-up times of the last 7 days moved: each a circular standard "
     "deviation of the time of day, the two averaged; needs 5 nights in the 7; smaller is steadier"),
    ("jaw", "Jaw muscle bursts", "per hour asleep", "sleep", "night before", "headband", "jaw-and-blinks", "strong",
     "bursts an hour asleep; a trend to compare nights, not a test for teeth grinding"),
    ("pulse", "Pulse while asleep", "per minute", "sleep", "night before", "headband", "pulse", "weak",
     "the median of the pulse readings in the asleep 30 s epochs of the day's nights (the pulse files of the phone or "
     "the laptop, read on each report's clock), from 10 readings; an experiment, not yet checked against a watch"),
    ("kss", "Sleepiness (check-in)", "1-9", "morning", "morning", "self-report", "morning-check-in", None,
     "Karolinska Sleepiness Scale at the day's first check-in"),
    ("mood", "Mood (check-in)", "1-5", "morning", "morning", "self-report", "morning-check-in", None,
     "1 very bad to 5 very good, at the day's first check-in"),
    ("tension", "Tension (check-in)", "1-5", "morning", "morning", "self-report", "morning-check-in", None,
     "1 none to 5 very much, at the day's first check-in"),
    ("slept", "How you slept (check-in)", "1-5", "morning", "morning", "self-report", "morning-check-in", None,
     "the optional tap \"How did you sleep?\", 1 very badly to 5 very well, at the day's first check-in that has it"),
    ("reaction", "Reaction time (check-in)", "ms", "morning", "morning", "tap test", "morning-check-in", None,
     "median of the 1-minute tap test at the check-in"),
    ("iaf", "Alpha speed", "Hz", "morning", "morning", "headband", "morning-check-in", "strong",
     "eyes closed, back of the head; it does not tell tiredness"),
    ("alpha", "Alpha strength", "uV2", "morning", "morning", "headband", "morning-check-in", "strong",
     "eyes-closed alpha power, back of the head"),
    ("rise", "Eyes-closed rise", "ratio", "morning", "morning", "headband", "morning-check-in", "strong",
     "alpha eyes closed over eyes open"),
    ("caffeine", "Caffeine the day before", "cups", "morning", "day before", "self-report", "morning-check-in", None,
     "cups of coffee, strong tea or energy drinks the day before, 5 = 5 or more, asked at the check-in"),
    ("alcohol", "Alcohol the day before", "drinks", "morning", "day before", "self-report", "morning-check-in", None,
     "drinks the day before, 5 = 5 or more, asked at the check-in"),
    ("sharp", "Sharpness in the day", "1-5", "day", "day", "self-report", "sharp-hours", None,
     "mean of the day's sharp-hours ratings (1 foggy to 5 very sharp)"),
    ("dayrt", "Reaction time in the day", "ms", "day", "day", "tap test", "sharp-hours", None,
     "median of the day's sharp-hours tap tests"),
    ("recall", "Recall of what you studied", "1-3", "day", "day", "self-report", "study-timing", None,
     "mean of the day's morning answers: 1 a little, 2 some, 3 well"),
    ("focus", "Focus sessions on the laptop", "count", "day", "day", "laptop", "break-hints", None,
     "35+ active minutes in one family of windows (ActivityWatch, scripts/aw_focus.py); no line = laptop off"),
    ("worktime", "Work with a signal", "min", "work", "day", "headband", "work-session", "some",
     "work-session minutes the drowsiness level could be read: no breaks, noise or closed eyes"),
    ("workdrowsy", "Work time drowsy", "%", "work", "day", "headband", "work-session", "some",
     "share of that time read as getting drowsy or drowsy"),
    ("workfirst", "Work until first drowsy stretch", "min", "work", "day", "headband", "work-session", "some",
     "worked minutes until 8 of 12 half minutes read drowsy; only days with one"),
    ("workhints", "Break hints shown", "count", "work", "day", "app", "break-hints", None,
     "break hints shown in work sessions"),
    ("workfollowed", "Hints followed by a break", "count", "work", "day", "app", "break-hints", None,
     "a break of 5+ minutes within 30 minutes of the hint"),
    ("workbreaks", "Work breaks", "count", "work", "day", "app", "break-hints", None,
     "breaks of 5+ minutes, tapped or the headband off"),
    ("worksharp", "Sharpness at work", "1-5", "work", "day", "self-report", "work-session", None,
     "mean of the 'how sharp' taps in work sessions"),
    ("practice", "Practice", "min", "practice", "day", "headband", "meditation-feedback", "weak",
     "meditation and alpha-theta minutes with a signal"),
    ("settled", "Settled in meditation", "%", "practice", "day", "headband", "meditation-feedback", "weak",
     "share of the day's meditation time read as settled"),
    ("walk_min", "Walking", "min", "activity", "day", "headband", "walking", "weak",
     "minutes of steady walking or running in the headband's step rhythm while it recorded (stretches of 30 s or "
     "more), and minutes the phone's step counter counted 60 steps or more; slow strolls and short walks are missed"),
    ("walk_steps", "Steps (estimated)", "count", "activity", "day", "headband", "walking", "weak",
     "steps while the headband recorded: the phone's step counter where it counted, else estimated from the "
     "headband's pace; the headband's estimate is left out once its pace failed the check against the phone "
     "(eeg_day.walking says the source and the check)"),
]
MEASURES = [dict(id=m[0], label=m[1], unit=m[2], group=m[3], about=m[4], source=m[5],
                 evidence_note=f"docs/evidence/{m[6]}.md", evidence=m[7], status="seen together", rule=m[8])
            for m in _M]
MEASURE_IDS = [m["id"] for m in MEASURES]
WORK_IDS = ["worktime", "workdrowsy", "workfirst", "workhints", "workfollowed", "workbreaks", "worksharp"]


def measure_set() -> dict:
    """The data of the `eeg_measure_set` event: what each number of `eeg_day` is."""
    return dict(
        version=MEASURES_VERSION, measures=MEASURES,
        day_rule="a day runs 04:00 to 04:00 local time; a night counts for the day you woke from it",
        status_rule="'seen together': placed next to other things, never shown to cause them; 'tested' only "
                    "for a randomised self-experiment's answer (none exported yet)",
        grades="strong | some | weak | none: how well the evidence supports the measure for this headband "
               "(BrainBit Black, O1 O2 T3 T4); null = not a headband measure (see source)")


# ---------------------------------------------------------------------------------------------------------- reading

def parse_time(v: object) -> datetime | None:
    """An ISO time with its own offset; a time without one is taken as this computer's local time."""
    if not isinstance(v, str):
        return None
    try:
        t = datetime.fromisoformat(v)
    except ValueError:
        return None
    return t if t.tzinfo else t.astimezone()


def day_key(t: datetime) -> str:
    """The 04:00-04:00 day `t` belongs to, on its own wall clock."""
    return (t - timedelta(hours=DAY_START_HOUR)).date().isoformat()


def _json(f: Path) -> object:
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def _lines(f: Path) -> list[object]:
    """Complete JSON lines of a file (a last line without a newline may be mid-write: left out)."""
    try:
        text = f.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    out = []
    for ln in text.splitlines(keepends=True):
        if not ln.endswith("\n") or not ln.strip():
            continue
        try:
            out.append(json.loads(ln))
        except ValueError:
            continue
    return out


def _num(v: object) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf") \
        else None


def _int_in(v: object, lo: int, hi: int) -> int | None:
    return v if isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi else None


def _wearer(j: dict) -> str | None:
    w = j.get("wearer")
    return w.get("answer") if isinstance(w, dict) and isinstance(w.get("answer"), str) else None


def read_reports(local: Path) -> list[dict]:
    """One sleep report per night (`night_of`): the laptop's when both exist (the reference scorer, with the second
    model), else the phone's. Damaged or foreign files are skipped, as the phone's `SleepReport.read` does. Each gets
    `_origin` (`laptop` / `phone`), `_file` and `_wearer` (an answer in either copy; "someone else" wins)."""
    found: dict[str, dict] = {}
    answers: dict[str, set] = defaultdict(set)
    for origin, folder in (("laptop", local / "nights"), ("phone", local / "phone" / "nights")):
        for f in sorted(folder.glob("*.report.json")):
            r = _json(f)
            if not (isinstance(r, dict) and isinstance(r.get("night_of"), str) and isinstance(r.get("total"), dict)
                    and isinstance(r.get("periods"), list) and parse_time(r.get("data_start"))
                    and parse_time(r.get("data_end"))):
                continue
            if _wearer(r):
                answers[r["night_of"]].add(_wearer(r))
            if r["night_of"] not in found:
                found[r["night_of"]] = dict(r, _origin=origin, _file=f)
    for night, r in found.items():
        a = answers.get(night, set())
        r["_wearer"] = SOMEONE_ELSE if SOMEONE_ELSE in a else (next(iter(a)) if a else None)
    return [found[k] for k in sorted(found)]


def final_wake(r: dict) -> datetime:
    """The end of the night's last sleep period, else its data end (trends.dart `finalWake`)."""
    ends = [parse_time(p.get("end")) for p in r["periods"] if isinstance(p, dict)]
    ends = [e for e in ends if e]
    return max(ends) if ends else parse_time(r["data_end"])


def read_mornings(local: Path) -> list[dict]:
    """Check-in results (`morning-v1` with a `back`), the phone's first, one per start; `_origin`, `_file`."""
    out: dict[str, dict] = {}
    for origin, folder in (("phone", local / "phone" / "mornings"), ("laptop", local / "recordings")):
        for f in sorted(folder.glob("*.morning.json")):
            j = _json(f)
            if not (isinstance(j, dict) and j.get("version") == MORNING_VERSION and isinstance(j.get("back"), dict)):
                continue
            t = parse_time(j.get("start"))
            if t is None:
                continue
            out.setdefault(t.isoformat(), dict(j, _origin=origin, _file=f, _start=t))
    return sorted(out.values(), key=lambda j: j["_start"])


# ---------------------------------------------------------------------------------------------------------- the days

class Days:
    """day -> numbers, counts, quality, exclusions, sources."""

    def __init__(self) -> None:
        self.numbers: dict[str, dict[str, float]] = defaultdict(dict)
        self.counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self.quality: dict[str, dict[str, float]] = defaultdict(dict)
        self.excluded: dict[str, list[dict]] = defaultdict(list)
        self.sources: dict[str, set] = defaultdict(set)
        self.walking: dict[str, dict] = {}

    def add(self, day: str, mid: str, v: float) -> None:
        self.numbers[day][mid] = self.numbers[day].get(mid, 0.0) + v

    def first(self, day: str, mid: str, v: float | None) -> None:
        if v is not None:
            self.numbers[day].setdefault(mid, v)

    def all_days(self) -> list[str]:
        return sorted(set(self.numbers) | set(self.excluded) | set(self.counts))


def _nights(days: Days, local: Path) -> None:
    jaw: dict[str, list[tuple[float, float, float | None]]] = defaultdict(list)  # day -> (bursts, min, per hour)
    noise: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])  # day -> noisy or missing min, min asleep
    stays: dict[str, list[tuple[datetime, float, float, float, float]]] = defaultdict(list)  # day -> see _timing
    pulse: dict[str, dict[tuple[str, int], float]] = defaultdict(dict)  # day -> (night, epoch) -> reading asleep
    pulses = read_pulses(local)
    for r in read_reports(local):
        day, night = day_key(final_wake(r)), r["night_of"]
        if r["_wearer"] == SOMEONE_ELSE:
            days.excluded[day].append(dict(what="night", id=night, why=SOMEONE_ELSE))
            continue
        if r.get("scored") is not True:
            days.excluded[day].append(dict(what="night", id=night, why="unscored: under 5 minutes recorded"))
            continue
        if r.get("no_sleep_found") is True:  # trends.dart: a stretch the app started with under 10 min asleep (DECISIONS 1132)
            days.excluded[day].append(dict(what="night", id=night, why="no sleep found"))
            continue
        t = r["total"]
        extras = r.get("extras") if isinstance(r.get("extras"), dict) else None
        asleep_x = extras.get("asleep") if extras and isinstance(extras.get("asleep"), dict) else None
        if asleep_x and _num(asleep_x.get("min")):
            bad = (_num(asleep_x.get("degraded_min")) or 0) + (_num(asleep_x.get("missing_min")) or 0)
            noisy = bad / _num(asleep_x["min"])
            noise[day][0] += bad
            noise[day][1] += _num(asleep_x["min"])
            if noisy > NOISY_NIGHT_SHARE:
                days.excluded[day].append(dict(what="night", id=night, why="noisy", noisy_share=round(noisy, 3)))
                continue
        days.counts[day]["nights"] += 1
        days.sources[day].add(r["_origin"])
        for mid, key in (("asleep", "asleep_min"), ("deep", "deep_min"), ("dream", "dream_min"),
                         ("light", "light_min"), ("wakeups", "wake_ups")):
            v = _num(t.get(key))
            if v is not None:
                days.add(day, mid, v)
        awake = [_num(p.get("awake_min")) for p in r["periods"] if isinstance(p, dict)]
        days.add(day, "awake_in_sleep", sum(a for a in awake if a is not None))
        drift = r.get("drift_off") if isinstance(r.get("drift_off"), dict) else None
        if drift and drift.get("source") != "night start":
            days.first(day, "fall_asleep", _num(drift.get("model_onset_min")))
        stay = _timing(r, drift)
        if stay:
            stays[day].append(stay)
        for e, b in _pulse_asleep(r, pulses).items():
            pulse[day][(night, e)] = b
        if asleep_x and _num(asleep_x.get("jaw_per_hour")) is not None and (_num(asleep_x.get("min")) or 0) > 0:
            jaw[day].append((_num(asleep_x.get("jaw_bursts")) or 0.0, _num(asleep_x["min"]),
                             _num(asleep_x["jaw_per_hour"])))
    _efficiency_and_regularity(days, stays)
    for day, (bad, total) in noise.items():  # over the day's scored nights, the noisy ones too
        days.quality[day]["night_noisy_share"] = round(bad / total, 3)
    for day, v in pulse.items():  # pulse/night.dart pulseDayNumbers: every reading asleep of the day's nights
        if len(v) >= PULSE_MIN_READINGS:
            days.numbers[day]["pulse"] = round(_median(list(v.values())) * 10) / 10
    for day, a in jaw.items():  # trends.dart: the night's own number, or over all the day's hours asleep
        days.numbers[day]["jaw"] = a[0][2] if len(a) == 1 else \
            round(sum(x[0] for x in a) / (sum(x[1] for x in a) / 60) * 10) / 10


def read_pulses(local: Path) -> list[dict]:
    """The pulse files (docs/data-format.md "Pulse"): the laptop's (`pulse/`) and the phone's (`phone/pulse/`), those
    with readings; others are skipped."""
    out = []
    for folder in (local / "pulse", local / "phone" / "pulse"):
        for f in sorted(folder.glob("*.pulse.json")):
            j = _json(f)
            if isinstance(j, dict) and j.get("format") == PULSE_FORMAT and j.get("version") == PULSE_VERSION \
                    and isinstance(j.get("start_ms"), int) and isinstance(j.get("bpm"), list):
                out.append(j)
    return out


def _night_stages(r: dict) -> tuple[float, str] | None:
    """(unix seconds of the first epoch, one letter per 30 s: W 1 2 3 R -) of a report: the phone's `stages`, or the
    laptop's sleep.json beside it."""
    if isinstance(r.get("stages"), str):
        return parse_time(r["data_start"]).timestamp(), r["stages"]
    side = r["_file"].parent / str(r.get("sleep_json") or "")
    if r.get("sleep_json") and side.is_file():
        j = _json(side)
        if isinstance(j, dict) and isinstance(j.get("epochs"), list) and isinstance(j.get("start"), str):
            letters = {"W": "W", "N1": "1", "N2": "2", "N3": "3", "R": "R"}
            st = "".join(letters.get(str(e.get("anysleep")), "-") for e in j["epochs"] if isinstance(e, dict))
            start = parse_time(j["start"])
            if start is not None:
                return start.timestamp(), st
    return None


def _pulse_asleep(r: dict, pulses: list[dict]) -> dict[int, float]:
    """A night's pulse readings in its asleep epochs, by epoch of its own clock: each reading goes to the epoch holding
    its middle (pulse/detector.dart pulseAligned); the first file with a reading for an epoch wins."""
    stages = _night_stages(r)
    if stages is None:
        return {}
    t0, st = stages
    out: dict[int, float] = {}
    for p in pulses:
        ep = _num(p.get("epoch_s")) or 30.0
        start = p["start_ms"] / 1000
        for j, b in enumerate(p["bpm"]):
            v = _num(b)
            if v is None:
                continue
            e = math.floor((start + j * ep + ep / 2 - t0) / 30)
            if 0 <= e < len(st) and st[e] in ASLEEP_CHARS:
                out.setdefault(e, v)
    return out


def _minute_of_day(t: datetime) -> float:
    return t.hour * 60.0 + t.minute + t.second / 60


def _timing(r: dict, drift: dict | None) -> tuple[datetime, float, float, float, float] | None:
    """(data start, minutes asleep, minutes in bed, first-sleep minute of the day, last-wake minute of the day) of a
    counted night, or None without a sleep period. Time in bed runs from Lights off (a tap or a marker, not the night
    start) else from the recording's start, but never from after the first sleep, to the last wake-up (sleep_days.dart
    `_Night`, DECISIONS 654). Clock times are the timestamps' own wall clock."""
    spans = [(parse_time(p.get("start")), parse_time(p.get("end")), _num(p.get("asleep_min")))
             for p in r["periods"] if isinstance(p, dict)]
    spans = [(a, b, m) for a, b, m in spans if a and b and m is not None]
    if not spans:
        return None
    onset, wake = min(a for a, _, _ in spans), max(b for _, b, _ in spans)
    tapped = parse_time(drift.get("lights_off")) if drift and drift.get("source") != "night start" else None
    begin = min(tapped or parse_time(r["data_start"]), onset)
    in_bed = (wake - begin).total_seconds() / 60
    return parse_time(r["data_start"]), sum(m for _, _, m in spans), in_bed, _minute_of_day(onset), _minute_of_day(wake)


def circular_spread(minutes: list[float]) -> float:
    """The standard deviation of times of day as a circle (23:50 and 00:10 are 20 minutes apart): sqrt(-2 ln R) of
    the times as unit arrows, in minutes, at most 12 hours (sleep_days.dart `circularSpreadMin`)."""
    if len(minutes) < 2:
        return 0.0
    c = sum(math.cos(m * math.pi / 720) for m in minutes)
    s = sum(math.sin(m * math.pi / 720) for m in minutes)
    r = math.hypot(c, s) / len(minutes)
    if r < 1e-9:
        return REGULARITY_CAP_MIN
    return min(REGULARITY_CAP_MIN, math.sqrt(-2 * math.log(min(1.0, r))) * 720 / math.pi)


def _efficiency_and_regularity(days: Days, stays: dict[str, list[tuple[datetime, float, float, float, float]]]) -> None:
    for day, nights in stays.items():
        nights.sort(key=lambda n: n[0])
        long = [n for n in nights if n[2] >= EFFICIENCY_MIN_IN_BED]
        if long:
            days.numbers[day]["efficiency"] = min(100.0, sum(n[1] for n in long) / sum(n[2] for n in long) * 100)
    for day in sorted(stays):
        window = [k for k in sorted(stays) if k <= day and
                  (datetime.fromisoformat(day) - datetime.fromisoformat(k)).days < REGULARITY_DAYS]
        if len(window) >= REGULARITY_MIN_NIGHTS:  # a day with two sleeps counts once: its first sleep, its last wake
            days.numbers[day]["regularity"] = (circular_spread([stays[k][0][3] for k in window])
                                               + circular_spread([stays[k][-1][4] for k in window])) / 2


def _mornings(days: Days, local: Path) -> None:
    for m in read_mornings(local):
        day, stem = day_key(m["_start"]), m["_file"].name.removesuffix(".morning.json")
        if _wearer(m) == SOMEONE_ELSE:
            days.excluded[day].append(dict(what="check-in", id=stem, why=SOMEONE_ELSE))
            continue
        days.counts[day]["checkins"] += 1
        days.sources[day].add(m["_origin"])
        ratings = m.get("ratings") if isinstance(m.get("ratings"), dict) else {}
        habits = m.get("habits") if isinstance(m.get("habits"), dict) else {}
        reaction = m.get("reaction") if isinstance(m.get("reaction"), dict) else {}
        for mid, v in (("kss", _int_in(ratings.get("kss"), 1, 9)), ("mood", _int_in(ratings.get("mood"), 1, 5)),
                       ("tension", _int_in(ratings.get("tension"), 1, 5)), ("slept", _int_in(ratings.get("sleep"), 1, 5)),
                       ("reaction", _num(reaction.get("median_ms"))),
                       ("caffeine", _int_in(habits.get("caffeine_cups"), 0, 5)),
                       ("alcohol", _int_in(habits.get("alcohol_drinks"), 0, 5))):
            days.first(day, mid, None if v is None else float(v))
        b = m["back"]
        clean = _num(b.get("clean_share"))
        if clean is not None:
            days.quality[day].setdefault("checkin_clean_share", round(clean, 3))
        if clean is not None and clean < CLEAN_CHECKIN_SHARE:
            days.excluded[day].append(dict(what="check-in", id=stem, why="noisy: headband numbers left out",
                                           clean_share=round(clean, 3)))
            continue
        for mid, key in (("iaf", "iaf_hz"), ("alpha", "alpha_ec_uv2"), ("rise", "ec_rise")):
            days.first(day, mid, _num(b.get(key)))


def _median(v: list[float]) -> float:
    s = sorted(v)
    n = len(s)
    return float(s[n // 2]) if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def _sharp(days: Days, local: Path) -> None:
    folder = local / "phone" / "sharp-hours"
    by_day: dict[str, list[int]] = defaultdict(list)
    for j in _lines(folder / "ratings.jsonl"):
        if not (isinstance(j, dict) and j.get("version") == 1 and j.get("scale") == "1-5"):
            continue
        at, v = parse_time(j.get("at")), _int_in(j.get("sharp"), 1, 5)
        if at and v is not None:
            by_day[day_key(at)].append(v)
    rt: dict[str, list[float]] = defaultdict(list)
    for j in _lines(folder / "reactions.jsonl"):
        if not (isinstance(j, dict) and j.get("version") == 1):
            continue
        at, times = parse_time(j.get("rating_at")), j.get("times_ms")
        if not at or not parse_time(j.get("at")) or _int_in(j.get("false_starts"), 0, 10**6) is None \
                or _int_in(j.get("length_s"), 1, 10**6) is None or not isinstance(times, list) \
                or any(_int_in(x, 100, 1500) is None for x in times):
            continue  # sharp/store.dart `SharpReaction.fromJson` refuses the whole line
        if len(times) >= 5:  # the test's own rule; sharp/store.dart `_medianInt` rounds an even middle
            s = sorted(times)
            n = len(s)
            rt[day_key(at)].append(s[n // 2] if n % 2 else round((s[n // 2 - 1] + s[n // 2]) / 2 + 1e-9))
    for day, v in by_day.items():
        days.numbers[day]["sharp"] = sum(v) / len(v)
        days.counts[day]["sharp_ratings"] = len(v)
        days.sources[day].add("phone")
    for day, v in rt.items():
        days.numbers[day]["dayrt"] = _median(v)
        days.counts[day]["sharp_tests"] = len(v)
        days.sources[day].add("phone")
    for f in sorted(folder.glob("focus-*.jsonl")):
        for j in _lines(f):
            if isinstance(j, dict) and j.get("version") == 1 and isinstance(j.get("day"), str) \
                    and _int_in(j.get("sessions"), 0, 10_000) is not None:
                days.numbers[j["day"]]["focus"] = float(j["sessions"])
                days.sources[j["day"]].add("laptop")


def _study(days: Days, local: Path) -> None:
    by_day: dict[str, list[int]] = defaultdict(list)
    for j in _lines(local / "phone" / "study-review" / "log.jsonl"):
        if not (isinstance(j, dict) and j.get("version") == 1 and j.get("kind") == "morning"):
            continue
        at, v = parse_time(j.get("at")), {"little": 1, "some": 2, "well": 3}.get(j.get("recall"))
        if at and v:
            by_day[day_key(at)].append(v)
    for day, v in by_day.items():
        days.numbers[day]["recall"] = sum(v) / len(v)
        days.sources[day].add("phone")


def _epoch_time(e: dict, start: datetime) -> datetime | None:
    t = parse_time(e.get("at")) or parse_time(e.get("t"))
    if t:
        return t
    s = _num(e.get("s"))
    return start + timedelta(seconds=round(s)) if s is not None else None


def _work(days: Days, local: Path) -> None:
    """work/days.dart `workDayNumbers`, line by line."""
    sessions = []
    taken = spans.taken_ids(local)
    for f in sorted((local / "phone" / "work-sessions").glob("*.work.json")):
        j = _json(f)
        start = parse_time(j.get("start")) if isinstance(j, dict) and j.get("kind") == "work_session" else None
        if start is None:
            continue
        if spans.mark_taken(j, taken):  # as work/store.dart leaves it out of its lists (DECISIONS 1042, 1080)
            days.excluded[day_key(start)].append(dict(what="work session", id=f.name.removesuffix(".work.json"),
                                                      why=MARK_REMOVED))
            continue
        if _wearer(j) == SOMEONE_ELSE:
            days.excluded[day_key(start)].append(dict(what="work session", id=f.name.removesuffix(".work.json"),
                                                      why=SOMEONE_ELSE))
            continue
        sessions.append((start, j))
    sessions.sort(key=lambda s: s[0])
    acc: dict[str, dict] = {}

    def day(t: datetime) -> dict:
        return acc.setdefault(day_key(t), dict(usable=0, drowsy=0, hints=0, followed=0, breaks=0, first=None,
                                               taps=[], sessions=set()))
    read, up = {"alert", "getting_drowsy", "drowsy"}, {"getting_drowsy", "drowsy"}
    for start, j in sessions:
        end = parse_time(j.get("end")) or start
        brk = []
        for b in j.get("breaks") if isinstance(j.get("breaks"), list) else []:
            frm = parse_time(b.get("start")) if isinstance(b, dict) else None
            if frm is None:
                continue
            to = parse_time(b.get("end")) or end
            brk.append((frm, to))
            if (to - frm).total_seconds() >= BREAK_MIN * 60:
                day(frm)["breaks"] += 1
        recent: list[bool] = []
        for e in j.get("epochs") if isinstance(j.get("epochs"), list) else []:
            if not isinstance(e, dict) or not isinstance(e.get("level"), str) or \
                    (e["level"] not in read and e["level"] != "unknown"):
                continue
            t = _epoch_time(e, start)
            if t is None or any(a <= t < b for a, b in brk):
                continue
            d = day(t)
            d["sessions"].add(start)
            if e["level"] in read and e.get("eyes_closed") is not True:
                d["usable"] += 1
                d["drowsy"] += e["level"] in up
            recent.append(e["level"] in up)
            if len(recent) > RECENT_EPOCHS:
                recent.pop(0)
            if d["first"] is None and sum(recent) >= DROWSY_EPOCHS:
                d["first"] = d["usable"] / 2
        for h in j.get("hints") if isinstance(j.get("hints"), list) else []:
            at = parse_time(h.get("at")) if isinstance(h, dict) else None
            if at:
                d = day(at)
                d["hints"] += 1
                d["followed"] += h.get("taken") is True
        for r in j.get("ratings") if isinstance(j.get("ratings"), list) else []:
            at = parse_time(r.get("at")) if isinstance(r, dict) else None
            v = _int_in(r.get("value"), 1, 5) if isinstance(r, dict) else None
            if at and v is not None:
                day(at)["taps"].append(v)
    for k, d in acc.items():
        if d["usable"] < WORK_DAY_MIN_MINUTES * 2:
            if d["sessions"]:
                days.excluded[k].append(dict(what="work", why=f"under {WORK_DAY_MIN_MINUTES} readable minutes",
                                             minutes=d["usable"] / 2))
            continue
        n = days.numbers[k]
        n["worktime"], n["workdrowsy"] = d["usable"] / 2, d["drowsy"] / d["usable"] * 100
        if d["first"] is not None:
            n["workfirst"] = d["first"]
        n["workhints"], n["workfollowed"], n["workbreaks"] = float(d["hints"]), float(d["followed"]), \
            float(d["breaks"])
        if d["taps"]:
            n["worksharp"] = sum(d["taps"]) / len(d["taps"])
        days.counts[k]["work_sessions"] = len(d["sessions"])
        days.sources[k].add("phone")


def _practice(days: Days, local: Path) -> None:
    settled: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0])
    taken = spans.taken_ids(local)
    for folder, suffix, kind in (("meditations", ".meditation.json", "meditation"),
                                 ("alpha-theta", ".alphatheta.json", "alpha-theta")):
        for f in sorted((local / "phone" / folder).glob("*" + suffix)):
            j = _json(f)
            if not (isinstance(j, dict) and j.get("version") == 1 and j.get("kind") == kind):
                continue
            start, run, sett = parse_time(j.get("start")), _num(j.get("runS")), _num(j.get("settledS"))
            if start is None or run is None or run <= 0 or sett is None or sett < 0 or sett > run + 0.05:
                continue
            day = day_key(start)
            if spans.mark_taken(j, taken):  # as meditation/store.dart leaves it out (DECISIONS 1042, 1080)
                days.excluded[day].append(dict(what=kind, id=f.name.removesuffix(suffix), why=MARK_REMOVED))
                continue
            days.add(day, "practice", run / 60)
            days.counts[day]["practice_sessions"] += 1
            days.sources[day].add("phone")
            if kind == "meditation":
                settled[day][0] += sett
                settled[day][1] += run
    for day, (s, r) in settled.items():
        days.numbers[day]["settled"] = s / r * 100


def read_walks(local: Path) -> list[dict]:
    """The walk files (docs/data-format.md "Walking"): the laptop's (`walking/`, scripts/walks.py) and the phone's
    (`phone/walking/`); each gets `_origin`. Files of another format or version, or with no minutes, are skipped."""
    out = []
    for origin, folder in (("laptop", local / "walking"), ("phone", local / "phone" / "walking")):
        for f in sorted(folder.glob("*.walk.json")):
            j = _json(f)
            if isinstance(j, dict) and j.get("format") == wm.WALK_FORMAT and j.get("version") == wm.WALK_VERSION \
                    and isinstance(j.get("minutes"), list) and isinstance(j.get("walks"), list):
                out.append(dict(j, _origin=origin))
    return out


def _walk_entry(w: dict, file: dict, rows: list[wm.Minute]) -> dict | None:
    """One walk for `eeg_day.walking.walks`: the file's walk with the steps counted in its minutes."""
    a, b = parse_time(w.get("start")), parse_time(w.get("end"))
    if a is None or b is None:
        return None
    inside = [m for m in rows if a.timestamp() - 60 < m.t < b.timestamp()]
    phone = sum(m.steps for m in inside if m.source == "phone")
    head = sum(m.steps for m in inside if m.source == "headband")
    keys = ("start", "end", "walking_min", "stopped_min", "stops", "pace")
    return dict({k: w.get(k) for k in keys}, recording=file.get("recording"), origin=file["_origin"],
                headband_steps=w.get("steps"), steps_phone=round(phone), steps_headband=round(head),
                stretches=[{k: s.get(k) for k in ("kind", "start", "end", "min", "steps", "pace", "confidence")}
                           for s in w.get("stretches") or [] if isinstance(s, dict)])


def _walking(days: Days, local: Path) -> None:
    files = read_walks(local)
    if not files:
        return
    not_mine = []
    for r in read_reports(local):
        if r["_wearer"] == SOMEONE_ELSE:
            not_mine.append((parse_time(r["data_start"]).timestamp(), parse_time(r["data_end"]).timestamp()))
    rows = wm.unique_minutes(files, not_mine)
    wd = wm.walk_days(rows)
    hidden = wd.check.status == "failed"
    taken: list[tuple[float, float]] = []
    walks: dict[str, list[dict]] = defaultdict(list)
    for f in sorted(files, key=lambda w: (-int(w.get("windows") or 0), str(w.get("recording")))):
        for w in f["walks"]:
            e = _walk_entry(w, f, rows) if isinstance(w, dict) else None
            if e is None:
                continue
            a, b = parse_time(e["start"]).timestamp(), parse_time(e["end"]).timestamp()
            if any(x < b and a < y for x, y in taken) or any(x <= a < y for x, y in not_mine):
                continue
            taken.append((a, b))
            e["steps"] = e["steps_phone"] + (0 if hidden else e["steps_headband"])
            walks[wm.day_of(int(a))].append(e)
    for d in sorted(set(wd.minutes) | set(wd.steps)):
        if d in wd.minutes:
            days.numbers[d]["walk_min"] = wd.minutes[d]
        if d in wd.steps:
            days.numbers[d]["walk_steps"] = wd.steps[d]
        days.walking[d] = dict(
            minutes=round(wd.minutes.get(d, 0.0), 1), steps=round(wd.steps.get(d, 0.0)),
            steps_phone=round(wd.phone.get(d, 0.0)), steps_headband=round(wd.headband.get(d, 0.0)),
            headband_counted=not hidden, source=wd.source(d),
            check=dict(status=wd.check.status, paired=wd.check.paired, right=wd.check.right),
            detector=sorted({str(f.get("detector")) for f in files}),
            walks=sorted(walks.get(d, []), key=lambda e: e["start"]))
        days.sources[d].update(f["_origin"] for f in files if any(wm.day_of(m[0]) == d for m in f["minutes"]
                                                                   if isinstance(m, list) and m and
                                                                   isinstance(m[0], int)))


def summarise(local: Path) -> Days:
    """Every day eeg_tracker has anything for, from `local` (the `_local/` folder)."""
    days = Days()
    for part in (_nights, _mornings, _sharp, _study, _work, _practice, _walking):
        part(days, local)
    return days


def _round(v: float) -> float:
    r = round(v, 2)
    return 0.0 if r == 0 else r


def day_events(local: Path, now: datetime | None = None) -> list[dict]:
    """The data of one `eeg_day` event per day, oldest first. `complete` is false for the day still going on."""
    now = now or datetime.now().astimezone()
    days = summarise(local)
    today = day_key(now)
    out = []
    for d in days.all_days():
        numbers = {k: _round(days.numbers[d][k]) for k in MEASURE_IDS if k in days.numbers.get(d, {})}
        out.append(dict(
            day=d, schema=SCHEMA, measures=MEASURES_VERSION, complete=d < today, numbers=numbers,
            counts={k: v for k, v in sorted(days.counts.get(d, {}).items()) if v},
            quality=dict(sorted(days.quality.get(d, {}).items())),
            excluded=days.excluded.get(d, []),
            sources=sorted(days.sources.get(d, set())),
            **({"walking": days.walking[d]} if d in days.walking else {}),
        ))
    return out
