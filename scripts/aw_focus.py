"""ActivityWatch focus sessions for the Sharp-hours log (the laptop's part: DECISIONS rows 289, 510-514).

usage: aw_focus.py [--since 7d|YYYY-MM-DD] [--until YYYY-MM-DD] [--dry-run] [--dest _local] [--show] [--json]

Reads ActivityWatch's window and AFK buckets (localhost:5600, this host), finds FOCUS SESSIONS, and writes the counts
per day and per 2-hour block to <dest>/phone/sharp-hours/focus-YYYY-MM.jsonl, beside the phone's ratings.jsonl.

A focus session (the research's third measure, after Brown 2023 at Google: the NUMBER of sessions of related work
tracked self-reported focus, total hours did not, so hours are never summed here):
- time counts only while you are not AFK; an AFK gap of 5 min or more is a real break and ends the session
  (break_hints.py's rule); gaps under 5 min only pause the clock;
- "related" = the same family of windows: terminals, editors, IDEs, AI-assistant windows (Claude, ChatGPT: the
  owner codes with them open) and browser pages whose title names documentation or code hosting are one family
  ("code"); writing and reading apps are another ("write");
  anything else (browser, chat, video, games) is its own app and is not work, unless --any-app;
- a short switch to something else is allowed: up to 3 min away in total between two stretches of the family
  (a quick chat reply does not end a session); a longer one ends it;
- a session is at least 35 min of active time (Brown: 35 min close, 60 min best); a longer run is still ONE session;
- a session belongs to the day (04:00-04:00, as the app's day) and the 2-hour block of the clock it STARTED in.

Window titles are read in memory to tell documentation from other browsing and are never stored: the file holds
counts, start times, minutes and the app name that held most of the session. Re-running is safe: every day in the
range is recomputed and replaces its own line; other lines stay; unchanged data gives a byte-identical file.
Nothing leaves the laptop. --show prints the sessions beside the phone's sharp-hours ratings, per 2-hour block
("seen together, not tested"). Standard library only; format in docs/data-format.md, rules in docs/break-hints.md.
"""
from __future__ import annotations

import argparse, bisect, json, os, re, socket, sys, urllib.error, urllib.parse
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, tzinfo
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import break_hints as bh  # noqa: E402  (its reading code and rules: AFK spans, the 04:00 day, the 5 min break)

DEST = Path(__file__).resolve().parents[1] / "_local"
RULE = "focus-v1"
VERSION = 1

# ---------- the choice of "related" (a planning rule; edit here) ----------

# family -> words that appear in an app's name (split at . - _ and spaces; whole words only)
FAMILIES: dict[str, frozenset[str]] = {
    "code": frozenset("""ghostty kitty alacritty konsole xterm wezterm terminator tilix foot terminal gnome-terminal
        code vscode vscodium codium cursor zed idea pycharm clion webstorm goland rider jetbrains studio intellij
        vim nvim neovim emacs sublime kate gedit geany meld claude chatgpt copilot""".split()),
    "write": frozenset("""libreoffice soffice obsidian notion zotero okular evince typora onlyoffice logseq joplin
        texstudio lyx xournalpp writer calc impress""".split()),
    "browser": frozenset("firefox chrome chromium brave vivaldi librewolf epiphany zen opera".split()),
}
WORK_FAMILIES = ("code", "write")
# a browser page whose title has one of these is documentation or code hosting: it belongs to "code"
DOC_WORDS = ("github", "gitlab", "stack overflow", "stackoverflow", "docs", "documentation", "mdn web", "readthedocs",
             "pypi", "crates.io", "docs.rs", "arxiv", "api reference", "dart.dev", "pub.dev", "flutter", "developer.",
             "huggingface", "man page", "manual")


@dataclass(frozen=True)
class FocusConfig:
    min_min: float = 35        # active minutes for a session (Brown 2023: 35 close, 60 best)
    switch_min: float = 3      # active minutes away from the family allowed inside a session
    any_app: bool = False      # count runs in any app, not only the work families


def family(app: str, title: str = "") -> str:
    words = set(re.split(r"[.\-_\s]+", (app or "").lower()))
    fam = next((f for f, names in FAMILIES.items() if words & names), None)
    if fam == "browser" and any(w in (title or "").lower() for w in DOC_WORDS):
        return "code"
    return fam or ((app or "unknown").lower())


# ---------- pure logic (no clock, no network; tested in analysis/tests/test_aw_focus.py) ----------

@dataclass
class Seg:
    start: datetime
    end: datetime
    fam: str
    apps: Counter = field(default_factory=Counter)   # app name -> active seconds

    @property
    def active_min(self) -> float:
        return sum(self.apps.values()) / 60


@dataclass(frozen=True)
class Session:
    start: datetime
    end: datetime
    active_min: float
    app: str            # the app that held most of it
    fam: str


def segments(window_events: list[dict], spans: list[tuple[datetime, datetime]],
             lo: datetime | None = None, hi: datetime | None = None) -> list[Seg]:
    """Window events cut to the not-AFK spans (the window watcher keeps writing while you are away), by family;
    neighbours of one family closer than a real break are joined. Titles are used here and go no further."""
    ends = [b for _, b in spans]
    pieces: list[tuple[datetime, datetime, str, str]] = []
    for e in window_events:
        a = bh.parse_ts(e["timestamp"]); b = a + timedelta(seconds=float(e.get("duration") or 0))
        data = e.get("data") or {}
        fam = family(str(data.get("app") or "unknown"), str(data.get("title") or ""))
        for i in range(bisect.bisect_right(ends, a), len(spans)):
            s0, s1 = spans[i]
            if s0 >= b:
                break
            x, y = max(a, s0, lo or a), min(b, s1, hi or b)
            if y > x:
                pieces.append((x, y, fam, str(data.get("app") or "unknown")))
    pieces.sort(key=lambda p: p[:2])
    out: list[Seg] = []
    brk = timedelta(minutes=bh.Config().break_min)
    for x, y, fam, app in pieces:
        if out and out[-1].fam == fam and x - out[-1].end < brk:
            out[-1].end = max(out[-1].end, y)
        else:
            out.append(Seg(x, y, fam))
        out[-1].apps[app] += (y - x).total_seconds()
    return out


def _next_in_family(segs: list[Seg], j: int, cfg: FocusConfig) -> int | None:
    """The next stretch of segs[j]'s family if only a short switch (<= switch_min active) and no real break lies
    between, else None."""
    brk = timedelta(minutes=bh.Config().break_min); away = 0.0
    for k in range(j + 1, len(segs)):
        if segs[k].start - segs[k - 1].end >= brk:
            return None
        if segs[k].fam == segs[j].fam:
            return k
        away += segs[k].active_min
        if away > cfg.switch_min:
            return None
    return None


def runs(segs: list[Seg], cfg: FocusConfig = FocusConfig()) -> list[list[Seg]]:
    """The segments cut into runs: a run is one family's stretches joined across short switches (switch_min) with no
    real break; the switches in between are part of the run. Every segment is in exactly one run, in order.
    (Also the laptop tray's work detection, scripts/laptop_work.py.)"""
    out: list[list[Seg]] = []; i = 0
    while i < len(segs):
        j = i
        while (k := _next_in_family(segs, j, cfg)) is not None:
            j = k
        out.append(segs[i:j + 1])
        i = j + 1
    return out


def find_sessions(segs: list[Seg], cfg: FocusConfig = FocusConfig()) -> list[Session]:
    out: list[Session] = []
    for run in runs(segs, cfg):
        active = sum(s.active_min for s in run)
        if active >= cfg.min_min and (cfg.any_app or run[0].fam in WORK_FAMILIES):
            apps: Counter = Counter()
            for s in run:
                apps.update(s.apps)
            out.append(Session(run[0].start, run[-1].end, active, apps.most_common(1)[0][0], run[0].fam))
    return out


def day_of(t: datetime, tz: tzinfo | None) -> date:
    return bh.day_key(t.astimezone(tz))


def block_of(t: datetime, tz: tzinfo | None) -> str:
    h = t.astimezone(tz).hour // 2 * 2
    return f"{h:02d}-{h + 2:02d}"


def day_records(segs: list[Seg], sessions: list[Session], cfg: FocusConfig, tz: tzinfo | None,
                first_day: date | None = None) -> dict[str, dict]:
    """One record per day with enough laptop time to show a session (a day under min_min of active time says
    nothing when it has none). `through` is the last moment of data that day: the day may still be going on."""
    active: Counter = Counter(); through: dict[date, datetime] = {}
    for s in segs:
        d = day_of(s.start, tz); active[d] += s.active_min
        through[d] = max(through.get(d, s.end), s.end)
    recs: dict[date, dict] = {}
    for d, minutes in active.items():
        if minutes >= cfg.min_min and (first_day is None or d >= first_day):
            recs[d] = dict(version=VERSION, day=d.isoformat(), sessions=0, blocks={}, list=[],
                           through=through[d].astimezone(tz).isoformat(timespec="seconds"),
                           rule=f"{RULE} min={cfg.min_min:g} switch={cfg.switch_min:g}"
                                + (" any-app" if cfg.any_app else ""))
    for s in sorted(sessions, key=lambda s: s.start):
        r = recs.get(day_of(s.start, tz))
        if r is None:
            continue
        r["sessions"] += 1
        b = block_of(s.start, tz); r["blocks"][b] = r["blocks"].get(b, 0) + 1
        r["list"].append(dict(start=s.start.astimezone(tz).isoformat(timespec="seconds"),
                              min=round(s.active_min), app=s.app))
    return {d.isoformat(): r for d, r in sorted(recs.items())}


# ---------- the files ----------

def month_file(dest: Path, day: str) -> Path:
    return dest / "phone" / "sharp-hours" / f"focus-{day[:7]}.jsonl"


def read_days(path: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue   # a line cut off by a crash
            if isinstance(r, dict) and isinstance(r.get("day"), str):
                out[r["day"]] = r
    return out


def write_days(dest: Path, recs: dict[str, dict]) -> list[Path]:
    """Replace each day's line in its month's file; keep every other line. Written under a temporary name, then
    renamed. Returns the files whose content changed."""
    changed: list[Path] = []
    for month in sorted({d[:7] for d in recs}):
        path = month_file(dest, month + "-01"); have = read_days(path)
        have.update({d: r for d, r in recs.items() if d[:7] == month})
        text = "".join(json.dumps(have[d], ensure_ascii=False, separators=(",", ":")) + "\n" for d in sorted(have))
        if path.exists() and path.read_text(encoding="utf-8") == text:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp"); tmp.write_text(text, encoding="utf-8"); os.replace(tmp, path)
        changed.append(path)
    return changed


# ---------- ActivityWatch ----------

class NoActivityWatch(Exception):
    pass


def pick_bucket(prefix: str, host: str) -> str:
    try:
        names = [b for b in bh.aw_get("/buckets/") if b.startswith(prefix + "_")]
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise NoActivityWatch(f"ActivityWatch is not reachable at {bh.AW} ({e})") from e
    if not names:
        raise NoActivityWatch(f"no {prefix} bucket (is {prefix} running?)")
    return next((b for b in names if b == f"{prefix}_{host}"), sorted(names)[0])


def fetch(bucket: str, start: datetime, end: datetime) -> list[dict]:
    """Events of a bucket, a day at a time (long ranges stay light); an event on a seam is read once."""
    seen: set = set(); out: list[dict] = []; t = start
    while t < end:
        for e in bh.afk_events(bucket, t, min(end, t + timedelta(days=1))):   # (works on any bucket)
            key = e.get("id", (e["timestamp"], e.get("duration")))
            if key not in seen:
                seen.add(key); out.append(e)
        t += timedelta(days=1)
    return out


def compute(window: list[dict], afk: list[dict], cfg: FocusConfig, tz: tzinfo | None, lo: datetime, hi: datetime,
            first_day: date) -> dict[str, dict]:
    spans = [(max(a, lo), min(b, hi)) for a, b in bh.active_spans(afk, bh.Config().merge_gap_min)]
    segs = segments(window, [s for s in spans if s[1] > s[0]], lo, hi)
    sessions = [s for s in find_sessions(segs, cfg) if s.start > lo]   # one cut by the start of the range is unknown
    return day_records(segs, sessions, cfg, tz, first_day)


# ---------- the view: sessions beside the ratings ----------

def read_ratings(dest: Path) -> list[tuple[date, str, float]]:
    """(day, 2-hour block, sharp) of each rating, by the local time it was written with."""
    f = dest / "phone" / "sharp-hours" / "ratings.jsonl"; out = []
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            try:
                r = json.loads(line); t = datetime.fromisoformat(r["at"]); v = float(r["sharp"])
            except (json.JSONDecodeError, KeyError, ValueError, TypeError):
                continue
            out.append((bh.day_key(t), block_of(t, t.tzinfo), v))
    return out


def read_focus(dest: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for f in sorted((dest / "phone" / "sharp-hours").glob("focus-*.jsonl")):
        out.update(read_days(f))
    return out


BLOCKS = [f"{h:02d}-{h + 2:02d}" for h in range(0, 24, 2)]


def block_table(ratings: list[tuple[date, str, float]], focus: dict[str, dict]) -> dict:
    """Per 2-hour block: ratings (count, mean) and focus sessions (total, per laptop day), over the days that have
    laptop data; with ratings imported, over the days that have both."""
    days = set(focus)
    if ratings:
        days &= {d.isoformat() for d, _, _ in ratings}
    rows = []
    for b in BLOCKS:
        vals = [v for d, bb, v in ratings if bb == b and d.isoformat() in days]
        n = sum(focus[d]["blocks"].get(b, 0) for d in days)
        rows.append(dict(block=b, ratings=len(vals), mean=round(sum(vals) / len(vals), 2) if vals else None,
                         sessions=n, per_day=round(n / len(days), 2) if days else None))
    return dict(days=len(days), ratings_imported=bool(ratings), rows=rows)


def show_lines(t: dict) -> list[str]:
    if not t["days"]:
        return ["No days with laptop focus data" + (" that also have ratings." if t["ratings_imported"] else
                " yet: run aw_focus.py first.")]
    head = ("over the %d days with both ratings and laptop data" if t["ratings_imported"] else
            "over the %d days with laptop data (no sharp-hours ratings imported yet)") % t["days"]
    lines = [f"Focus sessions (35+ min of related work, counted, never summed as hours) {head}",
             "block  | ratings  mean | focus sessions  per day", "-------+---------------+----------------------"]
    for r in t["rows"]:
        if r["ratings"] or r["sessions"]:
            m = "-" if r["mean"] is None else f"{r['mean']:.2f}"
            lines.append(f" {r['block']} | {r['ratings']:>7}  {m:>4} | {r['sessions']:>14}  {r['per_day']:>7.2f}")
    return lines + ["Seen together, not tested: a block with more sessions is not a sharper block."]


# ---------- running ----------

def parse_since(s: str, today: date) -> date:
    m = re.fullmatch(r"(\d+)d", s)
    return today - timedelta(days=int(m.group(1))) if m else date.fromisoformat(s)


def summary(recs: dict[str, dict]) -> list[str]:
    lines = [f"{d}  {r['sessions']} session(s)  " + "  ".join(f"{b}:{n}" for b, n in sorted(r["blocks"].items()))
             for d, r in recs.items()]
    return lines + [f"{len(recs)} day(s) with laptop data, {sum(r['sessions'] for r in recs.values())} session(s)"]


def main(argv: list[str] | None = None, out: Callable[[str], object] = print, now: datetime | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--since", default="7d", help="first day to (re)compute: N days back (7d) or YYYY-MM-DD")
    ap.add_argument("--until", help="last day to compute, YYYY-MM-DD (default: now)")
    ap.add_argument("--dest", type=Path, default=DEST, help="the laptop's _local folder (default: <repo>/_local)")
    ap.add_argument("--host", default=socket.gethostname(), help="whose buckets to read (default: this host)")
    ap.add_argument("--url", help="ActivityWatch API (default http://localhost:5600/api/0)")
    ap.add_argument("--min", type=float, default=FocusConfig.min_min, dest="min_min", help="session minutes (35)")
    ap.add_argument("--switch", type=float, default=FocusConfig.switch_min, help="short switch allowed, minutes (3)")
    ap.add_argument("--any-app", action="store_true", help="count a run in any app, not only terminals/editors/writing")
    ap.add_argument("--dry-run", action="store_true", help="work it out and print it; write nothing")
    ap.add_argument("--show", action="store_true", help="print the written sessions beside the ratings; no ActivityWatch")
    ap.add_argument("--json", action="store_true", help="with --show: JSON instead of text")
    a = ap.parse_args(argv)
    if a.show:
        t = block_table(read_ratings(a.dest), read_focus(a.dest))
        out(json.dumps(t) if a.json else "\n".join(show_lines(t)))
        return 0
    if a.url:
        bh.AW = a.url
    cfg = FocusConfig(a.min_min, a.switch, a.any_app)
    tz = None if now is None else now.tzinfo      # None: the computer's own zone at each moment
    now = now or datetime.now().astimezone()
    try:
        first = parse_since(a.since, now.date())
        last = date.fromisoformat(a.until) if a.until else None
    except ValueError:
        ap.error("--since / --until: use 7d or YYYY-MM-DD")
    lo = datetime.combine(first, datetime.min.time(), now.tzinfo) + timedelta(hours=bh.DAY_START_H - 12)
    hi = now if last is None else datetime.combine(last + timedelta(days=1), datetime.min.time(), now.tzinfo) \
        + timedelta(hours=bh.DAY_START_H)
    try:
        wb = pick_bucket("aw-watcher-window", a.host); ab = pick_bucket("aw-watcher-afk", a.host)
        window, afk = fetch(wb, lo, min(hi, now)), fetch(ab, lo, min(hi, now))
    except NoActivityWatch as e:
        out(f"aw_focus: {e}")
        return 1
    except (urllib.error.URLError, OSError, ValueError) as e:
        out(f"aw_focus: ActivityWatch stopped answering ({e})")
        return 1
    recs = compute(window, afk, cfg, tz, lo, min(hi, now), first)
    if last is not None:
        recs = {d: r for d, r in recs.items() if date.fromisoformat(d) <= last}
    if not recs:
        out("aw_focus: no laptop activity in that range (nothing to count)")
        return 0
    out("\n".join(summary(recs)))
    if a.dry_run:
        out("dry run: nothing written")
        return 0
    for f in write_days(a.dest, recs):
        out(f"wrote {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
