"""Connect the phone to this laptop with one scan, then keep its files mirrored and its live pages up.

usage: python3 scripts/phone_link.py [--dest _local] [--every 2] [--no-pages] [--no-mirror]
       less common: [--address <this laptop's Wi-Fi address>] [--port 8771] [--pages-port 8770] [--qr web|app]
                    [--phone-at http://127.0.0.1:8765] [--name <shown on the phone>]
                    [--push-port 8772] [--no-push] [--push-loopback-home]
       the tray's:  --keep   (a remembered phone, quietly: DECISIONS 677)

The owner's steps (app/README.md, "Share on Wi-Fi"): run this, point the phone's camera at the code it shows, tap the
link, tap **Open EEG Tracker**, then **Connect**. Leave the window open. Next time: run it again (or let the tray run
it); it finds the phone by itself whenever Share on Wi-Fi is on.

How it works (DECISIONS rows 530-539, 750-759; docs/phone-link.md):
- The code holds `http://<this laptop's Wi-Fi address>:8771/p#s=<one-time code>`: any camera opens it in the
  browser, which never sends what follows `#`; the page's script opens the app (`eegtracker://pair?...`) with it.
  `--qr app` puts the app link in the code itself instead.
- On Connect the app checks that this laptop knows the one-time code (an HMAC over its random nonce, so the code is
  never sent back) and proves it knows it too; then both work out the same key from the code and the two nonces
  (phone_auth.derive_key). Neither the code, the key nor the phone's token crosses the Wi-Fi. The one-time code works
  once, for 5 minutes; a new one is shown while no phone answers (Enter shows a new one at any time). Only while a
  code is shown does this listen on the Wi-Fi address; otherwise on 127.0.0.1 only.
- The laptop takes the phone's address from the connection itself, not from what the phone thinks it has, and
  records its home network (its router's address and hardware address: home_id).
- Both sides remember each other: `<dest>/phone/link.json` here (version 2: the key, the phone's address and port,
  home; no token; file mode 600), the app's private settings on the phone. Every request to the phone is signed with
  the key, says whether this laptop is at home now, and the phone's answer must prove the key (phone_auth). At home,
  when the phone stops answering at its address, this looks round the local /24 for it at most every 10 minutes. A
  version 1 file (the first pairing, whose key had crossed the Wi-Fi) is not used: pair once more.
- Then it does what scripts/pull_phone.py does (a copy every --every minutes, raw nights first; the same files and
  rules, and the acks of what this laptop holds, under the pairing's key: DECISIONS 690-699) and serves the live
  pages like scripts/page_server.py at http://localhost:8770/ (on this laptop only).
- `--keep` is how the laptop tray runs it whenever a phone is paired (DECISIONS 677): no window and no code unless
  one is asked for on this laptop (`POST http://127.0.0.1:8771/new`: the page's button, or the tray's "Pair phone…",
  which then opens the page); while that code is shown it also listens on the laptop's Wi-Fi address (none when the
  laptop has no home-network address). It ends by itself when the pairing is forgotten (`link.json` deleted).
- With `--keep` the phone may also send its files by itself (scripts/push_receiver.py, port 8772): it opens the
  connection, signs every request with the pairing's key, and this laptop only takes what it lacks, through the same
  pull_phone.py pass and lock. That port listens on 127.0.0.1 and, only while this laptop is on its home network, on
  its home-network address. When the phone does not answer at its port, its three fallback ports (8766-8768) are
  tried at the same address before the network is looked around.
- Nothing is reachable beyond this laptop and its local network: it listens on 127.0.0.1 (and on the Wi-Fi address
  while a code is shown), answers local-network addresses only (10.x, 172.16-31.x, 192.168.x, 169.254.x) and checks
  `Host` and `Origin` (scripts/local_http.py). Plain HTTP, like Share on Wi-Fi itself: a paired phone shares only on
  the home Wi-Fi or one allowed for 12 hours on the phone.

Standard library only (with scripts/qr_code.py, pull_phone.py, page_server.py and import_phone.py).
"""
from __future__ import annotations

import argparse, hashlib, hmac, html, ipaddress, json, os, re, secrets, socket, sys, threading, time
from dataclasses import dataclass
from datetime import datetime
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Callable
from urllib.parse import quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find the other scripts even under `python3 -I`
import import_phone as ip  # noqa: E402
import local_http  # noqa: E402
import phone_auth as pa  # noqa: E402
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
VERSION = 2  # pairing v2: the key is worked out on both sides, never sent (DECISIONS 753)
NONCE = pa.NONCE
MAX_BODY = 4096
HOME_CHECK_S = 30.0  # how long a look at this laptop's network (its router) is trusted
SWEEP_EVERY_S = 600.0  # at most one look around the home network for a phone that moved, this often
SWEEP_TIMEOUT_S = 0.4
PHONE_PORTS = (8765, 8766, 8767, 8768)  # the phone's Share on Wi-Fi port, and the ones it falls back to when taken

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


def gateway(route: Path = Path("/proc/net/route")) -> tuple[str, str] | None:
    """(interface, address) of the default route's router, never through a VPN or a container bridge; None where the
    kernel's table cannot be read (not Linux) or there is none."""
    try:
        rows = route.read_text().splitlines()[1:]
    except OSError:
        return None
    for row in rows:
        f = row.split()
        if len(f) < 4 or f[1] != "00000000" or _NOT_WIFI.match(f[0]):
            continue
        try:
            if not int(f[3], 16) & 0x2:  # RTF_GATEWAY
                continue
            return f[0], socket.inet_ntoa(int(f[2], 16).to_bytes(4, "little"))
        except (ValueError, OSError):
            continue
    return None


def _mac(address: str, arp: Path) -> str | None:
    try:
        rows = arp.read_text().splitlines()[1:]
    except OSError:
        return None
    for row in rows:
        f = row.split()
        if len(f) >= 4 and f[0] == address and int(f[2], 16) & 0x2 and f[3] != "00:00:00:00:00:00":
            return f[3].lower()
    return None


def home_id(route: Path = Path("/proc/net/route"), arp: Path = Path("/proc/net/arp"), *, poke: bool = True) -> str | None:
    """Which network this laptop is on, by its router: `<gateway address> <its hardware (MAC) address>`
    (DECISIONS 751). A cafe's router at the same 192.168.1.1 has another MAC. None while it cannot be told."""
    g = gateway(route)
    if g is None:
        return None
    mac = _mac(g[1], arp)
    if mac is None and poke:
        try:  # one datagram to the router's discard port makes the kernel learn its MAC; nothing else is sent
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.sendto(b"", (g[1], 9))
            time.sleep(0.2)
        except OSError:
            pass
        mac = _mac(g[1], arp)
    return None if mac is None else f"{g[1]} {mac}"


def sweep_hosts(address: str | None) -> list[str]:
    """Where to look for a phone that moved: the other addresses of the /24 around this laptop's home address."""
    a = _v4(address or "")
    if a is None or not is_lan(str(a)):
        return []
    net = ipaddress.ip_network(f"{a}/24", strict=False)
    return [str(h) for h in net.hosts() if h != a]


def _port_open(host: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def find_phone(key: str, port: int, hosts: list[str], *, timeout: float = SWEEP_TIMEOUT_S) -> str | None:
    """The address among [hosts] where the paired phone answers: the port is open there and the answer to a signed
    `GET /who` proves the pairing's key. Others learn only that this laptop asked (a signature they cannot use)."""
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=64) as pool:
        open_ = [h for h, ok in zip(hosts, pool.map(lambda h: _port_open(h, port, timeout), hosts)) if ok]
    for h in open_:
        try:
            if pp.Phone(f"http://{h}:{port}", key=key, home=True).who() is not None:
                return h
        except pp.PhoneError:
            continue
    return None


@dataclass(frozen=True)
class PhoneAt:
    address: str
    port: int


def _now_text() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Link:
    """The pairing: the one-time code, the key shared with the paired phone, where the phone is, and the network
    this laptop paired on."""

    def __init__(self, store: Path, *, name: str, host: str, port: int = PORT, phone_at: str | None = None,
                 clock: Callable[[], float] = time.monotonic, home_of: Callable[[], str | None] = home_id) -> None:
        self.store, self.name, self.host, self.port = store, name, host, port
        self.override = phone_at
        self.clock = clock
        self.home_of = home_of
        self.lock = threading.Lock()
        self.changed = threading.Event()  # paired, or the phone found at a new address: the mirror passes at once
        self.listeners: list[Callable[[PhoneAt, bool], None]] = []  # (the phone, paired now) at pairing or a move
        self.code: str | None = None
        self.code_until = 0.0
        self.answering = False  # the last mirror pass reached the phone
        self.sharing: str | None = None  # what the phone said of its Wi-Fi: home, here (allowed by hand), paused
        self.last_copy: str | None = None  # when the last pass reached the phone (local time, ISO)
        self.last_push: str | None = None  # when the phone last sent its files by itself (push_receiver.py)
        self.swept = -1e18  # when the home network was last looked around for the phone
        self._nonces: dict[str, tuple[str, float]] = {}  # laptop nonce -> (phone nonce, until)
        self.key: str | None = None
        self.phone: PhoneAt | None = None
        self.home: str | None = None  # home_id() at pairing
        self.home_checked = -1e18
        self._at_home = False
        self.old = False  # link.json holds a pairing of the first version: one new scan replaces it
        self._paired: str | None = None
        self._load()

    # --- the one-time code
    def new_code(self) -> str:
        with self.lock:
            self.code = secrets.token_urlsafe(16)  # 128 bits
            self.code_until = self.clock() + CODE_LIFE
            self._nonces = {}
            return self.code

    def code_valid(self, code: str | None = None) -> bool:
        with self.lock:
            ok = self.code is not None and self.clock() < self.code_until
            return ok and (code is None or hmac.compare_digest(code.encode(), (self.code or "").encode()))

    def web_link(self, code: str) -> str:
        """The QR code's link: the code after `#`, which a browser keeps to itself (DECISIONS 753)."""
        return f"http://{self.host}:{self.port}/p#s={code}"

    def app_link(self, code: str) -> str:
        return f"{SCHEME}://pair?h={self.host}&p={self.port}&s={code}&n={quote(self.name, safe='')}"

    def intent_prefix(self) -> str:
        """Chrome's form of the app link up to the code, and what follows it: the scan page's script puts the code
        between the two (it opens the app itself, never another app, or the install hint page)."""
        return f"intent://pair?h={self.host}&p={self.port}&s="

    def intent_suffix(self) -> str:
        fallback = quote(f"http://{self.host}:{self.port}/noapp", safe="")
        return (f"&n={quote(self.name, safe='')}#Intent;scheme={SCHEME};package={APP_PACKAGE};"
                f"S.browser_fallback_url={fallback};end")

    # --- the pairing
    def hello(self, body: object) -> tuple[int, dict]:
        """The phone's first step: its nonce. The answer proves this laptop knows the code."""
        if isinstance(body, dict) and body.get("v") == 1:
            return 400, {"error": "old app"}
        if not isinstance(body, dict) or body.get("v") != VERSION:
            return 400, {"error": "bad request"}
        theirs = body.get("nonce")
        if not isinstance(theirs, str) or not NONCE.fullmatch(theirs):
            return 400, {"error": "bad request"}
        with self.lock:
            code = self.code if self.code is not None and self.clock() < self.code_until else None
            if code is None:
                return 410, {"error": "expired"}
            now = self.clock()
            self._nonces = {k: v for k, v in self._nonces.items() if v[1] > now}
            while len(self._nonces) >= 64:
                self._nonces.pop(next(iter(self._nonces)))
            mine = secrets.token_urlsafe(16)
            self._nonces[mine] = (theirs, now + NONCE_LIFE)
            return 200, {"v": VERSION, "nonce": mine, "proof": pa.link_proof(code, "laptop", theirs, mine),
                         "name": self.name}

    def finish(self, body: object, client: str) -> tuple[int, dict]:
        """The phone's second step: its proof and its Share on Wi-Fi port. Both sides work the key out."""
        if not isinstance(body, dict) or body.get("v") != VERSION:
            return 400, {"error": "bad request"}
        mine, given, port = body.get("nonce"), body.get("proof"), body.get("port")
        if not (isinstance(mine, str) and isinstance(given, str)
                and isinstance(port, int) and not isinstance(port, bool) and 1024 <= port <= 65535):
            return 400, {"error": "bad request"}
        home = self.home_of()  # outside the lock: it may wait a moment for the router's MAC
        with self.lock:
            entry = self._nonces.pop(mine, None)  # one try per hello
            if entry is None or entry[1] <= self.clock():
                return 403, {"error": "start again"}
            code = self.code if self.code is not None and self.clock() < self.code_until else None
            if code is None:
                return 410, {"error": "expired"}
            if not hmac.compare_digest(pa.link_proof(code, "phone", mine, entry[0]).encode(), given.encode()):
                return 403, {"error": "wrong proof"}
            self.code = None  # used: it never works again
            self._nonces = {}
            self.key = pa.derive_key(code, entry[0], mine)
            self.home, self.home_checked, self._at_home = home, self.clock(), home is not None
            self.old = False
            address = "127.0.0.1" if is_loopback(client) else str(_v4(client))
            phone = self.phone = PhoneAt(address, port)
            self.sharing = None
            self._save(paired=True)
            answer = {"v": VERSION, "name": self.name, "confirm": pa.confirm(self.key, entry[0], mine)}
        self.changed.set()  # the mirror passes at once
        for f in list(self.listeners):
            f(phone, True)
        return 200, answer

    def forget(self) -> None:
        """The pairing file was deleted (the tray's "Forget the phone"): the phone and the key go from memory too, so
        nothing is copied any more and the phone hears nothing from this laptop."""
        with self.lock:
            self.phone = None
            self.key = None
            self._paired = None
        self.changed.set()

    # --- where the phone is, and where this laptop is
    def target(self) -> tuple[str, int] | None:
        """(host, port) of the phone's Share on Wi-Fi; None before any pairing."""
        with self.lock:
            p = self.phone
            if p is None or self.key is None:
                return None
            if self.override:
                u = urlsplit(self.override if "://" in self.override else f"http://{self.override}")
                return (u.hostname or "127.0.0.1", u.port or p.port)
            return (p.address, p.port)

    def moved_to(self, address: str, port: int | None = None) -> None:
        """The phone was found at a new address, or at another port (by its proof of the key)."""
        with self.lock:
            if self.phone is None or self.phone == PhoneAt(address, port or self.phone.port):
                return
            phone = self.phone = PhoneAt(address, port or self.phone.port)
            self._save(paired=False)
        for f in list(self.listeners):
            f(phone, False)

    def at_home(self) -> bool:
        """Whether this laptop is on the network where it paired (its router), looked at every 30 s at most."""
        if self.home is None:
            return False
        now = self.clock()
        if now - self.home_checked >= HOME_CHECK_S:
            self._at_home = self.home_of() == self.home
            self.home_checked = now
        return self._at_home

    # --- link.json
    def _load(self) -> None:
        try:
            raw = json.loads(self.store.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        if not isinstance(raw, dict):
            return
        if raw.get("version") != VERSION:
            self.old = raw.get("phone") is not None or raw.get("laptop_key") is not None
            return
        key, ph, home = raw.get("key"), raw.get("phone"), raw.get("home")
        if not (isinstance(key, str) and pa.KEY.fullmatch(key)):
            return
        self.key = key
        if (isinstance(ph, dict) and isinstance(ph.get("address"), str) and allowed_client(ph["address"])
                and isinstance(ph.get("port"), int) and not isinstance(ph.get("port"), bool)
                and 1024 <= ph["port"] <= 65535):
            self.phone = PhoneAt(ph["address"], ph["port"])
        self.home = home if isinstance(home, str) else None
        self._paired = raw.get("paired") if isinstance(raw.get("paired"), str) else None

    def _save(self, *, paired: bool) -> None:
        if paired or not self._paired:
            self._paired = _now_text()
        p = self.phone
        data = {"version": VERSION, "key": self.key, "paired": self._paired, "home": self.home,
                "phone": None if p is None else {"address": p.address, "port": p.port}}
        self.store.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.store.with_name(self.store.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.store)


def paired_phone(store: Path) -> tuple[str, int, str, str | None] | None:
    """(address, port, key, home) of the phone paired in [store] (link.json, version 2); None without one. What the
    tray and laptop_work.py read."""
    try:
        raw = json.loads(store.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict) or raw.get("version") != VERSION:
        return None
    key, ph, home = raw.get("key"), raw.get("phone"), raw.get("home")
    if not (isinstance(key, str) and pa.KEY.fullmatch(key) and isinstance(ph, dict)):
        return None
    addr, port = ph.get("address"), ph.get("port")
    if not (isinstance(addr, str) and allowed_client(addr) and isinstance(port, int) and not isinstance(port, bool)
            and 1024 <= port <= 65535):
        return None
    return addr, port, key, home if isinstance(home, str) else None


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


def landing_page(link: Link) -> bytes:
    """What the phone's browser shows after the scan: one button that opens the app. The code is in the link's `#`
    part, which the browser never sent here: the page's script puts it into the app link (DECISIONS 753)."""
    js = (f"var m=/[#&]s=([A-Za-z0-9_-]{{16,64}})/.exec(location.hash||''),go=document.getElementById('go'),"
          f"alt=document.getElementById('alt');"
          f"if(m){{go.href={json.dumps(link.intent_prefix())}+m[1]+{json.dumps(link.intent_suffix())};"
          f"alt.href={json.dumps(f'{SCHEME}://pair?h={link.host}&p={link.port}&s=')}+m[1]+"
          f"{json.dumps('&n=' + quote(link.name, safe=''))};setTimeout(function(){{location.href=go.href}},300)}}"
          f"else{{document.getElementById('msg').textContent='This link has no code: scan the laptop\u2019s code "
          f"again.'}}")
    return _page("Connect to EEG Tracker", (
        f"<h1>Connect this phone</h1><p id=\"msg\">to the laptop <b>{html.escape(link.name)}</b>.</p>"
        '<a class="go" id="go" href="#">Open EEG Tracker</a>'
        "<p>The app asks “Connect to this laptop?”: tap <b>Connect</b>.</p>"
        '<p class="small">Nothing opens? Install the EEG Tracker app first, then scan again. Another browser: '
        '<a id="alt" href="#" style="color:#e9e4d8">open the app this way</a>.</p>'
        f"<script>{js}</script>"))


def noapp_page() -> bytes:
    return _page("EEG Tracker", "<h1>The app is not on this phone</h1><p>Install the EEG Tracker app (the APK the "
                 "assistant gave you), open it once, then scan the laptop's code again.</p>")


def status(link: Link) -> dict:
    """phone_link.py's own status on this laptop (the tray reads it): whether the phone answers, what it said of its
    Wi-Fi (home, here: allowed there by hand, paused), when it was last copied from, whether this laptop is on the
    network where it paired, and whether an old pairing needs one new scan."""
    t = link.target()
    return {"connected": link.answering, "phone": None if t is None else f"{t[0]}:{t[1]}",
            "code_valid": link.code_valid(), "name": link.name, "sharing": link.sharing,
            "last_copy": link.last_copy, "last_push": link.last_push, "home": link.at_home(), "repair": link.old}


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
        parts.append(f'<p class="small">The code works once, for 5 minutes. Then {_NEW_BUTTON.format("show a new one")}'
                     '</p>')
    else:
        parts.append(f'<p class="small">No code right now: {_NEW_BUTTON.format("show one")} (only to pair a phone for '
                     "the first time, or another phone).</p>")
    return _page("EEG Tracker: connect", "".join(parts), refresh=None if code is None else 3)


# A new code only by POST from this laptop's own page (or the tray): a link or another site's page cannot make one.
_NEW_BUTTON = ('<form method="post" action="/new" style="display:inline"><button type="submit" style="font:inherit;'
               'color:#e9e4d8;background:none;border:0;padding:0;text-decoration:underline;cursor:pointer">{}</button>'
               "</form>")


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
            # its own Host (or the address the QR code names: the emulator says 10.0.2.2), no other site's Origin
            if not local_http.guard(self, extra_hosts=(link.host,)):
                return None
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
                self._send(200, landing_page(link), "text/html; charset=utf-8")
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
            raw = self.rfile.read(n)
            path = urlsplit(self.path).path
            try:
                body = None if path == "/new" else json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._json(400, {"error": "bad request"})
                return
            if path == "/new" and is_loopback(c):  # "show a code": this laptop's page or the tray (DECISIONS 750)
                if not link.code_valid():
                    link.new_code()
                self.send_response(303)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
            elif path == "/link/hello":
                self._json(*link.hello(body))
            elif path == "/link/finish":
                self._json(*link.finish(body, c))
            else:
                self._json(404, {"error": "not found"})

    return H


def serve(link: Link, addresses: list[str], port: int, handler=None) -> list[local_http.LocalServer]:
    """One server per address (loopback, and the Wi-Fi address while a code is shown); never 0.0.0.0."""
    out = []
    for a in dict.fromkeys(addresses):
        try:
            srv = local_http.LocalServer((a, port), handler or make_handler(link))
        except OSError:
            continue
        threading.Thread(target=srv.serve_forever, args=(0.1,), daemon=True, name=f"link {a}").start()
        out.append(srv)
    return out


class LanListener:
    """The pairing port on this laptop's home-network address, only while a one-time code is shown (DECISIONS 750):
    the rest of the time nothing of this laptop's link answers on the Wi-Fi. `sync` is called twice a second."""

    def __init__(self, link: Link, port: int, handler=None) -> None:
        self.link, self.port, self.handler = link, port, handler
        self.servers: list[local_http.LocalServer] = []
        self.bound: str | None = None

    def sync(self, address: str | None) -> None:
        want = address if address and address != "127.0.0.1" and self.link.code_valid() else None
        if want == self.bound and (want is None or self.servers):
            return
        self.close()
        if want is not None:
            self.servers = serve(self.link, [want], self.port, self.handler)
            self.bound = want if self.servers else None

    def close(self) -> None:
        for srv in self.servers:
            srv.shutdown(); srv.server_close()
        self.servers, self.bound = [], None


# --- what runs after the pairing

class Say:
    """Lines from several threads, one at a time."""

    def __init__(self, out: Callable[[str], object]) -> None:
        self.out, self.lock = out, threading.Lock()

    def __call__(self, line: str, *, stamp: bool = True) -> None:
        with self.lock:
            self.out((datetime.now().strftime("%H:%M ") if stamp else "") + line)


def phone_of(link: Link) -> pp.Phone | None:
    """The paired phone as pull_phone.py reaches it: every request signed with the key, never the token
    (DECISIONS 751)."""
    t, key = link.target(), link.key
    if t is None or key is None:
        return None
    return pp.Phone(f"http://{t[0]}:{t[1]}", key=key, home=link.at_home)


def mirror_pass(link: Link, dest: Path, say: Say, last: list[str | None], raw_only: bool = False, *,
                hosts: Callable[[], list[str]] | None = None) -> None:
    """One pull_phone.py pass to wherever the phone is now; a problem is said once, not every pass. When the phone
    does not answer at its address while this laptop is on its home network, the network is looked around for it
    (at most every 10 minutes): it may have a new address. No addresses go into what is said (DECISIONS 757)."""
    phone = phone_of(link)
    if phone is None:
        return
    now = datetime.now().astimezone()
    try:
        try:
            rep = pp.pull(phone, dest, raw_only=raw_only, now=now, key=link.key)
        except pp.PhoneError as e:
            if isinstance(e, pp.Paused) or not (_other_port(link) or _look_around(link, hosts)):
                raise
            phone = phone_of(link)
            assert phone is not None
            rep = pp.pull(phone, dest, raw_only=raw_only, now=now, key=link.key)
    except pp.NotThePhone:
        link.answering = False
        msg = ("Something at the phone's address did not prove this pairing's key: nothing is copied from it. Is the "
               "phone on this network? Pair phone… again if the phone forgot this laptop.")
    except pp.Refused as e:
        link.answering = False
        msg = f"The phone refused this laptop ({e}). Pair phone… again (one scan) if the phone forgot it."
    except pp.Paused:
        link.answering = False
        link.sharing = "paused"
        msg = ("The phone is not sharing on this Wi-Fi (not its home network, and not allowed there by hand): "
               "nothing is copied here.")
    except pp.PhoneError as e:
        link.answering = False
        msg = f"No answer from the phone ({e}). Is Share on Wi-Fi on? Trying again."
    else:
        if not link.answering:
            say("Connected: copying from the phone.")
        link.answering = True
        link.sharing = rep.here or link.sharing
        link.last_copy = datetime.now().astimezone().isoformat(timespec="seconds")
        last[0] = None
        for line in pp.summary(rep, dest, now):
            say(line, stamp=False)
        return
    if msg != last[0]:
        say(msg)
        last[0] = msg


def _other_port(link: Link) -> bool:
    """The phone's server takes one of three other ports when its own is taken: they are tried at the same address
    with a signed `GET /who`. True when one proved the key (link.json then holds it)."""
    t, key = link.target(), link.key
    if t is None or key is None or link.override:
        return False
    for port in PHONE_PORTS:
        if port == t[1] or not _port_open(t[0], port, SWEEP_TIMEOUT_S):
            continue
        try:
            if pp.Phone(f"http://{t[0]}:{port}", key=key, home=link.at_home).who() is not None:
                link.moved_to(t[0], port)
                return True
        except pp.PhoneError:
            continue
    return False


def _look_around(link: Link, hosts: Callable[[], list[str]] | None) -> bool:
    """At home, at most every SWEEP_EVERY_S: the phone looked for on this laptop's network by its proof of the key.
    True when it was found at a new address (link.json then holds it)."""
    t, key = link.target(), link.key
    if t is None or key is None or link.override or not link.at_home():
        return False
    now = link.clock()
    if now - link.swept < SWEEP_EVERY_S:
        return False
    link.swept = now
    found = find_phone(key, t[1], [h for h in (hosts() if hosts else sweep_hosts(link.host)) if h != t[0]])
    if found is None:
        return False
    link.moved_to(found)
    return True


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


def start_pages(link: Link, port: int, rec_dir: Path, say: Say) -> local_http.LocalServer | None:
    """page_server.py's pages on this laptop only, pointed at wherever the phone is now, every request passed on
    signed with the pairing's key (DECISIONS 751)."""
    def handler():
        t = link.target()
        host, p = t if t is not None else ("127.0.0.1", 9)  # no phone yet: "reconnecting"
        return page_server.make_handler(host, p, rec_dir, key=link.key, home=link.at_home)

    try:
        srv = local_http.LocalServer(("127.0.0.1", port), handler())
    except OSError as e:
        say(f"The live pages are not started: port {port} is taken ({e.strerror}). Close the other page server, "
            "or use --pages-port.")
        return None
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
        "laptop's browser.", stamp=False)  # the code itself is never written out: the log keeps it


def start_push(link: Link, a: argparse.Namespace, say: Say, after: Callable[[bool], object] | None = None):
    """The receiver of what the phone sends by itself (scripts/push_receiver.py), on this laptop's own address; its
    listener, or None when the port is taken. [after] is called with "something changed" after each of its passes."""
    import push_receiver
    r = push_receiver.Receiver(link, a.dest, say, client_ok=allowed_client, is_loopback=is_loopback,
                               allow_loopback_home=a.push_loopback_home, raw_only=a.raw_only, after=after)
    listener = push_receiver.Listener(r, a.push_port)
    if listener.loop is None:
        say(f"The phone cannot send its files by itself: port {a.push_port} is taken (--push-port). The copying from "
            "this laptop goes on.")
        return None
    return listener


KEEP_LOOK_S = 30.0  # --keep: how often this laptop's home-network address is looked at again


def keep(a: argparse.Namespace, out: Callable[[str], object], *, find: Callable[[], str | None] = lan_address,
         stop: threading.Event | None = None, look_s: float = KEEP_LOOK_S,
         clock: Callable[[], float] = time.monotonic) -> int:
    """--keep, the laptop tray's way (DECISIONS 677, 750): a remembered phone, kept with no window and no code. The pages
    and the copy as usual; this laptop's own port on 127.0.0.1 only, and on its home-network address only while a code
    asked for on this laptop is shown; it ends when `link.json` is deleted (the tray's "Forget the phone").
    3: no phone is paired; 2: the port is taken."""
    name = re.sub(r"[^\w .-]", "", a.name or socket.gethostname())[:40] or "laptop"
    store = a.dest / "phone" / "link.json"
    link = Link(store, name=name, host="127.0.0.1", port=a.port, phone_at=a.phone_at, clock=clock)
    if link.target() is None:
        out("No phone is paired here: run phone_link.py without --keep to pair one.")
        return 3
    loop = serve(link, ["127.0.0.1"], a.port)
    if not loop:
        out(f"Port {a.port} is taken: is phone_link.py already running?")
        return 2
    say = Say(out)
    stop = stop or threading.Event()
    lan = LanListener(link, a.port)
    push = None if a.no_push else start_push(link, a, say)
    home: list[str | None] = [None]   # this laptop's home-network address now, or None while there is none

    def look() -> None:
        addr = a.address or find()
        if not addr or not allowed_client(addr):
            if home[0] is not None:
                say("No home-network address now (Wi-Fi off?): the phone is copied from again when it is back.")
            home[0] = None
            return
        home[0] = addr
        link.host = addr  # what a new code's QR link names

    look()
    if home[0] is None:
        say("No home-network address yet (Wi-Fi off?): waiting for one.")
    if not a.no_pages:
        start_pages(link, a.pages_port, a.recordings or a.dest / "recordings", say)
    if not a.no_mirror:
        threading.Thread(target=mirror_loop, args=(link, a.dest, a.every, say, stop, a.raw_only), daemon=True,
                         name="mirror").start()
    say("Remembered phone: copying whenever it answers.")
    next_look = time.monotonic() + look_s
    try:
        while not stop.wait(0.5):
            if not store.exists():
                link.forget()
                say("The phone was forgotten here: stopping.")
                return 0
            if link.code is not None and not link.code_valid():
                link.code = None
            if time.monotonic() >= next_look:
                next_look = time.monotonic() + look_s
                look()
            if push is not None:
                push.sync(home[0])  # the phone's own sending: on the home network only while this laptop is there
            was = lan.bound
            lan.sync(home[0])
            if lan.bound != was:
                say("Listening for a phone to pair on the home network while the code is shown." if lan.bound else
                    "Not listening on the home network: no code is shown.")
        return 0
    finally:
        stop.set()
        link.changed.set()
        lan.close()
        if push is not None:
            push.close()
        for srv in loop:
            srv.shutdown(); srv.server_close()


def _print(line: str) -> None:
    print(line, flush=True)  # also when the output goes to a file (the assistant runs it in the background)


def parse(argv: list[str] | None = None) -> argparse.Namespace:
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
    ap.add_argument("--push-port", type=int, default=8772,
                    help="with --keep: the port the phone sends its files to by itself (default 8772)")
    ap.add_argument("--no-push", action="store_true", help="with --keep: do not take files the phone sends by itself")
    ap.add_argument("--push-loopback-home", action="store_true",
                    help="for tests and the emulator: a client on this computer counts as on the home network")
    ap.add_argument("--keep", action="store_true",
                    help="the tray's way: a remembered phone, quietly, following this laptop's address, until forgotten")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None, out: Callable[[str], object] = _print) -> int:
    a = parse(argv)
    if a.keep:
        return keep(a, out)

    address = a.address or lan_address()
    if not address or not allowed_client(address):
        out("This laptop has no home-network address. Join the same Wi-Fi as the phone, then run this again.")
        return 2
    name = re.sub(r"[^\w .-]", "", a.name or socket.gethostname())[:40] or "laptop"
    link = Link(a.dest / "phone" / "link.json", name=name, host=address, port=a.port, phone_at=a.phone_at)
    servers = serve(link, ["127.0.0.1"], a.port)
    if not servers:
        out(f"Port {a.port} is taken: is phone_link.py already running in another window?")
        return 2
    say = Say(out)
    lan = LanListener(link, a.port)

    def told(_phone: PhoneAt, paired: bool) -> None:
        if paired:
            say("Paired with the phone. It remembers this laptop: next time just run this command (or let the tray "
                "run it) and switch Share on Wi-Fi on.")
        else:
            say("Found the phone at a new address on the home network.")

    link.listeners.append(told)
    stop = threading.Event()
    if not a.no_pages:
        if start_pages(link, a.pages_port, a.recordings or a.dest / "recordings", say):
            say(f"Live pages: http://localhost:{a.pages_port}/ (on this laptop).", stamp=False)
    if not a.no_mirror:
        threading.Thread(target=mirror_loop, args=(link, a.dest, a.every, say, stop, a.raw_only), daemon=True,
                         name="mirror").start()
    if link.target() is not None:
        say("Remembered phone: copying whenever it answers.", stamp=False)
    elif link.old:
        say("This laptop was paired with the phone the old way: scan the code below once more.", stamp=False)
    color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    show_code(link, say, a.qr, color)
    lan.sync(address)
    if lan.bound is None:
        say(f"(Listening on this laptop only: {address} is not one of its addresses.)", stamp=False)
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
            lan.sync(address)  # the home network hears this laptop only while a code is shown (DECISIONS 750)
    except KeyboardInterrupt:
        return 0
    finally:
        stop.set()
        link.changed.set()
        lan.close()
        for s in servers:
            s.shutdown()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
