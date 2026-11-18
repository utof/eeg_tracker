"""A fake bleak (the names our driver uses from bleak 3.1) that plays a BrainBit Black, so the own-driver recorder,
the probe and the tests run without a headband.

usage: PYTHONPATH=tests/fake_bleak python3 scripts/record_ble.py --seconds 30 --port 8799 --out /tmp/rec

The fake headband speaks the protocol exactly as our notes describe it (docs/own-ble-driver.md), written here
independently of scripts/brainbit_ble.py so the tests check the driver's decoding against a second reading of the
notes: service 7e400001-...-dcca97 with characteristics 7e400002 (status: battery, command error, mode),
7e400003 (command), 7e400004 (signal: uint32 sample counter + 8 blocks of a marker byte and four signed 24-bit
little-endian counts in the wire order O2 T3 T4 O1, gain 6) and 7e400005 (resistance: uint32 counter + four uint32
ohms, same order). Commands: 2 idle, 3 signal, 4 resistance, 5 both. The signal is the fake SDK's
(tests/fake_neurosdk: alpha that switches every minute, jaw bursts, blinks), so both fakes give the same samples.

One FakeHeadband (module-level HEADBAND) is shared by every client, so a reconnect finds the same headband.
Environment: FAKE_BRAINBIT_SEED (noise), FAKE_BLE_DROP_AFTER (seconds of streaming before the link drops),
FAKE_BLE_DROP_FOR (seconds it stays away), FAKE_BLE_MAX_DROPS, FAKE_BLE_LOSE_EVERY (lose every Nth packet),
FAKE_BLE_COUNTER0 (first counter value, to test the wrap), FAKE_BLE_SUFFIX (last UUID digit, 7 or 9).
Pure Python and standard library only.
"""
import asyncio
import os
import random
import struct
import sys
import time
from pathlib import Path

from .exc import BleakError

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "fake_neurosdk"))
from neurosdk.scanner import fake_sample  # noqa: E402 (the fake SDK's signal: same samples in both fakes)

__all__ = ["BleakClient", "BleakScanner", "BleakError", "FakeHeadband", "HEADBAND", "reset"]

FS = 250
ORDER = ("O2", "T3", "T4", "O1")  # wire order the fake sends
VPC = 2.4 / (6 * (1 << 23))  # volts per count at gain 6


def _env(name: str, default: float | None) -> float | None:
    v = os.environ.get(name)
    return float(v) if v not in (None, "") else default


def _uuid(n: int, suffix: str) -> str:
    return f"7e40000{n}-b534-f393-68a9-e50e24dcca9{suffix}"


def encode_signal(counter: int, rows: list[dict[str, float]], marker: int = 0) -> bytes:
    out = bytearray(struct.pack("<I", counter % (1 << 32)))
    for r in rows:
        out.append(marker)
        for name in ORDER:
            c = max(-(1 << 23), min((1 << 23) - 1, round(r[name] / VPC)))
            out += (c & 0xFFFFFF).to_bytes(3, "little")
    return bytes(out)


def encode_resist(counter: int, ohms: dict[str, int]) -> bytes:
    return struct.pack("<I4I", counter % (1 << 32), *(ohms[n] for n in ORDER))


class BLEDevice:
    def __init__(self, address: str, name: str) -> None:
        self.address, self.name, self.details = address, name, {}


class AdvertisementData:
    def __init__(self, local_name: str, rssi: int) -> None:
        self.local_name, self.rssi = local_name, rssi


class Characteristic:
    def __init__(self, uuid: str, properties: list[str]) -> None:
        self.uuid, self.properties, self.descriptors, self.handle = uuid, properties, [], 0
        self.max_write_without_response_size = 514  # MTU 517 - 3, as BlueZ asks for by default


class Service:
    def __init__(self, uuid: str, characteristics: list[Characteristic], description: str = "") -> None:
        self.uuid, self.characteristics, self.description, self.handle = uuid, characteristics, description, 0


class FakeHeadband:
    def __init__(self, *, address: str = "C0:FF:EE:00:00:01", name: str = "BB Black", suffix: str | None = None,
                 interval: float = 8 / FS, drop_after: float | None = None, drop_for: float | None = None,
                 max_drops: int | None = None, lose_every: int | None = None, counter0: int | None = None,
                 battery: int = 87, resist: tuple[int, ...] = (150_000, 220_000, 400_000, 180_000),
                 ignore_cmd5: bool = False, stall_after: float | None = None) -> None:
        self.address, self.name, self.interval = address, name, interval
        self.suffix = suffix or os.environ.get("FAKE_BLE_SUFFIX") or "7"
        self.drop_after = drop_after if drop_after is not None else _env("FAKE_BLE_DROP_AFTER", None)
        self.drop_for = drop_for if drop_for is not None else _env("FAKE_BLE_DROP_FOR", 3.0)
        md = max_drops if max_drops is not None else _env("FAKE_BLE_MAX_DROPS", None)
        self.max_drops = int(md) if md is not None else None
        le = lose_every if lose_every is not None else _env("FAKE_BLE_LOSE_EVERY", None)
        self.lose_every = int(le) if le else 0
        c0 = counter0 if counter0 is not None else _env("FAKE_BLE_COUNTER0", 0)
        self.counter0 = int(c0 or 0)
        self.battery, self.resist_ohms, self.ignore_cmd5, self.stall_after = battery, resist, ignore_cmd5, stall_after
        self.rng = random.Random(os.environ.get("FAKE_BRAINBIT_SEED"))
        self.mode = 2; self.cmd_error = 0
        self.client = None  # the connected client
        self.away_until = 0.0
        self.n = 0  # signal sample index (fake_sample)
        self.counter = self.counter0
        self.packets = 0
        self.drops = 0
        self.scans = 0; self.connects = 0; self.connect_times: list[float] = []
        self.commands: list[int] = []
        self.paired = False
        self.task: asyncio.Task | None = None

    # GATT layout
    def services(self) -> list[Service]:
        s = self.suffix
        info = Service("0000180a-0000-1000-8000-00805f9b34fb", [
            Characteristic(f"00002a{x}-0000-1000-8000-00805f9b34fb", ["read"]) for x in ("24", "25", "26", "27", "29")])
        main = Service(_uuid(1, s), [
            Characteristic(_uuid(2, s), ["read", "notify"]), Characteristic(_uuid(3, s), ["write"]),
            Characteristic(_uuid(4, s), ["notify"]), Characteristic(_uuid(5, s), ["notify"])])
        return [info, main]

    def read(self, uuid: str) -> bytes:
        dev = {"2a24": "BrainBit Black (fake)", "2a25": "fake-serial", "2a26": "1.10.0", "2a27": "1.0.0", "2a29": "fake"}
        if uuid.startswith("00002a"):
            return dev[uuid[4:8]].encode()
        if uuid == _uuid(2, self.suffix):
            return bytes([self.battery, self.cmd_error & 0xFF, self.mode, 0])
        raise BleakError(f"read not permitted on {uuid}")

    def command(self, cmd: int) -> None:
        self.commands.append(cmd)
        if cmd == 5 and self.ignore_cmd5:
            self.cmd_error = 2; return  # "mode error": the fake does not know command 5
        self.cmd_error = 0
        if cmd in (3, 5) and self.mode not in (3, 5):
            self.counter = self.counter0  # the counter restarts with each new stream (seen through the SDK)
        self.mode = cmd

    def drop(self) -> None:
        """The headband goes out of range: the link breaks and it does not answer for drop_for seconds."""
        self.drops += 1; self.away_until = time.time() + (self.drop_for or 0)
        client = self.client
        if client is not None:
            client._lost()

    async def run(self, client: "BleakClient") -> None:
        """Notifications while connected: signal packets every `interval`, resistance 10 times a second."""
        nxt = time.time(); since = time.time(); next_resist = 0.0
        while self.client is client:
            nxt += self.interval
            await asyncio.sleep(max(0.0, nxt - time.time()))
            if self.client is not client:
                break
            now = time.time()
            if self.mode in (3, 5) and not (self.stall_after is not None and now - since > self.stall_after):
                rows = []
                for _ in range(8):
                    x = fake_sample(self.n, self.rng); self.n += 1
                    rows.append(dict(O1=x.O1, O2=x.O2, T3=x.T3, T4=x.T4))
                self.packets += 1
                pkt = encode_signal(self.counter, rows); self.counter = (self.counter + 8) % (1 << 32)
                if not (self.lose_every and self.packets % self.lose_every == 0):
                    client._notify(_uuid(4, self.suffix), pkt)
            if self.mode in (4, 5) and now >= next_resist:
                next_resist = now + 0.1
                client._notify(_uuid(5, self.suffix), encode_resist(self.packets, dict(zip(("O1", "O2", "T3", "T4"),
                                                                                            self.resist_ohms))))
            if (self.drop_after is not None and now - since > self.drop_after
                    and (self.max_drops is None or self.drops < self.max_drops)):
                self.drop(); break


HEADBAND = FakeHeadband()


def reset(**kw) -> FakeHeadband:
    """A fresh fake headband for a test (keyword arguments as FakeHeadband)."""
    global HEADBAND
    HEADBAND = FakeHeadband(**kw)
    return HEADBAND


class BleakScanner:
    @classmethod
    async def find_device_by_filter(cls, filterfunc, timeout: float = 10.0, **_kw):  # noqa: ANN001
        hb = HEADBAND; hb.scans += 1
        await asyncio.sleep(0.01)
        if hb.client is None and time.time() >= hb.away_until:
            dev, adv = BLEDevice(hb.address, hb.name), AdvertisementData(hb.name, -61)
            if filterfunc(dev, adv):
                return dev
        await asyncio.sleep(min(timeout, 0.05))
        return None

    @classmethod
    async def find_device_by_address(cls, address: str, timeout: float = 10.0, **kw):
        return await cls.find_device_by_filter(lambda d, _a: d.address.lower() == address.lower(), timeout, **kw)

    @classmethod
    async def discover(cls, timeout: float = 5.0, return_adv: bool = False, **_kw):
        hb = HEADBAND; hb.scans += 1
        await asyncio.sleep(min(timeout, 0.05))
        if hb.client is not None or time.time() < hb.away_until:
            return {} if return_adv else []
        dev = BLEDevice(hb.address, hb.name)
        return {hb.address: (dev, AdvertisementData(hb.name, -61))} if return_adv else [dev]


class BleakClient:
    def __init__(self, address_or_ble_device, disconnected_callback=None, services=None, *,  # noqa: ANN001
                 timeout: float = 30, pair: bool = False, **_kw) -> None:
        a = address_or_ble_device
        self.address = a if isinstance(a, str) else a.address
        self._cb = disconnected_callback; self._pair = pair
        self._connected = False; self._subs: dict[str, object] = {}; self._chars: dict[str, Characteristic] = {}

    @property
    def name(self) -> str:
        return HEADBAND.name

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def mtu_size(self) -> int:
        return 517

    @property
    def services(self) -> list[Service]:
        if not self._connected:
            raise BleakError("Service Discovery has not been performed yet")
        return HEADBAND.services()

    async def connect(self, **_kw) -> None:
        hb = HEADBAND
        await asyncio.sleep(0.01)
        if self.address.upper() != hb.address.upper() or time.time() < hb.away_until:
            raise BleakError(f"Device with address {self.address} was not found.")
        if hb.client is not None:
            raise BleakError("the headband keeps one connection")
        if self._pair:
            hb.paired = True
        hb.connects += 1; hb.connect_times.append(time.time())
        hb.client = self; self._connected = True
        self._chars = {c.uuid: c for s in hb.services() for c in s.characteristics}
        hb.task = asyncio.get_running_loop().create_task(hb.run(self))

    async def disconnect(self) -> None:
        if self._connected:
            self._connected = False
            if HEADBAND.client is self:
                HEADBAND.client = None; HEADBAND.mode = 2
            if self._cb:
                self._cb(self)

    def _lost(self) -> None:
        """Called by the fake headband when the link breaks."""
        if self._connected:
            self._connected = False
            HEADBAND.client = None; HEADBAND.mode = 2
            if self._cb:
                asyncio.get_running_loop().call_soon(self._cb, self)

    def _uuid(self, c) -> str:  # noqa: ANN001
        return str(getattr(c, "uuid", c)).lower()

    async def read_gatt_char(self, c) -> bytearray:  # noqa: ANN001
        if not self._connected:
            raise BleakError("Not connected")
        await asyncio.sleep(0)
        return bytearray(HEADBAND.read(self._uuid(c)))

    async def write_gatt_char(self, c, data, response: bool | None = None) -> None:  # noqa: ANN001
        if not self._connected:
            raise BleakError("Not connected")
        await asyncio.sleep(0)
        if self._uuid(c) != _uuid(3, HEADBAND.suffix):
            raise BleakError(f"write not permitted on {self._uuid(c)}")
        HEADBAND.command(bytes(data)[0])

    async def start_notify(self, c, callback, **_kw) -> None:  # noqa: ANN001
        if not self._connected:
            raise BleakError("Not connected")
        self._subs[self._uuid(c)] = callback

    async def stop_notify(self, c) -> None:  # noqa: ANN001
        self._subs.pop(self._uuid(c), None)

    def _notify(self, uuid: str, data: bytes) -> None:
        cb = self._subs.get(uuid)
        if cb and self._connected:
            cb(self._chars.get(uuid, Characteristic(uuid, [])), bytearray(data))

    async def pair(self, *_a, **_kw) -> None:
        HEADBAND.paired = True

    async def unpair(self) -> None:
        raise AssertionError("the driver must never unpair or remove a Bluetooth device (DECISIONS 84)")
