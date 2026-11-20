"""Battery readout for the BrainBit: one rule for the gauge's stuck values, the trend, and the charge by wear time.

The headband only reports a whole percent, and its gauge cannot be trusted while it streams: on 2026-11-18 from 05:17
to 08:03 it flipped between 1-2 % and 100 %; on the phone it read one value for a whole night (2 % on 11-18, 6 % on
11-19) while every fresh connection read 98-100 %. The rule (DECISIONS 766), shared by the recorder's live note,
scripts/phone_night_check.py and the data book (scripts/data_book.py):

- **Stuck:** 0-2 % and 100 % (the values it sticks at), and any value that stays unchanged for 60 minutes or more of
  streaming (a real battery falls about 10 points in that time). A stuck value is stuck for every reading of it in
  the same readings; it never counts as a level.
- **Trend:** the time left comes from a straight line through the believable readings of the last 90 minutes (since
  the last charge).
- **By wear time (an estimate):** the reading it counts from (a full one: 95 % or more, at the first reading or after
  30 minutes without streaming, when a charge was possible; or a believable reading more than 3 points above the
  believable one before it: charged in between) minus 11 % for every hour streamed since (measured on the nap of
  2026-11-20: 99 % to 79 % in 1.8 h). Planning values; always shown as an estimate.

Readings are (unix time, percent), oldest first; the recorder writes one every 10 s while it streams, so the time
between two readings at most 2 minutes apart counts as streaming. Pure Python: the recorder imports it and must stay
free of numpy.
"""
import re
from datetime import datetime
from pathlib import Path

STUCK = {0, 1, 2, 100}  # the values the gauge sticks at (2026-11-18)
STUCK_AFTER_S = 60 * 60  # any value unchanged this long while streaming is stuck too (2026-11-19: 6 % all night)
STREAM_GAP_S = 120  # readings further apart than this: the headband was not streaming in between
DRAIN_PER_H = 11.0  # % an hour of streaming, measured on the nap of 2026-11-20 (planning value)
FULL_PCT = 95  # a reading this high ...
CHARGE_OFF_S = 30 * 60  # ... first, or after this long without streaming, is a full charge for the estimate
CHARGE_RISE = 3  # a believable reading this many points above the one before: charged in between (as the trend's rule)
LINE = re.compile(r"^(\S+) .*\bbattery (\d+)%")
WINDOW_S = 90 * 60     # trend over the last 90 minutes
MIN_SPAN_S = 20 * 60   # at least 20 minutes of readings
MIN_DROP = 2           # and a drop of at least 2 % before saying anything about time left
WEAR_HOURS = 16.0      # how far back the recorder reads its logs, so the estimate finds the last full reading
RULE = (f"battery-v1: stuck {' '.join(map(str, sorted(STUCK)))} % or unchanged {STUCK_AFTER_S // 60} min streaming; "
        f"estimate {DRAIN_PER_H:g} %/h from a full ({FULL_PCT}+ %) or charged reading")  # the data book's rows name it

Points = list[tuple[float, int]]


def from_logs(folder: Path, now: float, hours: float = 3.0) -> Points:
    """(unix time, percent) from the recorder's .log files of the last `hours`, oldest first."""
    pts = []
    for f in sorted(Path(folder).glob("*.log")):
        try:
            if now - f.stat().st_mtime > hours * 3600:
                continue
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = LINE.match(line)
            if not m:
                continue
            try:
                t = datetime.fromisoformat(m.group(1)).timestamp()
            except ValueError:
                continue
            if 0 <= now - t <= hours * 3600:
                pts.append((t, int(m.group(2))))
    return sorted(pts)


def stuck_values(points: Points) -> set[int]:
    """STUCK and every value that stayed unchanged for STUCK_AFTER_S of streaming somewhere in `points`. A run of one
    value goes on across a pause in the stream (the gauge reads the same frozen value after a reconnect); only the
    streaming time inside it counts."""
    out = set(STUCK)
    run_v: int | None = None
    run_s = 0.0
    prev_t: float | None = None
    for t, v in points:
        if v != run_v:
            run_v, run_s = v, 0.0
        elif prev_t is not None and t - prev_t <= STREAM_GAP_S:
            run_s += t - prev_t
        if run_s >= STUCK_AFTER_S:
            out.add(v)
        prev_t = t
    return out


def believable(points: Points) -> Points:
    """The readings whose value is not stuck."""
    stuck = stuck_values(points)
    return [(t, v) for t, v in points if v not in stuck]


def streaming_s(points: Points, since: float, until: float) -> float:
    """Seconds streamed between `since` and `until`: the time between consecutive readings at most STREAM_GAP_S
    apart, inside that span."""
    total, prev = 0.0, None
    for t, _ in points:
        if prev is not None and t - prev <= STREAM_GAP_S:
            total += max(0.0, min(t, until) - max(prev, since))
        prev = t
    return total


def last_full(points: Points, at: float) -> tuple[float, int] | None:
    """The latest reading at or before `at` the estimate counts from: a full charge (FULL_PCT or more, and the first
    reading or one after CHARGE_OFF_S without a reading: the headband was off the stream, so it may have been charged;
    after the first, never a value found frozen) or a believable reading over CHARGE_RISE points above the one before it
    (charged in between). A full reading after a short drop (the gauge read 100 % after 5.3 h of streaming on
    2026-11-20) does not count."""
    stuck = stuck_values(points)
    frozen = stuck - STUCK
    best, prev, prev_good = None, None, None
    for t, v in points:
        if t > at:
            break
        if v >= FULL_PCT and (prev is None or (t - prev >= CHARGE_OFF_S and v not in frozen)):
            best = (t, v)
        elif v not in stuck and prev_good is not None and v > prev_good + CHARGE_RISE:
            best = (t, v)
        if v not in stuck:
            prev_good = v
        prev = t
    return best


def wear_estimate(points: Points, at: float) -> dict | None:
    """The charge at `at` by wear time: `pct` (whole percent, 0 at the least), `hours` streamed since the reading it
    counts from (last_full), `full` (that reading) and `since` (its time); None without one. An estimate."""
    full = last_full(points, at)
    if full is None:
        return None
    hours = streaming_s(points, full[0], at) / 3600
    return dict(pct=max(0, round(full[1] - DRAIN_PER_H * hours)), hours=round(hours, 1), full=full[1], since=full[0])


def _left(hours: float) -> str:
    if hours >= 3:
        return f"{hours:.0f} h"
    if hours >= 1:
        return f"{hours:.1f} h"
    return f"{hours * 60:.0f} min"


def estimate(points: Points, now: float) -> dict:
    """points: (unix time, percent), oldest first. Returns level, per_hour (drain), hours_left and a short text. A
    stuck gauge shows its value as stuck, with the charge by wear time when a full reading is known."""
    out = dict(level=None, per_hour=None, hours_left=None, text="?")
    if not points:
        return out
    stuck = stuck_values(points)
    last = points[-1][1]
    if last in stuck:
        wear = wear_estimate(points, now)
        out["text"] = f"gauge stuck (reads {last}%)" + (
            f"; about {wear['pct']}% by wear time (estimate)" if wear else "")
        return out
    good = [(t, v) for t, v in points if v not in stuck and now - t <= WINDOW_S]
    for i in range(len(good) - 1, 0, -1):  # a jump up means it was charged: the trend starts there
        if good[i][1] > good[i - 1][1] + 3:
            good = good[i:]
            break
    out.update(level=last, text=f"{last}%")
    if len(good) < 2 or good[-1][0] - good[0][0] < MIN_SPAN_S or good[0][1] - good[-1][1] < MIN_DROP:
        return out
    n = len(good)
    mt = sum(t for t, _ in good) / n
    mv = sum(v for _, v in good) / n
    den = sum((t - mt) ** 2 for t, _ in good)
    rate = -sum((t - mt) * (v - mv) for t, v in good) / den * 3600  # % per hour, positive while draining
    if rate <= 0.1:
        return out
    left = last / rate
    out.update(per_hour=round(rate, 1), hours_left=round(left, 1), text=f"{last}% · about {_left(left)} left")
    return out
