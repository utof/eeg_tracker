"""scripts/phone_link.py: what the QR code holds, the one-time code's life, the two-step handshake with its proofs,
the phone telling a new address later, what is kept in link.json, and the mirror and pages that follow the phone.
The phone's side here is a small client written from the protocol (the app's is app/lib/share/link.dart; both are
checked against the proofs in app/test/fixtures/phone_link.json)."""
import json
import secrets
import stat
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

import phone_link as pl
import pull_phone as pp
import qr_code
from test_pull_phone import STEM, TOKEN, FakePhone

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "app" / "test" / "fixtures" / "phone_link.json").read_text())


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def link(tmp_path: Path, clock: Clock) -> pl.Link:
    return pl.Link(tmp_path / "phone" / "link.json", name="my-laptop", host="192.168.1.10", clock=clock)


class Server:
    """The link's HTTP server on loopback; [client] is the address the laptop believes the phone has."""

    def __init__(self, link: pl.Link, client: str = "127.0.0.1") -> None:
        self.client = client
        self.srv = pl.serve(link, ["127.0.0.1"], 0, pl.make_handler(link, client_of=lambda _h: self.client))[0]
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def post(self, path: str, body: object) -> tuple[int, dict]:
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def get(self, path: str) -> tuple[int, str]:
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def close(self) -> None:
        self.srv.shutdown()
        self.srv.server_close()


@pytest.fixture
def server(link: pl.Link):
    s = Server(link)
    yield s
    s.close()


def phone_handshake(s: Server, via: str, secret: str, *, port: int = 8765, token: str = TOKEN,
                    tamper: bool = False) -> tuple[int, dict]:
    """The app's two steps: check the laptop's proof first, send the token only after it."""
    mine = secrets.token_urlsafe(16)
    code, hello = s.post("/link/hello", {"v": 1, "via": via, "nonce": mine})
    if code != 200:
        return code, hello
    if hello["proof"] != pl.proof(secret, "laptop", via, mine, hello["nonce"]):
        return -1, {"error": "the laptop did not prove the code: nothing sent"}
    given = pl.proof(secret, "phone", via, hello["nonce"], mine)
    if tamper:
        given = given[::-1]
    return s.post("/link/finish", {"v": 1, "via": via, "nonce": hello["nonce"], "proof": given, "port": port,
                                   "token": token})


def test_proofs_match_the_shared_vectors() -> None:
    for c in FIXTURE["proofs"]:
        assert pl.proof(c["secret"], "laptop", c["via"], c["phone_nonce"], c["laptop_nonce"]) == c["laptop_proof"]
        assert pl.proof(c["secret"], "phone", c["via"], c["laptop_nonce"], c["phone_nonce"]) == c["phone_proof"]


def test_what_the_qr_code_holds(link: pl.Link) -> None:
    code = link.new_code()
    assert len(code) == 22 and pl.NONCE.fullmatch(code)  # 128 bits, URL-safe
    web = link.web_link(code)
    assert web == f"http://192.168.1.10:8771/p?s={code}"
    assert TOKEN not in web and "token" not in web  # the phone's token is never in the code
    assert link.app_link(code) == f"eegtracker://pair?h=192.168.1.10&p=8771&s={code}&n=my-laptop"
    intent = link.intent_link(code)
    assert intent.startswith(f"intent://pair?h=192.168.1.10&p=8771&s={code}&n=my-laptop#Intent;scheme=eegtracker;")
    assert "package=io.github.utof.eeg_tracker;" in intent  # only the app itself may take it
    assert "S.browser_fallback_url=http%3A%2F%2F192.168.1.10%3A8771%2Fnoapp;end" in intent
    # the terminal drawing is that link: version 4 at level M, 21 lines with the quiet zone
    lines: list[str] = []
    pl.show_code(link, pl.Say(lines.append), "web", False)
    drawing = lines[1].split("\n")
    assert len(drawing) == 21
    assert qr_code.terminal(qr_code.encode(link.web_link(link.code or "")), color=False) == lines[1]
    assert lines[2].endswith(f"The same as a link: {link.web_link(link.code or '')}")
    lines.clear()
    pl.show_code(link, pl.Say(lines.append), "app", False)  # --qr app: the app link itself in the code
    assert lines[2].endswith(f"The same as a link: {link.app_link(link.code or '')}")
    assert qr_code.terminal(qr_code.encode(link.app_link(link.code or "")), color=False) == lines[1]


def test_the_code_expires_after_five_minutes_and_works_once(link: pl.Link, server: Server, clock: Clock) -> None:
    code = link.new_code()
    clock.t += pl.CODE_LIFE + 1
    assert server.post("/link/hello", {"v": 1, "via": "code", "nonce": "n" * 22}) == (410, {"error": "expired"})
    assert link.target() is None

    code = link.new_code()
    clock.t += pl.CODE_LIFE - 5
    status, answer = phone_handshake(server, "code", code)
    assert status == 200 and answer["name"] == "my-laptop" and len(answer["key"]) >= 32
    assert link.target() == ("127.0.0.1", 8765, TOKEN)  # loopback: the phone is reached through this laptop
    assert not link.code_valid() and link.code is None
    # used: the same code never works again
    assert phone_handshake(server, "code", code)[0] == 410


def test_a_hello_alone_does_not_expire_the_code_and_a_late_finish_fails(link: pl.Link, server: Server,
                                                                        clock: Clock) -> None:
    code = link.new_code()
    mine = "p" * 22
    _, hello = server.post("/link/hello", {"v": 1, "via": "code", "nonce": mine})
    clock.t += pl.NONCE_LIFE + 1
    late = server.post("/link/finish", {"v": 1, "via": "code", "nonce": hello["nonce"], "port": 8765,
                                        "token": TOKEN, "proof": pl.proof(code, "phone", "code", hello["nonce"], mine)})
    assert late == (403, {"error": "start again"})
    assert link.code_valid(code)  # still there for a fresh try
    assert phone_handshake(server, "code", code)[0] == 200


def test_proofs_both_ways(link: pl.Link, server: Server) -> None:
    code = link.new_code()
    # a phone holding another code finds the laptop's proof wrong and sends nothing
    assert phone_handshake(server, "code", "x" * 22)[0] == -1
    # a wrong phone proof is refused, the code stays, and that hello's nonce is spent
    mine = "q" * 22
    _, hello = server.post("/link/hello", {"v": 1, "via": "code", "nonce": mine})
    bad = {"v": 1, "via": "code", "nonce": hello["nonce"], "proof": "0" * 64, "port": 8765, "token": TOKEN}
    assert server.post("/link/finish", bad) == (403, {"error": "wrong proof"})
    good = dict(bad, proof=pl.proof(code, "phone", "code", hello["nonce"], mine))
    assert server.post("/link/finish", good) == (403, {"error": "start again"})
    assert link.target() is None and link.code_valid(code)
    # a finish with no hello at all
    assert server.post("/link/finish", dict(bad, nonce="z" * 22)) == (403, {"error": "start again"})


@pytest.mark.parametrize("body", [
    {"v": 2, "via": "code", "nonce": "n" * 22}, {"v": 1, "via": "other", "nonce": "n" * 22},
    {"v": 1, "via": "code", "nonce": "short"}, {"v": 1, "via": "code", "nonce": "bad nonce!" * 3}, ["not", "a", "map"],
])
def test_bad_hellos(link: pl.Link, server: Server, body: object) -> None:
    link.new_code()
    assert server.post("/link/hello", body)[0] == 400


@pytest.mark.parametrize("change", [{"port": 80}, {"port": True}, {"port": "8765"}, {"token": "a b"},
                                    {"token": "short"}, {"token": None}])
def test_bad_finishes(link: pl.Link, server: Server, change: dict) -> None:
    link.new_code()
    _, hello = server.post("/link/hello", {"v": 1, "via": "code", "nonce": "n" * 22})
    body = {"v": 1, "via": "code", "nonce": hello["nonce"], "proof": "0" * 64, "port": 8765, "token": TOKEN} | change
    assert server.post("/link/finish", body)[0] == 400


def test_too_big_and_not_json(link: pl.Link, server: Server) -> None:
    req = urllib.request.Request(server.base + "/link/hello", data=b"{" + b" " * 5000 + b"}")
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(req, timeout=5)
    assert e.value.code == 413
    req = urllib.request.Request(server.base + "/link/hello", data=b"not json")
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(req, timeout=5)
    assert e.value.code == 400
    # a chunked body (Dart's HttpClient sends one unless told the length) is refused plainly, not read as empty
    import http.client
    c = http.client.HTTPConnection("127.0.0.1", int(server.base.rsplit(":", 1)[1]), timeout=5)
    c.request("POST", "/link/hello", body=iter([b'{"v": 1}']), headers={"Transfer-Encoding": "chunked"},
              encode_chunked=True)
    assert c.getresponse().status == 411
    c.close()


def test_only_the_local_network(link: pl.Link) -> None:
    code = link.new_code()
    s = Server(link, client="8.8.8.8")
    try:
        assert s.get(f"/p?s={code}")[0] == 403
        assert s.post("/link/hello", {"v": 1, "via": "code", "nonce": "n" * 22})[0] == 403
        s.client = "100.64.0.5"  # carrier-grade NAT, a VPN: not a home network
        assert s.get("/noapp")[0] == 403
        s.client = "192.168.1.7"  # another device at home may open the scan's page, never this laptop's own page
        assert s.get(f"/p?s={code}")[0] == 200
        assert s.get("/")[0] == 404 and s.get("/status")[0] == 404
        s.client = "::ffff:192.168.1.7"
        assert s.get("/noapp")[0] == 200
        s.client = "127.0.0.1"
        status, page = s.get("/")
        assert status == 200 and "<svg" in page
    finally:
        s.close()
    for a, ok in [("10.1.2.3", True), ("172.16.0.1", True), ("172.32.0.1", False), ("169.254.9.9", True),
                  ("192.169.0.1", False), ("127.0.0.1", True), ("::1", False), ("fe80::1", False), ("x", False)]:
        assert pl.allowed_client(a) is ok, a


def test_the_scan_page(link: pl.Link, server: Server, clock: Clock) -> None:
    code = link.new_code()
    status, page = server.get(f"/p?s={code}")
    assert status == 200 and "Open EEG Tracker" in page
    assert link.intent_link(code).replace("&", "&amp;") in page
    assert "my-laptop" in page
    status, page = server.get("/p?s=" + "w" * 22)
    assert status == 200 and "expired" in page and "intent://" not in page
    clock.t += pl.CODE_LIFE + 1
    assert "intent://" not in server.get(f"/p?s={code}")[1]


def test_link_json_is_private_and_remembered(link: pl.Link, server: Server, tmp_path: Path, clock: Clock) -> None:
    code = link.new_code()
    _, answer = phone_handshake(server, "code", code, port=8766, token="abcdefghjkmnpqrs")
    f = tmp_path / "phone" / "link.json"
    assert stat.S_IMODE(f.stat().st_mode) == 0o600
    saved = json.loads(f.read_text())
    assert saved["laptop_key"] == answer["key"] and saved["phone"] == {"address": "127.0.0.1", "port": 8766,
                                                                       "token": "abcdefghjkmnpqrs"}
    again = pl.Link(f, name="my-laptop", host="192.168.1.10", clock=clock)  # the command run again tomorrow
    assert again.target() == ("127.0.0.1", 8766, "abcdefghjkmnpqrs") and again.key == answer["key"]
    assert again.code is None  # no code until one is shown


def test_the_phone_tells_its_new_address_with_the_key(link: pl.Link, clock: Clock) -> None:
    s = Server(link, client="192.168.1.23")
    heard: list[tuple[str, str, bool]] = []
    link.listeners.append(lambda p, via, moved: heard.append((p.address, via, moved)))
    try:
        # before any pairing there is no key to announce with
        assert s.post("/link/hello", {"v": 1, "via": "key", "nonce": "n" * 22}) == (404, {"error": "not paired"})
        _, answer = phone_handshake(s, "code", link.new_code())
        key = answer["key"]
        assert link.target() == ("192.168.1.23", 8765, TOKEN)  # the address the laptop saw, not one the phone named
        link.changed.clear()
        # the router gave the phone a new address; the phone says so with the key (and a new token after New code)
        s.client = "192.168.1.77"
        assert phone_handshake(s, "key", key, token="newtoken2345")[0] == 200
        assert link.target() == ("192.168.1.77", 8765, "newtoken2345")
        assert link.changed.is_set()  # the mirror passes at once
        # the same again five minutes later: nothing moved, and the mirror keeps its turn
        link.changed.clear()
        assert phone_handshake(s, "key", key, token="newtoken2345")[0] == 200
        assert not link.changed.is_set()
        assert heard == [("192.168.1.23", "code", True), ("192.168.1.77", "key", True), ("192.168.1.77", "key", False)]
        # an old key (the phone of an earlier pairing) proves nothing
        assert phone_handshake(s, "key", "k" * 43)[0] == -1
        # pairing again replaces the key: the old one stops working
        phone_handshake(s, "code", link.new_code())
        assert phone_handshake(s, "key", key)[0] == -1
    finally:
        s.close()


def test_phone_at_overrides_where_the_phone_is_reached(tmp_path: Path, clock: Clock) -> None:
    link = pl.Link(tmp_path / "link.json", name="l", host="10.0.2.2", phone_at="http://127.0.0.1:18765", clock=clock)
    s = Server(link, client="10.0.2.15")
    try:
        phone_handshake(s, "code", link.new_code())
        assert link.target() == ("127.0.0.1", 18765, TOKEN)  # adb forward on the emulator
    finally:
        s.close()


@pytest.fixture
def fake_phone():
    f = FakePhone()
    yield f
    f.close()


def test_mirror_and_pages_follow_the_phone(link: pl.Link, server: Server, fake_phone: FakePhone,
                                           tmp_path: Path) -> None:
    """After the pairing the mirror copies from the phone, and the live pages are pointed at it."""
    fake_phone.put(f"{STEM}.f32", b"\x02" * 64)
    lines: list[str] = []
    say = pl.Say(lines.append)
    pages = pl.start_pages(link, 0, tmp_path / "recordings", say)
    assert pages is not None
    try:
        page_base = f"http://127.0.0.1:{pages.server_address[1]}"
        with urllib.request.urlopen(page_base + "/state", timeout=5) as r:  # no phone yet
            assert json.loads(r.read())["status"] == "reconnecting"
        last: list[str | None] = [None]
        pl.mirror_pass(link, tmp_path, say, last)  # not paired: nothing to do
        assert lines == []
        port = int(fake_phone.base.rsplit(":", 1)[1])
        assert phone_handshake(server, "code", link.new_code(), port=port)[0] == 200
        pl.mirror_pass(link, tmp_path, say, last)
        assert (tmp_path / "recordings" / "2026-11-19-010000.f32").read_bytes() == b"\x02" * 64
        assert link.answering and any("Connected" in x for x in lines) and any("fetched" in x for x in lines)
        with urllib.request.urlopen(page_base + "/state", timeout=5) as r:  # passed on, with the token
            assert json.loads(r.read()) == {"status": "recording", "via": "phone"}
        # the phone made a new code: said once, not every pass
        key = json.loads((tmp_path / "phone" / "link.json").read_text())["laptop_key"]
        phone_handshake(server, "key", key, port=port, token="wrongtoken99")
        lines.clear()
        pl.mirror_pass(link, tmp_path, say, last)
        pl.mirror_pass(link, tmp_path, say, last)
        assert len(lines) == 1 and "refused" in lines[0] and not link.answering
        # and it tells the right one: copying again
        phone_handshake(server, "key", key, port=port, token=TOKEN)
        pl.mirror_pass(link, tmp_path, say, last)
        assert link.answering and "Connected" in lines[1]
    finally:
        pages.shutdown()
        pages.server_close()


def test_mirror_loop_passes_at_once_when_the_phone_speaks(link: pl.Link, fake_phone: FakePhone,
                                                          tmp_path: Path) -> None:
    port = int(fake_phone.base.rsplit(":", 1)[1])
    s = Server(link)
    stop = threading.Event()
    lines: list[str] = []
    t = threading.Thread(target=pl.mirror_loop, args=(link, tmp_path, 60, pl.Say(lines.append), stop), daemon=True)
    t.start()
    try:
        fake_phone.put(f"{STEM}.log", b"connected\n")
        phone_handshake(s, "code", link.new_code(), port=port)  # an hour's wait is cut short
        for _ in range(100):
            if (tmp_path / "recordings" / "2026-11-19-010000.log").exists():
                break
            threading.Event().wait(0.05)
        assert (tmp_path / "recordings" / "2026-11-19-010000.log").read_bytes() == b"connected\n"
    finally:
        stop.set()
        link.changed.set()
        t.join(5)
        s.close()


def test_main_refuses_without_a_home_network(tmp_path: Path) -> None:
    out: list[str] = []
    assert pl.main(["--address", "8.8.8.8", "--dest", str(tmp_path)], out=out.append) == 2
    assert "Wi-Fi" in out[0]


def test_main_says_when_the_port_is_taken(tmp_path: Path, link: pl.Link) -> None:
    s = Server(link)
    try:
        out: list[str] = []
        port = s.srv.server_address[1]
        assert pl.main(["--address", "127.0.0.1", "--port", str(port), "--dest", str(tmp_path)], out=out.append) == 2
        assert "already running" in out[0]
    finally:
        s.close()


def test_lan_address_is_private_or_none() -> None:
    a = pl.lan_address()
    assert a is None or pl.is_lan(a)
    for name, addr in pl.interface_addresses():
        assert isinstance(name, str) and addr.count(".") == 3


def test_pull_phone_is_what_the_mirror_runs() -> None:
    assert pl.pp is pp  # one copy rule for the laptop: pull_phone.py's


# ---------- --keep: the tray runs it while a phone is paired (DECISIONS 677) ----------

def _free_port() -> int:
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _paired(dest: Path, clock: Clock) -> str:
    """A phone paired earlier: link.json with its key, as the pairing left it."""
    link = pl.Link(dest / "phone" / "link.json", name="my-laptop", host="127.0.0.1", clock=clock)
    s = Server(link, client="192.168.1.23")
    try:
        _, answer = phone_handshake(s, "code", link.new_code())
    finally:
        s.close()
    return answer["key"]


def _get(url: str) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def _until(ok, seconds: float = 5.0) -> None:
    import time

    def check() -> bool:
        try:
            return bool(ok())
        except OSError:   # not listening there (yet)
            return False
    end = time.monotonic() + seconds
    while not check() and time.monotonic() < end:
        time.sleep(0.02)
    assert check()


def test_keep_needs_a_paired_phone(tmp_path: Path) -> None:
    out: list[str] = []
    a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(_free_port()), "--no-pages", "--no-mirror"])
    assert pl.keep(a, out.append) == 3 and "without --keep" in out[0]


def test_keep_runs_quietly_follows_the_laptops_address_and_ends_when_forgotten(tmp_path: Path, clock: Clock) -> None:
    """No window and no code until this laptop asks for one; the laptop's address can go (Wi-Fi off) and come back,
    or change, and the phone's announcement still reaches it; deleting link.json ends it."""
    key = _paired(tmp_path, clock)
    port = _free_port()
    wifi: list[str | None] = ["127.0.0.2"]   # this laptop's home-network address now (127.0.0.x stand in)

    def find() -> str | None:
        return wifi[0]

    a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(port), "--no-pages", "--no-mirror"])
    out: list[str] = []
    stop = threading.Event()
    done: list[int] = []
    t = threading.Thread(target=lambda: done.append(pl.keep(a, out.append, find=find, stop=stop, look_s=0.15)),
                         daemon=True)
    t.start()
    try:
        _until(lambda: _get(f"http://127.0.0.1:{port}/status")[0] == 200)
        status = json.loads(_get(f"http://127.0.0.1:{port}/status")[1])
        assert status["code_valid"] is False and status["phone"] == "192.168.1.23:8765"
        assert "No code right now" in _get(f"http://127.0.0.1:{port}/")[1]
        # "Pair phone…" in the tray opens /?new=1: a code, then the plain page (a reload does not make another)
        code, page = _get(f"http://127.0.0.1:{port}/?new=1")
        assert code == 200 and "<svg" in page and json.loads(_get(f"http://127.0.0.1:{port}/status")[1])["code_valid"]

        class At(Server):
            def __init__(self, host: str) -> None:  # the phone's announcement to wherever the laptop listens now
                self.client, self.base = "192.168.1.23", f"http://{host}:{port}"

        _until(lambda: _get(f"http://127.0.0.2:{port}/noapp")[0] == 200)   # on the address, not just loopback
        assert phone_handshake(At("127.0.0.2"), "key", key, token="newtoken2345")[0] == 200
        wifi[0] = None                                                        # Wi-Fi off a moment
        _until(lambda: any("No home-network address now" in x for x in out))
        wifi[0] = "127.0.0.2"                                                 # back at the same address
        _until(lambda: sum("Listening for the phone at 127.0.0.2" in x for x in out) == 2)
        assert phone_handshake(At("127.0.0.2"), "key", key, token="newtoken2345")[0] == 200
        wifi[0] = "127.0.0.3"                                                 # the router gave it a new one
        _until(lambda: _get(f"http://127.0.0.3:{port}/noapp")[0] == 200)
        assert phone_handshake(At("127.0.0.3"), "key", key, token="newtoken6789")[0] == 200
        saved = json.loads((tmp_path / "phone" / "link.json").read_text())
        assert saved["phone"]["token"] == "newtoken6789"   # a new code on the phone needs no new scan
        assert not any(key in x or "newtoken" in x for x in out)
        (tmp_path / "phone" / "link.json").unlink()        # the tray's "Forget the phone"
        _until(lambda: bool(done), 5)
        assert done == [0] and "forgotten" in out[-1]
        with pytest.raises(OSError):
            urllib.request.urlopen(f"http://127.0.0.1:{port}/status", timeout=1)
    finally:
        stop.set()
        t.join(5)
