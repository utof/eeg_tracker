"""Record BrainBit signal to disk until Ctrl+C. Survives disconnects.

Output in --out: <stamp>.f32 (records: uint32 PackNum + 4 float32 volts O1 O2 T3 T4),
<stamp>.idx (one record per arriving batch: float64 unix time + uint64 index of its first sample;
used to find gaps, since packet numbers can repeat), <stamp>.log (wall-clock lines: contact check, sample counts every 10 s, disconnects).
"""
import argparse, os, struct, threading, time
from datetime import datetime
from pathlib import Path

from neurosdk.cmn_types import SensorCommand, SensorFamily, SensorState
from neurosdk.scanner import Scanner

REC = struct.Struct("<I4f")
IDX = struct.Struct("<dQ")
FAMILIES = [SensorFamily.LEBrainBit, SensorFamily.LEBrainBitBlack]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="_local/recordings")
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    data = open(out / f"{stamp}.f32", "ab")
    logf = open(out / f"{stamp}.log", "a")
    idxf = open(out / f"{stamp}.idx", "ab")
    lock = threading.Lock(); buf: list[bytes] = []; idx: list[bytes] = []; total = 0; seen = [0]

    def log(msg: str) -> None:
        line = f"{datetime.now().isoformat(timespec='milliseconds')} {msg}"
        print(line, flush=True); logf.write(line + "\n"); logf.flush()

    sc = Scanner(FAMILIES); sc.start()
    for _ in range(30):
        time.sleep(1)
        if sc.sensors(): break
    sc.stop()
    if not sc.sensors():
        raise SystemExit("no BrainBit found: is it switched on?")
    info = sc.sensors()[0]
    s = sc.create_sensor(info)
    log(f"connected {info.Name} {info.Address} serial {info.SerialNumber} battery {s.batt_power}%")

    last = {}
    s.resistDataReceived = lambda _s, d: last.update(O1=d.O1, O2=d.O2, T3=d.T3, T4=d.T4)
    s.exec_command(SensorCommand.StartResist); time.sleep(6); s.exec_command(SensorCommand.StopResist)
    log("contact ohms " + " ".join(f"{k}={v:.0f}" for k, v in last.items()))

    def on_signal(_s, samples) -> None:
        now = time.time()
        with lock:
            idx.append(IDX.pack(now, seen[0])); seen[0] += len(samples)
            buf.extend(REC.pack(x.PackNum, x.O1, x.O2, x.T3, x.T4) for x in samples)
    s.signalDataReceived = on_signal
    s.exec_command(SensorCommand.StartSignal)
    log("recording started, 250 Hz, Ctrl+C to stop")

    t0 = time.time(); last_report = t0; last_total = 0; stalled = 0
    try:
        while not a.seconds or time.time() - t0 < a.seconds:
            time.sleep(1)
            with lock:
                chunk, buf[:] = b"".join(buf), []
                ichunk, idx[:] = b"".join(idx), []
            data.write(chunk); idxf.write(ichunk); total += len(chunk) // REC.size
            if time.time() - last_report >= 10:
                data.flush(); os.fsync(data.fileno()); idxf.flush()
                got = total - last_total
                log(f"samples {total} (+{got}) battery {s.batt_power}%")
                last_report = time.time(); last_total = total
                stalled = stalled + 1 if got == 0 else 0
                if stalled or s.state != SensorState.StateInRange:
                    try:
                        log(f"no data, state {s.state.name}; reconnecting")
                        if s.state != SensorState.StateInRange:
                            s.connect()
                        s.exec_command(SensorCommand.StartSignal)
                        log(f"reconnected, battery {s.batt_power}%")
                    except Exception as e:  # keep trying all night
                        log(f"reconnect failed: {e}")
    except KeyboardInterrupt:
        pass
    finally:
        try:
            s.exec_command(SensorCommand.StopSignal); log(f"stopped, battery {s.batt_power}%")
        except Exception as e:
            log(f"stop failed: {e}")
        with lock:
            data.write(b"".join(buf)); idxf.write(b"".join(idx))
        idxf.close(); data.flush(); os.fsync(data.fileno()); data.close()
        log(f"total samples {total}, {total / 250 / 60:.1f} min"); logf.close()
        try: s.disconnect()
        except Exception: pass


if __name__ == "__main__":
    main()
