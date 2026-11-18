"""An always-on front for the recorder's pages, so they stay up while the recorder reconnects.

usage: python3 scripts/page_server.py [--port 8770] [--recorder http://127.0.0.1:8765]

The recorder (scripts/record_night.py) restarts its whole process after every Bluetooth drop and for every contact
re-check, and its page server goes with it for 20-40 s. This small server never restarts: it serves the pages
itself (scripts/live_page.html at "/", anything in scripts/web/ by file name) and passes every other request
(state, stream, marker, contact, ...) to the recorder. While the recorder is away, /state answers
{"status": "reconnecting"} and other requests get 503, so the pages show "reconnecting" and carry on by themselves.
The results (GET/POST /sleep-report and /morning-report, GET /hypnogram.png) it answers itself through
night_files.py, like the recorder does, so the Sleep page works while the headband is off or charging, which is
when the recorder has no page server at all. Standard library only.
"""
import argparse, http.client, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find night_files.py even under `python3 -I`
try:
    import night_files as nf  # scripts/night_files.py: the results jobs (standard library only)
except Exception:
    nf = None

HERE = Path(__file__).parent
REPORTS = ("sleep-report", "morning-report", "hypnogram.png")
KINDS = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".png": "image/png"}


def make_handler(rec_host: str, rec_port: int, rec_dir: Path = HERE.parent / "_local" / "recordings"):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_a) -> None:
            pass

        def _send(self, code: int, body: bytes, kind: str) -> None:
            self.send_response(code); self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body))); self.send_header("Cache-Control", "no-store")
            self.end_headers(); self.wfile.write(body)

        def _page(self) -> bool:
            path = urlsplit(self.path).path
            name = path.rstrip("/").rsplit("/", 1)[-1]
            if path in ("", "/"):
                f = HERE / "live_page.html"
            elif name == "findings.html":  # the private research findings page (never committed), LAN only
                f = HERE.parent / "_local" / "research" / "2026-11-18-findings.html"
                if not f.is_file():
                    return False
            else:
                f = HERE / "web" / name
                if Path(name).suffix not in KINDS or not f.is_file():
                    return False
            self._send(200, f.read_bytes(), KINDS[f.suffix]); return True

        def _report(self, method: str) -> bool:
            """The results routes, answered here even while the recorder is away; any failure becomes {"error"}."""
            u = urlsplit(self.path)
            name = u.path.rstrip("/").rsplit("/", 1)[-1]
            if name not in REPORTS:
                return False
            if method == "POST":
                self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 10_000))
            nights, export = rec_dir.resolve().parent / "nights", rec_dir.resolve().parent / "export"
            try:
                if nf is None:
                    raise RuntimeError("scripts/night_files.py did not load")
                if name == "hypnogram.png":
                    png = nf.hypnogram(nights, parse_qs(u.query).get("date", [None])[0])
                    if png is None:
                        self._send(404, b"no chart", "text/plain"); return True
                    self._send(200, png.read_bytes(), "image/png"); return True
                sleep = name == "sleep-report"
                if method == "POST":
                    body = (nf.start_job if sleep else nf.start_morning)(rec_dir, nights, export)
                else:
                    body = nf.job_state(rec_dir, nights) if sleep else nf.morning_state(rec_dir, nights)
            except Exception as e:
                body = {"error": f"{type(e).__name__}: {e}"}
            self._send(200, json.dumps(body).encode(), "application/json")
            return True

        def _away(self) -> None:
            if urlsplit(self.path).path.rstrip("/").endswith("state"):
                self._send(200, json.dumps({"status": "reconnecting", "battery": "?", "minutes": 0, "age": 999,
                                            "names": ["O1", "O2", "T3", "T4"], "fs": 250, "contact": {},
                                            "data": [[], [], [], []]}).encode(), "application/json")
            else:
                self._send(503, b'{"error": "recorder reconnecting"}', "application/json")

        def _forward(self, method: str) -> None:
            body = None
            if method == "POST":
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            stream = urlsplit(self.path).path.rstrip("/").endswith("/stream")
            try:
                c = http.client.HTTPConnection(rec_host, rec_port, timeout=None if stream else 10)
                c.request(method, self.path, body=body,
                          headers={"Content-Type": self.headers.get("Content-Type", "text/plain")})
                r = c.getresponse()
            except OSError:
                self._away(); return
            if not stream:
                data = r.read(); self._send(r.status, data, r.getheader("Content-Type", "application/octet-stream"))
                c.close(); return
            self.send_response(r.status)  # server-sent events: pass the lines through until either side closes
            self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close"); self.end_headers()
            self.close_connection = True
            try:
                while True:
                    line = r.fp.readline()
                    if not line:
                        break
                    self.wfile.write(line); self.wfile.flush()
            except OSError:
                pass
            finally:
                c.close()

        def do_GET(self) -> None:
            if not self._page() and not self._report("GET"):
                self._forward("GET")

        def do_POST(self) -> None:
            if not self._report("POST"):
                self._forward("POST")

    return H


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--recorder", default="http://127.0.0.1:8765")
    ap.add_argument("--recordings", type=Path, default=HERE.parent / "_local" / "recordings",
                    help="the recorder's --out; the results live in the nights folder next to it")
    a = ap.parse_args()
    u = urlsplit(a.recorder)
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), make_handler(u.hostname or "127.0.0.1", u.port or 80, a.recordings))
    srv.daemon_threads = True
    print(f"pages on port {a.port}, recorder at {a.recorder}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
