"""Our own Bluetooth driver (scripts/brainbit_ble.py), its recorder (record_ble.py) and probe (ble_probe.py), on the
fake headband in tests/fake_bleak (a fake `bleak` that speaks the protocol as our notes describe it).

The expected bytes and volts below are worked out by hand from the protocol notes, not from the driver. They pin
what the driver assumes; the probe on the real headband decides whether the assumptions hold (TO VERIFY).
"""
import ast
import asyncio
import json
import math
import os
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "fake_bleak"))  # `import bleak` below gets the fake headband

import bleak  # noqa: E402

import battery  # noqa: E402
import brainbit_ble as bb  # noqa: E402
import ble_probe  # noqa: E402
import recorder_poll  # noqa: E402
import to_bdf  # noqa: E402

pytestmark = pytest.mark.realtime  # fake headband / board timers: run apart on a loaded machine (conftest.py)

VPC = 2.4 / 6 / 8388608  # volts per count at gain 6, by hand: 2.4 V reference / gain / 2^23
SVC = "7e400001-b534-f393-68a9-e50e24dcca97"
REC = struct.Struct("<I4f")


def test_the_fake_bleak_is_in_use():
    assert hasattr(bleak, "HEADBAND"), "tests must never load the real bleak (no radio in tests)"


# ---- decoding ------------------------------------------------------------------------------------------------
def packet(counter: int, blocks: list[tuple[int, int, int, int]], marker: int = 0) -> bytes:
    """Hand-built signal packet: uint32 LE counter, then per sample a marker byte and four signed 24-bit LE counts."""
    out = bytearray(counter.to_bytes(4, "little"))
    for b in blocks:
        out.append(marker)
        for c in b:
            out += (c & 0xFFFFFF).to_bytes(3, "little")
    return bytes(out)


def test_decode_signal_hand_built_packet():
    # wire slots O2 T3 T4 O1 = 1, -1, +max, -max; seven more samples of zeros
    data = bytes.fromhex("e8030000" "00" "010000" "ffffff" "ffff7f" "000080") + bytes(13 * 7)
    assert len(data) == 108
    p = bb.decode_signal(data)
    assert p.counter == 1000 and len(p.samples) == 8 and p.markers == [0] * 8
    assert [s[0] for s in p.samples] == list(range(1000, 1008))  # one packet number per sample
    num, o1, o2, t3, t4 = p.samples[0]
    assert o2 == pytest.approx(1 * VPC) and t3 == pytest.approx(-1 * VPC)
    assert t4 == pytest.approx(8388607 * VPC) and o1 == pytest.approx(-8388608 * VPC)
    assert o1 == pytest.approx(-0.4)  # gain 6 makes the 24-bit range +-0.4 V, the vendor's input range
    assert p.counts[0] == (1, -1, 8388607, -8388608)


def test_decode_signal_other_order_and_gain():
    data = packet(0, [(10, 20, 30, 40)])
    lay = bb.Layout(order=("T3", "T4", "O1", "O2"), gain=12)
    _n, o1, o2, t3, t4 = bb.decode_signal(data, lay).samples[0]
    half = 2.4 / 12 / 8388608
    assert (t3, t4, o1, o2) == pytest.approx((10 * half, 20 * half, 30 * half, 40 * half))
    with pytest.raises(ValueError):
        bb.Layout(order=("O1", "O1", "T3", "T4"))


@pytest.mark.parametrize("size", [0, 3, 4, 16, 18, 107, 109])
def test_decode_signal_rejects_odd_lengths(size):
    with pytest.raises(ValueError):
        bb.decode_signal(bytes(size))


def test_decode_signal_short_packet_of_one_sample():
    assert len(bb.decode_signal(packet(5, [(0, 0, 0, 0)])).samples) == 1


def test_counter_wraps_inside_a_packet_and_between_packets():
    p = bb.decode_signal(packet(0xFFFFFFFC, [(0, 0, 0, 0)] * 8))
    assert [s[0] for s in p.samples] == [0xFFFFFFFC, 0xFFFFFFFD, 0xFFFFFFFE, 0xFFFFFFFF, 0, 1, 2, 3]
    expected_next = (0xFFFFFFF8 + 8) % 2 ** 32
    assert bb.counter_gap(expected_next, 0) == 0  # continuous across the wrap
    assert bb.counter_gap(expected_next, 16) == 16  # two packets lost after the wrap
    assert bb.counter_gap(0xFFFFFFF8, 8) == 16  # two packets lost across the wrap
    assert bb.counter_gap(8, 0xFFFFFFF8) == -16  # and the same jump backwards is not a loss
    assert bb.counter_gap(None, 12345) == 0
    assert bb.counter_gap(808, 816) == 8
    assert bb.counter_gap(5008, 0) == -5008  # the stream restarted (counter back to 0)
    assert bb.counter_gap(5008, 5000) == -8  # a repeated packet


def test_decode_resist_and_status():
    data = struct.pack("<I4I", 7, 220_000, 0xFFFFFFFF, 400_000, 150_000)  # wire order O2 T3 T4 O1
    assert bb.decode_resist(data) == {"O1": 150_000.0, "O2": 220_000.0, "T3": math.inf, "T4": 400_000.0}
    with pytest.raises(ValueError):
        bb.decode_resist(bytes(19))
    st = bb.decode_status(bytes([68, 0xFE, 3, 8]))  # the Headband notes saw 44 00 2d 08 = 68 %
    assert (st.battery, st.cmd_error, st.state) == (68, -2, 3)
    with pytest.raises(ValueError):
        bb.decode_status(b"\x01\x02")


def test_char_uuids_follow_the_npm_numbering():
    assert bb.char_uuid(SVC, 3) == "7e400003-b534-f393-68a9-e50e24dcca97"
    assert bb.SERVICE_RE.match("7e400001-b534-f393-68a9-e50e24dcca99")
    assert not bb.SERVICE_RE.match("6e400001-b534-f393-68a9-e50e24dcca9e")  # the original BrainBit's family


def test_known_address_from_recorder_logs(tmp_path):
    (tmp_path / "2026-11-17-230000.log").write_text(
        "2026-11-17T23:00:00.000 connected BB Black AA:BB:CC:00:11:22 serial X battery 50% signal -70 dBm\n")
    (tmp_path / "2026-11-18-010000.log").write_text(
        "2026-11-18T01:00:00.000 connected BB Black aa:bb:cc:33:44:55 serial X battery 40% signal -80 dBm\n"
        "2026-11-18T01:30:00.000 reconnected after 12 s away (try 2), battery 40%; same files\n")
    (tmp_path / "2026-11-18-020000.log").write_text("2026-11-18T02:00:00.000 contact ohms O1=1\n")  # no address
    assert bb.known_address(tmp_path) == "AA:BB:CC:33:44:55"
    assert bb.known_address(tmp_path / "missing") is None


def test_power_down_is_never_sent():
    drv = bb.BrainBitBLE("C0:FF:EE:00:00:01", log=lambda _m: None)
    with pytest.raises(ValueError):
        asyncio.run(drv.command(bb.CMD_POWER_DOWN))


def test_scripts_never_unpair_or_remove_devices():
    """DECISIONS 84: BrainBit's SDK removed every known Bluetooth device. Ours must not even contain such a call."""
    banned = {"unpair", "RemoveDevice", "remove_device", "remove", "CancelPairing"}
    for name in ("brainbit_ble.py", "record_ble.py", "ble_probe.py"):
        tree = ast.parse((ROOT / "scripts" / name).read_text())
        calls = {n.func.attr for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
        assert not calls & banned, (name, calls & banned)
        strings = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
        assert not [s for s in strings if s in ("RemoveDevice", "Disconnect", "unpair")], name


# ---- the driver on the fake headband ---------------------------------------------------------------------------
class Run:
    """Drive bb.BrainBitBLE.run() against the fake for a while and keep what the callbacks saw."""

    def __init__(self, address: str | None = "C0:FF:EE:00:00:01", mode: int = bb.CMD_SIGNAL, **kw) -> None:
        self.logs: list[str] = []; self.samples: list[tuple] = []; self.gaps: list[int] = []; self.lost: list[str] = []
        self.resist: list[dict] = []; self.contacts: list[dict] = []; self.connected: list[int] = []
        opts = dict(timeout=2.0, stall_s=0.3, backoff=(0.05, 0.1, 0.2), contact_s=0.3, log=self.logs.append)
        opts.update(kw)
        self.drv = bb.BrainBitBLE(address, **opts); self.mode = mode
        self.drv.on_samples = lambda p, _t, gap: (self.samples.extend(p.samples), self.gaps.append(gap))
        self.drv.on_resist = lambda ohms, _t: self.resist.append(ohms)

    def go(self, until, limit: float = 10.0, during=None) -> "Run":  # noqa: ANN001
        async def main() -> None:
            stopping = asyncio.Event()
            task = asyncio.create_task(self.drv.run(
                self.mode, stopping, on_connected=lambda _i, a: self.connected.append(a),
                on_lost=lambda e, _a, _p: self.lost.append(str(e)), on_contact=self.contacts.append))
            t0 = time.time()
            while not until(self) and time.time() - t0 < limit:
                if during:
                    during(self)
                await asyncio.sleep(0.02)
                if task.done():
                    task.result()  # raise a bug (e.g. the fake's unpair guard) instead of hiding it
            stopping.set()
            await asyncio.wait_for(task, 5)
        asyncio.run(main())
        return self


def test_connects_to_a_known_address_without_scanning():
    hb = bleak.reset(interval=0.004)
    r = Run().go(lambda r: len(r.samples) >= 400)
    assert len(r.samples) >= 400 and hb.scans == 0 and hb.connects == 1
    assert hb.commands[0] == bb.CMD_SIGNAL and hb.commands[-1] == bb.CMD_IDLE  # stops the stream when done
    nums = [s[0] for s in r.samples]
    assert nums == list(range(len(nums)))  # one packet number per sample, from 0
    assert hb.client is None  # disconnected at the end


def test_scans_by_name_only_without_an_address():
    hb = bleak.reset(interval=0.004)
    r = Run(address=None).go(lambda r: len(r.samples) >= 80)
    assert hb.scans == 1 and r.drv.address == "C0:FF:EE:00:00:01" and len(r.samples) >= 80


def test_finds_the_service_by_pattern_with_either_suffix():
    bleak.reset(interval=0.004, suffix="9")
    r = Run().go(lambda r: len(r.samples) >= 80)
    assert r.drv.service == "7e400001-b534-f393-68a9-e50e24dcca99" and len(r.samples) >= 80


def test_decoded_volts_match_the_fake_sdk_signal():
    """The fake headband encodes the fake SDK's samples; decoding must give them back within one count."""
    sys.path.insert(0, str(ROOT / "tests" / "fake_neurosdk"))
    import random
    from neurosdk.scanner import fake_sample
    os.environ["FAKE_BRAINBIT_SEED"] = "11"
    try:
        bleak.reset(interval=0.004)
    finally:
        del os.environ["FAKE_BRAINBIT_SEED"]
    r = Run().go(lambda r: len(r.samples) >= 300)
    rng = random.Random("11")
    for n, got in enumerate(r.samples[:300]):
        want = fake_sample(n, rng)
        assert got[0] == n
        assert got[1:] == pytest.approx((want.O1, want.O2, want.T3, want.T4), abs=VPC)


def test_reconnects_in_process_after_drops_with_backoff():
    hb = bleak.reset(interval=0.004, drop_after=0.3, drop_for=0.35, max_drops=2)

    def restarts(r: Run) -> list[int]:  # where the packet number went back: a new stream after a reconnect
        return [i for i in range(1, len(r.samples)) if r.samples[i][0] < r.samples[i - 1][0]]
    r = Run().go(lambda r: len(restarts(r)) == 2 and len(r.samples) - restarts(r)[-1] > 100)
    assert hb.drops == 2 and hb.connects == 3 and len(r.connected) == 3
    assert r.connected[0] == 0 and r.connected[1] >= 1  # refused tries while it was away came first
    assert len(r.lost) >= 4, r.lost  # each drop: "link dropped", then refused tries while it is away
    assert any("link dropped" in x for x in r.lost) and any("not found" in x for x in r.lost)
    # the pauses between failed tries grow: 0.05, 0.1, 0.2, ...
    assert hb.connect_times[1] - hb.connect_times[0] >= 0.3 + 0.35 - 0.05
    assert len(restarts(r)) == 2  # the counter starts again after each reconnect: packet numbers can repeat
    assert all(g == 0 for g in r.gaps)  # and nothing counts as lost: the gap is in the .idx times instead


def test_a_late_disconnect_callback_does_not_end_the_next_session():
    async def main() -> None:
        bleak.reset(interval=0.004)
        drv = bb.BrainBitBLE("C0:FF:EE:00:00:01", log=lambda _m: None)
        await drv.connect(); old = drv.client
        await drv.close(idle=False)
        await drv.connect()
        old._cb(old)  # the first link's "disconnected" arrives only now
        assert not drv._lost.is_set()
        drv.client._lost()  # the current link breaking still counts
        await asyncio.sleep(0.01)
        assert drv._lost.is_set()
        await drv.close()
    asyncio.run(main())


def test_lost_packets_are_counted_as_gaps():
    bleak.reset(interval=0.004, lose_every=5)
    r = Run().go(lambda r: len(r.samples) >= 400)
    assert set(g for g in r.gaps if g) == {8} and r.drv.lost_samples == 8 * sum(1 for g in r.gaps if g)


def test_stall_gets_the_start_command_again_then_a_reconnect():
    hb = bleak.reset(interval=0.004, stall_after=0.2)
    r = Run(stall_s=0.25).go(lambda r: hb.connects >= 2 and len(r.samples) > 100, limit=8)
    assert any("sending the start command again" in x for x in r.logs), r.logs
    assert any("no signal for" in x for x in r.lost), r.lost
    assert hb.connects >= 2


def test_contact_check_runs_in_process_and_the_signal_comes_back():
    hb = bleak.reset(interval=0.004)
    asked = []

    def ask(r: Run) -> None:
        if len(r.samples) > 100 and not asked:
            asked.append(len(r.samples)); r.drv.check_contact()
    r = Run().go(lambda r: r.contacts and len(r.samples) > asked[0] + 200 if asked else False, during=ask)
    assert r.contacts[0] == {"O1": 150_000.0, "O2": 220_000.0, "T3": 400_000.0, "T4": 180_000.0}
    assert hb.commands[:5] == [bb.CMD_SIGNAL, bb.CMD_IDLE, bb.CMD_RESIST, bb.CMD_IDLE, bb.CMD_SIGNAL]
    assert hb.connects == 1  # no reconnect, no restart


def test_signal_and_resistance_together_with_command_5():
    hb = bleak.reset(interval=0.004)
    r = Run(mode=bb.CMD_SIGNAL_RESIST).go(lambda r: len(r.samples) >= 300 and len(r.resist) >= 3)
    assert hb.commands[0] == bb.CMD_SIGNAL_RESIST and r.resist[-1]["T3"] == 400_000.0


def test_command_5_without_signal_falls_back_to_command_3():
    hb = bleak.reset(interval=0.004, ignore_cmd5=True)
    r = Run(mode=bb.CMD_SIGNAL_RESIST).go(lambda r: len(r.samples) >= 200)
    assert hb.commands[:3] == [bb.CMD_SIGNAL_RESIST, bb.CMD_IDLE, bb.CMD_SIGNAL]
    assert any("falling back to signal only" in x for x in r.logs)


def test_probe_analysis_helpers():
    fs = bb.FS
    strong = [20 * math.sin(2 * math.pi * 10 * k / fs) for k in range(fs * 10)]
    weak = [5 * math.sin(2 * math.pi * 10 * k / fs) for k in range(fs * 10)]
    assert ble_probe.band_power(strong) / ble_probe.band_power(weak) == pytest.approx(16, rel=1e-6)
    off_band = [20 * math.sin(2 * math.pi * 25 * k / fs) for k in range(fs * 10)]
    assert ble_probe.band_power(off_band) < 0.01 * ble_probe.band_power(strong)
    lifts = {"O1": dict(slot=3), "O2": dict(slot=0), "T3": dict(slot=1), "T4": dict(slot=2)}
    assert ble_probe.order_from(lifts) == "O2,T3,T4,O1"
    assert ble_probe.order_from({**lifts, "T4": dict(slot=1)}) is None


# ---- the recorders end to end (subprocesses, run side by side: about 20 s) ----------------------------------
def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def recorders(tmp_path_factory):
    base = tmp_path_factory.mktemp("recorders")
    env = dict(os.environ, FAKE_BRAINBIT_SEED="7")
    specs = {
        "sdk": (["record_night.py", "--seconds", "11"], dict(PYTHONPATH=str(ROOT / "tests" / "fake_neurosdk"))),
        "ble": (["record_ble.py", "--seconds", "11"], dict(PYTHONPATH=str(ROOT / "tests" / "fake_bleak"))),
        # streaming starts after the 6 s contact check; the link drops 3 s later and stays away 2.5 s
        "drop": (["record_ble.py", "--seconds", "12"], dict(PYTHONPATH=str(ROOT / "tests" / "fake_bleak"),
                                                           FAKE_BLE_DROP_AFTER="9", FAKE_BLE_DROP_FOR="2.5",
                                                           FAKE_BLE_MAX_DROPS="1", FAKE_BLE_LOSE_EVERY="40")),
        "probe": (["ble_probe.py", "--no-head", "--recorder-port", "0", "--time-scale", "0.1"],
                  dict(PYTHONPATH=str(ROOT / "tests" / "fake_bleak"))),
    }
    procs, ports, dirs = {}, {}, {}
    for name, (args, extra) in specs.items():
        dirs[name] = base / name; ports[name] = free_port()
        where = (["--out", str(dirs[name]), "--recordings", str(base / "none")] if name == "probe"
                 else ["--out", str(dirs[name]), "--port", str(ports[name])])
        log = open(base / f"{name}.out", "w")
        # the recorders must run without numpy: the system python, not this environment's
        procs[name] = subprocess.Popen(["python3", str(ROOT / "scripts" / args[0]), *args[1:], *where],
                                       env={**env, **extra}, stdout=log, stderr=subprocess.STDOUT)
    seen = recorder_poll.watch(procs, ports, ("sdk", "ble", "drop"))
    out = {n: (base / f"{n}.out").read_text() for n in specs}
    return dict(dirs=dirs, seen=seen, rc={n: p.returncode for n, p in procs.items()}, out=out)


def one_set(folder: Path) -> dict[str, Path]:
    files = sorted(folder.iterdir())
    stamps = {f.name.split(".")[0] for f in files}
    assert len(stamps) == 1, files
    return {f.name[len(next(iter(stamps))):]: f for f in files}


def records(path: Path) -> list[tuple]:
    data = path.read_bytes()
    assert len(data) % REC.size == 0
    return [REC.unpack_from(data, i) for i in range(0, len(data), REC.size)]


LOG_LINES = [r"^\S+ connected .+ ([0-9A-F]{2}:){5}[0-9A-F]{2} serial \S+ battery \d+% signal \S+ dBm$",
             r"^\S+ contact ohms O1=\d+ O2=\d+ T3=\d+ T4=\d+$", r"^\S+ live check page on port \d+$",
             r"^\S+ recording started, 250 Hz, Ctrl\+C to stop$", r"^\S+ samples \d+ \(\+\d+\) battery \d+%$",
             r"^\S+ total samples \d+, [\d.]+ min$", r"^\S+ stopped, battery \d+%$"]


def test_ble_recorder_writes_the_sdk_recorders_format(recorders):
    assert recorders["rc"]["sdk"] == 0 and recorders["rc"]["ble"] == 0, recorders["out"]
    sets = {n: one_set(recorders["dirs"][n]) for n in ("sdk", "ble")}
    assert set(sets["sdk"]) == set(sets["ble"]) == {".f32", ".idx", ".log", ".markers.jsonl", ".header.json"}
    recs = {n: records(sets[n][".f32"]) for n in sets}
    for n in sets:
        assert 2300 < len(recs[n]) < 3100, (n, len(recs[n]))  # 11 s at 250 Hz
        assert [r[0] for r in recs[n]] == list(range(len(recs[n])))  # packet numbers count samples from 0
    # same fake signal, same seed: the same volts, within the 24-bit step our headband's packets carry
    k = min(len(recs["sdk"]), len(recs["ble"]))
    for a, b in zip(recs["sdk"][:k], recs["ble"][:k]):
        assert a[1:] == pytest.approx(b[1:], abs=VPC)
    for n in sets:
        idx = sets[n][".idx"].read_bytes()
        rows = [struct.unpack_from("<dQ", idx, i) for i in range(0, len(idx), 16)]
        assert rows[0][1] == 0 and all(b[1] > a[1] and b[0] >= a[0] for a, b in zip(rows, rows[1:]))
        assert rows[-1][1] < len(recs[n])
        log = sets[n][".log"].read_text().splitlines()
        for pat in LOG_LINES:
            assert any(re.match(pat, line) for line in log), (n, pat, log)
        assert battery.from_logs(recorders["dirs"][n], time.time()), n
        marks = [json.loads(x) for x in sets[n][".markers.jsonl"].read_text().splitlines()]
        assert [set(m) for m in marks] == [{"t", "i", "text"}] and marks[0]["text"] == "test-marker"
        runs = to_bdf.runs(sets[n][".f32"])
        assert len(runs) == 1 and len(runs[0][1]) == len(recs[n])
    assert bb.known_address(recorders["dirs"]["ble"]) == "C0:FF:EE:00:00:01"  # its own log names the headband
    s, b = recorders["seen"]["sdk"], recorders["seen"]["ble"]
    assert set(s["state"]) == set(b["state"]) and set(s["hello"]) == set(b["hello"]) and s["marker"] and b["marker"]
    assert b["state"]["contact"] == {"O1": 150000, "O2": 220000, "T3": 400000, "T4": 180000}


def test_ble_recorder_survives_a_drop_in_process(recorders):
    assert recorders["rc"]["drop"] == 0, recorders["out"]["drop"]
    files = one_set(recorders["dirs"]["drop"])  # one process, one set of files all night
    log = files[".log"].read_text()
    assert "headband lost or not found: link dropped" in log and "reconnected after" in log, log
    assert re.search(r"lost \d+ samples in \d+ gaps", log), log
    seen = recorders["seen"]["drop"]
    assert "reconnecting" in seen["status"] and seen["status"][-1] == "recording", seen["status"]
    assert seen["errors_after_up"] == 0  # the page server stayed up through the drop
    runs = to_bdf.runs(files[".f32"])
    assert len(runs) == 2, [(t, len(x)) for t, x in runs]  # the gap is found from the .idx arrival times
    gap = runs[1][0] - (runs[0][0] + len(runs[0][1]) / 250)
    assert 2.0 < gap < 7.5, gap  # away 2.5 s; tries at +1 s and +3 s after the drop, the next would be +8 s


def test_probe_runs_on_the_fake_headband(recorders):
    assert recorders["rc"]["probe"] == 0, recorders["out"]["probe"]
    folder = next(recorders["dirs"]["probe"].iterdir())
    assert {"gatt.txt", "raw.txt", "decoded.csv", "probe.log", "summary.txt", "summary.json"} <= {
        f.name for f in folder.iterdir()}
    s = json.loads((folder / "summary.json").read_text())
    assert s["service"] == SVC and all(s["verdict"][k] for k in (
        "rate_250", "packet_108_bytes", "counter_counts_samples", "no_lost_samples", "command2_stops_signal",
        "command4_gives_resistance", "command5_signal", "command5_resistance", "signal_restarts_after_resistance")), s
    raw = (folder / "raw.txt").read_text().splitlines()
    assert any(" signal 7e400004 108 " in line for line in raw)
    assert "7e400003" in (folder / "gatt.txt").read_text()
