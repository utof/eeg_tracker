"""The laptop's helper servers stay on this laptop (DECISIONS 750): they listen on 127.0.0.1 only, answer only
requests that name them in `Host` (no DNS rebinding) and carry no other site's `Origin` (no cross-site posts), and
start without a reverse-DNS lookup. scripts/local_http.py, page_server.py, recorder_hub.py; phone_link.py's own
port is in test_phone_link.py."""
import http.client
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import local_http  # noqa: E402
import page_server  # noqa: E402
import recorder_hub  # noqa: E402


def ask(port: int, method: str, path: str, *, host: str | None = None, origin: str | None = None,
        body: bytes | None = None) -> tuple[int, bytes]:
    headers = {"Host": f"127.0.0.1:{port}" if host is None else host}
    if origin is not None:
        headers["Origin"] = origin
    if body is not None:
        headers["Content-Type"] = "text/plain"
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        c.request(method, path, body=body, headers=headers)
        r = c.getresponse()
        return r.status, r.read()
    finally:
        c.close()


class Recorder:
    """A stand-in for the recorder behind the page server: it notes what reached it."""

    def __init__(self) -> None:
        self.got: list[tuple[str, str]] = []
        rec = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_a) -> None:
                pass

            def _ok(self) -> None:
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

            def do_GET(self) -> None:
                rec.got.append(("GET", self.path))
                self._ok()

            def do_POST(self) -> None:
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                rec.got.append(("POST", self.path))
                self._ok()

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.srv.shutdown()
        self.srv.server_close()


@pytest.fixture
def pages(tmp_path: Path):
    rec = Recorder()
    srv = page_server.make_server(0, "127.0.0.1", rec.port, tmp_path)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv, rec
    srv.shutdown()
    srv.server_close()
    rec.close()


def test_page_server_listens_on_this_laptop_only(pages) -> None:
    srv, _ = pages
    assert srv.server_address[0] == "127.0.0.1"  # never 0.0.0.0: no other device on the Wi-Fi reaches it
    assert isinstance(srv, local_http.LocalServer)


def test_page_server_answers_its_own_names_only(pages) -> None:
    srv, rec = pages
    port = srv.server_address[1]
    assert ask(port, "GET", "/")[0] == 200
    assert ask(port, "GET", "/", host=f"localhost:{port}")[0] == 200
    # DNS rebinding: a page whose own name now points at 127.0.0.1 sends that name
    status, body = ask(port, "GET", "/state", host=f"evil.example:{port}")
    assert status == 403 and json.loads(body) == {"error": "wrong host"}
    assert ask(port, "GET", "/files/recordings/x.f32", host="evil.example")[0] == 403
    assert ask(port, "GET", "/state", host="")[0] == 403
    assert rec.got == []  # nothing of those reached the recorder (or the phone behind it)


def test_page_server_takes_no_cross_site_posts(pages) -> None:
    srv, rec = pages
    port = srv.server_address[1]
    for origin in ("https://evil.example", "null", f"http://evil.example:{port}"):
        status, body = ask(port, "POST", "/marker", origin=origin, body=b"x")
        assert status == 403 and json.loads(body) == {"error": "wrong origin"}, origin
    assert rec.got == []
    # the live page's own button (same origin) and a tool without a browser still work
    assert ask(port, "POST", "/marker", origin=f"http://localhost:{port}", body=b"eyes closed")[0] == 200
    assert ask(port, "POST", "/work", body=b'{"working": true}')[0] == 200
    assert rec.got == [("POST", "/marker"), ("POST", "/work")]


def test_the_recorders_live_pages_stay_on_this_laptop(tmp_path: Path) -> None:
    hub = recorder_hub.Hub(tmp_path / "rec")
    hub.serve(0)
    try:
        port = hub.server.server_address[1]
        assert hub.server.server_address[0] == "127.0.0.1"
        assert ask(port, "GET", "/state")[0] == 200
        assert ask(port, "GET", "/state", host=f"evil.example:{port}")[0] == 403
        assert ask(port, "POST", "/contact", origin="https://evil.example", body=b"")[0] == 403
        assert not hub.want_contact.is_set()  # no page from elsewhere starts a contact check
    finally:
        hub.server.shutdown()
        hub.server.server_close()


def test_no_reverse_dns_lookup_when_a_server_starts(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """http.server looks the bound address's name up (socket.getfqdn); on a slow network that stalls for seconds and
    made a test time out on the desktop. None of these servers needs the name."""
    def boom(*_a: object) -> str:
        raise AssertionError("getfqdn called")

    monkeypatch.setattr(socket, "getfqdn", boom)
    srv = local_http.LocalServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
    srv.server_close()
    srv = page_server.make_server(0, "127.0.0.1", 9, tmp_path)
    srv.server_close()
    hub = recorder_hub.Hub(tmp_path / "rec")
    hub.serve(0)
    hub.server.shutdown()
    hub.server.server_close()
