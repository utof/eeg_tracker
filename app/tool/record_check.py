#!/usr/bin/env python3
"""Record first on a temporary emulator (DECISIONS 880-910): Record, Sleep on the running recording, Stop sleep,
Stop, the sheet "What was this recording?".

usage: python3 app/tool/record_check.py --apk <the REPLAY build> [--adb-port 5053] [--work DIR] [--out DIR] [--keep]

The replay build's headband plays a made-up quiet recording (tool/replay_scenario.dart), so no headband and no
recording of anyone is needed. It checks:
  1. Record starts a recording whose header names it, with no sleep marked (no spans file);
  2. Sleep on the running recording writes an open sleep span that did not start the recording;
  3. Stop, then "Stop sleep", closes the span while the recording goes on (its file keeps growing);
  4. Stop, then "Stop", ends the recording and the sheet comes; a chip and Save write a tag with source
     `owner_stop_sheet` into the recording's tags file;
  5. the sleep span gets a report file of its own (`nights/<date>.report.json` with `span`) (a SKIP when the scoring
     has not come to it within 3 minutes).
The emulator, its adb server and the helpers are the pre-install check's (tool/precheck.py). Emulator only: run it
inside `_local/build_slot.sh heavy`, with --work on a disk with 8 GB free.
"""
from __future__ import annotations

import argparse
import json
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


def check(apk: Path, stage: Path) -> list[pc.Result]:
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
    saved = tap(emu.match("Save", True)) if chip else False
    tags = wait(lambda: cat(f"{pc.FILES}/archive/{rec}.tags.json"), limit=30) if saved else ""
    try:
        tag = (json.loads(tags).get("tags") or [{}])[0]
    except ValueError:
        tag = {}
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
    return results


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apk", type=Path, required=True)
    p.add_argument("--out", type=Path)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--adb-port", type=int, default=5053)
    p.add_argument("--work", type=Path, default=Path("/var/tmp"),
                   help="where the run's folder (emulator, staged files, logs) is made; a disk with 8 GB free")
    a = p.parse_args()
    if not a.apk.is_file():
        p.error(f"{a.apk} is not there")
    pc.use_adb_port(a.adb_port)
    work = a.work / f"eeg-record-check-{time.strftime('%Y-%m-%d-%H%M%S')}"
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
    print(f"\nRecord first on the emulator ({a.apk.name}), {(time.time() - t0) / 60:.1f} min")
    for r in results:
        print(f"{r.verdict:4} {r.name}: {r.words}")
    print(f"Logs and details: {out}")
    return 1 if not results or any(r.verdict == "FAIL" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
