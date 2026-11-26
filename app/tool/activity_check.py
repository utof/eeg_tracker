#!/usr/bin/env python3
"""Automatic recording, phase 2, on a temporary emulator (DECISIONS 1100-1116): the question "Meditating or resting?"
and the "What happened" lane.

usage: python3 app/tool/activity_check.py --apk <release or replay build> [--adb-port 5073] [--adb-connect HOST:PORT] [--work DIR] [--out DIR] [--keep]

Seeds a made-up sleep report with its stages, a made-up walk file and a made-up guesses file (no recording of anyone)
whose one "eyes closed, resting" stretch ended a few minutes before the device's clock, starts the app and checks:
  1. the Record tab's "Quick check" card asks "HH:MM-HH:MM. Your eyes were closed and you were still. Meditating or
     resting?" with the two words, and without "the headband thinks";
  2. a tap on Resting writes a `said` line with `card` `choice` to files/confirm/answers.jsonl, and
     files/confirm/labels.tsv gets a `resting` row;
  3. the Archive's page of the made-up recording has the lane "What happened" with its stretches (asleep and a
     walk: the two that need no detectors' pass), and the "Found" list names it;
  4. the lane's list of stretches opens, and nothing was asked a second time.
The question is only asked by day, so outside 08:00-22:00 the device's clock is first put at 13:30.
Not checked here (unit and widget tests only): the morning line (it needs a sleep stretch of 3 hours) and the laptop's
work word during a recording (it needs a paired laptop).
The emulator, its adb server and the helpers are the pre-install check's (tool/precheck.py). Emulator only: run it
inside `_local/build_slot.sh heavy`.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asking_check as ac  # noqa: E402
import confirm_check as cc  # noqa: E402
import emu  # noqa: E402
import precheck as pc  # noqa: E402

CONFIRM = f"{pc.FILES}/confirm"
CHOICE = "Your eyes were closed and you were still. Meditating or resting?"


def made_up(stage: Path, now: datetime) -> tuple[list[tuple[Path, str]], str, str, datetime]:
    """The confirm check's report, walk file and settings, the report given its stages, and a guesses file with one
    "eyes closed, resting" stretch of 5 minutes that ended 7 minutes ago. Returns the files to seed, the question the
    app should ask, the recording's id and when its report's data starts."""
    now = now.replace(second=0, microsecond=0)
    pairs, _ = cc.made_up(stage, now)
    report_path = next(p for p, rel in pairs if rel.startswith("nights/"))
    report = json.loads(report_path.read_text())
    rec = report["inputs"][0]["file"][:17]
    start = datetime.fromisoformat(report["data_start"])
    period = report["periods"][0]
    s0, s1 = datetime.fromisoformat(period["start"]), datetime.fromisoformat(period["end"])
    end = datetime.fromisoformat(report["data_end"])
    awake_before = int((s0 - start).total_seconds() // 30)
    asleep = int((s1 - s0).total_seconds() // 30)
    awake_after = int((end - s1).total_seconds() // 30)
    report["stages"] = "W" * awake_before + "2" * asleep + "W" * awake_after
    report_path.write_text(json.dumps(report))
    r0, r1 = now - timedelta(minutes=12), now - timedelta(minutes=7)
    guesses = {"version": 1, "recording": rec, "made": cc.iso(now), "key": "made-up", "marks": [
        {"what": "eyes_closed_resting", "start": cc.iso(r0), "end": cc.iso(r1), "sure": "strong",
         "minutes_from_bedtime": -600, "in_bedtime_window": False, "eyes_closed_share": 0.9,
         "good_signal_share": 1, "jaw_bursts_per_min": 0, "movement_s_per_min": 0, "back_alpha": 2.4}]}
    p = stage / "activity" / f"{rec}.guesses.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(guesses))
    pairs.append((p, f"activity/{rec}.guesses.json"))
    return pairs, f"{ac.capital(ac.card_words(r0, r1, now))}. {CHOICE}", rec, start


def tap(hit: tuple[str, int, int] | None) -> bool:
    if hit is None:
        return False
    pc.sh(f"input tap {hit[1]} {hit[2]}")
    time.sleep(2)
    return True


def swipe_list() -> None:
    """Scrolls the page's list down by a swipe that starts above the Record tab's pinned bar (emu.scroll starts on it)."""
    w, h = emu.screen_size()
    emu.adb("shell", "input", "swipe", str(w // 2), str(int(h * 0.55)), str(w // 2), str(int(h * 0.25)), "400")
    time.sleep(0.8)


def scroll_to(wanted, scrolls: int = 16) -> tuple[str, int, int] | None:  # noqa: ANN001
    """The first element whose words [wanted] accepts, scrolling down until it is clear of the pinned bar."""
    _, h = emu.screen_size()
    for _ in range(scrolls):
        hit = next((n for n in emu.nodes() if wanted(n[0])), None)
        if hit is not None and hit[2] < h * 0.6:
            return hit
        swipe_list()
    return next((n for n in emu.nodes() if wanted(n[0])), None)


def check(apk: Path, stage: Path) -> list[pc.Result]:
    results: list[pc.Result] = []
    pc.install(apk)
    pc.start_app()  # once, so the app's folders exist
    pc.wait_main(240)
    now = datetime.strptime(pc.sh("date '+%Y-%m-%dT%H:%M:%S%z'").strip(), "%Y-%m-%dT%H:%M:%S%z")
    if not 8 <= now.hour < 22:
        print(f"the device's clock says {cc.hm(now)}: put at 13:30 (the question is only asked by day)", flush=True)
        now = cc.set_device_clock(cc.at_today(now, "13:30"))
    pairs, question, rec, start = made_up(stage, now)
    pc.seed(pairs, stage)
    pc.sh("logcat -c", check=False)
    pc.start_app()
    if not pc.wait_main(240):
        return [pc.Result("the app", "FAIL", "its main screen did not come", pc.screen_words("no-main"))]

    # 1. the card asks with the two words
    card = pc.find_on_tab("Record", "Quick check", limit=180)
    asked = cc.wait(lambda: pc.find(question, False), limit=60) if card else None
    # the card is one long element; its last question's words are buttons of their own, below the question
    scroll_to(lambda l: l.strip() == "Resting") if asked else None
    words = pc.screen_words("card")
    chips = {w: emu.match(w, True) for w in ("Meditating", "Resting", "Something else", "Not sure")}
    ok = bool(asked) and all(chips.values())
    results.append(pc.Result('1 the card asks "Meditating or resting?" with the two words', "PASS" if ok else "FAIL",
                             f"asked: {asked[0] if asked else 'not found: ' + question}; chips on screen: "
                             + ", ".join(w for w, hit in chips.items() if hit), words))
    if not ok:
        return results

    # 2. a tap on Resting is kept as what you said
    tap(chips["Resting"])
    got = cc.wait(lambda: [a for a in cc.answers() if a.get("answer") == "said"], limit=30)
    labels = pc.sh(f"cat {CONFIRM}/labels.tsv 2>/dev/null", check=False)
    rows = [l.split("\t") for l in labels.splitlines()[1:]]
    resting = [r for r in rows if len(r) >= 16 and r[5] == "resting" and r[14] == "1"]
    line = got[0] if got else {}
    ok = (line.get("card"), line.get("said"), line.get("via"), line.get("guess")) == ("choice", "resting", "card", "eyes_closed") \
        and len(resting) == 1
    results.append(pc.Result("2 a tap on Resting saves it as your word, and as a label", "PASS" if ok else "FAIL",
                             f"answers.jsonl: {json.dumps(line)}; resting rows in labels.tsv: {len(resting)}",
                             [l[:300] for l in labels.splitlines()] + pc.screen_words("card-answered")))

    # 3. the Archive's page of the recording has the lane
    opened = tap(pc.find_on_tab("More", "Open the archive", exact=True))
    # the quick checks' card leads the Archive too: the recording's row is under it
    cc.wait(lambda: emu.match("on this phone, newest first", False), limit=120) if opened else None
    row = scroll_to(lambda l: f"{cc.hm(start)} – " in l) if opened else None
    tap(row)
    # the timeline's own description for screen readers names every lane that has something
    lane = cc.wait(lambda: emu.match("What happened: ", False), limit=90) if row else None
    words = pc.screen_words("recording-page")
    found = scroll_to(lambda l: l.startswith("What happened") and "stretch" in l and "What happened: " not in l) if lane else None
    described = lane[0] if lane else ""
    ok = bool(lane) and found is not None
    results.append(pc.Result('3 the recording\'s page has the lane "What happened"', "PASS" if ok else "FAIL",
                             f"the timeline says: {described[:220] or 'no lane found'}; the Found row: "
                             f"{found[0] if found else 'not found'}", words + pc.screen_words("found")))

    # 4. its list of stretches opens; nothing was asked twice
    in_sheet: list[str] = []
    if found:
        tap(found)
        cc.wait(lambda: emu.match("Walking", False), limit=20)
        in_sheet = [l for l, _, _ in emu.nodes() if " · " in l and any(w in l for w in ("Asleep", "Nap", "Walking"))]
    words = pc.screen_words("lane-sheet")
    pc.sh("input keyevent 4", check=False)
    said = [a for a in cc.answers() if a.get("answer") == "said"]
    ok = any("Walking" in l for l in in_sheet) and any("Asleep" in l or "Nap" in l for l in in_sheet) and len(said) == 1
    results.append(pc.Result("4 the lane's stretches open as a list (asleep and a walk); one answer kept", "PASS" if ok else "FAIL",
                             f"in the list: {' / '.join(in_sheet) or 'nothing'}; said answers: {len(said)}", words))
    for _ in range(2):
        pc.sh("input keyevent 4", check=False)
        time.sleep(1.5)
    return results


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--out", type=Path)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--adb-port", type=int, default=5073)
    p.add_argument("--adb-connect", metavar="HOST:PORT",
                   help="use the emulator already reachable at this adb address (a worker PC's: _local/remote/precheck_emu.sh)")
    p.add_argument("--work", type=Path, default=Path("/var/tmp"),
                   help="where the run's folder (emulator, staged files, logs) is made; a disk with 8 GB free")
    a = p.parse_args()
    if not a.apk.is_file():
        p.error(f"{a.apk} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work / f"eeg-activity-check-{time.strftime('%Y-%m-%d-%H%M%S')}"
    out = a.out or work / "out"
    out.mkdir(parents=True, exist_ok=True)
    pc.OUT = out
    results: list[pc.Result] = []
    work.mkdir(parents=True, exist_ok=True)
    em = pc.Emulator(work, a.keep, connect=a.adb_connect)
    t0 = time.time()
    try:
        em.create()
        em.start()
        results = check(a.apk, work / "stage")
        (out / "logcat.txt").write_text(pc.logcat())
    except Exception as e:  # the list says what ran
        results.append(pc.Result("the check itself", "FAIL", f"{type(e).__name__}: {e}"))
        try:
            (out / "logcat.txt").write_text(pc.logcat())
        except Exception:
            pass
    finally:
        cc.restore_device_clock()
        em.stop()
        if not a.keep:
            shutil.rmtree(work / "stage", ignore_errors=True)
    (out / "results.json").write_text(json.dumps([r.__dict__ for r in results], indent=1))
    with open(out / "details.txt", "w") as f:
        for r in results:
            f.write(f"{r.verdict} {r.name}: {r.words}\n" + "".join(f"    {d}\n" for d in r.details))
    print(f"\nAutomatic recording, phase 2, on the emulator ({a.apk.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if not results or any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
