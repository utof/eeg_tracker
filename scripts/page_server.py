"""An always-on front for the recorder's pages, so they stay up while the recorder reconnects.

usage: python3 scripts/page_server.py [--port 8770] [--recorder http://127.0.0.1:8765]

The recorder (scripts/record_night.py) restarts its whole process after every Bluetooth drop and for every contact
re-check, and its page server goes with it for 20-40 s. This small server never restarts: it serves the pages
itself (scripts/live_page.html at "/", anything in scripts/web/ by file name) and passes every other request
(state, stream, marker, contact, ...) to the recorder. While the recorder is away, /state answers
{"status": "reconnecting"} and other requests get 503, so the pages show "reconnecting" and carry on by themselves.
Standard library only.
"""
import argparse, http.client, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).parent
KINDS = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".png": "image/png"}


def make_handler(rec_host: str, rec_port: int):
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
            else:
                f = HERE / "web" / name
                if Path(name).suffix not in KINDS or not f.is_file():
                    return False
            self._send(200, f.read_bytes(), KINDS[f.suffix]); return True

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
            if not self._page():
                self._forward("GET")

        def do_POST(self) -> None:
            self._forward("POST")

    return H


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--recorder", default="http://127.0.0.1:8765")
    a = ap.parse_args()
    u = urlsplit(a.recorder)
    srv = ThreadingHTTPServer(("0.0.0.0", a.port), make_handler(u.hostname or "127.0.0.1", u.port or 80))
    srv.daemon_threads = True
    print(f"pages on port {a.port}, recorder at {a.recorder}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
