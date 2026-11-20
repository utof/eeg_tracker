"""The laptop's own little web servers, kept to this laptop (DECISIONS 750).

Every helper server (scripts/page_server.py, scripts/phone_link.py's pages and its pairing port, the recorder's live
pages in scripts/recorder_hub.py) listens on 127.0.0.1 only. phone_link.py's pairing port also listens on the laptop's
home-network address, and only while a one-time code is shown.

`LocalServer` skips the reverse-DNS lookup `http.server` does when it binds (`socket.getfqdn`): on a slow network it
stalls the start for seconds, and nothing here uses the name.

`refused(handler)` is the first thing each request is checked by:
- the `Host` header must name this server as it is reached (`127.0.0.1:<port>`, `localhost:<port>`, `[::1]:<port>`,
  or the address it is bound to): a web page that points its own name at 127.0.0.1 (DNS rebinding) sends its own name;
- an `Origin` header, when there is one, must be this server's own (`http://<one of those>`): another site's page can
  not post to it (no cross-site requests), and "null" is refused too. Requests without `Origin` (the tray, curl, the
  browser's own address bar) are let in.

Standard library only.
"""
from __future__ import annotations

import socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)  # not HTTPServer's: it calls socket.getfqdn()
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


def own_hosts(handler: BaseHTTPRequestHandler, extra: tuple[str, ...] = ()) -> set[str]:
    """The `Host` values this server answers to: loopback names and the address it is bound to (and [extra]
    addresses, such as the one phone_link.py's QR code names), with its port."""
    host, port = handler.server.server_address[:2]
    names = {"127.0.0.1", "localhost", "[::1]"} | {e for e in extra if e}
    if host not in ("", "0.0.0.0", "::"):
        names.add(f"[{host}]" if ":" in str(host) else str(host))
    return {f"{n}:{port}" for n in names} | ({n for n in names} if port == 80 else set())


def refused(handler: BaseHTTPRequestHandler, extra_hosts: tuple[str, ...] = ()) -> str | None:
    """Why this request is turned away (a word for the answer), or None to answer it."""
    ok = own_hosts(handler, extra_hosts)
    host = (handler.headers.get("Host") or "").strip().lower()
    if host not in ok:
        return "wrong host"
    origin = handler.headers.get("Origin")
    if origin is not None and origin.strip().lower() not in {f"http://{h}" for h in ok}:
        return "wrong origin"
    return None


def refuse(handler: BaseHTTPRequestHandler, why: str) -> None:
    body = ('{"error": "' + why + '"}').encode()
    handler.send_response(403)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)
    handler.close_connection = True


def guard(handler: BaseHTTPRequestHandler, extra_hosts: tuple[str, ...] = ()) -> bool:
    """True when the request may go on; else it is answered with 403 here."""
    why = refused(handler, extra_hosts)
    if why is None:
        return True
    refuse(handler, why)  # a body is not read: the connection closes after the answer
    return False
