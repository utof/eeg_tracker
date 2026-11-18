"""Record BrainBit signal to disk until Ctrl+C. Survives disconnects.

Output in --out: <stamp>.f32 (records: uint32 PackNum + 4 float32 volts O1 O2 T3 T4),
<stamp>.idx (one record per arriving batch: float64 unix time + uint64 index of its first sample;
used to find gaps, since packet numbers can repeat), <stamp>.log (wall-clock lines: contact check, sample counts every 10 s, disconnects).
"""
import argparse, collections, json, os, queue, struct, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime
from pathlib import Path

from neurosdk.cmn_types import SensorCommand, SensorFamily, SensorState
from neurosdk.scanner import Scanner

SDK_LIB = sorted({ln.split()[-1] for ln in open("/proc/self/maps") if "libneurosdk2.so" in ln})  # which copy is loaded

try:
    import battery as batt  # scripts/battery.py: drops the gauge's stuck values, time left from the trend
except Exception:
    batt = None
try:
    import night_files as nf  # scripts/night_files.py: the Sleep page's report job (standard library only)
except Exception:
    nf = None

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
    nights_dir, export_dir = out.resolve().parent / "nights", out.resolve().parent / "export"  # next to --out
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
    log(f"sdk library {'patched (keeps other Bluetooth devices)' if SDK_LIB and all('patched' in x for x in SDK_LIB) else SDK_LIB}")
    for attr in ("features", "commands", "parameters"):  # what this headband offers (e.g. pulse or motion sensors)
        try: log(f"{attr} {getattr(s, attr)}")
        except Exception as e: log(f"{attr} unavailable: {e}")
    batt_pts: list = []  # (unix time, %) of the last 3 hours, earlier runs' logs included
    if batt:
        try:
            batt_pts = batt.from_logs(out, time.time()); live_note = batt.estimate(batt_pts, time.time())["text"]
        except Exception:
            batt_pts, live_note = [], None
    else:
        live_note = None

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
    want_contact = threading.Event(); live = dict(status="recording", t=time.time(), battery_note=live_note)
    subs: list[queue.Queue] = []; subs_lock = threading.Lock()  # live stream: one queue per connected consumer

    def publish(event: dict) -> None:
        line = json.dumps(event, separators=(",", ":"))
        with subs_lock:
            for q in subs:
                try: q.put_nowait(line)
                except queue.Full: pass  # a consumer that cannot keep up loses batches, the recording does not

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_a) -> None: pass

        def _send(self, body: bytes, kind: str) -> None:
            self.send_response(200); self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)

        def do_POST(self) -> None:
            name = self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
            if name == "contact":
                want_contact.set(); self._send(b"ok", "text/plain")
            elif name in ("sleep-report", "morning-report"):
                self.report_api(name, post=True)
            elif name == "marker":  # body: plain text, e.g. "eyes closed start"
                n = min(int(self.headers.get("Content-Length") or 0), 2000)
                text = self.rfile.read(n).decode("utf-8", "replace").strip()[:200] or "marker"
                with lock:
                    m = dict(t=round(time.time(), 3), i=seen[0], text=text)
                    markf.write(json.dumps(m) + "\n"); markf.flush()
                publish(dict(marker=text, i=m["i"], t=m["t"]))
                self._send(b"ok", "text/plain")
            else:
                self.send_error(404)

        def report_api(self, name: str, post: bool = False) -> None:
            """Results without asking (scripts/night_files.py): POST /sleep-report starts scripts/sleep_report.py and
            POST /morning-report scripts/morning_check.py, detached and memory-capped; GET on either says how it is
            going and returns the newest result; GET /hypnogram.png?date= serves a night's chart. Runs in this
            request's thread only; any failure becomes {"error": ...} and never reaches the recording."""
            try:
                if nf is None:
                    raise RuntimeError("scripts/night_files.py did not load")
                if name == "morning-report":
                    body = nf.start_morning(out, nights_dir, export_dir) if post else nf.morning_state(out, nights_dir)
                    self._send(json.dumps(body).encode(), "application/json"); return
                if name == "hypnogram.png":
                    date = urllib.parse.parse_qs(self.path.partition("?")[2]).get("date", [None])[0]
                    png = nf.hypnogram(nights_dir, date)
                    if png is None:
                        self.send_error(404); return
                    self._send(png.read_bytes(), "image/png"); return
                body = nf.start_job(out, nights_dir, export_dir) if post else nf.job_state(out, nights_dir)
            except Exception as e:
                body = {"error": f"{type(e).__name__}: {e}"}
            try:
                self._send(json.dumps(body).encode(), "application/json")
            except Exception:
                pass

        def stream(self) -> None:
            """Server-sent events: a hello line, then every batch as {"i": first sample, "t": arrival, "uv": [[O1,O2,T3,T4]...]}
            and every page marker as {"marker": text, "i", "t"}. Any number of consumers (pages, scripts/lsl_bridge.py)."""
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store"); self.send_header("Access-Control-Allow-Origin", "*"); self.end_headers()
            q: queue.Queue = queue.Queue(maxsize=200)
            with subs_lock: subs.append(q)
            try:
                hello = dict(hello=True, names=NAMES, fs=FS, unit="uV", status=live["status"], next_i=seen[0])
                self.wfile.write(f"data: {json.dumps(hello)}\n\n".encode()); self.wfile.flush()
                while True:
                    try: line = q.get(timeout=10)
                    except queue.Empty: self.wfile.write(b": keepalive\n\n"); self.wfile.flush(); continue
                    self.wfile.write(f"data: {line}\n\n".encode()); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with subs_lock:
                    if q in subs: subs.remove(q)

        def do_GET(self) -> None:
            if self.path.split("?")[0].rstrip("/").endswith("/stream"):
                self.stream(); return
            if self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1] in ("sleep-report", "morning-report", "hypnogram.png"):
                self.report_api(self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]); return
            if self.path.rstrip("/").endswith("state"):
                with lock:
                    rows = list(ring)[-FS * 4:]
                data = []
                for c in range(4):
                    col = [r[c] for r in rows]; m = sum(col) / len(col) if col else 0.0
                    data.append([round((v - m) * 1e6, 1) for v in col])
                contact = {n: (None if last.get(n, float("inf")) == float("inf") else round(last[n])) for n in NAMES}
                body = dict(status=live["status"], battery=live.get("battery", "?"), battery_note=live.get("battery_note"), minutes=round(total / FS / 60, 1),
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
            first = seen[0] - len(samples)
        if subs:
            publish(dict(i=first, t=round(now, 3), uv=[[round(x.O1 * 1e6, 2), round(x.O2 * 1e6, 2), round(x.T3 * 1e6, 2),
                                                       round(x.T4 * 1e6, 2)] for x in samples]))
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
                # Measuring contact mid-stream never worked with the Linux SDK (no resistance data, then the stream
                # would not restart; 2026-11-18 02:42 and 05:51). A fresh connection measures it reliably, so restart.
                live["status"] = "restarting to re-check contact"
                log("contact re-check asked: saving and exiting; record_night.sh starts a fresh recorder, which measures contact")
                raise SystemExit(3)
            with lock:
                chunk, buf[:] = b"".join(buf), []
                ichunk, idx[:] = b"".join(idx), []
            data.write(chunk); idxf.write(ichunk); total += len(chunk) // REC.size
            if time.time() - last_report >= 10:
                data.flush(); os.fsync(data.fileno()); idxf.flush()
                got = total - last_total
                try: live["battery"] = s.batt_power
                except Exception: pass
                log(f"samples {total} (+{got}) battery {live.get('battery', '?')}%")
                if batt and isinstance(live.get("battery"), int):
                    try:
                        batt_pts.append((time.time(), live["battery"])); del batt_pts[:-1100]
                        live["battery_note"] = batt.estimate(batt_pts, time.time())["text"]
                    except Exception: pass
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
