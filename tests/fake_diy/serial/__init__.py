"""A fake pyserial for tests: every port is the fake DIY board in tests/fake_diy/fake_board.py (one board per
process, so a reopened port finds the same board, as after a real USB drop). Only what scripts/diy_board.py uses."""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fake_board  # noqa: E402

__version__ = "fake"
BOARD: "fake_board.Board | None" = None
_state = dict(rebooted=False)


class SerialException(OSError):
    pass


def _board() -> "fake_board.Board":
    global BOARD
    if BOARD is None:
        BOARD = fake_board.Board()
    return BOARD


def _plugged(now: float) -> bool:
    """False while the cable is out; the first moment back, a FAKE_DIY_REBOOT board starts again."""
    b = _board()
    if b.unplugged(now):
        b.advance(now, port_open=False)  # the board's conversions go on (or it is off): nothing reaches us
        return False
    if b.unplug_at >= 0 and now - b.t0 >= b.unplug_at and not _state["rebooted"]:
        _state["rebooted"] = True
        if fake_board.env("REBOOT"):
            b.reboot(b.t0 + b.unplug_at + b.unplug_for)
    return True


class Serial:
    def __init__(self, port: str | None = None, baudrate: int = 9600, timeout: float | None = None, **_kw) -> None:
        self.port, self.baudrate, self.timeout = port, baudrate, timeout
        self.is_open = False; self._buf = bytearray()
        now = time.monotonic()
        if not _plugged(now):
            raise SerialException(f"[Errno 2] could not open port {port}: No such file or directory")
        b = _board(); b.advance(now, port_open=False)  # what the board sent before we opened is gone (not its text)
        self._buf += b.advance(now)
        self._cut = True  # we open in the middle of a frame
        self.is_open = True

    def _pull(self) -> None:
        now = time.monotonic()
        if not _plugged(now):
            self.is_open = False
            raise SerialException("device reports readiness to read but returned no data "
                                  "(device disconnected or multiple access on port?)")
        got = _board().advance(now)
        if self._cut and got:
            if got.startswith(b"E9"):  # opened mid-stream: the first frame arrives cut (text is never cut)
                got = got[_board().rng.randrange(1, 30):]
            self._cut = False
        self._buf += got

    @property
    def in_waiting(self) -> int:
        self._pull()
        return len(self._buf)

    def read(self, size: int = 1) -> bytes:
        end = time.monotonic() + (self.timeout or 0)
        while True:
            self._pull()
            if self._buf:
                out = bytes(self._buf[:size]); del self._buf[:size]
                return out
            if time.monotonic() >= end:
                return b""
            time.sleep(0.004)

    def write(self, data: bytes) -> int:
        """The host must never write to the board; any attempt is recorded for the tests."""
        path = os.environ.get("FAKE_DIY_WRITES")
        if path:
            with open(path, "ab") as f:
                f.write(bytes(data))
        return len(data)

    def close(self) -> None:
        self.is_open = False

    def __enter__(self) -> "Serial":
        return self

    def __exit__(self, *_a) -> None:
        self.close()
