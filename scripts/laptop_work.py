"""The laptop's work sessions, found from ActivityWatch, with break hints: the logic behind scripts/tray.py.

Standard library only and no GTK here: scripts/tray.py is the thin tray icon, menu and notifications around this.
Tested in analysis/tests/test_laptop_work.py. What the owner sees: docs/laptop-tray.md; choices: DECISIONS 570-579.

- Work apps: aw_focus.py's families "code" (terminals, editors, IDEs, Claude/ChatGPT, documentation and code pages in
  the browser) and "write" (office, notes, PDFs). Window titles are read in memory only and never written anywhere.
- Auto-start (a setting): off; ask first ("Started working?" once you have been 5 active minutes in work apps and are in
  one now); or automatic when sure (12 active minutes in work apps with at most 3 minutes elsewhere in between): it
  starts by itself and says so quietly, with a "Not work" button. Either way the session starts when that work began.
- Breaks: 5 minutes or more away from the keyboard and mouse (ActivityWatch AFK) is a break; so is "On a break" until
  "Back" (or until you come back from 5+ minutes away). 30 minutes or more away ends the session (a setting).
- Meetings (DECISIONS 660-669): while a call app holds the microphone (pactl) or a meeting window is in front, the
  time away from the keyboard is meeting time, never a break or the end; no notification pops up until it ends; a
  meeting can start a session under the auto-start setting.
- Break hints: break_hints.py's own rules (decide, breaks_taken, the same history file), on the active time with the
  tapped breaks cut out, while a session runs.
- Records: one JSON per session in _local/laptop/work/, the answers about detection in labels.jsonl beside them, and
  each hint as a break_hint event in break_hints.py's file (so the 4-a-day cap and the back-off are shared).
"""
from __future__ import annotations

import ipaddress, json, os, re, shutil, subprocess, sys, urllib.error, urllib.request
from bisect import bisect_left, bisect_right
from collections import Counter
from dataclasses import asdict, dataclass, field, fields, replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Callable, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aw_focus as af  # noqa: E402  (the work-app families, segments and runs)
import break_hints as bh  # noqa: E402  (AFK spans, the hint rules, the hint history file)

REPO = Path(__file__).resolve().parents[1]
LOCAL = REPO / "_local"
VERSION = 1
RULE = "laptop-detect-v1"
MODES = ("off", "ask", "auto")
AWAY_CHOICES = (30.0, 60.0, 0.0)        # the menu's "End the session after ... away" (0: never)
LIVE_LAG_MIN = 2.0                      # the last work window ended at most this long ago: you are in it now
SAVE_EVERY_MIN = 5.0                    # the session file is written whole this often while it runs
RESUME_WITHIN_MIN = 10.0                # a "running" file written this recently is taken up again after a restart
AUTOSTART_NAME = "eeg-tracker-tray.desktop"
HINT_ANSWERS = {"snooze": "snoozed", "break": "onBreak", "ok": "notNow"}   # the phone's names (app/lib/work)


# ---------- settings ----------

@dataclass(frozen=True)
class Settings:
    notifications: bool = True
    auto_start: str = "ask"               # off | ask | auto
    ask_after_min: float = 5.0            # active minutes in work apps before "Started working?"
    auto_after_min: float = 12.0          # clear active minutes in work apps before it starts by itself
    auto_max_away_min: float = 3.0        # at most this much elsewhere inside those clear minutes
    ask_again_min: float = 30.0           # no new question or auto-start this long after "Not work"
    end_after_away_min: float = 30.0      # away this long ends the session (0: never)
    hint_threshold_min: float = 60.0      # break_hints.py's threshold (50-90)
    quiet: str = "23:00-08:00"            # no hints in these hours ("off": none)
    max_hints_per_day: int = 4

    def hint_config(self) -> bh.Config:
        return bh.Config(threshold_min=self.hint_threshold_min, max_per_day=self.max_hints_per_day, quiet=self.quiet)


LIMITS = {"ask_after_min": (1, 60), "auto_after_min": (5, 120), "auto_max_away_min": (0, 15),
          "ask_again_min": (0, 240), "end_after_away_min": (0, 480), "hint_threshold_min": (50, 90),
          "max_hints_per_day": (0, 12)}


def _quiet_ok(v: object) -> bool:
    if not isinstance(v, str):
        return False
    try:
        bh.in_quiet(datetime(2026, 1, 1, 12), v)
        return True
    except ValueError:
        return False


def _value_ok(name: str, default: object, v: object) -> bool:
    if isinstance(default, bool):
        return isinstance(v, bool)
    if name == "auto_start":
        return v in MODES
    if name == "quiet":
        return _quiet_ok(v)
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return False
    if isinstance(default, int) and not float(v).is_integer():
        return False
    lo, hi = LIMITS[name]
    return lo <= v <= hi


def settings_from(raw: object) -> tuple[Settings, list[str]]:
    """Settings from parsed JSON. Each field is checked; a wrong one keeps its default and is named in the problems."""
    base = Settings()
    if not isinstance(raw, dict):
        return base, ["the settings file is not a JSON object"]
    vals: dict[str, object] = {}; problems = []
    for f in fields(Settings):
        if f.name not in raw:
            continue
        default = getattr(base, f.name); v = raw[f.name]
        if _value_ok(f.name, default, v):
            vals[f.name] = int(v) if isinstance(default, int) and not isinstance(default, bool) else \
                float(v) if isinstance(default, float) else v
        else:
            problems.append(f"{f.name}: {v!r} is not allowed, using {default!r}")
    return replace(base, **vals), problems


def config_dir() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def settings_path() -> Path:
    return config_dir() / "eeg_tracker" / "tray.json"


def write_json(path: Path, obj: object) -> None:
    """Written whole under a temporary name, then renamed (a crash leaves the old file or the new one)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, path)


class SettingsStore:
    """~/.config/eeg_tracker/tray.json. None: nothing is read or written (--once, --dry-run, tests)."""

    def __init__(self, path: Path | None):
        self.path = path; self.mtime: float | None = None; self.problems: list[str] = []

    def load(self) -> Settings:
        self.problems = []
        if self.path is None or not self.path.exists():
            return Settings()
        try:
            self.mtime = self.path.stat().st_mtime
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            self.problems = [f"the settings file could not be read ({e}); using the defaults"]
            return Settings()
        s, self.problems = settings_from(raw)
        return s

    def save(self, s: Settings) -> None:
        if self.path is None:
            return
        write_json(self.path, {"version": VERSION, **asdict(s)})
        self.mtime = self.path.stat().st_mtime

    def changed(self) -> bool:
        if self.path is None or not self.path.exists():
            return False
        return self.path.stat().st_mtime != self.mtime


# ---------- start at login (~/.config/autostart) ----------

_RESERVED = set(' \t\n"\'\\><~|&;$*?#()`')


def _exec_arg(a: str) -> str:
    """One argument of a desktop entry's Exec line (the Desktop Entry spec's quoting; % doubled)."""
    a = a.replace("%", "%%")
    if not any(c in _RESERVED for c in a):
        return a
    q = a.replace("\\", "\\\\\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")
    return f'"{q}"'


def autostart_path() -> Path:
    return config_dir() / "autostart" / AUTOSTART_NAME


def autostart_text(python: str, script: Path, icon: Path) -> str:
    return ("[Desktop Entry]\nType=Application\nName=EEG tracker: work sessions\n"
            "Comment=Work sessions and break hints from ActivityWatch (eeg_tracker, docs/laptop-tray.md)\n"
            f"Exec={_exec_arg(python)} {_exec_arg(str(script))}\nIcon={icon}\nTerminal=false\n"
            "X-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=20\n")


def autostart_on(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    return "Hidden=true" not in text and "X-GNOME-Autostart-enabled=false" not in text


def set_autostart(path: Path, on: bool, text: str) -> None:
    """Writes or removes the user's own autostart entry (nothing system-wide)."""
    if on:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    elif path.exists():
        path.unlink()


# ---------- ActivityWatch ----------

def _span(e: dict) -> tuple[datetime, datetime]:
    a = bh.parse_ts(e["timestamp"])
    return a, a + timedelta(seconds=float(e.get("duration") or 0))


def merge_events(cache: dict, new: list[dict]) -> None:
    """Adds fetched events to `cache` (id -> (start, end, event)). ActivityWatch cuts an event to the asked range, so
    one event can come back shorter than it is: the union of what was seen is kept."""
    for e in new:
        key = e.get("id", (e.get("timestamp"), json.dumps(e.get("data"), sort_keys=True)))
        a, b = _span(e)
        if key in cache:
            a0, b0, _ = cache[key]; a, b = min(a, a0), max(b, b0)
        cache[key] = (a, b, e)


def _event(a: datetime, b: datetime, e: dict) -> dict:
    return {**e, "timestamp": a.isoformat(), "duration": (b - a).total_seconds()}


class Source(Protocol):
    def read(self, now: datetime) -> None: ...
    def afk(self, now: datetime) -> list[dict]: ...
    def window_since(self, t: datetime, now: datetime) -> list[dict]: ...


class ActivityWatch:
    """This host's AFK and window buckets on localhost. AFK is read whole (12 h, a few dozen events); window events are
    kept for keep_h and only the last minutes are asked for again. Read-only; nothing is sent anywhere."""

    def __init__(self, host: str, keep_h: float = 6.0, afk_h: float = 12.0):
        self.host, self.keep_h, self.afk_h = host, keep_h, afk_h
        self.buckets: tuple[str, str] | None = None
        self.cache: dict = {}; self.last: datetime | None = None; self._afk: list[dict] = []
        self.afk_from: datetime | None = None    # read AFK from here at least (a session's start)

    def read(self, now: datetime) -> None:
        if self.buckets is None:
            self.buckets = (af.pick_bucket("aw-watcher-afk", self.host), af.pick_bucket("aw-watcher-window", self.host))
        ab, wb = self.buckets
        try:
            lo = now - timedelta(hours=self.afk_h)
            self._afk = bh.afk_events(ab, min(lo, self.afk_from or lo), now)
            keep = now - timedelta(hours=self.keep_h)
            since = keep if self.last is None else max(keep, self.last - timedelta(minutes=2))
            merge_events(self.cache, bh.afk_events(wb, since, now))      # (works on any bucket)
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.buckets = None
            raise af.NoActivityWatch(f"ActivityWatch stopped answering ({e})") from e
        self.cache = {k: v for k, v in self.cache.items() if v[1] > keep}
        self.last = now

    def afk(self, now: datetime) -> list[dict]:
        return self._afk

    def window_since(self, t: datetime, now: datetime) -> list[dict]:
        return [_event(a, b, e) for a, b, e in sorted(self.cache.values(), key=lambda v: v[0]) if b > t]


class Replay:
    """ActivityWatch as it was at each moment of recorded events (for --dry-run and the tests): nothing after `now`."""

    def __init__(self, afk: list[dict], window: list[dict]):
        self._afk = sorted((_span(e) + (e,) for e in afk), key=lambda v: v[0])
        self._win = sorted((_span(e) + (e,) for e in window), key=lambda v: v[0])
        self._starts = [v[0] for v in self._win]
        self._longest = max((b - a for a, b, _ in self._win), default=timedelta(0))

    def read(self, now: datetime) -> None:
        return None

    def afk(self, now: datetime) -> list[dict]:
        return [_event(a, min(b, now), e) for a, b, e in self._afk if a < now]

    def window_since(self, t: datetime, now: datetime) -> list[dict]:
        i, j = bisect_left(self._starts, t - self._longest), bisect_right(self._starts, now)
        return [_event(a, min(b, now), e) for a, b, e in self._win[i:j] if b > t and a < now]


# ---------- detection (pure) ----------

@dataclass(frozen=True)
class Run:
    """The run of work going on: one work family's stretches with only short switches between (aw_focus.runs).

    Minutes here are clock minutes in the work apps: from the run's start, less the time switched to other apps. A
    pause at the keyboard under 5 minutes (reading, thinking, waiting for a program or an assistant) counts; 5 minutes
    or more away is a real break and ends the run. (Hints count only active time: break_hints.py's rule.)"""
    start: datetime
    end: datetime
    work_min: float        # clock minutes in the family, less the switches
    away_min: float        # active minutes elsewhere inside the run (the short switches)
    clear_min: float       # work minutes at the run's end with at most auto_max_away_min elsewhere among them
    app: str               # the app that held most of it (a name, never a title)
    family: str
    now_in: bool           # you are in it now


def stretch_start(spans: list[tuple[datetime, datetime]], now: datetime) -> datetime | None:
    """When the activity going on now began (after the last break of 5 minutes or more); None: on a break."""
    return bh.session(spans, now, bh.Config())[0]


def _clear_tail(run: list[af.Seg], fam: str, max_away: float) -> float:
    """Work minutes of the longest end of the run with at most max_away active minutes in other apps."""
    away = 0.0; k = len(run) - 1
    for i in range(len(run) - 1, -1, -1):
        if run[i].fam != fam:
            if away + run[i].active_min > max_away:
                break
            away += run[i].active_min
        k = i
    return (run[-1].end - run[k].start).total_seconds() / 60 - away


def current_run(window: list[dict], spans: list[tuple[datetime, datetime]], now: datetime,
                s: Settings) -> Run | None:
    """The work run of the activity going on now, or None (on a break, or the last run is not in work apps)."""
    start = stretch_start(spans, now)
    if start is None:
        return None
    segs = af.segments(window, [p for p in spans if p[1] > start], start, now)
    if not segs:
        return None
    run = af.runs(segs)[-1]
    fam = run[0].fam
    if fam not in af.WORK_FAMILIES:
        return None
    apps: Counter = Counter()
    for x in run:
        if x.fam == fam:
            apps.update(x.apps)
    away = sum(x.active_min for x in run if x.fam != fam)
    return Run(run[0].start, run[-1].end,
               work_min=(run[-1].end - run[0].start).total_seconds() / 60 - away, away_min=away,
               clear_min=_clear_tail(run, fam, s.auto_max_away_min),
               app=apps.most_common(1)[0][0], family=fam,
               now_in=now - run[-1].end <= timedelta(minutes=LIVE_LAG_MIN))


def verdict(run: Run | None, s: Settings) -> str | None:
    """"ask", "auto" or None: what the auto-start setting does about this run now."""
    if run is None or not run.now_in or s.auto_start == "off":
        return None
    if s.auto_start == "auto":
        return "auto" if run.clear_min >= s.auto_after_min else None
    return "ask" if run.work_min >= s.ask_after_min else None


def same_run(a: Run, b: Run) -> bool:
    return abs((a.start - b.start).total_seconds()) <= 60


# ---------- meetings (pure, but for pactl; DECISIONS 660-669) ----------

# a word of a sound stream's app name -> the call app (the words as aw_focus.family splits them)
CALL_WORDS: dict[str, str] = {
    "zoom": "zoom", "teams": "teams", "skype": "skype", "skypeforlinux": "skype", "telegram": "telegram",
    "telegramdesktop": "telegram", "ayugram": "telegram", "ayugramdesktop": "telegram", "kotatogram": "telegram",
    "discord": "discord", "vesktop": "discord", "webcord": "discord", "slack": "slack", "signal": "signal",
    "element": "element", "webex": "webex", "whatsapp": "whatsapp", "jitsi": "jitsi", "mattermost": "mattermost",
    "viber": "viber"}
SPEAKER_CALL_APPS = frozenset({"zoom", "teams", "webex", "skype"})   # their sound out is a meeting (others: pings)
BROWSER_WORDS = af.FAMILIES["browser"] | {"yandex", "msedge", "edge", "floorp", "thorium"}
MEET_PAGES = ((re.compile(r"meet\.google\.com|google meet|^meet [-–—] [a-z]{3}-[a-z]{4}-[a-z]{3}"), "google meet"),
              (re.compile(r"jitsi"), "jitsi"), (re.compile(r"zoom meeting|zoom webinar"), "zoom"),
              (re.compile(r"whereby"), "whereby"), (re.compile(r"webex"), "webex"),
              (re.compile(r"(meeting|call).*teams|teams.*(meeting|call)"), "teams"))
MIC_JOIN_MIN = 3.0          # a call seen again within this long is the same meeting (a missed tick or two)
BACKDATE_MAX_H = 3.0        # a call found now counts from the last keyboard or mouse use at most this far back


def _words(s: str) -> list[str]:
    return [w for w in re.split(r"[.\-_\s/]+", (s or "").lower()) if w]


def pactl_streams(text: str) -> list[dict[str, str]]:
    """`pactl list source-outputs` / `sink-inputs` (LC_ALL=C) as one dict of properties per stream, with `corked`."""
    out: list[dict[str, str]] = []; cur: dict[str, str] | None = None
    for line in text.splitlines():
        if line and not line[0].isspace():
            cur = {}; out.append(cur); continue
        if cur is None:
            continue
        m = re.match(r'\s+([\w.\-]+) = "(.*)"\s*$', line)
        if m:
            cur[m[1]] = m[2]; continue
        m = re.match(r"\s+Corked: (\w+)", line)
        if m:
            cur["corked"] = m[1]
    return out


def call_app(props: dict[str, str]) -> str | None:
    """The call app a sound stream belongs to ("zoom", "telegram", "browser"), or None: the sound applet's
    "Peak detect" meters, recorders, speech tools and anything else that is not a call."""
    if "peak detect" in props.get("media.name", "").lower():
        return None
    words = _words(" ".join(props.get(k, "") for k in ("application.process.binary", "application.name",
                                                        "application.id")))
    app = next((CALL_WORDS[w] for w in words if w in CALL_WORDS), None)
    if app is None and BROWSER_WORDS & set(words):
        return "browser"          # a page holding the microphone: Meet, Jitsi, Teams or Zoom on the web
    return app


def meeting_from_pactl(mic: str, speaker: str = "") -> str | None:
    """The call app in a meeting now: one holding a microphone stream (muted or not), or Zoom, Teams, Webex or Skype
    playing sound (a meeting joined without a microphone); None."""
    for p in pactl_streams(mic):
        app = call_app(p)
        if app is not None:
            return app
    for p in pactl_streams(speaker):
        app = call_app(p)
        if app in SPEAKER_CALL_APPS and p.get("corked") != "yes":
            return app
    return None


def pactl_meeting(run: Callable[..., object] = subprocess.run) -> str | None:
    """meeting_from_pactl on this laptop's PipeWire/PulseAudio streams now (read only; 3 s at most each; None when
    pactl is missing or fails)."""
    def get(kind: str) -> str:
        try:
            r = run(["pactl", "list", kind], capture_output=True, text=True, timeout=3,
                    env={**os.environ, "LC_ALL": "C"})
        except (OSError, subprocess.SubprocessError):
            return ""
        return str(getattr(r, "stdout", "") or "") if getattr(r, "returncode", 1) == 0 else ""
    return meeting_from_pactl(get("source-outputs"), get("sink-inputs"))


def meeting_window(app: str, title: str) -> str | None:
    """A meeting's own window in front: Zoom's or Webex's meeting window, a Teams meeting or call, a meeting page in a
    browser. The title is read here, in memory, and never kept."""
    words = set(_words(app)); t = (title or "").lower()
    if "zoom" in words:
        return "zoom" if ("meeting" in t or "webinar" in t) and "workplace" not in t else None
    if "teams" in words:
        return "teams" if "meeting" in t or "call" in t else None
    if "webex" in words:
        return "webex" if "meeting" in t else None
    if words & BROWSER_WORDS:
        return next((name for rx, name in MEET_PAGES if rx.search(t)), None)
    return None


@dataclass
class Meeting:
    start: datetime
    end: datetime
    app: str                 # zoom, teams, telegram, browser, google meet, ...: never a title
    source: str              # mic (a call app's sound stream, seen each minute) | window (its window in front)

    def to_json(self) -> dict:
        return {"start": iso(self.start), "end": iso(self.end), "app": self.app, "source": self.source}


def window_meetings(window: list[dict], join_min: float = MIC_JOIN_MIN) -> list[Meeting]:
    """The stretches with a meeting window in front, joined across gaps under join_min."""
    out: list[Meeting] = []
    for e in sorted(window, key=lambda e: str(e.get("timestamp"))):
        d = e.get("data") or {}
        app = meeting_window(str(d.get("app") or ""), str(d.get("title") or ""))
        if app is None:
            continue
        a, b = _span(e)
        if out and out[-1].app == app and a - out[-1].end <= timedelta(minutes=join_min):
            out[-1].end = max(out[-1].end, b)
        else:
            out.append(Meeting(a, b, app, "window"))
    return out


def add_meeting(meetings: list[Meeting], m: Meeting, join_min: float = MIC_JOIN_MIN) -> None:
    """Into the kept meetings: joined with one of the same app and source it overlaps or nearly touches."""
    for x in meetings:
        if x.app == m.app and x.source == m.source and m.start - x.end <= timedelta(minutes=join_min) \
                and x.start - m.end <= timedelta(minutes=join_min):
            x.start, x.end = min(x.start, m.start), max(x.end, m.end)
            return
    meetings.append(m); meetings.sort(key=lambda x: x.start)


def with_meetings(spans: list[tuple[datetime, datetime]], meetings: list[Meeting],
                  gap_min: float) -> list[tuple[datetime, datetime]]:
    """The keyboard-and-mouse spans with the meetings added as activity (joined across gaps under gap_min)."""
    iv = sorted([*spans, *((m.start, m.end) for m in meetings)])
    out: list[list[datetime]] = []
    for a, b in iv:
        if out and a - out[-1][1] < timedelta(minutes=gap_min):
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def meeting_minutes(meetings: list[Meeting], lo: datetime, hi: datetime) -> float:
    """Minutes inside [lo, hi] in any meeting (overlaps counted once)."""
    return active_minutes(with_meetings([], meetings, 0), lo, hi)


def meeting_run(meetings: list[Meeting], app: str, now: datetime, gap_min: float) -> Run:
    """The meeting going on now as a run for the auto-start setting: from when it began (meetings joined across
    gaps under gap_min), every minute of it clear."""
    start = now
    for a, b in reversed(with_meetings([], meetings, gap_min)):
        if a <= start <= b + timedelta(minutes=LIVE_LAG_MIN):
            start = a
    m = (now - start).total_seconds() / 60
    return Run(start, now, work_min=m, away_min=0.0, clear_min=m, app=app, family="meeting", now_in=True)


def for_minutes(m: float) -> str:
    m = round(m)
    return f"{m} min" if m < 60 else f"{m // 60}h{m % 60:02d}"


# ---------- spans, breaks and the next hint (pure) ----------

Span = tuple[datetime, datetime]


def cut(spans: list[Span], holes: list[Span]) -> list[Span]:
    """The spans with the holes (tapped breaks) taken out."""
    out = []
    for a, b in spans:
        pieces = [(a, b)]
        for h0, h1 in holes:
            nxt = []
            for x, y in pieces:
                if h1 <= x or h0 >= y:
                    nxt.append((x, y)); continue
                if x < h0:
                    nxt.append((x, h0))
                if h1 < y:
                    nxt.append((h1, y))
            pieces = nxt
        out += pieces
    return out


def away_gaps(spans: list[Span], lo: datetime, hi: datetime, min_min: float) -> list[tuple[datetime, datetime | None]]:
    """Stretches of `min_min` or more with no activity inside [lo, hi]; the last is open (None) if still going."""
    gap = timedelta(minutes=min_min); out: list[tuple[datetime, datetime | None]] = []; last = lo
    for a, b in sorted(spans):
        if b <= lo or a >= hi:
            continue
        if a - last >= gap:
            out.append((last, a))
        last = max(last, min(b, hi))
    if hi - last >= gap:
        out.append((last, None))
    return out


def active_minutes(spans: list[Span], lo: datetime, hi: datetime) -> float:
    return sum(max(0.0, (min(b, hi) - max(a, lo)).total_seconds()) for a, b in spans) / 60


def next_hint_at(now: datetime, spans: list[Span], history: list[bh.Rec], cfg: bh.Config,
                 horizon_h: float = 12) -> datetime | None:
    """When the next hint would come if you kept working without a break: break_hints.decide, minute by minute.
    None: on a break now, or no hint before the day ends (cap, quiet hours) or within the horizon."""
    if bh.session(spans, now, cfg)[0] is None:
        return None
    ext = [(a, min(b, now)) for a, b in spans if a < now] + [(now, now + timedelta(hours=horizon_h + 1))]
    t = now
    while t < now + timedelta(hours=horizon_h):
        t += timedelta(minutes=1)
        if bh.day_key(t) != bh.day_key(now):
            return None
        if bh.decide(t, ext, history, cfg).show:
            return t
    return None


def quiet_end(now: datetime, quiet: str) -> datetime | None:
    if not bh.in_quiet(now, quiet):
        return None
    t = now.replace(second=0, microsecond=0)
    for _ in range(24 * 60):
        t += timedelta(minutes=1)
        if not bh.in_quiet(t, quiet):
            return t
    return None


# ---------- the hint history (break_hints.py's file, or memory) ----------

class HintLog(Protocol):
    def history(self) -> list[bh.Rec]: ...
    def write(self, kind: str, active_min: float, threshold_min: float, hint: str | None = None,
              now: datetime | None = None) -> bh.Rec: ...


class FileHintLog:
    """break_hints.py's <export>/events/<dev>/breaks-YYYY-MM.jsonl: the same events, cap and back-off."""

    def __init__(self, root: Path):
        self.log = bh.Log(root)

    def history(self) -> list[bh.Rec]:
        return bh.read_history(self.log.folder)

    def write(self, kind: str, active_min: float, threshold_min: float, hint: str | None = None,
              now: datetime | None = None) -> bh.Rec:
        return self.log.write(kind, active_min, threshold_min, hint=hint, now=now)


class MemoryHintLog:
    """Nothing written: --once, --dry-run and the tests (optionally starting from the file's history, read only)."""

    def __init__(self, seed: list[bh.Rec] | None = None):
        self.recs = list(seed or []); self.n = 0

    def history(self) -> list[bh.Rec]:
        return list(self.recs)

    def write(self, kind: str, active_min: float, threshold_min: float, hint: str | None = None,
              now: datetime | None = None) -> bh.Rec:
        self.n += 1
        r = bh.Rec(now or datetime.now().astimezone(), kind, f"mem:{self.n}", hint)
        self.recs.append(r)
        return r


def read_only_history(export_root: Path) -> list[bh.Rec]:
    f = export_root / "device_id"
    if not f.exists():
        return []
    return bh.read_history(export_root / "events" / f.read_text().strip())


# ---------- the records ----------

def iso(t: datetime | None) -> str | None:
    """Local time with its UTC offset, to the second (ActivityWatch's times come in UTC)."""
    return None if t is None else t.astimezone().replace(microsecond=0).isoformat()


class Records:
    """<local>/laptop/work/: one <stamp>.work.json per session and labels.jsonl. folder None: kept in memory only."""

    def __init__(self, folder: Path | None):
        self.folder = folder; self.memory: dict[str, dict] = {}; self.labels: list[dict] = []

    def free_stamp(self, start: datetime) -> str:
        base = start.astimezone().strftime("%Y-%m-%d-%H%M%S"); stamp = base; n = 1
        while stamp in self.memory or (self.folder is not None and (self.folder / f"{stamp}.work.json").exists()):
            n += 1; stamp = f"{base}-{n}"
        return stamp

    def save(self, stamp: str, data: dict) -> None:
        self.memory[stamp] = data
        if self.folder is not None:
            write_json(self.folder / f"{stamp}.work.json", data)

    def label(self, line: dict) -> None:
        self.labels.append(line)
        if self.folder is not None:
            self.folder.mkdir(parents=True, exist_ok=True)
            with open(self.folder / "labels.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(line, ensure_ascii=False, separators=(",", ":")) + "\n")

    def latest(self) -> tuple[str, dict] | None:
        """The newest session file (by its start), or None."""
        if self.folder is None:
            return max(self.memory.items()) if self.memory else None
        for f in sorted(self.folder.glob("*.work.json"), reverse=True) if self.folder.exists() else []:
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(d, dict) and d.get("kind") == "laptop_work_session":
                return f.name[:-len(".work.json")], d
        return None

    def running(self) -> list[tuple[str, dict]]:
        """Files a crash or a power cut left `running`, oldest first."""
        out = []
        if self.folder is None or not self.folder.exists():
            return out
        for f in sorted(self.folder.glob("*.work.json")):
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(d, dict) and d.get("kind") == "laptop_work_session" and d.get("ended") == "running":
                out.append((f.name[:-len(".work.json")], d))
        return out


@dataclass
class Hint:
    at: datetime
    reason: str               # stretch | snooze (the phone's names)
    active_min: float
    threshold_min: float
    event: str                # the id of its break_hint `shown` event
    via: str                  # notification | tray (notifications off: only the tray shows it)
    answer: str | None = None
    answered_at: datetime | None = None
    taken: bool = False

    def to_json(self) -> dict:
        return {"at": iso(self.at), "reason": self.reason, "active_min": round(self.active_min, 1),
                "threshold_min": self.threshold_min, "via": self.via, "answer": self.answer,
                "answered_at": iso(self.answered_at), "taken": self.taken, "event": self.event}


@dataclass
class Tapped:
    start: datetime
    end: datetime | None = None
    ended_by: str | None = None   # back | returned (came back from 5+ min away) | session end


@dataclass
class WorkSession:
    stamp: str
    start: datetime
    started_by: str               # manual | asked | auto
    detected: dict | None
    settings: dict
    hints: list[Hint] = field(default_factory=list)
    tapped: list[Tapped] = field(default_factory=list)
    labels: list[dict] = field(default_factory=list)
    events: list[dict] = field(default_factory=list)
    end: datetime | None = None
    ended: str = "running"
    meetings: list[Meeting] = field(default_factory=list)   # read back from its file (the tray keeps the live list)

    def open_break(self) -> Tapped | None:
        return self.tapped[-1] if self.tapped and self.tapped[-1].end is None else None

    def holes(self, now: datetime) -> list[Span]:
        return [(b.start, b.end or now + timedelta(days=1)) for b in self.tapped]

    def note(self, at: datetime, event: str) -> None:
        self.events.append({"at": iso(at), "event": event})

    def breaks(self, spans: list[Span], now: datetime, break_min: float) -> list[dict]:
        """Tapped breaks, and stretches of break_min or more away that are not inside one."""
        hi = self.end or now
        out = [{"start": iso(b.start), "end": iso(b.end), "source": "tapped"} for b in self.tapped]
        holes = self.holes(now)
        for a, b in away_gaps(spans, self.start, hi, break_min):
            if not any(h0 <= a < h1 for h0, h1 in holes):
                out.append({"start": iso(a), "end": iso(b), "source": "away"})
        return sorted(out, key=lambda x: x["start"] or "")

    def to_json(self, spans: list[Span], now: datetime, break_min: float,
                meetings: list[Meeting] | None = None) -> dict:
        hi = self.end or now
        mine = [Meeting(max(m.start, self.start), min(m.end, hi), m.app, m.source) for m in meetings or []
                if m.end > self.start and m.start < hi]
        return {"version": VERSION, "kind": "laptop_work_session", "app": "eeg_tracker tray",
                "start": iso(self.start), "end": iso(hi), "ended": self.ended, "started_by": self.started_by,
                "detected": self.detected,
                "active_min": round(active_minutes(cut(spans, self.holes(now)), self.start, hi), 1),
                "meeting_min": round(meeting_minutes(mine, self.start, hi), 1),
                "hints": [h.to_json() for h in self.hints], "breaks": self.breaks(spans, now, break_min),
                "meetings": [m.to_json() for m in mine],
                "labels": self.labels, "events": self.events, "settings": self.settings, "written": iso(now)}


def _t(v: object) -> datetime | None:
    try:
        return datetime.fromisoformat(v) if isinstance(v, str) else None
    except ValueError:
        return None


def session_from(stamp: str, d: dict) -> WorkSession | None:
    """A session file read back (to take up a session after a restart); None if it does not read cleanly."""
    try:
        start = _t(d["start"])
        if start is None or d.get("started_by") not in ("manual", "asked", "auto"):
            return None
        s = WorkSession(stamp, start, d["started_by"], d.get("detected"), dict(d.get("settings") or {}),
                        labels=list(d.get("labels") or []), events=list(d.get("events") or []))
        for h in d.get("hints") or []:
            s.hints.append(Hint(_t(h["at"]) or start, str(h["reason"]), float(h["active_min"]),
                                float(h["threshold_min"]), str(h["event"]), str(h.get("via") or "notification"),
                                h.get("answer"), _t(h.get("answered_at")), bool(h.get("taken"))))
        for b in d.get("breaks") or []:
            if b.get("source") == "tapped":
                s.tapped.append(Tapped(_t(b["start"]) or start, _t(b.get("end"))))
        for m in d.get("meetings") or []:
            a, b = _t(m["start"]), _t(m["end"])
            if a is not None and b is not None and b >= a:
                s.meetings.append(Meeting(a, b, str(m["app"]), str(m["source"])))
        return s
    except (KeyError, TypeError, ValueError):
        return None


# ---------- the phone link (a hook: feat/qr-pairing's scripts/phone_link.py) ----------

def link_status_probe(url: str = "http://127.0.0.1:8771/status") -> dict | None:
    """phone_link.py's own status, on this laptop only; None when it is not running."""
    try:
        with urllib.request.urlopen(url, timeout=0.5) as r:
            d = json.load(r)
        return d if isinstance(d, dict) else None
    except (urllib.error.URLError, OSError, ValueError):
        return None


PAIR_PAGE = "http://127.0.0.1:8771/"  # phone_link.py's own page on this laptop: the code, bigger


def pair_command(repo: Path = REPO, python: str = sys.executable, *, local: Path | None = None,
                 probe: Callable[[], dict | None] | None = None,
                 which: Callable[[str], str | None] = shutil.which) -> list[str] | None:
    """The command "Pair phone…" runs. While phone_link.py already runs (its status answers on this laptop): its page
    with the code, in the browser. Else phone_link.py in a terminal window (it shows the QR code and wants Enter for a
    new one), copying the phone's files into [local] (the tray's `_local`). None while the script is not in this
    checkout, or there is no terminal program."""
    script = repo / "scripts" / "phone_link.py"
    if not script.exists():
        return None
    if (probe or link_status_probe)() is not None:
        return ["xdg-open", PAIR_PAGE]
    args = [python, str(script)] + (["--dest", str(local)] if local is not None else [])
    term = which("x-terminal-emulator")
    if term is not None:
        return [term, "-e", *args]  # Debian's rule: -e takes the command and its arguments
    term = which("gnome-terminal")
    return None if term is None else [term, "--", *args]


def phone_line(local: Path, probe: Callable[[], dict | None] = link_status_probe) -> str | None:
    """One status line about the phone from <local>/phone/link.json (written by phone_link.py) and its running
    status; None when no phone was ever paired. The token in the file is never read out."""
    try:
        raw = json.loads((local / "phone" / "link.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict) or not raw.get("phone"):
        return None
    st = probe()
    if st is None:
        return "Phone: paired (the link is not running)"
    return "Phone: connected, copying its files" if st.get("connected") else "Phone: paired, not answering now"


_PHONE_NETS = tuple(ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "127.0.0.0/8"))   # phone_link.py's, and adb's
_TOKEN = re.compile(r"[A-Za-z0-9]{8,64}")


def _phone_target(local: Path) -> tuple[str, int, str] | None:
    """(address, port, token) of the paired phone's Share on Wi-Fi from <local>/phone/link.json; None when there is
    none, or it is not on the local network (or this laptop, through adb)."""
    try:
        raw = json.loads((local / "phone" / "link.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    ph = raw.get("phone") if isinstance(raw, dict) else None
    if not isinstance(ph, dict):
        return None
    addr, port, token = ph.get("address"), ph.get("port"), ph.get("token")
    if not (isinstance(addr, str) and isinstance(port, int) and 0 < port < 65536 and isinstance(token, str)
            and _TOKEN.fullmatch(token)):
        return None
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return None
    if ip.version != 4 or not any(ip in n for n in _PHONE_NETS):
        return None
    return addr, port, token


def phone_work_signal(local: Path, working: bool, *, meeting: bool | None = None, timeout: float = 3.0) -> str:
    """Tells the paired phone that a work session started ([working]) or ended here: Share on Wi-Fi's POST /work,
    with the token phone_link.py keeps. Automatic recording on the phone takes "working" from it (DECISIONS 603) and
    may check whether the headband is on. One word for the log ("sent", "not paired", "refused (503)": a night
    records, or sharing is off, "not reachable"); the token is never in it. Never raises; no proxy (local network).
    [meeting]: whether the session is in a meeting now (DECISIONS 666), sent at the session's start and end and at
    each meeting's start and end inside it; the phone's work session labels its meeting minutes by it (DECISIONS 685)."""
    t = _phone_target(local)
    if t is None:
        return "not paired"
    host, port, token = t
    req = urllib.request.Request(f"http://{host}:{port}/work", data=json.dumps({"working": working, **({} if meeting is None else {"meeting": meeting})}).encode(),
                                 method="POST", headers={"Authorization": f"Bearer {token}",
                                                         "Content-Type": "application/json"})
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as r:
            return "sent" if 200 <= r.status < 300 else f"refused ({r.status})"
    except urllib.error.HTTPError as e:
        return f"refused ({e.code})"
    except (urllib.error.URLError, OSError, ValueError):
        return "not reachable"


def phone_work_level(local: Path) -> str | None:
    """Hook, not wired yet: while the phone runs its own Work session with the headband, the tray could show its
    drowsiness level (alert / getting drowsy / drowsy) from the phone's Share on Wi-Fi API. The phone's /state has no
    work fields yet (app/test/fixtures/share_api.json), so this says nothing; the integration pass adds the call."""
    return None


# ---------- the controller ----------

class Notifier(Protocol):
    def show(self, key: str, title: str, body: str, actions: list[tuple[str, str]],
             answer: Callable[[str], None], low: bool = False) -> None: ...
    def close(self, key: str) -> None: ...


@dataclass(frozen=True)
class View:
    icon: str                      # working | break | idle | attention
    lines: tuple[str, ...]         # the status lines at the top of the menu (the first is also the tooltip)
    show: frozenset[str]           # the actions the menu offers now
    settings: Settings
    autostart: bool


def hm(t: datetime) -> str:
    return t.astimezone().strftime("%H:%M")


def dur(d: timedelta) -> str:
    m = max(0, int(d.total_seconds() // 60))
    return f"{m // 60}:{m % 60:02d}"


MODE_LINES = {"off": "Auto-start off: press Start work session",
              "ask": "Asks \"Started working?\" after {ask:g} min in work apps",
              "auto": "Starts by itself after {auto:g} clear min in work apps"}


class WorkTray:
    """Everything the tray does, without GTK: ticks with ActivityWatch's data, the menu's actions, and the view."""

    def __init__(self, source: Source, notifier: Notifier, records: Records, hints: HintLog,
                 store: SettingsStore | None = None, local: Path = LOCAL,
                 autostart: Path | None = None, phone: Callable[[], str | None] | None = None,
                 work_signal: Callable[[bool], None] | None = None, mic: Callable[[], str | None] | None = None):
        self.source, self.notifier, self.records, self.hints = source, notifier, records, hints
        self.store = store or SettingsStore(None); self.local = local
        self.s = self.store.load()
        self.autostart = autostart; self.phone = phone
        self.work_signal = work_signal          # tells the paired phone a session started (True) or ended (False)
        self.session: WorkSession | None = None
        self.spans: list[Span] = []; self.window: list[dict] = []
        self.run: Run | None = None; self.pending: Run | None = None
        self.blocked_before: datetime | None = None; self.quiet_until: datetime | None = None
        self.last_end: datetime | None = None; self.last_saved: datetime | None = None
        self.aw_error: str | None = None; self.phone_text: str | None = None
        self.ticks = 0; self.log: list[str] = []      # what happened, for --dry-run and the tests
        self.clock: Callable[[], datetime] = lambda: datetime.now().astimezone()   # for the notifications' answers
        self.mic = mic                          # the call app holding the microphone now (pactl_meeting), or None
        self.mic_now: str | None = None; self.meeting_now: str | None = None
        self.meetings: list[Meeting] = []; self.meet_scan: datetime | None = None
        self.held: dict[str, tuple] = {}        # notifications kept back during a meeting, shown when it ends

    # --- reading
    def tick(self, now: datetime) -> None:
        try:
            self.fetch(now)
        except af.NoActivityWatch as e:
            self.aw_error = str(e); return
        self.apply(now)

    def fetch(self, now: datetime) -> None:
        """The slow part, with no decisions: ActivityWatch and the phone link's status (scripts/tray.py runs this in a
        thread, then apply() in the main loop). Raises af.NoActivityWatch."""
        if self.phone is not None:
            self.phone_text = self.phone()
        if self.mic is not None:
            self.mic_now = self.mic()
        self.source.read(now)

    def apply(self, now: datetime) -> None:
        """The decisions, after fetch(now) succeeded."""
        self.aw_error = None; self.ticks += 1
        if self.store.changed():
            self.s = self.store.load()
        gap = bh.Config().merge_gap_min
        raw = bh.active_spans(self.source.afk(now), gap)
        new = self._track_meetings(now, raw)
        self.spans = with_meetings(raw, self.meetings, gap)
        old, self.meeting_now = self.meeting_now, new
        if new != old:
            self._meeting_changed(now, old, new)
        if self.session is not None:
            self._in_session(now)
        if self.session is None:
            self._detect(now)

    def _cfg(self) -> bh.Config:
        return self.s.hint_config()

    # --- meetings
    def _track_meetings(self, now: datetime, raw: list[Span]) -> str | None:
        """Adds what the window bucket and the microphone say to self.meetings; the call app in a meeting now."""
        lo = now - timedelta(hours=6) if self.meet_scan is None else self.meet_scan - timedelta(minutes=10)
        win = self.source.window_since(lo, now); self.meet_scan = now
        for m in window_meetings(win):
            add_meeting(self.meetings, m)
        if self.mic_now is not None:
            self._mic_seen(now, raw, self.mic_now)
        keep = now - timedelta(hours=12)
        if self.session is not None:
            keep = min(keep, self.session.start)
        self.meetings = [m for m in self.meetings if m.end > keep]
        in_front = None
        if win:
            a, b = _span(win[-1]); d = win[-1].get("data") or {}
            if now - b <= timedelta(minutes=LIVE_LAG_MIN):
                in_front = meeting_window(str(d.get("app") or ""), str(d.get("title") or ""))
        return self.mic_now or in_front

    def _mic_seen(self, now: datetime, raw: list[Span], app: str) -> None:
        last = next((m for m in reversed(self.meetings) if m.source == "mic"), None)
        if last is not None and last.app == app and now - last.end <= timedelta(minutes=MIC_JOIN_MIN):
            last.end = max(last.end, now); return
        # A call found now counts from the last keyboard or mouse use (or the meeting before) when nothing was
        # touched since: joining a call takes a click, so a stretch without input that runs into a call was in it.
        start = now
        before = [b for a, b in raw if a <= now] + [m.end for m in self.meetings if m.end <= now]
        if before and now - max(before) <= timedelta(hours=BACKDATE_MAX_H):
            start = min(now, max(before))
        add_meeting(self.meetings, Meeting(start, now, app, "mic"))

    def _meeting_changed(self, now: datetime, old: str | None, new: str | None) -> None:
        s = self.session
        if new is not None:
            start = meeting_run(self.meetings, new, now, bh.Config().merge_gap_min).start
            text = f"in a meeting ({new}) since {hm(start)}"
        else:
            text = f"meeting ({old}) ended"
        self.log.append(f"{hm(now)} {text}")
        if s is not None:
            s.note(now, text); self.last_saved = None
            # the phone labels its work session's talking minutes by it (DECISIONS 685): a word that only changes
            # the meeting asks it for no headband check
            self._tell_phone(now, True)
        if new is None:
            held, self.held = self.held, {}
            for key, args in held.items():
                self.notifier.show(key, *args)

    def _notify(self, key: str, title: str, body: str, actions: list[tuple[str, str]],
                answer: Callable[[str], None], low: bool = False) -> None:
        """A notification now, or when the meeting ends: nothing pops up during a meeting."""
        if self.meeting_now is not None:
            self.held[key] = (title, body, actions, answer, low)
        else:
            self.notifier.show(key, title, body, actions, answer, low=low)

    def _close(self, key: str) -> None:
        self.held.pop(key, None); self.notifier.close(key)

    def _take_up_after_meeting(self, now: datetime) -> bool:
        """The newest session ended as `away` while the time away was this meeting (the stretch going on now began
        before that end): it is taken up again, the same file."""
        got = self.records.latest()
        if got is None or got[1].get("ended") != "away":
            return False
        end = _t(got[1].get("end")); st = stretch_start(self.spans, now)
        if end is None or st is None or st > end or now - end > timedelta(hours=BACKDATE_MAX_H):
            return False
        s = session_from(*got)
        if s is None:
            return False
        for m in s.meetings:
            add_meeting(self.meetings, m)
        s.note(now, f"taken up again: the time away was a meeting ({self.meeting_now})")
        self.session = s; self.log.append(f"{hm(now)} session from {hm(s.start)} taken up again (a meeting)")
        self.save(now); self._tell_phone(now, True)
        return True

    def _spans_cut(self, now: datetime) -> list[Span]:
        return cut(self.spans, self.session.holes(now)) if self.session else self.spans

    # --- while a session runs
    def _in_session(self, now: datetime) -> None:
        s = self.session; assert s is not None
        if isinstance(self.source, ActivityWatch):   # AFK from the session's start, even past 12 h
            self.source.afk_from = s.start - timedelta(minutes=10)
        b = s.open_break()
        if b is not None:
            back = [g for g in away_gaps(self.spans, b.start, now, self._cfg().break_min) if g[1] is not None]
            if back:
                b.end, b.ended_by = back[0][1], "returned"; s.note(back[0][1], "back (returned)")
        if self._ended_by_away(now):
            return
        cfg = self._cfg(); spans = self._spans_cut(now); hist = self.hints.history()
        for h in bh.breaks_taken(now, spans, hist, cfg):
            self.hints.write("taken", 0, bh.threshold_now(now, hist, cfg), hint=h.id, now=now)
            for mine in s.hints:
                if mine.event == h.id:
                    mine.taken = True
            self.last_saved = None
        if s.open_break() is None and self.meeting_now is None:     # never during a meeting: after it
            d = bh.decide(now, spans, self.hints.history(), cfg)
            if d.show:
                self._show_hint(now, d)
        if self.last_saved is None or now - self.last_saved >= timedelta(minutes=SAVE_EVERY_MIN):
            self.save(now)

    def _ended_by_away(self, now: datetime) -> bool:
        s = self.session; limit = self.s.end_after_away_min
        if s is None or limit <= 0:
            return False
        for a, b in away_gaps(self.spans, s.start, now, limit):
            self.stop(now, ended="away", at=a, why=f"away {round(((b or now) - a).total_seconds() / 60)} min")
            return True
        return False

    def _show_hint(self, now: datetime, d: bh.Decision) -> None:
        s = self.session; assert s is not None
        rec = self.hints.write("shown", d.active_min, d.threshold_min, now=now)
        h = Hint(now, "snooze" if d.reason == "snooze over" else "stretch", d.active_min, d.threshold_min, rec.id,
                 "notification" if self.s.notifications else "tray")
        s.hints.append(h); s.note(now, "hint"); self.log.append(f"{hm(now)} hint ({round(d.active_min)} min)")
        st = bh.session(self._spans_cut(now), now, self._cfg())[0]
        mm = meeting_minutes(self.meetings, st, now) if st is not None else 0.0
        text = (f"You've been at it for {round(d.active_min)} min." if mm < 1 else
                f"You've been at it for {for_minutes(d.active_min)}, {round(mm)} min of it in a meeting.")
        if self.s.notifications:
            self._notify("hint", "A short break?", f"{text} A few minutes away from the screen?",
                         [("snooze", "Snooze 20 min"), ("break", "On a break"), ("ok", "OK")],
                         lambda ans, s=s, h=h: self.answer_hint(ans, self.clock(), s, h),
                         low=True)
        self.save(now)

    def pending_hint(self, now: datetime) -> Hint | None:
        """The last hint, while nobody answered it and no break followed (shown in the last 30 minutes)."""
        s = self.session
        if s is None or not s.hints or s.open_break() is not None:
            return None
        h = s.hints[-1]
        if h.answer or h.taken or now - h.at > timedelta(minutes=self._cfg().taken_window_min):
            return None
        return h

    def _snoozable(self, now: datetime) -> Hint | None:
        s = self.session
        if s is None or not s.hints or s.open_break() is not None:
            return None
        h = s.hints[-1]
        ok = h.answer in (None, "notNow") and not h.taken and now - h.at <= timedelta(minutes=self._cfg().min_gap_min)
        return h if ok else None

    # --- detection while no session runs
    def _detect(self, now: datetime) -> None:
        if self.meeting_now is not None and self._take_up_after_meeting(now):
            return
        start = stretch_start(self.spans, now)
        self.window = [] if start is None else self.source.window_since(start, now)
        run = current_run(self.window, self.spans, now, self.s)
        if self.meeting_now is not None and (run is None or not run.now_in):
            run = meeting_run(self.meetings, self.meeting_now, now, bh.Config().merge_gap_min)
        self.run = run
        p = self.pending
        if p is not None and (start is None or start > p.start + timedelta(minutes=1)
                              or (run is not None and not same_run(run, p))):
            self._label(now, "ask", "none", p, None); self.pending = None; self._close("ask")
        v = verdict(run, self.s)
        if v is None or run is None or self._blocked(run, now):
            return
        if v == "ask" and self.pending is None:
            self.pending = run; self.log.append(f"{hm(now)} asked (in work apps {round(run.work_min)} min)")
            if self.s.notifications:
                text = (f"In a meeting ({run.app}) since {hm(run.start)}. Start a work session from then?"
                        if run.family == "meeting" else
                        f"You've been in {run.app} and other work apps for {round(run.work_min)} min "
                        f"since {hm(run.start)}. Start a work session?")
                self._notify("ask", "Started working?", text, [("yes", "Yes"), ("no", "Not work")],
                             lambda ans, r=run: self.answer_question(ans == "yes", self.clock(), r))
        elif v == "auto":
            self.start(now, "auto", run)
            if self.s.notifications:
                text = (f"A meeting ({run.app}) since {hm(run.start)}, so a work session runs from then. Not work? "
                        "Tap Not work." if run.family == "meeting" else
                        f"{round(run.clear_min)} min in {run.app} and other work apps, so a work session "
                        f"runs from {hm(run.start)}. Not work? Tap Not work.")
                self._notify("auto", "Work session started", text, [("notwork", "Not work"), ("ok", "OK")],
                             lambda ans, s=self.session: self._auto_answer(ans, self.clock(), s),
                             low=True)

    def _blocked(self, run: Run, now: datetime) -> bool:
        if self.quiet_until is not None and now < self.quiet_until:
            return True
        return self.blocked_before is not None and run.start <= self.blocked_before

    def _label(self, now: datetime, question: str, answer: str, run: Run | None, session: WorkSession | None) -> None:
        r = run
        self.records.label({
            "version": VERSION, "at": iso(now), "question": question, "answer": answer,
            "run_start": iso(r.start) if r else None, "work_min": round(r.work_min, 1) if r else None,
            "away_min": round(r.away_min, 1) if r else None, "clear_min": round(r.clear_min, 1) if r else None,
            "app": r.app if r else None, "family": r.family if r else None,
            "session": session.stamp if session else None,
            "rule": f"{RULE} ask={self.s.ask_after_min:g} auto={self.s.auto_after_min:g} "
                    f"away={self.s.auto_max_away_min:g} switch={af.FocusConfig().switch_min:g}"})
        if session is not None and answer != "none":
            session.labels.append({"at": iso(now), "label": "not_work" if answer in ("no", "not_work") else "work",
                                   "question": question, "answer": answer})

    def _run_of(self, s: WorkSession) -> Run | None:
        d = s.detected
        if not d:
            return None
        return Run(_t(d["run_start"]) or s.start, s.start, d["work_min"], d["away_min"], d["clear_min"], d["app"],
                   d["family"], True)

    # --- the menu's and the notifications' actions
    def start(self, now: datetime, by: str = "manual", run: Run | None = None) -> None:
        if self.session is not None:
            return
        if self.pending is not None and by == "manual":     # Start pressed while being asked: the question is over
            self._label(now, "ask", "none", self.pending, None); self._close("ask")
        start = run.start if run else now
        if self.last_end is not None and start < self.last_end:
            start = self.last_end
        detected = None if run is None else {
            "at": iso(now), "run_start": iso(run.start), "work_min": round(run.work_min, 1),
            "away_min": round(run.away_min, 1), "clear_min": round(run.clear_min, 1), "app": run.app,
            "family": run.family}
        self.session = WorkSession(self.records.free_stamp(start), start, by, detected, asdict(self.s))
        self.session.note(now, f"started ({by})"); self.pending = None
        self.log.append(f"{hm(now)} session started ({by}) from {hm(start)}")
        self.save(now)
        self._tell_phone(now, True)

    def _tell_phone(self, now: datetime, working: bool) -> None:
        """Automatic recording on the phone (DECISIONS 603): a session started or ended here. A phone that cannot be
        told never stops the tray."""
        if self.work_signal is None:
            return
        try:
            self.work_signal(working)
        except (OSError, ValueError, RuntimeError) as e:
            self.log.append(f"{hm(now)} the phone was not told: {e}")

    def stop(self, now: datetime, ended: str = "stopped", at: datetime | None = None, why: str = "") -> None:
        s = self.session
        if s is None:
            return
        end = at or now
        b = s.open_break()
        if b is not None:
            b.end, b.ended_by = max(b.start, end), "session end"
        if s.started_by == "auto" and not s.labels and ended != "not_work":
            self._label(now, "auto", "none", self._run_of(s), s)
        s.end, s.ended = end, ended; s.note(now, f"ended ({ended}{': ' + why if why else ''})")
        self.save(now)
        self.log.append(f"{hm(now)} session ended ({ended}) at {hm(end)}, {dur(end - s.start)}")
        self.session = None; self.last_end = end; self.last_saved = None
        self._tell_phone(now, False)
        if isinstance(self.source, ActivityWatch):
            self.source.afk_from = None
        for k in ("hint", "auto"):
            self._close(k)
        if ended in ("stopped", "not_work"):
            self.blocked_before = now

    def on_break(self, now: datetime) -> None:
        s = self.session
        if s is None or s.open_break() is not None:
            return
        h = self.pending_hint(now)
        if h is not None:
            h.answer, h.answered_at = "onBreak", now; self._close("hint")
        s.tapped.append(Tapped(now)); s.note(now, "on a break"); self.save(now)

    def back(self, now: datetime) -> None:
        s = self.session; b = s.open_break() if s else None
        if s is None or b is None:
            return
        b.end, b.ended_by = now, "back"; s.note(now, "back"); self.save(now)

    def answer_hint(self, ans: str, now: datetime, session: WorkSession | None = None, h: Hint | None = None) -> None:
        """snooze | break | ok, from the notification or the menu (the last hint)."""
        s = session or self.session
        if s is None or s is not self.session or ans not in HINT_ANSWERS:
            return
        h = h or (s.hints[-1] if s.hints else None)
        if h is None or h.answer in ("snoozed", "onBreak") or (h.answer and ans != "snooze"):
            return
        if ans == "break":
            self.on_break(now); h.answer, h.answered_at = "onBreak", now
            return
        h.answer, h.answered_at = HINT_ANSWERS[ans], now
        self.hints.write("snoozed" if ans == "snooze" else "dismissed", h.active_min, h.threshold_min,
                         hint=h.event, now=now)
        self._close("hint"); self.save(now)

    def snooze(self, now: datetime) -> None:
        h = self._snoozable(now)
        if h is not None:   # (also after OK: an OK does not stop a later snooze)
            self.answer_hint("snooze", now, self.session, h)

    def answer_question(self, yes: bool, now: datetime, run: Run | None = None) -> None:
        p = self.pending
        if p is None or (run is not None and not same_run(run, p)) or self.session is not None:
            return
        self._close("ask")
        if yes:
            self.start(now, "asked", p); self._label(now, "ask", "yes", p, self.session); self.save(now)
        else:
            self._label(now, "ask", "no", p, None); self.pending = None
            self.blocked_before = now; self.quiet_until = now + timedelta(minutes=self.s.ask_again_min)
            self.log.append(f"{hm(now)} answered: not work")

    def _auto_answer(self, ans: str, now: datetime, s: WorkSession | None) -> None:
        if s is None or s is not self.session:
            return
        if ans == "notwork":
            self.not_work(now)
        elif ans == "ok" and not s.labels:
            self._label(now, "auto", "yes", self._run_of(s), s); self.save(now)

    def not_work(self, now: datetime) -> None:
        """Relabels a session this tray started (asked or by itself): not work; it ends, its file stays."""
        s = self.session
        if s is None or s.started_by == "manual":
            return
        self._label(now, "auto" if s.started_by == "auto" else "ask", "not_work", self._run_of(s), s)
        self.quiet_until = now + timedelta(minutes=self.s.ask_again_min)
        self.stop(now, ended="not_work")

    def quit(self, now: datetime) -> None:
        if self.pending is not None:
            self._label(now, "ask", "none", self.pending, None); self.pending = None
        self.stop(now, ended="quit")

    # --- settings
    def set_setting(self, now: datetime, **kw: object) -> None:
        self.s = replace(self.s, **kw); self.store.save(self.s)
        if self.s.auto_start != "ask" and self.pending is not None:
            self._label(now, "ask", "none", self.pending, None); self.pending = None
        if self.pending is None or not self.s.notifications:
            self._close("ask")

    def set_autostart(self, on: bool, text: str) -> None:
        if self.autostart is not None:
            set_autostart(self.autostart, on, text)

    # --- files
    def save(self, now: datetime) -> None:
        s = self.session
        if s is None:
            return
        self.records.save(s.stamp, s.to_json(self.spans, now, self._cfg().break_min, self.meetings))
        self.last_saved = now

    def resume(self, now: datetime) -> None:
        """At start: a session file left `running` (a crash, a restart) is taken up again if it was written in the
        last 10 minutes; older ones are closed as `lost` at their last written moment."""
        left = self.records.running()
        for i, (stamp, d) in enumerate(left):
            written = _t(d.get("written")) or _t(d.get("end"))
            s = session_from(stamp, d)
            fresh = written is not None and now - written <= timedelta(minutes=RESUME_WITHIN_MIN)
            if s is not None and fresh and i == len(left) - 1 and self.session is None:
                self.session = s; s.note(now, "taken up again after a restart")
                for m in s.meetings:
                    add_meeting(self.meetings, m)
                self.log.append(f"{hm(now)} session from {hm(s.start)} taken up again")
                continue
            d = {**d, "ended": "lost", "end": d.get("written") or d.get("end")}
            self.records.save(stamp, d)

    # --- what the menu shows
    def view(self, now: datetime) -> View:
        lines: list[str] = []; show = {"folder", "quit"}; icon = "idle"
        if self.aw_error:
            lines.append("ActivityWatch is not answering: no detection or hints")
        if self.session is not None:
            icon = self._session_view(now, lines, show)
        else:
            show.add("start")
            if self.pending is not None:
                icon = "attention"; show |= {"yes", "no"}
                lines.append(f"Started working at {hm(self.pending.start)}?")
            else:
                lines.append("Not in a work session")
            r = self.run
            if r is not None and r.now_in and not self.aw_error:
                lines.append(f"In a meeting ({r.app}) for {round(r.work_min)} min" if r.family == "meeting" else
                             f"In work apps for {round(r.work_min)} min (most: {r.app})")
            lines.append(MODE_LINES[self.s.auto_start].format(ask=self.s.ask_after_min, auto=self.s.auto_after_min))
        if self.phone_text:
            lines.append(self.phone_text)
        on = autostart_on(self.autostart) if self.autostart is not None else False
        return View(icon, tuple(lines), frozenset(show), self.s, on)

    def _session_view(self, now: datetime, lines: list[str], show: set[str]) -> str:
        s = self.session; assert s is not None
        show.add("stop"); icon = "working"
        b = s.open_break()
        if s.started_by in ("auto", "asked") and not any(x["label"] == "work" for x in s.labels):
            show.add("notwork")
        if b is not None:
            show.add("back")
            lines.append(f"On a break since {hm(b.start)} ({dur(now - b.start)})")
            lines.append("Hints wait until you are back")
            return "break"
        cfg = self._cfg(); spans = self._spans_cut(now)
        st, active, away_from = bh.session(spans, now, cfg)
        show.add("break")
        if st is None and away_from is not None:
            lines.append(f"Away since {hm(away_from)}: a break ({dur(now - away_from)})")
            icon = "break"
        else:
            lines.append(f"Working since {hm(s.start)} ({dur(now - s.start)})")
        if self.meeting_now is not None:
            m0 = meeting_run(self.meetings, self.meeting_now, now, bh.Config().merge_gap_min).start
            lines.append(f"In a meeting ({self.meeting_now}) since {hm(m0)}")
        h = self.pending_hint(now)
        if h is not None:
            icon = "attention"; show.add("dismiss")
            lines.append(f"Break hint: {round(h.active_min)} min at it. A few minutes away?")
        if self._snoozable(now) is not None:
            show.add("snooze")
        if self.meeting_now is not None:
            lines.append("Break hints wait until the meeting ends")
        elif st is not None:
            lines.append(self._hint_line(now, spans, active))
        return icon

    def _hint_line(self, now: datetime, spans: list[Span], active: float) -> str:
        cfg = self._cfg()
        q = quiet_end(now, cfg.quiet)
        if q is not None:
            return f"Break hints quiet until {hm(q)}"
        t = next_hint_at(now, spans, self.hints.history(), cfg)
        if t is None:
            return "No more break hints today"
        return f"Next break hint about {hm(t)} ({round(active)} min since the last break)"


# ---------- replaying a day (--dry-run) ----------

class QueueNotifier:
    """Shows nothing; answers are queued and given after the tick (as a click would come later)."""

    def __init__(self, policy: dict[str, str | None]):
        self.policy = policy; self.queue: list[tuple[Callable[[str], None], str]] = []
        self.shown: Counter = Counter()

    def show(self, key: str, title: str, body: str, actions: list[tuple[str, str]],
             answer: Callable[[str], None], low: bool = False) -> None:
        self.shown[key] += 1
        a = self.policy.get(key)
        if a is not None:
            self.queue.append((answer, a))

    def close(self, key: str) -> None:
        return None

    def flush(self) -> None:
        q, self.queue = self.queue, []
        for fn, a in q:
            fn(a)


def simulate(afk: list[dict], window: list[dict], start: datetime, end: datetime, s: Settings,
             history: list[bh.Rec] | None = None, step_min: float = 1) -> dict:
    """The tray minute by minute over recorded events, with notifications on, the question answered Yes and the
    auto-start's OK pressed; hints are not answered. Writes nothing. Returns counts and the log lines."""
    note = QueueNotifier({"ask": "yes", "auto": "ok"})
    rec = Records(None)
    tray = WorkTray(Replay(afk, window), note, rec, MemoryHintLog(history))
    tray.s = replace(s, notifications=True)
    t = start
    tray.clock = lambda: t
    while t <= end:
        tray.tick(t); note.flush()
        t += timedelta(minutes=step_min)
    if tray.session is not None:
        tray.stop(end, ended="still running")
    sessions = list(rec.memory.values())

    def minutes(x: dict) -> float:
        return (datetime.fromisoformat(x["end"]) - datetime.fromisoformat(x["start"])).total_seconds() / 60
    return {
        "asked": note.shown["ask"], "auto_started": sum(1 for x in sessions if x["started_by"] == "auto"),
        "sessions": len(sessions), "session_min": round(sum(minutes(x) for x in sessions)),
        "active_min": round(sum(x["active_min"] for x in sessions)),
        "breaks": sum(len(x["breaks"]) for x in sessions),
        "ended_by_away": sum(1 for x in sessions if x["ended"] == "away"),
        "hints": sum(len(x["hints"]) for x in sessions),
        "hints_taken": sum(1 for x in sessions for h in x["hints"] if h["taken"]),
        "log": tray.log}
