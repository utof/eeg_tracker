"""The laptop host driver for the owner's DIY ADS1299 board: eeg_ads1299_lab's bench firmware
(firmware/esp32_ads1299_bench, the breadboard ESP32-S3 build) and its "E9" wire protocol (docs/PROTOCOL.md there).

One E9 frame per conversion (25 + 3 x channels bytes: 37, 43 or 49):
    0  "E9"   2 version 1   3 channels 4/6/8   4 flags   5 gain   6 samples/s (LE16)
    8  sequence (LE32, DRDY count since boot)   12 device microseconds at DRDY (LE32)   16 cumulative overruns (LE32)
    20 the chip's own 24-bit status word (big endian, high nibble 0xC)
    23 channel values, 24-bit signed big endian    last 2: CRC-16/CCITT-FALSE (LE) over everything before it
Flags: 1 internal test signal, 2 internal inputs shorted, 4 synthetic, 8 at least one overrun so far.
Volts = counts x VREF / (gain x 2^23) (ADS1299 datasheet SBAS499C eq. 8). VREF is not in the frame: --vref, 4.5 V
for the chip's internal reference, which the bench firmware uses.

Links, as the firmware has them: USB serial (460800 baud, a byte stream that also carries the firmware's text:
start-up banner, prompts, HALTED lines) or Wi-Fi UDP (one frame per datagram to the laptop's port 9000). The
firmware has no Bluetooth. This host only reads: it never writes to the serial port or sends a datagram. The
firmware's only inputs are the operator's answers R and V (voltages measured by hand) and T or N (test signal or
shorted inputs); a person types those in a serial terminal before recording, never this program.

Standard library only; pyserial is imported when a serial link opens (the UDP route does not need it).
"""
from __future__ import annotations

import binascii, glob, socket, struct
from dataclasses import dataclass

MAGIC = b"E9"
VERSION = 1
HEADER = struct.Struct("<2sBBBBHIII")  # 20 bytes before the native frame
CHANNELS = (4, 6, 8)
GAINS = (1, 2, 4, 6, 8, 12, 24)
RATES = (250, 500, 1000, 2000, 4000, 8000, 16000)
FLAG_TEST, FLAG_SHORT, FLAG_SYNTHETIC, FLAG_OVERRUN = 1, 2, 4, 8
MAX_SIZE = 49  # the 8-channel frame
MAX_TEXT = 400  # longest firmware text line kept
DEFAULT_VREF = 4.5
BAUD = 460800
UDP_PORT = 9000
U32 = 1 << 32
STALE_WINDOW = 64  # a frame at most this far behind the last is a late datagram; farther back, the board restarted
MODES = {FLAG_TEST: ("test", "test signal: the chip's own square wave, not EEG"),
         FLAG_SHORT: ("short", "shorted inputs: the chip's own noise, not EEG"),
         FLAG_SYNTHETIC: ("synthetic", "synthetic: made-up data, not EEG")}


def frame_size(channels: int) -> int:
    return 25 + 3 * channels


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE (poly 0x1021, start 0xFFFF, no reflection, no final XOR), as portable_core.h computes it."""
    return binascii.crc_hqx(data, 0xFFFF)


def volts_per_count(gain: int, vref: float = DEFAULT_VREF) -> float:
    return vref / (gain * (1 << 23))


def signed24(b: bytes) -> int:
    v = int.from_bytes(b, "big")
    return v - (1 << 24) if v & 0x800000 else v


class FrameError(ValueError):
    pass


@dataclass(frozen=True)
class Frame:
    channels: int
    flags: int
    gain: int
    fs: int
    seq: int
    time_us: int
    overruns: int
    status: int  # 1100 + LOFF_STATP[7:0] + LOFF_STATN[7:0] + GPIO[7:4] (SBAS499C, data output)
    counts: tuple[int, ...]

    @property
    def mode(self) -> str:
        """test, short, synthetic, or electrodes (no mode bit: never sent by the bench firmware)."""
        for bit, (name, _text) in MODES.items():
            if self.flags & bit:
                return name
        return "electrodes"

    @property
    def mode_text(self) -> str:
        for bit, (_name, text) in MODES.items():
            if self.flags & bit:
                return text
        return "electrode inputs (the bench firmware has no such mode; unreviewed)"

    @property
    def overrun_flag(self) -> bool:
        return bool(self.flags & FLAG_OVERRUN)

    @property
    def lead_off_p(self) -> int:
        """Bit k set: channel k+1's positive input reads as off. Meaningless while lead-off detection is off."""
        return (self.status >> 12) & 0xFF

    @property
    def lead_off_n(self) -> int:
        return (self.status >> 4) & 0xFF

    @property
    def gpio(self) -> int:
        return self.status & 0xF

    @property
    def config(self) -> tuple[int, int, int, int]:
        """What must stay the same within one capture: channels, gain, rate, mode bits."""
        return (self.channels, self.gain, self.fs, self.flags & 7)

    def volts(self, vref: float = DEFAULT_VREF) -> tuple[float, ...]:
        k = volts_per_count(self.gain, vref)
        return tuple(c * k for c in self.counts)


def decode_frame(data: bytes) -> Frame:
    """Exactly one frame -> Frame. Raises FrameError naming the first check that failed."""
    data = bytes(data)
    if len(data) < HEADER.size + 2:
        raise FrameError(f"{len(data)} bytes is too short for a frame")
    magic, version, n, flags, gain, fs, seq, t_us, overruns = HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        raise FrameError(f"not an E9 version 1 frame ({magic!r}, version {version})")
    if n not in CHANNELS:
        raise FrameError(f"channel count {n}")
    if len(data) != frame_size(n):
        raise FrameError(f"{len(data)} bytes for {n} channels (expected {frame_size(n)})")
    if crc16(data[:-2]) != int.from_bytes(data[-2:], "little"):
        raise FrameError("CRC mismatch")
    if gain not in GAINS or fs not in RATES or flags & ~15:
        raise FrameError(f"gain {gain}, rate {fs} or flags {flags:#x} out of range")
    status = int.from_bytes(data[20:23], "big")
    if status >> 20 != 0xC:
        raise FrameError(f"status word {status:06x} lacks the 0xC prefix")
    counts = tuple(signed24(data[23 + 3 * c:26 + 3 * c]) for c in range(n))
    return Frame(n, flags, gain, fs, seq, t_us, overruns, status, counts)


def printable(line: bytes) -> bool:
    return len(line) >= 8 and all(32 <= b < 127 or b == 9 for b in line)


class StreamDecoder:
    """Frames out of the serial byte stream. Bytes that are not part of a valid frame (a frame cut at the start,
    damaged frames, the firmware's text) are skipped and counted; printable text lines among them are kept for
    take_lines(). The buffer never holds more than one frame's worth."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.text = bytearray()
        self.lines: list[str] = []
        self.frames = self.bad_frames = self.discarded_bytes = 0

    def _skip(self, n: int) -> None:
        for b in self.buffer[:n]:
            if b == 10:
                line = bytes(self.text).strip(b"\r\t ")
                if printable(line):
                    self.lines.append(line.decode("ascii"))
                self.text.clear()
            elif len(self.text) < MAX_TEXT:
                self.text.append(b)
            else:
                self.text.clear()  # too long for a firmware line: binary
        del self.buffer[:n]; self.discarded_bytes += n

    def feed(self, chunk: bytes) -> list[Frame]:
        self.buffer += chunk
        out: list[Frame] = []
        while self.buffer:
            at = self.buffer.find(MAGIC)
            if at < 0:  # keep a last "E": it may start the next magic
                self._skip(len(self.buffer) - (1 if self.buffer.endswith(b"E") else 0))
                break
            if at:
                self._skip(at)
            if len(self.buffer) < 4:
                break
            if self.buffer[2] != VERSION or self.buffer[3] not in CHANNELS:
                self._skip(1); continue
            size = frame_size(self.buffer[3])
            if len(self.buffer) < size:
                break
            try:
                frame = decode_frame(bytes(self.buffer[:size]))
            except FrameError:
                self.bad_frames += 1; self._skip(1); continue
            del self.buffer[:size]; self.frames += 1; out.append(frame)
        return out

    def take_lines(self) -> list[str]:
        lines, self.lines = self.lines, []
        return lines


def text_kind(line: str) -> str:
    """halted (the firmware stopped and parked the chip), prompt (it waits for the operator), banner (it just
    started), or info."""
    if line.startswith("HALTED"):
        return "halted"
    if "type R" in line or "type V" in line or "type T" in line:
        return "prompt"
    if line.startswith("ADS1299 learning lab"):
        return "banner"
    return "info"


@dataclass(frozen=True)
class Step:
    kind: str  # first, next, duplicate, stale, restart, config
    lost: int = 0  # sequence numbers missing before this frame
    board_missed: int = 0  # of those, conversions the board itself skipped (its overrun counter)


class Tracker:
    """One capture of one board boot (PROTOCOL.md, host behaviour): forward sequence numbers are accepted and
    gaps counted, never filled; a repeat or a late frame is dropped, never sorted in; a jump far back, a clock
    going back, or a changed configuration (channels, gain, rate, mode) is a new capture: the tracker starts
    again from that frame and says so ("restart" / "config"), and the recorder starts a new file set."""

    def __init__(self) -> None:
        self.last: Frame | None = None
        self.accepted = self.lost = self.board_missed = self.duplicates = self.stale = self.timing_anomalies = 0

    def reset(self) -> None:
        self.last = None

    def observe(self, f: Frame) -> Step:
        last = self.last
        if last is None:
            return self._take(f, Step("first"))
        if f.config != last.config:
            return self._take(f, Step("config"))
        ds = (f.seq - last.seq) % U32
        dt = (f.time_us - last.time_us) % U32
        if ds == 0:
            self.duplicates += 1
            return Step("duplicate")
        if ds >= U32 // 2 or dt >= U32 // 2:
            if ds >= U32 // 2 and (last.seq - f.seq) % U32 <= STALE_WINDOW:
                self.stale += 1
                return Step("stale")
            return self._take(f, Step("restart"))
        lost = ds - 1
        missed = min(lost, (f.overruns - last.overruns) % U32)
        expected = ds * 1e6 / f.fs
        if abs(dt - expected) > max(500.0, 0.1 * expected):
            self.timing_anomalies += 1
        self.lost += lost; self.board_missed += missed
        return self._take(f, Step("next", lost, missed))

    def _take(self, f: Frame, step: Step) -> Step:
        self.last = f; self.accepted += 1
        return step


# ---- links ------------------------------------------------------------------------------------------------------
class BoardLost(Exception):
    """The link failed: the USB port vanished or a read failed. The caller closes it and tries again later."""


def find_serial_ports() -> list[str]:
    """USB-serial ports a DevKit can show up as on Linux: CP210x/CH340 bridges are ttyUSB*, CH343 ones ttyACM*."""
    return sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*"))


class SerialLink:
    """The DevKit's USB-UART socket. Opened like miniterm opens it (pyserial's defaults), which is how the lab's
    bring-up card tells whether opening the port restarts that DevKit; if it does, use the Wi-Fi route."""
    framing = "stream"

    def __init__(self, path: str, baud: int = BAUD) -> None:
        self.path, self.baud, self.port = path, baud, None

    def describe(self) -> str:
        return f"USB serial {self.path} at {self.baud} baud"

    def open(self) -> None:
        try:
            import serial  # pyserial; the recorder's launcher adds it
        except ImportError as e:
            raise RuntimeError("the serial route needs pyserial: use scripts/record_night.sh with DRIVER=diy, "
                               "or `uv run --no-project --with pyserial==3.5 ...`") from e
        self._errors = (serial.SerialException, OSError)
        try:
            self.port = serial.Serial(self.path, baudrate=self.baud, timeout=0.1)
        except self._errors as e:
            raise BoardLost(str(e)) from e

    def read(self) -> bytes:
        """What has arrived (waits up to 0.1 s for the first byte)."""
        try:
            return self.port.read(max(1, min(self.port.in_waiting, 65536)))
        except self._errors as e:
            raise BoardLost(str(e)) from e

    def close(self) -> None:
        if self.port is not None:
            try:
                self.port.close()
            except Exception:  # noqa: BLE001 (a vanished port may fail to close; it is gone either way)
                pass
            self.port = None


class UdpLink:
    """The Wi-Fi route: the firmware sends each frame as one datagram to UDP_HOST:UDP_PORT (board_config.h).
    Unauthenticated and unencrypted (PROTOCOL.md): a private network only."""
    framing = "datagram"

    def __init__(self, host: str = "0.0.0.0", port: int = UDP_PORT) -> None:
        self.host, self.port, self.sock = host, port, None
        self.senders: set[str] = set()

    def describe(self) -> str:
        return f"UDP {self.host}:{self.port} (Wi-Fi route)"

    def open(self) -> None:
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.bind((self.host, self.port)); self.sock.settimeout(0.1)
        except OSError as e:
            self.close()
            raise BoardLost(str(e)) from e

    def read(self) -> list[tuple[bytes, str]]:
        """Every datagram waiting (waits up to 0.1 s for the first): (bytes, sender address)."""
        out: list[tuple[bytes, str]] = []
        try:
            self.sock.settimeout(0.1)
            while len(out) < 1024:
                data, addr = self.sock.recvfrom(2048)
                out.append((data, addr[0])); self.sock.settimeout(0)
        except (TimeoutError, BlockingIOError):
            pass
        except OSError as e:
            raise BoardLost(str(e)) from e
        return out

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close(); self.sock = None


class Reader:
    """Frames and firmware text from a link: the stream decoder for serial, one frame per datagram for UDP."""

    def __init__(self, link: SerialLink | UdpLink) -> None:
        self.link = link
        self.decoder = StreamDecoder()
        self.bad_datagrams = 0
        self.new_senders: list[str] = []
        self._taken = (0, 0)

    def poll(self) -> tuple[list[Frame], list[str]]:
        if self.link.framing == "stream":
            frames = self.decoder.feed(self.link.read())
            return frames, self.decoder.take_lines()
        frames = []
        for data, sender in self.link.read():
            if sender not in self.link.senders:
                self.link.senders.add(sender); self.new_senders.append(sender)
            try:
                frames.append(decode_frame(data))
            except FrameError:
                self.bad_datagrams += 1
        return frames, []

    def take_counts(self) -> tuple[int, int]:
        """(bad frames or datagrams, bytes skipped) since the last call."""
        bad, skipped = self.decoder.bad_frames + self.bad_datagrams, self.decoder.discarded_bytes
        out = (bad - self._taken[0], skipped - self._taken[1]); self._taken = (bad, skipped)
        return out

    def take_senders(self) -> list[str]:
        """Addresses that sent their first datagram since the last call (UDP only)."""
        new, self.new_senders = self.new_senders, []
        return new
