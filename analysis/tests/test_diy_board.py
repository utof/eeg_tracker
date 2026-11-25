"""The DIY ADS1299 board's laptop host driver (scripts/diy_board.py) and its recorder (scripts/record_diy.py), on the
fake board in tests/fake_diy (a fake `serial` module and a UDP sender that speak eeg_ads1299_lab's E9 protocol).

The golden frames in tests/fake_diy/golden/e9_vectors.json come from the board firmware's own framing code
(eeg_ads1299_lab, MIT: firmware/esp32_ads1299_bench/portable_core.h, built by tests/fake_diy/golden/make_golden.cpp);
the volts are worked out by hand from the ADS1299 datasheet's LSB (VREF / (gain x 2^23)), not from the driver.
"""
import ast
import json
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE = ROOT / "tests" / "fake_diy"
sys.path.insert(0, str(FAKE))

import diy_board as db  # noqa: E402
import fake_board  # noqa: E402
import record_diy  # noqa: E402
import recorder_hub  # noqa: E402
import recorder_poll  # noqa: E402
import recording  # noqa: E402
import to_bdf  # noqa: E402

pytestmark = pytest.mark.realtime  # fake headband / board timers: run apart on a loaded machine (conftest.py)

VECTORS = json.loads((FAKE / "golden" / "e9_vectors.json").read_text())
LSB_24 = 4.5 / (24 * 8388608)  # volts per count at gain 24 and the internal 4.5 V reference, by hand
STATE_KEYS = {"status", "battery", "battery_note", "minutes", "age", "names", "fs", "contact", "contact_t", "data"}
HELLO_KEYS = {"hello", "names", "fs", "unit", "status", "next_i"}


def vector(name: str) -> dict:
    return next(v for v in VECTORS if v["name"] == name)


def raw(name: str) -> bytes:
    return bytes.fromhex(vector(name)["hex"])


# ---- frames ----------------------------------------------------------------------------------------------------
@pytest.mark.parametrize("v", VECTORS, ids=[v["name"] for v in VECTORS])
def test_golden_frames_from_the_firmware_decode(v):
    f = db.decode_frame(bytes.fromhex(v["hex"]))
    assert len(bytes.fromhex(v["hex"])) == v["size"] == db.frame_size(v["channels"]) == 25 + 3 * v["channels"]
    assert (f.channels, f.gain, f.fs, f.flags, f.seq, f.time_us, f.overruns, f.status) == (
        v["channels"], v["gain"], v["fs"], v["flags"], v["seq"], v["tick"], v["overruns"], v["status"])
    assert list(f.counts) == v["codes"]


def test_the_fake_board_encodes_like_the_firmware():
    for v in VECTORS:
        got = fake_board.encode(v["codes"], seq=v["seq"], time_us=v["tick"], overruns=v["overruns"],
                                flags=v["flags"], gain=v["gain"], fs=v["fs"], status=v["status"])
        assert got.hex() == v["hex"], v["name"]


def test_crc_is_ccitt_false():
    assert db.crc16(b"123456789") == 0x29B1  # the catalogue check value, also asserted by the firmware's own test


def test_volts_from_counts_by_hand():
    f = db.decode_frame(raw("native_core_test"))  # gain 24: -2^23, -1, 0, 2^23 - 1
    v = f.volts(4.5)
    assert v[0] == pytest.approx(-0.1875, abs=1e-15)  # -VREF / gain: the negative rail exactly
    assert v[1] == pytest.approx(-LSB_24) and v[2] == 0.0
    assert v[3] == pytest.approx(0.1875 - LSB_24)
    sq = db.decode_frame(raw("breadboard_test_signal")).volts(4.5)  # the +-VREF/2400 internal test square wave
    assert sq[0] == pytest.approx(1.875e-3, rel=1e-5) and sq[2] == pytest.approx(-1.875e-3, rel=1e-5)
    assert db.decode_frame(raw("six_channels_gain_1")).volts(4.5)[0] == pytest.approx(-4.5)  # gain 1: -VREF
    assert db.decode_frame(raw("native_core_test")).volts(4.0)[0] == pytest.approx(-4.0 / 24)  # --vref is used
    assert db.volts_per_count(24, 4.5) == pytest.approx(LSB_24)


def test_flags_mode_and_status_bits():
    t = db.decode_frame(raw("breadboard_test_signal"))
    assert t.mode == "test" and not t.overrun_flag and "not EEG" in t.mode_text
    e = db.decode_frame(raw("eight_channels_short_overrun"))  # flags 2 | 8, status 0xCFF0F5
    assert e.mode == "short" and e.overrun_flag and "not EEG" in e.mode_text
    assert (e.lead_off_p, e.lead_off_n, e.gpio) == (0xFF, 0x0F, 0x5)  # 1100 + LOFF_STATP + LOFF_STATN + GPIO[7:4]
    assert db.decode_frame(raw("native_core_test")).mode == "synthetic"  # flag 4
    assert t.config == (4, 24, 250, 1) and e.config == (8, 24, 250, 2)  # the overrun bit is not configuration


def test_every_single_bit_flip_is_rejected():
    good = raw("breadboard_test_signal")
    for i in range(len(good)):
        for bit in range(8):
            bad = bytearray(good); bad[i] ^= 1 << bit
            with pytest.raises(db.FrameError):
                db.decode_frame(bytes(bad))


def test_wrong_lengths_fields_and_status_prefix_are_rejected():
    good = raw("breadboard_test_signal")
    for data in (good[:-1], good + b"\0", b"", good[:20]):
        with pytest.raises(db.FrameError):
            db.decode_frame(data)

    def resealed(i: int, value: int) -> bytes:  # a field changed and the CRC made valid again
        body = bytearray(good[:-2]); body[i] = value
        return bytes(body) + struct.pack("<H", db.crc16(bytes(body)))
    for i, value in ((2, 2), (3, 5), (5, 3), (4, 0x10), (20, 0xB0)):  # version, channels, gain, flags, status 0xB...
        with pytest.raises(db.FrameError):
            db.decode_frame(resealed(i, value))
    assert db.decode_frame(resealed(5, 12)).gain == 12  # resealing itself is not what fails


def test_stream_decoder_resynchronises_through_text_garbage_and_damage():
    frames = [fake_board.encode([k, -k, 3 * k, 0], seq=k + 1, time_us=4000 * (k + 1), flags=1) for k in range(40)]
    corrupt = bytearray(frames[12]); corrupt[30] ^= 0x40
    fake_magic = b"E9\x01\x04" + bytes(10)  # looks like a header, fails later
    stream = (b"ADS1299 learning lab. BENCH ONLY; remove ALL body electrodes.\r\n" + frames[3][17:]  # a partial frame
              + b"".join(frames[:12]) + bytes(corrupt) + fake_magic + bytes(random.Random(1).randbytes(300))
              + b"".join(frames[13:30]) + frames[30][:20]
              + b"\nHALTED / BENCH ONLY; CAPTURE INVALID: No valid data for 2 s; inspect DRDY and clock.\r\n"
              + b"".join(frames[31:]))
    dec = db.StreamDecoder(); got = []; rng = random.Random(4); pos = 0
    while pos < len(stream):
        n = rng.randrange(1, 60); got += dec.feed(stream[pos:pos + n]); pos += n
    want = [db.decode_frame(f) for i, f in enumerate(frames) if i not in (12, 30)]
    assert got == want
    assert dec.frames == len(want) and dec.bad_frames >= 2 and dec.discarded_bytes > 300
    lines = dec.take_lines()
    assert lines[0].startswith("ADS1299 learning lab.") and lines[-1].startswith("HALTED / BENCH ONLY")
    assert len(lines) == 2  # binary garbage never comes out as "text"
    assert dec.take_lines() == []


def test_stream_decoder_stays_small_on_endless_garbage():
    dec = db.StreamDecoder(); rng = random.Random(9)
    for _ in range(200):
        assert dec.feed(rng.randbytes(512)) == []
        assert len(dec.buffer) < db.MAX_SIZE and len(dec.text) <= db.MAX_TEXT
    assert dec.discarded_bytes > 90_000


def test_board_text_kinds():
    assert db.text_kind("HALTED / BENCH ONLY; CAPTURE INVALID: Wi-Fi timeout") == "halted"
    assert db.text_kind("BREADBOARD: chip awake. Measure VCAP1 (leg 28 to ground) above 1.1 V; then type V. "
                        "This firmware does not sense voltages.") == "prompt"
    assert db.text_kind("BREADBOARD: type T for the internal test signal or N for shorted inputs (noise). "
                        "There is no electrode mode.") == "prompt"
    assert db.text_kind("ADS1299 learning lab. BENCH ONLY; remove ALL body electrodes.") == "banner"
    assert db.text_kind("ID=0x3c; 4 physical channels; 250 SPS; gain 24") == "info"


# ---- the sequence: gaps, repeats, restarts ---------------------------------------------------------------------
def frame(seq: int, overruns: int = 0, t: int | None = None, flags: int = 1, channels: int = 4) -> db.Frame:
    return db.Frame(channels, flags, 24, 250, seq & 0xFFFFFFFF, (4000 * seq if t is None else t) & 0xFFFFFFFF,
                    overruns, 0xC00000, (0,) * channels)


def test_tracker_splits_lost_samples_into_board_and_link():
    tr = db.Tracker()
    assert tr.observe(frame(1)).kind == "first"
    s = tr.observe(frame(2)); assert (s.kind, s.lost, s.board_missed) == ("next", 0, 0)
    s = tr.observe(frame(6)); assert (s.lost, s.board_missed) == (3, 0)  # 3 frames lost on the link
    s = tr.observe(frame(10, overruns=2, flags=9)); assert (s.lost, s.board_missed) == (3, 2)  # board missed 2 of 3
    s = tr.observe(frame(11, overruns=5, flags=9)); assert (s.lost, s.board_missed) == (0, 0)  # never more than lost
    assert (tr.accepted, tr.lost, tr.board_missed) == (5, 6, 2)


def test_tracker_duplicates_stale_restart_and_configuration():
    tr = db.Tracker()
    for seq in (100, 101, 102):
        tr.observe(frame(seq))
    assert tr.observe(frame(102)).kind == "duplicate"
    assert tr.observe(frame(99)).kind == "stale"  # a late datagram: dropped, never sorted in
    assert tr.observe(frame(103)).kind == "next"
    assert tr.observe(frame(1, t=9_000_000)).kind == "restart"  # far back: the board started again
    assert tr.observe(frame(104, flags=2)).kind == "config"  # test signal -> shorted inputs: a new capture
    assert (tr.duplicates, tr.stale) == (1, 1)
    tr.reset(); assert tr.observe(frame(1, flags=2)).kind == "first"


def test_tracker_crosses_the_uint32_wrap_and_counts_timing_anomalies():
    tr = db.Tracker()
    tr.observe(frame(0xFFFFFFFE, t=0xFFFFE0C0)); s = tr.observe(frame(0xFFFFFFFF, t=0xFFFFF060))
    assert s.kind == "next" and s.lost == 0
    s = tr.observe(frame(0x100000000 + 1, t=0x100000000 + 4000))  # seq 1 after 2^32 - 1: one frame lost
    assert s.kind == "next" and s.lost == 1 and tr.timing_anomalies == 0
    assert tr.observe(frame(2, t=4000 + 4000 + 50_000)).kind == "next"  # 50 ms late for one step
    assert tr.timing_anomalies == 1


# ---- montage ---------------------------------------------------------------------------------------------------
def test_default_montage_is_the_breadboards_planned_electrodes():
    m = record_diy.load_montage(None)
    assert m.names == ("O1", "O2", "Fz", "Fp1") and "earlobe" in m.reference and "earlobe" in m.bias
    assert record_diy.channel_names(m.names, 4) == (("O1", "O2", "Fz", "Fp1"), None)
    names, note = record_diy.channel_names(m.names, 8)  # the 8-channel chip of stage 2: no planned positions
    assert names == tuple(f"Ch{i}" for i in range(1, 9)) and "8" in note


def test_montage_from_a_list_or_a_file(tmp_path):
    assert record_diy.load_montage("C3, C4,Cz,Pz").names == ("C3", "C4", "Cz", "Pz")
    p = tmp_path / "m.json"; p.write_text(json.dumps({"channels": ["A1", "B2", "C3", "D4"], "reference": "nose"}))
    assert record_diy.load_montage(str(p)).names == ("A1", "B2", "C3", "D4")
    for bad in ("O1,O1,O2,T3", "O1,,O2", "O1,has space", "x" * 30):
        with pytest.raises(ValueError):
            record_diy.load_montage(bad)


# ---- the hub: BrainBit's shape unchanged, any channel count for the board ------------------------------------
def test_hub_defaults_are_brainbits(tmp_path):
    hub = recorder_hub.Hub(tmp_path)
    assert hub.names == ("O1", "O2", "T3", "T4") and hub.rec.size == 20 and hub.fs == 250
    assert set(hub.state()) == STATE_KEYS and hub.state()["names"] == ("O1", "O2", "T3", "T4")


def test_hub_writes_any_channel_count_and_starts_new_file_sets(tmp_path):
    hub = recorder_hub.Hub(tmp_path, names=tuple(f"Ch{i}" for i in range(1, 9)), reports=False)
    first = hub.open_files("2026-11-19-010203")
    hub.add_batch([(7, *(c * 1e-6 for c in range(8)))], now=1000.0); hub.add_marker("m")
    hub.write_pending()
    st = hub.state(); assert set(st) == STATE_KEYS and len(st["data"]) == 8 and st["contact"]["Ch8"] is None
    assert hub.end_file_set() == first and hub.data is None and hub.add_marker("between sets") is None
    hub.configure(("O1", "O2", "Fz", "Fp1"), 250)
    assert hub.open_files() != first and hub.seen == 0 and hub.state()["names"] == ("O1", "O2", "Fz", "Fp1")
    hub.add_batch([(1, 1e-6, 2e-6, 3e-6, 4e-6)], now=1001.0); hub.finish(); hub.close()
    a = (tmp_path / f"{first}.f32").read_bytes(); b = (tmp_path / f"{hub.stamp}.f32").read_bytes()
    assert struct.unpack("<I8f", a)[0] == 7 and len(a) == 36 and struct.unpack("<I4f", b)[:2] == (1, pytest.approx(1e-6))
    assert json.loads((tmp_path / f"{first}.markers.jsonl").read_text())["i"] == 1
    assert "total samples 1" in (tmp_path / f"{first}.log").read_text()


def test_the_board_hub_refuses_the_brainbit_reports(tmp_path):
    hub = recorder_hub.Hub(tmp_path / "rec", reports=False); port = free_port(); hub.serve(port)
    try:
        for path in ("sleep-report", "morning-report"):
            body = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/{path}", timeout=15).read())
            assert "O1 O2 T3 T4" in body["error"]
        assert not (tmp_path / "nights").exists()
    finally:
        hub.server.shutdown()


def test_the_log_counts_the_boards_senders_and_never_names_one(tmp_path):
    class Link:
        senders = {"192.168.1.50", "192.168.1.77"}

    class Reader:
        link = Link()

        def take_senders(self): return ["192.168.1.50", "192.168.1.77"]
        def take_counts(self): return 0, 0

    hub = recorder_hub.Hub(tmp_path, names=("O1", "O2", "Fz", "Fp1"), reports=False)
    rec = record_diy.Recording(hub, record_diy.load_montage(None), 4.5, 9000, 0)
    hub.open_files("2026-11-19-010203")
    rec.on_input(Reader(), [], [], 1000.0)
    hub.close()
    log = (tmp_path / "2026-11-19-010203.log").read_text()
    assert "datagrams from the board on the Wi-Fi" in log and "datagrams from sender number 2" in log
    assert "more than one sender on this port" in log
    assert "192.168" not in log


# ---- safety: the host only reads -------------------------------------------------------------------------------
def test_the_host_never_writes_to_the_board():
    """The bench firmware's only inputs are the operator's answers R, V (voltages measured) and T / N (mode). The
    host must never type them, so neither module may contain a write or send call (record_diy only writes files
    through the hub)."""
    banned = {"write", "writelines", "send", "sendto", "sendall", "send_break", "setDTR", "setRTS"}
    for name in ("diy_board.py", "record_diy.py"):
        tree = ast.parse((ROOT / "scripts" / name).read_text())
        calls = {n.func.attr for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
        assert not calls & banned, (name, calls & banned)


def test_the_recorder_modules_need_no_numpy_and_no_pyserial_to_load():
    code = ("import sys; sys.path.insert(0, 'scripts'); import diy_board, record_diy; "
            "assert 'numpy' not in sys.modules and 'serial' not in sys.modules")
    subprocess.run(["python3", "-c", code], cwd=ROOT, check=True)


# ---- the recorder end to end on the fake board (subprocesses side by side, about 15 s) -------------------------
def free_port(kind: int = socket.SOCK_STREAM) -> int:
    with socket.socket(socket.AF_INET, kind) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def runs(tmp_path_factory):
    base = tmp_path_factory.mktemp("diy")
    udp = free_port(socket.SOCK_DGRAM)
    fake = dict(PYTHONPATH=str(FAKE), FAKE_DIY_SEED="3")
    specs = {
        # damage on the wire: corrupt frames, frames lost on the link, conversions the board missed, garbage bytes
        "serial": (["--seconds", "6"], dict(fake, FAKE_DIY_CORRUPT_EVERY="50", FAKE_DIY_LOSE_EVERY="70",
                                            FAKE_DIY_OVERRUN_EVERY="110", FAKE_DIY_GARBAGE_EVERY="90")),
        # the USB link drops for 1.5 s while the board keeps running
        "drop": (["--seconds", "6"], dict(fake, FAKE_DIY_UNPLUG_AFTER="2", FAKE_DIY_UNPLUG_FOR="1.5")),
        # unplugged for 1 s: the DevKit restarts, prints its prompts, and streams again from sequence 1
        "reboot": (["--seconds", "6"], dict(fake, FAKE_DIY_UNPLUG_AFTER="2", FAKE_DIY_UNPLUG_FOR="1",
                                            FAKE_DIY_REBOOT="1", FAKE_DIY_PROMPT_WAIT="1")),
        "halt": (["--seconds", "8"], dict(fake, FAKE_DIY_HALT_AFTER="1.5")),
        # Wi-Fi route, 8-channel chip, shorted inputs; no fake `serial` on the path: UDP must not need pyserial
        "udp": (["--seconds", "4", "--udp", f"127.0.0.1:{udp}"], {}),
    }
    procs, ports, dirs, writes = {}, {}, {}, {}
    for name, (args, extra) in specs.items():
        dirs[name] = base / name; ports[name] = free_port(); writes[name] = base / f"{name}.writes"
        link = [] if name == "udp" else ["--serial", "/dev/fake-diy"]
        env = dict(os.environ, FAKE_DIY_WRITES=str(writes[name]), **extra)
        env.pop("PYTHONPATH", None) if name == "udp" else None
        log = open(base / f"{name}.out", "w")
        procs[name] = subprocess.Popen(["python3", str(ROOT / "scripts" / "record_diy.py"), *link, *args,
                                        "--out", str(dirs[name]), "--port", str(ports[name])],
                                       env=env, stdout=log, stderr=subprocess.STDOUT)
    sender = subprocess.Popen(["python3", str(FAKE / "fake_board.py"), "--udp", f"127.0.0.1:{udp}", "--seconds", "9",
                               "--channels", "8", "--mode", "N"],
                              env=dict(os.environ, FAKE_DIY_SEED="5", FAKE_DIY_DUPLICATE_EVERY="40",
                                       FAKE_DIY_STALE_EVERY="60", FAKE_DIY_CORRUPT_EVERY="45"),
                              stdout=open(base / "sender.out", "w"), stderr=subprocess.STDOUT)
    seen = recorder_poll.watch(procs, ports)
    for p in [*procs.values(), sender]:
        if p.poll() is None:
            p.terminate(); p.wait(10)
    out = {n: (base / f"{n}.out").read_text() for n in specs}
    return dict(dirs=dirs, seen=seen, rc={n: p.returncode for n, p in procs.items()}, out=out, writes=writes)


def sets(folder: Path) -> list[dict[str, Path]]:
    stamps = sorted({f.name.split(".")[0] for f in folder.iterdir()})
    return [{f.name[len(s):]: f for f in folder.iterdir() if f.name.split(".")[0] == s} for s in stamps]


def records(path: Path, channels: int = 4) -> list[tuple]:
    rec = struct.Struct(f"<I{channels}f"); data = path.read_bytes()
    assert len(data) % rec.size == 0
    return [rec.unpack_from(data, i) for i in range(0, len(data), rec.size)]


def lost_in_log(text: str) -> tuple[int, int, int]:
    found = re.findall(r"lost (\d+) samples in \d+ gaps \(board missed (\d+), link lost (\d+)\)", text)
    return tuple(sum(int(x[k]) for x in found) for k in range(3))  # type: ignore[return-value]


def test_recorder_writes_the_same_files_and_pages_as_the_brainbit_recorders(runs):
    assert runs["rc"]["serial"] == 0, runs["out"]["serial"]
    (files,) = sets(runs["dirs"]["serial"])
    assert set(files) == {".f32", ".idx", ".log", ".markers.jsonl", ".header.json"}
    recs = records(files[".f32"])
    assert 1200 < len(recs) < 1800, len(recs)  # 6-7 s at 250 Hz (--seconds is checked once a second), minus damage
    seqs = [r[0] for r in recs]
    assert all(b > a for a, b in zip(seqs, seqs[1:]))  # the board's own sequence numbers, never sorted or repeated
    assert all(abs(abs(v) - 83886 * LSB_24) < 1e-9 for r in recs for v in r[1:])  # the +-1.875 mV test square
    log = files[".log"].read_text()
    lost, board, link = lost_in_log(log)
    assert lost == seqs[-1] - seqs[0] + 1 - len(recs) and board > 0 and link > 0 and lost == board + link, log
    assert re.search(r"bad frames \d+, bytes skipped \d+", log), log
    for pat in (r"driver DIY board .*E9 protocol version 1; link USB serial /dev/fake-diy at 460800 baud",
                r"channels O1 O2 Fz Fp1 \(montage .*diy-breadboard-4\.json",
                r"board 4 channels, 250 Hz, gain 24, vref 4\.5 V \(assumed",
                r"format \.f32 records <I4f: board sequence number, then O1 O2 Fz Fp1 in volts",
                r"mode test signal: .*not EEG", r"recording started, 250 Hz, Ctrl\+C to stop",
                r"samples \d+ \(\+\d+\)", r"total samples \d+", r"stopped"):
        assert re.search(pat, log), (pat, log)
    idx = files[".idx"].read_bytes(); rows = [struct.unpack_from("<dQ", idx, i) for i in range(0, len(idx), 16)]
    assert rows[0][1] == 0 and all(b[1] > a[1] and b[0] >= a[0] for a, b in zip(rows, rows[1:]))
    assert len(rows) < len(recs) / 4  # read in batches (about 10 frames): not one .idx row per frame
    marks = [json.loads(x) for x in files[".markers.jsonl"].read_text().splitlines()]
    assert [m["text"] for m in marks] == ["test-marker"]
    assert len(to_bdf.runs(files[".f32"])) == 1  # 4 channels: the BrainBit record, so the BDF tool can read it
    h = recording.read(files[".f32"])  # the set's header, written by the recorder itself
    assert h.source == "header" and h.names == ("O1", "O2", "Fz", "Fp1") and h.sample_rate == 250
    assert (h.device, h.counter, h.record) == ("DIY board", "board sequence number", "<I4f")
    assert h.layout.endswith("diy-breadboard-4.json") and h.reference.where.startswith("an earlobe")
    s = runs["seen"]["serial"]
    assert set(s["state"]) == STATE_KEYS and set(s["hello"]) == HELLO_KEYS and s["marker"]
    assert s["state"]["names"] == s["hello"]["names"] == ["O1", "O2", "Fz", "Fp1"] and s["state"]["fs"] == 250
    assert s["state"]["contact"] == {"O1": None, "O2": None, "Fz": None, "Fp1": None}  # not measured by this board
    assert any("test signal, not EEG" in x for x in s["status"]), s["status"]
    assert not runs["writes"]["serial"].exists()  # the fake board recorded no byte from the host


def test_a_usb_drop_is_handled_in_process(runs):
    assert runs["rc"]["drop"] == 0, runs["out"]["drop"]
    (files,) = sets(runs["dirs"]["drop"])  # the board kept running: same capture, same files
    log = files[".log"].read_text()
    assert "board link lost" in log and "board link back after" in log, log
    lost, board, link = lost_in_log(log)
    assert 300 < link < 700 and board == 0, log  # 1.5-2.5 s at 250 Hz went by unplugged or before the reopen
    pieces = to_bdf.runs(files[".f32"])
    assert len(pieces) == 2  # the gap shows in the .idx arrival times, as with Bluetooth drops
    assert 1.0 < pieces[1][0] - (pieces[0][0] + len(pieces[0][1]) / 250) < 3.0
    assert "reconnecting" in runs["seen"]["drop"]["status"], runs["seen"]["drop"]["status"]
    assert not runs["writes"]["drop"].exists()


def test_a_board_restart_starts_a_new_file_set(runs):
    assert runs["rc"]["reboot"] == 0, runs["out"]["reboot"]
    first, second = sets(runs["dirs"]["reboot"])  # never joined silently to the old capture (PROTOCOL.md)
    old, new = first[".log"].read_text(), second[".log"].read_text()
    assert "board restarted" in old and "this file set ends here" in old, old
    assert re.search(r"continues \S+ after a board restart", new), new
    assert "board says: BREADBOARD: ADS control lines parked low" in new  # its prompts, answered elsewhere
    assert records(second[".f32"])[0][0] < 10  # the sequence started again
    assert any("prompt" in x for x in runs["seen"]["reboot"]["status"]), runs["seen"]["reboot"]["status"]
    assert not runs["writes"]["reboot"].exists()


def test_a_halted_board_is_reported(runs):
    assert runs["rc"]["halt"] == 0, runs["out"]["halt"]
    (files,) = sets(runs["dirs"]["halt"])
    log = files[".log"].read_text()
    assert "board says: HALTED / BENCH ONLY; CAPTURE INVALID: No valid data for 2 s" in log, log
    assert "no data from the board for 5 s" in log, log
    assert any(x.startswith("board halted") for x in runs["seen"]["halt"]["status"]), runs["seen"]["halt"]["status"]


def test_the_wifi_route_with_eight_channels(runs):
    assert runs["rc"]["udp"] == 0, runs["out"]["udp"]
    (files,) = sets(runs["dirs"]["udp"])
    recs = records(files[".f32"], 8)
    assert 800 < len(recs) < 1100, len(recs)
    seqs = [r[0] for r in recs]
    assert all(b > a for a, b in zip(seqs, seqs[1:]))  # repeated and late datagrams were dropped, not written
    assert all(abs(v) < 5e-6 for r in recs for v in r[1:])  # shorted inputs: microvolts of noise
    log = files[".log"].read_text()
    assert "link UDP 127.0.0.1:" in log and re.search(r"repeated \d+, late \d+", log), log
    idx = files[".idx"].read_bytes()
    assert len(idx) // 16 < len(recs) / 4  # every waiting datagram per read, in batches
    assert "the montage names 4 channels but the board sends 8" in log, log
    h = recording.read(files[".f32"])
    assert h.source == "header" and h.names == tuple(f"Ch{i}" for i in range(1, 9)) and h.record == "<I8f"
    assert h.layout == "DIY board" and all(c.site is None for c in h.channels)
    assert "mode shorted inputs" in log
    s = runs["seen"]["udp"]
    assert s["state"]["names"] == [f"Ch{i}" for i in range(1, 9)] and len(s["state"]["data"]) == 8
    assert set(s["state"]) == STATE_KEYS and set(s["hello"]) == HELLO_KEYS


# ---- the real pyserial on a pseudo-terminal (the fake board writes the master side) ----------------------------
@pytest.mark.skipif(shutil.which("uv") is None, reason="needs uv to run the recorder with pyserial 3.5")
def test_real_pyserial_reads_a_pty_and_writes_nothing_back(tmp_path):
    master, slave = os.openpty()
    path = os.ttyname(slave)
    proc = subprocess.Popen(["uv", "run", "--offline", "--no-project", "--python", "3.12", "--with", "pyserial==3.5",
                             "python", str(ROOT / "scripts" / "record_diy.py"), "--serial", path, "--seconds", "2",
                             "--out", str(tmp_path / "rec"), "--port", "0"],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for line in proc.stdout:  # write nothing before pyserial has made the port raw (no echo)
            if "board link open" in line:
                break
        board = fake_board.Board(4, "T"); board.stream_t0 = board.t0 = time.monotonic(); board.seq = 0
        os.write(master, (fake_board.BANNER + "\r\n").encode())
        os.set_blocking(master, False)
        back = b""; end = time.monotonic() + 8
        while proc.poll() is None and time.monotonic() < end:
            os.write(master, board.advance(time.monotonic()))
            try:
                back += os.read(master, 4096)
            except BlockingIOError:
                pass
            time.sleep(0.01)
        out = proc.communicate(timeout=60)[0]
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master); os.close(slave)
    assert proc.returncode == 0, out
    assert back == b""  # not one byte from the host reached the board's side
    (files,) = sets(tmp_path / "rec")
    recs = records(files[".f32"])
    assert 450 < len(recs) < 900 and [r[0] for r in recs] == list(range(recs[0][0], recs[0][0] + len(recs)))
    assert "board says: ADS1299 learning lab." in files[".log"].read_text()
