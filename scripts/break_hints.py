"""Soft "take a break" hints from ActivityWatch (stage 0: no headband).

usage: break_hints.py [--threshold 60] [--quiet 23:00-08:00] [--dry-run] [--test-notify]

Every minute it reads ActivityWatch's AFK bucket, works out how long you have been active without a real
break, and after the threshold shows one soft desktop notification. At most 4 a day, at least 45 min apart,
+15 min to the threshold after each hint that did not lead to a break, nothing in quiet hours. An AFK stretch
of 5 min or more resets the count. Each hint and what followed it is written as a `break_hint` event to
<root>/events/<dev>/breaks-YYYY-MM.jsonl (docs/data-format.md). Standard library only.
How to install and change settings: docs/break-hints.md.
"""
import argparse, hashlib, json, shutil, socket, subprocess, sys, threading, time, urllib.parse, urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, time as dtime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_events import device_id, zone_name  # noqa: E402

AW = "http://localhost:5600/api/0"
ROOT = Path(__file__).resolve().parents[1] / "_local" / "export"
DAY_START_H = 4  # a "day" runs 04:00-04:00 local, so working past midnight does not reset the daily cap


@dataclass(frozen=True)
class Config:
    threshold_min: float = 60      # active minutes before the first hint (50-90)
    max_per_day: int = 4
    min_gap_min: float = 45        # between two hints
    backoff_min: float = 15        # added to the threshold for each hint today that led to no break
    quiet: str = "23:00-08:00"     # "off" for none
    merge_gap_min: float = 3       # AFK gaps shorter than this count as active time
    break_min: float = 5           # AFK this long resets the count (a real break)
    taken_window_min: float = 30   # a break starting this soon after a hint counts as "taken"
    snooze_min: float = 20


@dataclass(frozen=True)
class Rec:
    """One break_hint event, as the decision logic needs it."""
    ts: datetime
    kind: str          # shown | snoozed | dismissed | taken
    id: str
    hint: str | None = None   # for snoozed / dismissed / taken: the id of the shown hint


@dataclass(frozen=True)
class Decision:
    show: bool
    reason: str
    active_min: float
    threshold_min: float


# ---------- pure logic (no clock, no network; tested in analysis/tests/test_break_hints.py) ----------

def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def active_spans(afk_events: list[dict], merge_gap_min: float) -> list[tuple[datetime, datetime]]:
    """Not-afk intervals from ActivityWatch AFK events, sorted, with gaps under merge_gap_min joined."""
    iv = []
    for e in afk_events:
        if (e.get("data") or {}).get("status") != "not-afk":
            continue
        a = parse_ts(e["timestamp"]); iv.append((a, a + timedelta(seconds=float(e.get("duration") or 0))))
    iv.sort()
    out: list[list[datetime]] = []
    gap = timedelta(minutes=merge_gap_min)
    for a, b in iv:
        if out and a - out[-1][1] < gap:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def session(spans: list[tuple[datetime, datetime]], now: datetime, cfg: Config):
    """(start, active_min, last_break_start) of the activity going on at `now`.

    Spans are joined across AFK gaps shorter than break_min; only the active time counts, so a 3-5 min gap
    pauses the count without resetting it. If `now` is break_min or more after the last activity, you are on
    a break: start is None, active_min 0 and last_break_start is when that break began.
    """
    spans = [(a, min(b, now)) for a, b in spans if a <= now]
    brk = timedelta(minutes=cfg.break_min)
    if not spans:
        return None, 0.0, None
    if now - spans[-1][1] >= brk:
        return None, 0.0, spans[-1][1]
    i = len(spans) - 1
    while i > 0 and spans[i][0] - spans[i - 1][1] < brk:
        i -= 1
    active = sum((b - a).total_seconds() for a, b in spans[i:]) / 60
    last_break = spans[i - 1][1] if i > 0 else None
    return spans[i][0], active, last_break


def day_key(t: datetime):
    return (t - timedelta(hours=DAY_START_H)).date()


def in_quiet(t: datetime, quiet: str) -> bool:
    if quiet in ("", "off", "none"):
        return False
    a, b = (dtime.fromisoformat(x.strip()) for x in quiet.split("-"))
    x = t.timetz().replace(tzinfo=None)
    return a <= x < b if a <= b else (x >= a or x < b)


def no_break_after(hint: Rec, history: list[Rec]) -> bool:
    return not any(r.kind == "taken" and r.hint == hint.id for r in history)


def threshold_now(now: datetime, history: list[Rec], cfg: Config) -> float:
    """Base threshold (clamped to 50-90) + back-off for each of today's hints that led to no break.

    A hint counts once it was snoozed, or once its window for a break has closed."""
    base = min(max(cfg.threshold_min, 50), 90)
    today = [r for r in history if day_key(r.ts) == day_key(now)]
    snoozed = {r.hint for r in today if r.kind == "snoozed"}
    n = sum(1 for r in today if r.kind == "shown" and no_break_after(r, history)
            and (r.id in snoozed or now - r.ts > timedelta(minutes=cfg.taken_window_min)))
    return base + cfg.backoff_min * n


def decide(now: datetime, spans, history: list[Rec], cfg: Config) -> Decision:
    """Show a hint now? `history` holds earlier break_hint events (any days)."""
    start, active, _ = session(spans, now, cfg)
    thr = threshold_now(now, history, cfg)
    d = lambda show, why: Decision(show, why, round(active, 1), thr)  # noqa: E731
    if start is None:
        return d(False, "on a break")
    if in_quiet(now, cfg.quiet):
        return d(False, "quiet hours")
    today = [r for r in history if day_key(r.ts) == day_key(now)]
    shown = [r for r in today if r.kind == "shown"]
    if len(shown) >= cfg.max_per_day:
        return d(False, "daily cap reached")
    last = max(shown, key=lambda r: r.ts) if shown else None
    # A snooze asks for one more hint snooze_min later: the user's own request, so the 45-min spacing
    # does not apply, but the cap, quiet hours and a break in between (session restarted) do.
    if last:
        sn = [r for r in today if r.kind == "snoozed" and r.hint == last.id]
        if sn:
            due = sn[-1].ts + timedelta(minutes=cfg.snooze_min)
            if sn[-1].ts >= start and now >= due:
                return d(True, "snooze over")
    if active < thr:
        return d(False, "below threshold")
    if last and now - last.ts < timedelta(minutes=cfg.min_gap_min):
        return d(False, "too soon after last hint")
    return d(True, "threshold reached")


def breaks_taken(now: datetime, spans, history: list[Rec], cfg: Config) -> list[Rec]:
    """Shown hints that a real break (AFK >= break_min) followed within taken_window_min, not yet recorded."""
    start, _, brk = session(spans, now, cfg)
    if brk is None:  # (if start is set, brk is the break before this session: still counts if it was missed)
        return []
    win = timedelta(minutes=cfg.taken_window_min); slack = timedelta(minutes=cfg.merge_gap_min)
    done = {r.hint for r in history if r.kind == "taken"}
    return [r for r in history if r.kind == "shown" and r.id not in done
            and r.ts - slack <= brk <= r.ts + win and r.ts <= now]


# ---------- events file ----------

def read_history(folder: Path) -> list[Rec]:
    out = []
    for f in sorted(folder.glob("breaks-*.jsonl"))[-2:]:
        for line in f.read_text(encoding="utf-8").splitlines(keepends=True):
            if not line.endswith("\n"):
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("type") == "break_hint":
                out.append(Rec(parse_ts(e["ts"]), e["data"]["kind"], e["id"], e["data"].get("hint")))
    return out


def next_seq(folder: Path) -> int:
    seq = 0
    for f in folder.glob("*.jsonl"):
        for line in f.read_text(encoding="utf-8").splitlines(keepends=True):
            if line.endswith("\n"):
                try: seq = max(seq, int(json.loads(line).get("seq", 0)))
                except (json.JSONDecodeError, ValueError, TypeError): pass
    return seq + 1


class Log:
    def __init__(self, root: Path):
        self.dev = device_id(root); self.folder = root / "events" / self.dev
        self.folder.mkdir(parents=True, exist_ok=True); self.lock = threading.Lock()

    def write(self, kind: str, active_min: float, threshold_min: float, hint: str | None = None,
              now: datetime | None = None) -> Rec:
        now = (now or datetime.now().astimezone()).replace(microsecond=0)
        ts = now.isoformat(timespec="seconds")
        data = dict(kind=kind, active_min=round(active_min, 1), threshold_min=threshold_min)
        if hint:
            data["hint"] = hint
        eid = "eeg:" + hashlib.sha1(f"{self.dev}|break_hint|{ts}|{kind}|{hint}".encode()).hexdigest()
        with self.lock:
            ev = dict(v=1, id=eid, dev=self.dev, seq=next_seq(self.folder), ts=ts, tz=zone_name(),
                      type="break_hint", data=data)
            with open(self.folder / f"breaks-{now:%Y-%m}.jsonl", "a", encoding="utf-8") as out:
                out.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
        print(f"{ts} {kind} active={data['active_min']} threshold={threshold_min}", flush=True)
        return Rec(now, kind, eid, hint)


# ---------- ActivityWatch ----------

def aw_get(path: str, **params) -> object:
    url = AW + path + ("?" + urllib.parse.urlencode(params) if params else "")
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def afk_bucket() -> str:
    names = [b for b in aw_get("/buckets/") if b.startswith("aw-watcher-afk_")]
    if not names:
        raise RuntimeError("no aw-watcher-afk bucket (is aw-watcher-afk running?)")
    host = socket.gethostname()
    return next((b for b in names if b == f"aw-watcher-afk_{host}"), sorted(names)[0])


def afk_events(bucket: str, start: datetime, end: datetime) -> list[dict]:
    return aw_get(f"/buckets/{urllib.parse.quote(bucket)}/events",
                  start=start.isoformat(), end=end.isoformat(), limit=-1)


# ---------- notifications ----------

def notify_has_actions() -> bool:
    if not shutil.which("notify-send"):
        return False
    try:
        h = subprocess.run(["notify-send", "--help"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "--action" in h and "--wait" in h


def notify(active_min: float, on_answer=None, actions: bool = True) -> None:
    """Show the hint. With actions, waits (in a thread) for Snooze / OK and calls on_answer("snooze"|"ok")."""
    body = f"You've been at it for {round(active_min)} min. A few minutes away from the screen?"
    cmd = ["notify-send", "-u", "low", "-a", "Break hint", "-i", "face-smile"]
    if not shutil.which("notify-send"):
        print("notify-send not found; hint:", body, flush=True); return
    if not actions:
        subprocess.run(cmd + ["A short break?", body], timeout=10); return

    def run():
        try:
            p = subprocess.run(cmd + ["--wait", "--action=snooze=Snooze 20 min", "--action=ok=OK",
                                      "A short break?", body], capture_output=True, text=True, timeout=1800)
            ans = p.stdout.strip()
        except subprocess.TimeoutExpired:
            ans = ""
        if ans in ("snooze", "ok") and on_answer:
            on_answer(ans)
    threading.Thread(target=run, daemon=True).start()


# ---------- running ----------

def run(cfg: Config, root: Path, poll_s: float) -> None:
    log = Log(root); actions = notify_has_actions(); bucket = None; warned = False
    print(f"break hints: threshold {cfg.threshold_min} min, quiet {cfg.quiet}, actions={'yes' if actions else 'no'},"
          f" events -> {log.folder}", flush=True)
    while True:
        now = datetime.now().astimezone()
        try:
            bucket = bucket or afk_bucket()
            spans = active_spans(afk_events(bucket, now - timedelta(hours=12), now), cfg.merge_gap_min)
            warned = False
        except Exception as e:  # ActivityWatch not running yet, or restarting: try again next minute
            if not warned:
                print(f"{now:%H:%M} ActivityWatch not reachable: {e}", flush=True); warned = True
            bucket = None; time.sleep(poll_s); continue
        hist = read_history(log.folder)
        for h in breaks_taken(now, spans, hist, cfg):
            log.write("taken", 0, threshold_now(now, hist, cfg), hint=h.id)
        hist = read_history(log.folder)
        d = decide(now, spans, hist, cfg)
        if d.show:
            shown = log.write("shown", d.active_min, d.threshold_min)

            def answer(ans, shown=shown, d=d):
                log.write("snoozed" if ans == "snooze" else "dismissed", d.active_min, d.threshold_min, hint=shown.id)
            notify(d.active_min, answer, actions)
        time.sleep(poll_s)


def simulate(afk: list[dict], cfg: Config, start: datetime, end: datetime, step_min: float = 1) -> list[str]:
    """Replay the decision logic minute by minute over recorded AFK events; nobody clicks anything."""
    spans = active_spans(afk, cfg.merge_gap_min); hist: list[Rec] = []; lines = []; last_reason = None
    t = start; n = 0
    while t <= end:
        for h in breaks_taken(t, spans, hist, cfg):
            n += 1; hist.append(Rec(t, "taken", f"sim{n}", h.id))
            lines.append(f"{t:%a %H:%M}  break taken after the {h.ts:%H:%M} hint")
        d = decide(t, spans, hist, cfg)
        if d.show:
            n += 1; hist.append(Rec(t, "shown", f"sim{n}"))
            lines.append(f"{t:%a %H:%M}  HINT  active {d.active_min:g} min, threshold {d.threshold_min:g} ({d.reason})")
        elif d.reason != last_reason and d.reason not in ("below threshold", "on a break", "too soon after last hint"):
            lines.append(f"{t:%a %H:%M}  no hint: {d.reason} (active {d.active_min:g} min)")
        last_reason = d.reason
        t += timedelta(minutes=step_min)
    shown = sum(1 for r in hist if r.kind == "shown"); taken = sum(1 for r in hist if r.kind == "taken")
    lines.append(f"{shown} hint(s), {taken} followed by a break of {cfg.break_min:g}+ min")
    return lines


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--threshold", type=float, default=60, help="active minutes before a hint, 50-90 (default 60)")
    ap.add_argument("--quiet", default="23:00-08:00", help='no hints in these hours, or "off"')
    ap.add_argument("--max-per-day", type=int, default=4)
    ap.add_argument("--root", type=Path, default=ROOT, help="export folder (default: <repo>/_local/export)")
    ap.add_argument("--poll", type=float, default=60, help="seconds between checks")
    ap.add_argument("--dry-run", action="store_true", help="print what would have happened over the last day")
    ap.add_argument("--afk-json", type=Path, help="with --dry-run: read AFK events from this file, not ActivityWatch")
    ap.add_argument("--test-notify", action="store_true", help="show one sample notification and exit")
    a = ap.parse_args()
    if not 50 <= a.threshold <= 90:
        ap.error("--threshold must be between 50 and 90")
    cfg = Config(threshold_min=a.threshold, quiet=a.quiet, max_per_day=a.max_per_day)
    if a.test_notify:
        has = notify_has_actions(); print("actions supported:", has)
        done = threading.Event()
        notify(75, lambda ans: (print("answer:", ans), done.set()), has)
        if has:
            done.wait(60)
        return
    if a.dry_run:
        now = datetime.now().astimezone()
        if a.afk_json:
            afk = json.loads(a.afk_json.read_text())
            ends = [parse_ts(e["timestamp"]) + timedelta(seconds=float(e.get("duration") or 0)) for e in afk]
            now = max(ends).astimezone() if ends else now
        else:
            afk = afk_events(afk_bucket(), now - timedelta(hours=36), now)
        print("\n".join(simulate(afk, cfg, now - timedelta(hours=24), now)))
        return
    run(cfg, a.root, a.poll)


if __name__ == "__main__":
    main()
