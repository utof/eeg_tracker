"""scripts/phone_link.py: what the QR code holds, the one-time code's life, the two-step handshake with its proofs,
the phone telling a new address later, what is kept in link.json, and the mirror and pages that follow the phone.
The phone's side here is a small client written from the protocol (the app's is app/lib/share/link.dart; both are
checked against the proofs in app/test/fixtures/phone_link.json)."""
import json
import secrets
import stat
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import pytest

import phone_link as pl
import phone_auth as pa
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
    """A link whose laptop cannot tell its network (as on a machine without /proc): never at home."""
    return pl.Link(tmp_path / "phone" / "link.json", name="my-laptop", host="192.168.1.10", clock=clock,
                   home_of=lambda: None)


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


def phone_handshake(s: Server, code: str, *, port: int = 8765, tamper: bool = False) -> tuple[int, dict, str | None]:
    """The app's two steps (DECISIONS 753): check the laptop's proof first; then prove the code too and say the port.
    Nothing secret is sent: both sides work the key out. Returns (status, the laptop's answer, the phone's key)."""
    mine = secrets.token_urlsafe(16)
    status, hello = s.post("/link/hello", {"v": 2, "nonce": mine})
    if status != 200:
        return status, hello, None
    if hello["proof"] != pa.link_proof(code, "laptop", mine, hello["nonce"]):
        return -1, {"error": "the laptop did not prove the code: nothing sent"}, None
    given = pa.link_proof(code, "phone", hello["nonce"], mine)
    if tamper:
        given = given[::-1]
    status, done = s.post("/link/finish", {"v": 2, "nonce": hello["nonce"], "proof": given, "port": port})
    key = pa.derive_key(code, mine, hello["nonce"])
    if status == 200 and done.get("confirm") != pa.confirm(key, mine, hello["nonce"]):
        return -2, done, None
    return status, done, key if status == 200 else None


def test_signatures_match_the_shared_vectors() -> None:
    for c in FIXTURE["proofs"]:
        assert pa.link_proof(c["code"], "laptop", c["phone_nonce"], c["laptop_nonce"]) == c["laptop_proof"]
        assert pa.link_proof(c["code"], "phone", c["laptop_nonce"], c["phone_nonce"]) == c["phone_proof"]
        assert pa.derive_key(c["code"], c["phone_nonce"], c["laptop_nonce"]) == c["key"]
        assert pa.confirm(c["key"], c["phone_nonce"], c["laptop_nonce"]) == c["confirm"]
    for c in FIXTURE["requests"]:
        got = pa.request_sign(c["key"], c["method"], c["target"], c["time_ms"], c["nonce"], c["home"],
                              c["body"].encode())
        assert got == c["sign"], c["target"]
        assert pa.reply_proof(c["key"], c["nonce"]) == c["reply"]
    data = bytes((i * 7 + 3) % 256 for i in range(10_000))
    for c in FIXTURE["rechecks"]:
        ranges = [(s, n) for s, n in c["ranges"]]
        assert pa.recheck_mac(c["key"], c["path"], c["nonce"], c["size"], ranges,
                              (data[s:s + n] for s, n in ranges)) == c["mac"]


def test_what_the_qr_code_holds(link: pl.Link) -> None:
    code = link.new_code()
    assert len(code) == 22 and pl.NONCE.fullmatch(code)  # 128 bits, URL-safe
    web = link.web_link(code)
    # the code goes in the part after "#", which a browser never sends (DECISIONS 753): it never crosses the Wi-Fi
    assert web == f"http://192.168.1.10:8771/p#s={code}"
    assert code not in web.split("#")[0] and TOKEN not in web and "token" not in web
    assert link.app_link(code) == f"eegtracker://pair?h=192.168.1.10&p=8771&s={code}&n=my-laptop"
    # the terminal drawing is that link: version 4 at level M, 21 lines with the quiet zone
    lines: list[str] = []
    pl.show_code(link, pl.Say(lines.append), "web", False)
    drawing = lines[1].split("\n")
    assert len(drawing) == 21
    assert qr_code.terminal(qr_code.encode(link.web_link(link.code or "")), color=False) == lines[1]
    assert "The same as a link" not in "".join(lines) and (link.code or "") not in "".join(lines[2:])
    lines.clear()
    pl.show_code(link, pl.Say(lines.append), "app", False)  # --qr app: the app link itself in the code
    assert qr_code.terminal(qr_code.encode(link.app_link(link.code or "")), color=False) == lines[1]


def test_the_scan_page_builds_the_app_link_in_the_browser(link: pl.Link, server: Server, clock: Clock) -> None:
    """The page never sees the code: its script reads it from the link's # part and opens the app (Chrome's
    intent:// form, which names the app's package so no other app takes it)."""
    link.new_code()
    status, page = server.get("/p")
    assert status == 200 and "Open EEG Tracker" in page and "my-laptop" in page
    assert "location.hash" in page and "package=io.github.utof.eeg_tracker;" in page
    assert "intent://pair?h=192.168.1.10&p=8771" in page and "scheme=eegtracker" in page
    assert "S.browser_fallback_url=http%3A%2F%2F192.168.1.10%3A8771%2Fnoapp" in page
    assert (link.code or "") not in page
    assert server.get("/p?s=" + (link.code or ""))[0] == 200  # an old link's query is ignored, never checked


def test_the_code_expires_after_five_minutes_and_works_once(link: pl.Link, server: Server, clock: Clock) -> None:
    link.new_code()
    clock.t += pl.CODE_LIFE + 1
    assert server.post("/link/hello", {"v": 2, "nonce": "n" * 22}) == (410, {"error": "expired"})
    assert link.target() is None

    code = link.new_code()
    clock.t += pl.CODE_LIFE - 5
    status, answer, key = phone_handshake(server, code)
    assert status == 200 and answer["name"] == "my-laptop"
    assert link.target() == ("127.0.0.1", 8765) and link.key == key  # loopback: the phone reached through this laptop
    assert not link.code_valid() and link.code is None
    assert phone_handshake(server, code)[0] == 410  # used: the same code never works again


def test_pairing_sends_no_secret_and_both_sides_hold_the_same_key(link: pl.Link, server: Server) -> None:
    """DECISIONS 753: the key is worked out on both sides, not sent; the phone's token is not sent either."""
    sent: list[tuple[str, dict]] = []
    post = server.post

    def spy(path: str, body: object) -> tuple[int, dict]:
        status, answer = post(path, body)
        sent.append((path, body if isinstance(body, dict) else {}))
        sent.append((path + " answer", answer))
        return status, answer

    server.post = spy  # type: ignore[method-assign]
    code = link.new_code()
    status, _, key = phone_handshake(server, code)
    assert status == 200 and key is not None and pa.KEY.fullmatch(key) and link.key == key
    wire = json.dumps(sent)
    assert key not in wire and code not in wire and TOKEN not in wire and "token" not in wire and '"key"' not in wire


def test_an_old_app_is_told_to_update(link: pl.Link, server: Server) -> None:
    link.new_code()
    assert server.post("/link/hello", {"v": 1, "via": "code", "nonce": "n" * 22}) == (400, {"error": "old app"})


def test_a_hello_alone_does_not_expire_the_code_and_a_late_finish_fails(link: pl.Link, server: Server,
                                                                        clock: Clock) -> None:
    code = link.new_code()
    mine = "p" * 22
    _, hello = server.post("/link/hello", {"v": 2, "nonce": mine})
    clock.t += pl.NONCE_LIFE + 1
    late = server.post("/link/finish", {"v": 2, "nonce": hello["nonce"], "port": 8765,
                                        "proof": pa.link_proof(code, "phone", hello["nonce"], mine)})
    assert late == (403, {"error": "start again"})
    assert link.code_valid(code)  # still there for a fresh try
    assert phone_handshake(server, code)[0] == 200


def test_proofs_both_ways(link: pl.Link, server: Server) -> None:
    code = link.new_code()
    # a phone holding another code finds the laptop's proof wrong and sends nothing
    assert phone_handshake(server, "x" * 22)[0] == -1
    # a wrong phone proof is refused, the code stays, and that hello's nonce is spent
    mine = "q" * 22
    _, hello = server.post("/link/hello", {"v": 2, "nonce": mine})
    bad = {"v": 2, "nonce": hello["nonce"], "proof": "0" * 64, "port": 8765}
    assert server.post("/link/finish", bad) == (403, {"error": "wrong proof"})
    good = dict(bad, proof=pa.link_proof(code, "phone", hello["nonce"], mine))
    assert server.post("/link/finish", good) == (403, {"error": "start again"})
    assert link.target() is None and link.code_valid(code)
    # a finish with no hello at all
    assert server.post("/link/finish", dict(bad, nonce="z" * 22)) == (403, {"error": "start again"})
    # no code shown: nothing to pair with
    link.code = None
    assert server.post("/link/hello", {"v": 2, "nonce": "n" * 22}) == (410, {"error": "expired"})


@pytest.mark.parametrize("body", [
    {"v": 3, "nonce": "n" * 22}, {"nonce": "n" * 22}, {"v": 2, "nonce": "short"}, {"v": 2, "nonce": "bad nonce!" * 3},
    ["not", "a", "map"],
])
def test_bad_hellos(link: pl.Link, server: Server, body: object) -> None:
    link.new_code()
    assert server.post("/link/hello", body)[0] == 400


@pytest.mark.parametrize("change", [{"port": 80}, {"port": True}, {"port": "8765"}, {"proof": None}, {"v": 1}])
def test_bad_finishes(link: pl.Link, server: Server, change: dict) -> None:
    link.new_code()
    _, hello = server.post("/link/hello", {"v": 2, "nonce": "n" * 22})
    body = {"v": 2, "nonce": hello["nonce"], "proof": "0" * 64, "port": 8765} | change
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
    link.new_code()
    s = Server(link, client="8.8.8.8")
    try:
        assert s.get("/p")[0] == 403
        assert s.post("/link/hello", {"v": 2, "nonce": "n" * 22})[0] == 403
        s.client = "100.64.0.5"  # carrier-grade NAT, a VPN: not a home network
        assert s.get("/noapp")[0] == 403
        s.client = "192.168.1.7"  # another device at home may open the scan's page, never this laptop's own page
        assert s.get("/p")[0] == 200
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


def test_link_json_is_private_and_remembered(link: pl.Link, server: Server, tmp_path: Path, clock: Clock) -> None:
    code = link.new_code()
    _, _, key = phone_handshake(server, code, port=8766)
    f = tmp_path / "phone" / "link.json"
    assert stat.S_IMODE(f.stat().st_mode) == 0o600
    saved = json.loads(f.read_text())
    assert saved["version"] == 2 and saved["key"] == key
    assert saved["phone"] == {"address": "127.0.0.1", "port": 8766}  # no token: this laptop never needs it
    again = pl.Link(f, name="my-laptop", host="192.168.1.10", clock=clock)  # the command run again tomorrow
    assert again.target() == ("127.0.0.1", 8766) and again.key == key and not again.old
    assert again.code is None  # no code until one is shown


def test_a_pairing_from_before_needs_one_new_scan(tmp_path: Path, clock: Clock) -> None:
    """DECISIONS 753: a version-1 link.json (its key crossed the Wi-Fi at pairing) is not used: the phone is copied
    from again after one new scan; nothing of it is kept but the fact that there was one."""
    f = tmp_path / "phone" / "link.json"
    f.parent.mkdir(parents=True)
    f.write_text(json.dumps({"version": 1, "laptop_key": "k" * 43, "paired": "2026-11-20T10:00:00+03:00",
                             "phone": {"address": "192.168.1.23", "port": 8765, "token": TOKEN}}))
    old = pl.Link(f, name="my-laptop", host="192.168.1.10", clock=clock)
    assert old.target() is None and old.key is None and old.old
    assert pl.paired_phone(f) is None


def test_phone_at_overrides_where_the_phone_is_reached(tmp_path: Path, clock: Clock) -> None:
    link = pl.Link(tmp_path / "link.json", name="l", host="10.0.2.2", phone_at="http://127.0.0.1:18765", clock=clock)
    s = Server(link, client="10.0.2.15")
    try:
        phone_handshake(s, link.new_code())
        assert link.target() == ("127.0.0.1", 18765)  # adb forward on the emulator
    finally:
        s.close()


def test_the_emulator_pairs_through_the_hosts_alias(tmp_path: Path, clock: Clock) -> None:
    """The emulator reaches this laptop's loopback as 10.0.2.2 and says so in Host: with --address 10.0.2.2 the
    pairing port takes that name too (only the address the QR code names, never another site's)."""
    link = pl.Link(tmp_path / "link.json", name="l", host="10.0.2.2", clock=clock)
    s = Server(link)
    try:
        code = link.new_code()
        import http.client
        port = s.srv.server_address[1]
        body = json.dumps({"v": 2, "nonce": "n" * 22}).encode()
        for host, ok in ((f"10.0.2.2:{port}", True), (f"10.0.2.3:{port}", False), (f"rebind.example:{port}", False)):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            c.request("POST", "/link/hello", body=body, headers={"Host": host, "Content-Type": "application/json"})
            assert (c.getresponse().status == 200) is ok, host
            c.close()
        assert code
    finally:
        s.close()


@pytest.fixture
def fake_phone():
    f = FakePhone()
    yield f
    f.close()


def _pair_with(link: pl.Link, server: Server, phone: FakePhone) -> str:
    """Pairs [link] with [phone] (loopback stands for the Wi-Fi) and gives the phone the key both sides worked out."""
    port = int(phone.base.rsplit(":", 1)[1])
    status, _, key = phone_handshake(server, link.new_code(), port=port)
    assert status == 200 and key is not None
    phone.key = key
    return key


def test_the_mirror_signs_every_request_and_the_token_never_leaves(link: pl.Link, server: Server,
                                                                   fake_phone: FakePhone, tmp_path: Path) -> None:
    """DECISIONS 751: the paired laptop signs with the key (the phone answers with its own proof); the phone's token
    is not even known here."""
    fake_phone.put(f"{STEM}.f32", b"\x02" * 64)
    lines: list[str] = []
    say = pl.Say(lines.append)
    last: list[str | None] = [None]
    pl.mirror_pass(link, tmp_path, say, last)  # not paired: nothing to do
    assert lines == [] and fake_phone.requests == []
    _pair_with(link, server, fake_phone)
    pl.mirror_pass(link, tmp_path, say, last)
    assert (tmp_path / "recordings" / "2026-11-19-010000.f32").read_bytes() == b"\x02" * 64
    assert link.answering and any("Connected" in x for x in lines) and any("fetched" in x for x in lines)
    assert fake_phone.bearer == 0 and fake_phone.signed and all(m in ("GET", "POST") for m, _, _ in fake_phone.signed)
    assert pl.status(link)["last_copy"] is not None


def test_the_pages_pass_on_signed_requests(link: pl.Link, server: Server, fake_phone: FakePhone,
                                           tmp_path: Path) -> None:
    pages = pl.start_pages(link, 0, tmp_path / "recordings", pl.Say(lambda _l: None))
    assert pages is not None
    try:
        page_base = f"http://127.0.0.1:{pages.server_address[1]}"
        with urllib.request.urlopen(page_base + "/state", timeout=5) as r:  # no phone yet
            assert json.loads(r.read())["status"] == "reconnecting"
        _pair_with(link, server, fake_phone)
        with urllib.request.urlopen(page_base + "/state", timeout=5) as r:  # passed on, signed
            assert json.loads(r.read()) == {"status": "recording", "via": "phone"}
        assert ("GET", "/state", False) in fake_phone.signed and fake_phone.bearer == 0
    finally:
        pages.shutdown()
        pages.server_close()


def test_a_device_at_the_phones_old_address_is_not_trusted(link: pl.Link, server: Server, fake_phone: FakePhone,
                                                            tmp_path: Path) -> None:
    """Something else answering at the phone's address (another network, a device that took the address) cannot
    prove the key: nothing it says is copied, and it learns nothing it could use."""
    fake_phone.put(f"{STEM}.f32", b"\x02" * 64)
    _pair_with(link, server, fake_phone)
    fake_phone.key, fake_phone.ignore_auth = "0" * 64, True  # a stranger: it answers anything, but holds no key
    lines: list[str] = []
    pl.mirror_pass(link, tmp_path, pl.Say(lines.append), [None])
    assert not (tmp_path / "recordings" / "2026-11-19-010000.f32").exists() and not link.answering
    assert len(lines) == 1 and "did not prove" in lines[0]
    fake_phone.ignore_auth = False  # the phone forgot this laptop (or another pairing): it refuses the signature
    pl.mirror_pass(link, tmp_path, pl.Say(lines.append), [None])
    assert len(lines) == 2 and "refused" in lines[1] and "Pair phone" in lines[1]


def test_sharing_paused_on_another_network_is_said_once(link: pl.Link, server: Server, fake_phone: FakePhone,
                                                        tmp_path: Path) -> None:
    _pair_with(link, server, fake_phone)
    fake_phone.here = "paused"  # the phone is not on its home Wi-Fi and the owner did not allow this one
    lines: list[str] = []
    last: list[str | None] = [None]
    pl.mirror_pass(link, tmp_path, pl.Say(lines.append), last)
    pl.mirror_pass(link, tmp_path, pl.Say(lines.append), last)
    assert len(lines) == 1 and "not sharing on this Wi-Fi" in lines[0]
    assert pl.status(link)["sharing"] == "paused"


def test_the_home_network_is_the_routers_address_and_hardware_address(tmp_path: Path) -> None:
    """DECISIONS 751: this laptop knows the network it paired on by its router (gateway address and MAC, from the
    kernel's tables): a cafe's 192.168.1.1 is another router."""
    route = tmp_path / "route"
    arp = tmp_path / "arp"
    route.write_text("Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
                     "tun0\t00000000\t0100000A\t0003\t0\t0\t50\t00000000\t0\t0\t0\n"
                     "wlp2s0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n"
                     "wlp2s0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n")
    arp.write_text("IP address       HW type     Flags       HW address            Mask     Device\n"
                   "192.168.1.1      0x1         0x2         aa:bb:cc:dd:ee:ff     *        wlp2s0\n"
                   "192.168.1.30     0x1         0x2         11:22:33:44:55:66     *        wlp2s0\n")
    assert pl.gateway(route) == ("wlp2s0", "192.168.1.1")  # never a VPN's
    assert pl.home_id(route, arp, poke=False) == "192.168.1.1 aa:bb:cc:dd:ee:ff"
    arp.write_text("IP address       HW type     Flags       HW address            Mask     Device\n"
                   "192.168.1.1      0x1         0x0         00:00:00:00:00:00     *        wlp2s0\n")
    assert pl.home_id(route, arp, poke=False) is None  # not known yet: not home
    assert pl.home_id(tmp_path / "none", arp, poke=False) is None


def test_the_laptop_remembers_its_home_at_pairing(tmp_path: Path, clock: Clock) -> None:
    where = ["192.168.1.1 aa:bb:cc:dd:ee:ff"]
    link = pl.Link(tmp_path / "link.json", name="l", host="192.168.1.10", clock=clock, home_of=lambda: where[0])
    s = Server(link, client="192.168.1.23")
    try:
        phone_handshake(s, link.new_code())
    finally:
        s.close()
    assert json.loads((tmp_path / "link.json").read_text())["home"] == "192.168.1.1 aa:bb:cc:dd:ee:ff"
    assert link.at_home()
    where[0] = "192.168.1.1 01:02:03:04:05:06"  # the same address at a cafe: another router
    link.home_checked = -1e9
    assert not link.at_home()
    again = pl.Link(tmp_path / "link.json", name="l", host="192.168.1.10", clock=clock, home_of=lambda: where[0])
    assert again.home == "192.168.1.1 aa:bb:cc:dd:ee:ff" and not again.at_home()


def test_the_laptop_finds_the_phone_at_a_new_address(link: pl.Link, server: Server, tmp_path: Path) -> None:
    """The phone tells the laptop nothing (the laptop does not listen on the Wi-Fi): when it stops answering at its
    address at home, the laptop looks for it on its own network, and only a device that proves the key is it."""
    port = _free_port()
    stranger = FakePhone(host="127.0.0.2", port=port)  # another device with the same port open
    phone = FakePhone(host="127.0.0.3", port=port)
    try:
        status, _, key = phone_handshake(server, link.new_code(), port=port)
        phone.key, stranger.key = key, "0" * 64
        phone.put(f"{STEM}.log", b"connected\n")
        link.phone = pl.PhoneAt("127.0.0.9", port)  # where it was: nothing there now
        link.home_of = lambda: "home"
        link.home = "home"
        link.home_checked = -1e9
        lines: list[str] = []
        pl.mirror_pass(link, tmp_path, pl.Say(lines.append), [None],
                       hosts=lambda: ["127.0.0.2", "127.0.0.3", "127.0.0.4"])
        assert link.target() == ("127.0.0.3", port) and link.answering
        assert (tmp_path / "recordings" / "2026-11-19-010000.log").read_bytes() == b"connected\n"
        assert json.loads((tmp_path / "phone" / "link.json").read_text())["phone"]["address"] == "127.0.0.3"
        assert stranger.requests == [("GET", "/who", None)]  # asked once, and given nothing it could use
        assert not any("127.0.0." in x for x in lines)
    finally:
        stranger.close()
        phone.close()


def test_no_looking_around_off_the_home_network(link: pl.Link, server: Server, tmp_path: Path) -> None:
    port = _free_port()
    phone = FakePhone(host="127.0.0.3", port=port)
    try:
        phone_handshake(server, link.new_code(), port=port)
        link.phone = pl.PhoneAt("127.0.0.9", port)
        link.home_of = lambda: "a cafe"
        link.home = "home"
        link.home_checked = -1e9
        pl.mirror_pass(link, tmp_path, pl.Say(lambda _l: None), [None], hosts=lambda: ["127.0.0.3"])
        assert link.target() == ("127.0.0.9", port) and phone.requests == []
    finally:
        phone.close()


def test_mirror_loop_passes_at_once_after_the_pairing(link: pl.Link, fake_phone: FakePhone, tmp_path: Path) -> None:
    s = Server(link)
    stop = threading.Event()
    lines: list[str] = []
    t = threading.Thread(target=pl.mirror_loop, args=(link, tmp_path, 60, pl.Say(lines.append), stop), daemon=True)
    t.start()
    try:
        fake_phone.put(f"{STEM}.log", b"connected\n")
        _pair_with(link, s, fake_phone)  # an hour's wait is cut short
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
        _, _, key = phone_handshake(s, link.new_code())
    finally:
        s.close()
    assert key is not None
    return key


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


def _post(url: str, origin: str | None = None, host: str | None = None) -> int:
    import http.client
    u = urllib.parse.urlsplit(url)
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=3)
    headers = {"Content-Length": "0", **({"Origin": origin} if origin else {}), **({"Host": host} if host else {})}
    try:
        c.request("POST", u.path, body=b"", headers=headers)
        return c.getresponse().status
    finally:
        c.close()


def test_a_new_code_only_by_post_from_this_laptop(link: pl.Link, server: Server) -> None:
    """DECISIONS 750: a plain link (or another site's page) cannot make a code; this laptop's page and the tray can."""
    port = server.srv.server_address[1]
    assert server.get("/?new=1")[0] == 200 and not link.code_valid()  # a GET changes nothing
    assert _post(server.base + "/new", origin="https://evil.example") == 403 and not link.code_valid()
    assert _post(server.base + "/new", origin="null") == 403 and not link.code_valid()
    assert _post(server.base + "/new", host=f"evil.example:{port}") == 403 and not link.code_valid()
    assert _post(server.base + "/new", origin=f"http://127.0.0.1:{port}") == 303 and link.code_valid()  # its page
    code = link.code
    assert _post(server.base + "/new") == 303 and link.code == code  # the tray (no Origin): the shown one stays
    page = server.get("/")[1]
    assert '<form method="post" action="/new"' in page and "?new=1" not in page
    # DNS rebinding: a page naming itself cannot read this laptop's own page (the code) or its status
    import http.client
    for path in ("/", "/status", f"/p?s={code}"):
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        c.request("GET", path, headers={"Host": f"rebind.example:{port}"})
        assert c.getresponse().status == 403, path
        c.close()


def test_keep_listens_on_the_wifi_only_while_a_code_is_shown(tmp_path: Path, clock: Clock) -> None:
    """No window and no code until this laptop asks for one; the pairing port answers on the home network only while
    that code is shown (DECISIONS 750), follows the laptop's address, and deleting link.json ends it."""
    _paired(tmp_path, clock)
    port = _free_port()
    wifi: list[str | None] = ["127.0.0.2"]   # this laptop's home-network address now (127.0.0.x stand in)
    a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(port), "--no-pages", "--no-mirror"])
    out: list[str] = []
    stop = threading.Event()
    done: list[int] = []
    t = threading.Thread(target=lambda: done.append(pl.keep(a, out.append, find=lambda: wifi[0], stop=stop,
                                                             look_s=0.15, clock=clock)), daemon=True)
    t.start()
    try:
        _until(lambda: _get(f"http://127.0.0.1:{port}/status")[0] == 200)
        status = json.loads(_get(f"http://127.0.0.1:{port}/status")[1])
        assert status["code_valid"] is False
        assert "No code right now" in _get(f"http://127.0.0.1:{port}/")[1]
        with pytest.raises(OSError):  # nothing on the Wi-Fi while no code is shown
            urllib.request.urlopen(f"http://127.0.0.2:{port}/noapp", timeout=1)
        # "Pair phone…" in the tray: a POST for a code, then the page
        assert _post(f"http://127.0.0.1:{port}/new") == 303
        assert "<svg" in _get(f"http://127.0.0.1:{port}/")[1]
        _until(lambda: _get(f"http://127.0.0.2:{port}/noapp")[0] == 200)   # now on the address too
        wifi[0] = "127.0.0.3"                                                 # the router gave it a new one
        _until(lambda: _get(f"http://127.0.0.3:{port}/noapp")[0] == 200)
        clock.t += pl.CODE_LIFE + 1                                           # the code ran out
        _until(lambda: not _reachable(f"http://127.0.0.3:{port}/noapp"))
        assert _get(f"http://127.0.0.1:{port}/status")[0] == 200            # this laptop's own port stays
        assert not any("127.0.0." in x for x in out)                        # no addresses in its log
        (tmp_path / "phone" / "link.json").unlink()        # the tray's "Forget the phone"
        _until(lambda: bool(done), 5)
        assert done == [0] and "forgotten" in out[-1]
        with pytest.raises(OSError):
            urllib.request.urlopen(f"http://127.0.0.1:{port}/status", timeout=1)
    finally:
        stop.set()
        t.join(5)


def _reachable(url: str) -> bool:
    try:
        _get(url)
        return True
    except OSError:
        return False


def test_keep_starts_the_after_pull_jobs_after_a_copy_that_brought_something(
        tmp_path: Path, clock: Clock, fake_phone: FakePhone, monkeypatch: pytest.MonkeyPatch) -> None:
    """--keep, as the tray runs it, against a phone with a new recording: the copy fetches it, then the after-pull jobs
    are asked with `changed` (DECISIONS 768); --no-after-pull asks nothing."""
    import time

    import after_pull
    fake_phone.key = _paired(tmp_path, clock)  # the copy is signed with the pairing's key (DECISIONS 751)
    asked: list[tuple[Path, bool]] = []

    class Kicker:
        def __init__(self, local: Path) -> None:
            self.local = local

        def __call__(self, changed: bool) -> bool:
            asked.append((self.local, changed))
            return False

    monkeypatch.setattr(after_pull, "Kicker", Kicker)
    for name, extra in (("2026-11-19-010000", []), ("2026-11-19-020000", ["--no-after-pull"])):
        asked.clear()
        fake_phone.put(f"recordings/{name}.f32", b"\x02" * 64)
        a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(_free_port()), "--no-pages", "--every", "0.01",
                      "--phone-at", fake_phone.base, *extra])
        stop = threading.Event()
        t = threading.Thread(target=lambda: pl.keep(a, lambda _x: None, find=lambda: None, stop=stop), daemon=True)
        t.start()
        try:
            _until(lambda: (tmp_path / "recordings" / f"{name}.f32").exists())
            if not extra:
                _until(lambda: (tmp_path, True) in asked)
            else:
                time.sleep(0.5)
                assert asked == []
        finally:
            stop.set()
            t.join(5)
