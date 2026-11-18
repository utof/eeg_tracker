#!/usr/bin/env python3
"""Drive the app on an Android emulator through adb (the emulator smoke test, app/README.md).

Standard library only. Flutter exposes its semantics to Android's accessibility tree, so `uiautomator dump`
sees the app's labels and buttons; this finds one by its text and taps its centre.

    python3 app/tool/emu.py texts                 # every label on screen, with its centre
    python3 app/tool/emu.py tap "Sleep report"    # tap the first element whose text contains it
    python3 app/tool/emu.py tap "Start" --exact   # ... whose text is exactly it
    python3 app/tool/emu.py tap "Export" --scroll # scroll down to it first when it is not on screen
    python3 app/tool/emu.py find "Listen"         # scroll down until it is on screen (exit 1 when not found)
    python3 app/tool/emu.py shot DIR/name         # screenshot to DIR/name.png
    python3 app/tool/emu.py back | scroll [up|down]

`ADB` (default: `adb` on PATH) and `ANDROID_SERIAL` choose the tool and device.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = os.environ.get("ADB", "adb")
BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def adb(*args: str, timeout: float = 60) -> bytes:
    return subprocess.run([ADB, *args], check=True, capture_output=True, timeout=timeout).stdout


def nodes() -> list[tuple[str, int, int]]:
    """(text, x, y) of every node with a text or description, top to bottom."""
    for attempt in range(3):
        raw = adb("exec-out", "uiautomator", "dump", "/dev/tty")
        xml = raw[raw.find(b"<?xml") : raw.rfind(b">") + 1]
        try:
            root = ET.fromstring(xml)
            break
        except ET.ParseError:
            if attempt == 2:
                raise
            time.sleep(1)
    out = []
    for n in root.iter("node"):
        label = (n.get("text") or "") or (n.get("content-desc") or "")
        m = BOUNDS.fullmatch(n.get("bounds", ""))
        if label and m:
            x0, y0, x1, y1 = map(int, m.groups())
            out.append((label.replace("\n", " | "), (x0 + x1) // 2, (y0 + y1) // 2))
    return out


def match(text: str, exact: bool) -> tuple[str, int, int] | None:
    for label, x, y in nodes():
        if (label == text) if exact else (text in label):
            return label, x, y
    return None


def screen_size() -> tuple[int, int]:
    m = re.search(rb"(\d+)x(\d+)", adb("shell", "wm", "size"))
    return (int(m[1]), int(m[2])) if m else (1080, 2400)


def scroll(direction: str) -> None:
    w, h = screen_size()
    a, b = (int(h * 0.75), int(h * 0.3)) if direction == "down" else (int(h * 0.3), int(h * 0.75))
    adb("shell", "input", "swipe", str(w // 2), str(a), str(w // 2), str(b), "400")
    time.sleep(0.8)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("cmd", choices=["texts", "tap", "find", "shot", "back", "scroll"])
    p.add_argument("arg", nargs="?")
    p.add_argument("--exact", action="store_true")
    p.add_argument("--scroll", action="store_true", help="tap: scroll down to it when it is not on screen")
    p.add_argument("--tries", type=int, default=8, help="scrolls before find (or tap --scroll) gives up")
    a = p.parse_args()
    if a.cmd == "texts":
        for label, x, y in nodes():
            print(f"{x:5d} {y:5d}  {label}")
    elif a.cmd in ("tap", "find"):
        if not a.arg:
            p.error("which text?")
        hit = match(a.arg, a.exact)
        for _ in range(a.tries if a.cmd == "find" or a.scroll else 0):
            if hit:
                break
            scroll("down")
            hit = match(a.arg, a.exact)
        if hit is None:
            print(f"not found: {a.arg!r}", file=sys.stderr)
            return 1
        label, x, y = hit
        if a.cmd == "tap":
            adb("shell", "input", "tap", str(x), str(y))
            time.sleep(1.0)
        print(f"{x} {y}  {label}")
    elif a.cmd == "shot":
        if not a.arg:
            p.error("where to?")
        path = Path(a.arg).with_suffix(".png")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(adb("exec-out", "screencap", "-p"))
        print(path)
    elif a.cmd == "back":
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(0.8)
    elif a.cmd == "scroll":
        scroll(a.arg or "down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
