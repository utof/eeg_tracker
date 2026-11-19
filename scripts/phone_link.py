"""Connect the phone to this laptop with one scan, then keep its files mirrored and its live pages up.

usage: python3 scripts/phone_link.py [--dest _local] [--every 2] [--no-pages] [--no-mirror]
       less common: [--address <this laptop's Wi-Fi address>] [--port 8771] [--pages-port 8770] [--qr web|app]
                    [--phone-at http://127.0.0.1:8765] [--name <shown on the phone>]

The owner's steps (app/README.md, "Share on Wi-Fi"): run this, point the phone's camera at the code it shows, tap the
link, tap **Open EEG Tracker**, then **Connect**. Leave the window open. Next time: run it again; the phone finds
this laptop by itself whenever Share on Wi-Fi is on.

How it works (DECISIONS rows 530-539; docs/phone-link.md):
- The code holds `http://<this laptop's Wi-Fi address>:8771/p?s=<one-time code>`: any camera opens it in the browser,
  whose page opens the app (`eegtracker://pair?...`). `--qr app` puts the app link in the code itself instead.
- On Connect the app checks that this laptop knows the one-time code (an HMAC over its random nonce, so the code is
  never sent back), proves it knows it too, and only then sends its Share on Wi-Fi port and token. The one-time code
  works once, for 5 minutes; a new one is shown while no phone answers (Enter shows a new one at any time).
- The laptop takes the phone's address from the connection itself, not from what the phone thinks it has.
- Both sides remember each other: `<dest>/phone/link.json` here (the phone's address, port and token, and a key of
  their own; file mode 600), the app's private settings on the phone. Whenever Share on Wi-Fi starts, and every 5
  minutes while it is on, the phone tells this laptop where it is now, by the same proof with that key, so a new
  address is picked up by itself.
- Then it does what scripts/pull_phone.py does (a copy every --every minutes, raw nights first; the same files and
  rules) and serves the live pages like scripts/page_server.py at http://localhost:8770/ (on this laptop only).
- Nothing is reachable beyond this laptop and its local network: it listens on the Wi-Fi address and 127.0.0.1 only,
  and answers local-network addresses only (10.x, 172.16-31.x, 192.168.x, 169.254.x). Plain HTTP, like Share on
  Wi-Fi itself (home Wi-Fi only).

Standard library only (with scripts/qr_code.py, pull_phone.py, page_server.py and import_phone.py).
"""
from __future__ import annotations

import argparse, hashlib, hmac, html, ipaddress, json, os, re, secrets, socket, sys, threading, time
from dataclasses import dataclass
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find the other scripts even under `python3 -I`
import import_phone as ip  # noqa: E402
import page_server  # noqa: E402
import pull_phone as pp  # noqa: E402
import qr_code  # noqa: E402

PORT = 8771
PAGES_PORT = 8770
CODE_LIFE = 300.0  # seconds a one-time code works (once)
NONCE_LIFE = 60.0  # seconds between the phone's hello and its finish
RENEW_FOR = 1800.0  # new codes are shown by themselves for this long; then Enter shows one
APP_PACKAGE = "io.github.utof.eeg_tracker"
SCHEME = "eegtracker"
VERSION = 1
PROOF = "eeg-tracker link v1"
NONCE = re.compile(r"[A-Za-z0-9_-]{16,64}")
TOKEN = re.compile(r"[A-Za-z0-9]{8,64}")
MAX_BODY = 4096

_LAN = tuple(ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"))
_NOT_WIFI = re.compile(r"^(lo|tun|tap|wg|docker|br-|virbr|veth|vmnet|vboxnet|zt|tailscale|ppp|wwan)")


def _v4(addr: str) -> ipaddress.IPv4Address | None:
    try:
        a = ipaddress.ip_address(addr.split("%")[0])
    except ValueError:
        return None
    if isinstance(a, ipaddress.IPv6Address):
        return a.ipv4_mapped
    return a


def is_lan(addr: str) -> bool:
    """A private IPv4 address of a local network (the phone's own rule, app/lib/share/protocol.dart)."""
    a = _v4(addr)
    return a is not None and any(a in n for n in _LAN)


def is_loopback(addr: str) -> bool:
    a = _v4(addr)
    return a is not None and a.is_loopback


def allowed_client(addr: str) -> bool:
    return is_lan(addr) or is_loopback(addr)


def interface_addresses() -> list[tuple[str, str]]:
    """(interface, IPv4 address) of this computer's interfaces; empty where the system cannot tell (not Linux)."""
    try:
        import fcntl, struct
        names = [n for _, n in socket.if_nameindex()]
    except (ImportError, OSError, AttributeError):
        return []
    out = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        for name in names:
            try:
                raw = fcntl.ioctl(s.fileno(), 0x8915, struct.pack("256s", name[:15].encode()))  # SIOCGIFADDR
            except OSError:
                continue
            out.append((name, socket.inet_ntoa(raw[20:24])))
    return out


def lan_address() -> str | None:
    """This laptop's address on the home network: Wi-Fi first, then wired; never a VPN, a container bridge or
    loopback. Falls back to the address the system would send from (nothing is sent)."""
    found = sorted((0 if n.startswith("wl") else 1, n, a) for n, a in interface_addresses()
                   if not _NOT_WIFI.match(n) and is_lan(a))
    if found:
        return found[0][2]
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))  # a documentation address: only picks the outgoing interface
            a = s.getsockname()[0]
    except OSError:
        return None
    return a if is_lan(a) else None


def proof(key: str, who: str, via: str, first: str, second: str) -> str:
    """HMAC-SHA256 of `eeg-tracker link v1|<who>|<via>|<first>|<second>` with the code or the key (UTF-8), in hex.
    The laptop answers the phone's nonce with who=laptop (phone nonce, laptop nonce); the phone answers with
    who=phone (laptop nonce, phone nonce). app/lib/share/link.dart computes the same."""
    msg = "|".join((PROOF, who, via, first, second))
    return hmac.new(key.encode("utf-8"), msg.encode("utf-8"), hashlib.sha256).hexdigest()


@dataclass(frozen=True)
class PhoneAt:
    address: str
    port: int
    token: str


def _now_text() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Link:
    """The pairing: the one-time code, the key shared with the paired phone, and where the phone is."""

    def __init__(self, store: Path, *, name: str, host: str, port: int = PORT, phone_at: str | None = None,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.store, self.name, self.host, self.port = store, name, host, port
        self.override = phone_at
        self.clock = clock
        self.lock = threading.Lock()
        self.changed = threading.Event()  # the phone told where it is: the mirror passes at once
        self.listeners: list[Callable[[PhoneAt, str, bool], None]] = []  # (phone, via, moved)
        self.code: str | None = None
        self.code_until = 0.0
        self.answering = False  # the last mirror pass reached the phone
        self._nonces: dict[str, tuple[str, str, float]] = {}  # laptop nonce -> (phone nonce, via, until)
        self.key: str | None = None
        self.phone: PhoneAt | None = None
        self._paired: str | None = None
        self._load()

    # --- the one-time code
    def new_code(self) -> str:
        with self.lock:
            self.code = secrets.token_urlsafe(16)  # 128 bits
            self.code_until = self.clock() + CODE_LIFE
            self._nonces = {k: v for k, v in self._nonces.items() if v[1] != "code"}
            return self.code

    def code_valid(self, code: str | None = None) -> bool:
        with self.lock:
            ok = self.code is not None and self.clock() < self.code_until
            return ok and (code is None or hmac.compare_digest(code.encode(), (self.code or "").encode()))

    def web_link(self, code: str) -> str:
        return f"http://{self.host}:{self.port}/p?s={code}"

    def app_link(self, code: str) -> str:
        return f"{SCHEME}://pair?h={self.host}&p={self.port}&s={code}&n={quote(self.name, safe='')}"

    def intent_link(self, code: str) -> str:
        """Chrome's form of the app link: opens the app itself (never another app), or the install hint page."""
        fallback = quote(f"http://{self.host}:{self.port}/noapp", safe="")
        return (f"intent://pair?h={self.host}&p={self.port}&s={code}&n={quote(self.name, safe='')}"
                f"#Intent;scheme={SCHEME};package={APP_PACKAGE};S.browser_fallback_url={fallback};end")

    # --- the handshake
    def _secret(self, via: str) -> str | None:
        if via == "code":
            return self.code if self.code is not None and self.clock() < self.code_until else None
        return self.key

    @staticmethod
    def _missing(via: str) -> tuple[int, dict]:
        return (410, {"error": "expired"}) if via == "code" else (404, {"error": "not paired"})

    def hello(self, body: object) -> tuple[int, dict]:
        """The phone's first step: its nonce. The answer proves this laptop knows the code (or the key)."""
        if not isinstance(body, dict) or body.get("v") != VERSION or body.get("via") not in ("code", "key"):
            return 400, {"error": "bad request"}
        via, theirs = body["via"], body.get("nonce")
        if not isinstance(theirs, str) or not NONCE.fullmatch(theirs):
            return 400, {"error": "bad request"}
        with self.lock:
            secret = self._secret(via)
            if secret is None:
                return self._missing(via)
            now = self.clock()
            self._nonces = {k: v for k, v in self._nonces.items() if v[2] > now}
            while len(self._nonces) >= 64:
                self._nonces.pop(next(iter(self._nonces)))
            mine = secrets.token_urlsafe(16)
            self._nonces[mine] = (theirs, via, now + NONCE_LIFE)
            return 200, {"v": VERSION, "nonce": mine, "proof": proof(secret, "laptop", via, theirs, mine),
                         "name": self.name}

    def finish(self, body: object, client: str) -> tuple[int, dict]:
        """The phone's second step: its proof, then its Share on Wi-Fi port and token."""
        if not isinstance(body, dict) or body.get("v") != VERSION or body.get("via") not in ("code", "key"):
            return 400, {"error": "bad request"}
        via, mine, given = body["via"], body.get("nonce"), body.get("proof")
        port, token = body.get("port"), body.get("token")
        if not (isinstance(mine, str) and isinstance(given, str) and isinstance(token, str) and TOKEN.fullmatch(token)
                and isinstance(port, int) and not isinstance(port, bool) and 1024 <= port <= 65535):
            return 400, {"error": "bad request"}
        with self.lock:
            entry = self._nonces.pop(mine, None)  # one try per hello
            if entry is None or entry[2] <= self.clock() or entry[1] != via:
                return 403, {"error": "start again"}
            secret = self._secret(via)
            if secret is None:
                return self._missing(via)
            if not hmac.compare_digest(proof(secret, "phone", via, mine, entry[0]).encode(), given.encode()):
                return 403, {"error": "wrong proof"}
            old = self.phone
            if via == "code":
                self.code = None  # used: it never works again
                self.key = secrets.token_urlsafe(32)
                self._nonces = {k: v for k, v in self._nonces.items() if v[1] != "code"}
            address = "127.0.0.1" if is_loopback(client) else str(_v4(client))
            phone = self.phone = PhoneAt(address, port, token)
            self._save(paired=via == "code")
            answer: dict = {"v": VERSION, "name": self.name}
            if via == "code":
                answer["key"] = self.key
        moved = old is None or old != phone
        if moved:
            self.changed.set()  # a new address or token: the mirror passes at once, not at its next turn
        for f in list(self.listeners):
            f(phone, via, moved)
        return 200, answer

    # --- where the phone is
    def target(self) -> tuple[str, int, str] | None:
        """(host, port, token) to reach the phone's Share on Wi-Fi; None before any pairing."""
        with self.lock:
            p = self.phone
            if p is None:
                return None
            if self.override:
                u = urlsplit(self.override if "://" in self.override else f"http://{self.override}")
                return (u.hostname or "127.0.0.1", u.port or p.port, p.token)
            return (p.address, p.port, p.token)

    # --- link.json
    def _load(self) -> None:
        try:
            raw = json.loads(self.store.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(raw, dict):
            return
        key, ph = raw.get("laptop_key"), raw.get("phone")
        if isinstance(key, str) and len(key) >= 32:
            self.key = key
        if (isinstance(ph, dict) and isinstance(ph.get("address"), str) and allowed_client(ph["address"])
                and isinstance(ph.get("port"), int) and isinstance(ph.get("token"), str)
                and TOKEN.fullmatch(ph["token"])):
            self.phone = PhoneAt(ph["address"], ph["port"], ph["token"])
        self._paired = raw.get("paired") if isinstance(raw.get("paired"), str) else None

    def _save(self, *, paired: bool) -> None:
        if paired or not self._paired:
            self._paired = _now_text()
        p = self.phone
        data = {"version": 1, "laptop_key": self.key, "paired": self._paired, "told": _now_text(),
                "phone": None if p is None else {"address": p.address, "port": p.port, "token": p.token}}
        self.store.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.store.with_name(self.store.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.store)


# --- the web pages the phone's browser and this laptop's browser see

_STYLE = ("body{font:18px/1.5 system-ui,sans-serif;background:#14161a;color:#e9e4d8;margin:0;padding:28px;"
          "max-width:34em}a.go{display:block;text-align:center;background:#e9e4d8;color:#14161a;padding:18px;"
          "border-radius:10px;font-size:22px;text-decoration:none;margin:24px 0}p.small{color:#a7a196;font-size:15px}"
          ".qr{background:#fff;display:inline-block;padding:8px;border-radius:6px}")


def _page(title: str, body: str, *, refresh: int | None = None) -> bytes:
    meta = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ""
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
            f'content="width=device-width,initial-scale=1">{meta}<title>{html.escape(title)}</title>'
            f"<style>{_STYLE}</style></head><body>{body}</body></html>").encode("utf-8")


def landing_page(link: Link, code: str) -> bytes:
    """What the phone's browser shows after the scan: one button that opens the app."""
    if not link.code_valid(code):
        return _page("EEG Tracker", "<h1>This code has expired</h1><p>Each code works once, for 5 minutes. Look at "
                     "the laptop: it shows a new one (or press Enter in its window). Scan that one.</p>")
    intent, app = html.escape(link.intent_link(code)), html.escape(link.app_link(code))
    return _page("Connect to EEG Tracker", (
        f"<h1>Connect this phone</h1><p>to the laptop <b>{html.escape(link.name)}</b>.</p>"
        f'<a class="go" id="go" href="{intent}">Open EEG Tracker</a>'
        "<p>The app asks “Connect to this laptop?”: tap <b>Connect</b>.</p>"
        f'<p class="small">Nothing opens? Install the EEG Tracker app first, then scan again. Another browser: '
        f'<a href="{app}" style="color:#e9e4d8">open the app this way</a>.</p>'
        f"<script>setTimeout(function(){{location.href=document.getElementById('go').href}},300)</script>"))


def noapp_page() -> bytes:
    return _page("EEG Tracker", "<h1>The app is not on this phone</h1><p>Install the EEG Tracker app (the APK the "
                 "assistant gave you), open it once, then scan the laptop's code again.</p>")


def status(link: Link) -> dict:
    t = link.target()
    return {"connected": link.answering, "phone": None if t is None else f"{t[0]}:{t[1]}",
            "code_valid": link.code_valid(), "name": link.name}


def local_page(link: Link) -> bytes:
    """http://127.0.0.1:8771/ on this laptop: the code, bigger than in the terminal, and the state."""
    t = link.target()
    parts = ["<h1>EEG Tracker: connect your phone</h1>"]
    if link.answering and t is not None:
        parts.append(f"<p>Connected: copying from the phone at {html.escape(t[0])}. Live pages: "
                     '<a href="http://localhost:8770/" style="color:#e9e4d8">http://localhost:8770/</a></p>')
    elif t is not None:
        parts.append(f"<p>Paired with the phone (last at {html.escape(t[0])}); it is not answering now. Switch "
                     "Share on Wi-Fi on in the app: it finds this laptop within a minute.</p>")
    with link.lock:
        code = link.code if link.code is not None and link.clock() < link.code_until else None
    if code is not None:
        parts.append("<p>Open the phone's camera, point it at the code, tap the link, then <b>Open EEG Tracker</b>, "
                     "then <b>Connect</b>.</p>")
        parts.append(f'<div class="qr">{qr_code.svg(qr_code.encode(link.web_link(code)), scale=10)}</div>')
        parts.append('<p class="small">The code works once, for 5 minutes. Then press Enter in the laptop window '
                     "for a new one.</p>")
    else:
        parts.append('<p class="small">No code right now: press Enter in the laptop window for a new one.</p>')
    return _page("EEG Tracker: connect", "".join(parts), refresh=3)


def make_handler(link: Link, client_of: Callable[[BaseHTTPRequestHandler], str] | None = None):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "eeg-tracker-link"
        sys_version = ""

        def log_message(self, *_a) -> None:
            pass

        def _send(self, code: int, body: bytes, kind: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, obj: dict) -> None:
            self._send(code, json.dumps(obj).encode(), "application/json")

        def _client(self) -> str | None:
            c = client_of(self) if client_of else self.client_address[0]
            if not allowed_client(c):
                self._json(403, {"error": "local network only"})
                return None
            return c

        def do_GET(self) -> None:
            c = self._client()
            if c is None:
                return
            u = urlsplit(self.path)
            if u.path == "/p":
                self._send(200, landing_page(link, parse_qs(u.query).get("s", [""])[0]), "text/html; charset=utf-8")
            elif u.path == "/noapp":
                self._send(200, noapp_page(), "text/html; charset=utf-8")
            elif u.path == "/" and is_loopback(c):  # the code itself: never to another device
                self._send(200, local_page(link), "text/html; charset=utf-8")
            elif u.path == "/status" and is_loopback(c):
                self._json(200, status(link))
            else:
                self._send(404, b"not found", "text/plain")

        def do_POST(self) -> None:
            c = self._client()
            if c is None:
                return
            if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Length") is None:
                self.close_connection = True  # a chunked body is not read here: the client must say its length
                self._json(411, {"error": "length required"})
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if not 0 <= n <= MAX_BODY:
                self.close_connection = True
                self._json(413, {"error": "too big"})
                return
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._json(400, {"error": "bad request"})
                return
            path = urlsplit(self.path).path
            if path == "/link/hello":
                self._json(*link.hello(body))
            elif path == "/link/finish":
                self._json(*link.finish(body, c))
            else:
                self._json(404, {"error": "not found"})

    return H


def serve(link: Link, addresses: list[str], port: int, handler=None) -> list[ThreadingHTTPServer]:
    """One server per address (the Wi-Fi address and loopback); never 0.0.0.0."""
    out = []
    for a in dict.fromkeys(addresses):
        try:
            srv = ThreadingHTTPServer((a, port), handler or make_handler(link))
        except OSError:
            continue
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, args=(0.1,), daemon=True, name=f"link {a}").start()
        out.append(srv)
    return out


# --- what runs after the pairing

class Say:
    """Lines from several threads, one at a time."""

    def __init__(self, out: Callable[[str], object]) -> None:
        self.out, self.lock = out, threading.Lock()

    def __call__(self, line: str, *, stamp: bool = True) -> None:
        with self.lock:
            self.out((datetime.now().strftime("%H:%M ") if stamp else "") + line)


def mirror_pass(link: Link, dest: Path, say: Say, last: list[str | None], raw_only: bool = False) -> None:
    """One pull_phone.py pass to wherever the phone is now; a problem is said once, not every pass."""
    t = link.target()
    if t is None:
        return
    host, port, token = t
    now = datetime.now().astimezone()
    try:
        rep = pp.pull(pp.Phone(f"http://{host}:{port}", token), dest, raw_only=raw_only, now=now)
    except pp.Refused as e:
        link.answering = False
        msg = (f"The phone at {host} refused ({e}): it got a new code. It tells this laptop within 5 minutes while "
               "Share on Wi-Fi is on; or scan a new code (Enter).")
    except pp.PhoneError as e:
        link.answering = False
        msg = f"No answer from the phone at {host} ({e}). Is Share on Wi-Fi on? Trying again."
    else:
        if not link.answering:
            say(f"Connected: copying from the phone at {host}.")
        link.answering = True
        last[0] = None
        for line in pp.summary(rep, dest, now):
            say(line, stamp=False)
        return
    if msg != last[0]:
        say(msg)
        last[0] = msg


def mirror_loop(link: Link, dest: Path, every_min: float, say: Say, stop: threading.Event,
                raw_only: bool = False) -> None:
    last: list[str | None] = [None]
    while not stop.is_set():
        try:
            mirror_pass(link, dest, say, last, raw_only)
        except Exception as e:  # a bug in a pass must not end the mirror
            say(f"PROBLEM in the copy: {type(e).__name__}: {e}")
        link.changed.wait(max(every_min, 0.1) * 60)
        link.changed.clear()


def start_pages(link: Link, port: int, rec_dir: Path, say: Say) -> ThreadingHTTPServer | None:
    """page_server.py's pages on this laptop only, pointed at wherever the phone is now."""
    def handler():
        t = link.target()
        host, p, token = t if t is not None else ("127.0.0.1", 9, None)  # no phone yet: "reconnecting"
        return page_server.make_handler(host, p, rec_dir, token)

    try:
        srv = ThreadingHTTPServer(("127.0.0.1", port), handler())
    except OSError as e:
        say(f"The live pages are not started: port {port} is taken ({e.strerror}). Close the other page server, "
            "or use --pages-port.")
        return None
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True, name="pages").start()
    link.listeners.append(lambda *_: setattr(srv, "RequestHandlerClass", handler()))  # new requests go there
    return srv


def show_code(link: Link, say: Say, qr: str, color: bool) -> None:
    code = link.new_code()
    text = link.app_link(code) if qr == "app" else link.web_link(code)
    until = datetime.fromtimestamp(time.time() + CODE_LIFE).strftime("%H:%M")
    say("Connect the phone: open its camera, point it at this code, tap the link, then Open EEG Tracker, "
        "then Connect.", stamp=False)
    say(qr_code.terminal(qr_code.encode(text), color=color), stamp=False)
    say(f"The code works once, until {until}. Enter: a new code. Bigger: http://127.0.0.1:{link.port}/ in this "
        f"laptop's browser. The same as a link: {text}", stamp=False)


def _print(line: str) -> None:
    print(line, flush=True)  # also when the output goes to a file (the assistant runs it in the background)


def main(argv: list[str] | None = None, out: Callable[[str], object] = _print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dest", type=Path, default=ip.DEFAULT_DEST, help="where to copy (default: <repo>/_local)")
    ap.add_argument("--every", type=float, default=2, help="minutes between copies (default 2)")
    ap.add_argument("--raw-only", action="store_true", help="copy only the raw recordings")
    ap.add_argument("--no-mirror", action="store_true", help="pair and keep the pages, but do not copy files")
    ap.add_argument("--no-pages", action="store_true", help="do not serve the live pages")
    ap.add_argument("--address", help="this laptop's Wi-Fi address as the phone reaches it (default: found)")
    ap.add_argument("--port", type=int, default=PORT, help=f"the pairing port (default {PORT})")
    ap.add_argument("--pages-port", type=int, default=PAGES_PORT, help=f"the live pages' port (default {PAGES_PORT})")
    ap.add_argument("--qr", choices=("web", "app"), default="web",
                    help="web: a link any camera opens (default); app: the app link itself")
    ap.add_argument("--phone-at", help="reach the phone here instead (adb forward: http://127.0.0.1:8765)")
    ap.add_argument("--name", help="this laptop's name on the phone (default: the computer's name)")
    ap.add_argument("--recordings", type=Path, help="the page server's results folder (default: <dest>/recordings)")
    a = ap.parse_args(argv)

    address = a.address or lan_address()
    if not address or not allowed_client(address):
        out("This laptop has no home-network address. Join the same Wi-Fi as the phone, then run this again.")
        return 2
    name = re.sub(r"[^\w .-]", "", a.name or socket.gethostname())[:40] or "laptop"
    link = Link(a.dest / "phone" / "link.json", name=name, host=address, port=a.port, phone_at=a.phone_at)
    servers = serve(link, [address, "127.0.0.1"], a.port)
    if not any(s.server_address[0] == "127.0.0.1" for s in servers):
        out(f"Port {a.port} is taken: is phone_link.py already running in another window?")
        for s in servers:
            s.shutdown()
        return 2
    say = Say(out)
    if not any(s.server_address[0] == address for s in servers):
        say(f"(Listening on this laptop only: {address} is not one of its addresses.)", stamp=False)

    def told(phone: PhoneAt, via: str, moved: bool) -> None:
        if via == "code":
            say(f"Paired with the phone at {phone.address}. It remembers this laptop: next time just run this "
                "command and switch Share on Wi-Fi on.")
        elif moved:
            say(f"The phone says it is at {phone.address} now.")

    link.listeners.append(told)
    stop = threading.Event()
    if not a.no_pages:
        if start_pages(link, a.pages_port, a.recordings or a.dest / "recordings", say):
            say(f"Live pages: http://localhost:{a.pages_port}/ (on this laptop).", stamp=False)
    if not a.no_mirror:
        threading.Thread(target=mirror_loop, args=(link, a.dest, a.every, say, stop, a.raw_only), daemon=True,
                         name="mirror").start()
    t = link.target()
    if t is not None:
        say(f"Remembered phone at {t[0]}: copying whenever it answers.", stamp=False)
    color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    show_code(link, say, a.qr, color)
    asked = threading.Event()
    if sys.stdin is not None and sys.stdin.isatty():
        def keys() -> None:
            for _ in sys.stdin:
                asked.set()
        threading.Thread(target=keys, daemon=True, name="keys").start()
    renew_until = time.monotonic() + RENEW_FOR
    try:
        while True:
            time.sleep(0.5)
            if asked.is_set():
                asked.clear()
                renew_until = time.monotonic() + RENEW_FOR
                show_code(link, say, a.qr, color)
            elif (not link.code_valid() and link.code is not None and not link.answering
                  and time.monotonic() < renew_until):
                say("That code has expired; here is a new one.", stamp=False)
                show_code(link, say, a.qr, color)
            elif link.code is not None and not link.code_valid():
                link.code = None
                if not link.answering:
                    say("No code shown any more: press Enter for a new one.")
    except KeyboardInterrupt:
        return 0
    finally:
        stop.set()
        link.changed.set()
        for s in servers:
            s.shutdown()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
