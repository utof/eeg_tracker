#!/usr/bin/env python3
"""Record first on a temporary emulator (DECISIONS 880-910, 980-984): Record, Work on the running recording, Stop
work, Sleep on the running recording, Stop sleep, Stop, the sheet "What was this recording?", then Work pressed with
nothing recording.

usage: python3 app/tool/record_check.py --apk <the REPLAY build> [--adb-port 5053] [--work DIR] [--out DIR] [--keep]
       [--adb-connect HOST:PORT]   (an emulator somebody else runs, as tool/precheck.py: `_local/remote/precheck_emu.sh`
       with PRECHECK=<this file>)

The replay build's headband plays a made-up quiet recording (tool/replay_scenario.dart), so no headband and no
recording of anyone is needed. It checks:
  1. Record starts a recording whose header names it, with no sleep marked (no spans file);
  2. Sleep on the running recording writes an open sleep span that did not start the recording;
  3. Stop, then "Stop sleep", closes the span while the recording goes on (its file keeps growing);
  4. Stop, then "Stop", ends the recording and the sheet comes; a chip and Save write a tag with source
     `owner_stop_sheet` into the recording's tags file;
  5. the sleep span gets a report file of its own (`nights/<date>.report.json` with `span`) (a SKIP when the scoring
     has not come to it within 3 minutes);
  W1. Work on the running recording (after 1): a work span that did not start the recording, no second file set, the
     work session's own file names the recording and the span;
  W2. Stop work: the span closes, nothing is asked, the recording goes on;
  W3. Work pressed with nothing recording (after 5): the recorder starts, the work span says it started the
     recording; Stop work asks, "Stop everything" ends the recording.
  L1. (review finding 6) Signal, then Sleep: the night starts on the Signal tab's live connection (lent by the screen's
     engine). The app is then swiped from Recents: the recording must go on, or pick up within 90 s, with the gap in
     its log; the sleep span stays open.
  L2. The app's whole process is then ended (kill -9, as Android does under memory pressure): Android must start the
     recorder again and the same recording must get data again within 150 s.
  L3. The app is opened again: it shows the running recording (Stop is offered, not Record), and "Stop everything"
     ends it with the sleep span closed.
`--only main` runs 1-5 and W1-W3, `--only lent` L1-L3; without it, everything.
The emulator, its adb server and the helpers are the pre-install check's (tool/precheck.py). Emulator only: run it
inside `_local/build_slot.sh heavy`, with --work on a disk with 8 GB free.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emu  # noqa: E402
import precheck as pc  # noqa: E402

REC = f"{pc.FILES}/recordings"
SPANS = f"{pc.FILES}/spans"


def wait(what, limit: float = 90, every: float = 3):  # noqa: ANN001, ANN201
    t0 = time.time()
    while True:
        got = what()
        if got or time.time() - t0 > limit:
            return got
        time.sleep(every)


def tap(hit: tuple[str, int, int] | None) -> bool:
    if hit is None:
        return False
    pc.sh(f"input tap {hit[1]} {hit[2]}")
    time.sleep(2)
    return True


def cat(path: str) -> str:
    return pc.sh(f"cat {path} 2>/dev/null", check=False)


def spans(recording: str) -> list[dict]:
    """The recording's spans, the last line of each."""
    by_id: dict[str, dict] = {}
    for line in cat(f"{SPANS}/{recording}.spans.jsonl").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if isinstance(d, dict) and "span" in d:
            by_id[d["span"]] = d
    return list(by_id.values())


def size(path: str) -> int:
    out = pc.sh(f"stat -c %s {path} 2>/dev/null", check=False).strip()
    return int(out) if out.isdigit() else 0


def sets() -> list[str]:
    return sorted(pc.sh(f"ls {REC}/*.f32 2>/dev/null", check=False).split())


def work_file(span: str) -> dict:
    """The work session file that names [span]."""
    for f in pc.sh(f"ls {pc.FILES}/work-sessions/*.work.json 2>/dev/null", check=False).split():
        try:
            j = json.loads(cat(f))
        except ValueError:
            continue
        if isinstance(j, dict) and j.get("span") == span:
            return j
    return {}


def start_work() -> tuple[bool, list[str]]:
    """Taps Work on the Record tab's bar, then the work page's own start. True when both were found."""
    if not tap(wait(lambda: pc.bar_button("Work"), limit=30)):
        return False, pc.screen_words("w-no-chip")
    started = tap(wait(lambda: emu.match("Start work session", False), limit=40))
    return started, pc.screen_words("w-page")


def stop_work() -> bool:
    """The work page's Stop, and its "Stop the work session?" when it asks."""
    if not tap(wait(lambda: emu.match("Stop", True), limit=20)):
        return False
    if emu.match("Stop the work session?", False):
        tap(emu.match("Stop", True))
    return True


def work_on_recording(rec: str) -> list[pc.Result]:
    """W1 and W2: Work on the recording [rec] that runs, then Stop work."""
    out: list[pc.Result] = []
    n_sets = len(sets())
    started, words = start_work()
    got = wait(lambda: [s for s in spans(rec) if s.get("kind") == "work"], limit=60) if started else []
    s = got[0] if got else {}
    time.sleep(25)  # the session reads the recording's stream for a while
    words += pc.screen_words("w1-running")
    ok = bool(got) and s.get("end") is None and s.get("started_recording") is False and s.get("source") == "owner_button"
    same_file = len(sets()) == n_sets
    out.append(pc.Result("W1 Work on the running recording: a span on it, no second file", "PASS" if ok and same_file else "FAIL",
                         f"span {json.dumps(s)}; file sets before {n_sets}, now {len(sets())}", words))
    if not ok:
        pc.sh("input keyevent 4", check=False)
        return out
    stopped = stop_work()
    closed = wait(lambda: [x for x in spans(rec) if x.get("kind") == "work" and x.get("end")], limit=40)
    asked = emu.match("has ended", False)
    a = size(f"{REC}/{rec}.f32")
    time.sleep(8)
    b = size(f"{REC}/{rec}.f32")
    c = closed[0] if closed else {}
    wf = work_file(c.get("span", "-"))
    ok2 = stopped and bool(closed) and c.get("ended_by") == "owner" and not asked and b > a
    named = wf.get("recording") == rec and wf.get("raw") == rec
    out.append(pc.Result("W2 Stop work: the span closes, nothing is asked, the recording goes on", "PASS" if ok2 and named else "FAIL",
                         f"span end {c.get('end')!r} by {c.get('ended_by')!r}; asked: {bool(asked)}; the recording grew {a} -> {b} "
                         f"bytes; the work file names recording {wf.get('recording')!r}, span {wf.get('span')!r}, raw {wf.get('raw')!r}",
                         pc.screen_words("w2-stopped")))
    pc.sh("input keyevent 4", check=False)  # back to the Record tab
    time.sleep(2)
    return out


def work_starts_recording(before: set[str]) -> list[pc.Result]:
    """W3: Work pressed with nothing recording, then Stop work and "Stop everything"."""
    pc.open_tab("Record")
    started, words = start_work()

    def new_log() -> str | None:
        new = sorted(f for f in pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split() if f not in before)
        return new[-1] if new and "recording started" in cat(new[-1]) else None

    log = wait(new_log, limit=150) if started else None
    if not log:
        return [pc.Result("W3 Work with nothing recording starts the recorder", "FAIL",
                          f"Work's start tapped: {started}; no new recording within 150 s", words + pc.screen_words("w3-no-recording"))]
    rec = log.rsplit("/", 1)[1][: -len(".log")]
    got = wait(lambda: [s for s in spans(rec) if s.get("kind") == "work"], limit=40)
    s = got[0] if got else {}
    time.sleep(15)
    stopped = stop_work()
    asked = wait(lambda: emu.match("Stop everything", True), limit=30) if stopped else None
    words += pc.screen_words("w3-asked")
    tap(asked)

    wait(lambda: any(x.get("kind") == "work" and x.get("end") for x in spans(rec)), limit=40)
    time.sleep(6)
    a = size(f"{REC}/{rec}.f32")
    time.sleep(8)
    b = size(f"{REC}/{rec}.f32")
    c = next((x for x in spans(rec) if x.get("kind") == "work"), {})
    ok = bool(got) and s.get("started_recording") is True and bool(asked) and bool(c.get("end")) and a == b
    words += pc.screen_words("w3-after")
    sheet = emu.match("What was this recording?", True)
    if sheet:
        tap(emu.match("Skip", True))
    return [pc.Result("W3 Work with nothing recording starts the recorder; Stop everything ends it", "PASS" if ok else "FAIL",
                      f"recording {rec}; span {json.dumps(c)}; asked Stop everything: {bool(asked)}; the file after it {a} -> {b} "
                      f"bytes; the sheet came: {bool(sheet)}", words)]


def rec_sets(rec: str) -> dict[str, int]:
    """Every raw file of the recording [rec] (its header names it) with its size."""
    out: dict[str, int] = {}
    for h in pc.sh(f"ls {REC}/*.header.json 2>/dev/null", check=False).split():
        stem = h.rsplit("/", 1)[1][: -len(".header.json")]
        if stem < rec:
            continue
        try:
            named = json.loads(cat(h)).get("recording")
        except ValueError:
            named = None
        if named == rec or stem == rec:
            f = f"{REC}/{stem}.f32"
            out[f] = size(f)
    if not out:
        out[f"{REC}/{rec}.f32"] = size(f"{REC}/{rec}.f32")
    return out


def growth(rec: str, limit: float, every: float = 3) -> tuple[float | None, float, list[str]]:
    """Watches the recording's files for [limit] s: (seconds until bytes came after the first pause, or 0.0 when they
    never paused, or None when they never came back; the longest pause in s; one line per change)."""
    t0 = time.time()
    last = sum(rec_sets(rec).values())
    last_at = t0
    longest = 0.0
    paused = False
    back: float | None = 0.0
    lines: list[str] = []
    while time.time() - t0 < limit:
        time.sleep(every)
        now = time.time()
        total = sum(rec_sets(rec).values())
        if total > last:
            if paused:
                back = now - t0
                lines.append(f"bytes again {back:.0f} s after the start of the watch, after a pause of {now - last_at:.0f} s")
                paused = False
            longest = max(longest, now - last_at - every)
            last, last_at = total, now
        elif now - last_at > every * 2.5 and not paused:
            paused = True
            back = None
            lines.append(f"no new bytes since {last_at - t0:.0f} s into the watch")
    if paused:
        longest = max(longest, time.time() - last_at)
    return back, max(longest, 0.0), lines


def swipe_away() -> tuple[bool, str]:
    """Takes the app's task out of Recents, as the owner's swipe does. True when its activity is gone."""
    def task() -> str:
        for line in pc.sh("am stack list 2>/dev/null", check=False).splitlines():
            m = re.search(r"taskId=(\d+): " + pc.PKG.replace(".", r"\."), line)
            if m:
                return m.group(1)
        return ""

    tid = task()
    w, h = emu.screen_size()
    pc.sh("input keyevent KEYCODE_APP_SWITCH", check=False)
    time.sleep(3)
    pc.sh(f"input swipe {w // 2} {h // 2} {w // 2} {h // 12} 200", check=False)
    time.sleep(3)
    how = "the Recents swipe"
    if task():
        # the gesture missed the card: Android's own removal of the task (what the swipe calls)
        pc.sh(f"am stack remove {tid}", check=False)
        time.sleep(3)
        how = f"am stack remove {tid}"
    pc.sh("input keyevent KEYCODE_HOME", check=False)
    return not task(), how


def lent_night() -> list[pc.Result]:
    """L1-L3: a night on the lent connection, the app swiped away, the process ended, the app opened again."""
    n1 = "L1 Signal, Sleep, the app swiped from Recents: the recording goes on"
    before = set(pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split())
    for _ in range(3):  # a session's page of the steps before (Work's "Saved") may still be in front
        if pc.open_tab("Signal"):
            break
        pc.sh("input keyevent 4", check=False)
        time.sleep(2)
    else:
        return [pc.Result(n1, "FAIL", "the Signal tab was not found", pc.screen_words("l-tab"))]

    def live() -> bool:
        texts = [l for l, _, _ in emu.nodes()]
        return any(t.strip().startswith("Live") for t in texts) and any("Connected" in t for t in texts)

    if not wait(live, limit=120, every=4):
        return [pc.Result(n1, "FAIL", "the Signal tab got no live signal within 2 minutes", pc.screen_words("l-signal"))]
    pc.open_tab("Record")
    if not tap(wait(lambda: pc.bar_button("Sleep"), limit=30)):
        return [pc.Result(n1, "FAIL", "the Sleep button was not found", pc.screen_words("l-no-sleep"))]

    def started() -> str | None:
        new = sorted(f for f in pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split() if f not in before)
        return new[0] if new and "recording started" in cat(new[0]) else None

    log = wait(started, limit=120)
    if not log:
        return [pc.Result(n1, "FAIL", "no recording within 120 s of Sleep", pc.screen_words("l-no-recording"))]
    rec = log.rsplit("/", 1)[1][: -len(".log")]
    lent = "started on the connection that was already live" in cat(log)
    time.sleep(20)
    a = sum(rec_sets(rec).values())
    pid = pc.app_pid()
    gone, how = swipe_away()
    back, pause, lines = growth(rec, 120)
    logs = "".join(cat(f[: -len(".f32")] + ".log") for f in rec_sets(rec))
    span = next((x for x in spans(rec) if x.get("kind") == "sleep"), {})
    said = [l for l in logs.splitlines() if "no data" in l or "reconnect" in l or "connected " in l or "gap" in l or "lost" in l]
    details = [f"recording {rec}; lent: {lent}; process {pid} before, {pc.app_pid() or 'none'} after; the task left Recents: {gone} ({how})",
               f"bytes before the swipe {a}, at the end {sum(rec_sets(rec).values())}; longest pause {pause:.0f} s", *lines,
               f"file sets: {json.dumps(rec_sets(rec))}", f"sleep span: {json.dumps(span)}", *("  log: " + l for l in said[-12:])]
    ok = lent and gone and back is not None and back <= 90 and span.get("end") is None and bool(span)
    words = ("the recording never paused" if back == 0.0 else
             f"the recording paused {pause:.0f} s and went on {back:.0f} s after the swipe" if back is not None else
             "the recording did not come back within 120 s of the swipe")
    out = [pc.Result(n1, "PASS" if ok else "FAIL", words if lent and gone else f"lent {lent}, swiped {gone}; {words}", details)]

    # L2. the whole process ended
    n2 = "L2 the app's process ended (kill -9): Android starts the recorder again, the same recording goes on"
    pid = pc.app_pid()
    if pid:
        pc.sh(f"kill -9 {pid}", check=False)
    t0 = time.time()
    new_pid = wait(lambda: (p := pc.app_pid()) and p != pid and p, limit=120, every=2)
    up_after = time.time() - t0
    sets_before = set(rec_sets(rec))
    back2, pause2, lines2 = growth(rec, 150)
    now_sets = rec_sets(rec)
    logs = "".join(cat(f[: -len(".f32")] + ".log") for f in now_sets)
    restarted = "service restarted by Android" in logs
    span = next((x for x in spans(rec) if x.get("kind") == "sleep"), {})
    ok2 = bool(pid) and bool(new_pid) and back2 is not None and span.get("end") is None and bool(span)
    out.append(pc.Result(n2, "PASS" if ok2 else "FAIL",
                         (f"a new process after {up_after:.0f} s; data again {back2:.0f} s after it, in "
                          f"{len(set(now_sets) - sets_before)} new file set(s) of the same recording") if ok2 else
                         f"process before {pid or 'none'}, after {new_pid or 'none'}; data back: {back2}",
                         [f"longest pause {pause2:.0f} s; the log says restarted by Android: {restarted}", *lines2,
                          f"file sets: {json.dumps(now_sets)}", f"sleep span: {json.dumps(span)}",
                          *("  log: " + l for l in logs.splitlines() if "restart" in l or "previous process" in l)][:20]))

    # L3. the app opened again knows the recording, and stops it
    n3 = "L3 the app opened again shows the running recording; Stop everything ends it"
    pc.bring_to_front()
    shown = pc.wait_main(240)
    pc.open_tab("Record")
    stop = wait(lambda: pc.bar_button("Stop"), limit=60)
    offers_record = pc.bar_button("Record") is not None
    words3 = pc.screen_words("l3-open")
    tap(stop)
    confirm = wait(lambda: emu.match("Stop everything", True) or emu.match("Stop", True), limit=20)
    tap(confirm)
    ended = wait(lambda: [x for x in spans(rec) if x.get("kind") == "sleep" and x.get("end")], limit=90)
    time.sleep(6)
    x = sum(rec_sets(rec).values())
    time.sleep(8)
    y = sum(rec_sets(rec).values())
    sheet = emu.match("What was this recording?", True)
    if sheet:
        tap(emu.match("Skip", True))
    e = ended[0] if ended else {}
    ok3 = shown and bool(stop) and not offers_record and bool(ended) and x == y
    out.append(pc.Result(n3, "PASS" if ok3 else "FAIL",
                         f"main screen {shown}; Stop offered {bool(stop)}, Record offered {offers_record}; sleep span ended "
                         f"{e.get('end')!r} by {e.get('ended_by')!r}; the files after Stop {x} -> {y} bytes",
                         words3 + pc.screen_words("l3-after")))
    return out


def check(apk: Path, stage: Path, only: str = "") -> list[pc.Result]:
    results: list[pc.Result] = []
    f32 = pc.make_quiet(stage)
    stem = f32.name[: -len(".f32")]
    pc.install(apk)
    pc.start_app()  # once, so the app's folders exist
    pc.wait_main(240)
    pc.stop_app()
    plan = stage / "plan-quiet.json"
    plan.write_text(json.dumps({"files": [f"quiet/{f32.name}"], "speed": 1, "loop": True}))
    pairs = [(plan, "replay/plan.json")]
    for ext in (".f32", ".idx", ".log", ".header.json"):
        pairs.append((f32.with_name(stem + ext), f"replay/quiet/{stem}{ext}"))
    pc.seed(pairs, stage / "push-quiet")
    pc.sh("cmd bluetooth_manager enable", check=False)
    pc.sh(f"dumpsys deviceidle whitelist +{pc.PKG}", check=False)  # a start would open the battery settings page
    before = set(pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split())
    pc.sh("logcat -c", check=False)
    pc.start_app()
    if not pc.wait_main(240):
        return [pc.Result("the app", "FAIL", "its main screen did not come", pc.screen_words("no-main"))]
    pc.open_tab("Record")
    if only == "lent":
        return lent_night()

    # 1. Record
    if not tap(wait(lambda: pc.bar_button("Record"), limit=60)):
        return [pc.Result("1 Record", "FAIL", "the Record button was not found", pc.screen_words("1-no-button"))]

    def started() -> str | None:
        new = sorted(f for f in pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split() if f not in before)
        return new[0] if new and "recording started" in cat(new[0]) else None

    log = wait(started, limit=150)
    if not log:
        return [pc.Result("1 Record", "FAIL", "no recording started within 150 s of Record", pc.screen_words("1-no-recording"))]
    rec = log.rsplit("/", 1)[1][: -len(".log")]
    header = cat(f"{REC}/{rec}.header.json")
    try:
        named = json.loads(header).get("recording")
    except ValueError:
        named = None
    no_spans = not pc.sh(f"ls {SPANS}/{rec}.spans.jsonl 2>/dev/null", check=False).strip()
    words = pc.screen_words("1-recording")
    results.append(pc.Result("1 Record records, with no sleep marked", "PASS" if named == rec and no_spans else "FAIL",
                             f"recording {rec}; its header names {named!r}; spans file: {'none' if no_spans else 'there'}",
                             [w for w in words if "Recording" in w or "marked" in w][:4]))

    # W1, W2. Work on the running recording, then Stop work
    results += work_on_recording(rec)

    # 2. Sleep on the running recording
    tapped = tap(wait(lambda: pc.bar_button("Sleep"), limit=30))
    got = wait(lambda: [s for s in spans(rec) if s.get("kind") == "sleep"], limit=40)
    s = got[0] if got else {}
    lights = wait(lambda: emu.match("Lights off", True), limit=20)
    ok = tapped and bool(got) and s.get("end") is None and s.get("started_recording") is False and s.get("source") == "owner_button"
    results.append(pc.Result("2 Sleep on the running recording opens a sleep span", "PASS" if ok and lights else "FAIL",
                             f"span {json.dumps(s)}; Lights off on the screen: {bool(lights)}", pc.screen_words("2-sleep")))
    if not ok:
        return results
    time.sleep(20)

    # 3. Stop sleep keeps the recording
    tap(pc.bar_button("Stop"))
    asked = wait(lambda: emu.match("Stop sleep", True), limit=20)
    tap(asked)
    closed = wait(lambda: [x for x in spans(rec) if x.get("kind") == "sleep" and x.get("end")], limit=30)
    a = size(f"{REC}/{rec}.f32")
    time.sleep(8)
    b = size(f"{REC}/{rec}.f32")
    s = closed[0] if closed else {}
    ok3 = bool(closed) and s.get("ended_by") == "owner" and b > a
    results.append(pc.Result("3 Stop sleep ends the sleep, the recording goes on", "PASS" if ok3 else "FAIL",
                             f"span end {s.get('end')!r} by {s.get('ended_by')!r}; the recording grew {a} -> {b} bytes",
                             pc.screen_words("3-after-sleep")))

    # 4. Stop, the sheet, a chip, Save
    tap(wait(lambda: pc.bar_button("Stop"), limit=20))
    tap(wait(lambda: emu.match("Stop", True) if emu.match("Stop recording?", True) else None, limit=20))
    sheet = wait(lambda: emu.match("What was this recording?", True), limit=60)
    details = pc.screen_words("4-sheet")
    chip = tap(emu.match("Walked", True)) if sheet else False
    part = wait(lambda: emu.match("Walked: only part of it?", True), limit=15) if chip else None
    details += pc.screen_words("4-chip")
    saved = tap(emu.match("Save", True)) if chip else False
    tags = wait(lambda: cat(f"{pc.FILES}/archive/{rec}.tags.json"), limit=30) if saved else ""
    try:
        tag = (json.loads(tags).get("tags") or [{}])[0]
    except ValueError:
        tag = {}
    details.append(f"chip tapped {chip}, its times row shown {bool(part)}, Save tapped {saved}; archive: " + pc.sh(f"ls -la {pc.FILES}/archive {SPANS} 2>&1", check=False).replace("\n", " / "))
    details += pc.screen_words("4-after-save")
    ok4 = bool(sheet) and tag.get("label") == "walking" and tag.get("source") == "owner_stop_sheet" and tag.get("confidence") == "within"
    results.append(pc.Result("4 Stop, then the sheet: a chip and Save write the tag", "PASS" if ok4 else "FAIL",
                             f"sheet shown: {bool(sheet)}; tag {json.dumps(tag)}", details))
    end_log = cat(log)
    results[-1].details.extend(l for l in end_log.splitlines() if "span:" in l or "sleep kit" in l)

    # 5. the sleep span's own report
    def report() -> str:
        for f in pc.sh(f"ls {pc.FILES}/nights/*.report.json 2>/dev/null", check=False).split():
            text = cat(f)
            if rec in text and '"span"' in text:
                return text
        return ""

    rep = wait(report, limit=180, every=10)
    if rep:
        j = json.loads(rep)
        results.append(pc.Result("5 the sleep span has its own report", "PASS",
                                 f"night {j.get('night_of')}: span {json.dumps(j.get('span'))}, {j.get('data_start')} to {j.get('data_end')}"))
    else:
        results.append(pc.Result("5 the sleep span has its own report", "SKIP", "no report within 3 minutes of Stop",
                                 pc.screen_words("5-no-report")))

    # W3. Work pressed with nothing recording
    results += work_starts_recording(set(pc.sh(f"ls {REC}/*.log 2>/dev/null", check=False).split()))
    if only != "main":
        time.sleep(5)
        pc.open_tab("Record")
        results += lent_night()
    return results


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--out", type=Path)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--adb-port", type=int, default=5053)
    p.add_argument("--work", type=Path, default=Path("/var/tmp"),
                   help="where the run's folder (emulator, staged files, logs) is made; a disk with 8 GB free")
    p.add_argument("--adb-connect", metavar="HOST:PORT", help="use the emulator already reachable at this adb address "
                   "(a tunnel to another machine's) instead of making one here")
    p.add_argument("--only", choices=["main", "lent"], default="", help="main: 1-5 and W1-W3; lent: L1-L3; default: all")
    a = p.parse_args()
    if not a.apk.is_file():
        p.error(f"{a.apk} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work / f"eeg-record-check-{time.strftime('%Y-%m-%d-%H%M%S')}"
    out = a.out or work / "out"
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    pc.OUT = out
    results: list[pc.Result] = []
    em = pc.Emulator(work, a.keep, a.adb_connect)
    t0 = time.time()
    try:
        em.create()
        em.start()
        results = check(a.apk, work / "stage", a.only)
        (out / "logcat.txt").write_text(pc.logcat())
    except Exception as e:  # the list says what ran
        results.append(pc.Result("the check itself", "FAIL", f"{type(e).__name__}: {e}"))
        try:
            (out / "logcat.txt").write_text(pc.logcat())
        except Exception:
            pass
    finally:
        em.stop()
        if not a.keep:
            shutil.rmtree(work / "stage", ignore_errors=True)
    (out / "results.json").write_text(json.dumps([r.__dict__ for r in results], indent=1))
    with open(out / "details.txt", "w") as f:
        for r in results:
            f.write(f"{r.verdict} {r.name}: {r.words}\n" + "".join(f"    {d}\n" for d in r.details))
    print(f"\nRecord first on the emulator ({a.apk.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if not results or any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
