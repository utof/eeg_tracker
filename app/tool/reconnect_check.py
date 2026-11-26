#!/usr/bin/env python3
"""The reconnect ladder on an emulator, as far as an emulator can show it (DECISIONS 940-945).

usage: reconnect_check.py --replay REPLAY.apk --work DIR [--out DIR] [--adb-port 5055] [--stage-c-min 10]
       [--adb-connect HOST:PORT]   (an emulator somebody else runs, as tool/precheck.py: `_local/remote/precheck_emu.sh`)

Needs the candidate's replay build (`--dart-define=EEG_REPLAY=true`, never for a phone). It replays a short quiet
recording that ENDS: to the night recorder that is a headband that went out of range and stays away. Then it watches
the night's `.log` and logcat for what the ladder does by the phone's real clock:

  1. the old tries first (2, 5, 10, 30 s, then one a minute, every third a scan);
  2. the "Headband lost" notice after 5 minutes, with its "Reconnect now" button; a tap on it makes a try at once,
     named in the log, and the notice then says "Tried again at HH:MM: no answer yet";
  3. after 10 minutes the 60 s tries stop: the log says so, and (a replay has no waiting connect, like BrainBit's SDK)
     the fallback's timed tries follow, every 2 minutes while the screen is on;
  4. hints, each a try at once with its name in the log: the app brought to the front, Bluetooth off and on, the
     screen locked and unlocked;
  5. the app's process killed: Android restarts the recorder, which tries once at once. A new process plays the
     replay from its start again, so that try finds the "headband": the log's return line must say how long it was
     away by the time of the DROP (kept with the night across the process's death) and "back by: app restart".

What it cannot show (the real phone and headband only): the waiting connect itself (`connectGatt(autoConnect)`),
whether it survives HyperOS with the screen off or Deep Doze, the link's real timing line, and any radio fact.

It starts a plain recording (Record) and stops it at the end. Everything it makes (the AVD, its temp files, logs,
screenshots) stays under --work. It uses its own adb server on --adb-port and its own emulator (inside
`_local/build_slot.sh heavy`), or with --adb-connect the emulator of the worker PC's queue.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import emu  # noqa: E402
import precheck as pc  # noqa: E402

TRY = re.compile(r"reconnect try (\d+) \(([^)]*)\): (\w+)")


def night_log(before: set[str]) -> tuple[str, str]:
    """The newest night log made since [before] (its path on the device and its text)."""
    new = [f for f in pc.sh(f"ls {pc.FILES}/recordings/*.log 2>/dev/null", check=False).split() if f not in before]
    if not new:
        return "", ""
    text = "".join(pc.sh(f"cat {f}", check=False) for f in sorted(new))
    return sorted(new)[-1], text


def tries(log: str) -> list[tuple[int, str]]:
    return [(int(m.group(1)), m.group(2)) for m in TRY.finditer(log)]


def wait_for(what, limit: float, every: float = 3.0):
    t0 = time.time()
    while time.time() - t0 < limit:
        got = what()
        if got:
            return got
        time.sleep(every)
    return None


def notice_text() -> str:
    """The headband notice as Android holds it (its title, text and actions), or ''."""
    dump = pc.sh("dumpsys notification --noredact", check=False, timeout=60)
    i = dump.find("headband_lost")
    if i < 0:
        return ""
    block = dump[max(0, i - 3000): i + 6000]
    keep = [l.strip() for l in block.splitlines() if any(k in l for k in ("android.title", "android.text", "android.bigText", "actions=", "Reconnect now", "[0] \""))]
    return " | ".join(keep)[:900]


def tap_reconnect_now(out: Path) -> bool:
    """Opens the notification shade and taps "Reconnect now"; closes the shade again."""
    pc.sh("cmd statusbar expand-notifications", check=False)
    time.sleep(3)
    hit = None
    for _ in range(4):
        dump = pc.sh("uiautomator dump /sdcard/shade.xml >/dev/null 2>&1; cat /sdcard/shade.xml", check=False, timeout=60)
        for m in re.finditer(r'<node[^>]*?(?:text|content-desc)="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', dump):
            if m.group(1).strip().lower() == "reconnect now":
                hit = ((int(m.group(2)) + int(m.group(4))) // 2, (int(m.group(3)) + int(m.group(5))) // 2)
        if hit:
            break
        # a collapsed notice shows no buttons: tap its title to unfold it
        t = re.search(r'text="Headband lost"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', dump)
        if t:
            pc.sh(f"input swipe {(int(t.group(1)) + int(t.group(3))) // 2} {int(t.group(2)) + 10} "
                  f"{(int(t.group(1)) + int(t.group(3))) // 2} {int(t.group(2)) + 400} 300", check=False)
        time.sleep(2)
    try:
        (out / "shade.png").write_bytes(emu.adb("exec-out", "screencap", "-p"))
    except Exception:
        pass
    if hit:
        pc.sh(f"input tap {hit[0]} {hit[1]}")
        time.sleep(1)
    pc.sh("cmd statusbar collapse", check=False)
    return hit is not None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--replay", type=Path, required=True, help="the candidate's replay build")
    p.add_argument("--work", type=Path, required=True, help="where the AVD, the temp files and the logs go")
    p.add_argument("--out", type=Path, help="where the logs go (default: WORK/out)")
    p.add_argument("--adb-connect", metavar="HOST:PORT", help="use the emulator already reachable at this adb address "
                   "(started by _local/remote/emu.sh); none is created or stopped here")
    p.add_argument("--adb-port", type=int, default=5055)
    p.add_argument("--stage-c-min", type=float, default=10, help="the build's ladderWaitAfter in minutes")
    p.add_argument("--keep", action="store_true")
    a = p.parse_args()
    if not a.replay.is_file():
        p.error(f"{a.replay} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work.resolve()
    out = (a.out or work / "out").resolve()
    out.mkdir(parents=True, exist_ok=True)
    (work / "tmp").mkdir(exist_ok=True)
    # the emulator's own temp files beside the AVD, never on the root disk
    pc.ENV["TMPDIR"] = str(work / "tmp")
    pc.ENV["ANDROID_EMULATOR_HOME"] = str(work / "emu-home")
    pc.OUT = out
    stage = work / "stage"
    lines: list[str] = []
    verdicts: list[tuple[str, str, str]] = []

    def step(name: str, ok: bool | None, words: str) -> None:
        v = "PASS" if ok else ("SKIP" if ok is None else "FAIL")
        verdicts.append((v, name, words))
        pc.say(f"{v} {name}: {words}")

    em = pc.Emulator(work, a.keep, a.adb_connect)
    t_run = time.time()
    log = ""
    try:
        em.create()
        em.start()
        f32 = pc.make_quiet(stage)
        stem = f32.name[: -len(".f32")]
        pc.install(a.replay)
        pc.start_app()  # once, so the app's folders exist
        pc.wait_main(240)
        pc.stop_app()
        plan = stage / "plan-ends.json"
        # not looping, and from its 8th minute: after 2 minutes the replayed headband is out of range for good
        plan.write_text(json.dumps({"files": [f"quiet/{f32.name}"], "speed": 1, "from_s": 480, "loop": False}))
        pairs = [(plan, "replay/plan.json")]
        for ext in (".f32", ".idx", ".log", ".header.json"):
            pairs.append((f32.with_name(stem + ext), f"replay/quiet/{stem}{ext}"))
        pc.seed(pairs, stage / "push")
        pc.sh("cmd bluetooth_manager enable", check=False)
        pc.sh(f"dumpsys deviceidle whitelist +{pc.PKG}", check=False)
        pc.sh(f"pm grant {pc.PKG} android.permission.POST_NOTIFICATIONS", check=False)
        before = set(pc.sh(f"ls {pc.FILES}/recordings/*.log 2>/dev/null", check=False).split())
        time.sleep(3)
        pc.start_app()
        if not pc.wait_main(240):
            step("the app starts", False, "the main screen did not come up in 4 minutes")
            raise RuntimeError("no main screen")
        if not pc.open_tab("Record"):
            raise RuntimeError("the Record tab was not found")
        hit = wait_for(lambda: pc.bar_button("Record"), 60)
        if hit is None:
            raise RuntimeError("the Record button was not found")
        pc.sh(f"input tap {hit[1]} {hit[2]}")
        t_start = time.time()

        # ---- the drop: the replay ends
        def dropped():
            nonlocal log
            _, log = night_log(before)
            return "drop (" in log
        ok = wait_for(dropped, 240)
        t_drop = time.time()
        step("the replayed headband goes away", bool(ok), "the night's log has its drop line" if ok else "no drop line in 4 minutes")
        if not ok:
            raise RuntimeError("no drop")

        # ---- 1. the old tries: at least 4 within the first 70 s, then about one a minute
        time.sleep(75)
        _, log = night_log(before)
        early = tries(log)
        step("stage A: the short waits (2, 5, 10, 30 s)", len(early) >= 4, f"{len(early)} tries in the first 75 s: {[h for _, h in early]}")

        # ---- 2. the lost notice (5 min by default) with its button
        got = wait_for(lambda: "Headband lost" in notice_text() and notice_text(), 330 - (time.time() - t_drop) + 60, every=10)
        has_button = bool(got) and "Reconnect now" in got
        step("the Headband lost notice has a Reconnect now button", has_button, (got or "no notice")[:300])
        if got:
            n0 = len(tries(night_log(before)[1]))
            tapped = tap_reconnect_now(out)
            named = wait_for(lambda: any(h.endswith("Reconnect now") for _, h in tries(night_log(before)[1])), 40) if tapped else None
            step("a tap on Reconnect now makes a try at once", bool(named),
                 "the log names the try 'Reconnect now'" if named else ("the button was tapped, no such try in 40 s" if tapped else "the button was not found in the shade (see shade.png)"))
            if named:
                said = wait_for(lambda: "Tried again at" in notice_text(), 50, every=5)
                step("the notice says how the try went", bool(said), notice_text()[:200] if said else "no 'Tried again' text in 50 s")
            lines.append(f"tries before the tap {n0}")

        # ---- 3. stage C
        def stage_c():
            return "the 60 s tries stop" in night_log(before)[1]
        left = a.stage_c_min * 60 + 150 - (time.time() - t_drop)
        ok = wait_for(stage_c, max(left, 30), every=10)
        _, log = night_log(before)
        line = next((l for l in log.splitlines() if "the 60 s tries stop" in l), "")
        step("stage C begins after 10 minutes", bool(ok), line[24:] if ok else "no stage line")
        if ok:
            fallback = "no waiting connect with this connection" in line
            step("a replay has no waiting connect: the fallback is named", fallback, "one try every 5 min (2 min with the screen on)" if fallback else line)
            before_c = [h for _, h in tries(log)]
            minute = [h for h in before_c if h in ("direct to replay", "scan")]
            lines.append(f"ordinary tries before stage C: {len(minute)} ({sum(h == 'scan' for h in minute)} scans)")
            # the screen is on (stay-on): a timed try within about 2 minutes, and no scan in stage C
            timed = wait_for(lambda: any(h.endswith("timed try") for _, h in tries(night_log(before)[1])), 200, every=10)
            step("the fallback's timed try (screen on: every 2 min)", bool(timed), "named in the log" if timed else "none in 200 s")

            # ---- 4. hints
            def hint(name: str, label: str, do) -> None:
                n = sum(h.endswith(label) for _, h in tries(night_log(before)[1]))
                do()
                got = wait_for(lambda: sum(h.endswith(label) for _, h in tries(night_log(before)[1])) > n, 45)
                step(f"hint: {name}", bool(got), f"a try named '{label}' at once" if got else f"no try named '{label}' in 45 s")
                time.sleep(20)  # the try under way ends before the next hint

            hint("the app brought to the front", "opened app",
                 lambda: (pc.sh("input keyevent KEYCODE_HOME", check=False), time.sleep(3), pc.bring_to_front()))
            hint("Bluetooth off and on", "Bluetooth on",
                 lambda: (pc.sh("cmd bluetooth_manager disable", check=False), time.sleep(8),
                          pc.sh("cmd bluetooth_manager enable", check=False)))
            hint("the phone locked and unlocked", "phone unlocked",
                 lambda: (pc.sh("locksettings set-disabled false", check=False), pc.sh("input keyevent KEYCODE_SLEEP", check=False),
                          time.sleep(6), pc.sh("input keyevent KEYCODE_WAKEUP", check=False), time.sleep(2),
                          pc.sh("wm dismiss-keyguard", check=False), pc.sh("input keyevent 82", check=False)))

            # ---- 5. the process killed: Android restarts the recorder; its first try comes at once and (a new
            # process plays the replay again) finds the headband: the return line counts from the drop
            pid = pc.app_pid()
            pc.sh(f"kill -9 {pid}", check=False)
            back = wait_for(lambda: "service restarted by Android" in night_log(before)[1], 180, every=5)
            if not back:
                step("the process killed: Android restarts the recorder", None,
                     "Android did not restart the service within 3 minutes on this emulator")
            else:
                step("the process killed: Android restarts the recorder", True, "the night's log says so")
                ret = wait_for(lambda: re.search(r"reconnected \(direct, try 1\) after a drop \(app process restarted\).*"
                                                 r"waited (?:(\d+) h )?(\d+) min; back by: app restart", night_log(before)[1]), 90, every=5)
                away = (int(ret.group(1) or 0) * 60 + int(ret.group(2))) if ret else None
                step("after the restart: one try at once; the time away counts from the drop", bool(ret) and away >= a.stage_c_min,
                     f"'{ret.group(0)[-60:]}'" if ret else "no such return line within 90 s of the restart")

        # ---- stop
        pc.bring_to_front()
        time.sleep(4)
        pc.open_tab("Record")
        hit = wait_for(lambda: pc.bar_button("Stop"), 60)
        if hit:
            pc.sh(f"input tap {hit[1]} {hit[2]}")
            time.sleep(2)
            confirm = wait_for(lambda: emu.match("Stop", exact=True) if emu.match("Stop recording?", exact=True) else None, 20)
            if confirm:
                pc.sh(f"input tap {confirm[1]} {confirm[2]}")
            time.sleep(8)
            if emu.match("What was this recording?", exact=True):
                skip = emu.match("Skip", exact=True)
                if skip:
                    pc.sh(f"input tap {skip[1]} {skip[2]}")
        stopped = wait_for(lambda: pc.bar_button("Record"), 60)
        step("Stop ends the recording", bool(stopped), "the Record button is back" if stopped else "still recording 60 s after Stop")
        _, log = night_log(before)
        lines.append(f"the night ran {round((time.time() - t_start) / 60, 1)} min; {len(tries(log))} tries in all")
    except Exception as e:
        step("the check itself", False, f"{type(e).__name__}: {e}")
    finally:
        try:
            _, log2 = night_log(set())
            (out / "night-logs.txt").write_text(log or log2)
            cat = pc.logcat()
            (out / "logcat.txt").write_text(cat)
            hints = [l for l in cat.splitlines() if "reconnect hint:" in l]
            (out / "hints.txt").write_text("\n".join(hints) + "\n")
            crashes = [l for l in cat.splitlines() if "FATAL EXCEPTION" in l or ("ANR in" in l and pc.PKG in l)]
            verdicts.append(("PASS" if not crashes else "FAIL", "no crash and no ANR of the app",
                             f"{len(crashes)} in logcat; {len(hints)} hint lines from Android (hints.txt)"))
            pc.screen_words("end")
        except Exception as e:
            lines.append(f"collecting the logs failed: {e}")
        try:
            em.stop()
        except Exception as e:
            lines.append(f"stopping the emulator failed: {e}")
    with open(out / "details.txt", "w") as f:
        for v, name, words in verdicts:
            f.write(f"{v} {name}: {words}\n")
        for l in lines:
            f.write(f"    {l}\n")
    print()
    print(f"Reconnect ladder check of {a.replay.name}, {(time.time() - t_run) / 60:.1f} min")
    for v, name, words in verdicts:
        print(f"{v:4} {name}: {words}")
    for l in lines:
        print(f"     {l}")
    print(f"Logs: {out}")
    return 1 if any(v == "FAIL" for v, _, _ in verdicts) else 0


if __name__ == "__main__":
    sys.exit(main())
