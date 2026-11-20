#!/usr/bin/env python3
"""The pre-install check: one command on a temporary emulator before an APK goes to the phone (app/README.md,
"Pre-install check"; DECISIONS 733).

    python3 app/tool/precheck.py --old LAST_ON_PHONE.apk --new CANDIDATE.apk \\
        [--replay REPLAY_BUILD.apk] [--nights DIR] [--reports DIR] [--out DIR] [--adb-port N] [--keep]

It makes a new AVD under /var/tmp with 2 cores (the phone's arm64 APK runs there through Android's ARM translation,
which crashes ONNX Runtime with 4 cores), boots it headless, and checks what reached the owner's phone on 2026-11-19/20:

  (a) update over yesterday: the old APK with real finished nights and their reports (read-only copies of
      --nights and --reports, by default the main checkout's _local/recordings and _local/phone/nights), then the new
      APK over it (`adb install -r`): no finished night may be scored again, every report stays byte for byte.
  (b) Share on Wi-Fi while the app sits in the background, Doze forced, its standby bucket "rare" and `am freeze`
      sent: `/state` must answer within 5 s.
  (c) a replayed noisy work session (the made-up "talking" recording through the replay build's headband, at real
      speed for 6.5 minutes): no break may start by itself. Runs when --replay is given (DECISIONS 735; the
      work-day fix it waited for is in main since integration 17).
  (d) logcat, ANRs and Android's exit reasons are collected; a crash or an ANR of the app fails, and the app's own
      files/app-starts.log must have recorded its starts with the exit reasons.

Prints a plain PASS / FAIL / SKIP list; exit status 1 when anything failed. About 10 minutes, 16 with (c).

Only its own things: a private adb server on port 5041 (--adb-port; ADB_LIBUSB=0 ADB_USB=0) and the emulator's own serial on
every adb call, never another device or the default adb server; the emulator and that server are stopped by PID
and the AVD deleted at the end (--keep leaves the AVD and the seed copies). Run it in the heavy build slot.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import lzma
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
REPO = APP.parent
sys.path.insert(0, str(HERE))
import emu  # noqa: E402  (the same folder: the semantics-tree driver)

PKG = "io.github.utof.eeg_tracker"
ACTIVITY = f"{PKG}/.MainActivity"
ADB_PORT = 5041
IMAGE = "system-images;android-36;google_apis;x86_64"
SDK = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "android-sdk")
ADB = str(SDK / "platform-tools" / "adb")
EMULATOR = str(SDK / "emulator" / "emulator")
AVDMANAGER = str(SDK / "cmdline-tools" / "latest" / "bin" / "avdmanager")
FILES = f"/data/data/{PKG}/files"
SHARE_PORT = 8765
TALK_MIN = 6.5  # the talking replay: a break would start after 5 minutes of "not worn"
MAIN = Path("/media/vboxuser/G-samsung/0utoffiles/code/eeg_tracker")  # the main checkout: real nights, read-only

ENV = {**os.environ, "ADB_LIBUSB": "0", "ADB_USB": "0", "ANDROID_ADB_SERVER_PORT": str(ADB_PORT)}
ENV.pop("ANDROID_SERIAL", None)
# the server's address as IPv4: with `-P` alone a client tries [::1] when 127.0.0.1 refuses, and on this laptop a
# connect to [::1] never returns (a dead server would hang every call instead of failing)
SERVER = ["-L", f"tcp:127.0.0.1:{ADB_PORT}"]
SERIAL = ""


def use_adb_port(port: int) -> None:
    """Our private server on [port] instead of 5041 (another check's server may hold that one)."""
    global ADB_PORT
    ADB_PORT = port
    ENV["ANDROID_ADB_SERVER_PORT"] = str(port)
    SERVER[:] = ["-L", f"tcp:127.0.0.1:{port}"]


def say(line: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {line}", flush=True)


def run(cmd: list[str], timeout: float = 120, check: bool = True, **kw) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, env=ENV, text=True, capture_output=True, timeout=timeout, check=check, **kw)


def adb(*args: str, timeout: float = 120, check: bool = True) -> str:
    """adb on our server and our emulator only."""
    return run([ADB, *SERVER, "-s", SERIAL, *args], timeout=timeout, check=check).stdout


def sh(command: str, timeout: float = 120, check: bool = True) -> str:
    return adb("shell", command, timeout=timeout, check=check)


def _emu_adb(*args: str, timeout: float = 60) -> bytes:
    return subprocess.run(
        [ADB, *SERVER, "-s", SERIAL, *args], env=ENV, check=True, capture_output=True, timeout=timeout
    ).stdout


emu.adb = _emu_adb  # emu.py's taps and texts go through our server and serial too


@dataclass
class Result:
    name: str
    verdict: str  # PASS, FAIL, SKIP
    words: str
    details: list[str] = field(default_factory=list)


# ---- the emulator -------------------------------------------------------------------------------------------------


def free_port_pair() -> int:
    """An even console port whose adb port (next one) is free too, from 5584 down."""
    for port in range(5584, 5554, -2):
        ok = True
        for p in (port, port + 1):
            with socket.socket() as s:
                try:
                    s.bind(("127.0.0.1", p))
                except OSError:
                    ok = False
        if ok:
            return port
    raise SystemExit("no free emulator port between 5556 and 5585")


class Emulator:
    def __init__(self, work: Path, keep: bool):
        self.work = work
        self.keep = keep
        self.avd_home = work / "avd"
        self.name = "eeg_precheck"
        self.proc: subprocess.Popen[bytes] | None = None
        self.server: subprocess.Popen[bytes] | None = None

    def create(self) -> None:
        self.avd_home.mkdir(parents=True, exist_ok=True)
        env = {**ENV, "ANDROID_AVD_HOME": str(self.avd_home)}
        subprocess.run(
            [AVDMANAGER, "create", "avd", "-n", self.name, "-k", IMAGE, "-d", "pixel_6", "-p",
             str(self.avd_home / f"{self.name}.avd"), "--force"],
            env=env, input="no\n", text=True, capture_output=True, check=True, timeout=300,
        )
        cfg = self.avd_home / f"{self.name}.avd" / "config.ini"
        lines = [l for l in cfg.read_text().splitlines()
                 if not l.startswith(("hw.cpu.ncore", "hw.ramSize", "disk.dataPartition.size", "hw.keyboard"))]
        # 2 cores: the arm64 APK's ONNX Runtime crashes at launch under the translation with 4 (app/README.md)
        lines += ["hw.cpu.ncore=2", "hw.ramSize=3072", "disk.dataPartition.size=6G", "hw.keyboard=yes"]
        cfg.write_text("\n".join(lines) + "\n")

    def start(self) -> None:
        global SERIAL
        # our own adb server, a child of this script (its PID is stopped at the end); a client cannot start one at an
        # explicit address
        self.server = subprocess.Popen(
            [ADB, "-L", f"tcp:{ADB_PORT}", "server", "nodaemon"], env=ENV, stdin=subprocess.DEVNULL,
            stdout=open(self.work / "adb-server.log", "wb"), stderr=subprocess.STDOUT, start_new_session=True,
        )
        t0 = time.time()
        while run([ADB, *SERVER, "devices"], timeout=10, check=False).returncode != 0:
            if time.time() - t0 > 30 or self.server.poll() is not None:
                raise RuntimeError(f"our adb server did not start on port {ADB_PORT} (see adb-server.log)")
            time.sleep(1)
        port = free_port_pair()
        SERIAL = f"emulator-{port}"
        env = {**ENV, "ANDROID_AVD_HOME": str(self.avd_home)}
        log = open(self.work / "emulator.log", "wb")
        self.proc = subprocess.Popen(
            [EMULATOR, "-avd", self.name, "-port", str(port), "-no-window", "-no-snapshot", "-no-boot-anim",
             "-no-audio", "-timezone", "Europe/Moscow", "-gpu", "swiftshader_indirect"],
            env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        say(f"emulator {SERIAL} starting (pid {self.proc.pid}, AVD in {self.avd_home})")
        t0 = time.time()
        while SERIAL not in run([ADB, *SERVER, "devices"], timeout=10, check=False).stdout:
            if self.proc.poll() is not None:
                raise RuntimeError("the emulator ended while starting (see emulator.log)")
            if time.time() - t0 > 90:
                # it did not tell our server it is there: reach its adb port directly
                run([ADB, *SERVER, "connect", f"127.0.0.1:{port + 1}"], timeout=30, check=False)
                SERIAL = f"127.0.0.1:{port + 1}"
                say(f"  reached as {SERIAL}")
                break
            time.sleep(2)
        run([ADB, *SERVER, "-s", SERIAL, "wait-for-device"], timeout=600)
        while sh("getprop sys.boot_completed", check=False).strip() != "1":
            if time.time() - t0 > 600 or self.proc.poll() is not None:
                raise RuntimeError("the emulator did not boot (see emulator.log)")
            time.sleep(3)
        adb("root", check=False)
        time.sleep(3)
        if SERIAL.startswith("127.0.0.1:"):  # adbd restarted as root: the TCP link goes with it
            run([ADB, *SERVER, "connect", SERIAL], timeout=30, check=False)
        run([ADB, *SERVER, "-s", SERIAL, "wait-for-device"], timeout=120)
        while sh("getprop sys.boot_completed", check=False).strip() != "1":
            time.sleep(2)
        for k in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            sh(f"settings put global {k} 0", check=False)
        sh("svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard", check=False)
        sh("logcat -G 16M; logcat -c", check=False)
        say(f"booted in {time.time() - t0:.0f} s")

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            if SERIAL and self.server is not None and self.server.poll() is None:
                run([ADB, *SERVER, "-s", SERIAL, "emu", "kill"], timeout=30, check=False)
            try:
                self.proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGTERM)  # the group this script made for it, nothing else
                try:
                    self.proc.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)
        if self.server is not None and self.server.poll() is None:
            self.server.terminate()  # our own server's PID, nothing else
            try:
                self.server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.server.kill()
        if not self.keep:
            shutil.rmtree(self.avd_home, ignore_errors=True)


# ---- the app ------------------------------------------------------------------------------------------------------


def install(apk: Path) -> None:
    say(f"install -r {apk.name}")
    adb("install", "-r", "-g", str(apk), timeout=600)


def start_app() -> None:
    sh(f"input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; am start -W -n {ACTIVITY}", timeout=180)


def app_pid() -> str:
    return sh(f"pidof {PKG}", check=False).strip()


def stop_app() -> None:
    sh(f"am force-stop {PKG}", check=False)


def logcat(since: str | None = None) -> str:
    """The whole log buffer, or from [since] (`MM-DD HH:MM:SS.mmm`) on."""
    args = ["logcat", "-d", "-v", "threadtime"] + (["-T", since] if since else [])
    return adb(*args, timeout=120, check=False)


def device_time() -> str:
    return sh("date '+%m-%d %H:%M:%S.000'").strip()


def seed(pairs: list[tuple[Path, str]], stage: Path) -> None:
    """Copies local files into the app's files/ (paths relative to it), owned by the app, with its SELinux label."""
    stop_app()
    sh("rm -rf /data/local/tmp/seed && mkdir -p /data/local/tmp/seed")
    stage.mkdir(parents=True, exist_ok=True)
    for local, rel in pairs:
        sh(f"mkdir -p /data/local/tmp/seed/{Path(rel).parent}")
        adb("push", str(local), f"/data/local/tmp/seed/{rel}", timeout=600)
    sh(f"mkdir -p {FILES}")
    uid = sh(f"stat -c %u /data/data/{PKG}").strip()
    ctx = sh(f"ls -Zd /data/data/{PKG}").split()[0]
    sh(f"cp -r /data/local/tmp/seed/. {FILES}/ && chown -R {uid}:{uid} {FILES} && chcon -R {ctx} {FILES}"
       f" && rm -rf /data/local/tmp/seed")


OUT: Path | None = None  # the run's log folder (screenshots of a screen a step could not use)


def screen_words(tag: str) -> list[str]:
    """What is on screen now, for the details, and a screenshot `<out>/<tag>.png`."""
    try:
        if OUT is not None:
            (OUT / f"{tag}.png").write_bytes(emu.adb("exec-out", "screencap", "-p"))
        return [f"on screen ({tag}): " + " / ".join(l[:60] for l, _, _ in emu.nodes())[:600]]
    except Exception as e:  # the screen is only evidence
        return [f"on screen ({tag}): not readable ({e})"]


def wait_main(limit: float = 120) -> bool:
    """Until the app's main screen shows its bottom bar (a cold start under the ARM translation takes a while); taps
    Wait on an "isn't responding" dialog meanwhile."""
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            labels = emu.nodes()
        except Exception:
            labels = []
        if any(l.startswith("Night | Tab") for l, _, _ in labels):
            return True
        for l, x, y in labels:
            if l.strip() == "Wait":
                sh(f"input tap {x} {y}")
        time.sleep(3)
    return False


def open_tab(name: str) -> bool:
    """Taps the bottom bar's tab [name] (Night, Sessions, Signal, Trends, More)."""
    _, h = emu.screen_size()
    for label, x, y in emu.nodes():
        if y > h * 0.85 and label.split(" | ")[0].split("\n")[0].strip().startswith(name):
            sh(f"input tap {x} {y}")
            time.sleep(2)
            return True
    return False


def find(text: str, exact: bool = False, scrolls: int = 12) -> tuple[str, int, int] | None:
    """The first element showing [text], scrolling down to it (from the top) when it is not on screen."""
    hit = emu.match(text, exact)
    for _ in range(scrolls):
        if hit:
            return hit
        emu.scroll("down")
        hit = emu.match(text, exact)
    return hit


def find_on_tab(tab: str, text: str, exact: bool = False, limit: float = 150) -> tuple[str, int, int] | None:
    """[text] on the bottom bar's [tab], tried again from the top until [limit] s: a section can come only once the
    screen's first read of the app's folder is done, which takes a while after a cold start on the emulator."""
    t0 = time.time()
    while True:
        open_tab(tab)
        for _ in range(4):
            emu.scroll("up")
        hit = find(text, exact)
        if hit is not None or time.time() - t0 > limit:
            return hit
        time.sleep(5)


def report_hashes() -> dict[str, str]:
    out = sh(f"cd {FILES}/nights 2>/dev/null && sha256sum *.report.json", check=False)
    return {l.split()[1]: l.split()[0] for l in out.splitlines() if len(l.split()) == 2}


def scoring_lines(log: str) -> list[str]:
    return [l for l in log.splitlines() if "sleep scoring of" in l]


# ---- (a) update over yesterday -------------------------------------------------------------------------------------


def night_files(reports: Path, nights: Path, stage: Path) -> list[tuple[Path, str]]:
    """Each report and the recordings it names (`inputs`), with their .idx .log .header.json .markers.jsonl; an
    `.f32.xz` from the laptop's archive is unpacked into [stage] (the source is only read)."""
    pairs: list[tuple[Path, str]] = []
    for rep in sorted(reports.glob("*.report.json")):
        try:
            inputs = json.loads(rep.read_text())["inputs"]
        except (OSError, ValueError, KeyError):
            continue
        found = []
        for i in inputs:
            name, size = i["file"], i["bytes"]
            stem = name[: -len(".f32")]
            plain, xz = nights / name, nights / f"{name}.xz"
            if plain.exists() and plain.stat().st_size == size:
                f32 = plain
            elif xz.exists():
                f32 = stage / name
                if not f32.exists():
                    with lzma.open(xz) as src, open(f32, "wb") as dst:
                        shutil.copyfileobj(src, dst, 1 << 20)
                if f32.stat().st_size != size:
                    break
            else:
                break
            found.append((f32, f"recordings/{name}"))
            for ext in (".idx", ".log", ".header.json", ".markers.jsonl"):
                side = nights / f"{stem}{ext}"
                if side.exists():
                    found.append((side, f"recordings/{stem}{ext}"))
        else:
            pairs += found + [(rep, f"nights/{rep.name}")]
            continue
        say(f"  {rep.name}: its recordings are not all in {nights} at their sizes; left out")
    return pairs


def check_update(old: Path, new: Path, reports: Path, nights: Path, stage: Path) -> Result:
    pairs = night_files(reports, nights, stage)
    names = sorted(p[1][len("nights/"):-len(".report.json")] for p in pairs if p[1].startswith("nights/"))
    if not names:
        return Result("(a) update over yesterday", "FAIL", f"no night with its recordings found in {reports} / {nights}")
    install(old)
    start_app()
    time.sleep(8)
    seed(pairs, stage / "push")
    say(f"  seeded {len(names)} finished nights ({', '.join(names)}), {sum(p[0].stat().st_size for p in pairs) >> 20} MB")
    t_old = device_time()
    start_app()
    # the app waits 45 s after it opens before it scores anything (DECISIONS 583); give the old one time to decide
    time.sleep(75)
    old_lines = scoring_lines(logcat(t_old))
    if any(": starting" in l or "going on" in l for l in old_lines):
        say("  the old APK scores a night again (the old bug, or a report it cannot read); waiting for it to finish")
        t0 = time.time()
        while time.time() - t0 < 900 and not any(": done" in l or "failed" in l for l in scoring_lines(logcat(t_old))):
            time.sleep(15)
    before = report_hashes()
    t_new = device_time()
    install(new)  # an update: Android ends the old process
    start_app()
    time.sleep(100)
    new_lines = scoring_lines(logcat(t_new))
    after = report_hashes()
    again = [l.split("sleep scoring of", 1)[1].strip() for l in new_lines if ": starting" in l or "going on" in l]
    changed = sorted(k for k in before if after.get(k) != before[k])
    details = [f"old APK: {len(old_lines)} scoring lines"] + [f"old: {l}" for l in old_lines[-5:]]
    details += [f"new: {l}" for l in new_lines]
    alive = bool(app_pid())
    if again or changed or not alive:
        why = []
        if again:
            why.append(f"scored again after the update: {'; '.join(again)}")
        if changed:
            why.append(f"reports changed: {', '.join(changed)}")
        if not alive:
            why.append("the new app is not running after its start")
        return Result("(a) update over yesterday", "FAIL", "; ".join(why), details)
    return Result(
        "(a) update over yesterday", "PASS",
        f"{len(before)} finished nights kept their reports byte for byte after the update; none scored again", details,
    )


# ---- (b) Share on Wi-Fi while frozen -------------------------------------------------------------------------------


def share_token() -> str | None:
    xml = sh(f"cat /data/data/{PKG}/shared_prefs/*.xml", check=False)
    for m in re.finditer(r"(\{[^<>]*token[^<>]*\})", html.unescape(xml)):
        try:
            j = json.loads(m.group(1))
        except ValueError:
            continue
        if isinstance(j, dict) and isinstance(j.get("token"), str) and j.get("on"):
            return j["token"]
    return None


def ask_state(port: int, token: str, timeout: float = 5) -> tuple[bool, float, str]:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/state", headers={"Authorization": f"Bearer {token}"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(400).decode("utf-8", "replace")
            return r.status == 200, time.time() - t0, body[:120]
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return False, time.time() - t0, str(e)


def proc_state() -> str:
    out = quiet(f"dumpsys activity processes {PKG}")
    m = re.search(r"curProcState=(\d+)", out) or re.search(r"procState=(\d+)", out)
    frozen = "isFrozen=true" in out
    fg = "isForeground=true" in quiet(f"dumpsys activity services {PKG}")
    return f"procState {m.group(1) if m else '?'}, foreground service {'yes' if fg else 'no'}, frozen {'yes' if frozen else 'no'}"


def quiet(command: str, timeout: float = 30) -> str:
    """A shell command whose failure or hang (an overloaded emulator) is only a line in the details."""
    try:
        return sh(command + " 2>&1", timeout=timeout, check=False).strip()
    except subprocess.TimeoutExpired:
        return f"no answer in {timeout:.0f} s"


def check_share() -> Result:
    name = "(b) Share on Wi-Fi in the background"
    start_app()
    if not wait_main():
        return Result(name, "FAIL", "the app's main screen did not come up within 2 minutes", screen_words("b-start"))
    if share_token() is None:
        hit = find_on_tab("More", "Share on Wi-Fi")
        if hit is None:
            return Result(name, "FAIL", "the Share on Wi-Fi switch was not found on the More tab", screen_words("b-share"))
        _, x, y = hit
        sh(f"input tap {x} {y}")
        time.sleep(4)
        emu.adb("shell", "input", "keyevent", "KEYCODE_BACK")  # the sheet, if it opened
    token = None
    for _ in range(10):
        token = share_token()
        if token:
            break
        time.sleep(1)
    if not token:
        return Result(name, "FAIL", "sharing did not switch on (no code saved)")
    local = 18765 + (os.getpid() % 1000)
    adb("forward", f"tcp:{local}", f"tcp:{SHARE_PORT}")
    details = []
    try:
        ok, s, body = ask_state(local, token)
        details.append(f"in front: {'answered' if ok else 'no answer'} in {s:.2f} s ({body})")
        if not ok:
            return Result(name, "FAIL", f"/state did not answer even with the app in front ({body})", details)
        sh("input keyevent KEYCODE_HOME")
        time.sleep(15)  # past Android 14+'s 10 s before a cached app is frozen
        details.append(f"in the background: {proc_state()}")
        for c in ("dumpsys battery unplug", f"am set-inactive {PKG} true", f"am set-standby-bucket {PKG} rare",
                  "dumpsys deviceidle force-idle"):
            out = quiet(c)
            details.append(f"$ {c}{(': ' + out[:100]) if out else ''}")
        time.sleep(20)
        state = proc_state()
        details.append(f"after Doze and the rare bucket: {state}")
        answers = [ask_state(local, token) for _ in range(3)]
        for ok, s, body in answers:
            details.append(f"/state: {'answered' if ok else 'no answer'} in {s:.2f} s{'' if ok else ' (' + body + ')'}")
        # harder than stock Android: a forced freeze (`am freeze`), which Android never applies to a process with a
        # foreground service; nothing can answer while frozen, but the server must answer again once thawed. (An `am
        # freeze` of a process Android froze already hangs on the emulator: then it is not sent.)
        thawed = (False, 0.0, "not tried")
        if "frozen no" in state:
            out = quiet(f"am freeze {PKG}")
            details.append(f"$ am freeze {PKG}: {out[:100]}")
            frozen = [ask_state(local, token, timeout=3) for _ in range(2)]
            details.append(f"while frozen: {sum(f[0] for f in frozen)} of 2 answered (none expected)")
            quiet(f"am unfreeze {PKG}")
            thawed = ask_state(local, token, timeout=10)
            details.append(f"after am unfreeze: {'answered' if thawed[0] else 'no answer'} in {thawed[1]:.2f} s")
    finally:
        for c in (f"am unfreeze {PKG}", "dumpsys deviceidle unforce", "dumpsys battery reset",
                  f"am set-inactive {PKG} false", f"am set-standby-bucket {PKG} active"):
            quiet(c)
        adb("forward", "--remove", f"tcp:{local}", check=False)
    if not all(a[0] for a in answers):
        return Result(name, "FAIL", f"/state answered {sum(a[0] for a in answers)} of 3 times within 5 s with the app in "
                      f"the background, Doze forced and its standby bucket rare ({state})", details)
    if not thawed[0]:
        return Result(name, "FAIL", f"/state did not answer again after a forced freeze was lifted ({thawed[2]})", details)
    worst = max(a[1] for a in answers)
    return Result(name, "PASS", f"/state answered 3 of 3 within {worst:.2f} s in the background with Doze forced and "
                  f"the standby bucket rare ({state}); after a forced freeze it answered again in {thawed[1]:.2f} s",
                  details)


# ---- (c) a replayed noisy work session ----------------------------------------------------------------------------


def make_talking(stage: Path) -> Path:
    """The made-up talking recording (tool/replay_scenario.dart): `<stage>/talking-work/<stamp>.f32`."""
    out = stage / "scenarios"
    done = list((out / "talking-work").glob("*.f32"))
    if not done:
        run(["dart", "run", "tool/replay_scenario.dart", "talking-work", str(out)], timeout=900, cwd=str(APP))
        done = list((out / "talking-work").glob("*.f32"))
    return done[0]


def check_talking(replay: Path, stage: Path) -> Result:
    name = "(c) a replayed noisy work session"
    f32 = make_talking(stage)
    stem = f32.name[: -len(".f32")]
    install(replay)
    plan = stage / "plan.json"
    plan.write_text(json.dumps({"files": [f"talking/{f32.name}"], "speed": 1}))
    pairs = [(plan, "replay/plan.json")]
    for ext in (".f32", ".idx", ".log", ".header.json"):
        pairs.append((f32.with_name(stem + ext), f"replay/talking/{stem}{ext}"))
    seed(pairs, stage / "push-replay")
    sh("cmd bluetooth_manager enable", check=False)  # the work screen asks for Bluetooth before it starts
    time.sleep(3)
    start_app()
    if not wait_main():
        return Result(name, "FAIL", "the app's main screen did not come up within 2 minutes", screen_words("c-start"))
    hit = find_on_tab("Sessions", "Work session", exact=True)
    if hit is None:
        return Result(name, "FAIL", "the Work session button was not found on the Sessions tab", screen_words("c-tab"))
    sh(f"input tap {hit[1]} {hit[2]}")
    time.sleep(3)
    hit = find("Start work session", exact=True, scrolls=3)
    if hit is None:
        return Result(name, "FAIL", "Start work session was not found on the work page", screen_words("c-work"))
    sh(f"input tap {hit[1]} {hit[2]}")
    details = []
    t0 = time.time()
    broke = False
    while time.time() - t0 < TALK_MIN * 60:
        time.sleep(30)
        texts = [l for l, _, _ in emu.nodes()]
        line = " | ".join(t for t in texts if len(t) < 90)[:300]
        details.append(f"+{(time.time() - t0) / 60:.1f} min: {line}")
        # on a break the readout says "on this break" (and the button "Back"); "On a break" is the button's word
        # while working, so it cannot tell
        if any("on this break" in t.lower() for t in texts):
            broke = True
    hit = emu.match("Stop", exact=True)
    if hit:
        sh(f"input tap {hit[1]} {hit[2]}")
        time.sleep(2)
        confirm = emu.match("Stop", exact=True)
        if confirm:
            sh(f"input tap {confirm[1]} {confirm[2]}")
        time.sleep(5)
    newest = sh(f"ls -t {FILES}/work-sessions/*.work.json 2>/dev/null | head -1", check=False).strip()
    if not newest:
        return Result(name, "FAIL", "no work session was saved", details)
    j = json.loads(sh(f"cat {newest}"))
    breaks = j.get("breaks") if isinstance(j.get("breaks"), list) else []
    count = len(breaks)
    details.append(f"saved: headband {j.get('headband')!r}, breaks {count}, ended {j.get('ended')!r}")
    if "Replay" not in str(j.get("headband")):
        return Result(name, "FAIL", f"the session did not use the replay (headband {j.get('headband')!r})", details)
    if count or broke:
        return Result(name, "FAIL", f"talking started {max(count, 1)} break(s) by itself within {TALK_MIN} minutes", details)
    return Result(name, "PASS", f"{TALK_MIN} minutes of replayed talking: no break started", details)


# ---- (d) what the run left -----------------------------------------------------------------------------------------


def collect(out: Path, started_ms: int) -> Result:
    name = "(d) crashes, ANRs, exit reasons"
    log = logcat()
    (out / "logcat.txt").write_text(log)
    exits = sh(f"dumpsys activity exit-info {PKG}", check=False)
    (out / "exit-info.txt").write_text(exits)
    anr_dir = out / "anr"
    anr_dir.mkdir(exist_ok=True)
    adb("pull", "/data/anr/.", str(anr_dir), check=False, timeout=120)
    starts = sh(f"cat {FILES}/app-starts.log", check=False)
    (out / "app-starts.log").write_text(starts)
    problems = []
    lines = log.splitlines()
    # the app's Dart errors nobody caught (the only Flutter app on the emulator); a missing plugin is a broken build
    # (2026-11-20: an APK without its GeneratedPluginRegistrant answered every plugin call so)
    unhandled = [l.split("Unhandled Exception:", 1)[1].strip()[:160] for l in lines
                 if " flutter " in l and "Unhandled Exception:" in l]
    for u in sorted({u for u in unhandled if u.startswith("MissingPluginException")}):
        problems.append(u)
    for i, l in enumerate(lines):
        if f"ANR in {PKG}" in l:
            problems.append(l.strip())
        if "FATAL EXCEPTION" in l and any(f"Process: {PKG}" in x for x in lines[i : i + 3]):
            problems.append(l.strip())
        if "Fatal signal" in l and PKG.split(".")[-1] in l:
            problems.append(l.strip())
    reasons = []
    for block in exits.split("ApplicationExitInfo #")[1:]:
        r = re.search(r"reason=(\d+) \(([^)]*)\)", block)
        ts = re.search(r"timestamp=(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", block)
        desc = re.search(r"description=(.*)", block)
        if not r:
            continue
        when = time.mktime(time.strptime(ts.group(1), "%Y-%m-%d %H:%M:%S")) * 1000 if ts else started_ms
        if when + 60_000 < started_ms:
            continue
        reasons.append(f"{r.group(2).strip().lower()}{(' (' + desc.group(1).strip() + ')') if desc else ''}")
        if r.group(1) in ("4", "5", "6"):  # CRASH, CRASH_NATIVE, ANR
            problems.append(f"exit reason {r.group(2)}")
    anrs = []
    for f in sorted(anr_dir.iterdir()) if anr_dir.exists() else []:
        head = f.read_bytes()[:4000].decode("utf-8", "replace")
        m = re.search(r"Cmd line: (\S+)", head)
        who = m.group(1) if m else "?"
        anrs.append(f"{f.name} ({who})")
        if who.startswith(PKG):
            problems.append(f"ANR trace of the app: {f.name}")
    starts_ok = starts.count("start: screen engine") >= 2 and "previous process ended:" in starts
    details = [f"exit reasons this run: {', '.join(reasons) or 'none'}", f"/data/anr: {', '.join(anrs) or 'empty'}",
               f"uncaught Dart errors: {len(unhandled)}"]
    details += [f"uncaught: {u}" for u in sorted(set(unhandled))[:8]]
    details += [f"app-starts.log: {len(starts.splitlines())} lines"] + [f"app-starts: {l}" for l in starts.splitlines()[-8:]]
    if problems:
        return Result(name, "FAIL", "; ".join(sorted(set(problems)))[:300], details)
    if not starts_ok:
        return Result(name, "FAIL", "files/app-starts.log did not record the starts and Android's exit reasons", details)
    return Result(name, "PASS", f"no crash or ANR; {len(reasons)} exit reasons, all in files/app-starts.log too"
                  f"{f'; {len(unhandled)} uncaught Dart errors (details)' if unhandled else ''}", details)


# ---- the run -------------------------------------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--old", type=Path, required=True, help="the APK on the phone now (the last one installed there)")
    p.add_argument("--new", type=Path, required=True, help="the candidate APK")
    p.add_argument("--replay", type=Path, help="the replay build of the candidate (--dart-define=EEG_REPLAY=true)")
    p.add_argument("--talking", action="store_true", help="kept for old commands: (c) runs whenever --replay is given")
    p.add_argument("--nights", type=Path, default=MAIN / "_local" / "recordings", help="recordings to seed (read-only)")
    p.add_argument("--reports", type=Path, default=MAIN / "_local" / "phone" / "nights", help="the phone's night reports")
    p.add_argument("--out", type=Path, help="where the logs go (default: the run's folder under /var/tmp)")
    p.add_argument("--only", default="abcd", help="which checks, e.g. 'bd'")
    p.add_argument("--keep", action="store_true", help="keep the AVD and the copies (the emulator still stops)")
    p.add_argument("--adb-port", type=int, default=ADB_PORT, help="our private adb server's port (default 5041)")
    a = p.parse_args()
    use_adb_port(a.adb_port)
    for apk in (a.old, a.new, *([a.replay] if a.replay else [])):
        if not apk.is_file():
            p.error(f"{apk} is not there")
    stamp = time.strftime("%Y-%m-%d-%H%M%S")
    work = Path(f"/var/tmp/eeg-precheck-{stamp}")
    out = a.out or work / "out"
    out.mkdir(parents=True, exist_ok=True)
    global OUT
    OUT = out
    stage = work / "stage"
    t0 = time.time()
    started_ms = int(t0 * 1000)
    results: list[Result] = []
    em = Emulator(work, a.keep)
    talking_job = None
    if "c" in a.only and a.replay and not list((stage / "scenarios" / "talking-work").glob("*.f32")):
        stage.mkdir(parents=True, exist_ok=True)  # made while the emulator boots
        talking_job = subprocess.Popen(["dart", "run", "tool/replay_scenario.dart", "talking-work", str(stage / "scenarios")],
                                       cwd=str(APP), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        em.create()
        em.start()
        if "a" in a.only:
            say("(a) update over yesterday")
            results.append(check_update(a.old, a.new, a.reports, a.nights, stage))
        else:
            install(a.new)
        if "b" in a.only:
            say("(b) Share on Wi-Fi in the background")
            results.append(check_share())
        if "c" in a.only:
            if not a.replay:
                results.append(Result("(c) a replayed noisy work session", "SKIP",
                                      "needs the candidate's replay build: --replay <replay build>"))
            else:
                say("(c) a replayed noisy work session")
                if talking_job:
                    talking_job.wait(timeout=900)
                results.append(check_talking(a.replay, stage))
        if "d" in a.only:
            say("(d) crashes, ANRs, exit reasons")
            results.append(collect(out, started_ms))
    except Exception as e:  # the list says what ran; the error is the run's own failure
        results.append(Result("the check itself", "FAIL", f"{type(e).__name__}: {e}"))
        try:
            (out / "logcat.txt").write_text(logcat())
        except Exception:
            pass
    finally:
        try:
            em.stop()
        except Exception as e:
            results.append(Result("stopping the emulator", "FAIL", f"{type(e).__name__}: {e}"))
        if not a.keep:
            shutil.rmtree(stage, ignore_errors=True)
    (out / "results.json").write_text(json.dumps([r.__dict__ for r in results], indent=1))
    with open(out / "details.txt", "w") as f:
        for r in results:
            f.write(f"{r.verdict} {r.name}: {r.words}\n" + "".join(f"    {d}\n" for d in r.details))
    print()
    print(f"Pre-install check of {a.new.name} (over {a.old.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
