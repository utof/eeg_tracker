"""Make app/test/fixtures/own_ble_vectors.json: packets of the fake headband (tests/fake_bleak) and hand-built edge
cases, with what the laptop's parser (scripts/brainbit_ble.py) makes of them. The phone's Dart parser
(app/lib/headband/own/protocol.dart) must give the very same numbers (app/test/own_ble_protocol_test.dart), and
analysis/tests/test_own_ble_vectors.py checks that this file still matches the Python parser.

  python3 app/test/fixtures/make_own_ble_vectors.py            # rewrite the file
  python3 app/test/fixtures/make_own_ble_vectors.py --check    # exit 1 if the file is out of date

Standard library only; no radio, no recordings: every byte comes from the fake headband with a fixed seed.
Volts are written with Python's shortest float text, which Dart reads back to the same 64-bit number.
"""
from __future__ import annotations

import json
import math
import random
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tests" / "fake_bleak"))  # `import bleak` = the fake headband
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests" / "fake_neurosdk"))

import bleak  # noqa: E402 (the fake)
import brainbit_ble as bb  # noqa: E402
from neurosdk.scanner import fake_sample  # noqa: E402

OUT = Path(__file__).resolve().parent / "own_ble_vectors.json"


def hand_packet(counter: int, blocks: list[tuple[int, int, int, int]], marker: int = 0) -> bytes:
    out = bytearray((counter % (1 << 32)).to_bytes(4, "little"))
    for b in blocks:
        out.append(marker)
        for c in b:
            out += (c & 0xFFFFFF).to_bytes(3, "little")
    return bytes(out)


def signal_case(name: str, data: bytes, layout: bb.Layout = bb.DEFAULT_LAYOUT) -> dict:
    case: dict = dict(name=name, hex=data.hex(), order=list(layout.order), gain=layout.gain)
    try:
        p = bb.decode_signal(data, layout)
    except ValueError:
        case["error"] = True
        return case
    case.update(counter=p.counter, markers=p.markers, counts=[list(c) for c in p.counts],
                samples=[list(s) for s in p.samples])
    return case


def resist_case(name: str, data: bytes, layout: bb.Layout = bb.DEFAULT_LAYOUT) -> dict:
    case: dict = dict(name=name, hex=data.hex(), resist_order=list(layout.resist_order))
    try:
        ohms = bb.decode_resist(data, layout)
    except ValueError:
        case["error"] = True
        return case
    case["ohms"] = {k: ("inf" if math.isinf(v) else v) for k, v in ohms.items()}
    return case


def status_case(data: bytes) -> dict:
    case: dict = dict(hex=data.hex())
    try:
        st = bb.decode_status(data)
    except ValueError:
        case["error"] = True
        return case
    case.update(battery=st.battery, cmd_error=st.cmd_error, state=st.state, text=st.text())
    return case


def build() -> dict:
    rng = random.Random("own-ble-vectors")
    signal = []
    n = 0
    counter = 0
    for k in range(6):  # six packets in a row from the fake headband: alpha, blinks and jaw noise
        rows = []
        for _ in range(8):
            x = fake_sample(n, rng); n += 1
            rows.append(dict(O1=x.O1, O2=x.O2, T3=x.T3, T4=x.T4))
        signal.append(signal_case(f"fake headband packet {k}", bleak.encode_signal(counter, rows)))
        counter += 8
    signal += [
        signal_case("extremes: 1, -1, +max, -max", hand_packet(1000, [(1, -1, 8388607, -8388608)] + [(0, 0, 0, 0)] * 7)),
        signal_case("markers kept", hand_packet(16, [(5, -6, 7, -8)] * 8, marker=0xA5)),
        signal_case("counter wraps inside the packet", hand_packet(0xFFFFFFFC, [(100, 200, 300, 400)] * 8)),
        signal_case("one sample", hand_packet(5, [(-123456, 654321, -1, 0)])),
        signal_case("twelve samples", hand_packet(2_600_000, [(k, -k, 1000 * k, -1000 * k) for k in range(12)])),
        signal_case("other order and gain", hand_packet(0, [(10, 20, 30, 40)] * 2),
                    bb.Layout(order=("T3", "T4", "O1", "O2"), gain=12)),
        signal_case("order O1 O2 T3 T4, gain 3", hand_packet(7, [(-10, 20, -30, 40)]),
                    bb.Layout(order=("O1", "O2", "T3", "T4"), gain=3)),
    ]
    signal += [signal_case(f"bad length {size}", bytes(size)) for size in (0, 3, 4, 16, 18, 107, 109)]
    resist = [
        resist_case("fake headband", bleak.encode_resist(42, dict(O1=150_000, O2=220_000, T3=400_000, T4=180_000))),
        resist_case("one electrode open", struct.pack("<I4I", 7, 220_000, 0xFFFFFFFF, 400_000, 150_000)),
        resist_case("longer packet", struct.pack("<I4I", 7, 1, 2, 3, 4) + b"\x09\x09"),
        resist_case("other order", struct.pack("<I4I", 1, 11, 22, 33, 44),
                    bb.Layout(resist_order=("T3", "T4", "O1", "O2"))),
        resist_case("too short", bytes(19)),
    ]
    status = [status_case(bytes(b)) for b in ([87, 0, 3, 0], [68, 0xFE, 3, 8], [100, 2, 0x80], [1, 2])]
    gaps = [dict(expected=e, counter=c, gap=bb.counter_gap(e, c)) for e, c in (
        (None, 12345), (808, 808), (808, 816), (0, 0), (0xFFFFFFF8, 8), (8, 0xFFFFFFF8), (5008, 0), (5008, 5000),
        ((0xFFFFFFF8 + 8) % 2 ** 32, 0), ((0xFFFFFFF8 + 8) % 2 ** 32, 16), (0, 0x7FFFFFFF), (0, 0x80000000))]
    uuids = [dict(service=s, n=k, uuid=bb.char_uuid(s, k), is_service=bool(bb.SERVICE_RE.match(s)))
             for s in ("7e400001-b534-f393-68a9-e50e24dcca97", "7e400001-b534-f393-68a9-e50e24dcca99",
                       "6e400001-b534-f393-68a9-e50e24dcca9e") for k in (2, 3, 4, 5)]
    return dict(
        made_by="app/test/fixtures/make_own_ble_vectors.py",
        constants=dict(
            names=list(bb.NAMES), fs=bb.FS, status_char=bb.STATUS_CHAR, command_char=bb.COMMAND_CHAR,
            signal_char=bb.SIGNAL_CHAR, resist_char=bb.RESIST_CHAR, cmd_power_down=bb.CMD_POWER_DOWN,
            cmd_idle=bb.CMD_IDLE, cmd_signal=bb.CMD_SIGNAL, cmd_resist=bb.CMD_RESIST,
            cmd_signal_resist=bb.CMD_SIGNAL_RESIST, header=bb.HEADER, block=bb.BLOCK, vref=bb.VREF, gain=bb.GAIN,
            signal_order=list(bb.SIGNAL_ORDER), resist_order=list(bb.RESIST_ORDER), resist_header=bb.RESIST_HEADER,
            resist_open=bb.RESIST_OPEN, name_prefixes=list(bb.NAME_PREFIXES), device_info=bb.DEVICE_INFO,
            stall_s=bb.STALL_S, backoff=list(bb.BACKOFF), status_every_s=bb.STATUS_EVERY_S, contact_s=bb.CONTACT_S,
            volts_per_count=bb.DEFAULT_LAYOUT.volts_per_count, layout_text=bb.DEFAULT_LAYOUT.describe(),
            mode_names={str(k): v for k, v in bb.MODE_NAMES.items()}),
        signal=signal, resist=resist, status=status, counter_gap=gaps, uuids=uuids)


def text() -> str:
    return json.dumps(build(), indent=1) + "\n"


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(0 if OUT.exists() and OUT.read_text() == text() else 1)
    OUT.write_text(text())
    print(f"wrote {OUT}")
