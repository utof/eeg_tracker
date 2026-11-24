#!/usr/bin/env python3
"""The asking rules on a temporary emulator (DECISIONS 960-975), on top of the questions' own check (confirm_check.py).

usage: python3 app/tool/asking_check.py --apk <release or replay build> [--adb-port 5056] [--work DIR] [--out DIR] [--keep]

Seeds a made-up sleep report, a made-up walk file with two walks (no recording of anyone) and one made-up earlier
notification batch of today, starts the app and checks:
  1. the card names the stretch first and the guess second ("... The headband thinks you walked. Did you?"), and one
     card is a blind one ("What were you doing ...?": the walk whose id draws blind, worked out here by the app's rule);
  2. "Yes, but the times are off" opens the strip; moving the end and saving stores a Yes with `times_confirmed` true;
  3. a chip on the blind card stores `said` with the guess kept beside it (`card` blind);
  4. "Not sure" in the notification is stored as `not_sure`; back in the app the question is not asked again and
     the labels file has no row for it;
  5. the 2-batch limit: a new walk arrives after today's second batch: no notification comes, the next one is planned
     for tomorrow, and the question is on the card.
Emulator only: run it inside `_local/build_slot.sh heavy`, with --work on a disk with 8 GB free.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import confirm_check as cc  # noqa: E402
import emu  # noqa: E402
import precheck as pc  # noqa: E402

CONFIRM = cc.CONFIRM
iso, hm, wait, answers = cc.iso, cc.hm, cc.wait, cc.answers


def estimate_id(detector: str, label: str, start: datetime, end: datetime, recording: str) -> str:
    """packages/shared_labels estimate.dart: the id is the SHA-1 of detector, label, times and recording."""
    return "est:" + hashlib.sha1("|".join([detector, label, iso(start), iso(end), recording]).encode()).hexdigest()[:16]


def blind(eid: str) -> bool:
    """estimate.dart `blindByDraw`: 1 card in 5 by the id and the seed."""
    b = hashlib.sha1(f"blind-1|{eid}".encode()).digest()
    return ((b[0] << 16) | (b[1] << 8) | b[2]) % 5 == 0


def span(a: datetime, b: datetime, now: datetime) -> str:
    """estimate.dart `spanWords`: the day word only when the stretch did not end today."""
    return ("yesterday " if b.date() < now.date() else "") + f"{hm(a)}-{hm(b)}"


def capital(s: str) -> str:
    return s[:1].upper() + s[1:]


def walk_file(rec: str, start: datetime, walks: list[tuple[datetime, datetime, str]]) -> dict:
    def one(a: datetime, b: datetime, sure: str) -> dict:
        minutes = (b - a).total_seconds() / 60
        return {"start": iso(a), "end": iso(b), "walking_min": minutes, "stopped_min": 0.0, "steps": int(minutes * 110),
                "pace": 110.0, "stretches": [{"kind": "walking", "start": iso(a), "end": iso(b),
                                              "steps": int(minutes * 110), "pace": 110.0, "confidence": sure}]}
    return {"format": "eeg-tracker-walking", "version": 1, "detector": "walk-v2", "recording": rec, "key": "made-up",
            "start": iso(start), "channels": ["T3", "T4"], "sample_rate": 250, "windows": 100, "walking_min": 55.0,
            "headband_steps": 6050, "pace": 110.0, "confidence": "likely", "walks": [one(*w) for w in walks],
            "minutes": []}


def made_up(stage: Path, now: datetime) -> tuple[list[tuple[Path, str]], dict]:
    """The seed files, and what the app should show: the sleep card and the sure walk with their guess, the unsure
    walk as a blind card (its start is moved by whole minutes until its id draws blind and the others do not)."""
    stage.mkdir(parents=True, exist_ok=True)
    now = now.replace(second=0, microsecond=0)
    s0, s1 = now - timedelta(minutes=200), now - timedelta(minutes=90)
    w0, w1 = now - timedelta(minutes=80), now - timedelta(minutes=45)
    rec = (now - timedelta(minutes=205)).strftime("%Y-%m-%d-%H%M%S")
    nap = 9 <= s0.hour < 20
    for shift in range(40):  # the sure walk must show its guess: move it too when it draws blind
        w0 = now - timedelta(minutes=80 + shift)
        if not blind(estimate_id("walking", "walking", w0, w1, rec)):
            break
    v1 = now - timedelta(minutes=15)
    v0 = next(now - timedelta(minutes=36 + k) for k in range(60)
              if blind(estimate_id("walking", "walking", now - timedelta(minutes=36 + k), v1, rec)) and 36 + k < 44)
    sleep_id = estimate_id("sleep-periods", "nap" if nap else "asleep", s0, s1, rec)
    if blind(sleep_id):
        raise SystemExit("the made-up sleep period draws a blind card at this minute: run the check again in a minute")
    night = (now - timedelta(hours=12)).strftime("%Y-%m-%d")
    report = {
        "version": 2, "night_of": night, "built": iso(now), "scoring_s": 1.0, "data_start": iso(s0 - timedelta(minutes=4)),
        "data_end": iso(v1 + timedelta(minutes=5)), "inputs": [{"file": f"{rec}.f32", "bytes": 1}], "scored": True,
        "note": "made up for the asking rules' check", "validated": False, "source": "phone", "epoch_s": 30,
        "rules": {"split_min": 60, "min_period_sleep_min": 10, "wake_up_over_min": 5},
        "periods": [{"start": iso(s0), "end": iso(s1), "asleep_min": 95.0, "light_min": 60.0, "deep_min": 20.0,
                     "dream_min": 15.0, "awake_min": 15.0, "wake_ups": 1, "missing_min": 0.0, "wake_up_list": []}],
        "total": {"asleep_min": 95.0, "light_min": 60.0, "deep_min": 20.0, "dream_min": 15.0, "wake_ups": 1,
                  "periods": 1, "recorded_min": 200.0, "missing_min": 0.0, "stray_sleep_min": 0.0},
        "hypnogram": None, "sleep_json": None, "bdf": None, "model": "made-up", "cross_check": None, "stages": "",
        "extras": None, "extras_error": None, "drift_off": None, "drift_off_error": None, "wearer_signal": None,
    }
    quiet = ((now.hour + 12) % 24) * 60  # a minute of quiet hours half a day away: the batch may go out now
    settings = {"version": 2, "on": True, "per_batch": 4, "per_day": 2, "quiet_start_min": quiet,
                "quiet_end_min": quiet + 1, "quiet_from_sleep": False}
    earlier = max(now - timedelta(hours=3), now.replace(hour=0, minute=0) + timedelta(seconds=5))
    asks = json.dumps({"at": iso(earlier), "via": "notification", "estimates": ["est:0000000000000001"], "why": {}}) + "\n"
    pairs = []
    for rel, text in ((f"nights/{night}.report.json", json.dumps(report)),
                      (f"walking/{rec}.walk.json", json.dumps(walk_file(rec, s0 - timedelta(minutes=4),
                                                                        [(w0, w1, "sure"), (v0, v1, "unsure")]))),
                      ("confirm/settings.json", json.dumps(settings)), ("confirm/asks.jsonl", asks)):
        p = stage / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        pairs.append((p, rel))
    slept = "you napped" if nap else "you slept"
    return pairs, {
        "sleep": f"{capital(span(s0, s1, now))}. The headband thinks {slept}. Did you?",
        "sleep_title": capital(span(s0, s1, now)),
        "walk": f"{hm(w0)}-{hm(w1)}. The headband thinks you walked. Did you?",
        "blind": f"What were you doing {hm(v0)}-{hm(v1)}?",
        "blind_shown_guess": f"{hm(v0)}-{hm(v1)}. The headband thinks",
        "ids": {"sleep": sleep_id, "walk": estimate_id("walking", "walking", w0, w1, rec),
                "blind": estimate_id("walking", "walking", v0, v1, rec)},
        "earlier": earlier, "now": now,
    }


def tap(word: str, exact: bool = True, limit: float = 30) -> bool:
    hit = wait(lambda: emu.match(word, exact), limit=limit)
    if not hit:
        return False
    pc.sh(f"input tap {hit[1]} {hit[2]}")
    time.sleep(2)
    return True


def line_of(eid: str) -> dict | None:
    return next((a for a in answers() if a.get("estimate_id") == eid and a.get("answer") != "not_answered"), None)


def cat(name: str) -> str:
    return pc.sh(f"cat {CONFIRM}/{name} 2>/dev/null", check=False)


def check(apk: Path, stage: Path) -> list[pc.Result]:
    results: list[pc.Result] = []
    pc.install(apk)
    pc.start_app()  # once, so the app's folders exist
    pc.wait_main(240)
    pc.stop_app()

    def device_now() -> datetime:
        return datetime.strptime(pc.sh("date '+%Y-%m-%dT%H:%M:%S%z'").strip(), "%Y-%m-%dT%H:%M:%S%z")
    now = device_now()
    # the made-up earlier batch must be today's and at least an hour old (an hour between batches)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if now - midnight < timedelta(minutes=62):
        hold = (midnight + timedelta(minutes=62) - now).total_seconds()
        print(f"just after midnight: waiting {hold / 60:.0f} min so today's earlier batch is an hour old", flush=True)
        time.sleep(hold)
        now = device_now()
    pairs, want = made_up(stage, now)
    ids = want["ids"]
    pc.seed(pairs, stage)
    pc.sh("logcat -c", check=False)
    pc.start_app()
    if not pc.wait_main(240):
        return [pc.Result("the app", "FAIL", "its main screen did not come", pc.screen_words("no-main"))]

    card = pc.find_on_tab("Night", "Quick check", limit=180)
    seen = {k: bool(wait(lambda k=k: emu.match(want[k], False), limit=25)) for k in ("sleep", "walk", "blind")}
    leaked = bool(emu.match(want["blind_shown_guess"], False))
    named = bool(emu.match("I walked", True)) and bool(emu.match("I did not walk", True)) and not emu.match("Yes", True)
    results.append(pc.Result(
        "1 the card: the stretch first, the guess second, named buttons; one blind card without the guess",
        "PASS" if card and all(seen.values()) and not leaked and named else "FAIL",
        f"sleep card {seen['sleep']}, walk card {seen['walk']}, blind card {seen['blind']}; the blind card's guess on "
        f"screen: {leaked}; buttons name the thing: {named}", [json.dumps({k: want[k] for k in ('sleep', 'walk', 'blind')})]
        + pc.screen_words("card")))
    if not card:
        return results

    # the cards are in time order: sleep, the sure walk, the blind walk. Each card that shows its guess has the link;
    # the walk's is the second from the top (the card's questions are one text node, so the place tells them apart)
    links = sorted((n for n in emu.nodes() if n[0].strip() == "Yes, but the times are off"), key=lambda n: n[2])
    opened = len(links) == 2
    if opened:
        pc.sh(f"input tap {links[1][1]} {links[1][2]}")
        time.sleep(2)
    strip = bool(wait(lambda: emu.match("set the times", False), limit=20))
    moved = tap("End 5 minutes earlier", limit=10)
    saved = tap("Save these times")
    got = wait(lambda: line_of(ids["walk"]), limit=30)
    good = bool(got) and got.get("answer") == "yes" and got.get("times_confirmed") is True and bool(got.get("start")) and bool(got.get("end"))
    results.append(pc.Result(
        "2 \"Yes, but the times are off\": the strip, an end moved, saved as confirmed times",
        "PASS" if opened and strip and moved and saved and good else "FAIL",
        f"link tapped {opened}, strip shown {strip}, end moved {moved}, saved {saved}; answers.jsonl: {json.dumps(got)}",
        pc.screen_words("times-saved")))

    chip = None
    for _ in range(8):  # the blind card is the third: its chips are below the screen's edge
        chip = emu.match("Walking", True)
        if chip:
            break
        pc.sh("input swipe 540 1500 540 900 400")
        time.sleep(2)
    ok = chip is not None
    if chip:
        pc.sh(f"input tap {chip[1]} {chip[2]}")
        time.sleep(2)
    got = wait(lambda: line_of(ids["blind"]), limit=30)
    good = bool(got) and (got.get("answer"), got.get("card"), got.get("said"), got.get("guess")) == ("said", "blind", "walking", "walking")
    results.append(pc.Result("3 a blind card stores what you said, with the guess kept beside it",
                             "PASS" if ok and good else "FAIL", f"chip found {ok}; answers.jsonl: {json.dumps(got)}",
                             pc.screen_words("blind-answered")))

    title = wait(cc.notification_title, limit=180)
    tapped = cc.tap_in_shade("Not sure")
    got = wait(lambda: line_of(ids["sleep"]), limit=30)
    pc.sh("cmd statusbar collapse", check=False)
    pc.sh("input keyevent KEYCODE_HOME", check=False)
    time.sleep(2)
    pc.bring_to_front()
    pc.wait_main(120)
    time.sleep(10)
    still = bool(emu.match("Quick check", True))
    labels = [l.split("\t") for l in cat("labels.tsv").splitlines()[1:]]
    table = {l.split("\t")[0]: l.split("\t") for l in cat("estimates.tsv").splitlines()[1:]}
    row = table.get(ids["sleep"], [])
    stored = bool(got) and (got.get("answer"), got.get("via")) == ("not_sure", "notification")
    no_label = all(ids["sleep"] not in r for r in labels) and len(labels) == 2
    results.append(pc.Result(
        "4 Not sure is stored as its own answer, is no label, and is not asked again",
        "PASS" if title and tapped and stored and no_label and not still and "not_sure" in row else "FAIL",
        f"notification title {title!r} (expected {want['sleep_title']!r}); line {json.dumps(got)}; label rows "
        f"{len(labels)} (none for it: {no_label}); card after reopening: {'still there' if still else 'gone'}; "
        f"estimates.tsv answer: {row[11] if len(row) > 11 else None!r}",
        [l[:300] for l in cat("labels.tsv").splitlines()] + pc.screen_words("after-not-sure")))

    # 5: today's two batches are used up (the made-up earlier one and the one just shown). A new walk arrives.
    pc.stop_app()
    now2 = device_now().replace(second=0, microsecond=0)
    # well before the first recording's stretches: one that overlaps an answered walk would rightly not be asked
    b = now2 - timedelta(minutes=250)
    a = b - timedelta(minutes=40)
    rec2 = (b - timedelta(minutes=50)).strftime("%Y-%m-%d-%H%M%S")
    for shift in range(40):
        a = b - timedelta(minutes=40 + shift)
        if not blind(estimate_id("walking", "walking", a, b, rec2)):
            break
    p = stage / f"walking/{rec2}.walk.json"
    p.write_text(json.dumps(walk_file(rec2, a - timedelta(minutes=5), [(a, b, "likely")])))
    pc.seed([(p, f"walking/{rec2}.walk.json")], stage)
    before = cat("asks.jsonl")
    pc.start_app()
    pc.wait_main(240)
    new_card = pc.find_on_tab("Night", f"{hm(a)}-{hm(b)}. The headband thinks you walked", limit=180)
    armed = wait(lambda: cat("armed.json").strip() or None, limit=60)
    time.sleep(45)  # a batch that may go out does so at once: give it time to show that it does not
    title2 = cc.notification_title()
    after = cat("asks.jsonl")
    pushes = [json.loads(l) for l in after.splitlines() if l.strip().startswith("{") and '"estimates"' in l]
    shown = after.count('"event":"shown"')
    at = None
    try:
        at = datetime.fromisoformat(json.loads(armed)["at"]) if armed else None
    except (ValueError, KeyError):
        pass
    tomorrow = at is not None and at.date() > now2.date()
    results.append(pc.Result(
        "5 the 2-batch limit: a third batch gets no notification today, is planned for tomorrow, and is on the card",
        "PASS" if new_card and tomorrow and title2 is None and len(pushes) == 2 and shown == 1 else "FAIL",
        f"batches today {len(pushes)} (shown by the phone: {shown}); new question on the card: {bool(new_card)}; "
        f"notification now: {title2!r}; next batch planned for {at.isoformat() if at else None}",
        ["asks.jsonl before:"] + before.splitlines() + ["asks.jsonl after:"] + after.splitlines() + [f"armed.json: {armed}"]
        + pc.screen_words("third-batch")))
    return results


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--out", type=Path)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--adb-port", type=int, default=5056)
    p.add_argument("--work", type=Path, required=True,
                   help="where the run's folder (emulator, staged files, logs) is made; a disk with 8 GB free")
    a = p.parse_args()
    if not a.apk.is_file():
        p.error(f"{a.apk} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work / f"eeg-asking-check-{time.strftime('%Y-%m-%d-%H%M%S')}"
    out = a.out or work / "out"
    out.mkdir(parents=True, exist_ok=True)
    pc.OUT = out
    results: list[pc.Result] = []
    em = pc.Emulator(work, a.keep)
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
    print(f"\nThe asking rules on the emulator ({a.apk.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if not results or any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
