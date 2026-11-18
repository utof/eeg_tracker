"""Record the BrainBit with our own Bluetooth driver (scripts/brainbit_ble.py, no BrainBit SDK) until Ctrl+C.

Same files and routes as record_night.py (both use scripts/recorder_hub.py; docs/data-format.md), but one process
all night: a Bluetooth drop is handled in-process (reconnect to the same address with growing pauses; the gap
shows in the .idx arrival times, so to_bdf.py marks it BAD_gap), the page server stays up, and a contact re-check
(POST /contact) runs resistance mode for 6 s and goes back to the signal without a restart. With --signal-resist
(command 5, TO VERIFY with scripts/ble_probe.py) the contact is measured all the time instead. Lost packets inside a
connection (jumps of the headband's packet counter) are counted in the .log.

usage: DRIVER=ble scripts/record_night.sh            (the launcher pins bleak)
       uv run --no-project --python 3.12 --with bleak==3.1.0 python scripts/record_ble.py [--address AA:BB:...]
No headband: PYTHONPATH=tests/fake_bleak python3 scripts/record_ble.py --port 8799 --out /tmp/rec
The address comes from --address, else BRAINBIT_ADDRESS, else the newest recorder .log in --out; only without one
does it scan by name. Standard library + bleak only (no numpy).
"""
import argparse, asyncio, os, signal, sys, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find the modules beside this file even under `python3 -I`
import brainbit_ble as bb  # noqa: E402
from recorder_hub import Hub  # noqa: E402

CONTACT_LOG_EVERY_S = 60  # with --signal-resist, a "contact ohms" line this often


def ohms_text(ohms: dict[str, float]) -> str:
    return " ".join(f"{k}={v:.0f}" for k, v in ohms.items())


def bleak_version() -> str:
    try:
        from importlib.metadata import version
        return version("bleak")
    except Exception:  # the fake bleak in tests/ has no package metadata
        return "unknown (fake?)"


class Recording:
    """Glue between the driver's callbacks and the hub; every callback runs in the event loop's thread."""

    def __init__(self, hub: Hub, drv: bb.BrainBitBLE, mode: int, port: int, seconds: float) -> None:
        self.hub, self.drv, self.mode, self.port, self.seconds = hub, drv, mode, port, seconds
        self.started: float | None = None  # when the first stream began (--seconds counts from here)
        self.lost_at: float | None = None
        self.gaps = self.gap_samples = 0
        self.last_contact_log = 0.0
        drv.on_samples, drv.on_resist, drv.on_status = self.on_samples, self.on_resist, self.on_status

    def on_samples(self, pkt: bb.Packet, now: float, gap: int) -> None:
        if gap > 0:
            self.gaps += 1; self.gap_samples += gap
        self.hub.add_batch(pkt.samples, now)

    def on_resist(self, ohms: dict[str, float], now: float) -> None:
        if self.drv.mode == bb.CMD_SIGNAL_RESIST:
            self.hub.set_contact(ohms, now)  # live contact: pages see it change at once
        else:
            self.hub.contact.update(ohms)  # a check in progress; contact_t moves when it ends (on_contact)

    def on_status(self, st: bb.Status) -> None:
        self.hub.live["battery"] = st.battery

    def on_contact(self, ohms: dict[str, float]) -> None:
        self.hub.set_contact(ohms)
        self.hub.log("contact ohms " + ohms_text(ohms) if ohms else "contact check: no resistance data")
        self.hub.live["status"] = "recording"

    async def on_connected(self, info: bb.DeviceInfo, attempt: int) -> None:
        hub, now = self.hub, time.time()
        battery = info.status.battery if info.status else "?"
        if hub.stamp is None:  # first connection: files now, so runs while the headband is off leave none
            hub.open_files()
            hub.log(f"connected {info.name or 'BrainBit'} {info.address} serial {info.info.get('serial', '?')} "
                    f"battery {battery}% signal {info.rssi if info.rssi is not None else '?'} dBm")
            hub.log(f"driver own Bluetooth LE (scripts/brainbit_ble.py, bleak {bleak_version()}); service {info.service}; "
                    f"device {info.info}; mtu {info.mtu}")
            hub.log(f"layout {self.drv.layout.describe()}")
            hub.log(f"mode {bb.MODE_NAMES[self.mode]} (command {self.mode})")
            if info.status:
                hub.log(f"status {info.status.text()}")
            hub.battery_start()
        if self.started is None:  # the first stream of this run (a failed first try lands here again)
            if self.mode != bb.CMD_SIGNAL_RESIST:
                hub.live["status"] = "checking contact"
                try:
                    self.on_contact(await self.drv.measure_contact())
                except bb.HeadbandLost as e:
                    hub.log(f"contact check failed: {e}"); raise
            if self.port:
                hub.log(f"live check page on port {self.port}")
            hub.log("recording started, 250 Hz, Ctrl+C to stop")
            self.started = hub.last_report = time.time()  # --seconds and the 10 s line count from here
        else:
            away = now - self.lost_at if self.lost_at else 0.0
            hub.log(f"reconnected after {away:.0f} s away (try {attempt + 1}), battery {battery}%; same files")
        self.lost_at = None
        hub.live["status"] = "recording"

    def on_lost(self, err: bb.HeadbandError, attempt: int, pause: float) -> None:
        if self.lost_at is None:
            self.lost_at = time.time()
        self.hub.live["status"] = "reconnecting" if self.hub.stamp else "searching for the headband"
        self.hub.log(f"headband lost or not found: {err}; trying again in {pause:.0f} s (try {attempt + 1})")

    def tick(self, stopping: asyncio.Event) -> None:
        """Once a second from the main loop: --seconds, contact requests, files, the 10 s line."""
        hub, now = self.hub, time.time()
        if self.seconds and self.started and now - self.started >= self.seconds:
            stopping.set()
        if hub.want_contact.is_set():
            hub.want_contact.clear()
            if self.drv.client is None:
                hub.log("contact re-check asked while the headband is away: skipped")
            else:
                hub.log("contact re-check asked: measuring in-process, no restart")
                hub.live["status"] = "checking contact"; self.drv.check_contact()
        if hub.data is None:
            return
        hub.write_pending()
        if now - hub.last_report >= 10:
            hub.sync(); hub.report()
            if self.gaps:
                hub.log(f"lost {self.gap_samples} samples in {self.gaps} gaps (packet counter jumps)")
                self.gaps = self.gap_samples = 0
            if self.drv.mode == bb.CMD_SIGNAL_RESIST and hub.contact and now - self.last_contact_log >= CONTACT_LOG_EVERY_S:
                hub.log("contact ohms " + ohms_text(hub.contact)); self.last_contact_log = now


async def record(hub: Hub, drv: bb.BrainBitBLE, mode: int, port: int, seconds: float) -> int:
    loop = asyncio.get_running_loop(); stopping = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stopping.set)
    rec = Recording(hub, drv, mode, port, seconds)
    hub.live["status"] = "searching for the headband"
    if port:
        hub.serve(port)  # up at once and all night: the pages say "searching" / "reconnecting" by themselves
    beat = [time.time()]

    def watchdog() -> None:  # last resort if the event loop itself stops turning (no known case)
        while True:
            time.sleep(5)
            if time.time() - beat[0] > 60:
                try:
                    if hub.data is not None:
                        hub.emergency_save()
                    hub.log("main loop stuck for 60 s; saved, exiting so record_night.sh starts a fresh one")
                finally:
                    os._exit(3)
    threading.Thread(target=watchdog, daemon=True).start()
    runner = asyncio.create_task(drv.run(mode, stopping, on_connected=rec.on_connected, on_lost=rec.on_lost,
                                         on_contact=rec.on_contact))
    rc = 0
    while not stopping.is_set():
        await bb._wait(stopping, 1.0)
        beat[0] = time.time()
        if runner.done():  # a bug, not a drop (drops never leave run()): save and let the launcher restart
            exc = runner.exception()
            hub.log(f"driver stopped unexpectedly: {type(exc).__name__}: {exc}"); rc = 1; break
        rec.tick(stopping)
    stopping.set()
    try:
        await asyncio.wait_for(runner, 15)
    except Exception:  # noqa: BLE001 (already logged above, or a stuck close: the files come first)
        runner.cancel()
    if hub.data is not None:
        hub.finish()
        hub.log(f"stopped, battery {hub.live.get('battery', '?')}%")
    hub.close()
    return rc


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default="_local/recordings")
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C")
    ap.add_argument("--port", type=int, default=8765, help="live check page; 0 = off")
    ap.add_argument("--address", help="headband address (default: BRAINBIT_ADDRESS, else the newest .log in --out)")
    ap.add_argument("--signal-resist", action="store_true",
                    help="command 5: signal and contact together (TO VERIFY with scripts/ble_probe.py)")
    ap.add_argument("--order", default=",".join(bb.SIGNAL_ORDER), help="signal wire order (TO VERIFY)")
    ap.add_argument("--resist-order", default=",".join(bb.RESIST_ORDER), help="resistance wire order (TO VERIFY)")
    ap.add_argument("--gain", type=int, default=bb.GAIN, help="amplifier gain for counts -> volts (TO VERIFY)")
    ap.add_argument("--pair", action="store_true", help="pair before connecting (headband in pairing mode)")
    a = ap.parse_args()
    try:
        layout = bb.Layout(bb.parse_order(a.order), bb.parse_order(a.resist_order), a.gain)
    except ValueError as e:
        raise SystemExit(str(e)) from None
    hub = Hub(Path(a.out))
    address = a.address or os.environ.get("BRAINBIT_ADDRESS") or bb.known_address(hub.out)
    hub.log(f"own Bluetooth driver; headband address {address or 'unknown: will scan by name'}")
    drv = bb.BrainBitBLE(address, layout=layout, pair=a.pair, log=hub.log)
    mode = bb.CMD_SIGNAL_RESIST if a.signal_resist else bb.CMD_SIGNAL
    raise SystemExit(asyncio.run(record(hub, drv, mode, a.port, a.seconds)))


if __name__ == "__main__":
    main()
