#!/usr/bin/env python3
"""Run the link probe on one device and print the table (DECISIONS row 1020).

  run_probe.py --serial SERIAL [--adb-port PORT] [--autostart keep|off|on|both] [--swipe auto|manual|kill] [--uninstall]

Question it answers: can the reader app reach the source app's provider, bound service and result screen when the source is
(1) in front, (2) in the background, (3) in the background with a foreground service, (4) swiped away from recents, (5) force-stopped?
It installs both apps, sets each state up by adb, starts the reader (by an intent to its screen, or by a broadcast for the "bg" rows),
pulls what the reader wrote, greps logcat, and prints one table: route x state -> worked / blocked / time.

Safe by construction: every adb command goes through one gate (check_adb_args) that only lets through commands that name one of the
three probe packages, plus read-only reads (getprop, date, pm path, pidof, cat of the probe's own result file, logcat -d, dumpsys activity activities, uiautomator dump) and the
home / recents keys and one swipe for the "swiped" state. It changes no setting except, with --autostart, the source's own
MIUI Autostart app-op (10008). Every command is printed before it runs (the serial is shown as <serial>).
A device that does not look like an emulator needs --real-phone.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

PKG_SOURCE = "io.github.utof.linkprobe.source"
PKG_READER = "io.github.utof.linkprobe.reader"
PKG_WRONG = "io.github.utof.linkprobe.readerwrong"
PROBE_PACKAGES = (PKG_SOURCE, PKG_READER, PKG_WRONG)
SOURCE_MAIN = f"{PKG_SOURCE}/{PKG_SOURCE}.MainActivity"
READER_CLASS = "io.github.utof.linkprobe.reader.MainActivity"  # (the code's package is the same for both reader builds)
RECEIVER_CLASS = "io.github.utof.linkprobe.reader.TriggerReceiver"
APPOP_AUTOSTART = "10008"
READ_ONLY_PM_PATHS = ("com.google.android.apps.healthdata", "com.android.healthconnect.controller", "com.google.android.healthconnect.controller")
STATES = ("front", "background", "fgs", "swiped", "stopped")
STATE_TEXT = {
    "front": "source in front (the reader's screen covers it for the 'front' rows; 'bg' rows keep it in front)",
    "background": "source was used, then Home was pressed",
    "fgs": "like background, with a foreground service running (eeg while recording)",
    "swiped": "source swiped away from recents",
    "stopped": "source force-stopped (am force-stop)",
}
ROWS = (("provider", "front"), ("service", "front"), ("activity", "front"), ("provider", "bg"), ("service", "bg"))
# lines worth keeping: the MIUI / permission / start-blocked words, matched case-insensitively and only kept when they name a probe package
# (see keep_log_hits), plus the probe's own tag
LOG_WORDS = re.compile(r"MIUILOG|WAKEPATH|AutoStart|denied|Permission Denial|Failed to find provider|Reject service|BLOCKED|"
                       r"Background (start|execution) not allowed|Abort background activity|BAL_BLOCK|not allowed to start|SecurityException", re.I)
LOG_TAG = re.compile(r"\bLINKPROBE\b:")


class Refused(Exception):
    """A command the gate does not allow (a bug in this script, never something to bypass)."""


def is_probe(p: str) -> bool:
    return p in PROBE_PACKAGES


def component_ok(c: str) -> bool:
    return "/" in c and is_probe(c.split("/", 1)[0])


def check_adb_args(a: list[str]) -> None:
    """Raise Refused unless this adb command only touches the probe's own packages or reads harmlessly."""
    if not a:
        raise Refused("empty command")
    top = a[0]
    if top == "get-state" and len(a) == 1:
        return
    if top == "install" and a[-1].endswith(".apk") and set(a[1:-1]) <= {"-r", "-t"}:
        return
    if top == "uninstall" and len(a) == 2 and is_probe(a[1]):
        return
    if top == "logcat" and "-d" in a and set(a) <= {"logcat", "-d", "-T", "-v", "threadtime"} | {x for x in a if re.fullmatch(r"\d+\.\d{3}", x)}:
        return
    if top == "shell" and len(a) >= 2 and _check_shell(a[1:]):
        return
    if top == "exec-out" and a[1:] == ["uiautomator", "dump", "/dev/stdout"]:  # (`shell ... /dev/tty` answers nothing without a terminal)
        return
    raise Refused("not allowed: adb " + " ".join(a))


def _check_shell(s: list[str]) -> bool:
    cmd, rest = s[0], s[1:]
    if cmd == "getprop":
        return len(rest) <= 1
    if cmd == "date":
        return rest == ["+%s"]
    if cmd == "pm":
        return len(rest) == 2 and rest[0] == "path" and (is_probe(rest[1]) or rest[1] in READ_ONLY_PM_PATHS)
    if cmd == "pidof":
        return len(rest) == 1 and is_probe(rest[0])
    if cmd == "am":
        if len(rest) == 2 and rest[0] in ("force-stop", "kill"):
            return is_probe(rest[1])
        if rest and rest[0] in ("start", "broadcast"):
            comps = [rest[i + 1] for i, x in enumerate(rest[:-1]) if x == "-n"]
            return len(comps) == 1 and component_ok(comps[0])
        return False
    if cmd == "appops":
        if rest[:1] == ["get"]:
            return rest[1:] == [PKG_SOURCE, APPOP_AUTOSTART]
        return rest[:1] == ["set"] and len(rest) == 4 and rest[1:3] == [PKG_SOURCE, APPOP_AUTOSTART] and rest[3] in ("allow", "ignore", "default")
    if cmd == "input":
        if rest[:1] == ["keyevent"]:
            return rest[1:] in (["KEYCODE_HOME"], ["KEYCODE_APP_SWITCH"])
        return rest[:1] == ["swipe"] and len(rest) == 6 and all(x.isdigit() for x in rest[1:])
    if cmd == "cat":
        return len(rest) == 1 and any(rest[0] == f"/sdcard/Android/data/{p}/files/results.jsonl" for p in PROBE_PACKAGES)
    if cmd == "ls":
        return len(rest) == 2 and rest[0] == "-d" and any(rest[1] == f"/sdcard/Android/data/{p}" for p in PROBE_PACKAGES)
    if cmd == "dumpsys":
        return rest == ["activity", "activities"]
    return False


def looks_like_emulator(serial: str) -> bool:
    return bool(re.fullmatch(r"emulator-\d+|(127\.0\.0\.1|localhost):\d+", serial))


# ---------------------------------------------------------------------------------------------------------------- parsing

def parse_jsonl(text: str) -> list[dict]:
    out: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def results_from_logcat(text: str) -> list[dict]:
    out: list[dict] = []
    for line in text.splitlines():
        m = re.search(r"LINKPROBE.*?RESULT (\{.*\})\s*$", line)
        if m:
            out += parse_jsonl(m.group(1))
    return out


def parse_appop(text: str) -> str | None:
    """The mode word of `appops get PKG 10008`, or None when the device does not know that op."""
    low = text.lower()
    if re.search(r"unknown|error|exception|no operations", low):
        return None
    m = re.search(r"\b(allow|ignore|deny|default|foreground)\b", low)
    return m.group(1) if m else None


def find_swipe_target(dump: str, label: str) -> tuple[int, int, int] | None:
    """From a uiautomator dump of the recents screen: (x, y, screen height) of the card whose text or description holds label."""
    start = dump.find("<?xml")
    end = dump.rfind("</hierarchy>")
    if start < 0 or end < 0:
        return None
    try:
        root = ET.fromstring(dump[start:end + len("</hierarchy>")])
    except ET.ParseError:
        return None
    height = 0
    hit: tuple[int, int] | None = None
    for node in root.iter("node"):
        m = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not m:
            continue
        l, t, r, b = map(int, m.groups())
        height = max(height, b)
        if hit is None and label.lower() in (node.get("text", "") + " " + node.get("content-desc", "")).lower() and r > l and b > t:
            hit = ((l + r) // 2, (t + b) // 2)
    return (hit[0], hit[1], height) if hit and height else None


@dataclass
class Cell:
    route: str
    mode: str  # front = the reader's screen started it, bg = a broadcast did
    state: str
    autostart: str
    result: dict | None  # the reader's line (None = it never answered)
    alive_before: bool
    guard_lines: list[str] = field(default_factory=list)

    @property
    def row(self) -> tuple[str, str]:
        return (self.route, self.mode)

    @property
    def text(self) -> str:
        return cell_text(self)


def cell_text(c: Cell) -> str:
    r = c.result
    if r is None:
        return "NO ANSWER"
    if r.get("ok"):
        return f"OK {r.get('ms', '?')} ms" + ("" if c.alive_before else "*") + (" (ack FAILED)" if r.get("ackOk") is False else "")
    kind = r.get("kind", "?")
    return "REFUSED" if kind == "refused" else f"BLOCKED {kind}"


def render_table(cells: list[Cell], states: list[str], title: str) -> str:
    names = {"stopped": "force-stopped"}
    cols = [names.get(s, s) for s in states]
    rows = [(rt, md) for (rt, md) in ROWS if any(c.row == (rt, md) for c in cells)]
    lab = {(rt, md): rt if md == "front" else f"{rt} (reader in bg)" for rt, md in rows}
    texts = {(c.row, c.state): c.text for c in cells}
    w0 = max([len("route"), len("source before call")] + [len(v) for v in lab.values()])
    ws = [max(len(col), *(len(texts.get((r, s), "-")) for r in rows)) for col, s in zip(cols, states)]
    line = lambda parts: "  ".join(p.ljust(w) for p, w in zip(parts, [w0] + ws))  # noqa: E731
    out = [title, line(["route"] + cols), line(["-" * w0] + ["-" * w for w in ws])]
    for r in rows:
        out.append(line([lab[r]] + [texts.get((r, s), "-") for s in states]))
    alive = []
    for s in states:
        v = {c.alive_before for c in cells if c.state == s}
        alive.append("-" if not v else "running" if v == {True} else "not running" if v == {False} else "mixed")
    out.append(line(["source before call"] + alive))
    if any(not c.alive_before and c.result and c.result.get("ok") for c in cells):
        out.append("* = the source was not running and the call started it")
    return "\n".join(out)


def verdict_lines(cells: list[Cell]) -> list[str]:
    out = []
    for rt, md in ROWS:
        mine = [c for c in cells if c.row == (rt, md)]
        if not mine:
            continue
        bad = [c.state for c in mine if not (c.result and c.result.get("ok"))]
        out.append(f"  {rt}{'' if md == 'front' else ' (reader in bg)'}: " + ("works in every state" if not bad else "blocked or no answer when the source is: " + ", ".join(bad)))
    return out


# -------------------------------------------------------------------------------------------------------------------- adb

class Adb:
    def __init__(self, adb: str, serial: str, port: int | None, log_path: Path):
        self.adb, self.serial, self.port, self.log_path = adb, serial, port, log_path
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("")

    def run(self, *args: str, timeout: int = 60, quiet: bool = False) -> subprocess.CompletedProcess:
        check_adb_args(list(args))
        shown = f"adb{f' -P {self.port}' if self.port else ''} -s <serial> " + " ".join(args)
        if not quiet:
            print("$", shown, flush=True)
        with self.log_path.open("a") as f:
            f.write(shown + "\n")
        cmd = [self.adb] + (["-P", str(self.port)] if self.port else []) + ["-s", self.serial, *args]
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, errors="replace")
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(cmd, 124, (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout")

    def shell(self, *args: str, timeout: int = 60, quiet: bool = False) -> subprocess.CompletedProcess:
        return self.run("shell", *args, timeout=timeout, quiet=quiet)


# ------------------------------------------------------------------------------------------------------------- the probe

class Probe:
    def __init__(self, adb: Adb, args: argparse.Namespace, out: Path):
        self.adb, self.args, self.out = adb, args, out
        self.n = 0
        self.stamp = datetime.now().strftime("%H%M%S")
        self.logcat_hits: list[str] = []
        self.other_miui_lines = 0
        self.swipe_method: set[str] = set()
        self.unconfirmed: set[str] = set()
        self.input_warned = False

    # --- facts and install
    def facts(self) -> dict[str, str]:
        props = self.adb.shell("getprop").stdout
        want = re.compile(r"\[((?:ro\.)?(?:product\.(?:manufacturer|model)|build\.version\.(?:release|sdk|incremental|extensions\.[a-z_]+)|miui\.ui\.version\.(?:name|code)|mi\.os\.version\.(?:name|code)|build\.display\.id))\]: \[(.*)\]")
        f = {m.group(1): m.group(2) for line in props.splitlines() if (m := want.search(line))}
        for pkg in READ_ONLY_PM_PATHS:
            r = self.adb.shell("pm", "path", pkg)
            f[f"has {pkg}"] = "yes" if r.stdout.strip().startswith("package:") else "no"
        return f

    def install(self, apks: dict[str, Path]) -> None:
        for name, apk in apks.items():
            r = self.adb.run("install", "-r", str(apk), timeout=240)
            if r.returncode != 0 or "Success" not in r.stdout:
                hint = "  (on a Xiaomi phone: Developer options > 'Install via USB' must be on)" if "USER_RESTRICTED" in r.stdout + r.stderr else ""
                sys.exit(f"install of {name} failed: {(r.stdout + r.stderr).strip()}{hint}")

    def installed(self, pkg: str) -> bool:
        return self.adb.shell("pm", "path", pkg, quiet=True).stdout.strip().startswith("package:")

    def uninstall_all(self) -> bool:
        for pkg in PROBE_PACKAGES:
            if self.installed(pkg):
                self.adb.run("uninstall", pkg)
        left = [p for p in PROBE_PACKAGES if self.installed(p)]
        left += [f"/sdcard/Android/data/{p}" for p in PROBE_PACKAGES if self.adb.shell("ls", "-d", f"/sdcard/Android/data/{p}", quiet=True).returncode == 0]
        print("uninstall: " + ("nothing of the probe is left on the device" if not left else "STILL THERE: " + ", ".join(left)))
        return not left

    # --- autostart app-op
    def appop(self) -> str | None:
        raw = self.adb.shell("appops", "get", PKG_SOURCE, APPOP_AUTOSTART)
        mode = parse_appop(raw.stdout)
        if mode is None:
            print(f"  (appops says: {(raw.stdout + raw.stderr).strip()[:120] or 'nothing'})")
        return mode

    def set_appop(self, mode: str) -> bool:
        self.adb.shell("appops", "set", PKG_SOURCE, APPOP_AUTOSTART, mode)
        got = self.appop()
        ok = got == mode or (mode == "ignore" and got in ("ignore", "deny"))
        if not ok:
            print(f"autostart: asked for '{mode}' but the device says '{got}'")
        return ok

    # --- states
    def pid_alive(self) -> bool:
        return bool(self.adb.shell("pidof", PKG_SOURCE, quiet=True).stdout.strip())

    def top_is_source(self) -> bool:
        out = self.adb.shell("dumpsys", "activity", "activities", quiet=True).stdout
        return bool(re.search(r"(topResumedActivity|ResumedActivity)=.*" + re.escape(PKG_SOURCE), out))

    def home(self) -> None:
        r = self.adb.shell("input", "keyevent", "KEYCODE_HOME")
        if (r.returncode != 0 or "INJECT_EVENTS" in r.stdout + r.stderr) and not self.input_warned:
            self.input_warned = True
            print("  !! the Home key did not go through: " + (r.stdout + r.stderr).strip()[:160]
                  + "\n  !! on a Xiaomi phone: Developer options > 'USB debugging (Security settings)' must be on for adb to press keys")

    def setup_state(self, state: str) -> None:
        a = self.adb
        for pkg in PROBE_PACKAGES:
            a.shell("am", "force-stop", pkg, quiet=True)
        time.sleep(0.5)
        ok = True
        if state == "front":
            a.shell("am", "start", "-W", "-n", SOURCE_MAIN)
            time.sleep(1.5)
            ok = self.top_is_source()
        elif state in ("background", "fgs", "swiped"):
            extra = ["--ez", "fgs", "true"] if state == "fgs" else []
            a.shell("am", "start", "-W", "-n", SOURCE_MAIN, *extra)
            time.sleep(2 if state == "fgs" else 1.5)
            self.home()
            time.sleep(1.5)
            ok = self.pid_alive() and not self.top_is_source()
            if state == "swiped":
                ok = self.swipe_away()
        else:  # stopped: the force-stop above is the state
            ok = not self.pid_alive()
        if not ok:
            self.unconfirmed.add(state)
            print(f"  (could not confirm the state '{state}')")

    def swipe_away(self) -> bool:
        a, mode = self.adb, self.args.swipe
        if mode == "auto":
            a.shell("input", "keyevent", "KEYCODE_APP_SWITCH")
            time.sleep(2)
            tgt = find_swipe_target(a.run("exec-out", "uiautomator", "dump", "/dev/stdout", timeout=40).stdout, "Probe source")
            if tgt:
                x, y, h = tgt
                a.shell("input", "swipe", str(x), str(y), str(x), str(max(h // 20, 5)), "180")
                time.sleep(1.5)
            else:
                print("  (recents: no card named 'Probe source' found in the screen dump)")
            self.home()
            time.sleep(1)
            if not self.pid_alive():
                self.swipe_method.add("recents swipe by adb")
                return True
        if mode in ("auto", "manual") and sys.stdin.isatty():
            input("  >> On the phone: open recents, swipe 'Probe source' away, press Home, then press Enter here. ")
            if not self.pid_alive():
                self.swipe_method.add("swiped by hand")
                return True
        elif mode == "manual":
            sys.exit("--swipe manual needs a terminal (stdin) to ask you to swipe")
        a.shell("am", "kill", PKG_SOURCE)
        time.sleep(1)
        self.swipe_method.add("am kill (not the real swipe)")
        return not self.pid_alive()

    # --- one cell
    def device_epoch(self) -> int:
        r = self.adb.shell("date", "+%s", quiet=True).stdout.strip()
        return int(r) if r.isdigit() else int(time.time())

    def cell(self, route: str, mode: str, state: str, autostart: str, reader_pkg: str = PKG_READER) -> Cell:
        self.n += 1
        run_id = f"{self.stamp}-{self.n:03d}"
        print(f"\n[{self.n}] route={route} reader={'front' if mode == 'front' else 'background'} source={state} autostart={autostart}")
        self.setup_state(state)
        alive = self.pid_alive()
        since = self.device_epoch() - 1
        extras = ["--es", "run", run_id, "--es", "state", state, "--es", "routes", route]
        if mode == "front":
            self.adb.shell("am", "start", "-W", "-n", f"{reader_pkg}/{READER_CLASS}", *extras, timeout=60)
        else:
            self.adb.shell("am", "broadcast", "-n", f"{reader_pkg}/{RECEIVER_CLASS}", *extras)
        lines = self.wait_results(reader_pkg, run_id, 45)
        log = self.adb.run("logcat", "-d", "-T", f"{since}.000", "-v", "threadtime", timeout=90, quiet=True).stdout
        guard = self.keep_log_hits(log, f"[{self.n}] {route}/{mode}/{state}/autostart={autostart}")
        if not any(not x.get("done") for x in lines):  # the file could not be read: the reader also wrote the same lines to logcat
            lines = [x for x in results_from_logcat(log) if x.get("run") == run_id]
        res = next((x for x in lines if x.get("route") == route), None)
        c = Cell(route, mode, state, autostart, res, alive, guard)
        print(f"    -> {c.text}" + (f"  ({res.get('detail')})" if res and res.get("detail") else ""))
        return c

    def wait_results(self, reader_pkg: str, run_id: str, seconds: int) -> list[dict]:
        end = time.time() + seconds
        path = f"/sdcard/Android/data/{reader_pkg}/files/results.jsonl"
        mine: list[dict] = []
        while time.time() < end:
            mine = [x for x in parse_jsonl(self.adb.shell("cat", path, quiet=True).stdout) if x.get("run") == run_id]
            if any(x.get("done") for x in mine):
                break
            time.sleep(0.7)
        return mine

    def keep_log_hits(self, log: str, header: str) -> list[str]:
        """Our own packages' lines, saved. Other apps' MIUI lines are only counted, never kept."""
        mine, guard = [], []
        for line in log.splitlines():
            tagged = bool(LOG_TAG.search(line))
            if not tagged and not LOG_WORDS.search(line):
                continue
            if tagged or "linkprobe" in line.lower():
                mine.append(line.strip())
                if "source guard" in line:
                    guard.append(line.strip())
            else:
                self.other_miui_lines += 1
        if mine:
            self.logcat_hits.append(f"== {header}\n" + "\n".join(mine))
        return guard


# --------------------------------------------------------------------------------------------------------------- main

def find_apk(dirpath: Path, kind: str) -> Path:
    hits = sorted(dirpath.glob(f"link-probe-{kind}-*.apk"), key=lambda p: p.stat().st_mtime)
    hits = [h for h in hits if (kind != "reader" or "wrongkey" not in h.name)]
    if not hits:
        sys.exit(f"no link-probe-{kind}-*.apk in {dirpath} (build.py makes them)")
    return hits[-1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serial", required=True)
    ap.add_argument("--adb-port", type=int, help="adb server port (default: adb's own default)")
    ap.add_argument("--adb", default=shutil.which("adb") or str(Path.home() / "android-sdk/platform-tools/adb"))
    ap.add_argument("--apk-dir", type=Path, default=Path(__file__).resolve().parent / "out")
    ap.add_argument("--source-apk", type=Path)
    ap.add_argument("--reader-apk", type=Path)
    ap.add_argument("--wrong-apk", type=Path)
    ap.add_argument("--states", default=",".join(STATES), help="comma list out of: " + ", ".join(STATES))
    ap.add_argument("--modes", default="front,bg", help="front = reader's screen starts it (3 routes); bg = a broadcast starts it, source untouched (routes 1, 2)")
    ap.add_argument("--autostart", choices=("keep", "off", "on", "both"), default="keep",
                    help="flip the source's MIUI Autostart app-op 10008 (ignore/allow) and run the table for it; keep = do not touch it")
    ap.add_argument("--swipe", choices=("auto", "manual", "kill"), default="auto",
                    help="how the 'swiped' state is made: auto = swipe the card in recents by adb, asking you if that fails; manual = you swipe; kill = am kill")
    ap.add_argument("--no-wrong-caller", action="store_true", help="skip the run with the wrong-key reader")
    ap.add_argument("--uninstall", action="store_true", help="remove the probe apps at the end (also when a step failed)")
    ap.add_argument("--uninstall-only", action="store_true", help="just remove the probe apps and check nothing is left")
    ap.add_argument("--real-phone", action="store_true", help="required when the serial is not an emulator")
    ap.add_argument("--out", type=Path, help="where the report files go (default reports/<time>)")
    args = ap.parse_args()

    if not looks_like_emulator(args.serial) and not args.real_phone:
        sys.exit("this serial does not look like an emulator: add --real-phone if you mean a real phone")
    states = [s for s in args.states.split(",") if s]
    modes = [m for m in args.modes.split(",") if m]
    if not set(states) <= set(STATES) or not set(modes) <= {"front", "bg"}:
        sys.exit("bad --states or --modes")
    here = Path(__file__).resolve().parent
    out = args.out or here / "reports" / datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    adb = Adb(args.adb, args.serial, args.adb_port, out / "commands.log")
    probe = Probe(adb, args, out)
    print(f"report files: {out}\n(<serial> = the --serial you gave; every adb command is printed before it runs)")
    st = adb.run("get-state", timeout=20)
    if st.stdout.strip() != "device":
        sys.exit(f"device not ready: {(st.stdout + st.stderr).strip()}")
    if args.uninstall_only:
        return 0 if probe.uninstall_all() else 1

    apks = {"source": args.source_apk or find_apk(args.apk_dir, "source"), "reader": args.reader_apk or find_apk(args.apk_dir, "reader")}
    wrong = None if args.no_wrong_caller else (args.wrong_apk or find_apk(args.apk_dir, "reader-wrongkey"))
    code = 0
    try:
        facts = probe.facts()
        print("\nPHONE FACTS")
        for k, v in facts.items():
            print(f"  {k}: {v}")
        probe.install(apks)
        original = probe.appop()
        print(f"\nautostart app-op {APPOP_AUTOSTART} of the source: " + (original if original else "not available on this device (no MIUI/HyperOS autostart)"))
        values = {"keep": ["as is"], "off": ["off"], "on": ["on"], "both": ["off", "on"]}[args.autostart]
        if original is None and args.autostart != "keep":
            print("autostart: the device has no such app-op: one table, without it")
            values = ["n/a"]
        tables, all_cells = [], []
        for v in values:
            if v in ("off", "on") and not probe.set_appop("ignore" if v == "off" else "allow"):
                print(f"autostart {v}: could not set it; skipping this table")
                continue
            label = f"autostart {v}" + (f" (the app-op reads: {original})" if v == "as is" and original else "")
            cells = [probe.cell(rt, md, s, v) for s in states for (rt, md) in ROWS if md in modes]
            all_cells += cells
            tables.append(render_table(cells, states, f"TABLE: {label}"))
        wrong_text = ""
        if wrong:
            adb.run("install", "-r", str(wrong), timeout=240)
            wc = [probe.cell(rt, "front", "background", "-", PKG_WRONG) for rt in ("provider", "service", "activity")]
            ok = all(c.result and c.result.get("kind") == "refused" for c in wc)
            reasons = [g for c in wc for g in c.guard_lines][:3]
            wrong_text = ("WRONG-KEY READER (another package id, another key): " + ", ".join(f"{c.route} {c.text}" for c in wc)
                          + f"\n  -> {'PASS: refused on all three routes' if ok else 'FAIL: it must be refused on all three routes'}"
                          + "".join(f"\n  source log: {re.sub(r'^.*LINKPROBE', 'LINKPROBE', g)}" for g in reasons))
            code = 0 if ok else 1
            if not ok:
                print("\n!! the wrong-key reader was NOT refused everywhere")
        if args.autostart in ("off", "on", "both") and original is not None:
            probe.set_appop(original if original in ("allow", "ignore", "default") else "default")
        report = ["", "PHONE FACTS"] + [f"  {k}: {v}" for k, v in facts.items()] + [""] + tables
        if probe.swipe_method:
            report.append("swiped state was made by: " + ", ".join(sorted(probe.swipe_method)))
        if probe.unconfirmed:
            report.append("states that could not be confirmed on the device: " + ", ".join(sorted(probe.unconfirmed)))
        report += ["", "READING (per route, over the states of the first table):"] + verdict_lines([c for c in all_cells if c.autostart == (values[0] if values else "")])
        if wrong_text:
            report += ["", wrong_text]
        report += ["", f"logcat: {len(probe.logcat_hits)} cell(s) with lines about the probe's packages (saved in logcat.txt); "
                       f"{probe.other_miui_lines} MIUILOG/WAKEPATH/AutoStart/denied line(s) about other apps were seen and not kept",
                   "A 'BLOCKED' or 'NO ANSWER' cell: look in logcat.txt for MIUILOG / WAKEPATH / AutoStart / 'Failed to find provider' lines."]
        text = "\n".join(report)
        print("\n" + "=" * 100 + text)
        (out / "table.txt").write_text(text + "\n")
        (out / "logcat.txt").write_text("\n\n".join(probe.logcat_hits) + "\n")
        (out / "results.json").write_text(json.dumps([{"route": c.route, "mode": c.mode, "state": c.state, "autostart": c.autostart,
                                                      "alive_before": c.alive_before, "text": c.text, "result": c.result} for c in all_cells], indent=1))
        (out / "facts.json").write_text(json.dumps(facts, indent=1))
    finally:
        if args.uninstall:
            if not probe.uninstall_all():
                code = code or 1
    return code


if __name__ == "__main__":
    sys.exit(main())
