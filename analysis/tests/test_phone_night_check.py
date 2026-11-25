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
from fake_phone_night import (ADDRESS, PhoneRun, span_line, stem, write_empty_run, write_report,  # noqa: E402
                              write_run, write_spans)

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


def test_a_helper_that_stopped_is_listed_and_the_rest_is_information(tmp_path: Path) -> None:
    run = PhoneRun(T, seconds=600, night_end=True,
                   head=["drift-off detector on; lights off counts from the first sample until Lights off",
                         "lights off"],
                   after=[(1, "drift-off detector: 0.40 s of work for 0.17 h of signal (2.40 s an hour)"),
                          (2, "smart alarm stopped: StateError; the phone's alarm still rings at 07:30; the recording "
                              "goes on"),
                          (3, "sharing on Wi-Fi off")])
    write_run(tmp_path / "recordings", run)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    assert [text for _, text in s["helpers"]] == [
        "smart alarm stopped: StateError; the phone's alarm still rings at 07:30; the recording goes on"]
    assert "  helpers       " in pnc.render(s)


WIFI_START = "wifi connected, 866 Mbps, -58 dBm, 5 GHz; default route wifi; screen on; idle no; lock held"


def test_wifi_off_while_sharing_says_when_and_what_to_check(tmp_path: Path) -> None:
    """The owner's night of 2026-11-20: the laptop lost the phone soon after the screen went off. The Wi-Fi lines
    (app/lib/recorder/wifi_watch.dart) say from when to when the phone itself was off Wi-Fi."""
    run = PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False,
                   head=["sharing on Wi-Fi on: 192.168.1.5 port 8765", WIFI_START],
                   extra=[(130, "wifi connected, 866 Mbps, -60 dBm, 5 GHz; default route wifi; screen off; idle no; "
                                "lock held"),
                          (250, "wifi not connected; default route cell; screen off; idle yes; lock held"),
                          (300, "wifi unreadable: PlatformException(phone, x)"),
                          (490, "wifi connected, 433 Mbps, -71 dBm, 2.4 GHz; default route vpn over wifi; screen off; "
                                "idle no; lock held")])
    write_run(tmp_path / "recordings", run)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    w = s["wifi"]
    assert [(round(a - T.timestamp()), round(b - T.timestamp()), what) for a, b, what in w["off"]] == [
        (250, 490, "not connected, screen off, default route cell")]
    assert (w["lines"], w["unreadable"], w["dbm"], w["shared"]) == (4, 1, (-71, -58), True)
    text = pnc.render(s)
    assert "  Wi-Fi         off from 23:04 to 23:08 (not connected, screen off, default route cell)" in text
    assert any(f.startswith("Wi-Fi was off from 23:04 to 23:08 while sharing was on") for f in s["fixes"]), s["fixes"]
    assert s["verdict"] == "Good night for the recorder"  # the recording itself did not suffer


def test_wifi_still_off_at_the_end_and_connected_all_night(tmp_path: Path) -> None:
    off = PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False, head=[WIFI_START],
                   extra=[(250, "wifi off; default route cell; screen off; idle yes; lock not held")])
    write_run(tmp_path / "a" / "recordings", off)
    s = pnc.check(tmp_path / "a", NIGHT, signal=False)
    assert s["wifi"]["off"][0][2] == "switched off, screen off, default route cell"
    end = hm_of(s["last_line"])
    assert f"  Wi-Fi         off from 23:04 until the end ({end}; switched off, screen off, default route cell)" in \
        pnc.render(s)
    assert not any(f.startswith("Wi-Fi was off") for f in s["fixes"])  # sharing was off: nothing to mirror

    on = PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False, head=[WIFI_START],
                  extra=[(130, "wifi connected, 866 Mbps, -61 dBm, 5 GHz; default route wifi; screen off; idle yes; "
                               "lock held")])
    write_run(tmp_path / "b" / "recordings", on)
    s = pnc.check(tmp_path / "b", NIGHT, signal=False)
    assert s["wifi"]["off"] == []
    assert "  Wi-Fi         connected all night (2 lines; signal -61 to -58 dBm)" in pnc.render(s)


def test_the_settings_line_keeps_the_wifi_sleep_policy_and_the_vpn() -> None:
    rest = ("34, battery-opt exempt yes, background restricted no, power save no, standby bucket 10, notifications yes, "
            "xiaomi OS1.0, wifi sleep policy 0, vpn yes")
    got = pnc.settings_of(rest)
    assert (got["wifi sleep policy"], got["vpn"], got["xiaomi"]) == ("0", "yes", "OS1.0")


def test_a_night_from_an_app_without_wifi_lines(tmp_path: Path) -> None:
    write_run(tmp_path / "recordings", PhoneRun(T, seconds=600, night_end=True))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["wifi"] is None
    assert "  Wi-Fi         not logged (an app from before 2026-11-20)" in pnc.render(s)


def hm_of(t: float) -> str:
    return datetime.fromtimestamp(t).strftime("%H:%M")


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


def test_a_night_moved_to_the_sdk_scans_in_the_same_try(tmp_path: Path) -> None:
    """Our own connection's headband, then the SDK after a restart: its direct try needs a scan, made at once."""
    a = PhoneRun(T, seconds=200, end="stall",
                 after=[(30, f"reconnect try 1 ({DIRECT}): the night's headband was reached through our own "
                             "connection; BrainBit's SDK needs a scan first; scanning instead"),
                        (36, "reconnect try 1 (scan): connected after 6.0 s")])
    b = PhoneRun(a.last + timedelta(seconds=40), seconds=200, contact=None, night_end=True,
                 head=[f"reconnected (scan, try 1) after a drop (no data); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.000, 40.0 s ago"])
    write_run(tmp_path, a)
    write_run(tmp_path, b)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    gap = [x for x in s["breaks"] if x.cat != "late"]
    assert [x.text for x in gap] == ["drop (no data); 1 try (0 direct, 1 scan); back by scan, try 1"]
    assert s["tries"] == dict(direct=0, scan=1, direct_ok=0, scan_ok=1)


def test_a_loss_as_the_signal_stops_is_not_a_drop(tmp_path: Path) -> None:
    """Our own connection notes a loss after Stop ended the run: the break stays the one Stop made."""
    a = PhoneRun(T, seconds=200, end="stop", night_end=True,
                 after=[(0.35, "headband lost: timeout; no further tries: the signal was stopped")])
    write_run(tmp_path, a)
    b = PhoneRun(a.last + timedelta(seconds=60), seconds=200, contact=None, night_end=True)
    write_run(tmp_path, b)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    gap = [x for x in s["breaks"] if x.cat != "late"]
    assert [x.cat for x in gap] == ["by_hand"]


def test_a_recorder_that_died_and_never_came_back(tmp_path: Path) -> None:
    write_run(tmp_path, PhoneRun(T, seconds=300, end="killed"))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["stop"] is None and not s["last_closed"]
    assert s["verdict"] == "Not trustworthy yet"
    assert s["fixes"][0].startswith("The recorder stopped by itself at 23:05")


def test_a_headband_that_never_came_back_before_stop(tmp_path: Path) -> None:
    tries = [(60.0 * k, f"reconnect try {k} (scan): not found after 15.0 s") for k in range(1, 41)]
    run = PhoneRun(T, seconds=200, end="drop", after=tries)
    write_run(tmp_path, run)
    log = tmp_path / f"{stem(T)}.log"
    stop = run.last + timedelta(minutes=41)
    log.write_text(log.read_text() + f"{stop:%Y-%m-%dT%H:%M:%S}.000 end of night, packets: 49999 samples, missing 0 in "
                   "0 gaps, repeated 0, longest gap 0 samples\n")
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["tail"] is not None and s["tail"].text == "drop (out of range); 40 tries (0 direct, 40 scan)"
    assert s["verdict"] == "Usable, with gaps"
    assert any(f.startswith("No data for the last 41.0 min before Stop") for f in s["fixes"])
    assert "after data    41.0 min from 23:03 until Stop: drop (out of range); 40 tries" in pnc.render(s)


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
    # since 2026-11-20 (DECISIONS 613): Android's old Wi-Fi sleep policy when the phone has it, and a VPN
    "phone android 34, battery-opt exempt yes, background restricted no, power save no, standby bucket 10, "
    "notifications yes, xiaomi OS1.0, wifi sleep policy 2, vpn yes",
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
    "no contact reading on the live connection; not measured now",
    "recording started, 250 Hz",
    "samples 2500 (+2500) battery 90%",
    "samples 2500 (+0) battery null%",
    "no data, state inRange; restarting stream (try 1)",
    "stream restarted",
    "stream restart failed: Exception: x",
    "still no data; reconnecting",
    "no data for 60 min: what was marked ends at the last data",
    "no data for 6 h: the recording stops itself",
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
    # an IO or store error ends one run, never the night (the night pipeline review, DECISIONS 390-391)
    "the run ended on an unexpected error: FileSystemException: x; the night goes on",
    "could not save the newest data: FileSystemException: x",
    "could not save the night state: StateError; the recording goes on",
    "no data; the headband is mending the link itself (check 1)",
    # our own connection's headband, then the SDK (the switch moved): a scan in the same try (DECISIONS 398)
    f"reconnect try 2 ({DIRECT}): the night's headband was reached through our own connection; BrainBit's SDK needs a "
    "scan first; scanning instead",
    f"reconnect try 1 ({DIRECT}): unknown sensor family \"x\"; BrainBit's SDK needs a scan first; scanning instead",
] + [  # the night's live helpers, their markers and Share on Wi-Fi (app-line, DECISIONS 182-330)
    "drift-off detector on; lights off counts from the first sample until Lights off",
    "drift-off detector off after the restart; it starts again at Lights off",
    "drift-off detector could not start: StateError",
    "drift-off detector stopped: it took 2.4 % of the time (over 2.0 %); the recording goes on",
    "drift-off detector: 1.20 s of work for 7.50 h of signal (0.16 s an hour), then stopped",
    "drift-off: eyes-closed baseline done",
    "drift-off: probably asleep, onset 23:41",
    "lights off",
    "hands-free on: a double clench marks a moment (never while probably asleep)",
    "hands-free: moment (double clench)",
    "hands-free: 2 moments marked, 1 double clenches ignored while probably asleep",
    "smart alarm set: wake by 07:30, window from 07:00; the sleep model starts at 06:00",
    "smart alarm: the app process ended while the sleep model ran, so the model stays off tonight; the phone's alarm "
    "still rings at 07:30",
    "smart alarm: sleep model on (window 30 min)",
    "smart alarm: wake, light sleep (N1 at 07:12:30, read 1 min behind; 18 min before 07:30)",
    "smart alarm: could not ring early (StateError); the phone's alarm rings at 07:30",
    "smart alarm: the sleep model could not start: StateError; the phone's alarm rings at 07:30",
    "smart alarm stopped: StateError; the phone's alarm still rings at 07:30; the recording goes on",
    "smart alarm: turned off",
    "smart alarm: sleep model 1.84 s of the recorder's time over 92.0 min",
    "smart alarm and lucid cues, one sleep model: 3.10 s of the recorder's time over 240.5 min",
    "smart alarm and lucid cues stopped: too slow; the phone's alarm still rings at 07:30; the recording goes on",
    "lucid cues on: night 3 of the test; cues from 03:30, the sleep model from 03:00",
    "lucid cues from 03:45 (4.5 h after Lights off)",
    "lucid cue 2 (dream sleep 0.81, +3 dB)",
    "lucid cues off: No loudness is set yet: do the evening practice first.",
    "lucid cues could not start: StateError; the recording goes on",
    "lucid cues stopped: StateError; the recording goes on",
    "lucid cues: 2.05 s of the recorder's time over 180.0 min",
    "live sleep model on for the lucid cues (load 1 tonight)",
    "live sleep model: shared with the smart alarm (no second copy)",
    "live sleep model off, done (240 calls, median 0.4 s)",
    "live sleep model stopped: over its memory; the recording goes on",
    "sharing on Wi-Fi on: 192.168.1.23:8765",
    "sharing on Wi-Fi off",
    "sharing on Wi-Fi stopped by an error: SocketException",
] + [  # the phone's Wi-Fi, on every change and every 30 minutes (app/lib/recorder/wifi_watch.dart, DECISIONS 611)
    "wifi connected, 866 Mbps, -58 dBm, 5 GHz; default route wifi; screen off; idle no; lock held",
    "wifi connected, 2.4 GHz; default route vpn over wifi; screen on; idle no; lock not held",
    "wifi connected; default route none; screen ?; idle ?; lock held",
    "wifi not connected; default route cell; screen off; idle yes; lock held",
    "wifi not connected; default route vpn over cell; screen off; idle yes; lock held",
    "wifi off; default route none; screen off; idle yes; lock not held",
    "wifi unreadable: PlatformException(phone, x)",
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
    # the signal stopped while a drop was being mended (the rest of the night pipeline review, 2026-11-19)
    "headband lost: timeout; no further tries: the signal was stopped",
    "reconnected after 3.2 s away (as the signal was stopped), battery 90%; same files",
    "reconnected (try 1) after the link closed while the signal was off, battery ?%; same files",
    "reconnected (as the signal was stopped) after the link closed while the signal was off, battery 90%; same files",
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


def test_the_apps_wifi_lines_have_samples() -> None:
    """Every Wi-Fi line wifi_watch.dart can write starts like one of the samples above."""
    text = (ROOT / "app/lib/recorder/wifi_watch.dart").read_text()
    starts = [x.split("$")[0] for x in re.findall(r"'(wifi [^']*)'", text)]
    assert len(starts) >= 2, "no 'wifi ...' lines found in wifi_watch.dart: has the code moved?"
    assert [x for x in starts if not any(line.startswith(x) for line in PHONE_LINES)] == []
    states = re.findall(r"'(connected|not connected|off)'", text)
    assert sorted(set(states)) == ["connected", "not connected", "off"]


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


# ---- any number of channels (docs/data-format.md "The recording header") ---------------------------------------

EIGHT = tuple(f"Ch{i}" for i in range(1, 9))


def eight_channel_night(root: Path) -> None:
    """Two runs of 8 channels with their headers: lost packets in the first, a drop between them."""
    ohms = " ".join(f"{n}={v}" for n, v in zip(EIGHT, (120000, 95000, 48000, 31000, 3000000, 60000, 70000, 80000)))
    a = PhoneRun(T, seconds=600, lost=[(100, 5), (200, 2)], end="drop", names=EIGHT, header=True, contact=ohms,
                 after=[(12, "reconnect try 1 (scan): connected after 4.2 s")])
    b = PhoneRun(a.last + timedelta(seconds=30), seconds=480, names=EIGHT, header=True, contact=None, night_end=True,
                 head=[f"reconnected (scan, try 1) after a drop (out of range); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.000, 30.0 s ago"])
    for k, run in enumerate((a, b)):
        write_run(root / "recordings", run, seed=k + 1)


def test_an_eight_channel_night_is_read_by_its_header(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    eight_channel_night(tmp_path)
    s = pnc.check(tmp_path, NIGHT)
    assert s["channels"] == EIGHT and s["fs"] == 250
    assert s["samples"] == (600 + 480) * 250 and s["signal_s"] == 1080.0  # 36-byte records, not 20
    assert abs(s["rate"] - 250) < 0.5
    assert (s["packets"].lost, s["packets"].jumps) == (7, 2)  # the counter is read every 36 bytes
    assert len(s["drops"]) == 1 and 20 < s["drops"][0].length < 60
    sig = s["signal"]
    assert sig["seconds"] == 1080 and len(sig["flat"]) == len(sig["railed"]) == len(sig["hum"]) == 8
    assert sig["flat"] == [0, 0, 0, 1080, 0, 0, 0, 0]  # the fourth channel is all zeros
    assert sig["hum"][2] > pnc.HUM_HIGH and all(h < pnc.HUM_SOME for i, h in enumerate(sig["hum"]) if i not in (2, 3))
    assert s["contact"]["start"][1] == dict(zip(EIGHT, (120000.0, 95000.0, 48000.0, 31000.0, 3000000.0, 60000.0,
                                                        70000.0, 80000.0)))
    assert any("Ch4 was flat" in f for f in s["fixes"]) and any("Strong 50 Hz hum on Ch3" in f for f in s["fixes"])
    assert any("Contact at the start was poor or missing on Ch5" in f for f in s["fixes"])
    text = pnc.render(s)
    head = next(ln for ln in text.splitlines() if ln.startswith("Signal  "))
    assert head.split() == ["Signal", *EIGHT]
    row = next(ln for ln in text.splitlines() if ln.startswith("  flat min"))
    assert row.split()[2:] == ["0.0", "0.0", "0.0", "18.0", "0.0", "0.0", "0.0", "0.0"]
    assert "Ch8 80 k" in text and "O1" not in text and "T4" not in text
    assert "all understood" in text


def test_a_brainbit_night_with_headers_reads_like_one_without(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    runs = {}
    for name, header in (("old", False), ("new", True)):
        write_run(tmp_path / name / "recordings", PhoneRun(T, seconds=600, lost=[(100, 5)], night_end=True, header=header))
        runs[name] = pnc.check(tmp_path / name, NIGHT)
    assert (tmp_path / "new" / "recordings" / f"{stem(T)}.header.json").is_file()
    assert pnc.render(runs["old"]) == pnc.render(runs["new"])
    assert runs["new"]["channels"] == ("O1", "O2", "T3", "T4")


def test_a_night_of_mixed_channel_sets_keeps_its_signal_table_to_the_first_kind(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    a = PhoneRun(T, seconds=300, names=EIGHT, header=True, contact=None, end="drop")
    b = PhoneRun(a.last + timedelta(seconds=30), seconds=300, night_end=True)  # 4 channels, no header
    for k, run in enumerate((a, b)):
        write_run(tmp_path / "recordings", run, seed=k + 1)
    s = pnc.check(tmp_path, NIGHT)
    assert s["samples"] == 600 * 250 and s["channels"] == EIGHT
    assert s["signal"]["seconds"] == 300 and len(s["signal"]["flat"]) == 8
    assert s["signal"]["other"] == ["O1 O2 T3 T4 (1 recording)"]
    assert "not in this table: O1 O2 T3 T4 (1 recording)" in pnc.render(s)


def test_a_damaged_header_is_said_and_nothing_is_guessed(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    eight_channel_night(tmp_path)
    (tmp_path / "recordings" / f"{stem(T)}.header.json").write_text("{")
    assert pnc.main([NIGHT, "--data", str(tmp_path)]) == 2
    assert f"{stem(T)}.header.json" in capsys.readouterr().err


@pytest.mark.parametrize("prev,cur,want", [(5, 6, ("ok", 0)), (5, 9, ("lost", 3)), (5, 5, ("repeat", 0)),
                                           (3000, 5000, ("lost", 1999)), (5000, 3, ("restart", 0)),
                                           (2**32 - 1, 0, ("ok", 0)), (2**32 - 2, 1, ("lost", 2))])
def test_a_board_sequence_number_has_no_2048_wrap(prev: int, cur: int, want: tuple[str, int]) -> None:
    assert pnc.jump(prev, cur, "board sequence number") == want


# ---- the dream sleep check (DECISIONS 740-749) ----

def _with_stages(folder: Path, runs: list[Path], stages: str, **more: object) -> dict:
    """The fake phone report with stages, a period over every asleep epoch and `data_start` where the night joins."""
    import json

    import rem_check as rc
    import to_bdf
    start, _, _ = to_bdf.join(runs)
    t0 = start.astimezone()
    first = next(i for i, c in enumerate(stages) if c in "123R")
    last = max(i for i, c in enumerate(stages) if c in "123R")
    f = folder / f"{NIGHT}.report.json"
    rep = json.loads(f.read_text())
    rep.update(stages=stages, data_start=t0.isoformat(timespec="seconds"),
               periods=[{"start": (t0 + timedelta(seconds=30 * first)).isoformat(timespec="seconds"),
                         "end": (t0 + timedelta(seconds=30 * last + 30)).isoformat(timespec="seconds")}], **more)
    assert rc.periods_of(rep) == [(first, last)]
    f.write_text(json.dumps(rep))
    return rep


STAGES = "WW" + "2" * 10 + "R" * 6 + "22"  # 10 minutes: 8 asleep, 3 of them dream sleep


def test_the_dream_sleep_check_in_the_phones_words(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    import rem_check as rc
    p = write_run(tmp_path / "recordings", PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False))
    write_report(tmp_path / "phone" / "nights", NIGHT, [p])
    st = rc.stages_of(STAGES)
    own = rc.night_check(st, [(2, 19)], [[0, 0, 0, 0, 700]] * 20, rc.eye_measured("T3-T4", [1] * 12 + [6] * 6 + [1] * 2))
    _with_stages(tmp_path / "phone" / "nights", [p], STAGES, rem_check=own)
    s = pnc.check(tmp_path, NIGHT)
    assert s["report"]["rem"] == own and not s["report"]["rem_eye_here"]  # the report's own: nothing measured here
    text = pnc.render(s)
    for line in rc.check_lines(own):
        assert f"  {line}" in text
    assert "Dream sleep 3 min (33 %). Usual for adults is 20-25 %; this night is above it." in text
    assert "eye movements (T3-T4): 9.0 min of sleep measured; share in REM 0.75 (REM is 0.333 of it)" in text


def test_an_older_report_gets_its_eye_movements_measured_from_the_recordings(tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    p = write_run(tmp_path / "recordings", PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False))
    write_report(tmp_path / "phone" / "nights", NIGHT, [p])
    _with_stages(tmp_path / "phone" / "nights", [p], STAGES)
    s = pnc.check(tmp_path, NIGHT)
    r = s["report"]
    assert r["rem_eye_here"] and r["rem"]["eye"]["pair"] == "T3-T4" and len(r["rem"]["eye"]["epochs"]) == 20
    assert r["rem"]["rem_min"] == 3.0 and r["rem"]["rem_prob_min"] is None
    text = pnc.render(s)
    assert "Dream sleep check (eye movements measured here from the recordings; the report predates them)" in text
    assert "This report is older than the check" not in text
    assert "the scorer's likelihood is not in this report" in text
    s = pnc.check(tmp_path, NIGHT, signal=False)  # --no-signal: the stage-only check, and why
    assert s["report"]["rem"]["eye"] is None and "--no-signal" in s["report"]["rem_why"]


# ---- batteries: the one stuck rule, the charge by wear time, the phone's own cost (DECISIONS 766-767) ---------------

def _log(start: datetime, lines: list[tuple[float, str]]) -> list:
    text = "".join(f"{(start + timedelta(seconds=s)).strftime('%Y-%m-%dT%H:%M:%S.000')} {x}\n" for s, x in lines)
    return pnc.parse_log(text, stem(start))[0]


def test_a_gauge_frozen_at_6_percent_is_no_reason_to_say_it_ended_at_6() -> None:
    """The 2026-11-19 night: 99 % at connect, 6 % at every reading after, 100 % at a reconnect after a short drop."""
    lines = [(0, f"connected BB Black {ADDRESS} serial 0 battery 99% signal -70 dBm")]
    lines += [(10 + 10 * k, f"samples {2500 * (k + 1)} (+2500) battery 6%") for k in range(5 * 360)]
    t = 10 + 10 * 5 * 360
    lines += [(t + 20, f"connected BB Black {ADDRESS} serial 0 battery 100% signal unknown (no scan)")]
    lines += [(t + 30 + 10 * k, f"samples {2500 * (k + 1)} (+2500) battery 6%") for k in range(9 * 180)]
    lines += [(t + 30 + 10 * 9 * 180, "stopped, battery 6%")]
    band = pnc.band_numbers(_log(T, lines))
    assert band["stuck_at"] == [6, 100] and band["first"] == 99 and band["last"] == 99
    est = band["estimate"]
    assert est["full"] == 99 and 9.4 < est["hours"] < 9.6 and est["pct"] == 0
    fix = pnc.band_issue(band)
    assert "6 %" not in fix and "ended at" not in fix
    assert fix.startswith("The headband streamed 9.5 h after its 99 % reading, longer than the estimate of 11 %/h "
                          "allows (so it drained under 10.4 %/h)")
    short = pnc.band_numbers(_log(T, lines[: 7 * 360]))  # 7 h: about 22 % left, nothing to say
    assert short["estimate"]["pct"] == round(99 - 11 * short["estimate"]["hours"]) and pnc.band_issue(short) is None
    mid = pnc.band_numbers(_log(T, lines[: 8 * 360]))  # 8 h: about 11 % left
    assert pnc.band_issue(mid).startswith(f"The headband streamed 8.0 h after its 99 % reading: about "
                                          f"{mid['estimate']['pct']} % left by wear time (an estimate")
    text = pnc.band_text(band)
    assert "stuck at 6 %, 100 %" in text and "by wear time (an estimate" in text


def test_a_moving_gauge_and_a_full_charge_say_nothing() -> None:
    lines = [(0, f"connected BB Black {ADDRESS} serial 0 battery 98% signal -70 dBm")]
    lines += [(10 + 10 * k, f"samples {2500 * (k + 1)} (+2500) battery {98 - k // 33}%") for k in range(360)]
    band = pnc.band_numbers(_log(T, lines))
    assert band["stuck"] == 0 and band["first"] == 98 and band["last"] == 98 - 359 // 33
    assert band["estimate"]["pct"] == round(98 - 11.0 * band["estimate"]["hours"])
    assert pnc.band_issue(band) is None


def _phone_lines(hours: float, plateau_min: float, screen_hour: int | None, wifi: bool) -> list[tuple[float, str]]:
    """A phone battery line a minute: 100 % with a flat counter for `plateau_min` after unplugging, then 60 mA (the
    screen hour 300 mA); with `wifi`, Wi-Fi lines that say when the screen was on."""
    out, uah = [], 4_000_000.0
    for m in range(int(hours * 60)):
        on = screen_hour is not None and screen_hour * 60 <= m < (screen_hour + 1) * 60
        ma = 300.0 if on else 60.0
        if m >= plateau_min:
            uah -= ma * 1000 / 60
        pct = 100 if m < plateau_min else int(uah / 40_000)
        out.append((m * 60.0, f"phone battery {pct}% charge {uah:.0f} uAh current {ma * 1000:.0f} uA unplugged "
                              "temp 30.0 C"))
        if wifi and m % 30 == 0:
            out.append((m * 60.0, f"wifi connected, 144 Mbps, -52 dBm, 2.4 GHz; default route wifi; screen "
                                      f"{'on' if on else 'off'}; idle no; lock not held"))
    return out


@pytest.mark.parametrize("wifi", [True, False])
def test_the_phones_cost_leaves_out_the_first_hour_and_the_screen(wifi: bool) -> None:
    start = datetime(2026, 11, 20, 2, 0, 0)  # on the hour, so the screen hour is one clock hour
    st = pnc.battery_numbers(_log(start, _phone_lines(8, 60, 5, wifi)))["phone"]["steady"]
    assert st["mah_per_hour"] == pytest.approx(60, abs=1) and st["ma"] == pytest.approx(60, abs=1)
    assert st["unplug_skipped_h"] == pytest.approx(1.0, abs=0.05) and st["screen_hours"] == 1
    assert st["hours"] == pytest.approx(6.0, abs=0.1)
    assert st["screen"] == ("logged" if wifi else "guessed from the current")
    assert "left out: the first 1.0 h after unplugging, 1 hour with" in pnc.phone_cost_text(st)


# ---- the lines the app writes since 2026-11-25 (the owner's night of 2026-11-24 said "382 lines not understood") ------
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "phone_night_check"
REAL_LOGS = sorted(FIXTURES.glob("*.log"))
LENDER_LINES = [
    "the screen that lent the connection is gone; saving and reconnecting at once",
    "drop (lender gone); last data 2026-11-25T14:18:31.044; reconnecting",
    "reconnected (direct, try 1) after a drop (lender gone); previous run 2026-11-25-141752, last data "
    "2026-11-25T14:18:31.044, 11.0 s ago",
]
NEW_LINES = LENDER_LINES + [
    "started on the connection that was already live on the screen: no search, no new contact check",
    "no contact reading on the live connection; not measured now",
    "contact ohms O1=inf O2=inf T3=1876694 T4=inf (measured 2026-11-25T14:10:11.123 on the live connection; "
    "not measured again)",
    "phone step counter: on", "phone step counter: off", "phone step counter: no sensor", "phone steps 134848",
    "span: sleep start", "span: sleep end", "span: nap start", "span: dream_catcher end", "span: calibration start",
    "span: sleep start (again: Undo)", "span: some_new_kind start (again: Undo)",
    "sleep kit on for 2026-11-25-141752-1",
    "sleep kit on for 2026-11-25-141752-2; smart alarm set: wake by 07:30, window from 07:00",
    "sleep kit off after 2026-11-25-141752-1",
    "the headband is back: sleep goes on by itself from here in a new stretch 2026-11-25-141752-2 "
    "(the app's guess; Undo takes it away)",
    "Undo: the stretch the app opened by itself (2026-11-25-141752-2) is taken away",
    "Undo: sleep goes on", "Undo: work, sound go on",
    "could not write the span 2026-11-25-141752-1: FileSystemException; the recording goes on",
    "notice: Low battery. The headband is at 5 %",
    "no data for 20 min: what was marked ends at the last data",
    "no data for 6 h: the recording stops itself",
]


@pytest.mark.parametrize("line", NEW_LINES)
def test_the_new_lines_are_understood(line: str) -> None:
    assert pnc.parse_line(line) is not None, line


@pytest.mark.parametrize("log", REAL_LOGS, ids=lambda p: p.name)
def test_every_line_of_the_real_logs_is_understood(log: Path) -> None:
    events, unknown = pnc.parse_log(log.read_text(), log.stem)
    assert unknown == []
    assert events


def test_the_fixture_logs_are_made_from_real_ones_and_hold_no_identifiers() -> None:
    assert {p.name for p in REAL_LOGS} >= {"2026-11-25-141752.log", "2026-11-25-141922.log", "2026-11-25-003600.log",
                                           "2026-11-25-052304.log"}
    kinds = {e.kind for p in REAL_LOGS for e in pnc.parse_log(p.read_text(), p.stem)[0]}
    assert {"live_connection", "step_counter", "steps", "span", "contact_not_measured"} <= kinds
    text = "\n".join(p.read_text() for p in REAL_LOGS)  # the repository is public: no address, serial, IP or name
    assert set(re.findall(r"the laptop (\S+) did not answer", text)) <= {"LAPTOP"}
    assert set(pnc.MAC.findall(text)) <= {"AA:BB:CC:DD:EE:FF"}
    assert set(re.findall(r"serial (\S*)", text)) <= {"000000"}
    assert set(re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text)) <= {"0.0.0.0"}


def test_a_run_on_the_live_connection_has_no_contact_reading_and_that_is_no_fault(tmp_path: Path) -> None:
    run = PhoneRun(T, seconds=600, night_end=True, hum_t3=False, flat_t4=False, contact=None,
                   head=["started on the connection that was already live on the screen: no search, no new "
                         "contact check"],
                   extra=[(7.0, "no contact reading on the live connection; not measured now")])
    write_run(tmp_path / "recordings", run)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    assert s["contact"]["not_measured"] == 1
    assert not any("contact" in f.lower() for f in s["fixes"]), s["fixes"]
    assert "no reading: the recording started on the connection the app's screen already had" in pnc.render(s)


def test_no_reading_without_a_live_connection_is_still_a_fault(tmp_path: Path) -> None:
    write_run(tmp_path / "recordings", PhoneRun(T, seconds=600, night_end=True, contact=None, hum_t3=False,
                                                flat_t4=False))
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert any(f.startswith("No contact reading at the start") for f in s["fixes"]), s["fixes"]


def test_a_gap_after_the_screen_that_lent_the_connection_was_closed(tmp_path: Path) -> None:
    a = PhoneRun(T, seconds=600, end="lender", contact=None)
    b = PhoneRun(a.last + timedelta(seconds=11), seconds=600, night_end=True, contact=None, hum_t3=False,
                 flat_t4=False, band_battery=(88, 87), phone_battery=(99, 98),
                 head=[f"reconnected (direct, try 1) after a drop (lender gone); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.044, 11.0 s ago"])
    for r in (a, b):
        write_run(tmp_path / "recordings", r)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    gaps = [x for x in s["breaks"] if x.cat != "late"]
    assert len(gaps) == 1 and gaps[0].cat == "drop"
    assert gaps[0].text == ("drop (lender gone); the app's screen was closed while it held the connection, the "
                            "recorder took the headband over; back by direct, try 1")
    assert len(s["drops"]) == 1


def test_a_stall_on_a_lent_connection_is_explained_like_any_no_data_drop(tmp_path: Path) -> None:
    a = PhoneRun(T, seconds=600, end="stall", contact=None,
                 head=["started on the connection that was already live on the screen: no search, no new contact "
                       "check"])
    b = PhoneRun(a.last + timedelta(seconds=51), seconds=300, night_end=True, hum_t3=False, flat_t4=False,
                 band_battery=(88, 87), phone_battery=(99, 98),
                 head=[f"reconnected (direct, try 1) after a drop (no data); previous run {stem(T)}, last data "
                       f"{a.last:%Y-%m-%dT%H:%M:%S}.044, 51.0 s ago"])
    for r in (a, b):
        write_run(tmp_path / "recordings", r)
    s = pnc.check(tmp_path, NIGHT, signal=False)
    assert s["unknown"] == []
    gaps = [x for x in s["breaks"] if x.cat != "late"]
    assert [g.text.split(";")[0] for g in gaps] == ["drop (no data)"]


# ---- a night said by its spans file (Record first) ------------------------------------------------------------------
def at(h: int, m: int, s: int = 0) -> datetime:
    return datetime(2026, 11, 19, h, m, s)


def day_recording(root: Path, *, sleep: tuple[datetime, datetime] | None, source: str = "owner_button",
                  ended_by: str = "owner") -> str:
    """One recording of three file sets from 22:00: lost packets and a drop while awake (before the sleep), a drop
    and lost packets inside the sleep, awake again after it. Returns the recording id."""
    rid = stem(at(22, 0))
    a = PhoneRun(at(22, 0), seconds=300, lost=[(100, 4)], end="drop", recording=rid, contact=None)  # awake
    b = PhoneRun(a.last + timedelta(seconds=82), seconds=600, lost=[(400, 6)], end="drop", recording=rid,
                 contact=None, head=[f"reconnected (direct, try 1) after a drop (out of range); previous run "
                                     f"{rid}, last data {a.last:%Y-%m-%dT%H:%M:%S}.000, 82.0 s ago"])
    c = PhoneRun(b.last + timedelta(seconds=82), seconds=480, recording=rid, contact=None, night_end=True,
                 head=[f"reconnected (direct, try 1) after a drop (out of range); previous run {stem(b.start)}, "
                       f"last data {b.last:%Y-%m-%dT%H:%M:%S}.000, 82.0 s ago"])
    for k, r in enumerate((a, b, c)):
        write_run(root / "recordings", r, seed=k)
    lines = [] if sleep is None else [span_line(rid, 1, "sleep", sleep[0], sleep[1], source, ended_by)]
    write_spans(root / "spans", rid, *lines, span_line(rid, 2, "work", at(22, 26), at(22, 27)))
    return rid


def test_a_night_with_spans_is_reported_by_its_sleep_stretches(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    rid = day_recording(root, sleep=(at(22, 10), at(22, 25)))
    s = pnc.check(root, "2026-11-19", signal=False)
    assert (s["source"], s["name"]) == ("phone", "2026-11-19")
    assert [(x["start"], x["end"], x["who"], x["how"]) for x in s["stretches"]] == [
        (at(22, 10).timestamp(), at(22, 25).timestamp(), "you pressed Sleep", "you ended it")]
    # the numbers are about the 15 minutes of sleep, not the 26 minutes of the recording
    assert s["span_s"] == pytest.approx(900, abs=1)
    assert len(s["drops"]) == 1 and s["drops"][0].length == pytest.approx(90, abs=2)  # the awake drop is not counted
    assert s["packets"].lost == 6  # nor the 4 lost packets before the sleep
    assert s["signal_s"] == pytest.approx(900 - 90, abs=3)
    assert s["whole"]["recorded_s"] == pytest.approx(1380, abs=1) and 0 < s["whole"]["outside_s"] < s["whole"]["recorded_s"]
    text = pnc.render(s)
    assert "Sleep stretches (what you marked)" in text
    assert "22:10 to 22:25, 15.0 min: you pressed Sleep; you ended it" in text
    assert "whole recording" in text and "outside the sleep" in text
    assert "1 drop;" in text.splitlines()[2]
    assert rid in text  # the recording named


def test_the_words_for_who_marked_a_stretch_and_how_it_ended() -> None:
    assert pnc.who_marked("owner_button") == "you pressed Sleep"
    assert pnc.who_marked("owner_confirmed") == "you said yes afterwards"
    assert pnc.who_marked("auto_start") == "the app marked it by itself"
    assert pnc.who_marked("auto_resume") == "the app marked it by itself (the headband came back)"
    assert pnc.who_marked("something_new") == "something_new"
    assert pnc.ended_how("headband_off") == "the headband was off for an hour"
    assert pnc.ended_how("recording_stopped") == "you stopped the recording"
    assert pnc.ended_how("undone") == "you took it away with Undo"
    assert pnc.ended_how(None) == "still open"


def test_stretches_you_said_yes_to_and_stretches_the_app_marked_say_so(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    day_recording(root, sleep=(at(22, 10), at(22, 25)), source="owner_confirmed", ended_by="headband_off")
    text = pnc.render(pnc.check(root, "2026-11-19", signal=False))
    assert "22:10 to 22:25, 15.0 min: you said yes afterwards; the headband was off for an hour" in text


def test_a_recording_with_an_id_and_no_sleep_stretch_is_not_a_night(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    day_recording(root, sleep=None)
    s = pnc.check(root, None, signal=False)
    assert s["not_night"] is True
    text = pnc.render(s)
    assert "nothing in it was marked as sleep" in text
    assert "22:00 to 22:2" in text  # when it was recorded
    assert "Verdict" not in text and "Fix first" not in text
    s2 = pnc.check(root, "2026-11-19", signal=False)  # named by its evening date: the same words
    assert s2["not_night"] is True


def test_a_later_recording_with_no_sleep_is_said_and_the_night_stays_reachable(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    day_recording(root, sleep=(at(22, 10), at(22, 25)))
    t2 = datetime(2026, 11, 20, 14, 25, 0)
    rid = stem(t2)
    write_run(root / "recordings", PhoneRun(t2, seconds=100, recording=rid, night_end=True, contact=None))
    write_spans(root / "spans", rid, span_line(rid, 1, "work", t2, None))
    s = pnc.check(root, None, signal=False)
    assert s["not_night"] is True and "2026-11-19" in pnc.render(s)  # says where the newest night is
    assert pnc.check(root, "2026-11-19", signal=False)["name"] == "2026-11-19"


def test_a_recording_id_with_no_spans_file_is_judged_as_before(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    write_run(root / "recordings", PhoneRun(T, seconds=600, night_end=True, recording=stem(T), hum_t3=False,
                                            flat_t4=False))
    s = pnc.check(root, NIGHT, signal=False)
    assert not s.get("not_night") and s["data_runs"] == 1 and not s.get("stretches")


def test_spans_are_found_where_the_laptop_keeps_them(tmp_path: Path) -> None:
    """On the laptop the recordings are in `<local>/recordings` and the spans in `<local>/phone/spans`."""
    root = tmp_path / "local"
    day_recording(root, sleep=(at(22, 10), at(22, 25)))
    (root / "phone").mkdir()
    (root / "spans").rename(root / "phone" / "spans")
    assert len(pnc.check(root, "2026-11-19", signal=False)["stretches"]) == 1


def test_stretches_taken_away_by_the_owner_are_mentioned_only_when_the_reader_lists_them() -> None:
    from types import SimpleNamespace

    import spans
    gone = spans.Span("x-3", "sleep", None, at(22, 17).timestamp(), at(22, 21).timestamp(), "auto_start")
    assert pnc.removed_words(spans.SpansFile()) == ""  # a reader without `removed` says nothing
    assert pnc.removed_words(SimpleNamespace(removed=[])) == ""
    assert pnc.removed_words(SimpleNamespace(removed=[gone])) == "1 stretch was taken away by you: 22:17-22:21"


def test_the_signal_numbers_count_only_the_sleep(tmp_path: Path) -> None:
    root = tmp_path / "eeg-export"
    day_recording(root, sleep=(at(22, 10), at(22, 25)))
    s = pnc.check(root, "2026-11-19")
    assert s["signal"]["seconds"] == pytest.approx(900 - 90, abs=4)
