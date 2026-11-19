"""Make app/test/fixtures/diy_vectors.json: E9 frames of the DIY ADS1299 board (the firmware's own golden frames,
frames of the fake board in tests/fake_diy, and damaged ones), byte streams and frame sequences, with what the
laptop's driver (scripts/diy_board.py) makes of them. The phone's Dart decoder (app/lib/headband/diy/e9.dart) must
give the very same results (app/test/diy_e9_test.dart), and analysis/tests/test_diy_vectors.py checks that this file
still matches the Python driver.

  python3 app/test/fixtures/make_diy_vectors.py            # rewrite the file
  python3 app/test/fixtures/make_diy_vectors.py --check    # exit 1 if the file is out of date

Standard library only; every byte comes from the golden file or from the fake board's encoder with a fixed seed.
Volts are written with Python's shortest float text, which Dart reads back to the same 64-bit number. Errors are
written as the first check that failed (`short`, `magic`, `channels`, `length`, `crc`, `range`, `status`), not as
Python's message text.
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests" / "fake_diy"))

import diy_board as db  # noqa: E402
import fake_board  # noqa: E402 (its encoder is written apart from diy_board.py)

OUT = Path(__file__).resolve().parent / "diy_vectors.json"
GOLDEN = ROOT / "tests" / "fake_diy" / "golden" / "e9_vectors.json"
VREFS = (4.5, 4.45)

REASONS = (("is too short", "short"), ("not an E9 version 1 frame", "magic"), ("channel count", "channels"),
           ("bytes for", "length"), ("CRC mismatch", "crc"), ("out of range", "range"), ("0xC prefix", "status"))


def reason(e: db.FrameError) -> str:
    text = str(e)
    for needle, code in REASONS:
        if needle in text:
            return code
    raise AssertionError(f"unknown FrameError text: {text}")


def fields(f: db.Frame) -> dict:
    return dict(channels=f.channels, flags=f.flags, gain=f.gain, fs=f.fs, seq=f.seq, time_us=f.time_us,
                overruns=f.overruns, status=f.status, counts=list(f.counts), mode=f.mode, mode_text=f.mode_text,
                overrun_flag=f.overrun_flag, lead_off_p=f.lead_off_p, lead_off_n=f.lead_off_n, gpio=f.gpio,
                config=list(f.config), volts={str(v): list(f.volts(v)) for v in VREFS})


def case(name: str, data: bytes) -> dict:
    out = dict(name=name, hex=data.hex())
    try:
        out["frame"] = fields(db.decode_frame(data))
    except db.FrameError as e:
        out["error"] = reason(e)
    return out


def reseal(data: bytes, i: int, value: int) -> bytes:
    """One byte changed and the CRC made right again, so a later check is what fails."""
    b = bytearray(data[:-2]); b[i] = value
    return bytes(b) + db.crc16(bytes(b)).to_bytes(2, "little")


def frames() -> list[dict]:
    golden = json.loads(GOLDEN.read_text())
    out = [case(f"golden {g['name']}", bytes.fromhex(g["hex"])) for g in golden]
    rng = random.Random("diy-vectors-frames")
    for channels in (4, 6, 8):
        for flags in (1, 2, 4, 9, 10, 0):
            codes = [rng.randrange(-(1 << 23), 1 << 23) for _ in range(channels)]
            data = fake_board.encode(codes, seq=rng.randrange(1 << 32), time_us=rng.randrange(1 << 32),
                                     overruns=rng.randrange(1000), flags=flags, gain=rng.choice(db.GAINS),
                                     fs=rng.choice(db.RATES), status=0xC00000 | rng.randrange(1 << 20))
            out.append(case(f"fake {channels} ch flags {flags}", data))
    base = bytes.fromhex(golden[1]["hex"])  # the breadboard's test signal frame
    out += [
        case("empty", b""), case("21 bytes", base[:21]), case("cut by one", base[:-1]),
        case("one byte too many", base + b"\x00"), case("two frames in one datagram", base + base),
        case("magic E8", reseal(base, 1, ord("8"))), case("version 2", reseal(base, 2, 2)),
        case("5 channels", reseal(base, 3, 5)), case("8 channels in a 37-byte frame", reseal(base, 3, 8)),
        case("flags 16", reseal(base, 4, 16)), case("flags 15", reseal(base, 4, 15)), case("gain 3", reseal(base, 5, 3)),
        case("gain 12", reseal(base, 5, 12)), case("rate 300", reseal(reseal(base, 6, 0x2C), 7, 1)),
        case("rate 500", reseal(reseal(base, 6, 0xF4), 7, 1)), case("status 0xB", reseal(base, 20, 0xB0)),
        case("status 0xF", reseal(base, 20, 0xF0)), case("status 0xC with lead-off bits", reseal(reseal(base, 20, 0xCA), 21, 0x5F)),
        case("not a frame at all", b"ADS1299 learning lab. BENCH ONLY; remove ALL body electrodes."),
    ]
    return out


def bit_flips() -> dict:
    """Every single-bit flip of the breadboard's test signal frame: the check that refuses it, bit by bit."""
    base = bytes.fromhex(json.loads(GOLDEN.read_text())[1]["hex"])
    codes = []
    for bit in range(len(base) * 8):
        b = bytearray(base); b[bit // 8] ^= 1 << (bit % 8)
        try:
            db.decode_frame(bytes(b)); codes.append("ok")
        except db.FrameError as e:
            codes.append(reason(e))
    return dict(hex=base.hex(), refused_by=codes)


def stream_case(name: str, stream: bytes, seed: str, most: int) -> dict:
    """The stream fed in chunks of 1..most bytes; after each chunk: [the frames' sequence numbers, the text lines
    taken, bytes left in the buffer, bytes of unfinished text]."""
    rng = random.Random(seed)
    chunks, pos = [], 0
    while pos < len(stream):
        n = rng.randrange(1, most + 1); chunks.append(n); pos += n
    dec = db.StreamDecoder(); steps = []; pos = 0
    for n in chunks:
        got = dec.feed(stream[pos:pos + n]); pos += n
        steps.append([[f.seq for f in got], dec.take_lines(), len(dec.buffer), len(dec.text)])
    return dict(name=name, hex=stream.hex(), chunks=chunks, steps=steps, frames=dec.frames, bad_frames=dec.bad_frames,
                discarded_bytes=dec.discarded_bytes)


def streams() -> list[dict]:
    good = [fake_board.encode([k, -k, 3 * k, 0], seq=k + 1, time_us=4000 * (k + 1), flags=1) for k in range(40)]
    corrupt = bytearray(good[12]); corrupt[30] ^= 0x40
    fake_magic = b"E9\x01\x04" + bytes(10)
    mixed = (fake_board.BANNER.encode() + b"\r\n" + good[3][17:] + b"".join(good[:12]) + bytes(corrupt) + fake_magic
             + random.Random(1).randbytes(300) + b"".join(good[13:30]) + good[30][:20] + fake_board.HALTED.encode()
             + b"\r\n" + b"".join(good[31:]))
    prompts = "\r\n".join([fake_board.BANNER, fake_board.PROMPT_R, fake_board.PROMPT_V, "ID=0x3c; 4 physical channels; "
                           "250 SPS; gain 24", fake_board.PROMPT_TN, "short", "x" * 500, "tab\tline ok"]).encode() + b"\n"
    eight = [fake_board.encode([k] * 8, seq=k, time_us=4000 * k, flags=2) for k in range(10)]
    return [
        stream_case("text, cut frame, damage, garbage", mixed, "diy-stream-1", 60),
        stream_case("the same, 1 to 3 bytes at a time", mixed, "diy-stream-2", 3),
        stream_case("prompts and long text", prompts + b"".join(good[:5]), "diy-stream-3", 25),
        stream_case("8 channels and a trailing E", b"".join(eight) + b"E", "diy-stream-4", 97),
        stream_case("garbage only", random.Random(9).randbytes(3000) + b"E9\x01", "diy-stream-5", 512),
    ]


def tracker_cases() -> list[dict]:
    def f(seq, overruns=0, t=None, flags=1, channels=4, gain=24, fs=250):
        return dict(seq=seq & 0xFFFFFFFF, time_us=(4000 * seq if t is None else t) & 0xFFFFFFFF, overruns=overruns,
                    flags=flags, channels=channels, gain=gain, fs=fs)
    seqs = {
        "gaps split into board and link": [f(1), f(2), f(6), f(10, 2, flags=9), f(11, 5, flags=9)],
        "repeats, late and a restart": [f(100), f(101), f(102), f(102), f(99), f(101), f(103), f(30), f(31), f(32)],
        "far behind is a restart": [f(1000), f(1001), f(1001 - 64), f(1001 - 65), f(1001 - 64)],
        "clock goes back": [f(5), f(6), f(7, t=100), f(8, t=4100)],
        "configuration changes": [f(1), f(2), f(3, flags=2), f(4, flags=2), f(5, flags=10), f(6, channels=8, flags=10),
                                  f(7, gain=12, channels=8, flags=10), f(8, fs=500, gain=12, channels=8, flags=10)],
        "uint32 wrap": [f(0xFFFFFFFE), f(0xFFFFFFFF), f(0), f(3), f(2)],
        "timing anomalies": [f(1, t=0), f(2, t=4000), f(3, t=9000), f(4, t=12000), f(5, t=16000), f(105, t=416000),
                             f(106, t=420900)],
    }
    out = []
    for name, items in seqs.items():
        tr = db.Tracker(); steps = []
        for it in items:
            frame = db.Frame(it["channels"], it["flags"], it["gain"], it["fs"], it["seq"], it["time_us"],
                             it["overruns"], 0xC00000, (0,) * it["channels"])
            s = tr.observe(frame)
            steps.append(dict(kind=s.kind, lost=s.lost, board_missed=s.board_missed))
        out.append(dict(name=name, frames=items, steps=steps, accepted=tr.accepted, lost=tr.lost,
                        board_missed=tr.board_missed, duplicates=tr.duplicates, stale=tr.stale,
                        timing_anomalies=tr.timing_anomalies))
    return out


def build() -> dict:
    texts = [fake_board.BANNER, fake_board.PROMPT_R, fake_board.PROMPT_V, fake_board.PROMPT_TN,
             fake_board.HALTED.strip(), "ID=0x3c; 4 physical channels; 250 SPS; gain 24", "HALTED: Wi-Fi timeout",
             "type R", "ADS1299 learning lab"]
    return dict(
        made_by="app/test/fixtures/make_diy_vectors.py",
        constants=dict(magic=db.MAGIC.decode(), version=db.VERSION, header=db.HEADER.size, channels=list(db.CHANNELS),
                       gains=list(db.GAINS), rates=list(db.RATES), max_size=db.MAX_SIZE, max_text=db.MAX_TEXT,
                       default_vref=db.DEFAULT_VREF, udp_port=db.UDP_PORT, stale_window=db.STALE_WINDOW,
                       frame_sizes={str(n): db.frame_size(n) for n in db.CHANNELS},
                       volts_per_count={str(g): db.volts_per_count(g) for g in db.GAINS},
                       crc_check=db.crc16(b"123456789")),
        frames=frames(), bit_flips=bit_flips(), streams=streams(), tracker=tracker_cases(),
        text_kinds=[dict(line=t, kind=db.text_kind(t)) for t in texts])


def text() -> str:
    """One case per line: small enough to read in a diff."""
    v = build()
    out = ["{"]
    keys = list(v)
    for k in keys:
        end = "," if k != keys[-1] else ""
        val = v[k]
        if isinstance(val, list):
            out.append(f" {json.dumps(k)}: [")
            out += [f"  {json.dumps(x)}{',' if i < len(val) - 1 else ''}" for i, x in enumerate(val)]
            out.append(f" ]{end}")
        else:
            out.append(f" {json.dumps(k)}: {json.dumps(val)}{end}")
    return "\n".join(out + ["}"]) + "\n"


if __name__ == "__main__":
    if "--check" in sys.argv:
        raise SystemExit(0 if OUT.exists() and OUT.read_text() == text() else 1)
    OUT.write_text(text())
    print(f"wrote {OUT}")
