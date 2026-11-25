#!/usr/bin/env python3
"""Emulator check of the push (DECISIONS 840-849): Android's scheduled job reaches the laptop's receiver (emulator ->
host 10.0.2.2) with no notification; the spare port when 8765 is taken; the laptop's own copy pass beside it.

    _local/build_slot.sh heavy python3 app/tool/push_smoke.py APK [--natural-min 32] [--work /var/tmp/share_smoke]
        [--replay REPLAY_BUILD.apk] [--push-port N]

With --replay (needs dart on PATH): first the replay build makes a short recording with a sleep stretch, a Stop and
a chip on the sheet (tool/record_check.py's five steps), then APK is installed over it; the push must bring the
recording's spans file and its tags to the laptop, where scripts/spans.py reads the sleep stretch (DECISIONS 836).
The check's receiver listens on a port the OS says is free (--push-port N picks one) and the emulator sends what the
app addresses to the laptop's port 8772 there instead (a rule inside the emulator only): the laptop's own
`phone_link.py --keep` holds 8772 for the real phone, and the emulator's app must never knock on that receiver, which
rightly refuses it (the run of 2026-11-25 01:07: every push "the laptop did not answer").

Own adb server on port 5049, own temporary AVD under the work folder, both removed at the end. About 30-45 minutes:
most of it is the wait for Android's own second run of the regular job.

What the order of the steps is for (the first run of this check, 2026-11-21, got them wrong):
- Android runs a periodic job once in each 15-minute window, and every run, a forced one too (`cmd jobscheduler run`),
  moves the next window one period on. So the wait for Android's own run comes first, before anything is forced.
- The phone leaves out a try within 30 s of the last one (`pushSpacing`): a forced run waits for that.
- The headband watcher shows its own short notification when the app opens (channel `auto_start`); it is not the
  push's and is only listed.
"""
import json, socket, subprocess, sys, time, urllib.request
from pathlib import Path

WT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WT / "app" / "tool"))
sys.path.insert(0, str(WT / "scripts"))
import precheck as pc  # noqa: E402
import emu  # noqa: E402
import phone_link as pl  # noqa: E402
import phone_auth as pa  # noqa: E402
import record_check  # noqa: E402
import spans as laptop_spans  # noqa: E402

WORK = Path("/var/tmp/share_smoke")
DEST = WORK / "dest"
LINK_PORT = 18771
PUSH_PORT = 0  # the check's own receiver port: --push-port, else one the OS says is free (push_port_from)
JOB = "877201"
RESULTS: list[tuple[str, bool, str]] = []


def push_port_from(argv: list[str]) -> int:
    """The port the check's receiver listens on: `--push-port N`, else a free one (never the real receiver's 8772)."""
    if "--push-port" in argv:
        return int(argv[argv.index("--push-port") + 1])
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def note(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    pc.say(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")


def tap(text: str, exact: bool = False, wait: float = 60) -> bool:
    t0 = time.time()
    while time.time() - t0 < wait:
        try:
            hit = emu.match(text, exact)
        except Exception:
            hit = None
        if hit:
            pc.sh(f"input tap {hit[1]} {hit[2]}")
            return True
        time.sleep(2)
    return False


def job_lines() -> str:
    """The regular job as Android lists it: periodic, kept, its constraints and its window (`Run time: earliest=..`)."""
    out = pc.sh(f"dumpsys jobscheduler {pc.PKG}", check=False)
    keep, inside = [], False
    for l in out.splitlines():
        if "JOB #" in l:
            inside = f"/{JOB}:" in l
            if inside:
                keep.append(l.strip()[:90])
        elif inside and "JobStatus{" not in l and any(w in l for w in ("PERIODIC", "PERSISTED", "Run time:", "Required constraints",
                                             "Unsatisfied constraints", "Standby bucket", "Network type")):
            keep.append(l.strip())
    return " | ".join(keep)[:900]


def notifications() -> tuple[list[str], list[str]]:
    """(the app's notifications that are not the headband watcher's, the watcher's)."""
    out = pc.sh("dumpsys notification --noredact", check=False)
    mine = [l.strip() for l in out.splitlines() if "NotificationRecord" in l and pc.PKG in l]
    return [l for l in mine if "channel=auto_start" not in l], [l for l in mine if "channel=auto_start" in l]


def no_notification(name: str) -> None:
    ours, watcher = notifications()
    note(name, not ours, "; ".join(ours)[:200] or (f"(the headband watcher's own: {len(watcher)})" if watcher else ""))


def push_state() -> dict:
    try:
        return json.loads((DEST / "phone" / "push-state.json").read_text())
    except (OSError, ValueError):
        return {}


def last_seen() -> str | None:
    s = push_state()
    return s.get("last_try") or s.get("last_push")


def pulls() -> list[dict]:
    try:
        return [json.loads(l) for l in (DEST / "phone" / "pulls.jsonl").read_text().splitlines() if l.strip()]
    except OSError:
        return []


def app_log(grep: str, last: int = 5) -> list[str]:
    out = pc.sh(f"cat {pc.FILES}/logs/app-*.jsonl 2>/dev/null | grep -F '{grep}' | sort | tail -{last}", check=False)
    return [l[:300] for l in out.splitlines()]


def phone_try_age() -> float:
    """Seconds since the phone's last try (its own `transfer/push.json`); large when it never tried."""
    try:
        j = json.loads(pc.sh(f"cat {pc.FILES}/transfer/push.json 2>/dev/null", check=False) or "{}")
        now_ms = int(pc.sh("date +%s%3N", check=False).strip())
        return (now_ms - int(j.get("try_ms", 0))) / 1000
    except (ValueError, TypeError):
        return 1e9


def force_job() -> None:
    """Asks Android to run the regular job now, once the phone's 30 s spacing since its last try is over."""
    t0 = time.time()
    while phone_try_age() < 33 and time.time() - t0 < 60:
        time.sleep(3)
    pc.sh(f"cmd jobscheduler run -f {pc.PKG} {JOB}", check=False)


def wait_for(what, limit: float, every: float = 3):
    t0 = time.time()
    while time.time() - t0 < limit:
        v = what()
        if v:
            return v
        time.sleep(every)
    return None


def signed_who(port: int, key: str) -> str:
    h = pa.signed_headers(key, "GET", "/who", home=False)
    req = urllib.request.Request(f"http://127.0.0.1:{port}/who", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return f"{r.status} {r.read(200).decode()}"
    except Exception as e:
        return f"error {e}"


def keep(*extra: str) -> subprocess.Popen:
    log = open(WORK / "keep.log", "ab")
    args = ["--keep", "--dest", str(DEST), "--address", "10.0.2.2", "--port", str(LINK_PORT), "--no-pages",
            "--no-after-pull", "--push-loopback-home", *extra]
    # the app still names the laptop's port 8772 in `Host`; this check's receiver listens on PUSH_PORT, so here
    # (and only here) it also answers to that name: the real receiver's Host rule is untouched
    start = ("import sys; sys.path.insert(0, sys.argv.pop(1)); import local_http as lh; own = lh.own_hosts; "
             "lh.own_hosts = lambda h, extra=(): own(h, extra) | {'10.0.2.2:8772'}; "
             "import phone_link; sys.exit(phone_link.main(sys.argv[1:]))")
    cmd = [sys.executable, "-I", "-u", "-c", start, str(WT / "scripts"), *args, "--push-port", str(PUSH_PORT)]
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)


def close_app() -> bool:
    """The app out of sight and its process gone, as after hours unused (the jobs stay: no force-stop)."""
    pc.sh("input keyevent KEYCODE_HOME"); time.sleep(3)
    pc.sh(f"am kill {pc.PKG}", check=False); time.sleep(3)
    pid = pc.app_pid()
    if pid:
        pc.sh(f"kill {pid}", check=False); time.sleep(2)
    return not pc.app_pid()


def replaced_are_older_beginnings() -> tuple[bool, str]:
    """Every copy the laptop set aside in `replaced/` is the beginning of the file that took its place (a log the
    phone went on writing: pull_phone.py's ordinary rule), so no two different versions of a file met."""
    root = DEST / "phone" / "replaced"
    bad, n = [], 0
    for old in (p for p in root.rglob("*") if p.is_file()) if root.exists() else ():
        n += 1
        now = DEST / old.relative_to(root).relative_to(old.relative_to(root).parts[0])
        if not now.is_file() or not now.read_bytes().startswith(old.read_bytes()):
            bad.append(str(old.relative_to(root)))
    return not bad, f"{n} set aside" + (f"; not a beginning: {bad[:4]}" if bad else "")


def record_with_sleep(replay: Path) -> list[str]:
    """A recording with a sleep stretch made by the replay build (record_check's steps); the phone's spans files."""
    for r in record_check.check(replay, WORK / "stage"):
        note(f"recording first: {r.name}", r.verdict != "FAIL", f"{r.verdict}: {r.words}"[:300])
    pc.stop_app()
    names = [f.rsplit("/", 1)[1] for f in pc.sh(f"ls {pc.FILES}/spans/*.spans.jsonl 2>/dev/null", check=False).split()]
    note("the phone has the recording's spans file", bool(names), ", ".join(names))
    return names


def spans_on_laptop(names: list[str]) -> None:
    """The phone's spans files, tags and answers as they landed in the laptop's folders."""
    for n in names:
        f = DEST / "phone" / "spans" / n
        same = f.is_file() and f.read_text() == pc.sh(f"cat {pc.FILES}/spans/{n}", check=False)
        got = laptop_spans.read(f).spans if f.is_file() else []
        sleep = [s for s in got if s.kind == "sleep" and s.closed]
        note("the spans file landed on the laptop, the phone's bytes, and its sleep stretch reads there",
             same and bool(sleep), f"phone/spans/{n}: there {f.is_file()}, same bytes {same}, spans {[s.kind for s in got]}")
        tags = DEST / "phone" / "archive" / n.replace(".spans.jsonl", ".tags.json")
        note("the recording's tags (the sheet's chip) landed on the laptop", tags.is_file() and "owner_stop_sheet" in tags.read_text(),
             str(tags.relative_to(DEST)))
    asked = pc.sh(f"ls {pc.FILES}/confirm 2>/dev/null", check=False).split()
    here = sorted(p.name for p in (DEST / "phone" / "confirm").glob("*")) if (DEST / "phone" / "confirm").is_dir() else []
    note("the questions' files on the phone are on the laptop too", set(asked) <= set(here), f"phone {sorted(asked)}; laptop {here}")


def main() -> int:
    global WORK, DEST, PUSH_PORT
    apk = Path(sys.argv[1])
    PUSH_PORT = push_port_from(sys.argv)
    replay = Path(sys.argv[sys.argv.index("--replay") + 1]) if "--replay" in sys.argv else None
    natural = float(sys.argv[sys.argv.index("--natural-min") + 1]) if "--natural-min" in sys.argv else 32
    if "--work" in sys.argv:
        WORK = Path(sys.argv[sys.argv.index("--work") + 1])
        DEST = WORK / "dest"
    pc.use_adb_port(5049)
    WORK.mkdir(parents=True, exist_ok=True)
    pc.OUT = WORK
    em = pc.Emulator(WORK, keep=False)
    em.name = "share_smoke"
    kp = None
    try:
        em.create()
        em.start()
        # --- 0. something else holds port 8765 before the app starts (the owner's phone, 2026-11-20)
        pc.sh("nohup toybox nc -L -p 8765 sleep 100000 >/dev/null 2>&1 &", check=False)
        time.sleep(2)
        pc.say("holder of 8765: " + pc.sh("ss -ltn 2>/dev/null | grep 8765 || netstat -ltn | grep 8765", check=False).strip())
        pc.sh(f"iptables -t nat -A OUTPUT -p tcp -d 10.0.2.2 --dport 8772 -j DNAT --to-destination 10.0.2.2:{PUSH_PORT}")
        rule = pc.sh("iptables -t nat -S OUTPUT", check=False)
        note(f"the emulator sends the app's pushes to this check's receiver (port {PUSH_PORT})", str(PUSH_PORT) in rule,
             rule.strip().splitlines()[-1] if rule.strip() else "no rule")
        span_files = record_with_sleep(replay) if replay else []
        pc.install(apk)
        pc.start_app()
        note("the app's main screen shows", pc.wait_main(240))

        # --- 1. pair: the laptop's link served here, the code handed to the app by its own link
        DEST.mkdir(parents=True, exist_ok=True)
        link = pl.Link(DEST / "phone" / "link.json", name="smoke-laptop", host="10.0.2.2", port=LINK_PORT)
        servers = pl.serve(link, ["127.0.0.1"], LINK_PORT)
        code = link.new_code()
        pc.sh(f"am start -a android.intent.action.VIEW -d '{link.app_link(code)}'")
        note("the pairing dialog's Connect is tapped", tap("Connect", exact=True, wait=90))
        paired = wait_for(lambda: link.key, 60)
        t_pair = time.time()
        note("paired (link.json has a key)", bool(paired))
        tap("OK", exact=True, wait=15)
        for s in servers:
            s.shutdown(); s.server_close()
        key = link.key or ""
        # the receiver alone (no copy pass of the laptop's own) from here to step 7
        kp = keep("--no-mirror")
        time.sleep(8)
        taken = "is taken" in (WORK / "keep.log").read_text(errors="replace")
        note("the check's receiver has its port (no other receiver on this laptop holds it)", not taken,
             (WORK / "keep.log").read_text(errors="replace").strip().splitlines()[-1][:200] if taken else "")
        if taken:
            raise RuntimeError("the receiver's port is taken since it was chosen: run it again (or with --push-port N)")

        # --- 2. the spare port: 8765 is held by nc, the app's server must be on 8766 and say why
        pc.adb("forward", "tcp:18765", "tcp:8765"); pc.adb("forward", "tcp:18766", "tcp:8766")
        got = wait_for(lambda: (lambda a: a if a.startswith("200") else None)(signed_who(18766, key)), 150, 5)
        note("signed /who answers on the spare port 8766 while nc holds 8765", bool(got), str(got or signed_who(18766, key)))
        lines = wait_for(lambda: app_log("is taken"), 30)
        note("the app's log says what holds 8765", bool(lines), (lines or ["-"])[-1])

        # --- 3. the job is armed, nothing of the push is shown
        j = job_lines()
        note(f"Android's job {JOB} is scheduled (periodic, on Wi-Fi, kept over a restart)",
             JOB in j and "PERIODIC" in j and "PERSISTED" in j, j)
        no_notification("no notification of sharing or the push")
        pc.say("the phone's tries so far (Android runs a new periodic job once at once): "
               + "; ".join(app_log('"sub":"push"')) + f" | the receiver: {json.dumps(push_state())}")

        # --- 4. the natural schedule: nothing forced, the app closed; Android runs the regular job by itself in its
        # next window (15 to 30 minutes after it was armed at the pairing)
        note("the app's process is gone", close_app(), pc.app_pid())
        before = last_seen()
        left = max(60.0, natural * 60 - (time.time() - t_pair))
        pc.say(f"waiting up to {left / 60:.0f} min for Android's own run of the job (app closed); its window: {job_lines()}")
        t0 = time.time()
        st3 = wait_for(lambda: last_seen() != before and push_state().get("last_push"), left, 15)
        note("Android ran the regular job by itself, app closed, and the push reached the receiver", bool(st3),
             f"{(time.time() - t_pair) / 60:.1f} min after the pairing: {json.dumps(push_state())}")
        if not st3:
            pc.say("the job as Android lists it now: " + job_lines())
        pushed = [p for p in pulls() if p.get("phone") == "pushed"]
        note("pulls.jsonl has a pushed pass with new files", bool(pushed) and any(p.get("new", 0) > 0 for p in pushed),
             json.dumps(pushed[-1:]))
        got_files = sorted(str(p.relative_to(DEST)) for p in DEST.rglob("*") if p.is_file() and "push-inbox" not in p.parts)
        note("files landed in the laptop's folders", any(f.startswith("phone/logs/") for f in got_files),
             f"{len(got_files)} files, e.g. {got_files[:4]}")
        if replay:
            spans_on_laptop(span_files)
        inbox = DEST / "phone" / "push-inbox"
        note("the inbox is empty after the commit", not inbox.exists() or not any(inbox.iterdir()))
        no_notification("no notification of sharing or the push after Android's own run")

        # --- 5. a forced run with the app closed: the job starts the process by itself
        note("the app's process is gone again", close_app(), pc.app_pid())
        first = push_state().get("last_push")
        time.sleep(62)  # a new minute for last_push
        force_job()
        st2 = wait_for(lambda: push_state().get("last_push") not in (None, first) and push_state().get("last_push"), 240)
        note("with the app closed, a forced job starts it and pushes", bool(st2), json.dumps(push_state()))
        no_notification("still no notification of sharing or the push")

        # --- 6. a forced run with the app in front
        pc.start_app(); pc.wait_main(180)
        second = push_state().get("last_push")
        time.sleep(62)
        force_job()
        st1 = wait_for(lambda: push_state().get("last_push") not in (None, second) and push_state().get("last_push"), 240)
        note("with the app in front, a forced job pushes", bool(st1), json.dumps(push_state()))
        note("the phone's log has the push's line", bool(app_log("sent to the laptop")), (app_log("sent to the laptop") or ["-"])[-1])

        # --- 7. the pull beside it: the laptop's own copy through the cable, into the same folders
        kp.terminate(); kp.wait(timeout=20)
        up = wait_for(lambda: signed_who(18766, key).startswith("200"), 150, 5)
        port = 18766 if up else 18765
        n_before = len(pulls())
        kp = keep("--phone-at", f"http://127.0.0.1:{port}", "--every", "0.5")
        after = wait_for(lambda: [p for p in pulls()[n_before:] if p.get("phone") != "pushed"], 150, 5) or []
        log = (WORK / "keep.log").read_text(errors="replace")
        dmg = sum(p.get("damaged", 0) for p in pulls())
        note("the laptop's own copy pass works beside the push (same folders, nothing damaged)",
             "Connected: copying from the phone" in log and bool(after) and dmg == 0,
             f"damaged {dmg}; the phone's server on {port - 10000}; new passes {json.dumps(after[-2:])}")
        third = push_state().get("last_push")
        time.sleep(62)
        force_job()
        st4 = wait_for(lambda: push_state().get("last_push") not in (None, third) and push_state().get("last_push"), 240)
        note("a push while the laptop's own copy loop runs", bool(st4), json.dumps(push_state()))
        time.sleep(40)  # one more pass of the laptop's own after it
        dmg = sum(p.get("damaged", 0) for p in pulls())
        ok, detail = replaced_are_older_beginnings()
        note("nothing damaged, and no file met in two different versions", ok and dmg == 0, f"damaged {dmg}; {detail}")
        pc.say("keep.log tail:\n  " + "\n  ".join(l[:200] for l in (WORK / 'keep.log').read_text(errors='replace').splitlines()[-16:]))
        pc.say("phone push log:\n  " + "\n  ".join(app_log('"sub":"push"', last=12)))
        crash = [l for l in pc.logcat().splitlines() if "FATAL EXCEPTION" in l or ("ANR in" in l and pc.PKG in l)]
        note("no crash or ANR of the app in logcat", not crash, "; ".join(crash)[:300])
    except Exception as e:
        note("the check ran to its end", False, f"{type(e).__name__}: {e}")
    finally:
        if kp is not None and kp.poll() is None:
            kp.terminate()
        try:
            (WORK / "logcat.txt").write_text(pc.logcat())
        except Exception:
            pass
        em.stop()
    print("\n== result")
    for name, ok, detail in RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"\n        {detail}" if detail else ""))
    return 0 if all(ok for _, ok, _ in RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
