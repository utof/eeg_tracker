"""A fake DIY ADS1299 board for tests and demos: eeg_ads1299_lab's bench firmware as its PROTOCOL.md and sketch
describe it, without hardware. Two ways in:

- `tests/fake_diy/serial/` is a fake pyserial whose port streams this board's bytes (the USB-serial route):
      PYTHONPATH=tests/fake_diy python3 scripts/record_diy.py --serial /dev/fake-diy --port 8799 --out /tmp/diy
- this file as a script sends one frame per UDP datagram (the Wi-Fi route):
      python3 tests/fake_diy/fake_board.py --udp 127.0.0.1:9000 --seconds 60 [--channels 8] [--mode N]

The frames are encoded here, independently of scripts/diy_board.py (struct + binascii only), and a test checks them
against golden frames made by the firmware's own framing code (golden/e9_vectors.json).

Signals: mode T is the chip's internal test signal (a +-83886-count square wave at 0.9765625 Hz on every channel,
VREF/2400 at gain 24); mode N is shorted inputs (a few counts of noise). Faults, from environment variables:
  FAKE_DIY_CHANNELS (4), FAKE_DIY_MODE (T), FAKE_DIY_SEED
  FAKE_DIY_CORRUPT_EVERY n   every n-th frame has one byte flipped (fails its CRC)
  FAKE_DIY_LOSE_EVERY n      every n-th frame never reaches the laptop (a hole in the sequence, overruns unchanged)
  FAKE_DIY_OVERRUN_EVERY n   every n-th conversion is missed by the board itself (overruns + 1, flag 8 from then on)
  FAKE_DIY_GARBAGE_EVERY n   random bytes before every n-th frame (serial only)
  FAKE_DIY_DUPLICATE_EVERY n / FAKE_DIY_STALE_EVERY n   the n-th datagram is sent twice / an old one again (UDP only)
  FAKE_DIY_UNPLUG_AFTER s, FAKE_DIY_UNPLUG_FOR s   the USB cable is out for a while (reads fail, the port is gone)
  FAKE_DIY_REBOOT 1          the DevKit restarts at the replug: start-up text and prompts, then sequence 1 again
  FAKE_DIY_PROMPT_WAIT s     how long the (imagined) operator takes to answer those prompts in another terminal (2)
  FAKE_DIY_HALT_AFTER s      the firmware prints a HALTED line and stops sending
  FAKE_DIY_WRITES path       any byte the host writes to the board is recorded here (the host must never write)
Times count from when the board is first used. Bytes made while the port is closed are lost, except the text lines.
"""
import argparse, binascii, os, random, socket, struct, sys, time

HEADER = struct.Struct("<2sBBBBHIII")
FS = 250
SQUARE = 83886  # counts: VREF / 2400 at gain 24, for any VREF
TEST_HZ = 2.048e6 / 2 ** 21  # fCLK / 2^21 = 0.9765625 Hz
BANNER = "ADS1299 learning lab. BENCH ONLY; remove ALL body electrodes."
PROMPT_R = ("BREADBOARD: ADS control lines parked low. Switch on the AFE 5 V, measure AVDD at the chip legs "
            "(4.75-5.25 V) and 3V3; then type R.")
PROMPT_V = "BREADBOARD: chip awake. Measure VCAP1 (leg 28 to ground) above 1.1 V; then type V. This firmware does not sense voltages."
PROMPT_TN = ("BREADBOARD: type T for the internal test signal or N for shorted inputs (noise). "
             "There is no electrode mode.")
HALTED = "\nHALTED / BENCH ONLY; CAPTURE INVALID: No valid data for 2 s; inspect DRDY and clock."


def encode(codes, *, seq: int, time_us: int, overruns: int = 0, flags: int = 1, gain: int = 24, fs: int = FS,
           status: int = 0xC00000) -> bytes:
    """One E9 frame: little-endian header, the native ADS1299 frame (big-endian 24-bit words), CRC-16/CCITT-FALSE."""
    body = HEADER.pack(b"E9", 1, len(codes), flags, gain, fs, seq & 0xFFFFFFFF, time_us & 0xFFFFFFFF,
                       overruns & 0xFFFFFFFF)
    body += status.to_bytes(3, "big") + b"".join((int(c) & 0xFFFFFF).to_bytes(3, "big") for c in codes)
    return body + struct.pack("<H", binascii.crc_hqx(body, 0xFFFF))


def env(name: str, default: float = 0.0) -> float:
    return float(os.environ.get(f"FAKE_DIY_{name}", default))


class Board:
    """The board's state over time. advance() returns the bytes it sent since the last call, in order."""

    def __init__(self, channels: int | None = None, mode: str | None = None) -> None:
        self.channels = int(channels or env("CHANNELS", 4))
        self.mode = (mode or os.environ.get("FAKE_DIY_MODE", "T")).upper()
        self.rng = random.Random(int(env("SEED", 1)))
        self.t0 = time.monotonic()
        self.boot = self.t0 - 30.0  # powered 30 s ago; the operator answered its prompts in miniterm
        self.stream_t0 = self.t0 - 2.0  # streaming for 2 s already
        self.seq = int(2.0 * FS)  # DRDY edges so far
        self.overruns = 0
        self.halted = False
        self.unplug_at, self.unplug_for = env("UNPLUG_AFTER", -1), env("UNPLUG_FOR", 0)
        self.text: list[tuple[float, str]] = []  # (when, line) still to print

    def flags(self) -> int:
        return (1 if self.mode == "T" else 2) | (8 if self.overruns else 0)

    def unplugged(self, now: float | None = None) -> bool:
        t = (time.monotonic() if now is None else now) - self.t0
        return self.unplug_at >= 0 and self.unplug_at <= t < self.unplug_at + self.unplug_for

    def reboot(self, now: float) -> None:
        """The DevKit restarts (USB power came back): its start-up text, then streaming from sequence 1."""
        wait = env("PROMPT_WAIT", 2)
        self.boot = now; self.seq = 0; self.overruns = 0
        self.stream_t0 = now + wait + 0.6  # registers written and 500 ms of reference settling after T or N
        self.text = [(now + 0.5, BANNER), (now + 0.5, PROMPT_R), (now + wait / 2, PROMPT_V),
                     (now + wait / 2, f"ID=0x3{'c' if self.channels == 4 else 'e'}; {self.channels} physical "
                                      "channels; 250 SPS; gain 24"), (now + wait, PROMPT_TN)]

    def codes(self, seq: int) -> list[int]:
        if self.mode == "T":
            high = (seq / FS * TEST_HZ) % 1.0 < 0.5
            return [SQUARE if high else -SQUARE] * self.channels
        return [round(self.rng.gauss(0, 6)) for _ in range(self.channels)]

    def frames_due(self, now: float) -> list[tuple[int, bytes | None]]:
        """(sequence, frame bytes or None when lost on the way) for every conversion due by now."""
        if self.halted or now < self.stream_t0:
            return []
        out = []
        while self.seq < int((now - self.stream_t0) * FS):
            self.seq += 1
            every = lambda name: env(name) and self.seq % int(env(name)) == 0  # noqa: E731
            if every("OVERRUN_EVERY"):
                self.overruns += 1; continue  # the board missed this conversion; its sequence still moves on
            t_us = int((self.stream_t0 - self.boot + self.seq / FS) * 1e6)
            data = encode(self.codes(self.seq), seq=self.seq, time_us=t_us, overruns=self.overruns, flags=self.flags())
            if every("LOSE_EVERY"):
                out.append((self.seq, None)); continue
            if every("CORRUPT_EVERY"):
                b = bytearray(data); b[self.rng.randrange(2, len(b))] ^= 0x10; data = bytes(b)
            out.append((self.seq, data))
        return out

    def advance(self, now: float, port_open: bool = True) -> bytes:
        """What reaches the laptop since the last call: due text lines (kept while the port is closed, like the
        bridge's buffer) and frames (lost while it is closed)."""
        out = bytearray()
        halt = env("HALT_AFTER", -1)
        if not self.halted and halt >= 0 and now - self.t0 >= halt:
            self.halted = True; self.text.append((now, HALTED))
        if port_open:
            while self.text and self.text[0][0] <= now:
                out += (self.text.pop(0)[1] + "\r\n").encode()
        for _seq, data in self.frames_due(now):
            if data is None or not port_open:
                continue
            if env("GARBAGE_EVERY") and _seq % int(env("GARBAGE_EVERY")) == 0:
                out += self.rng.randbytes(self.rng.randrange(1, 40))
            out += data
        return bytes(out)


def send_udp(target: str, seconds: float, channels: int, mode: str) -> int:
    """The Wi-Fi route: one frame per datagram, as the firmware's udp.beginPacket / write / endPacket does."""
    host, port = target.rsplit(":", 1)
    board = Board(channels, mode); board.stream_t0 = board.t0; board.seq = 0
    sent: list[bytes] = []; n = 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for _seq, data in board.frames_due(time.monotonic()):
                if data is None:
                    continue
                n += 1
                sock.sendto(data, (host, int(port))); sent.append(data); del sent[:-100]
                if env("DUPLICATE_EVERY") and n % int(env("DUPLICATE_EVERY")) == 0:
                    sock.sendto(data, (host, int(port)))
                if env("STALE_EVERY") and n % int(env("STALE_EVERY")) == 0 and len(sent) > 5:
                    sock.sendto(sent[-5], (host, int(port)))
            time.sleep(0.004)
    print(f"sent {n} frames", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="fake DIY ADS1299 board: E9 frames over UDP")
    ap.add_argument("--udp", required=True, help="HOST:PORT to send to")
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--channels", type=int, default=4, choices=(4, 8))
    ap.add_argument("--mode", default="T", choices=("T", "N"))
    a = ap.parse_args()
    return send_udp(a.udp, a.seconds, a.channels, a.mode)


if __name__ == "__main__":
    sys.exit(main())
