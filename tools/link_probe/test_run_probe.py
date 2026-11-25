"""Tests of run_probe.py's pure parts: the safety gate, parsing, the table. Run: python3 -m unittest discover tools/link_probe"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_probe as rp  # noqa: E402

S, R, W = rp.PKG_SOURCE, rp.PKG_READER, rp.PKG_WRONG


class Gate(unittest.TestCase):
    def ok(self, *a: str) -> None:
        rp.check_adb_args(list(a))

    def no(self, *a: str) -> None:
        with self.assertRaises(rp.Refused):
            rp.check_adb_args(list(a))

    def test_allowed(self) -> None:
        self.ok("get-state")
        self.ok("install", "-r", "/x/link-probe-source-abc.apk")
        self.ok("uninstall", R)
        self.ok("shell", "getprop")
        self.ok("shell", "date", "+%s")
        self.ok("shell", "pm", "path", S)
        self.ok("shell", "pm", "path", "com.google.android.apps.healthdata")
        self.ok("shell", "pidof", S)
        self.ok("shell", "am", "force-stop", S)
        self.ok("shell", "am", "kill", W)
        self.ok("shell", "am", "start", "-W", "-n", f"{S}/{S}.MainActivity", "--ez", "fgs", "true")
        self.ok("shell", "am", "start", "-W", "-n", f"{R}/{rp.READER_CLASS}", "--es", "run", "1", "--es", "routes", "provider,service")
        self.ok("shell", "am", "broadcast", "-n", f"{W}/{rp.RECEIVER_CLASS}", "--es", "run", "1")
        self.ok("shell", "appops", "get", S, "10008")
        self.ok("shell", "appops", "set", S, "10008", "ignore")
        self.ok("shell", "input", "keyevent", "KEYCODE_HOME")
        self.ok("shell", "input", "swipe", "540", "1200", "540", "100", "180")
        self.ok("exec-out", "uiautomator", "dump", "/dev/stdout")
        self.ok("shell", "cat", f"/sdcard/Android/data/{R}/files/results.jsonl")
        self.ok("shell", "ls", "-d", f"/sdcard/Android/data/{S}")
        self.ok("shell", "dumpsys", "activity", "activities")
        self.ok("logcat", "-d", "-T", "1764000000.000", "-v", "threadtime")

    def test_refused(self) -> None:
        self.no()
        self.no("uninstall", "com.whatsapp")
        self.no("shell", "am", "force-stop", "com.android.settings")
        self.no("shell", "am", "start", "-n", "com.android.settings/.Settings")
        self.no("shell", "am", "start", "-a", "android.intent.action.VIEW")
        self.no("shell", "am", "broadcast", "-a", "android.intent.action.BOOT_COMPLETED")
        self.no("shell", "pm", "clear", S)
        self.no("shell", "pm", "path", "com.whatsapp")
        self.no("shell", "pm", "disable-user", S)
        self.no("shell", "settings", "put", "global", "adb_enabled", "0")
        self.no("shell", "appops", "set", "com.whatsapp", "10008", "allow")
        self.no("shell", "appops", "set", S, "10008", "deny")
        self.no("shell", "appops", "set", S, "RUN_IN_BACKGROUND", "ignore")
        self.no("shell", "input", "keyevent", "KEYCODE_POWER")
        self.no("shell", "input", "text", "hello")
        self.no("shell", "cat", "/sdcard/DCIM/photo.jpg")
        self.no("shell", "cat", f"/sdcard/Android/data/{R}/files/../../../x")
        self.no("shell", "rm", "-rf", "/sdcard")
        self.no("logcat", "-c")
        self.no("install", "/x/other.apk", "--user", "0")
        self.no("push", "a", "b")
        self.no("reboot")
        self.no("exec-out", "screencap", "-p")
        self.no("exec-out", "uiautomator", "dump", "/sdcard/x.xml")

    def test_emulator_names(self) -> None:
        self.assertTrue(rp.looks_like_emulator("emulator-5554"))
        self.assertTrue(rp.looks_like_emulator("127.0.0.1:15555"))
        self.assertFalse(rp.looks_like_emulator("ABCDEF0123456789"))
        self.assertFalse(rp.looks_like_emulator("192.168.1.5:5555"))


class Parsing(unittest.TestCase):
    def test_jsonl_ignores_noise(self) -> None:
        got = rp.parse_jsonl('cat: no such file\n{"run":"1","done":true}\nnot json {\n{"run":"1","route":"provider","ok":true}\n')
        self.assertEqual([x["run"] for x in got], ["1", "1"])

    def test_logcat_results(self) -> None:
        line = '11-25 12:00:00.000  100  100 I LINKPROBE: RESULT {"run":"7","route":"service","ok":false,"kind":"timeout"}'
        self.assertEqual(rp.results_from_logcat(line)[0]["kind"], "timeout")

    def test_appop(self) -> None:
        self.assertEqual(rp.parse_appop("MIUIAUTOSTART: allow"), "allow")
        self.assertEqual(rp.parse_appop("MIUIAUTOSTART: ignore; time=+1d"), "ignore")
        self.assertIsNone(rp.parse_appop("Error: Unknown operation string: 10008"))
        self.assertIsNone(rp.parse_appop(""))

    def test_swipe_target(self) -> None:
        xml = ('UI hierarchy dumped to: /dev/tty<?xml version="1.0"?><hierarchy rotation="0"><node bounds="[0,0][1080,2400]">'
               '<node text="" content-desc="Probe source" bounds="[100,500][980,1900]"/></node></hierarchy>UI hierarchy dumped to: /dev/tty')
        self.assertEqual(rp.find_swipe_target(xml, "Probe source"), (540, 1200, 2400))
        self.assertIsNone(rp.find_swipe_target(xml, "Other app"))
        self.assertIsNone(rp.find_swipe_target("garbage", "Probe source"))


class Facts(unittest.TestCase):
    def test_facts_pick_the_lines_the_report_names(self) -> None:
        class Out:
            def __init__(self, stdout: str) -> None:
                self.stdout, self.returncode = stdout, 0

        class FakeAdb:
            def shell(self, *a: str, quiet: bool = False) -> Out:
                if a == ("getprop",):
                    return Out("[ro.product.model]: [21081111RG]\n[ro.product.manufacturer]: [Xiaomi]\n[ro.build.version.sdk]: [34]\n"
                               "[ro.serialno]: [SECRET123]\n[ro.mi.os.version.name]: [OS1.0]\n[ro.miui.ui.version.code]: [816]\n"
                               "[build.version.extensions.u]: [15]\n[persist.wm.extensions.enabled]: [true]\n")
                return Out("package:/x" if a[-1] == "com.google.android.apps.healthdata" else "")

        facts = rp.Probe(FakeAdb(), None, Path("/nonexistent")).facts()  # type: ignore[arg-type]
        self.assertEqual(facts["ro.product.model"], "21081111RG")
        self.assertEqual(facts["build.version.extensions.u"], "15")
        self.assertEqual(facts["ro.mi.os.version.name"], "OS1.0")
        self.assertEqual(facts["has com.google.android.apps.healthdata"], "yes")
        self.assertEqual(facts["has com.android.healthconnect.controller"], "no")
        self.assertNotIn("ro.serialno", facts)
        self.assertFalse(any("SECRET123" in v for v in facts.values()))


class Table(unittest.TestCase):
    def cells(self) -> list[rp.Cell]:
        ok = {"ok": True, "ms": 12, "kind": "ok"}
        return [
            rp.Cell("provider", "front", "front", "as is", ok, True),
            rp.Cell("provider", "front", "swiped", "as is", {"ok": False, "kind": "null_cursor", "ms": 3}, False),
            rp.Cell("service", "front", "swiped", "as is", ok, False),
            rp.Cell("activity", "front", "swiped", "as is", None, False),
            rp.Cell("provider", "front", "stopped", "as is", {"ok": False, "kind": "refused"}, False),
        ]

    def test_cell_text(self) -> None:
        c = self.cells()
        self.assertEqual([x.text for x in c], ["OK 12 ms", "BLOCKED null_cursor", "OK 12 ms*", "NO ANSWER", "REFUSED"])

    def test_a_failed_ack_shows(self) -> None:
        c = rp.Cell("service", "front", "front", "as is", {"ok": True, "ms": 5, "ackOk": False}, True)
        self.assertEqual(c.text, "OK 5 ms (ack FAILED)")

    def test_table_has_every_state_and_the_footnote(self) -> None:
        t = rp.render_table(self.cells(), ["front", "swiped", "stopped"], "TABLE: x")
        self.assertIn("force-stopped", t)
        self.assertIn("BLOCKED null_cursor", t)
        self.assertIn("source before call", t)
        self.assertIn("* = the source was not running", t)
        self.assertEqual(len({len(line.rstrip()) > 0 for line in t.splitlines()}), 1)

    def test_verdict(self) -> None:
        v = "\n".join(rp.verdict_lines(self.cells()))
        self.assertIn("provider: blocked or no answer when the source is: swiped, stopped", v)
        self.assertIn("service: works in every state", v)


if __name__ == "__main__":
    unittest.main()
