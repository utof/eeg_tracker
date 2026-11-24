"""The laptop's receiver for files the phone sends by itself (the phone opens the connection; the laptop only takes).

Runs inside `phone_link.py --keep` on port 8772: on 127.0.0.1 always, and on this laptop's home-network address only
while the laptop is on the network where it paired; never on every interface. Plain HTTP, like the pull.

- Every request is a POST signed with the pairing's key (phone_auth.push_sign: method, path and query, a time, a nonce
  used once, the body's SHA-256). Every answer to a well signed request proves the key back over the request's nonce
  and the answer's own bytes (phone_auth.push_reply). Anything else gets `{"error": ...}` and nothing more.
- Upload only. There is no listing and nothing of this laptop's files is ever sent. A client never names a file on
  this disk: what it sends is kept in `<dest>/phone/push-inbox/` under names made from a hash, and only a pass of
  pull_phone.pull() (its path check, temporary names, SHA-256 check, atomic rename) moves bytes into the real folders.
- `/push/hello`: is this the paired laptop, and is it at home. `/push/begin`: the phone's list (as GET /files gives
  it); the answer says which byte ranges this laptop lacks (`want`). `/push/chunk`: those bytes, in order, appended
  to the inbox. `/push/commit`: one pull_phone.pull() pass fed from the inbox, under the same lock every pass takes,
  so the phone's sending and the laptop's own copying never interleave; the answer carries the acks and the re-check
  proofs the pass made.
- Sizes are bounded before a body is read; ten wrong tries a minute from one address make it wait a minute; at most
  16 connections (4 from one address); idle connections close after 30 s.

Standard library only (with pull_phone.py, import_phone.py, packed.py, phone_auth.py, local_http.py).
"""
from __future__ import annotations

import hashlib, hmac, json, os, secrets, shutil, sys, threading, time
from dataclasses import dataclass, replace
from datetime import datetime
from http.server import BaseHTTPRequestHandler
from pathlib import Path, PurePosixPath
from typing import Callable
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find the other scripts even under `python3 -I`
import import_phone as ip  # noqa: E402
import local_http  # noqa: E402
import packed  # noqa: E402
import phone_auth as pa  # noqa: E402
import pull_phone as pp  # noqa: E402

PUSH_PORT = 8772
MAX_CHUNK = 4 * 1024 * 1024
LIMITS = {"/push/hello": 4096, "/push/begin": 4 * 1024 * 1024, "/push/chunk": MAX_CHUNK, "/push/commit": 4096}
CLOCK_SLACK_MS = 5 * 60 * 1000  # a request's time may differ this much from this laptop's clock
NONCE_KEEP_S = 600.0
NONCE_CAP = 20000
TRIES, TRIES_S, BLOCK_S = 10, 60.0, 60.0  # wrong tries from one address within a minute; then it waits a minute
SESSION_S = 1800.0  # a session ends this long after its last request
LOCK_WAIT_S = 20.0  # a commit waits this long for a running pull pass, then answers 503
STAGING_CAP = 8 * 1024 ** 3  # bytes the inbox may hold
FREE_MARGIN = 1024 ** 3  # bytes of the disk never planned for
MAX_CONN, MAX_CONN_EACH = 16, 4
IDLE_S = 30.0
INBOX = "push-inbox"
STATE_FILE = "push-state.json"


def _json(obj: dict) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode()


def _iso(t: datetime | None = None) -> str:
    return (t or datetime.now().astimezone()).isoformat(timespec="seconds")


def read_state(dest: Path) -> dict:
    """`<dest>/phone/push-state.json` ({last_push, files, bytes, last_try}); {} without one."""
    try:
        m = json.loads((dest / "phone" / STATE_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return m if isinstance(m, dict) else {}


def _write_state(dest: Path, m: dict) -> None:
    f = dest / "phone" / STATE_FILE
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text(json.dumps(m, sort_keys=True), encoding="utf-8")
    os.replace(tmp, f)


# --- what this laptop lacks of a listed file: pull()'s own decisions, without fetching

def wanted_from(e: pp.Listed, dest: Path, index: ip.Index, state: pp.State) -> int | None:
    """Where pull_phone.pull() would start fetching [e] now: 0 for the whole file, the laptop's own partial copy's
    length to continue it, None when it would fetch nothing (the same bytes are here; the laptop's copy is as new or
    newer; it differs and the phone is still writing it). Must say what pull()'s loop does (a test compares them)."""
    key, dst = str(e.path), ip.target_for(dest, e.path)
    if e.original is not None or packed.is_packed(ip.on_laptop(dst) or dst):
        return _wanted_packed(e, dest, index, state)
    if not dst.is_file():
        return 0
    have = dst.stat().st_size
    if e.sha256 is not None and have == e.bytes and index.sha(dst) == e.sha256:
        return None
    ours = key in state.partial or (state.raw.get(key) == have and have < e.bytes)
    if ours and have <= e.bytes:
        if have < e.bytes:
            return have
        if e.sha256 is None:
            return None
        return None if ip.hash_file(dst) == e.sha256 else 0  # a partial copy that does not add up is fetched whole
    if e.modified_ms <= dst.stat().st_mtime_ns // 1_000_000 or e.sha256 is None:
        return None  # kept, or waiting
    return 0


def _wanted_packed(e: pp.Listed, dest: Path, index: ip.Index, state: pp.State) -> int | None:
    path, size, digest = e.lands
    key, dst = str(path), ip.target_for(dest, path)
    have = ip.on_laptop(dst)
    if digest is None or e.sha256 is None:
        return None
    if have is None:
        return 0
    try:
        have_bytes = ip.size_of(dst)
        same = have_bytes == size and index.sha(dst) == digest
    except OSError:
        have_bytes, same = -1, False
    if same:
        return None
    ours = key in state.partial or state.raw.get(key) == have_bytes
    if not ours and e.modified_ms <= have.stat().st_mtime_ns // 1_000_000:
        return None
    return 0


# --- the inbox

class Inbox:
    """`<dest>/phone/push-inbox/`: for each wanted path `<hash of the path>.part` (bytes [from, from+its length) of
    the phone's file, only ever added to) and `<hash>.json` ({path, from, bytes_listed, modified_ms, sha256}). No name
    here comes from a client."""

    def __init__(self, dest: Path) -> None:
        self.dir = dest / "phone" / INBOX

    @staticmethod
    def name(path: str) -> str:
        return hashlib.sha256(path.encode("utf-8")).hexdigest()[:40]

    def part(self, path: str) -> Path:
        return self.dir / (self.name(path) + ".part")

    def meta(self, path: str) -> dict | None:
        try:
            m = json.loads((self.dir / (self.name(path) + ".json")).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return m if isinstance(m, dict) and m.get("path") == path else None

    def size(self, path: str) -> int:
        try:
            return self.part(path).stat().st_size
        except OSError:
            return 0

    def note(self, path: str, start: int, e: pp.Listed) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        f = self.dir / (self.name(path) + ".json")
        tmp = f.with_name(f.name + ".tmp")
        tmp.write_text(json.dumps({"path": path, "from": start, "bytes_listed": e.bytes, "modified_ms": e.modified_ms,
                                   "sha256": e.sha256}), encoding="utf-8")
        os.replace(tmp, f)

    def add(self, path: str, body: bytes) -> int:
        """Appends [body]; on the disk before this returns. The length staged now."""
        fd = os.open(self.part(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            view = memoryview(body)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
            return os.fstat(fd).st_size
        finally:
            os.close(fd)

    def drop(self, path: str) -> None:
        for suffix in (".part", ".json"):
            (self.dir / (self.name(path) + suffix)).unlink(missing_ok=True)

    def sweep(self, keep: set[str]) -> None:
        """Everything not staged for one of the paths in [keep] goes."""
        names = {self.name(p) for p in keep}
        try:
            found = list(self.dir.iterdir())
        except OSError:
            return
        for f in found:
            if f.name.split(".")[0] not in names or f.suffix not in (".part", ".json"):
                try:
                    f.unlink()
                except OSError:
                    pass


@dataclass
class Want:
    e: pp.Listed
    start: int  # `from`: where in the phone's file the staged bytes begin


@dataclass
class Session:
    id: str
    listed: list[pp.Listed]
    bad: list[str]
    wants: dict[str, Want]
    asks: list
    used: float


class StagedPhone:
    """What pull_phone.pull() takes for the phone during a commit: the session's list and the bytes in the inbox, so
    pull's own rules decide everything. Nothing here talks to the phone: the acks and the re-check proofs are
    collected and go back in the commit's answer."""

    how = "pushed"
    acks_always = True

    def __init__(self, receiver: "Receiver", session: Session, key: str) -> None:
        self.r, self.s, self.key = receiver, session, key
        self.acks: list[dict[str, str]] = []
        self.proofs: list[dict] = []
        self.looked: list[str] = []  # wanted paths this pass was shown: their staged bytes are used up

    def who(self) -> dict | None:
        return None

    def files(self) -> tuple[list[pp.Listed], list[str]]:
        """The listed entries that need nothing, or whose needed bytes are all in the inbox; the others are simply
        not looked at in this pass. Called by pull() under its lock, so what the laptop holds is looked at afresh."""
        r = self.r
        index, state = ip.Index(r.dest, False), pp.State(r.dest)
        out = []
        for e in self.s.listed:
            key = str(e.path)
            try:
                need = wanted_from(e, r.dest, index, state)
            except OSError:
                continue
            if need is None or need >= e.bytes:
                out.append(e)
                continue
            w = self.s.wants.get(key)
            if w is None or w.start > need or w.start + r.inbox.size(key) < e.bytes:
                continue
            if need > 0 and w.start > 0 and e.sha256 is not None and not self._adds_up(e, need, w):
                r.inbox.drop(key)       # the laptop's own beginning is not the phone's: the next begin asks for
                del self.s.wants[key]   # the whole file
                r.whole.add(key)
                continue
            self.looked.append(key)
            out.append(e)
        return out, list(self.s.bad)

    def _adds_up(self, e: pp.Listed, need: int, w: Want) -> bool:
        """Whether the laptop's first [need] bytes and the staged rest make the file the phone lists."""
        h = hashlib.sha256()
        try:
            with ip.target_for(self.r.dest, e.path).open("rb") as f:
                left = need
                while left > 0 and (b := f.read(min(ip.CHUNK, left))):
                    h.update(b)
                    left -= len(b)
            if left:
                return False
            self.fetch(e.path, need, e.bytes, None, h)
        except OSError:
            return False
        return h.hexdigest() == e.sha256

    def fetch(self, path: PurePosixPath, start: int, end: int, out, digest=None) -> int:
        """Bytes [start, end) of the phone's file from the inbox; 0 when they are not there."""
        w = self.s.wants.get(str(path))
        if end <= start or w is None or start < w.start:
            return 0
        n = 0
        try:
            with self.r.inbox.part(str(path)).open("rb") as f:
                f.seek(start - w.start)
                while n < end - start and (b := f.read(min(ip.CHUNK, end - start - n))):
                    if out is not None:
                        out.write(b)
                    if digest is not None:
                        digest.update(b)
                    n += len(b)
        except OSError:
            return n
        return n

    def ack(self, files: list[dict[str, str]], key: str | None = None) -> tuple[list[str], list[dict]]:
        self.acks += files
        return [f["path"] for f in files], []

    def asks(self) -> list | None:
        return self.s.asks or None

    def prove(self, proofs: list[dict]) -> dict | None:
        self.proofs += proofs
        return None  # the phone checks them when it reads the commit's answer


class Receiver:
    """The rules of the four routes, apart from HTTP. [link]: phone_link.py's `Link` (its key, name, `at_home()`,
    `moved_to()`, `last_push`)."""

    def __init__(self, link, dest: Path, say: Callable[..., object], *, client_ok: Callable[[str], bool],
                 is_loopback: Callable[[str], bool], allow_loopback_home: bool = False, raw_only: bool = False,
                 after: Callable[[bool], object] | None = None, now: Callable[[], float] = time.time,
                 clock: Callable[[], float] = time.monotonic, free: Callable[[Path], int] | None = None,
                 staging_cap: int = STAGING_CAP, lock_wait: float = LOCK_WAIT_S) -> None:
        self.link, self.dest, self.say = link, dest, say
        self.client_ok, self.is_loopback = client_ok, is_loopback
        self.allow_loopback_home, self.raw_only, self.after = allow_loopback_home, raw_only, after
        self.now, self.clock = now, clock
        self.free = free or (lambda d: shutil.disk_usage(d).free)
        self.staging_cap, self.lock_wait = staging_cap, lock_wait
        self.inbox = Inbox(dest)
        self.lock = threading.Lock()   # one begin, chunk or commit at a time
        self.guard = threading.Lock()  # the nonces and the wrong tries
        self.session: Session | None = None
        self.whole: set[str] = set()   # paths whose laptop copy did not add up: asked for whole at the next begin
        self.nonces: dict[str, float] = {}
        self.tries: dict[str, list[float]] = {}
        self.blocked: dict[str, float] = {}
        self.extra_hosts: tuple[str, ...] = ()
        last = read_state(dest).get("last_push")
        if isinstance(last, str) and getattr(link, "last_push", None) is None:
            link.last_push = last

    # --- who may ask
    def home(self, client: str) -> bool:
        return (self.allow_loopback_home and self.is_loopback(client)) or bool(self.link.at_home())

    def is_blocked(self, client: str) -> bool:
        with self.guard:
            return self.blocked.get(client, -1e18) > self.clock()

    def wrong_try(self, client: str) -> None:
        with self.guard:
            t = self.clock()
            if len(self.tries) > 1024:
                self.tries = {k: v for k, v in self.tries.items() if v and t - v[-1] < TRIES_S}
                self.blocked = {k: v for k, v in self.blocked.items() if v > t}
            mine = [x for x in self.tries.get(client, []) if t - x < TRIES_S] + [t]
            self.tries[client] = mine
            if len(mine) >= TRIES:
                self.blocked[client] = t + BLOCK_S
                self.tries[client] = []

    def fresh(self, nonce: str) -> bool:
        """True once for each nonce (kept 10 minutes; at most 20000, the oldest dropped first)."""
        with self.guard:
            t = self.clock()
            if len(self.nonces) >= NONCE_CAP // 2:
                self.nonces = {k: v for k, v in self.nonces.items() if t - v < NONCE_KEEP_S}
            while len(self.nonces) >= NONCE_CAP:
                self.nonces.pop(next(iter(self.nonces)))
            if nonce in self.nonces and t - self.nonces[nonce] < NONCE_KEEP_S:
                return False
            self.nonces[nonce] = t
            return True

    # --- the routes
    def hello(self, client: str, body: object) -> tuple[int, dict]:
        if not isinstance(body, dict) or body.get("v") != 1:
            return 400, {"error": "bad request"}
        return 200, {"v": 1, "app": "eeg-tracker-laptop", "home": self.home(client), "name": str(self.link.name)}

    def _session(self, sid: str | None) -> Session | None:
        s = self.session
        if s is None or sid is None or not hmac.compare_digest(s.id.encode(), sid.encode()):
            return None
        if self.clock() - s.used > SESSION_S:
            self.session = None
            return None
        s.used = self.clock()
        return s

    def begin(self, client: str, body: object) -> tuple[int, dict]:
        if not isinstance(body, dict) or body.get("v") != 1:
            return 400, {"error": "bad request"}
        port, asks = body.get("port"), body.get("asks", [])
        if port is not None and not (isinstance(port, int) and not isinstance(port, bool) and 1024 <= port <= 65535):
            return 400, {"error": "bad request"}
        if not isinstance(asks, list):
            return 400, {"error": "bad request"}
        if not self.home(client):
            return 403, {"error": "not at home"}
        try:
            listed, bad = pp.read_list(body.get("files"))
        except pp.Refused:
            return 400, {"error": "bad request"}
        with self.lock:
            answer = self._plan(pp.order(listed), bad, asks)
        if not self.is_loopback(client):  # where the laptop's own copying finds the phone
            self.link.moved_to(client, port)
        return 200, answer

    def _plan(self, listed: list[pp.Listed], bad: list[str], asks: list) -> dict:
        index, state = ip.Index(self.dest, False), pp.State(self.dest)  # read only: nothing of them is saved here
        try:
            self.inbox.dir.mkdir(parents=True, exist_ok=True)
            room = self.free(self.inbox.dir) - FREE_MARGIN
        except OSError:
            room = 0
        cap = self.staging_cap
        wants: dict[str, Want] = {}
        answer, skipped = [], 0
        for e in listed:
            key = str(e.path)
            if self.raw_only and not pp.is_raw(e.path):
                continue
            try:
                start = wanted_from(e, self.dest, index, state)
            except OSError:
                continue
            if start is None or start >= e.bytes:
                continue
            if key in self.whole:
                start = 0
            size = e.bytes - start
            have, m = self.inbox.size(key), self.inbox.meta(key)
            unchanged = m is not None and (m.get("bytes_listed"), m.get("modified_ms"), m.get("sha256")) == (
                e.bytes, e.modified_ms, e.sha256)
            if not (m is not None and m.get("from") == start and have <= size
                    and (unchanged or (e.sha256 is None and e.bytes >= start + have))):
                self.inbox.drop(key)
                have = 0
            # the inbox holds [size] in the end, and the pass then writes as much again into the real folders
            if size > cap or (size - have) + size > room:
                skipped += 1
                continue
            cap -= size
            room -= (size - have) + size
            self.inbox.note(key, start, e)
            wants[key] = Want(e, start)
            answer.append({"path": key, "from": start, "have": have})
        self.inbox.sweep(set(wants))
        self.session = Session(secrets.token_urlsafe(16), listed, bad, wants, asks, self.clock())
        return {"v": 1, "session": self.session.id, "max_chunk": MAX_CHUNK, "want": answer, "skipped": skipped,
                "refused": len(bad)}

    def chunk(self, query: dict[str, list[str]], body: bytes) -> tuple[int, dict]:
        sid, path, at = (query.get(k, [None])[0] for k in ("s", "p", "at"))
        if path is None or at is None or not at.isascii() or not at.isdigit() or len(at) > 18:
            return 400, {"error": "bad request"}
        with self.lock:
            s = self._session(sid)
            if s is None:
                return 410, {"error": "session"}
            w = s.wants.get(path)  # only a path this laptop asked for; no name is made from [path]
            if w is None:
                return 404, {"error": "not wanted"}
            staged = self.inbox.size(path)
            if int(at) != w.start + staged:
                return 409, {"error": "offset", "staged": staged}
            if not body:
                return 400, {"error": "bad request"}
            if int(at) + len(body) > w.e.bytes:
                return 413, {"error": "too big"}
            if self.inbox.meta(path) is None:
                return 410, {"error": "session"}
            return 200, {"v": 1, "staged": self.inbox.add(path, body)}

    def commit(self, query: dict[str, list[str]], body: object) -> tuple[int, dict]:
        if not isinstance(body, dict) or body.get("v") != 1:
            return 400, {"error": "bad request"}
        key = self.link.key
        with self.lock:
            s = self._session(query.get("s", [None])[0])
            if s is None or key is None:
                return 410, {"error": "session"}
            now = datetime.now().astimezone()
            state = read_state(self.dest)
            state["last_try"] = _iso(now)
            phone = StagedPhone(self, s, key)
            try:
                rep = pp.pull(phone, self.dest, raw_only=self.raw_only, now=now, key=key, lock_wait=self.lock_wait)
            except pp.Busy:
                _write_state(self.dest, state)
                return 503, {"error": "busy"}
            except Exception as e:  # the staged bytes stay: the phone commits again later
                _write_state(self.dest, state)
                self.say(f"PROBLEM taking the files the phone sent: {type(e).__name__}: {e}")
                return 500, {"error": "failed"}
            for p in phone.looked:  # used up, whatever the pass made of them
                self.inbox.drop(p)
                s.wants.pop(p, None)
                self.whole.discard(p)
            acked = {a["path"] for a in phone.acks}
            s.listed = [replace(e, acked=True) if str(e.path) in acked else e for e in s.listed]
            s.asks = []
            got = len(rep.new) + len(rep.grown) + len(rep.checked) + len(rep.updated)
            state.update(last_push=_iso(now), files=got, bytes=rep.fetched)
            _write_state(self.dest, state)
            self.link.last_push = state["last_push"]
        lines = pp.summary(rep, self.dest, now)
        self.say("The phone sent its files by itself: " + lines[0].split(" ", 1)[1])
        for line in lines[1:]:
            self.say(line, stamp=False)
        if self.after is not None:
            try:
                self.after(rep.changed)
            except Exception as e:  # what runs after a copy must not fail the phone's commit
                self.say(f"PROBLEM after the phone's files: {type(e).__name__}: {e}")
        return 200, {"v": 1, "acks": phone.acks, "proofs": phone.proofs,
                     "summary": {"new": len(rep.new), "grown": len(rep.grown), "checked": len(rep.checked),
                                 "updated": len(rep.updated), "kept": len(rep.kept), "damaged": len(rep.damaged),
                                 "waiting": len(rep.waiting), "bytes": rep.fetched}}


# --- HTTP

class _Server(local_http.LocalServer):
    """At most MAX_CONN connections, MAX_CONN_EACH from one address: one more is closed at once."""
    request_queue_size = 16

    def __init__(self, *a, **k) -> None:
        self.gate = threading.Lock()
        self.open_by: dict[str, int] = {}
        super().__init__(*a, **k)

    def process_request(self, request, client_address) -> None:
        who = str(client_address[0])
        with self.gate:
            if sum(self.open_by.values()) >= MAX_CONN or self.open_by.get(who, 0) >= MAX_CONN_EACH:
                self.shutdown_request(request)
                return
            self.open_by[who] = self.open_by.get(who, 0) + 1
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            who = str(client_address[0])
            with self.gate:
                n = self.open_by.get(who, 1) - 1
                if n > 0:
                    self.open_by[who] = n
                else:
                    self.open_by.pop(who, None)


def make_handler(r: Receiver, client_of: Callable[[BaseHTTPRequestHandler], str] | None = None):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "eeg-tracker-push"
        sys_version = ""
        timeout = IDLE_S

        def log_message(self, *_a) -> None:
            pass

        def _answer(self, code: int, obj: dict, *, nonce: str | None = None, key: str | None = None,
                    close: bool = False) -> None:
            body = _json(obj)
            if close:
                self.close_connection = True
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if nonce is not None and key is not None:
                self.send_header(pa.REPLY_H, pa.push_reply(key, nonce, body))
            if close:
                self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _any(self) -> None:
            try:
                self._route()
            except (OSError, TimeoutError):  # the client went away, or sent too slowly
                self.close_connection = True

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_PATCH = _any

        def _route(self) -> None:
            # nothing of the body is read before the last line of the checks below
            client = client_of(self) if client_of else self.client_address[0]
            if not r.client_ok(client):
                return self._answer(403, {"error": "local network only"}, close=True)
            u = urlsplit(self.path)
            limit = LIMITS.get(u.path)
            if limit is None:
                return self._answer(404, {"error": "not found"}, close=True)
            if self.command != "POST":
                return self._answer(405, {"error": "post only"}, close=True)
            if self.headers.get("Transfer-Encoding") is not None:
                return self._answer(400, {"error": "no transfer encoding"}, close=True)
            length = self.headers.get("Content-Length")
            if length is None:
                return self._answer(411, {"error": "length required"}, close=True)
            if not (length.isascii() and length.isdigit() and len(length) <= 12 and int(length) <= limit):
                return self._answer(413, {"error": "too big"}, close=True)
            key = r.link.key
            if key is None:
                return self._answer(403, {"error": "not paired"}, close=True)
            if r.is_blocked(client):
                return self._answer(429, {"error": "too many tries"}, close=True)
            t, nonce, sign = (self.headers.get(h) or "" for h in (pa.TIME_H, pa.NONCE_H, pa.SIGN_H))
            if not (t.isascii() and t.isdigit() and len(t) <= 16 and pa.NONCE.fullmatch(nonce)
                    and pa.KEY.fullmatch(sign)):
                r.wrong_try(client)
                return self._answer(401, {"error": "signature"}, close=True)
            body = self.rfile.read(int(length))
            if len(body) != int(length):
                self.close_connection = True
                return None
            good = hmac.compare_digest(pa.push_sign(key, "POST", self.path, int(t), nonce, body).encode(),
                                       sign.encode())
            if not good or not r.fresh(nonce):
                r.wrong_try(client)
                return self._answer(401, {"error": "signature"})
            if abs(int(t) - int(r.now() * 1000)) > CLOCK_SLACK_MS:  # well signed: the phone may be told why
                r.wrong_try(client)
                return self._answer(401, {"error": "time"}, nonce=nonce, key=key)
            why = local_http.refused(self, r.extra_hosts)
            if why is not None:
                return self._answer(403, {"error": why}, nonce=nonce, key=key)
            try:
                code, obj = self._run(u.path, parse_qs(u.query, keep_blank_values=True), client, body)
            except Exception as e:  # a bug must not take the receiver down, nor say anything of this disk
                r.say(f"PROBLEM in the phone's sending: {type(e).__name__}")
                code, obj = 500, {"error": "failed"}
            return self._answer(code, obj, nonce=nonce, key=key)

        def _run(self, path: str, query: dict[str, list[str]], client: str, body: bytes) -> tuple[int, dict]:
            if path == "/push/chunk":
                return r.chunk(query, body)
            try:
                m = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError, RecursionError):
                return 400, {"error": "bad request"}
            if path == "/push/hello":
                return r.hello(client, m)
            if path == "/push/begin":
                return r.begin(client, m)
            return r.commit(query, m)

    return H


class Listener:
    """The receiver's port: on 127.0.0.1 from the start, and on this laptop's home-network address only while the
    laptop is at home (`sync`, called twice a second; it follows a new address). Never on every interface."""

    def __init__(self, receiver: Receiver, port: int = PUSH_PORT, handler=None) -> None:
        self.r, self.port = receiver, port
        self.handler = handler or make_handler(receiver)
        self.loop = self._serve("127.0.0.1")
        self.lan: _Server | None = None
        self.bound: str | None = None

    def _serve(self, address: str) -> _Server | None:
        try:
            srv = _Server((address, self.port), self.handler)
        except OSError:
            return None
        threading.Thread(target=srv.serve_forever, args=(0.1,), daemon=True, name=f"push {address}").start()
        return srv

    def sync(self, address: str | None) -> None:
        want = address if address and address != "127.0.0.1" and self.r.link.key and self.r.link.at_home() else None
        self.r.extra_hosts = tuple(h for h in (getattr(self.r.link, "host", None), want) if h)
        if want == self.bound and (want is None or self.lan is not None):
            return
        self._close_lan()
        if want is not None:
            self.lan = self._serve(want)
            self.bound = want if self.lan is not None else None

    def _close_lan(self) -> None:
        if self.lan is not None:
            self.lan.shutdown(); self.lan.server_close()
        self.lan, self.bound = None, None

    def close(self) -> None:
        self._close_lan()
        if self.loop is not None:
            self.loop.shutdown(); self.loop.server_close()
            self.loop = None
