"""Record BrainBit signal to disk until Ctrl+C. Survives disconnects.

Output in --out: <stamp>.f32 (records: uint32 PackNum + 4 float32 volts O1 O2 T3 T4),
<stamp>.idx (one record per arriving batch: float64 unix time + uint64 index of its first sample;
used to find gaps, since packet numbers can repeat), <stamp>.log (wall-clock lines: contact check, sample counts every 10 s, disconnects).
Files and live routes come from scripts/recorder_hub.py, shared with record_ble.py (our own Bluetooth driver).
"""
import argparse, os, threading, time
from pathlib import Path

from neurosdk.cmn_types import SensorCommand, SensorFamily, SensorState
from neurosdk.scanner import Scanner

from recorder_hub import Hub

SDK_LIB = sorted({ln.split()[-1] for ln in open("/proc/self/maps") if "libneurosdk2.so" in ln})  # which copy is loaded
FAMILIES = [SensorFamily.LEBrainBit, SensorFamily.LEBrainBitBlack]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="_local/recordings")
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C")
    ap.add_argument("--port", type=int, default=8765, help="live check page; 0 = off")
    a = ap.parse_args()
    hub = Hub(Path(a.out)); log = hub.log

    sc = Scanner(FAMILIES); sc.start()
    for _ in range(30):
        time.sleep(1)
        if sc.sensors(): break
    sc.stop()
    if not sc.sensors():
        raise SystemExit("no BrainBit found: is it switched on?")
    info = sc.sensors()[0]
    s = sc.create_sensor(info)
    # files only once a headband is found, so restarts while it is off leave no empty files
    hub.open_files()
    log(f"connected {info.Name} {info.Address} serial {info.SerialNumber} battery {s.batt_power}% signal {info.RSSI} dBm")
    log(f"sdk library {'patched (keeps other Bluetooth devices)' if SDK_LIB and all('patched' in x for x in SDK_LIB) else SDK_LIB}")
    for attr in ("features", "commands", "parameters"):  # what this headband offers (e.g. pulse or motion sensors)
        try: log(f"{attr} {getattr(s, attr)}")
        except Exception as e: log(f"{attr} unavailable: {e}")
    hub.battery_start()

    last = hub.contact
    resist_n = [0]

    def on_resist(_s, d) -> None:
        resist_n[0] += 1; last.update(O1=d.O1, O2=d.O2, T3=d.T3, T4=d.T4)
    s.resistDataReceived = on_resist
    try:
        s.exec_command(SensorCommand.StartResist); time.sleep(6); s.exec_command(SensorCommand.StopResist)
        hub.set_contact(dict(last))
        log("contact ohms " + " ".join(f"{k}={v:.0f}" for k, v in last.items()))
    except Exception as e:  # a weak link must not stop the recording
        log(f"contact check failed: {e}")

    live = hub.live; live["t"] = time.time()

    if a.port:
        hub.serve(a.port)
        log(f"live check page on port {a.port}")

    def on_signal(_s, samples) -> None:
        hub.add_batch([(x.PackNum, x.O1, x.O2, x.T3, x.T4) for x in samples])
    s.signalDataReceived = on_signal
    for attempt in range(10):
        try:
            if s.state != SensorState.StateInRange:
                s.connect()
            s.exec_command(SensorCommand.StartSignal); break
        except Exception as e:
            log(f"start failed ({attempt + 1}/10): {e}"); time.sleep(3)
    log("recording started, 250 Hz, Ctrl+C to stop")

    t0 = time.time(); hub.last_report = t0; stalled = 0; lost = [False]; beat = [t0]

    def watchdog() -> None:  # an SDK call can block forever (seen 2026-11-18 03:04 in connect after a drop)
        while True:
            time.sleep(5)
            if time.time() - beat[0] > 60:
                try:
                    hub.emergency_save()
                    log("main loop stuck in an SDK call for 60 s; saved, exiting so record_night.sh starts a fresh one")
                finally:
                    os._exit(3)
    threading.Thread(target=watchdog, daemon=True).start()
    try:
        while not a.seconds or time.time() - t0 < a.seconds:
            time.sleep(1); beat[0] = time.time()
            if hub.want_contact.is_set():
                # Measuring contact mid-stream never worked with the Linux SDK (no resistance data, then the stream
                # would not restart; 2026-11-18 02:42 and 05:51). A fresh connection measures it reliably, so restart.
                live["status"] = "restarting to re-check contact"
                log("contact re-check asked: saving and exiting; record_night.sh starts a fresh recorder, which measures contact")
                raise SystemExit(3)
            hub.write_pending()
            if time.time() - hub.last_report >= 10:
                hub.sync()
                try: live["battery"] = s.batt_power
                except Exception: pass
                got = hub.report()
                stalled = stalled + 1 if got == 0 else 0
                if s.state != SensorState.StateInRange:  # SDK calls on a lost sensor segfault (seen 3x on 2026-11-18)
                    log(f"headband {s.state.name}; saving and exiting so record_night.sh starts a fresh recorder")
                    lost[0] = True; raise SystemExit(3)
                if stalled:
                    if stalled >= 4:  # 40 s without data: a fresh process is the path known to work
                        log("still no data; exiting so record_night.sh starts a fresh recorder")
                        raise SystemExit(3)
                    try:
                        log(f"no data, state {s.state.name}; restarting stream (try {stalled})")
                        try: s.exec_command(SensorCommand.StopSignal)
                        except Exception: pass
                        if stalled >= 2 or s.state != SensorState.StateInRange:
                            try: s.disconnect()
                            except Exception: pass
                            time.sleep(2); s.connect(); time.sleep(1)
                        s.exec_command(SensorCommand.StartSignal)
                        log(f"stream restarted, battery {s.batt_power}%")
                    except Exception as e:  # keep trying all night
                        log(f"stream restart failed: {e}")
    except KeyboardInterrupt:
        pass
    finally:  # save first: the SDK calls below can crash the process
        hub.finish()
        if not lost[0]:
            try:
                s.exec_command(SensorCommand.StopSignal); log(f"stopped, battery {s.batt_power}%")
            except Exception as e:
                log(f"stop failed: {e}")
            try: s.disconnect()
            except Exception: pass
        hub.close()


if __name__ == "__main__":
    main()
