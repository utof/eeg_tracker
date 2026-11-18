"""Our own Bluetooth LE driver for the BrainBit Black: no BrainBit SDK. Linux laptop first (Python + bleak).

What it does: finds the headband (a known address first; a name scan only when there is none), connects, reads
the device information and the status bytes (battery), starts the signal (command 3) or signal + contact together
(command 5, behind a flag until the probe confirms it), decodes every notification into samples
(packet number, O1, O2, T3, T4 in volts) and, after a drop, reconnects to the same address by itself with a
growing pause. Every failure reaches the caller as a plain HeadbandError, never as a crash.

Protocol sources (facts only, no code copied):
- Neiry's `web_sdk_neiry` 1.1.5 on npm (MIT per its package.json): the service family
  7e400001-b534-f393-68a9-e50e24dcca9?, characteristic n = the 8th hex digit (2 status, 3 command, 4 signal,
  5 listed), one-byte commands 1 power down, 2 idle (stop), 3 signal, 4 resistance, the status bytes
  (0 battery, 1 command error, 2 status) and the signal framing: 4 header bytes, then 13-byte blocks of one marker
  byte and four 3-byte channel values.
- NeuroSDK2's public C header (cmn_type.h): amplifier mode 5 = SignalResist.
- Our own NeuroSDK2 recordings of this headband (2026-11-18): batches of 8 samples, 250 Hz, a packet number that
  counts samples (it passed 2.6 million without wrapping), DC offsets of 0.03-0.14 V, the name "BB Black".
Every constant marked TO VERIFY rests on one unconfirmed source or on a guess; scripts/ble_probe.py checks them on
the owner's headband (docs/own-ble-driver.md).

Safety: nothing here calls BlueZ RemoveDevice or bleak's unpair(). It scans, connects to and disconnects from
this one headband and uses GATT reads, writes and notifications; it pairs only when asked (pair=True).
Standard library + bleak only (no numpy), like the SDK recorder.
"""
from __future__ import annotations

import asyncio
import math
import re
import struct
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError

NAMES = ("O1", "O2", "T3", "T4")  # order of every sample this module returns and of the .f32 records
FS = 250  # verified: NeuroSDK2 reports 250 Hz for this headband and delivered 250 samples/s

# ---- protocol constants -------------------------------------------------------------------------------------
SERVICE_RE = re.compile(r"^7e400001-b534-f393-68a9-e50e24dcca9[0-9a-f]$")  # TO VERIFY the last digit: 7 (npm,
# "BrainBitBlack") or 9 (one hobby script for the Black); found by pattern, so either works
STATUS_CHAR, COMMAND_CHAR, SIGNAL_CHAR, RESIST_CHAR = 2, 3, 4, 5  # 2-4: npm. 5 = resistance: TO VERIFY
CMD_POWER_DOWN, CMD_IDLE, CMD_SIGNAL, CMD_RESIST = 1, 2, 3, 4  # npm; never sends power down
CMD_SIGNAL_RESIST = 5  # TO VERIFY: NeuroSDK2's mode number for SignalResist; not yet sent to our headband
MODE_NAMES = {CMD_IDLE: "idle", CMD_SIGNAL: "signal", CMD_RESIST: "resistance", CMD_SIGNAL_RESIST: "signal+resistance"}
HEADER = 4  # signal: a uint32 counter first. TO VERIFY little-endian (hobby script)
BLOCK = 13  # one marker byte + 4 channels x 3 bytes (npm)
COUNTER_MOD = 1 << 32  # TO VERIFY that the counter is a full uint32 (seen above 2.6 million through the SDK)
VREF = 2.4  # volts
GAIN = 6  # TO VERIFY: gain 6 gives the vendor's +-0.4 V range; one hobby script assumed 12 (half the volts)
SIGNAL_ORDER = ("O2", "T3", "T4", "O1")  # wire order. TO VERIFY: the one Black script; a Headband script: T3 T4 O1 O2
RESIST_ORDER = ("O2", "T3", "T4", "O1")  # wire order of the resistance packet. TO VERIFY, as above
RESIST_HEADER = 4  # resistance: a uint32 counter, then four uint32 little-endian ohms. TO VERIFY (hobby scripts)
RESIST_OPEN = 0xFFFFFFFF  # TO VERIFY what an electrode without contact reads; taken as infinity
NAME_PREFIXES = ("BB Black", "BrainBit")  # "BB Black": verified (NeuroSDK2 scan of our headband)
DEVICE_INFO = {"model": "2a24", "serial": "2a25", "firmware": "2a26", "hardware": "2a27", "manufacturer": "2a29"}
STALL_S = 5.0  # no signal for this long: send the start command again; twice as long: reconnect
BACKOFF = (1.0, 2.0, 5.0, 10.0, 20.0, 30.0)  # pauses between reconnect attempts, the last one repeats
STATUS_EVERY_S = 60.0  # read the status (battery) this often while streaming
CONTACT_S = 6.0  # a contact check in resistance mode lasts this long (the SDK recorder used 6 s)
PAIRING_HINT = ("the headband may need pairing: hold its button 4 s until it blinks fast, then run with --pair "
                "(pairing never removes other devices)")

Sample = tuple[int, float, float, float, float]  # (packet number, O1, O2, T3, T4 in volts): one .f32 record


class HeadbandError(Exception):
    """Any failure talking to the headband. Callers catch this one type and reconnect."""


class HeadbandNotFound(HeadbandError):
    pass


class HeadbandLost(HeadbandError):
    pass


def uuid16(short: str) -> str:
    return f"0000{short}-0000-1000-8000-00805f9b34fb"


def char_uuid(service_uuid: str, n: int) -> str:
    """Characteristic n of a 7e4000xx service: the 8th hex digit of the first group is n (npm's changeUUID)."""
    return service_uuid[:7] + str(n) + service_uuid[8:]


@dataclass(frozen=True)
class Layout:
    """Where the four channels sit in a packet and how counts become volts. All TO VERIFY by the probe."""
    order: tuple[str, ...] = SIGNAL_ORDER
    resist_order: tuple[str, ...] = RESIST_ORDER
    gain: int = GAIN

    def __post_init__(self) -> None:
        for o in (self.order, self.resist_order):
            if sorted(o) != sorted(NAMES):
                raise ValueError(f"channel order must name {' '.join(NAMES)} once each, got {o}")
        if self.gain <= 0:
            raise ValueError("gain must be positive")

    @property
    def volts_per_count(self) -> float:
        return VREF / (self.gain * (1 << 23))

    def describe(self) -> str:
        return (f"wire order {' '.join(self.order)}, resistance order {' '.join(self.resist_order)}, gain {self.gain} "
                f"({self.volts_per_count * 1e6:.4f} uV per count); TO VERIFY by scripts/ble_probe.py")


DEFAULT_LAYOUT = Layout()


def parse_order(text: str) -> tuple[str, ...]:
    """'O2,T3,T4,O1' -> ('O2', 'T3', 'T4', 'O1'); Layout checks it names each channel once."""
    return tuple(x.strip().upper() for x in text.split(",") if x.strip())


@dataclass
class Packet:
    counter: int
    samples: list[Sample]
    markers: list[int]  # first byte of each block: the device's marker / status byte (meaning TO VERIFY)
    counts: list[tuple[int, int, int, int]]  # raw signed counts in wire order, for the probe


def decode_signal(data: bytes, layout: Layout = DEFAULT_LAYOUT) -> Packet:
    """One signal notification -> its samples. Raises ValueError on a length that is not 4 + 13 k bytes."""
    n, rest = divmod(len(data) - HEADER, BLOCK)
    if n < 1 or rest:
        raise ValueError(f"signal packet of {len(data)} bytes (expected 4 + 13 x samples)")
    counter = int.from_bytes(data[:HEADER], "little")
    where = [layout.order.index(name) for name in NAMES]
    scale = layout.volts_per_count
    samples: list[Sample] = []; markers: list[int] = []; counts: list[tuple[int, int, int, int]] = []
    for k in range(n):
        b = HEADER + BLOCK * k
        markers.append(data[b])
        c = tuple(int.from_bytes(data[b + 1 + 3 * j:b + 4 + 3 * j], "little", signed=True) for j in range(4))
        counts.append(c)  # type: ignore[arg-type]
        samples.append(((counter + k) % COUNTER_MOD, *(c[w] * scale for w in where)))  # type: ignore[arg-type]
    return Packet(counter, samples, markers, counts)


def decode_resist(data: bytes, layout: Layout = DEFAULT_LAYOUT) -> dict[str, float]:
    """One resistance notification -> ohms per electrode in NAMES order (inf = no contact)."""
    if len(data) < RESIST_HEADER + 16:
        raise ValueError(f"resistance packet of {len(data)} bytes (expected at least 20)")
    vals = struct.unpack_from("<4I", data, RESIST_HEADER)
    got = {name: (math.inf if v == RESIST_OPEN else float(v)) for name, v in zip(layout.resist_order, vals)}
    return {name: got[name] for name in NAMES}


@dataclass
class Status:
    battery: int  # percent (npm: byte 0). TO VERIFY against the SDK's reading
    cmd_error: int  # npm: byte 1, signed
    state: int  # npm: byte 2 "status", signed; meaning TO VERIFY
    raw: bytes

    def text(self) -> str:
        return f"battery {self.battery}% command error {self.cmd_error} state {self.state} raw {self.raw.hex()}"


def decode_status(data: bytes) -> Status:
    if len(data) < 3:
        raise ValueError(f"status of {len(data)} bytes (expected at least 3)")
    return Status(data[0], struct.unpack_from("b", data, 1)[0], struct.unpack_from("b", data, 2)[0], bytes(data))


def counter_gap(expected: int | None, counter: int) -> int:
    """Samples missing before a packet: 0 = continuous, > 0 = lost, < 0 = the counter went back (a restarted
    stream or a repeated packet). Modular, so the 32-bit wrap reads as continuous."""
    if expected is None:
        return 0
    d = (counter - expected) % COUNTER_MOD
    return d if d < COUNTER_MOD // 2 else d - COUNTER_MOD


MAC_RE = re.compile(r"\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b")


def known_address(folder: Path, newest: int = 60) -> str | None:
    """The headband's address from the newest recorder logs ('... connected <name> <address> serial ...')."""
    for f in sorted(Path(folder).glob("*.log"), reverse=True)[:newest]:  # names are time stamps
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines[:20]:  # the connection line is near the top
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[1] == "connected":
                m = MAC_RE.search(parts[2])
                if m:
                    return m.group(1).upper()
    return None


def is_brainbit(name: str | None) -> bool:
    return bool(name) and any(str(name).startswith(p) for p in NAME_PREFIXES)


@dataclass
class DeviceInfo:
    address: str
    name: str
    service: str
    rssi: int | None = None
    info: dict[str, str] = field(default_factory=dict)  # model, serial, firmware, hardware, manufacturer
    status: Status | None = None
    mtu: int | None = None


async def _wait(event: asyncio.Event, seconds: float) -> bool:
    """Wait up to `seconds` for `event`; True if it was set."""
    try:
        await asyncio.wait_for(event.wait(), seconds)
        return True
    except asyncio.TimeoutError:
        return event.is_set()


class BrainBitBLE:
    """One BrainBit Black over Bluetooth LE. Callbacks run in the event loop's thread:

    on_samples(packet, arrival unix time, gap)  every signal notification; gap = counter_gap (lost samples if > 0)
    on_resist(ohms by name, arrival time)        every resistance notification
    on_status(Status)                            every status read or notification
    on_raw(characteristic uuid, bytes, time)     every notification as received (the probe logs these)
    """

    def __init__(self, address: str | None = None, *, layout: Layout = DEFAULT_LAYOUT, pair: bool = False,
                 client_cls: type = BleakClient, scanner_cls: type = BleakScanner, timeout: float = 20.0,
                 scan_s: float = 30.0, stall_s: float = STALL_S, backoff: tuple[float, ...] = BACKOFF,
                 status_every_s: float = STATUS_EVERY_S, contact_s: float = CONTACT_S,
                 log: Callable[[str], None] = print) -> None:
        self.address = address.upper() if address else None
        self.layout, self.pair, self.timeout, self.scan_s = layout, pair, timeout, scan_s
        self.client_cls, self.scanner_cls = client_cls, scanner_cls
        self.stall_s, self.backoff, self.status_every_s, self.contact_s = stall_s, backoff, status_every_s, contact_s
        self.log = log
        self.on_samples: Callable[[Packet, float, int], None] | None = None
        self.on_resist: Callable[[dict[str, float], float], None] | None = None
        self.on_status: Callable[[Status], None] | None = None
        self.on_raw: Callable[[str, bytes, float], None] | None = None
        self.client = None
        self.service: str | None = None
        self.mode = CMD_IDLE
        self.name: str | None = None
        self.rssi: int | None = None
        self.last_signal = 0.0  # arrival time of the newest signal packet (or of the last start command)
        self.last_resist: dict[str, float] = {}
        self.status: Status | None = None
        self.packets = self.bad_packets = self.lost_samples = 0
        self._next: int | None = None  # the counter expected next
        self._lost: asyncio.Event | None = None
        self._lost_reason = ""
        self._closing = False
        self._write_response = True
        self._contact_wanted = False

    # ---- finding and connecting ----------------------------------------------------------------------------
    async def find(self) -> str:
        """The address to connect to: the known one, or the first BrainBit a name scan finds."""
        if self.address:
            return self.address
        seen: dict[str, object] = {}

        def match(dev, adv) -> bool:  # noqa: ANN001 (bleak's BLEDevice, AdvertisementData)
            name = getattr(adv, "local_name", None) or getattr(dev, "name", None)
            if is_brainbit(name):
                seen.update(name=name, rssi=getattr(adv, "rssi", None))
                return True
            return False
        self.log(f"no known address: scanning up to {self.scan_s:.0f} s for a BrainBit by name")
        try:
            dev = await self.scanner_cls.find_device_by_filter(match, timeout=self.scan_s)
        except (BleakError, OSError) as e:
            raise HeadbandNotFound(f"scan failed: {type(e).__name__}: {e}") from e
        if dev is None:
            raise HeadbandNotFound("no BrainBit found: is it switched on?")
        self.address = str(dev.address).upper()
        self.name = str(seen.get("name") or "")
        rssi = seen.get("rssi")
        self.rssi = rssi if isinstance(rssi, int) else None
        return self.address

    async def _ble(self, aw, what: str, seconds: float | None = None):  # noqa: ANN001, ANN202 (any bleak awaitable)
        """Await one bleak call with a timeout; any failure becomes a HeadbandLost naming `what`."""
        try:
            return await asyncio.wait_for(aw, seconds or self.timeout)
        except asyncio.CancelledError:
            raise
        except (BleakError, asyncio.TimeoutError, OSError, EOFError, ValueError, AttributeError, KeyError) as e:
            raise HeadbandLost(f"{what} failed: {type(e).__name__}: {e}") from e

    def _mark_lost(self, reason: str, session: asyncio.Event | None = None) -> None:
        """The link of `session` (default: the current one) broke. A late callback from an earlier connection
        names that connection's event, so it cannot mark a newer session as lost."""
        ev = self._lost if session is None else session
        if ev is self._lost and ev is not None and not self._closing and not ev.is_set():
            self._lost_reason = reason
            ev.set()

    async def connect(self) -> DeviceInfo:
        """Connect, find the 7e4000xx service, read device information and status, subscribe to notifications."""
        address = await self.find()
        self._closing = False
        session = self._lost = asyncio.Event()
        self._next = None
        client = self.client_cls(address, disconnected_callback=lambda _c: self._mark_lost("link dropped", session),
                                 timeout=self.timeout, pair=self.pair)
        await self._ble(client.connect(), "connect", self.timeout + 5)
        self.client = client
        try:
            return await self._setup(client, address)
        except HeadbandError:
            await self.close(idle=False)
            raise

    async def _setup(self, client, address: str) -> DeviceInfo:  # noqa: ANN001
        services = list(client.services)
        found = [s for s in services if SERVICE_RE.match(str(s.uuid).lower())]
        if not found:
            raise HeadbandError("no 7e4000xx BrainBit service on this device; services: "
                                + ", ".join(str(s.uuid) for s in services))
        self.service = str(found[0].uuid).lower()
        chars = {str(c.uuid).lower(): c for c in found[0].characteristics}
        cmd = chars.get(char_uuid(self.service, COMMAND_CHAR))
        if cmd is None:
            raise HeadbandError(f"service {self.service} has no command characteristic")
        self._write_response = "write" in cmd.properties
        info = DeviceInfo(address, self.name or str(getattr(client, "name", "") or ""), self.service, self.rssi)
        for key, short in DEVICE_INFO.items():
            try:
                raw = await self._ble(client.read_gatt_char(uuid16(short)), f"read {key}", 5)
                info.info[key] = bytes(raw).decode("utf-8", "replace").strip("\x00 ")
            except HeadbandLost:
                pass  # optional
        try:  # bleak's mtu_size is always 23 on BlueZ; a characteristic's write size is the MTU minus 3 (BlueZ >= 5.62)
            info.mtu = int(cmd.max_write_without_response_size) + 3
        except Exception:  # noqa: BLE001 (backends differ; the MTU is only reported: 108-byte packets need >= 111)
            info.mtu = None
        try:
            info.status = await self.read_status()
        except HeadbandLost as e:
            if not client.is_connected:
                raise
            self.log(f"status read failed ({e}); {PAIRING_HINT}")
        for n, handler in ((STATUS_CHAR, self._on_status_note), (SIGNAL_CHAR, self._on_signal),
                           (RESIST_CHAR, self._on_resist)):
            c = chars.get(char_uuid(self.service, n))
            if c is None or not {"notify", "indicate"} & set(c.properties):
                if n == SIGNAL_CHAR:
                    raise HeadbandError(f"service {self.service} has no signal characteristic to subscribe to")
                continue
            try:
                await self._ble(client.start_notify(c, handler), f"subscribe to {c.uuid}")
            except HeadbandLost as e:
                raise HeadbandLost(f"{e}; {PAIRING_HINT}") from e
        return info

    async def read_status(self) -> Status:
        raw = await self._ble(self.client.read_gatt_char(char_uuid(self.service, STATUS_CHAR)), "status read", 5)
        st = decode_status(bytes(raw))
        self._note_status(st)
        return st

    # ---- notifications -----------------------------------------------------------------------------------
    def _note_status(self, st: Status) -> None:
        self.status = st
        if self.on_status:
            try:
                self.on_status(st)
            except Exception as e:  # noqa: BLE001 (a caller's bug must not break the link)
                self.log(f"status callback failed: {type(e).__name__}: {e}")

    def _raw(self, n: int, data: bytes, now: float) -> None:
        if self.on_raw and self.service:
            try:
                self.on_raw(char_uuid(self.service, n), data, now)
            except Exception as e:  # noqa: BLE001
                self.log(f"raw callback failed: {type(e).__name__}: {e}")

    def _on_status_note(self, _char, data: bytearray) -> None:  # noqa: ANN001
        self._raw(STATUS_CHAR, bytes(data), time.time())
        try:
            self._note_status(decode_status(bytes(data)))
        except ValueError:
            pass

    def _on_signal(self, _char, data: bytearray) -> None:  # noqa: ANN001
        now = time.time()
        self._raw(SIGNAL_CHAR, bytes(data), now)
        try:
            pkt = decode_signal(bytes(data), self.layout)
        except ValueError:
            self.bad_packets += 1
            return
        self.last_signal = now; self.packets += 1
        gap = counter_gap(self._next, pkt.counter)
        if gap > 0:
            self.lost_samples += gap
        self._next = (pkt.counter + len(pkt.samples)) % COUNTER_MOD
        if self.on_samples:
            try:
                self.on_samples(pkt, now, gap)
            except Exception as e:  # noqa: BLE001
                self.log(f"samples callback failed: {type(e).__name__}: {e}")

    def _on_resist(self, _char, data: bytearray) -> None:  # noqa: ANN001
        now = time.time()
        self._raw(RESIST_CHAR, bytes(data), now)
        try:
            ohms = decode_resist(bytes(data), self.layout)
        except ValueError:
            return
        self.last_resist = ohms
        if self.on_resist:
            try:
                self.on_resist(ohms, now)
            except Exception as e:  # noqa: BLE001
                self.log(f"resistance callback failed: {type(e).__name__}: {e}")

    # ---- commands ----------------------------------------------------------------------------------------
    async def command(self, cmd: int) -> None:
        """Write one command byte (2 idle, 3 signal, 4 resistance, 5 signal+resistance)."""
        if cmd == CMD_POWER_DOWN:
            raise ValueError("power down is never sent: it would switch the headband's amplifier off")
        if self.client is None or self.service is None:
            raise HeadbandLost("not connected")
        await self._ble(self.client.write_gatt_char(char_uuid(self.service, COMMAND_CHAR), bytes([cmd]),
                                                    response=self._write_response), f"command {cmd}")
        self.mode = cmd
        if cmd in (CMD_SIGNAL, CMD_SIGNAL_RESIST):
            self._next = None; self.last_signal = time.time()  # the stall timer starts now

    def check_contact(self) -> None:
        """Ask for a contact check; the streaming loop runs it between packets (call from the loop's thread)."""
        self._contact_wanted = True

    async def measure_contact(self) -> dict[str, float]:
        """Resistance mode for contact_s seconds, then idle. Returns the last ohms per electrode ({} if none)."""
        self.last_resist = {}
        await self.command(CMD_IDLE)
        await self.command(CMD_RESIST)
        lost = await _wait(self._lost, self.contact_s) if self._lost else False
        if lost:
            raise HeadbandLost(self._lost_reason)
        await self.command(CMD_IDLE)
        return dict(self.last_resist)

    # ---- one session and the reconnecting loop --------------------------------------------------------------
    async def stream_until_lost(self, mode: int, stopping: asyncio.Event,
                                on_contact: Callable[[dict[str, float]], None] | None = None) -> int:
        """Stream in `mode` until `stopping` is set (returns the mode in use) or the headband is lost (raises
        HeadbandLost). A stall first gets the start command again, then counts as lost. Command 5 that brings no
        signal falls back to command 3 (returned, so the caller keeps it)."""
        await self.command(mode)
        started = time.time(); got_any = False; resent = False; next_status = time.time() + self.status_every_s
        while not stopping.is_set():
            if await _wait(self._lost, 0.25):
                raise HeadbandLost(self._lost_reason or "link dropped")
            now = time.time()
            got_any = got_any or self.last_signal > started
            if self._contact_wanted:
                self._contact_wanted = False
                if mode == CMD_SIGNAL_RESIST:
                    ohms = dict(self.last_resist)
                else:
                    ohms = await self.measure_contact()
                    await self.command(mode)
                if on_contact:
                    on_contact(ohms)
                resent = False; continue
            quiet = now - self.last_signal
            if mode == CMD_SIGNAL_RESIST and not got_any and quiet > self.stall_s:
                self.log(f"signal+resistance (command 5) gave no signal in {quiet:.0f} s; "
                         "falling back to signal only (command 3)")
                mode = CMD_SIGNAL; await self.command(CMD_IDLE); await self.command(mode); continue
            if quiet > 2 * self.stall_s:
                raise HeadbandLost(f"no signal for {quiet:.0f} s")
            if quiet > self.stall_s and not resent:
                self.log(f"no signal for {quiet:.0f} s: sending the start command again")
                await self.command(mode); self.last_signal = now - quiet; resent = True
            elif quiet < 1:
                resent = False
            if now >= next_status:
                next_status = now + self.status_every_s
                try:
                    await self.read_status()
                except HeadbandLost as e:
                    self.log(f"status read failed: {e}")
        return mode

    async def run(self, mode: int, stopping: asyncio.Event, *,
                  on_connected: Callable[[DeviceInfo, int], object] | None = None,
                  on_lost: Callable[[HeadbandError, int, float], None] | None = None,
                  on_contact: Callable[[dict[str, float]], None] | None = None) -> None:
        """Connect, stream and reconnect to the same address after every failure, until `stopping` is set.
        on_connected(info, attempt) may be a coroutine; on_lost(error, attempt, pause before the next try)."""
        attempt = 0
        while not stopping.is_set():
            try:
                info = await self.connect()
                if on_connected:
                    r = on_connected(info, attempt)
                    if asyncio.iscoroutine(r):
                        await r
                attempt = 0
                mode = await self.stream_until_lost(mode, stopping, on_contact)
            except HeadbandError as e:
                pause = self.backoff[min(attempt, len(self.backoff) - 1)]
                if on_lost:
                    on_lost(e, attempt, pause)
                attempt += 1
                await self.close(idle=False)
                await _wait(stopping, pause)
                continue
            await self.close(idle=True)

    async def close(self, idle: bool = True) -> None:
        """Stop streaming (idle) when asked and the link is up, then disconnect this headband only."""
        client, self.client = self.client, None
        self._closing = True
        if client is None:
            return
        try:
            if idle and client.is_connected and self.service:
                await asyncio.wait_for(client.write_gatt_char(char_uuid(self.service, COMMAND_CHAR),
                                                              bytes([CMD_IDLE]), response=self._write_response), 3)
        except (BleakError, asyncio.TimeoutError, OSError, EOFError):
            pass
        try:
            await asyncio.wait_for(client.disconnect(), 5)
        except (BleakError, asyncio.TimeoutError, OSError, EOFError):
            pass
        self.mode = CMD_IDLE
