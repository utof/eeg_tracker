"""Record BrainBit signal to disk until Ctrl+C. Survives disconnects.

Output in --out: <stamp>.f32 (records: uint32 PackNum + 4 float32 volts O1 O2 T3 T4),
<stamp>.idx (one record per arriving batch: float64 unix time + uint64 index of its first sample;
used to find gaps, since packet numbers can repeat), <stamp>.log (wall-clock lines: contact check, sample counts every 10 s, disconnects).
"""
import argparse, collections, json, os, struct, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime
from pathlib import Path

from neurosdk.cmn_types import SensorCommand, SensorFamily, SensorState
from neurosdk.scanner import Scanner

REC = struct.Struct("<I4f")
IDX = struct.Struct("<dQ")
FAMILIES = [SensorFamily.LEBrainBit, SensorFamily.LEBrainBitBlack]


NAMES = ("O1", "O2", "T3", "T4")
FS = 250


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="_local/recordings")
    ap.add_argument("--seconds", type=float, default=0, help="0 = until Ctrl+C")
    ap.add_argument("--port", type=int, default=8765, help="live check page; 0 = off")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
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
    # files only once a headband is found, so restarts while it is off leave no empty files
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    data = open(out / f"{stamp}.f32", "ab")
    logf = open(out / f"{stamp}.log", "a")
    idxf = open(out / f"{stamp}.idx", "ab")
    markf = open(out / f"{stamp}.markers.jsonl", "a")  # page markers: {"t": unix time, "i": sample index, "text"}
    log(f"connected {info.Name} {info.Address} serial {info.SerialNumber} battery {s.batt_power}% signal {info.RSSI} dBm")

    last = {}
    resist_n = [0]

    def on_resist(_s, d) -> None:
        resist_n[0] += 1; last.update(O1=d.O1, O2=d.O2, T3=d.T3, T4=d.T4)
    s.resistDataReceived = on_resist
    try:
        s.exec_command(SensorCommand.StartResist); time.sleep(6); s.exec_command(SensorCommand.StopResist)
        log("contact ohms " + " ".join(f"{k}={v:.0f}" for k, v in last.items()))
    except Exception as e:  # a weak link must not stop the recording
        log(f"contact check failed: {e}")

    ring: collections.deque = collections.deque(maxlen=FS * 5)
    want_contact = threading.Event(); live = dict(status="recording", t=time.time())

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_a) -> None: pass

        def _send(self, body: bytes, kind: str) -> None:
            self.send_response(200); self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)

        def do_POST(self) -> None:
            name = self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
            if name == "contact":
                want_contact.set(); self._send(b"ok", "text/plain")
            elif name == "marker":  # body: plain text, e.g. "eyes closed start"
                n = min(int(self.headers.get("Content-Length") or 0), 2000)
                text = self.rfile.read(n).decode("utf-8", "replace").strip()[:200] or "marker"
                with lock:
                    markf.write(json.dumps(dict(t=round(time.time(), 3), i=seen[0], text=text)) + "\n"); markf.flush()
                self._send(b"ok", "text/plain")
            else:
                self.send_error(404)

        def do_GET(self) -> None:
            if self.path.rstrip("/").endswith("state"):
                with lock:
                    rows = list(ring)[-FS * 4:]
                data = []
                for c in range(4):
                    col = [r[c] for r in rows]; m = sum(col) / len(col) if col else 0.0
                    data.append([round((v - m) * 1e6, 1) for v in col])
                contact = {n: (None if last.get(n, float("inf")) == float("inf") else round(last[n])) for n in NAMES}
                body = dict(status=live["status"], battery=live.get("battery", "?"), minutes=round(total / FS / 60, 1),
                            age=round(time.time() - live["t"], 1), names=NAMES, fs=FS, contact=contact, data=data)
                self._send(json.dumps(body).encode(), "application/json")
            else:  # pages in scripts/web/ by file name; anything else gets the live check page
                name = self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
                kind = {".html": "text/html", ".js": "text/javascript", ".css": "text/css"}.get(Path(name).suffix)
                f = Path(__file__).parent / "web" / name
                if kind and f.is_file():
                    self._send(f.read_bytes(), kind + "; charset=utf-8")
                else:
                    self._send((Path(__file__).parent / "live_page.html").read_bytes(), "text/html; charset=utf-8")

    if a.port:
        srv = ThreadingHTTPServer(("0.0.0.0", a.port), Page)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        log(f"live check page on port {a.port}")

    def on_signal(_s, samples) -> None:
        now = time.time(); live["t"] = now
        with lock:
            idx.append(IDX.pack(now, seen[0])); seen[0] += len(samples)
            buf.extend(REC.pack(x.PackNum, x.O1, x.O2, x.T3, x.T4) for x in samples)
            ring.extend((x.O1, x.O2, x.T3, x.T4) for x in samples)
    s.signalDataReceived = on_signal
    for attempt in range(10):
        try:
            if s.state != SensorState.StateInRange:
                s.connect()
            s.exec_command(SensorCommand.StartSignal); break
        except Exception as e:
            log(f"start failed ({attempt + 1}/10): {e}"); time.sleep(3)
    log("recording started, 250 Hz, Ctrl+C to stop")

    t0 = time.time(); last_report = t0; last_total = 0; stalled = 0; lost = [False]; beat = [t0]

    def watchdog() -> None:  # an SDK call can block forever (seen 2026-11-18 03:04 in connect after a drop)
        while True:
            time.sleep(5)
            if time.time() - beat[0] > 60:
                with lock:
                    chunk, ichunk = b"".join(buf), b"".join(idx); buf.clear(); idx.clear()
                try:
                    data.write(chunk); idxf.write(ichunk)
                    data.flush(); os.fsync(data.fileno()); idxf.flush(); os.fsync(idxf.fileno())
                    log("main loop stuck in an SDK call for 60 s; saved, exiting so record_night.sh starts a fresh one")
                finally:
                    os._exit(3)
    threading.Thread(target=watchdog, daemon=True).start()
    try:
        while not a.seconds or time.time() - t0 < a.seconds:
            time.sleep(1); beat[0] = time.time()
            if want_contact.is_set():
                want_contact.clear(); live["status"] = "checking contact"
                n0 = resist_n[0]
                try:
                    s.exec_command(SensorCommand.StopSignal); time.sleep(1)
                    s.exec_command(SensorCommand.StartResist); time.sleep(6)
                    s.exec_command(SensorCommand.StopResist); time.sleep(1)
                    s.exec_command(SensorCommand.StartSignal)
                    if resist_n[0] > n0:
                        log("contact ohms " + " ".join(f"{k}={v:.0f}" for k, v in last.items()))
                    else:
                        log("contact re-check: no resistance data arrived")
                except Exception as e:
                    log(f"contact re-check failed: {e}")
                live["status"] = "recording"
            with lock:
                chunk, buf[:] = b"".join(buf), []
                ichunk, idx[:] = b"".join(idx), []
            data.write(chunk); idxf.write(ichunk); total += len(chunk) // REC.size
            if time.time() - last_report >= 10:
                data.flush(); os.fsync(data.fileno()); idxf.flush()
                got = total - last_total
                try: live["battery"] = s.batt_power
                except Exception: pass
                log(f"samples {total} (+{got}) battery {s.batt_power}%")
                last_report = time.time(); last_total = total
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
        with lock:
            chunk = b"".join(buf); data.write(chunk); idxf.write(b"".join(idx)); total += len(chunk) // REC.size
        idxf.flush(); os.fsync(idxf.fileno()); idxf.close(); data.flush(); os.fsync(data.fileno()); data.close()
        log(f"total samples {total}, {total / 250 / 60:.1f} min")
        if not lost[0]:
            try:
                s.exec_command(SensorCommand.StopSignal); log(f"stopped, battery {s.batt_power}%")
            except Exception as e:
                log(f"stop failed: {e}")
            try: s.disconnect()
            except Exception: pass
        markf.close(); logf.close()


if __name__ == "__main__":
    main()
