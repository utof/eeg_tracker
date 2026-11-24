"""scripts/push_receiver.py: the phone sends its files by itself. The phone's side here is a small client written
from the protocol (the app's is in app/lib/share/); both sign as app/test/fixtures/phone_link.json says. What is
checked: the signatures; a good upload end to end through pull_phone.pull()'s own rules; everything a stranger on the
home Wi-Fi can try (no or wrong signature, a replay, a stale time, other methods and paths, paths that leave the
folder, too much, too slowly); interrupted uploads; the lock shared with the pull; the tray's line; the phone's
fallback ports."""
import hashlib
import http.client
import json
import socket
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

import pytest

import laptop_work as lw
import phone_auth as pa
import phone_link as pl
import pull_phone as pp
import push_receiver as pr
import import_phone as ip
from test_pull_phone import FakePhone, T0

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "app" / "test" / "fixtures" / "phone_link.json").read_text())
KEY = "9" * 64
STEM = "recordings/2026-11-19-010000"
F32 = f"{STEM}.f32"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def row(path: str, body: bytes, *, growing: bool = False, modified: int = T0, **more) -> dict:
    return dict(path=path, bytes=len(body), sha256=None if growing else sha(body), modified_ms=modified, **more)


def listing(*rows: dict) -> dict:
    return {"format": "eeg-tracker-phone-files", "version": 1, "files": list(rows)}


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def make_link(dest: Path, *, home: bool = True, key: str | None = KEY) -> pl.Link:
    (dest / "phone").mkdir(parents=True, exist_ok=True)
    if key is not None:
        (dest / "phone" / "link.json").write_text(json.dumps(
            {"version": 2, "key": key, "paired": "2026-11-19T21:00:00+03:00", "home": "home",
             "phone": {"address": "192.168.1.23", "port": 8765}}))
    where = ["home" if home else "a cafe"]
    link = pl.Link(dest / "phone" / "link.json", name="my-laptop", host="192.168.1.10", home_of=lambda: where[0])
    link.where = where  # type: ignore[attr-defined]
    return link


class Rig:
    """A receiver on loopback and the phone's side of the protocol. [client]: the address the laptop believes the
    phone has."""

    def __init__(self, dest: Path, *, home: bool = True, key: str | None = KEY, client: str = "192.168.1.23",
                 **kw) -> None:
        self.dest, self.client, self.key = dest, client, KEY
        self.lines: list[str] = []
        self.link = make_link(dest, home=home, key=key)
        self.clock = Clock()
        self.after: list[bool] = []
        self.r = pr.Receiver(self.link, dest, pl.Say(self.lines.append), client_ok=pl.allowed_client,
                             is_loopback=pl.is_loopback, clock=self.clock, after=self.after.append, **kw)
        self.listener = pr.Listener(self.r, 0, pr.make_handler(self.r, client_of=lambda _h: self.client))
        assert self.listener.loop is not None
        self.port = self.listener.loop.server_address[1]
        self.listener.port = self.port

    def close(self) -> None:
        self.listener.close()

    def raw(self, method: str, target: str, body: bytes | None = b"", headers: dict | None = None,
            ) -> tuple[int, dict, dict]:
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            c.request(method, target, body=body, headers=headers or {})
            r = c.getresponse()
            data = r.read()
            try:
                m = json.loads(data) if data else {}
            except ValueError:
                m = {"raw": data.decode("latin-1")}
            return r.status, m, {"reply": r.getheader(pa.REPLY_H), "body": data}
        finally:
            c.close()

    def post(self, target: str, body: bytes | dict = b"", *, key: str | None = None, headers: dict | None = None,
             ) -> tuple[int, dict]:
        """A signed POST; the answer must prove the key over the nonce and its own bytes, unless it is a 401."""
        data = json.dumps(body).encode() if isinstance(body, dict) else body
        h = pa.push_headers(key or self.key, "POST", target, data)
        h.update(headers or {})
        status, m, extra = self.raw("POST", target, data, h)
        if key is None and headers is None and not (status == 401 and m.get("error") == "signature") \
                and status not in (429,):
            assert pa.push_reply_ok(self.key, h[pa.NONCE_H], extra["body"], extra["reply"]), (status, m)
        return status, m

    def begin(self, *rows: dict, asks: list | None = None, port: int | None = 8765) -> dict:
        status, m = self.post("/push/begin", {"v": 1, "port": port, "files": listing(*rows), "asks": asks or []})
        assert status == 200, m
        return m

    def chunk(self, session: str, path: str, at: int, body: bytes) -> tuple[int, dict]:
        return self.post(f"/push/chunk?s={session}&p={quote(path, safe='')}&at={at}", body)

    def commit(self, session: str) -> dict:
        status, m = self.post(f"/push/commit?s={session}", {"v": 1})
        assert status == 200, m
        return m

    def send(self, files: dict[str, bytes], *rows: dict, asks: list | None = None, piece: int = 1 << 20) -> dict:
        """A whole push as the app does it: begin, every wanted range in pieces, commit."""
        b = self.begin(*rows, asks=asks)
        for w in b["want"]:
            data, at = files[w["path"]], w["from"] + w["have"]
            while at < len(data):
                status, m = self.chunk(b["session"], w["path"], at, data[at:at + piece])
                assert status == 200, m
                at += len(data[at:at + piece])
        return self.commit(b["session"])


@pytest.fixture
def rig(tmp_path: Path):
    r = Rig(tmp_path)
    yield r
    r.close()


def inbox(dest: Path) -> list[Path]:
    d = dest / "phone" / "push-inbox"
    return sorted(d.iterdir()) if d.is_dir() else []


def real_files(dest: Path) -> list[str]:
    """Everything under [dest] that is not the inbox, the pairing or the receiver's and the pull's own notes."""
    own = {"link.json", "push-state.json", "pull-state.json", "import-index.json", "pulls.jsonl", "acks.jsonl"}
    return sorted(str(p.relative_to(dest)) for p in dest.rglob("*")
                  if p.is_file() and "push-inbox" not in p.parts and p.name not in own)


# ---------- the signatures ----------

def test_push_signatures_match_the_shared_vectors() -> None:
    assert len(FIXTURE["push"]) >= 3
    for c in FIXTURE["push"]:
        body = c["body"].encode("utf-8")
        assert pa.push_sign(c["key"], c["method"], c["target"], c["time_ms"], c["nonce"], body) == c["sign"]
        assert pa.push_reply(c["key"], c["nonce"], c["reply_body"].encode("utf-8")) == c["reply"]
        assert pa.push_reply_ok(c["key"], c["nonce"], c["reply_body"].encode("utf-8"), c["reply"])
        assert not pa.push_reply_ok(c["key"], c["nonce"], c["reply_body"].encode("utf-8") + b" ", c["reply"])
        h = pa.push_headers(c["key"], c["method"], c["target"], body, now_ms=c["time_ms"], nonce=c["nonce"])
        assert h == {"X-Eeg-Time": str(c["time_ms"]), "X-Eeg-Nonce": c["nonce"], "X-Eeg-Sign": c["sign"]}
    targets = [c["target"] for c in FIXTURE["push"]]
    assert any("%2F" in t and "?" in t for t in targets) and any("?" not in t for t in targets)


# ---------- a good upload ----------

def test_hello_says_who_and_whether_at_home(rig: Rig) -> None:
    assert rig.post("/push/hello", {"v": 1}) == (200, {"v": 1, "app": "eeg-tracker-laptop", "home": True,
                                                       "name": "my-laptop"})
    rig.link.where[0] = "a cafe"; rig.link.home_checked = -1e18
    assert rig.post("/push/hello", {"v": 1})[1]["home"] is False
    assert rig.post("/push/hello", {"v": 2})[0] == 400


def test_a_new_file_arrives_whole_checked_and_acked(rig: Rig, tmp_path: Path) -> None:
    data = bytes(range(256)) * 40
    small = b'{"a": 1}'
    rows = (row(F32, data), row("settings.json", small))
    b = rig.begin(*rows)
    assert b["max_chunk"] == 4194304 and len(b["session"]) >= 22 and b["skipped"] == 0
    assert b["want"] == [{"path": F32, "from": 0, "have": 0}, {"path": "settings.json", "from": 0, "have": 0}]
    for at in range(0, len(data), 4000):
        assert rig.chunk(b["session"], F32, at, data[at:at + 4000]) == (200, {"v": 1, "staged": min(at + 4000, len(data))})
    assert rig.chunk(b["session"], "settings.json", 0, small)[0] == 200
    assert real_files(tmp_path) == []  # nothing in the real folders before the commit
    m = rig.commit(b["session"])
    assert (tmp_path / "recordings" / "2026-11-19-010000.f32").read_bytes() == data
    assert (tmp_path / "phone" / "settings.json").read_bytes() == small
    assert sorted(m["acks"], key=lambda a: a["path"]) == [{"path": F32, "sha256": sha(data)},
                                                         {"path": "settings.json", "sha256": sha(small)}]
    assert m["summary"] == {"new": 2, "grown": 0, "checked": 0, "updated": 0, "kept": 0, "damaged": 0, "waiting": 0,
                            "bytes": len(data) + len(small)}
    assert m["proofs"] == [] and inbox(tmp_path) == []
    # the notes: pulls.jsonl says pushed, push-state.json, the link, the log line (no address), the hook
    line = json.loads((tmp_path / "phone" / "pulls.jsonl").read_text().splitlines()[-1])
    assert line["phone"] == "pushed" and line["new"] == 2
    state = json.loads((tmp_path / "phone" / "push-state.json").read_text())
    assert state["files"] == 2 and state["bytes"] == len(data) + len(small) and state["last_push"] == state["last_try"]
    assert rig.link.last_push == state["last_push"] and pl.status(rig.link)["last_push"] == state["last_push"]
    assert any("The phone sent its files by itself" in x for x in rig.lines)
    assert not any("192.168." in x or "127.0.0." in x for x in rig.lines)
    assert rig.after == [True]
    # the same list again: nothing is wanted, nothing is acked twice when the phone lists them as acked
    assert rig.begin(*(dict(r, acked=True) for r in rows))["want"] == []


def test_a_growing_raw_file_is_continued_across_two_pushes_then_checked(rig: Rig, tmp_path: Path) -> None:
    first, more = b"\x01" * 5000, b"\x02" * 3000
    dst = tmp_path / "recordings" / "2026-11-19-010000.f32"
    m = rig.send({F32: first}, row(F32, first, growing=True))
    assert dst.read_bytes() == first and m["summary"]["new"] == 1 and m["acks"] == []
    b = rig.begin(row(F32, first + more, growing=True, modified=T0 + 1000))
    assert b["want"] == [{"path": F32, "from": 5000, "have": 0}]
    assert rig.chunk(b["session"], F32, 5000, more)[0] == 200
    m = rig.commit(b["session"])
    assert dst.read_bytes() == first + more and m["summary"]["grown"] == 1 and m["summary"]["bytes"] == 3000
    # the phone closed the file: nothing more to send, the copy is checked against the SHA-256 and acked
    m = rig.send({}, row(F32, first + more, modified=T0 + 1000))
    assert m["summary"]["checked"] == 1 and m["acks"] == [{"path": F32, "sha256": sha(first + more)}]
    assert json.loads((tmp_path / "phone" / "pull-state.json").read_text())["partial"] == {}


def test_a_recheck_is_answered_from_the_laptops_own_copy(rig: Rig, tmp_path: Path) -> None:
    data = bytes((i * 7 + 3) % 256 for i in range(10_000))
    rig.send({F32: data}, row(F32, data))
    ranges = [[0, 16], [4096, 100], [9990, 10]]
    asks = [{"path": F32, "nonce": "cmVjaGVjay1ub25jZS0wMDE", "bytes": len(data), "ranges": ranges},
            {"path": f"{STEM}.idx", "nonce": "cmVjaGVjay1ub25jZS0wMDI", "bytes": 4, "ranges": [[0, 4]]},
            {"path": "../link.json", "nonce": "cmVjaGVjay1ub25jZS0wMDM", "bytes": 4, "ranges": [[0, 4]]}]
    m = rig.send({}, row(F32, data, acked=True), asks=asks)
    mac = pa.recheck_mac(KEY, F32, asks[0]["nonce"], len(data), [(s, n) for s, n in ranges],
                         (data[s:s + n] for s, n in ranges))
    assert m["proofs"] == [{"path": F32, "nonce": asks[0]["nonce"], "mac": mac},
                           {"path": f"{STEM}.idx", "nonce": asks[1]["nonce"], "missing": True}]


def test_a_packed_night_from_the_phone_is_unpacked_and_checked(rig: Rig, tmp_path: Path) -> None:
    import gzip
    plain = b"\x05" * 9000
    gz = gzip.compress(plain)
    r = row(f"{F32}.gz", gz, original={"path": F32, "bytes": len(plain), "sha256": sha(plain)})
    m = rig.send({f"{F32}.gz": gz}, r)
    assert m["summary"]["new"] == 1
    assert (tmp_path / "recordings" / "2026-11-19-010000.f32").read_bytes() == plain
    assert m["acks"] == [{"path": f"{F32}.gz", "sha256": sha(plain)}]
    assert rig.begin(r)["want"] == []


def test_want_is_in_pulls_order_and_the_phone_is_remembered(rig: Rig, tmp_path: Path) -> None:
    b = rig.begin(row("settings.json", b"{}", modified=T0 + 9), row(f"{STEM}.idx", b"i", modified=T0),
                  row("recordings/2026-11-20-010000.f32", b"n", modified=T0 + 5), port=8767)
    assert [w["path"] for w in b["want"]] == ["recordings/2026-11-20-010000.f32", f"{STEM}.idx", "settings.json"]
    assert rig.link.target() == ("192.168.1.23", 8767)
    assert json.loads((tmp_path / "phone" / "link.json").read_text())["phone"] == {"address": "192.168.1.23",
                                                                                 "port": 8767}
    rig.client = "192.168.1.77"
    rig.begin()
    assert rig.link.target() == ("192.168.1.77", 8765)
    rig.client = "127.0.0.1"   # a cable (adb): the address is not taken from that
    rig.begin(port=None)
    assert rig.link.target() == ("192.168.1.77", 8765)


def test_the_plan_says_what_pull_would_fetch(tmp_path: Path) -> None:
    """`wanted_from` against pull_phone.pull() itself: for laptops in many states, the first byte pull asks the phone
    for (or nothing) is what the receiver would ask the phone to send."""
    phone = FakePhone()
    try:
        dest = tmp_path / "d"
        phone.put(f"{STEM}.f32", b"a" * 100, growing=True)
        phone.put(f"{STEM}.log", b"line\n")
        phone.put(f"{STEM}.idx", b"i" * 8, growing=True)
        phone.put("reports/x.json", b"{}")
        phone.put("reports/kept.json", b"phone")
        phone.put("reports/older.json", b"phone-new", modified=T0 + 10_000_000_000)
        phone.put("reports/waiting.json", b"phone-growing", modified=T0 + 10_000_000_000, growing=True)
        for name, body in (("kept", b"laptop"), ("older", b"laptop"), ("waiting", b"laptop")):
            f = dest / "phone" / "reports" / f"{name}.json"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(body)
        steps = [lambda: None,
                 lambda: (phone.put(f"{STEM}.f32", b"a" * 150, growing=True), phone.put(f"{STEM}.log", b"line\nmore\n"),
                          phone.put("empty.txt", b"")),
                 lambda: (phone.put(f"{STEM}.f32", b"a" * 150), phone.put(f"{STEM}.idx", b"j" * 8)),
                 lambda: (dest / "phone" / "reports" / "x.json").unlink(),
                 lambda: None]
        for k, step in enumerate(steps):
            step()
            listed, _ = pp.Phone(phone.base, "abcdefghjkmn").files()
            phone.requests.clear()
            plan = {str(e.path): pr.wanted_from(e, dest, ip.Index(dest, False), pp.State(dest)) for e in listed}
            pp.pull(pp.Phone(phone.base, "abcdefghjkmn"), dest)
            first: dict[str, int] = {}
            for path, rng in phone.fetched():
                first.setdefault(path, 0 if rng is None else int(rng.removeprefix("bytes=").split("-")[0]))
            sizes = {str(e.path): e.bytes for e in listed}
            assert {p: f for p, f in plan.items() if f is not None and f < sizes[p]} == first, k
    finally:
        phone.close()


# ---------- what a stranger on the Wi-Fi can try ----------

def test_unsigned_badly_signed_replayed_and_stale_requests_get_nothing(rig: Rig, tmp_path: Path) -> None:
    body = json.dumps({"v": 1}).encode()
    status, m, extra = rig.raw("POST", "/push/hello", body)
    assert (status, m) == (401, {"error": "signature"}) and extra["reply"] is None
    status, m = rig.post("/push/hello", body, key="0" * 64)
    assert (status, m) == (401, {"error": "signature"})
    # signed for another path, or with another body
    h = pa.push_headers(KEY, "POST", "/push/hello", body)
    assert rig.raw("POST", "/push/commit", body, h)[0] == 401
    h = pa.push_headers(KEY, "POST", "/push/hello", body)
    assert rig.raw("POST", "/push/hello", b'{"v":1} ', h)[0] == 401
    # a replay: the same headers and body twice
    h = pa.push_headers(KEY, "POST", "/push/hello", body)
    assert rig.raw("POST", "/push/hello", body, h)[0] == 200
    status, m, extra = rig.raw("POST", "/push/hello", body, h)
    assert (status, m) == (401, {"error": "signature"}) and extra["reply"] is None
    # a stale time, well signed: told why, with the proof (only the key's holder learns it)
    for off in (-6 * 60_000, 6 * 60_000):
        h = pa.push_headers(KEY, "POST", "/push/hello", body, now_ms=int(time.time() * 1000) + off)
        status, m, extra = rig.raw("POST", "/push/hello", body, h)
        assert (status, m) == (401, {"error": "time"})
        assert pa.push_reply_ok(KEY, h[pa.NONCE_H], extra["body"], extra["reply"])
    for bad in ({pa.NONCE_H: "short"}, {pa.TIME_H: "now"}, {pa.SIGN_H: "zz"}):
        h = dict(pa.push_headers(KEY, "POST", "/push/hello", body), **bad)
        assert rig.raw("POST", "/push/hello", body, h)[0] == 401
    assert real_files(tmp_path) == [] and inbox(tmp_path) == []


def test_only_post_and_only_the_four_paths_no_listing(rig: Rig, tmp_path: Path) -> None:
    (tmp_path / "recordings").mkdir()
    (tmp_path / "recordings" / "secret.f32").write_bytes(b"secret")
    for path in ("/", "/push", "/push/", "/recordings/secret.f32", "/phone/link.json", "/push/../phone/link.json",
                 "/push/inbox", "/status", "/files"):
        for method in ("GET", "POST", "HEAD", "PUT", "DELETE"):
            status, m, extra = rig.raw(method, path, b"" if method != "GET" else None)
            assert status == 404 and extra["reply"] is None, (method, path)
            assert b"secret" not in extra["body"] and b"link" not in extra["body"]
    for path in ("/push/hello", "/push/begin", "/push/chunk?s=a&p=b&at=0", "/push/commit"):
        for method in ("GET", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH"):
            assert rig.raw(method, path, None)[0] == 405, (method, path)
    # a signed GET is no better
    h = pa.push_headers(KEY, "GET", "/push/hello", b"")
    assert rig.raw("GET", "/push/hello", None, h)[0] == 405


def test_paths_that_leave_the_folder_never_reach_the_disk(rig: Rig, tmp_path: Path) -> None:
    outside = tmp_path.parent / "outside.txt"
    bad = ["../outside.txt", "/etc/passwd", str(outside), "a/../../outside.txt", "recordings/../../outside.txt",
           "manifest.json", "", "a\\..\\b", "./x", "a//b"]
    b = rig.begin(*(dict(path=p, bytes=4, sha256=sha(b"evil"), modified_ms=T0) for p in bad), row("ok.txt", b"fine"))
    assert b["want"] == [{"path": "ok.txt", "from": 0, "have": 0}] and b["refused"] == len(bad)
    for p in bad + ["ok.txt/../../outside.txt", "%2e%2e/outside.txt", "phone/link.json", "push-inbox/x"]:
        status, m = rig.chunk(b["session"], p, 0, b"evil")
        assert (status, m) == (404, {"error": "not wanted"}), p
    assert rig.chunk(b["session"], "ok.txt", 0, b"fine")[0] == 200
    # the staged names are hashes: nothing in the inbox is named by the client
    names = [f.name for f in inbox(tmp_path)]
    assert sorted(names) == sorted(hashlib.sha256(b"ok.txt").hexdigest()[:40] + s for s in (".part", ".json"))
    rig.commit(b["session"])
    assert real_files(tmp_path) == ["phone/ok.txt"] and not outside.exists()
    assert json.loads((tmp_path / "phone" / "link.json").read_text())["key"] == KEY


def test_a_chunk_for_a_path_not_wanted_and_bad_parameters(rig: Rig, tmp_path: Path) -> None:
    (tmp_path / "phone" / "here.txt").write_bytes(b"same")
    b = rig.begin(row("here.txt", b"same"), row("new.txt", b"new!"))
    assert [w["path"] for w in b["want"]] == ["new.txt"]
    assert rig.chunk(b["session"], "here.txt", 0, b"evil") == (404, {"error": "not wanted"})
    assert rig.chunk(b["session"], "never-listed.txt", 0, b"evil") == (404, {"error": "not wanted"})
    for target in (f"/push/chunk?s={b['session']}&p=new.txt", f"/push/chunk?s={b['session']}&at=0",
                   f"/push/chunk?s={b['session']}&p=new.txt&at=-1", f"/push/chunk?s={b['session']}&p=new.txt&at=x"):
        assert rig.post(target, b"n")[0] == 400, target
    assert rig.chunk(b["session"], "new.txt", 0, b"")[0] == 400
    assert (tmp_path / "phone" / "here.txt").read_bytes() == b"same" and real_files(tmp_path) == ["phone/here.txt"]
    for body in (b"not json", b"[]", b'{"v":1,"files":{"format":"other"}}', b'{"v":1,"port":80,"files":null}'):
        assert rig.post("/push/begin", body)[0] == 400


def test_sizes_are_bounded_before_anything_is_read(rig: Rig, tmp_path: Path) -> None:
    def send(lines: list[str], body: bytes = b"") -> bytes:
        with socket.create_connection(("127.0.0.1", rig.port), timeout=5) as s:
            s.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
            s.settimeout(5)
            got = b""
            try:
                while b := s.recv(65536):
                    got += b
            except TimeoutError:
                pass
            return got

    host = f"Host: 127.0.0.1:{rig.port}"
    # a length over the route's limit: refused at once, with no body sent at all
    for path, limit in (("/push/hello", 4096), ("/push/commit", 4096), ("/push/begin", 4 << 20),
                        ("/push/chunk?s=a&p=b&at=0", 4 << 20)):
        got = send([f"POST {path} HTTP/1.1", host, f"Content-Length: {limit + 1}"])
        assert got.startswith(b"HTTP/1.1 413"), path
    for bad in ("-1", "abc", "1e3", "99999999999999999999999999"):
        assert send(["POST /push/hello HTTP/1.1", host, f"Content-Length: {bad}"]).startswith(b"HTTP/1.1 413")
    assert send(["POST /push/hello HTTP/1.1", host]).startswith(b"HTTP/1.1 411")
    got = send(["POST /push/hello HTTP/1.1", host, "Transfer-Encoding: chunked"], b"7\r\n{\"v\":1}\r\n0\r\n\r\n")
    assert got.startswith(b"HTTP/1.1 400") and got.count(b"HTTP/1.1") == 1  # and the chunks are not read as a request
    got = send(["POST /push/hello HTTP/1.1", host, "Transfer-Encoding: chunked", "Content-Length: 7"], b'{"v":1}')
    assert got.startswith(b"HTTP/1.1 400")
    # more bytes than the file was listed with
    b = rig.begin(row("a.bin", b"12345678"))
    assert rig.chunk(b["session"], "a.bin", 0, b"123456789") == (413, {"error": "too big"})
    assert rig.chunk(b["session"], "a.bin", 0, b"12345") == (200, {"v": 1, "staged": 5})
    assert rig.chunk(b["session"], "a.bin", 5, b"6789") == (413, {"error": "too big"})
    assert rig.chunk(b["session"], "a.bin", 5, b"678") == (200, {"v": 1, "staged": 8})
    assert rig.chunk(b["session"], "a.bin", 8, b"9") == (413, {"error": "too big"})
    assert real_files(tmp_path) == []


def test_the_inbox_and_the_disk_have_a_limit(tmp_path: Path) -> None:
    rig = Rig(tmp_path, staging_cap=100, free=lambda _d: pr.FREE_MARGIN + 130)
    try:
        b = rig.begin(row("a.bin", b"a" * 60), row("b.bin", b"b" * 60, modified=T0 - 1),
                      row("c.bin", b"c" * 10, modified=T0 - 2))
        # a (60, and 60 again to land it) fits; b does not fit the inbox any more; c fits the inbox, not the disk
        assert [w["path"] for w in b["want"]] == ["a.bin"] and b["skipped"] == 2
        assert rig.chunk(b["session"], "b.bin", 0, b"b")[0] == 404
    finally:
        rig.close()


def test_wrong_offsets_are_refused_and_a_replayed_chunk_changes_nothing(rig: Rig, tmp_path: Path) -> None:
    data = b"0123456789"
    b = rig.begin(row("a.bin", data))
    target = f"/push/chunk?s={b['session']}&p=a.bin&at=0"
    h = pa.push_headers(KEY, "POST", target, data[:4])
    assert rig.raw("POST", target, data[:4], h)[0] == 200
    assert rig.raw("POST", target, data[:4], h)[0] == 401                     # the same request again: its nonce is used
    assert rig.chunk(b["session"], "a.bin", 0, data[:4]) == (409, {"error": "offset", "staged": 4})  # signed anew
    assert rig.chunk(b["session"], "a.bin", 6, data[6:]) == (409, {"error": "offset", "staged": 4})  # a gap
    assert rig.chunk(b["session"], "a.bin", 4, data[4:]) == (200, {"v": 1, "staged": 10})
    rig.commit(b["session"])
    assert (tmp_path / "phone" / "a.bin").read_bytes() == data


def test_an_unknown_or_expired_session(rig: Rig) -> None:
    b = rig.begin(row("a.bin", b"abcd"))
    assert rig.chunk("x" * 22, "a.bin", 0, b"abcd") == (410, {"error": "session"})
    assert rig.post("/push/commit?s=" + "x" * 22, {"v": 1}) == (410, {"error": "session"})
    assert rig.post("/push/commit", {"v": 1}) == (410, {"error": "session"})
    rig.clock.t += pr.SESSION_S - 5
    assert rig.chunk(b["session"], "a.bin", 0, b"ab")[0] == 200   # each request keeps it for another 30 minutes
    rig.clock.t += pr.SESSION_S + 5
    assert rig.chunk(b["session"], "a.bin", 2, b"cd") == (410, {"error": "session"})
    b2 = rig.begin(row("a.bin", b"abcd"))
    assert rig.chunk(b["session"], "a.bin", 2, b"cd")[0] == 410  # a new begin replaces the old session
    assert b2["want"] == [{"path": "a.bin", "from": 0, "have": 2}]


def test_not_paired_and_a_forgotten_phone(tmp_path: Path) -> None:
    rig = Rig(tmp_path, key=None)
    try:
        status, m, extra = rig.raw("POST", "/push/hello", b'{"v":1}', pa.push_headers(KEY, "POST", "/push/hello", b'{"v":1}'))
        assert (status, m) == (403, {"error": "not paired"}) and extra["reply"] is None
    finally:
        rig.close()


def test_not_at_home_nothing_is_taken_and_the_wifi_is_not_listened_on(tmp_path: Path) -> None:
    rig = Rig(tmp_path, home=False, client="127.0.0.1")
    try:
        assert rig.post("/push/hello", {"v": 1})[1]["home"] is False
        assert rig.post("/push/begin", {"v": 1, "port": 8765, "files": listing(row("a.bin", b"a")), "asks": []}) == (
            403, {"error": "not at home"})
        assert inbox(tmp_path) == []
        rig.listener.sync("127.0.0.2")   # 127.0.0.2 stands for the home-network address
        assert rig.listener.bound is None
        with pytest.raises(OSError):
            socket.create_connection(("127.0.0.2", rig.port), timeout=1).close()
        rig.link.where[0] = "home"; rig.link.home_checked = -1e18
        rig.listener.sync("127.0.0.2")
        assert rig.listener.bound == "127.0.0.2"
        socket.create_connection(("127.0.0.2", rig.port), timeout=1).close()
        rig.listener.sync("127.0.0.3")   # the router gave the laptop a new address
        socket.create_connection(("127.0.0.3", rig.port), timeout=1).close()
        with pytest.raises(OSError):
            socket.create_connection(("127.0.0.2", rig.port), timeout=1).close()
        rig.link.where[0] = "a cafe"; rig.link.home_checked = -1e18
        rig.listener.sync("127.0.0.3")
        assert rig.listener.bound is None
        with pytest.raises(OSError):
            socket.create_connection(("127.0.0.3", rig.port), timeout=1).close()
        socket.create_connection(("127.0.0.1", rig.port), timeout=1).close()   # this laptop's own port stays
    finally:
        rig.close()


def test_the_emulator_switch_makes_a_loopback_client_home(tmp_path: Path) -> None:
    rig = Rig(tmp_path, home=False, client="127.0.0.1", allow_loopback_home=True)
    try:
        assert rig.post("/push/hello", {"v": 1})[1]["home"] is True
        assert rig.begin(row("a.bin", b"a"))["want"]
        rig.client = "192.168.1.23"   # a Wi-Fi client is still not at home
        assert rig.post("/push/hello", {"v": 1})[1]["home"] is False
    finally:
        rig.close()


def test_ten_wrong_tries_make_that_address_wait_a_minute(rig: Rig) -> None:
    body = b'{"v":1}'
    for _ in range(pr.TRIES):
        assert rig.post("/push/hello", body, key="0" * 64)[0] == 401
    status, m, extra = rig.raw("POST", "/push/hello", body, pa.push_headers(KEY, "POST", "/push/hello", body))
    assert (status, m) == (429, {"error": "too many tries"}) and extra["reply"] is None   # the right key waits too
    rig.client = "192.168.1.50"   # another device is not held up
    assert rig.post("/push/hello", body)[0] == 200
    rig.client = "192.168.1.23"
    rig.clock.t += pr.BLOCK_S + 1
    assert rig.post("/push/hello", body)[0] == 200


def test_an_address_beyond_the_local_network_is_refused(rig: Rig) -> None:
    body = b'{"v":1}'
    for client in ("8.8.8.8", "100.64.1.2", "2001:db8::1", "not an address"):
        rig.client = client
        status, m, extra = rig.raw("POST", "/push/hello", body, pa.push_headers(KEY, "POST", "/push/hello", body))
        assert (status, m) == (403, {"error": "local network only"}) and extra["reply"] is None, client


def test_another_sites_name_in_host_is_refused(rig: Rig) -> None:
    body = b'{"v":1}'
    h = dict(pa.push_headers(KEY, "POST", "/push/hello", body), Host=f"rebind.example:{rig.port}")
    assert rig.raw("POST", "/push/hello", body, h)[:2] == (403, {"error": "wrong host"})
    h = dict(pa.push_headers(KEY, "POST", "/push/hello", body), Host=f"192.168.1.10:{rig.port}")
    rig.listener.sync(None)   # the address the pairing's code names is this laptop's too (the emulator's 10.0.2.2)
    assert rig.raw("POST", "/push/hello", body, h)[0] == 200


def test_too_many_connections_are_closed_at_once(rig: Rig) -> None:
    held = [socket.create_connection(("127.0.0.1", rig.port), timeout=5) for _ in range(pr.MAX_CONN_EACH)]
    try:
        time.sleep(0.2)
        with socket.create_connection(("127.0.0.1", rig.port), timeout=5) as s:
            s.sendall(b"POST /push/hello HTTP/1.1\r\n\r\n")
            try:
                assert s.recv(100) == b""
            except ConnectionError:
                pass
    finally:
        for s in held:
            s.close()
    time.sleep(0.2)
    assert rig.post("/push/hello", {"v": 1})[0] == 200


# ---------- interrupted uploads ----------

def test_a_cut_upload_leaves_the_real_folders_alone_and_resumes(rig: Rig, tmp_path: Path) -> None:
    data = bytes(range(200)) * 50
    r = row(F32, data)
    b = rig.begin(r)
    assert rig.chunk(b["session"], F32, 0, data[:3000])[0] == 200
    assert rig.chunk(b["session"], F32, 3000, data[3000:4500])[0] == 200
    # ... the phone leaves the Wi-Fi. A commit now takes nothing of the unfinished file
    m = rig.commit(b["session"])
    assert m["summary"]["new"] == 0 and m["acks"] == [] and real_files(tmp_path) == []
    rig.close()
    again = Rig(tmp_path)   # the laptop restarted meanwhile, too
    try:
        b = again.begin(r)
        assert b["want"] == [{"path": F32, "from": 0, "have": 4500}]
        assert again.chunk(b["session"], F32, 0, data[:100]) == (409, {"error": "offset", "staged": 4500})
        assert again.chunk(b["session"], F32, 4500, data[4500:])[0] == 200
        m = again.commit(b["session"])
        assert m["summary"]["new"] == 1 and (tmp_path / "recordings" / "2026-11-19-010000.f32").read_bytes() == data
        assert inbox(tmp_path) == []
    finally:
        again.close()


def test_staged_bytes_of_a_file_that_changed_are_dropped(rig: Rig, tmp_path: Path) -> None:
    old, new = b"old-old-old", b"new-new-new"
    b = rig.begin(row("a.txt", old), row("gone.txt", b"gone"), row("grow.log", b"abcdef", growing=True))
    assert rig.chunk(b["session"], "a.txt", 0, old[:5])[0] == 200
    assert rig.chunk(b["session"], "gone.txt", 0, b"go")[0] == 200
    assert rig.chunk(b["session"], "grow.log", 0, b"abc")[0] == 200
    # the phone changed a.txt (same length, another time and hash), deleted gone.txt; grow.log grew on
    b = rig.begin(row("a.txt", new, modified=T0 + 5), row("grow.log", b"abcdefgh", growing=True, modified=T0 + 9))
    want = {w["path"]: w for w in b["want"]}
    assert want == {"a.txt": {"path": "a.txt", "from": 0, "have": 0},
                    "grow.log": {"path": "grow.log", "from": 0, "have": 3}}
    assert len(inbox(tmp_path)) == 3   # a.txt's note, grow.log's note and part; nothing of gone.txt
    assert rig.chunk(b["session"], "a.txt", 0, new)[0] == 200
    assert rig.chunk(b["session"], "grow.log", 3, b"defgh")[0] == 200
    rig.commit(b["session"])
    assert (tmp_path / "phone" / "a.txt").read_bytes() == new
    assert (tmp_path / "phone" / "grow.log").read_bytes() == b"abcdefgh"


def test_staged_bytes_for_another_start_are_dropped(rig: Rig, tmp_path: Path) -> None:
    """Bytes staged from byte 4 on are of no use once the laptop's own copy ends elsewhere."""
    log = f"{STEM}.log"
    rig.send({log: b"aaaa"}, row(log, b"aaaa", growing=True))
    b = rig.begin(row(log, b"aaaabbbbcc", growing=True, modified=T0 + 1))
    assert b["want"] == [{"path": log, "from": 4, "have": 0}]
    assert rig.chunk(b["session"], log, 4, b"bbb")[0] == 200
    with (tmp_path / "recordings" / "2026-11-19-010000.log").open("ab") as f:   # the pull went on meanwhile
        f.write(b"bbbbc")
    state = tmp_path / "phone" / "pull-state.json"
    m = json.loads(state.read_text()); m["partial"][log] = 9; state.write_text(json.dumps(m))
    b = rig.begin(row(log, b"aaaabbbbcc", growing=True, modified=T0 + 1))
    assert b["want"] == [{"path": log, "from": 9, "have": 0}]
    assert rig.chunk(b["session"], log, 9, b"c")[0] == 200
    rig.commit(b["session"])
    assert (tmp_path / "recordings" / "2026-11-19-010000.log").read_bytes() == b"aaaabbbbcc"


def test_staged_bytes_that_are_not_the_listed_file_do_not_land(rig: Rig, tmp_path: Path) -> None:
    good = b"the right bytes!"
    b = rig.begin(row("a.txt", good))
    assert rig.chunk(b["session"], "a.txt", 0, b"the wrong bytes!")[0] == 200
    m = rig.commit(b["session"])
    assert m["summary"]["damaged"] == 1 and m["acks"] == [] and real_files(tmp_path) == []
    assert inbox(tmp_path) == []   # and they are not kept for another try
    assert rig.send({"a.txt": good}, row("a.txt", good))["summary"]["new"] == 1


def test_a_laptop_copy_that_does_not_add_up_is_asked_for_whole(rig: Rig, tmp_path: Path) -> None:
    """The laptop's own partial copy holds other bytes than the phone's file begins with: the end alone would not
    make the file, so nothing is touched and the next begin asks for all of it; the older copy is kept aside."""
    dst = tmp_path / "recordings" / "2026-11-19-010000.log"
    rig.send({f"{STEM}.log": b"aaaa"}, row(f"{STEM}.log", b"aaaa", growing=True))
    full = b"bbbbcccc"
    r = row(f"{STEM}.log", full, modified=T0 + 5)
    b = rig.begin(r)
    assert b["want"] == [{"path": f"{STEM}.log", "from": 4, "have": 0}]
    rig.chunk(b["session"], f"{STEM}.log", 4, full[4:])
    m = rig.commit(b["session"])
    assert dst.read_bytes() == b"aaaa" and m["summary"]["damaged"] == 0 and m["acks"] == []
    b = rig.begin(r)
    assert b["want"] == [{"path": f"{STEM}.log", "from": 0, "have": 0}]
    rig.chunk(b["session"], f"{STEM}.log", 0, full)
    m = rig.commit(b["session"])
    assert dst.read_bytes() == full and m["summary"]["updated"] == 1
    assert m["acks"] == [{"path": f"{STEM}.log", "sha256": sha(full)}]
    assert [p.read_bytes() for p in (tmp_path / "phone" / "replaced").rglob("*.log")] == [b"aaaacccc"]


# ---------- the pull and the push, at once ----------

def test_a_pass_waits_for_the_other_and_a_commit_says_busy(tmp_path: Path) -> None:
    rig = Rig(tmp_path, lock_wait=0.3)
    try:
        b = rig.begin(row("a.txt", b"abcd"))
        rig.chunk(b["session"], "a.txt", 0, b"abcd")
        with pp.pass_lock(tmp_path):   # a pull pass is running
            assert rig.post(f"/push/commit?s={b['session']}", {"v": 1}) == (503, {"error": "busy"})
            assert real_files(tmp_path) == [] and len(inbox(tmp_path)) == 2   # the staged bytes stay
            with pytest.raises(pp.Busy):
                with pp.pass_lock(tmp_path, 0.1):
                    pass
        assert rig.commit(b["session"])["summary"]["new"] == 1
        state = json.loads((tmp_path / "phone" / "push-state.json").read_text())
        assert state["last_push"] and state["last_try"]
    finally:
        rig.close()


def test_pull_passes_never_interleave(tmp_path: Path) -> None:
    """Two passes over the same folder (the mirror's and a commit's): the second starts only when the first ended."""
    phone = FakePhone()
    events: list[str] = []
    inside = threading.Event()
    go = threading.Event()

    class Slow(pp.Phone):
        def files(self):
            events.append("pull in")
            inside.set()
            go.wait(5)
            out = super().files()
            events.append("pull out")
            return out

    rig = Rig(tmp_path)
    try:
        phone.put("b.txt", b"from the pull")
        b = rig.begin(row("a.txt", b"abcd"))
        rig.chunk(b["session"], "a.txt", 0, b"abcd")
        t = threading.Thread(target=lambda: pp.pull(Slow(phone.base, "abcdefghjkmn"), tmp_path), daemon=True)
        t.start()
        assert inside.wait(5)
        done: list[dict] = []
        c = threading.Thread(target=lambda: (done.append(rig.commit(b["session"])), events.append("commit out")),
                             daemon=True)
        c.start()
        time.sleep(0.4)
        assert events == ["pull in"] and not done   # the commit waits
        go.set()
        t.join(5); c.join(10)
        assert events == ["pull in", "pull out", "commit out"] and done[0]["summary"]["new"] == 1
        assert real_files(tmp_path) == ["phone/a.txt", "phone/b.txt"]
    finally:
        rig.close()
        phone.close()


def test_a_file_half_pulled_is_finished_by_a_push_and_the_other_way_round(rig: Rig, tmp_path: Path) -> None:
    phone = FakePhone()
    try:
        phone.key = KEY
        laptop = pp.Phone(phone.base, key=KEY, home=True)
        dst = tmp_path / "recordings" / "2026-11-19-010000.f32"
        a, b_, c, d = (bytes([k]) * 1000 for k in (1, 2, 3, 4))
        # pulled while it grows...
        phone.put(F32, a, growing=True)
        pp.pull(laptop, tmp_path, key=KEY)
        assert dst.read_bytes() == a
        # ...continued by a push...
        m = rig.send({F32: a + b_}, row(F32, a + b_, growing=True, modified=T0 + 1))
        assert dst.read_bytes() == a + b_ and m["summary"] == dict(m["summary"], grown=1, bytes=1000)
        # ...a push begun, and before its commit the pull took more than the push was asked for...
        s = rig.begin(row(F32, a + b_ + c, growing=True, modified=T0 + 2))
        assert s["want"] == [{"path": F32, "from": 2000, "have": 0}]
        rig.chunk(s["session"], F32, 2000, c)
        phone.put(F32, a + b_ + c[:400], growing=True, modified=T0 + 2)
        pp.pull(laptop, tmp_path, key=KEY)
        assert dst.read_bytes() == a + b_ + c[:400]
        m = rig.commit(s["session"])   # only the 600 bytes the laptop still lacks are added: none twice
        assert dst.read_bytes() == a + b_ + c and m["summary"]["bytes"] == 600
        # ...the pull went past the push altogether: the staged bytes are no longer needed
        s = rig.begin(row(F32, a + b_ + c + d[:10], growing=True, modified=T0 + 3))
        rig.chunk(s["session"], F32, 3000, d[:10])
        phone.put(F32, a + b_ + c + d, growing=True, modified=T0 + 4)
        pp.pull(laptop, tmp_path, key=KEY)
        m = rig.commit(s["session"])
        assert dst.read_bytes() == a + b_ + c + d and m["summary"]["bytes"] == 0
        # ...and the pull finishes it: checked against the SHA-256 and acked to the phone
        phone.put(F32, a + b_ + c + d, modified=T0 + 4)
        rep = pp.pull(laptop, tmp_path, key=KEY)
        assert rep.checked == [F32] and rep.acked == [F32] and dst.read_bytes() == a + b_ + c + d
        assert json.loads((tmp_path / "phone" / "pull-state.json").read_text())["partial"] == {}
        hows = [json.loads(x)["phone"] for x in (tmp_path / "phone" / "pulls.jsonl").read_text().splitlines()]
        assert set(hows) == {"paired", "pushed"}
    finally:
        phone.close()


def test_an_ordinary_pull_still_answers_rechecks_over_http(tmp_path: Path) -> None:
    """`recheck_proofs` is the core of `answer_rechecks`: the same proof either way."""
    data = bytes(range(250)) * 4
    dst = tmp_path / "recordings" / "2026-11-19-010000.f32"
    dst.parent.mkdir(parents=True)
    dst.write_bytes(data)
    ask = {"path": F32, "nonce": "cmVjaGVjay1ub25jZS0wMDE", "bytes": len(data), "ranges": [[0, 10], [500, 20]]}
    mac = pa.recheck_mac(KEY, F32, ask["nonce"], len(data), [(0, 10), (500, 20)], [data[:10], data[500:520]])
    assert pp.recheck_proofs(tmp_path, KEY, [ask, "junk", {"path": "../x"}]) == [
        {"path": F32, "nonce": ask["nonce"], "mac": mac}]
    phone = FakePhone()
    try:
        phone.key = KEY
        phone.put(F32, data)
        phone.asks = [ask]
        rep = pp.pull(pp.Phone(phone.base, key=KEY, home=True), tmp_path, key=KEY)
        assert rep.proven == [F32] and phone.rechecks == [{"path": F32, "nonce": ask["nonce"], "mac": mac, "ok": True}]
    finally:
        phone.close()


# ---------- the tray's line, the kept link, the phone's other ports ----------

def test_the_tray_says_when_the_phone_sent_its_files_by_itself(tmp_path: Path) -> None:
    tz = timezone(timedelta(hours=3))
    now = datetime(2026, 11, 21, 15, 0, tzinfo=tz)
    make_link(tmp_path)
    unreachable = lambda *_a: ("unreachable", None, None)  # noqa: E731
    lk = lw.look_at_phone(tmp_path, now, ask=unreachable, probe=lambda: None)
    assert lk.pushed is None and lw.phone_view(lk, None, 2).lines == (
        "Phone: not reachable (app asleep, or Share on Wi-Fi off?)", "Headband: —")
    (tmp_path / "phone" / "push-state.json").write_text(json.dumps(
        {"last_push": "2026-11-21T14:05:09+03:00", "files": 3, "bytes": 10, "last_try": "2026-11-21T14:05:09+03:00"}))
    lk = lw.look_at_phone(tmp_path, now, ask=unreachable, probe=lambda: None)
    sent = "Phone: sent its files by itself " + lw.hm(datetime(2026, 11, 21, 14, 5, 9, tzinfo=tz))
    assert lw.phone_view(lk, None, 2).lines == (
        "Phone: not reachable (app asleep, or Share on Wi-Fi off?)", sent, "Headband: —")
    ok = lambda *_a: ("ok", {"status": "not recording", "age": 999, "minutes": 0}, None)  # noqa: E731
    lk = lw.look_at_phone(tmp_path, now, ask=ok, probe=lambda: {"connected": True, "sharing": "home",
                                                                "last_copy": "2026-11-21T14:01:00+03:00"})
    lines = lw.phone_view(lk, lk, 0).lines
    assert lines[0].startswith("Phone: sharing on its home Wi-Fi · copied ") and lines[1] == sent and len(lines) == 3
    later = lw.look_at_phone(tmp_path, now + timedelta(days=2), ask=ok, probe=lambda: None)
    assert lw.phone_view(later, later, 0).lines[1].startswith("Phone: sent its files by itself 21 Nov, ")
    import tray
    assert tray.N_PHONE >= 4   # the phone, sent by itself, the headband, a break
    (tmp_path / "phone" / "push-state.json").write_text("not json")
    assert lw.look_at_phone(tmp_path, now, ask=ok, probe=lambda: None).pushed is None


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_keep_takes_the_phones_files_and_follows_home(tmp_path: Path) -> None:
    make_link(tmp_path)
    port, push_port = _free_port(), _free_port()
    a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(port), "--push-port", str(push_port), "--no-pages",
                  "--no-mirror", "--push-loopback-home"])
    assert pl.parse([]).push_port == 8772 and not pl.parse([]).no_push and not pl.parse([]).push_loopback_home
    out: list[str] = []
    stop = threading.Event()
    done: list[int] = []
    t = threading.Thread(target=lambda: done.append(pl.keep(a, out.append, find=lambda: None, stop=stop, look_s=0.1)),
                         daemon=True)
    t.start()
    try:
        def post(target: str, body: bytes) -> tuple[int, dict]:
            c = http.client.HTTPConnection("127.0.0.1", push_port, timeout=5)
            try:
                c.request("POST", target, body=body, headers=pa.push_headers(KEY, "POST", target, body))
                r = c.getresponse()
                return r.status, json.loads(r.read())
            finally:
                c.close()

        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                socket.create_connection(("127.0.0.1", push_port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.02)
        status, hello = post("/push/hello", b'{"v":1}')
        assert status == 200 and hello["home"] is True and hello["app"] == "eeg-tracker-laptop" and hello["name"]
        status, b = post("/push/begin", json.dumps({"v": 1, "port": None, "files": listing(row("a.txt", b"abcd")),
                                                    "asks": []}).encode())
        assert status == 200
        assert post(f"/push/chunk?s={b['session']}&p=a.txt&at=0", b"abcd")[0] == 200
        assert post(f"/push/commit?s={b['session']}", b'{"v":1}')[1]["summary"]["new"] == 1
        assert (tmp_path / "phone" / "a.txt").read_bytes() == b"abcd"
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/status", timeout=5) as r:
            assert json.loads(r.read())["last_push"] is not None
        assert any("sent its files by itself" in x for x in out) and not any("127.0.0." in x for x in out)
    finally:
        stop.set()
        t.join(5)
    assert done == [0]
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", push_port), timeout=1).close()
    # --no-push: the port is not opened at all
    a = pl.parse(["--keep", "--dest", str(tmp_path), "--port", str(port), "--push-port", str(push_port), "--no-pages",
                  "--no-mirror", "--no-push"])
    stop = threading.Event()
    t = threading.Thread(target=lambda: pl.keep(a, out.append, find=lambda: None, stop=stop), daemon=True)
    t.start()
    try:
        end = time.monotonic() + 5
        while time.monotonic() < end:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.02)
        with pytest.raises(OSError):
            socket.create_connection(("127.0.0.1", push_port), timeout=1).close()
    finally:
        stop.set()
        t.join(5)


def test_the_mirror_finds_the_phone_at_a_fallback_port(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ports = sorted(_free_port() for _ in range(4))
    monkeypatch.setattr(pl, "PHONE_PORTS", tuple(ports))
    stranger = FakePhone(port=ports[1])   # something else on one of the ports: it cannot prove the key
    phone = FakePhone(port=ports[2])      # the phone, on its second fallback port
    try:
        stranger.key, phone.key = "0" * 64, KEY
        phone.put("a.txt", b"abcd")
        link = make_link(tmp_path)
        link.phone = pl.PhoneAt("127.0.0.1", ports[0])   # where it was: nothing there now
        lines: list[str] = []
        swept: list[int] = []
        pl.mirror_pass(link, tmp_path, pl.Say(lines.append), [None], hosts=lambda: swept.append(1) or [])
        assert link.target() == ("127.0.0.1", ports[2]) and link.answering and not swept
        assert (tmp_path / "phone" / "a.txt").read_bytes() == b"abcd"
        assert json.loads((tmp_path / "phone" / "link.json").read_text())["phone"]["port"] == ports[2]
        assert stranger.requests == [("GET", "/who", None)]
        # moved_to keeps the port when only the address is new, and says nothing when nothing changed
        told: list[pl.PhoneAt] = []
        link.listeners.append(lambda p, _paired: told.append(p))
        link.moved_to("127.0.0.1", ports[2])
        link.moved_to("192.168.1.30")
        assert told == [pl.PhoneAt("192.168.1.30", ports[2])]
    finally:
        stranger.close()
        phone.close()


# ---------- Record first: the spans files and the answers reach the laptop both ways ----------
SPANS = "spans/2026-11-24-230000.spans.jsonl"
SMALL = (SPANS, "confirm/estimates.jsonl", "confirm/answers.jsonl", "archive/2026-11-24-230000.tags.json")


def _span_line(end: str | None) -> bytes:
    return (json.dumps({"v": 1, "span": "r-1", "kind": "sleep", "start": "2026-11-24T23:10:00+03:00", "end": end,
                        "source": "owner_button", "made": "2026-11-24T23:10:00+03:00"}) + "\n").encode()


def _sleep_spans_on_laptop(dest: Path) -> list[tuple[str, bool]]:
    import spans  # the laptop's reader of what just landed
    f = spans.for_recording(dest, "2026-11-24-230000")
    return [(s.kind, s.closed) for s in f.spans]


def test_a_push_carries_the_spans_file_and_the_answers_and_a_later_push_the_longer_file(rig: Rig, tmp_path: Path) -> None:
    files = {SPANS: _span_line(None), "confirm/estimates.jsonl": b'{"id": "e1"}\n',
             "confirm/answers.jsonl": b'{"id": "e1", "answer": "yes"}\n',
             "archive/2026-11-24-230000.tags.json": b'{"tags": []}'}
    m = rig.send(files, *(row(p, files[p]) for p in SMALL))
    assert m["summary"]["new"] == 4 and m["summary"]["damaged"] == 0
    for p in SMALL:
        assert (tmp_path / "phone" / p).read_bytes() == files[p], p
    assert sorted(a["path"] for a in m["acks"]) == sorted(SMALL)
    assert _sleep_spans_on_laptop(tmp_path) == [("sleep", False)]
    # Stop sleep adds a line on the phone: the next push brings the file as it is now
    longer = files[SPANS] + _span_line("2026-11-25T07:00:00+03:00")
    m = rig.send({SPANS: longer}, row(SPANS, longer, modified=T0 + 60_000))
    assert (tmp_path / "phone" / SPANS).read_bytes() == longer and m["summary"]["updated"] == 1
    assert _sleep_spans_on_laptop(tmp_path) == [("sleep", True)]


def test_the_laptops_own_copy_pass_carries_the_spans_file_and_the_answers(tmp_path: Path) -> None:
    phone = FakePhone()
    try:
        first = _span_line(None)
        phone.put(SPANS, first)
        phone.put("confirm/estimates.jsonl", b'{"id": "e1"}\n')
        phone.put("confirm/answers.jsonl", b'{"id": "e1", "answer": "no"}\n')
        rep = pp.pull(pp.Phone(phone.base, "abcdefghjkmn"), tmp_path)
        assert sorted(rep.new) == sorted(SMALL[:3]) and not rep.refused and not rep.damaged
        assert _sleep_spans_on_laptop(tmp_path) == [("sleep", False)]
        longer = first + _span_line("2026-11-25T07:00:00+03:00")
        phone.put(SPANS, longer, modified=T0 + 60_000)
        rep = pp.pull(pp.Phone(phone.base, "abcdefghjkmn"), tmp_path)
        assert rep.updated == [SPANS] and (tmp_path / "phone" / SPANS).read_bytes() == longer
        assert _sleep_spans_on_laptop(tmp_path) == [("sleep", True)]
    finally:
        phone.close()
