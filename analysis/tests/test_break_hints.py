"""Decision logic of scripts/break_hints.py over made-up AFK events and a fixed clock (no network)."""
import json, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import break_hints as bh  # noqa: E402
from break_hints import Config, Rec  # noqa: E402

TZ = timezone(timedelta(hours=3))
DAY = datetime(2026, 11, 18, 9, 0, tzinfo=TZ)
CFG = Config()


def at(h: int, m: int = 0) -> datetime:
    return DAY.replace(hour=h, minute=m)


def ev(start: datetime, minutes: float, status: str = "not-afk") -> dict:
    return {"timestamp": start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            "duration": minutes * 60, "data": {"status": status}}


def work(*blocks) -> list:
    """blocks of (start, minutes) not-afk, with afk events filling the holes (as ActivityWatch writes them)."""
    out = []
    for i, (s, m) in enumerate(blocks):
        out.append(ev(s, m))
        if i + 1 < len(blocks):
            nxt = blocks[i + 1][0]; end = s + timedelta(minutes=m)
            out.append(ev(end, (nxt - end).total_seconds() / 60, "afk"))
    return out


def spans(*blocks):
    return bh.active_spans(work(*blocks), CFG.merge_gap_min)


# ---- continuous activity ----

def test_short_gaps_are_merged_and_counted():
    sp = spans((at(9), 30), (at(9, 32), 30))          # 2 min gap: merged, counted as active
    assert len(sp) == 1
    _, active, _ = bh.session(sp, at(10, 2), CFG)
    assert active == 62


def test_medium_gap_pauses_but_does_not_reset():
    sp = spans((at(9), 30), (at(9, 34), 30))          # 4 min gap: not merged, not a break
    assert len(sp) == 2
    start, active, _ = bh.session(sp, at(10, 4), CFG)
    assert start == at(9) and active == 60


def test_break_of_five_minutes_resets():
    sp = spans((at(9), 50), (at(9, 55), 20))          # 5 min AFK
    start, active, last_break = bh.session(sp, at(10, 15), CFG)
    assert start == at(9, 55) and active == 20 and last_break == at(9, 50)


def test_on_break_now():
    sp = spans((at(9), 70))
    start, active, last_break = bh.session(sp, at(10, 16), CFG)
    assert start is None and active == 0 and last_break == at(10, 10)
    assert bh.decide(at(10, 16), sp, [], CFG).reason == "on a break"


def test_afk_events_ignored_and_unsorted_input():
    raw = [ev(at(9, 30), 30), ev(at(9), 30, "afk"), ev(at(9), 29)]
    sp = bh.active_spans(raw, CFG.merge_gap_min)
    assert sp == [(at(9), at(10))]


# ---- threshold, cap, spacing, back-off ----

def test_hint_at_threshold():
    sp = spans((at(9), 120))
    assert not bh.decide(at(9, 59), sp, [], CFG).show
    d = bh.decide(at(10), sp, [], CFG)
    assert d.show and d.active_min == 60 and d.threshold_min == 60


def test_threshold_is_clamped():
    assert bh.threshold_now(at(10), [], Config(threshold_min=30)) == 50
    assert bh.threshold_now(at(10), [], Config(threshold_min=200)) == 90


def test_spacing_and_backoff():
    sp = spans((at(9), 300))
    h = [Rec(at(10), "shown", "h1")]
    # within the break window: no back-off yet, and too soon anyway
    d = bh.decide(at(10, 20), sp, h, CFG)
    assert not d.show and d.threshold_min == 60
    # window closed with no break: threshold 75; spacing says not before 10:45
    d = bh.decide(at(10, 44), sp, h, CFG)
    assert not d.show and d.threshold_min == 75 and d.reason == "too soon after last hint"
    assert bh.decide(at(10, 45), sp, h, CFG).show


def test_backoff_pushes_past_spacing():
    sp = spans((at(9), 300))
    h = [Rec(at(10), "shown", "h1"), Rec(at(10, 45), "shown", "h2")]
    d = bh.decide(at(11, 30), sp, h, CFG)            # threshold 90 now, active 150: spacing is the limit
    assert d.threshold_min == 90 and d.show
    sp2 = spans((at(11, 0), 100))                     # new session after a break: 90 needed
    assert not bh.decide(at(12, 19), sp2, h, CFG).show
    assert bh.decide(at(12, 30), sp2, h, CFG).show


def test_no_backoff_when_break_taken():
    h = [Rec(at(10), "shown", "h1"), Rec(at(10, 20), "taken", "t1", "h1")]
    assert bh.threshold_now(at(12), h, CFG) == 60


def test_backoff_counts_snooze_at_once():
    h = [Rec(at(10), "shown", "h1"), Rec(at(10, 1), "snoozed", "s1", "h1")]
    assert bh.threshold_now(at(10, 2), h, CFG) == 75


def test_daily_cap_and_next_day():
    sp = spans((at(9), 900))
    h = [Rec(at(10 + i), "shown", f"h{i}") for i in range(4)]
    assert bh.decide(at(20), sp, h, CFG).reason == "daily cap reached"
    nxt = at(10) + timedelta(days=1)
    sp2 = spans((nxt - timedelta(minutes=60), 60))
    d = bh.decide(nxt, sp2, h, CFG)
    assert d.show and d.threshold_min == 60          # new day: cap and back-off start over


def test_day_starts_at_four():
    late = DAY.replace(hour=1) + timedelta(days=1)  # 01:00 next calendar day still counts as today
    assert bh.day_key(late) == bh.day_key(at(10))


# ---- snooze ----

def test_snooze_brings_one_more_hint_after_20_min():
    sp = spans((at(9), 300))
    h = [Rec(at(10), "shown", "h1"), Rec(at(10, 1), "snoozed", "s1", "h1")]
    assert not bh.decide(at(10, 20), sp, h, CFG).show
    d = bh.decide(at(10, 21), sp, h, CFG)
    assert d.show and d.reason == "snooze over"
    h.append(Rec(at(10, 21), "shown", "h2"))          # after the re-hint, normal rules again
    assert not bh.decide(at(10, 40), sp, h, CFG).show


def test_snooze_cancelled_by_a_break():
    sp = spans((at(9), 62), (at(10, 10), 30))
    h = [Rec(at(10), "shown", "h1"), Rec(at(10, 1), "snoozed", "s1", "h1")]
    assert not bh.decide(at(10, 25), sp, h, CFG).show


# ---- quiet hours ----

def test_quiet_hours():
    assert bh.in_quiet(at(23, 30), "23:00-08:00")
    assert bh.in_quiet(DAY.replace(hour=7, minute=59), "23:00-08:00")
    assert not bh.in_quiet(at(8), "23:00-08:00")
    assert bh.in_quiet(at(13), "12:00-14:00") and not bh.in_quiet(at(14), "12:00-14:00")
    assert not bh.in_quiet(at(23, 30), "off")
    late = DAY.replace(hour=21)
    sp = spans((late, 200))
    assert bh.decide(late + timedelta(minutes=125), sp, [], CFG).reason == "quiet hours"


# ---- break detection ----

def test_break_after_hint_is_taken():
    sp = spans((at(9), 70))                           # hint 10:00, AFK from 10:10
    h = [Rec(at(10), "shown", "h1")]
    assert bh.breaks_taken(at(10, 14), sp, h, CFG) == []
    assert [r.id for r in bh.breaks_taken(at(10, 15), sp, h, CFG)] == ["h1"]
    h.append(Rec(at(10, 15), "taken", "t1", "h1"))
    assert bh.breaks_taken(at(10, 16), sp, h, CFG) == []


def test_break_too_late_is_not_counted():
    sp = spans((at(9), 95))                           # AFK from 10:35, 35 min after the hint
    assert bh.breaks_taken(at(10, 45), sp, [Rec(at(10), "shown", "h1")], CFG) == []


def test_missed_break_still_found_after_return():
    sp = spans((at(9), 70), (at(10, 20), 10))         # break 10:10-10:20, back at work at 10:25
    assert [r.id for r in bh.breaks_taken(at(10, 25), sp, [Rec(at(10), "shown", "h1")], CFG)] == ["h1"]


# ---- replay and event file ----

def test_simulate_a_day():
    afk = work((at(9), 100), (at(10, 50), 120), (at(13), 240))
    lines = bh.simulate(afk, CFG, at(8), at(18))
    hints = [ln for ln in lines if "HINT" in ln]
    assert len(hints) <= 4 and "HINT" in lines[0] and "10:00" in lines[0]
    text = "\n".join(lines)
    assert "break taken after the 12:50 hint" in text      # AFK 12:50-13:00 right after the hint
    assert "after the 10:00 hint" not in text               # that break began 40 min after the hint
    assert lines[-1].startswith(f"{len(hints)} hint(s)")


def test_event_file_envelope(tmp_path):
    log = bh.Log(tmp_path)
    s = log.write("shown", 75.04, 60, now=at(10))
    log.write("snoozed", 75, 60, hint=s.id, now=at(10, 1))
    files = list((tmp_path / "events").glob("*/breaks-2026-11.jsonl"))
    assert len(files) == 1
    evs = [json.loads(x) for x in files[0].read_text().splitlines()]
    assert [e["seq"] for e in evs] == [1, 2]
    e = evs[0]
    assert set(e) == {"v", "id", "dev", "seq", "ts", "tz", "type", "data"}
    assert e["type"] == "break_hint" and e["dev"].startswith("eeg-pc-") and e["id"].startswith("eeg:")
    assert e["ts"] == "2026-11-18T10:00:00+03:00"
    assert e["data"] == {"kind": "shown", "active_min": 75.0, "threshold_min": 60}
    assert evs[1]["data"]["hint"] == e["id"]
    back = bh.read_history(files[0].parent)
    assert [r.kind for r in back] == ["shown", "snoozed"] and back[1].hint == back[0].id
