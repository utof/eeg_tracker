"""The recorder hub shared by the recorders: files on disk and the live HTTP routes (DECISIONS 38).

record_night.py (BrainBit's NeuroSDK2), record_ble.py (our own Bluetooth driver, scripts/brainbit_ble.py) and
record_diy.py (the DIY ADS1299 board, scripts/diy_board.py) only differ in how samples reach the hub; all write the
same files and answer the same routes. The DIY board's channel names and count come from its montage (a record is
then uint32 + one float32 per channel), and its hub refuses the sleep and morning reports, which read BrainBit's
O1 O2 T3 T4 only (DECISIONS 350-359):

Files in --out, one set per recorder run (docs/data-format.md): <stamp>.header.json (what the .f32 holds: the
channels in record order, the rate, the device; written first, scripts/recording.py), <stamp>.f32 (records: uint32
packet number + one float32 in volts per channel; O1 O2 T3 T4 for the BrainBit), <stamp>.idx (one record per
arriving batch: float64 unix time + uint64 index of its first sample; gaps are found from these times), <stamp>.log
(wall-clock lines), <stamp>.markers.jsonl.

Routes: GET /state (last 4 s, contact, battery), GET /stream (server-sent events), POST /marker, POST /contact,
GET/POST /sleep-report and /morning-report, GET /hypnogram.png, and the pages in scripts/web/ by name.
Standard library only: never import numpy here (it segfaulted next to the SDK, DECISIONS 3).
"""
import collections, json, os, queue, struct, threading, time, urllib.parse
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Sequence

import local_http  # scripts/local_http.py: this laptop only (DECISIONS 750)
import recording  # scripts/recording.py: the recording header (standard library only)

try:
    import battery as batt  # scripts/battery.py: the gauge's stuck values, time left, the charge by wear time
except Exception:
    batt = None
try:
    import night_files as nf  # scripts/night_files.py: the Sleep page's report job (standard library only)
except Exception:
    nf = None

REC = struct.Struct("<I4f")
IDX = struct.Struct("<dQ")
NAMES = ("O1", "O2", "T3", "T4")
FS = 250
HERE = Path(__file__).parent
MADE_BY = "eeg_tracker scripts/recorder_hub.py"

Row = tuple[float, ...]  # (packet number, then one value in volts per channel: O1 O2 T3 T4 for BrainBit): one .f32 record


class Hub:
    """Samples in, files and live pages out. add_batch() may be called from any thread; write_pending() and
    report() from the recorder's main loop. names and fs default to BrainBit's; reports=False answers the sleep and
    morning report routes with an error instead of scoring these files. `header` is what every file set's
    <stamp>.header.json says (recording.Header); without one it is the BrainBit's for the default channels, else
    made from the names (a site where a name is a 10-10 one)."""

    def __init__(self, out: Path, names: Sequence[str] = NAMES, fs: int = FS, reports: bool = True,
                 header: recording.Header | None = None) -> None:
        self.out = Path(out); self.out.mkdir(parents=True, exist_ok=True)
        self.reports = reports
        self.names: tuple[str, ...] = tuple(names); self.fs = fs; self.rec = REC  # set again by configure()
        self.nights_dir = self.out.resolve().parent / "nights"  # next to --out
        self.export_dir = self.out.resolve().parent / "export"
        self.lock = threading.Lock()
        self.buf: list[bytes] = []; self.idx: list[bytes] = []
        self.total = 0  # records written to the .f32
        self.seen = 0  # records received (index of the next sample)
        self.ring: collections.deque = collections.deque(maxlen=fs * 5)
        self.contact: dict[str, float] = {}  # last contact resistance in ohms (inf = none)
        self.contact_t: float | None = None  # when it was measured (pages wait for this to change)
        self.want_contact = threading.Event()
        self.live: dict = dict(status="recording", t=time.time(), battery_note=None)
        self.subs: list[queue.Queue] = []; self.subs_lock = threading.Lock()  # live stream: one queue per reader
        self.batt_pts: list = []  # (unix time, %) of the last 16 hours (battery.WEAR_HOURS), earlier runs' logs included
        self.last_report = time.time(); self.last_total = 0
        self.stamp: str | None = None
        self.data = self.logf = self.idxf = self.markf = None
        self.server: ThreadingHTTPServer | None = None
        self.header: recording.Header = recording.brainbit(MADE_BY)  # set again by configure()
        self.configure(names, fs, header)  # BrainBit's defaults give REC, as before

    # ---- files ---------------------------------------------------------------------------------------------
    def configure(self, names: Sequence[str], fs: int = FS, header: recording.Header | None = None) -> None:
        """Channel names (the record is uint32 + one float32 each), rate and the header the next file sets get; only
        while no file set is open."""
        if self.data is not None:
            raise RuntimeError("change the channels between file sets only")
        names = tuple(names)
        if header is None:
            if names == recording.BRAINBIT_NAMES and fs == recording.BRAINBIT_FS:
                header = recording.brainbit(MADE_BY)
            else:
                header = recording.checked(recording.Header(
                    tuple(recording.Channel(n, recording.site_of(n)) for n in names), fs, recording.PACKET_NUMBER,
                    made_by=MADE_BY), "the hub's header")
        elif header.names != names or header.sample_rate != fs:
            raise ValueError(f"the header ({' '.join(header.names)} at {header.sample_rate} Hz) does not match the "
                             f"channels ({' '.join(names)} at {fs} Hz)")
        with self.lock:
            self.names = names; self.fs = fs; self.header = header
            self.rec = struct.Struct(f"<I{len(self.names)}f")
            self.ring = collections.deque(maxlen=fs * 5)

    def open_files(self, stamp: str | None = None) -> str:
        """Create this run's files; call once a headband is found, so runs while it is off leave no empty files.
        A stamp already used in --out moves on by a second (a new set never appends to an old one). The set's
        <stamp>.header.json is written first, before any sample."""
        if stamp is None:
            t = datetime.now()
            while any((self.out / f"{t:%Y-%m-%d-%H%M%S}{s}").exists() for s in (".f32", recording.SUFFIX)):
                t += timedelta(seconds=1)
            stamp = f"{t:%Y-%m-%d-%H%M%S}"
        recording.write(self.out / f"{stamp}.f32", self.header)
        self.stamp = stamp
        self.data = open(self.out / f"{self.stamp}.f32", "ab")
        self.logf = open(self.out / f"{self.stamp}.log", "a")
        self.idxf = open(self.out / f"{self.stamp}.idx", "ab")
        self.markf = open(self.out / f"{self.stamp}.markers.jsonl", "a")  # {"t": unix time, "i": sample index, "text"}
        return self.stamp

    def log(self, msg: str) -> None:
        line = f"{datetime.now().isoformat(timespec='milliseconds')} {msg}"
        print(line, flush=True)
        if self.logf:
            self.logf.write(line + "\n"); self.logf.flush()

    def log_lines(self, lines: Sequence[str]) -> None:
        """Lines that already carry their time (noted before this file set opened) into its log, as they are."""
        if self.logf and lines:
            self.logf.write("".join(line + "\n" for line in lines)); self.logf.flush()

    def add_batch(self, rows: Sequence[Row], now: float | None = None) -> None:
        """One batch as it arrived: an .idx row, the records, the ring for /state and the live stream."""
        now = time.time() if now is None else now
        self.live["t"] = now
        with self.lock:
            self.idx.append(IDX.pack(now, self.seen)); self.seen += len(rows)
            self.buf.extend(self.rec.pack(*r) for r in rows)
            self.ring.extend(r[1:] for r in rows)
            first = self.seen - len(rows)
        if self.subs:
            self.publish(dict(i=first, t=round(now, 3), uv=[[round(v * 1e6, 2) for v in r[1:]] for r in rows]))

    def write_pending(self) -> int:
        """Move what arrived since the last call to the files; returns the records written."""
        with self.lock:
            chunk, self.buf[:] = b"".join(self.buf), []
            ichunk, self.idx[:] = b"".join(self.idx), []
        self.data.write(chunk); self.idxf.write(ichunk)
        n = len(chunk) // self.rec.size; self.total += n
        return n

    def sync(self) -> None:
        self.data.flush(); os.fsync(self.data.fileno()); self.idxf.flush()

    def emergency_save(self) -> None:
        """From another thread when the main loop is stuck: save what is buffered, both files to disk."""
        with self.lock:
            chunk, ichunk = b"".join(self.buf), b"".join(self.idx); self.buf.clear(); self.idx.clear()
        self.data.write(chunk); self.idxf.write(ichunk)
        self.data.flush(); os.fsync(self.data.fileno()); self.idxf.flush(); os.fsync(self.idxf.fileno())

    def finish(self) -> None:
        """Save the rest and close the samples; the log and markers stay open for the last lines (close())."""
        with self.lock:
            chunk = b"".join(self.buf); self.data.write(chunk); self.idxf.write(b"".join(self.idx))
            self.total += len(chunk) // self.rec.size
        self.idxf.flush(); os.fsync(self.idxf.fileno()); self.idxf.close()
        self.data.flush(); os.fsync(self.data.fileno()); self.data.close()
        self.log(f"total samples {self.total}, {self.total / self.fs / 60:.1f} min")

    def close(self) -> None:
        with self.lock:
            if self.markf:
                self.markf.close(); self.markf = None
        if self.logf:
            self.logf.close(); self.logf = None

    def end_file_set(self) -> str | None:
        """Close this set (the samples, then its log and markers) so the next open_files() starts a fresh one in the
        same process; the counters start again. Returns the closed set's stamp."""
        old = self.stamp
        if self.data is not None:
            self.finish()
        self.close()
        with self.lock:
            self.data = self.idxf = None; self.stamp = None
            self.buf.clear(); self.idx.clear(); self.ring.clear()
            self.total = self.seen = self.last_total = 0
        return old

    # ---- battery and the 10 s line ---------------------------------------------------------------------------
    def battery_start(self) -> None:
        """The battery note from earlier runs' logs, so it shows before this run has its own trend."""
        if batt:
            try:
                self.batt_pts = batt.from_logs(self.out, time.time(), batt.WEAR_HOURS)
                self.live["battery_note"] = batt.estimate(self.batt_pts, time.time())["text"]
            except Exception:
                self.batt_pts, self.live["battery_note"] = [], None

    def report(self) -> int:
        """The 10 s line: samples written since the last one and the battery; returns that sample count."""
        got = self.total - self.last_total
        self.log(f"samples {self.total} (+{got}) battery {self.live.get('battery', '?')}%")
        if batt and isinstance(self.live.get("battery"), int):
            try:
                self.batt_pts.append((time.time(), self.live["battery"])); del self.batt_pts[:-6000]  # 16 h at 10 s
                self.live["battery_note"] = batt.estimate(self.batt_pts, time.time())["text"]
            except Exception:
                pass
        self.last_report = time.time(); self.last_total = self.total
        return got

    def set_contact(self, ohms: dict[str, float], now: float | None = None) -> None:
        self.contact.update(ohms); self.contact_t = round(time.time() if now is None else now, 3)

    # ---- live pages ------------------------------------------------------------------------------------------
    def publish(self, event: dict) -> None:
        line = json.dumps(event, separators=(",", ":"))
        with self.subs_lock:
            for q in self.subs:
                try: q.put_nowait(line)
                except queue.Full: pass  # a consumer that cannot keep up loses batches, the recording does not

    def add_marker(self, text: str) -> dict | None:
        with self.lock:
            if self.markf is None:
                return None
            m = dict(t=round(time.time(), 3), i=self.seen, text=text)
            self.markf.write(json.dumps(m) + "\n"); self.markf.flush()
        self.publish(dict(marker=text, i=m["i"], t=m["t"]))
        return m

    def state(self) -> dict:
        with self.lock:
            rows = list(self.ring)[-self.fs * 4:]; names, fs = self.names, self.fs
        data = []
        for c in range(len(names)):
            col = [r[c] for r in rows]; m = sum(col) / len(col) if col else 0.0
            data.append([round((v - m) * 1e6, 1) for v in col])
        last = self.contact
        contact = {n: (None if last.get(n, float("inf")) == float("inf") else round(last[n])) for n in names}
        return dict(status=self.live["status"], battery=self.live.get("battery", "?"),
                    battery_note=self.live.get("battery_note"), minutes=round(self.total / fs / 60, 1),
                    age=round(time.time() - self.live["t"], 1), names=names, fs=fs, contact=contact,
                    contact_t=self.contact_t, data=data)

    def serve(self, port: int) -> None:
        """The live pages on 127.0.0.1:[port] only (DECISIONS 750): open http://localhost:<port>/ on this laptop."""
        self.server = local_http.LocalServer(("127.0.0.1", port), make_handler(self))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def make_handler(hub: Hub) -> type:
    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_a) -> None: pass

        def _send(self, body: bytes, kind: str) -> None:
            self.send_response(200); self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)

        def do_POST(self) -> None:
            if not local_http.guard(self):
                return
            name = self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
            if name == "contact":
                hub.want_contact.set(); self._send(b"ok", "text/plain")
            elif name in ("sleep-report", "morning-report"):
                self.report_api(name, post=True)
            elif name == "marker":  # body: plain text, e.g. "eyes closed start"
                n = min(int(self.headers.get("Content-Length") or 0), 2000)
                text = self.rfile.read(n).decode("utf-8", "replace").strip()[:200] or "marker"
                if hub.add_marker(text) is None:
                    self.send_error(503, "not recording yet"); return
                self._send(b"ok", "text/plain")
            else:
                self.send_error(404)

        def report_api(self, name: str, post: bool = False) -> None:
            """Results without asking (scripts/night_files.py): POST /sleep-report starts scripts/sleep_report.py and
            POST /morning-report scripts/morning_check.py, detached and memory-capped; GET on either says how it is
            going and returns the newest result; GET /hypnogram.png?date= serves a night's chart. Runs in this
            request's thread only; any failure becomes {"error": ...} and never reaches the recording."""
            out, nights_dir, export_dir = hub.out, hub.nights_dir, hub.export_dir
            try:
                if not hub.reports:
                    raise RuntimeError(f"the sleep and morning reports read BrainBit recordings (O1 O2 T3 T4) only; "
                                       f"this recorder's channels are {' '.join(hub.names)} (DECISIONS 350-359)")
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
            self.send_header("Cache-Control", "no-store"); self.end_headers()  # no CORS: other sites' pages never read it
            q: queue.Queue = queue.Queue(maxsize=200)
            with hub.subs_lock: hub.subs.append(q)
            try:
                hello = dict(hello=True, names=hub.names, fs=hub.fs, unit="uV", status=hub.live["status"], next_i=hub.seen)
                self.wfile.write(f"data: {json.dumps(hello)}\n\n".encode()); self.wfile.flush()
                while True:
                    try: line = q.get(timeout=10)
                    except queue.Empty: self.wfile.write(b": keepalive\n\n"); self.wfile.flush(); continue
                    self.wfile.write(f"data: {line}\n\n".encode()); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with hub.subs_lock:
                    if q in hub.subs: hub.subs.remove(q)

        def do_GET(self) -> None:
            if not local_http.guard(self):
                return
            if self.path.split("?")[0].rstrip("/").endswith("/stream"):
                self.stream(); return
            if self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1] in ("sleep-report", "morning-report", "hypnogram.png"):
                self.report_api(self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]); return
            if self.path.rstrip("/").endswith("state"):
                self._send(json.dumps(hub.state()).encode(), "application/json")
            else:  # pages in scripts/web/ by file name; anything else gets the live check page
                name = self.path.split("?")[0].rstrip("/").rsplit("/", 1)[-1]
                kind = {".html": "text/html", ".js": "text/javascript", ".css": "text/css"}.get(Path(name).suffix)
                f = HERE / "web" / name
                if kind and f.is_file():
                    self._send(f.read_bytes(), kind + "; charset=utf-8")
                else:
                    self._send((HERE / "live_page.html").read_bytes(), "text/html; charset=utf-8")

    return Page
