"""scripts/phone_night_check.py: how a night recorded by the phone app went, on synthetic phone nights
(analysis/tests/fake_phone_night.py) and, when they are on this machine, on the owner's real laptop nights."""
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import phone_night_check as pnc  # noqa: E402
from fake_phone_night import ADDRESS, PhoneRun, stem, write_empty_run, write_report, write_run  # noqa: E402

T = datetime(2026, 11, 19, 23, 0, 0)
NIGHT = "2026-11-19"
DIRECT = f"direct to {ADDRESS}"


@pytest.fixture(autouse=True)
def short_nights_count(monkeypatch: pytest.MonkeyPatch) -> None:
    """Synthetic nights are minutes long; the 2-hour floor is tested on its own."""
    monkeypatch.setattr(pnc, "MIN_NIGHT_H", 0.0)


def mixed_night(root: Path) -> tuple[PhoneRun, PhoneRun, PhoneRun]:
    """Three runs: lost packets, data held back 3 s, then a drop with three tries; a run whose process is killed;
    Android's restart with the exit reason; Stop. Written in the phone's export layout (eeg-export/)."""
    rec = root / "recordings"
    a = PhoneRun(T, seconds=600, lost=[(100, 5), (200, 2)], late=[(150, 3.0)], end="drop",
                 after=[(12, f"reconnect try 1 ({DIRECT}): not found after 12.0 s"),
                        (40, f"reconnect try 2 ({DIRECT}): failed after 2.1 s: PlatformException(133)"),
                        (85, "reconnect try 3 (scan): connected after 4.2 s")])
    b_start = a.last + timedelta(seconds=89)
    b = PhoneRun(b_start, seconds=480, contact=None, end="killed", band_battery=(88, 87), phone_battery=(99, 99),
                 head=[f"reconnected (scan, try 3) after a drop (out of range); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.000, 89.5 s ago"])
    c_start = b.last + timedelta(seconds=120)
    c = PhoneRun(c_start, seconds=600, contact=None, end="stop", night_end=True, band_battery=(87, 86),
                 phone_battery=(99, 98), signal="unknown (no scan)",
                 app_counts="419997 samples, missing 7 in 2 gaps, repeated 0, longest gap 5 samples",
                 head=["service restarted by Android after the app process ended",
                       f"previous process ended: {b.last + timedelta(seconds=5):%Y-%m-%dT%H:%M:%S} low-memory status 0 "
                       "importance 125 (low memory killer)"])
    paths = [write_run(rec, r, seed=i) for i, r in enumerate((a, b, c))]
    write_report(root / "nights", NIGHT, paths)
    return a, b, c


def test_mixed_night_numbers(tmp_path: Path) -> None:
    a, b, c = mixed_night(tmp_path / "eeg-export")
    s = pnc.check(tmp_path / "eeg-export", NIGHT, signal=False)
    assert (s["source"], s["name"], s["data_runs"]) == ("phone", NIGHT, 3)
    assert s["samples"] == (600 + 480 + 600) * 250
    assert s["start"] == pytest.approx(a.first.timestamp(), abs=0.05)
    assert s["end"] == pytest.approx(c.last.timestamp(), abs=0.05)
    # lost packets: two jumps inside run A, nothing else (each run's first batch is not compared across runs)
    pk = s["packets"]
    assert (pk.lost, pk.jumps, pk.longest) == (7, 2, 5)
    assert sum(pk.per_hour.values()) == 7
    # the 3 s of held-back data is not a gap and loses nothing
    assert [round(x.length) for x in s["late"]] == [3]
    # two gaps over 30 s, each with the log's reason
    gaps = [x for x in s["breaks"] if x.cat != "late"]
    assert [round(x.length) for x in gaps] == [97, 128]
    assert gaps[0].cat == "drop"
    assert gaps[0].text == "drop (out of range); 3 tries (2 direct, 1 scan); back by scan, try 3"
    assert gaps[1].cat == "android"
    assert gaps[1].text == "Android restarted the service (the process ended: low-memory)"
    assert s["tries"] == dict(direct=2, scan=1, direct_ok=0, scan_ok=1)
    assert [r.stem for r in s["killed"]] == [stem(b.start)]
    assert len(s["restarts"]) == 1 and s["exits"][0].g["reason"] == "low-memory"
    assert s["stop"] is not None and not s["stuck"]
    assert (s["app_packets"]["missing"], s["app_packets"]["gaps"]) == ("7", "2")  # the app's own count, beside ours
    assert s["rate"] == pytest.approx(250, abs=0.5)
    # batteries, contact, settings, the phone's report
    ph, band = s["battery"]["phone"], s["battery"]["band"]
    assert (ph["first"], ph["last"], ph["plugged"]) == (100, 98, False)
    assert (band["first"], band["last"], band["stuck"]) == (90, 86, 0)
    assert s["battery"]["summary"].startswith("1% in 0.2 h")
    assert s["contact"]["start"][1] == {"O1": 120000, "O2": 95000, "T3": 48000, "T4": 31000}
    assert s["settings"]["battery-opt exempt"] == "yes"
    assert s["report"]["covers"] == 3 and s["report"]["scoring_s"] == 95.0
    assert s["unknown"] == []
    # the verdict: usable, and the first fix is Android's kill
    assert s["verdict"] == "Usable, with gaps"
    assert "Android ended the app 1 time (low-memory)" in s["fixes"][0]


def test_mixed_night_text(tmp_path: Path) -> None:
    _, b, _ = mixed_night(tmp_path / "eeg-export")
    text = pnc.render(pnc.check(tmp_path / "eeg-export", NIGHT, signal=False))
    assert "Verdict: Usable, with gaps" in text
    assert "drop (out of range); 3 tries (2 direct, 1 scan); back by scan, try 3" in text
    assert f"process ended {b.last + timedelta(seconds=5):%H:%M:%S} low-memory (low memory killer)" in text
    assert "lost          7 samples in 2 counter jumps" in text
    assert "Scored on this phone".lower() in text.lower() and "95 s" in text
    assert "Stop pressed at" in text and "Log: " in text and "all understood" in text
    assert ADDRESS not in text and "0000000000" not in text  # no address or serial in the output


def test_signal_numbers_find_the_flat_channel_and_the_hum(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    mixed_night(tmp_path / "eeg-export")
    s = pnc.check(tmp_path / "eeg-export", NIGHT)
    sig = s["signal"]
    assert sig["seconds"] == 1680
    assert sig["flat"][3] == 1680 and sig["flat"][:3] == [0, 0, 0]  # T4 is all zeros
    assert sig["railed"] == [0, 0, 0, 0]
    assert sig["hum"][2] > pnc.HUM_HIGH  # T3 carries 50 Hz
    assert all(h < pnc.HUM_SOME for h in (sig["hum"][0], sig["hum"][1]))
    assert any("T4 was flat" in f for f in s["fixes"])


def test_a_good_night(tmp_path: Path) -> None:
    run = PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False)
    p = write_run(tmp_path / "recordings", run)
    write_report(tmp_path / "phone" / "nights", NIGHT, [p])  # the laptop's _local/ layout
    s = pnc.check(tmp_path, None)  # the newest phone night
    assert s["name"] == NIGHT and s["breaks"] == [] and s["drops"] == []
    assert s["verdict"] == "Good night for the recorder"
    assert s["report"] is not None and s["report"]["phone"]
    assert "Nothing to fix" in pnc.render(s) or s["fixes"]


def test_too_short_a_night_is_not_trustworthy(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(pnc, "MIN_NIGHT_H", 2.0)
    write_run(tmp_path / "recordings", PhoneRun(T, seconds=120, night_end=True))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["verdict"] == "Not trustworthy yet" and s["fixes"][0].startswith("Only 0.0 h of signal")


def test_bluetooth_stuck_and_the_apps_own_restart(tmp_path: Path) -> None:
    a = PhoneRun(T, seconds=200, end="stuck")
    b = PhoneRun(a.last + timedelta(seconds=60), seconds=200, contact=None, night_end=True,
                 head=["service restarted by Android after the app process ended",
                       f"previous process ended: {a.last + timedelta(seconds=31):%Y-%m-%dT%H:%M:%S} signaled status 9 "
                       "importance 125"])
    write_run(tmp_path, a)
    write_run(tmp_path, b)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    gap = [x for x in s["breaks"] if x.cat != "late"]
    assert len(gap) == 1 and gap[0].cat == "stuck"
    assert gap[0].text == ('Bluetooth stuck ("battery" gave no answer); the app restarted itself '
                           "(the process ended: signaled)")
    assert len(s["stuck"]) == 1 and s["killed"] == []  # a stuck run saves and closes its files
    assert s["verdict"] == "Usable, with gaps"
    assert any(f.startswith("Bluetooth got stuck 1 time (battery)") for f in s["fixes"])


def test_a_stall_reconnects_through_a_new_run(tmp_path: Path) -> None:
    a = PhoneRun(T, seconds=200, end="stall",
                 after=[(42, f"reconnect try 1 ({DIRECT}): connected after 1.5 s")])
    b = PhoneRun(a.last + timedelta(seconds=45), seconds=200, contact=None, night_end=True, signal="unknown (no scan)",
                 head=[f"reconnected (direct, try 1) after a drop (no data); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.000, 45.0 s ago"])
    write_run(tmp_path, a)
    write_run(tmp_path, b)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    gap = [x for x in s["breaks"] if x.cat != "late"]
    assert [x.text for x in gap] == ["drop (no data); 1 try (1 direct, 0 scan); back by direct, try 1"]
    assert s["tries"]["direct_ok"] == 1
    assert "none through a scan" not in pnc.render(s)  # the first run's scan gave a strength


def test_a_recorder_that_died_and_never_came_back(tmp_path: Path) -> None:
    write_run(tmp_path, PhoneRun(T, seconds=300, end="killed"))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["stop"] is None and not s["last_closed"]
    assert s["verdict"] == "Not trustworthy yet"
    assert s["fixes"][0].startswith("The recorder stopped by itself at 23:05")


def test_risky_phone_settings_are_named(tmp_path: Path) -> None:
    run = PhoneRun(T, seconds=200, night_end=True)
    write_run(tmp_path, run)
    log = tmp_path / f"{stem(T)}.log"
    log.write_text(log.read_text().replace("battery-opt exempt yes", "battery-opt exempt no")
                   .replace("standby bucket 10", "standby bucket 40"))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    fix = next(f for f in s["fixes"] if f.startswith("Phone settings"))
    assert "not exempt from battery optimisation" in fix and "standby bucket 40" in fix


# ---- laptop logs, and phone and laptop recordings in one folder ------------------------------------------------------
LAPTOP_HEAD = [
    f"connected BB Black {ADDRESS} serial 000000000 battery 100% signal -81 dBm",
    "sdk library patched (keeps other Bluetooth devices)",
    "features [<SensorFeature.Signal: 0>, <SensorFeature.Resist: 1>]",
    "commands [<SensorCommand.StartSignal: 0>, <SensorCommand.StopSignal: 1>]",
    "parameters [ParameterInfo(Param=<SensorParameter.Name: 0>, ParamAccess=<SensorParamAccess.Read: 0>)]",
    "contact ohms O1=111633 O2=89393 T3=46618 T4=31512",
    "live check page on port 8765",
    "recording started, 250 Hz, Ctrl+C to stop",
]


def laptop_run(start: datetime, seconds: float, tail: list[str], stale: int | None = None) -> PhoneRun:
    n = int(seconds * 250)
    lines = [(0.1 * k, x) for k, x in enumerate(LAPTOP_HEAD)]
    lines += [(8 + s, f"samples {s * 250} (+2500) battery 2%") for s in range(10, int(seconds) + 1, 10)]
    lines += [(8 + seconds + 0.1 * k, x.format(n=n, min=n / 250 / 60)) for k, x in enumerate(tail)]
    return PhoneRun(start, seconds=seconds, stale_first=stale, log=lines, flat_t4=False, hum_t3=False)


def laptop_night(folder: Path, start: datetime) -> None:
    a = laptop_run(start, 200, ["headband StateOutOfRange; saving and exiting so record_night.sh starts a fresh "
                                "recorder", "total samples {n}, {min:.1f} min"], stale=181880)
    write_run(folder, a)
    write_empty_run(folder, a.last + timedelta(seconds=20), [
        (0.0, f"connected BB Black {ADDRESS} serial 000000000 battery 100% signal -88 dBm"),
        (6.6, "contact check failed: Code 513. Message:Device error: [ERR_DATA_SEND]"),
        (6.7, "live check page on port 8765")])
    b = laptop_run(a.last + timedelta(seconds=50), 200, ["stopped, battery 37%", "total samples {n}, {min:.1f} min"],
                   stale=1127)
    write_run(folder, b)


def test_laptop_logs_are_understood(tmp_path: Path) -> None:
    laptop_night(tmp_path, T)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["source"] == "laptop" and s["unknown"] == []
    assert s["packets"].lost == 0  # the SDK's leftover first batch is a restart, not a loss
    gap = [x for x in s["breaks"] if x.cat != "late"]
    assert len(gap) == 1 and gap[0].text == "drop (out of range); 1 start without data"
    assert len(s["killed"]) == 1  # the start that died after its failed contact check
    assert s["battery"]["band"]["stuck"] > 0
    assert "Laptop night of 2026-11-19" in pnc.render(s)


def test_phone_and_laptop_recordings_in_one_folder_stay_apart(tmp_path: Path) -> None:
    write_run(tmp_path, PhoneRun(T, seconds=200, night_end=True))
    laptop_night(tmp_path, T + timedelta(minutes=30))
    phone = pnc.check(tmp_path, NIGHT, signal=False)
    laptop = pnc.check(tmp_path, NIGHT, source="laptop", signal=False)
    assert (phone["source"], phone["data_runs"]) == ("phone", 1)
    assert (laptop["source"], laptop["data_runs"], laptop["runs"]) == ("laptop", 2, 3)
    table = pnc.render_compare(phone, laptop)
    assert f"phone {NIGHT}" in table and f"laptop {NIGHT}" in table and "verdict" in table


def test_the_command(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    write_run(tmp_path / "recordings", PhoneRun(T, seconds=200, night_end=True))
    laptop_night(tmp_path / "recordings", T - timedelta(days=1))
    assert pnc.main([NIGHT, "--data", str(tmp_path), "--compare", "2026-11-18", "--no-signal"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("Phone night of 2026-11-19") and "Next to the laptop night of 2026-11-18" in out
    assert pnc.main(["2026-11-01", "--data", str(tmp_path)]) == 2
    assert "nights: 2026-11-19 (phone, 1 recordings), 2026-11-18 (laptop, 2 recordings)" in capsys.readouterr().err


# ---- the packet counter ---------------------------------------------------------------------------------------------
@pytest.mark.parametrize("prev,cur,want", [
    (100, 101, ("ok", 0)),
    (100, 103, ("lost", 2)),
    (2047, 0, ("ok", 0)),  # the 11-bit counter wraps
    (2040, 5, ("lost", 12)),  # a loss across the wrap
    (5, 5, ("repeat", 0)),
    (181887, 8, ("restart", 0)),  # BrainBit's SDK starts counting again after a leftover batch
    (100, 100 + 5000, ("restart", 0)),  # a step too far to be a loss
])
def test_packet_jumps(prev: int, cur: int, want: tuple[str, int]) -> None:
    assert pnc.jump(prev, cur) == want


# ---- every log line the recorders can write --------------------------------------------------------------------------
PHONE_LINES = [
    f"connected BB Black {ADDRESS} serial 0000 battery 90% signal -70 dBm",
    f"connected BB Black {ADDRESS} serial  battery null% signal unknown (no scan)",
    "phone android 34, battery-opt exempt yes, background restricted no, power save no, standby bucket 10, "
    "notifications yes, xiaomi OS1.0",
    "phone battery 87% charge 3612345 uAh current -310250 uA unplugged temp 31.2 C",
    "phone battery ?% charge ? uAh current ? uA plugged ? temp ? C",
    "phone battery 87% charge 3612345 uAh current 310250 uA plugged usb temp 31.2 C",
    "phone battery summary: 19% in 7.9 h = 2.41 %/h, 1590 mAh = 201 mAh/h",
    "phone battery summary: no readings (Android gave no battery numbers)",
    "phone battery summary: only 12 min between readings, too short for a rate",
    "phone battery summary: the readings had neither level nor charge counter",
    "contact ohms O1=120000 O2=inf T3=none T4=31000",
    "contact check: no resistance data arrived",
    "contact check failed: PlatformException(x)",
    "recording started, 250 Hz",
    "samples 2500 (+2500) battery 90%",
    "samples 2500 (+0) battery null%",
    "no data, state inRange; restarting stream (try 1)",
    "stream restarted",
    "stream restart failed: Exception: x",
    "still no data; reconnecting",
    "headband out of range; saving",
    "headband out of range; leaving it without SDK calls",
    "packets: 7200000 samples, missing 3 in 2 gaps, repeated 1, longest gap 2 samples",
    "end of night, packets: 7200000 samples, missing 3 in 2 gaps, repeated 1, longest gap 2 samples",
    "total samples 75000, 5.0 min",
    "drop (out of range); last data 2026-11-19T23:05:08.000; reconnecting",
    "drop (no data); last data none; reconnecting",
    "drop (run failed); last data none; reconnecting",
    "stopped, battery 88%",
    "stopped, battery null%",
    "stop failed: Exception: x",
    f"reconnect try 1 ({DIRECT}): not found after 12.0 s",
    f"reconnect try 2 ({DIRECT}): failed after 2.1 s: PlatformException(x)",
    "reconnect try 3 (scan): connected after 4.2 s",
    f"reconnect try 4 ({DIRECT}): no answer for 60.0 s (SDK stuck)",
    "reconnected (scan, try 3) after a drop (out of range); previous run 2026-11-19-230000, last data "
    "2026-11-19T23:05:08.000, 92.0 s ago",
    "reconnected (direct, try 1) after a drop (app process restarted); previous run unknown, last data unknown",
    "service restarted by Android after the app process ended",
    "previous process ended: 2026-11-19T23:10:45 low-memory status 0 importance 125 (low memory)",
    "previous process ended: 2026-11-19T23:10:45 signaled status 9 importance 125",
    "the previous process ended during a direct connection; scans only for the rest of the night",
    'SDK call "battery" stuck for 30 s; saved, restarting the app process',
    'SDK call "stop signal" stuck for 30 s; saved',
    'closing: SDK call "disconnect" stuck for 30 s',
    f"BB Black {ADDRESS} answered but reports out of range; left alone",
    "start failed (1/10): Exception: x",
    "the signal would not start; reconnecting",
    "unexpected error: StateError",
]
OWN_LINES = [  # our own connection's notes (app/lib/headband/own/), in the same .log
    "driver own Bluetooth LE (lib/headband/own, universal_ble); service 6e400001; device {}; mtu 517",
    "layout O1 O2 T3 T4, 13-byte samples",
    "mode signal (command 3)",
    "status battery 90%",
    "lost 12 samples in 2 gaps (packet counter jumps)",
    "reconnected after 3.2 s away (try 2), battery 90%; same files",
    "headband lost: timeout; trying again in 2 s (try 1)",
    "headband lost: timeout; still away after 31 s, handing over to the app's reconnect",
    "own connection stopped unexpectedly: StateError",
    "scanning up to 30 s for a BrainBit by name",
    "the link carries 23-byte packets, the signal needs 111: packets may arrive cut short",
    "status read failed (x); hold the button for 4 s",
    "status read failed: x",
    "samples callback failed: x",
    "signal+resistance (command 5) gave no signal in 5 s; falling back to signal only (command 3)",
    "no signal for 5 s: sending the start command again",
]
LAPTOP_LINES = LAPTOP_HEAD + [  # scripts/record_night.py, record_ble.py, recorder_hub.py
    f"connected BB Black {ADDRESS} serial 000000000 battery 96%",
    "samples 2536 (+2536)",
    "headband StateOutOfRange; saving and exiting so record_night.sh starts a fresh recorder",
    "still no data; exiting so record_night.sh starts a fresh recorder",
    "no data, state StateInRange; reconnecting",
    "no data, state StateOutOfRange; restarting stream (try 1)",
    "reconnected, battery 76%",
    "reconnect failed: Code 3. Message:Failed to connect the sensor",
    "stream restarted, battery 76%",
    "contact re-check asked: saving and exiting; record_night.sh starts a fresh recorder, which measures contact",
    "contact re-check asked: measuring in-process, no restart",
    "contact re-check asked while the headband is away: skipped",
    "contact re-check: no resistance data arrived",
    "contact check: no resistance data",
    "main loop stuck in an SDK call for 60 s; saved, exiting so record_night.sh starts a fresh one",
    "main loop stuck for 60 s; saved, exiting so record_night.sh starts a fresh one",
    "driver stopped unexpectedly: RuntimeError: x",
    "headband lost or not found: timeout; trying again in 5 s (try 2)",
    "own Bluetooth driver; headband address unknown: will scan by name",
    "no known address: scanning up to 30 s for a BrainBit by name",
    "features unavailable: x",
]


@pytest.mark.parametrize("line", PHONE_LINES + OWN_LINES + LAPTOP_LINES)
def test_every_line_is_understood(line: str) -> None:
    assert pnc.parse_line(line) is not None, line


def _literals(path: Path, call: str) -> list[str]:
    """The fixed start (up to the first `$`) of every string literal passed to `call(` in a Dart file."""
    text = path.read_text()
    found = re.findall(rf"(?<![\w.]){call}\(\s*'((?:[^'\\]|\\.)*)'", text)
    found += re.findall(rf"(?<![\w.])w\.{call}\(\s*'((?:[^'\\]|\\.)*)'", text) if call == "log" else []
    return [f.split("$")[0].replace("\\'", "'") for f in found]


@pytest.mark.parametrize("path,call", [
    ("app/lib/recorder/night_recorder.dart", "log"),
    ("app/lib/recorder/night_recorder.dart", "_note"),
    ("app/lib/headband/own/own_headband.dart", "_note"),
    ("app/lib/headband/own/driver.dart", "log"),
])
def test_every_line_the_app_writes_has_a_sample(path: str, call: str) -> None:
    """A new log line in the app fails here until it has a sample above (and a rule in the check)."""
    starts = [s for s in _literals(ROOT / path, call) if s]
    assert starts, f"no {call}(...) lines found in {path}: has the code moved?"
    samples = PHONE_LINES + OWN_LINES
    missing = [s for s in starts if not any(x.startswith(s) for x in samples)]
    assert missing == []


def test_the_apps_own_battery_and_packet_lines_have_samples() -> None:
    battery = (ROOT / "app/lib/recorder/battery.dart").read_text()
    starts = [s.split("$")[0] for s in re.findall(r"'(phone battery summary: [^']*)'", battery)]
    starts += ["packets: "] if "'packets: $samples samples" in (ROOT / "app/lib/recorder/packets.dart").read_text() \
        else ["<packets line changed>"]
    assert len(starts) >= 4
    assert [s for s in starts if not any(x.startswith(s) for x in PHONE_LINES)] == []


# ---- the owner's real laptop nights (read-only; skipped where they are not) ------------------------------------------
REAL = Path(os.environ.get("PHONE_NIGHT_CHECK_DATA", ROOT / "_local"))


@pytest.mark.skipif(not (REAL / "recordings").is_dir(), reason="no real recordings here (set PHONE_NIGHT_CHECK_DATA)")
def test_the_owners_laptop_nights_parse() -> None:
    rec_dir, _ = pnc.folders(REAL)
    runs = pnc.load_runs(rec_dir)
    recs = {r.path.stem: r for r in pnc.nf.recordings(rec_dir)}
    nights = pnc.nights_of(runs, recs, "laptop")
    assert nights, "no laptop nights in the real recordings"
    for n in nights:
        s = pnc.check(REAL, n.name, source="laptop", signal=False)
        assert s["source"] == "laptop" and s["unknown"] == [], s["unknown"][:5]
        assert s["rate"] == pytest.approx(250, rel=0.01)
        text = pnc.render(s)
        assert "Verdict: " in text and not pnc.MAC.search(text)
