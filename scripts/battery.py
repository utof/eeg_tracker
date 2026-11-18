"""Battery readout for the BrainBit: drop the gauge's stuck values and estimate the time left from the trend.

The headband only reports a whole percent, and on 2026-11-18 from 05:17 to 08:03 it flipped between 1-2 % and
100 % while streaming; after that it read 37, 36, 35 % in 22 min. So 0-2 % and 100 % are treated as "stuck",
and the time left comes from a straight line through the believable readings of the last 90 minutes (since the
last charge). Pure Python: the recorder imports it and must stay free of numpy.
"""
import re
from datetime import datetime
from pathlib import Path

STUCK = {0, 1, 2, 100}
LINE = re.compile(r"^(\S+) .*\bbattery (\d+)%")
WINDOW_S = 90 * 60     # trend over the last 90 minutes
MIN_SPAN_S = 20 * 60   # at least 20 minutes of readings
MIN_DROP = 2           # and a drop of at least 2 % before saying anything about time left


def from_logs(folder: Path, now: float, hours: float = 3.0) -> list[tuple[float, int]]:
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


def _left(hours: float) -> str:
    if hours >= 3:
        return f"{hours:.0f} h"
    if hours >= 1:
        return f"{hours:.1f} h"
    return f"{hours * 60:.0f} min"


def estimate(points: list[tuple[float, int]], now: float) -> dict:
    """points: (unix time, percent), oldest first. Returns level, per_hour (drain), hours_left and a short text."""
    out = dict(level=None, per_hour=None, hours_left=None, text="?")
    if not points:
        return out
    last = points[-1][1]
    if last in STUCK:
        out["text"] = f"gauge stuck (reads {last}%)"
        return out
    good = [(t, v) for t, v in points if v not in STUCK and now - t <= WINDOW_S]
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
