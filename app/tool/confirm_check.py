#!/usr/bin/env python3
"""The confirmation questions on a temporary emulator (DECISIONS 860-869): a batch on the card and in the notification.

usage: python3 app/tool/confirm_check.py --apk <release or replay build> [--adb-port 5051] [--adb-connect HOST:PORT] [--work DIR] [--out DIR] [--keep]

Seeds a made-up sleep report and a made-up walk file (no recording of anyone), starts the app and checks:
  1. the Record tab shows the "Quick check" card with the batch ("19:08-21:14. The headband thinks you walked. Did
     you?" lines; the buttons name the thing since DECISIONS 964: "I walked" / "I did not walk" / "Not sure");
  2. a tap on the card's first Yes writes a `card` line to files/confirm/answers.jsonl;
  3. the notification is there with the next question; its No and Not sure buttons write `notification` lines while
     the questions go by one after the other, and the notification leaves after the last;
  4. back in the app the card is gone, no second batch or notification came, and files/confirm/labels.tsv holds the
     Yes and the No.
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
import emu  # noqa: E402
import precheck as pc  # noqa: E402

CONFIRM = f"{pc.FILES}/confirm"


def iso(t: datetime) -> str:
    return t.astimezone().isoformat(timespec="seconds")


def hm(t: datetime) -> str:
    return t.strftime("%H:%M")


def made_up(stage: Path, now: datetime) -> tuple[list[tuple[Path, str]], list[str]]:
    """A report with one sleep period, a walk file with two walks, and settings whose quiet hours are far from now.
    Returns the files to seed and the questions the app should ask."""
    stage.mkdir(parents=True, exist_ok=True)
    now = now.replace(second=0, microsecond=0)
    import asking_check as ac  # the id and the blind draw, as the app works them out (it imports this file too)
    s0, s1 = now - timedelta(minutes=200), now - timedelta(minutes=90)
    w0, w1 = now - timedelta(minutes=80), now - timedelta(minutes=45)
    v0, v1 = now - timedelta(minutes=35), now - timedelta(minutes=15)
    rec = (now - timedelta(minutes=205)).strftime("%Y-%m-%d-%H%M%S")
    # every card here shows its guess: a stretch whose id draws a blind card (1 in 5, DECISIONS 966) starts a minute
    # earlier until it does not (the blind card has its own check, asking_check.py)
    while ac.blind(ac.estimate_id("sleep-periods", "nap" if 9 <= s0.hour < 20 else "asleep", s0, s1, rec)):
        s0 -= timedelta(minutes=1)
    while ac.blind(ac.estimate_id("walking", "walking", w0, w1, rec)):
        w0 -= timedelta(minutes=1)
    while ac.blind(ac.estimate_id("walking", "walking", v0, v1, rec)):
        v0 -= timedelta(minutes=1)
    night = (now - timedelta(hours=12)).strftime("%Y-%m-%d")
    report = {
        "version": 2, "night_of": night, "built": iso(now), "scoring_s": 1.0, "data_start": iso(s0 - timedelta(minutes=4)),
        "data_end": iso(v1 + timedelta(minutes=5)), "inputs": [{"file": f"{rec}.f32", "bytes": 1}], "scored": True,
        "note": "made up for the confirmation questions' check", "validated": False, "source": "phone", "epoch_s": 30,
        "rules": {"split_min": 60, "min_period_sleep_min": 10, "wake_up_over_min": 5},
        "periods": [{"start": iso(s0), "end": iso(s1), "asleep_min": 95.0, "light_min": 60.0, "deep_min": 20.0,
                     "dream_min": 15.0, "awake_min": 15.0, "wake_ups": 1, "missing_min": 0.0, "wake_up_list": []}],
        "total": {"asleep_min": 95.0, "light_min": 60.0, "deep_min": 20.0, "dream_min": 15.0, "wake_ups": 1,
                  "periods": 1, "recorded_min": 200.0, "missing_min": 0.0, "stray_sleep_min": 0.0},
        "hypnogram": None, "sleep_json": None, "bdf": None, "model": "made-up", "cross_check": None, "stages": "",
        "extras": None, "extras_error": None, "drift_off": None, "drift_off_error": None, "wearer_signal": None,
    }

    def walk(a: datetime, b: datetime, sure: str) -> dict:
        minutes = (b - a).total_seconds() / 60
        return {"start": iso(a), "end": iso(b), "walking_min": minutes, "stopped_min": 0.0, "steps": int(minutes * 110),
                "pace": 110.0, "stretches": [{"kind": "walking", "start": iso(a), "end": iso(b),
                                              "steps": int(minutes * 110), "pace": 110.0, "confidence": sure}]}
    walks = {"format": "eeg-tracker-walking", "version": 1, "detector": "walk-v2", "recording": rec, "key": "made-up",
             "start": iso(s0 - timedelta(minutes=4)), "channels": ["T3", "T4"], "sample_rate": 250, "windows": 100,
             "walking_min": 55.0, "headband_steps": 6050, "pace": 110.0, "confidence": "likely",
             "walks": [walk(w0, w1, "sure"), walk(v0, v1, "unsure")], "minutes": []}
    quiet = ((now.hour + 12) % 24) * 60  # a minute of quiet hours half a day away: the batch may go out now
    settings = {"version": 2, "on": True, "per_batch": 4, "per_day": 2, "quiet_start_min": quiet,
                "quiet_end_min": quiet + 1, "quiet_from_sleep": False}
    pairs = []
    for rel, obj in ((f"nights/{night}.report.json", report), (f"walking/{rec}.walk.json", walks),
                     ("confirm/settings.json", settings)):
        p = stage / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(obj))
        pairs.append((p, rel))
    slept = "you napped" if 9 <= s0.hour < 20 else "you slept"
    return pairs, [f"{hm(s0)}-{hm(s1)}. The headband thinks {slept}. Did you?",
                   f"{hm(w0)}-{hm(w1)}. The headband thinks you walked. Did you?",
                   f"{hm(v0)}-{hm(v1)}. The headband thinks you walked. Did you?"]


def answers() -> list[dict]:
    text = pc.sh(f"cat {CONFIRM}/answers.jsonl 2>/dev/null", check=False)
    return [json.loads(l) for l in text.splitlines() if l.strip().startswith("{")]


def notification_title() -> str | None:
    """The questions' notification's title as Android holds it; None when it is not posted."""
    dump = pc.sh("dumpsys notification --noredact", timeout=60, check=False)
    block = ""
    for part in dump.split("NotificationRecord(")[1:]:
        head = part.split("\n", 1)[0]  # the record's own line; the last record's text runs on into other sections
        if "confirm_questions" in head and pc.PKG in head:
            block = part
            break
    if not block:
        return None
    for line in block.splitlines():
        if "android.title=" in line:
            return line.split("android.title=", 1)[1].split("String (", 1)[-1].strip().rstrip(")").strip()
    return ""


def wait(what, limit: float = 90, every: float = 3):  # noqa: ANN001, ANN201
    t0 = time.time()
    while True:
        got = what()
        if got or time.time() - t0 > limit:
            return got
        time.sleep(every)


YES_WORDS = ("I slept", "I napped", "I walked")  # vocabulary.dart: what a Yes and a No are called on these cards
NO_WORDS = ("I was awake", "I did not walk")


def tap_in_shade(word: str, limit: float = 30) -> bool:
    """Opens the notification shade and taps the questions' button [word]."""
    pc.sh("cmd statusbar expand-notifications", check=False)
    time.sleep(2)
    hit = wait(lambda: next(((l, x, y) for l, x, y in emu.nodes() if l.strip() == word), None), limit=limit)
    if not hit:
        return False
    pc.sh(f"input tap {hit[1]} {hit[2]}")
    time.sleep(2)
    return True


def check(apk: Path, stage: Path) -> list[pc.Result]:
    results: list[pc.Result] = []
    pc.install(apk)
    pc.start_app()  # once, so the app's folders exist
    pc.wait_main(240)
    now = datetime.strptime(pc.sh("date '+%Y-%m-%dT%H:%M:%S%z'").strip(), "%Y-%m-%dT%H:%M:%S%z")
    pairs, questions = made_up(stage, now)
    pc.seed(pairs, stage)
    pc.sh("logcat -c", check=False)
    pc.start_app()
    if not pc.wait_main(240):
        return [pc.Result("the app", "FAIL", "its main screen did not come", pc.screen_words("no-main"))]

    card = pc.find_on_tab("Record", "Quick check", limit=180)
    seen = [q for q in questions if wait(lambda q=q: emu.match(q, False), limit=20)]
    details = pc.screen_words("card")
    results.append(pc.Result("1 the card shows the batch", "PASS" if card and len(seen) == 3 else "FAIL",
                             f"{len(seen)} of 3 questions on the Record tab: " + " / ".join(seen), details))
    if not card:
        return results

    # the buttons name the thing (DECISIONS 964): the first card's Yes
    yes = next(((l, x, y) for l, x, y in emu.nodes() if l.strip() in YES_WORDS), None)
    if yes:
        pc.sh(f"input tap {yes[1]} {yes[2]}")
    got = wait(lambda: [a for a in answers() if a.get("via") == "card"], limit=30)
    results.append(pc.Result("2 a tap on the card saves the answer", "PASS" if got and got[0]["answer"] == "yes" else "FAIL",
                             f"answers.jsonl: {json.dumps(got)}", pc.screen_words("card-answered")))

    title = wait(notification_title, limit=180)
    first = title
    taps = []
    for word, answer in (("No", "no"), ("Not sure", "not_sure")):
        before = len(answers())
        ok = any(tap_in_shade(w, limit=8) for w in NO_WORDS) if word == "No" else tap_in_shade(word)
        line = wait(lambda b=before: answers()[b:] or None, limit=30)
        taps.append((word, ok, line[0] if line else None, notification_title()))
    pc.sh("cmd statusbar collapse", check=False)
    good = bool(first) and all(ok and line and line.get("via") == "notification" and line.get("answer") == a
                               for (w, ok, line, _), a in zip(taps, ("no", "not_sure")))
    gone = taps[-1][3] is None
    results.append(pc.Result(
        "3 the notification's buttons answer one question after the other", "PASS" if good and gone else "FAIL",
        f"first shown: {first!r}; after No: {taps[0][3]!r}; after Not sure: {'gone' if gone else taps[1][3]!r}",
        [f"{w}: tapped {ok}, line {json.dumps(line)}" for w, ok, line, _ in taps]
        + [l for l in pc.sh(f"cat {CONFIRM}/asks.jsonl 2>/dev/null", check=False).splitlines()]))

    pc.sh("input keyevent KEYCODE_HOME", check=False)
    time.sleep(2)
    pc.bring_to_front()
    pc.wait_main(120)
    time.sleep(8)
    still = emu.match("Quick check", True)
    labels = pc.sh(f"cat {CONFIRM}/labels.tsv 2>/dev/null", check=False)
    rows = [l.split("\t") for l in labels.splitlines()[1:]]
    present = sorted(r[14] for r in rows if len(r) >= 16)
    shown = pc.sh(f"cat {CONFIRM}/asks.jsonl 2>/dev/null", check=False).count('"event":"shown"')
    again = notification_title()
    results.append(pc.Result("4 the card is gone, nothing is asked again, the labels file has the Yes and the No",
                             "PASS" if not still and present == ["0", "1"] and shown == 1 and again is None else "FAIL",
                             f"{len(rows)} label rows, present {present}; card {'still there' if still else 'gone'}; "
                             f"batches shown {shown}; notification after reopening: {again!r}",
                             [l[:300] for l in labels.splitlines()] + pc.screen_words("after")))
    return results


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--out", type=Path)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--adb-port", type=int, default=5051)
    p.add_argument("--adb-connect", metavar="HOST:PORT",
                   help="use the emulator already reachable at this adb address (a worker PC's: _local/remote/precheck_emu.sh)")
    p.add_argument("--work", type=Path, default=Path("/var/tmp"),
                   help="where the run's folder (emulator, staged files, logs) is made; a disk with 8 GB free")
    a = p.parse_args()
    if not a.apk.is_file():
        p.error(f"{a.apk} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work / f"eeg-confirm-check-{time.strftime('%Y-%m-%d-%H%M%S')}"
    out = a.out or work / "out"
    out.mkdir(parents=True, exist_ok=True)
    pc.OUT = out
    results: list[pc.Result] = []
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
        em.stop()
        if not a.keep:
            shutil.rmtree(work / "stage", ignore_errors=True)
    (out / "results.json").write_text(json.dumps([r.__dict__ for r in results], indent=1))
    with open(out / "details.txt", "w") as f:
        for r in results:
            f.write(f"{r.verdict} {r.name}: {r.words}\n" + "".join(f"    {d}\n" for d in r.details))
    print(f"\nConfirmation questions on the emulator ({a.apk.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if not results or any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
