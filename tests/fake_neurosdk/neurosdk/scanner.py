import math, os, random, threading, time
from dataclasses import dataclass

from .cmn_types import SensorCommand, SensorState

FS = 250


@dataclass
class SensorInfo:
    Name: str = "BB Black (fake)"
    Address: str = "00:00:00:00:00:00"
    SerialNumber: str = "fake"
    RSSI: int = -60


@dataclass
class Sample:
    PackNum: int
    O1: float
    O2: float
    T3: float
    T4: float


@dataclass
class Resist:
    O1: float
    O2: float
    T3: float
    T4: float


def fake_sample(n: int, rng: random.Random) -> Sample:
    t = n / FS
    closed = int(t // 60) % 2 == 0
    alpha = (25e-6 if closed else 6e-6) * math.sin(2 * math.pi * 10 * t)
    jaw = 40e-6 * rng.gauss(0, 1) if (t % 45) < 3 else 0.0
    blink = 80e-6 * math.exp(-(((t % 7) - 0.15) / 0.08) ** 2)
    noise = lambda: 4e-6 * rng.gauss(0, 1)  # noqa: E731
    return Sample(n % 65536, alpha + blink + noise(), 0.9 * alpha + blink + noise(),
                  jaw + 0.3 * blink + noise(), jaw + 0.3 * blink + noise())


class Sensor:
    def __init__(self, info: SensorInfo) -> None:
        self.info = info; self.state = SensorState.StateInRange; self.batt_power = 87
        self.signalDataReceived = None; self.resistDataReceived = None
        self._run = threading.Event(); self._resist = threading.Event(); self._n = 0
        self._rng = random.Random(os.environ.get("FAKE_BRAINBIT_SEED"))
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:
        nxt = time.time()
        while True:
            nxt += 0.1; time.sleep(max(0.0, nxt - time.time()))
            if self._run.is_set() and self.signalDataReceived:
                batch = [fake_sample(self._n + k, self._rng) for k in range(25)]; self._n += 25
                self.signalDataReceived(self, batch)
            if self._resist.is_set() and self.resistDataReceived:
                self.resistDataReceived(self, Resist(180e3, 150e3, 220e3, 400e3))

    def exec_command(self, cmd: SensorCommand) -> None:
        {SensorCommand.StartSignal: self._run.set, SensorCommand.StopSignal: self._run.clear,
         SensorCommand.StartResist: self._resist.set, SensorCommand.StopResist: self._resist.clear}[cmd]()

    def connect(self) -> None: self.state = SensorState.StateInRange

    def disconnect(self) -> None: self._run.clear()


class Scanner:
    def __init__(self, families) -> None: self._found = []

    def start(self) -> None: self._found = [SensorInfo()]

    def stop(self) -> None: pass

    def sensors(self): return self._found

    def create_sensor(self, info: SensorInfo) -> Sensor: return Sensor(info)
