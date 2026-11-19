"""scripts/pull_phone.py against a fake phone: new files, a night file that grows, checks, and what is never overwritten.
Also scripts/page_server.py --token, which passes the phone's token on with every request."""
import hashlib
import json
import os
import sys
import threading
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import import_phone as ip  # noqa: E402
import page_server  # noqa: E402
import pull_phone as pp  # noqa: E402

TOKEN = "abcdefghjkmn"
T0 = 1_763_500_000_000  # ms
NOW = datetime(2026, 11, 19, 3, 12).astimezone()
STEM = "recordings/2026-11-19-010000"


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class FakePhone:
    """The app's Share on Wi-Fi server, as far as the laptop scripts use it."""

    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}
        self.modified: dict[str, int] = {}
        self.growing: set[str] = set()
        self.requests: list[tuple[str, str, str | None]] = []  # (method, path, Range)
        self.corrupt: set[str] = set()  # paths served with a flipped byte
        self.lie: dict[str, dict] = {}  # extra list rows, as sent
        self.originals: dict[str, dict] = {}  # a packed file's `original` (path, bytes, sha256), as the app lists it
        self.down = False
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *_a) -> None:
                pass

            def _send(self, code: int, body: bytes, headers: dict[str, str] | None = None) -> None:
                self.send_response(code)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                fake.requests.append(("GET", self.path, self.headers.get("Range")))
                if fake.down:
                    self._send(500, b""); return
                if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                    self._send(401, b'{"error": "token missing or wrong"}'); return
                if self.path == "/files":
                    rows = [dict(path=p, bytes=len(b), sha256=None if p in fake.growing else sha(b),
                                 modified_ms=fake.modified.get(p, T0), **({"growing": True} if p in fake.growing else {}),
                                 **({"original": fake.originals[p]} if p in fake.originals else {}))
                            for p, b in sorted(fake.files.items())] + list(fake.lie.values())
                    self._send(200, json.dumps(dict(format=pp.FORMAT, version=1, files=rows)).encode()); return
                if self.path == "/state":
                    self._send(200, json.dumps(dict(status="recording", via="phone")).encode()); return
                p = urllib.request.unquote(self.path.removeprefix("/files/"))
                if not self.path.startswith("/files/") or p not in fake.files:
                    self._send(404, b"{}"); return
                body = fake.files[p]
                if p in fake.corrupt and body:
                    body = bytes([body[0] ^ 0xFF]) + body[1:]
                rng = self.headers.get("Range")
                if rng:
                    a, b = rng.removeprefix("bytes=").split("-")
                    a, b = int(a), min(int(b), len(body) - 1)
                    if a >= len(body):
                        self._send(416, b"", {"Content-Range": f"bytes */{len(body)}"}); return
                    self._send(206, body[a:b + 1], {"Content-Range": f"bytes {a}-{b}/{len(body)}"}); return
                self._send(200, body)

            def do_POST(self) -> None:
                n = int(self.headers.get("Content-Length") or 0)
                fake.requests.append(("POST", self.path, self.rfile.read(n).decode()))
                self._send(200 if self.headers.get("Authorization") == f"Bearer {TOKEN}" else 401, b"ok")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def put(self, path: str, body: bytes, *, modified: int = T0, growing: bool = False) -> None:
        self.files[path] = body
        self.modified[path] = modified
        (self.growing.add if growing else self.growing.discard)(path)

    def fetched(self) -> list[tuple[str, str | None]]:
        got = [(p.removeprefix("/files/"), r) for m, p, r in self.requests if m == "GET" and p.startswith("/files/")]
        self.requests.clear()
        return got

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def phone():
    f = FakePhone()
    yield f
    f.close()


def run(phone: FakePhone, dest: Path, **kw) -> pp.Pass:
    return pp.pull(pp.Phone(phone.base, TOKEN), dest, now=NOW, **kw)


def test_new_files_land_in_import_phones_layout_checked_and_timed(phone, tmp_path):
    phone.put(f"{STEM}.f32", b"\x01" * 40)
    phone.put(f"{STEM}.log", b"connected\n")
    phone.put("nights/2026-11-18.report.json", b'{"version": 2}', modified=T0 + 5000)
    phone.put("dream-catcher/2026-11-18-230000 r1.wav", b"RIFF")
    rep = run(phone, tmp_path)
    assert sorted(rep.new) == sorted(phone.files) and not rep.problems and rep.fetched == 40 + 10 + 14 + 4
    raw = tmp_path / "recordings" / "2026-11-19-010000.f32"
    assert raw.read_bytes() == b"\x01" * 40  # next to the laptop's own recordings
    assert (tmp_path / "phone" / "nights" / "2026-11-18.report.json").stat().st_mtime_ns == (T0 + 5000) * 1_000_000
    assert (tmp_path / "phone" / "dream-catcher" / "2026-11-18-230000 r1.wav").read_bytes() == b"RIFF"
    assert not list(tmp_path.rglob("*.pulling"))
    line = json.loads((tmp_path / "phone" / "pulls.jsonl").read_text().splitlines()[-1])
    assert line["new"] == 4 and line["bytes"] == 68
    # a second pass asks only for the list; an import of the same files finds them already here
    phone.requests.clear()
    again = run(phone, tmp_path)
    assert again.same == 4 and not again.changed and phone.fetched() == []
    assert len((tmp_path / "phone" / "pulls.jsonl").read_text().splitlines()) == 1


def test_raw_samples_first_tonights_before_older(phone, tmp_path):
    phone.put("nights/2026-11-18.report.json", b"{}", modified=T0 + 9000)
    phone.put("recordings/2026-11-17-230000.f32", b"old", modified=T0 - 86_400_000)
    phone.put(f"{STEM}.markers.jsonl", b"{}\n", modified=T0 + 10)
    phone.put(f"{STEM}.f32", b"new", modified=T0 + 20, growing=True)
    run(phone, tmp_path)
    assert [p for p, _ in phone.fetched()] == [f"{STEM}.f32", f"{STEM}.markers.jsonl", "recordings/2026-11-17-230000.f32",
                                             "nights/2026-11-18.report.json"]
    assert pp.is_raw(ip.safe_path(f"{STEM}.idx")) and not pp.is_raw(ip.safe_path("nights/x.log"))
    only = tmp_path / "only"
    run(phone, only, raw_only=True)
    assert not (only / "phone" / "nights").exists() and (only / "recordings" / "2026-11-17-230000.f32").exists()


def test_a_growing_night_file_is_fetched_piece_by_piece_then_checked(phone, tmp_path):
    night = bytes(range(200)) * 3
    phone.put(f"{STEM}.f32", night[:100], growing=True)
    rep = run(phone, tmp_path)
    dst = tmp_path / "recordings" / "2026-11-19-010000.f32"
    assert rep.new == [f"{STEM}.f32"] and rep.growing == 1 and dst.read_bytes() == night[:100]
    assert phone.fetched() == [(f"{STEM}.f32", "bytes=0-99")]

    phone.put(f"{STEM}.f32", night[:260], modified=T0 + 120_000, growing=True)
    rep = run(phone, tmp_path)
    assert rep.grown == [f"{STEM}.f32"] and rep.fetched == 160 and dst.read_bytes() == night[:260]
    assert phone.fetched() == [(f"{STEM}.f32", "bytes=100-259")]  # only the new end
    assert dst.stat().st_mtime_ns == (T0 + 120_000) * 1_000_000

    rep = run(phone, tmp_path)  # nothing new on the phone: nothing fetched
    assert not rep.changed and phone.fetched() == []

    phone.put(f"{STEM}.f32", night, modified=T0 + 240_000)  # the night ended: the phone lists its SHA-256
    rep = run(phone, tmp_path)
    assert rep.grown == [f"{STEM}.f32"] and rep.checked == [f"{STEM}.f32"] and dst.read_bytes() == night
    assert phone.fetched() == [(f"{STEM}.f32", "bytes=260-599")]
    assert json.loads((tmp_path / "phone" / "pull-state.json").read_text())["partial"] == {}
    assert run(phone, tmp_path).same == 1
    # the phone's export of the same night, imported later, finds the copy as it should be
    assert ip.Index(tmp_path, False).sha(dst) == sha(night)


def test_a_partial_copy_that_does_not_add_up_is_kept_aside_and_fetched_whole(phone, tmp_path):
    phone.put(f"{STEM}.f32", b"A" * 100, growing=True)
    run(phone, tmp_path)
    dst = tmp_path / "recordings" / "2026-11-19-010000.f32"
    dst.write_bytes(b"B" * 100)  # the laptop's partial copy went wrong
    phone.put(f"{STEM}.f32", b"A" * 150, modified=T0 + 1000)
    rep = run(phone, tmp_path)
    assert rep.updated == [f"{STEM}.f32"] and dst.read_bytes() == b"A" * 150
    aside = tmp_path / "phone" / "replaced" / ip._stamp(NOW) / "recordings" / "2026-11-19-010000.f32"
    assert aside.read_bytes() == b"B" * 100 + b"A" * 50 and rep.replaced_dir == aside.parents[1]


def test_a_closed_runs_log_that_gets_lines_later_is_continued_not_replaced(phone, tmp_path):
    log = b"total samples 100\ndrop (out of range)\n"
    phone.put(f"{STEM}.log", log)
    phone.put("nights/2026-11-18.report.json", b"v1")
    run(phone, tmp_path)
    phone.put(f"{STEM}.log", log + b"reconnect try 1\n", modified=T0 + 60_000)  # rested, so it has a SHA-256 again
    phone.put("nights/2026-11-18.report.json", b"v2 longer", modified=T0 + 60_000)
    phone.requests.clear()
    rep = run(phone, tmp_path)
    assert rep.grown == [f"{STEM}.log"] and rep.checked == [f"{STEM}.log"]
    assert (f"{STEM}.log", f"bytes={len(log)}-{len(log) + 15}") in phone.fetched()
    assert (tmp_path / "recordings" / "2026-11-19-010000.log").read_bytes() == log + b"reconnect try 1\n"
    # a report is rewritten, not added to: replaced whole, the older copy kept aside
    assert rep.updated == ["nights/2026-11-18.report.json"]
    assert (rep.replaced_dir / "phone" / "nights" / "2026-11-18.report.json").read_bytes() == b"v1"
    assert not (rep.replaced_dir / "recordings").exists()
    # a raw copy the owner changed on the laptop is no longer ours to continue
    dst = tmp_path / "recordings" / "2026-11-19-010000.log"
    dst.write_bytes(b"edited on the laptop")
    phone.put(f"{STEM}.log", log + b"reconnect try 1\nreconnect try 2\n", modified=T0 + 120_000, growing=True)
    rep = run(phone, tmp_path)
    assert dst.read_bytes() == b"edited on the laptop" and (rep.kept or rep.waiting) and not rep.grown


def test_never_overwritten_silently(phone, tmp_path):
    # the laptop's own copy is newer: left alone; older: replaced by the phone's, the old one kept aside
    newer = tmp_path / "phone" / "settings.json"
    older = tmp_path / "recordings" / "2026-11-19-010000.log"
    for f, text, ms in ((newer, b"laptop", T0 + 1000), (older, b"laptop", T0 - 1000)):
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(text)
        os.utime(f, ns=(ms * 1_000_000, ms * 1_000_000))
    phone.put("settings.json", b"phone!")
    phone.put(f"{STEM}.log", b"phone log")
    rep = run(phone, tmp_path)
    assert rep.kept == ["settings.json"] and newer.read_bytes() == b"laptop"
    assert rep.updated == [f"{STEM}.log"] and older.read_bytes() == b"phone log"
    assert (rep.replaced_dir / "recordings" / "2026-11-19-010000.log").read_bytes() == b"laptop"
    text = "\n".join(pp.summary(rep, tmp_path, NOW))
    assert "left alone" in text and "older copies are in" in text and "PROBLEM" not in text


def test_a_foreign_copy_is_not_replaced_by_a_file_still_being_written(phone, tmp_path):
    f = tmp_path / "recordings" / "2026-11-19-010000.f32"
    f.parent.mkdir(parents=True)
    f.write_bytes(b"laptop")
    os.utime(f, ns=((T0 - 1000) * 1_000_000,) * 2)
    phone.put(f"{STEM}.f32", b"phone, growing", growing=True)
    rep = run(phone, tmp_path)
    assert rep.waiting == [f"{STEM}.f32"] and f.read_bytes() == b"laptop" and phone.fetched() == []


def test_a_damaged_download_is_not_kept(phone, tmp_path):
    phone.put(f"{STEM}.f32", b"\x01" * 40)
    phone.corrupt.add(f"{STEM}.f32")
    rep = run(phone, tmp_path)
    assert rep.damaged == [f"{STEM}.f32"] and rep.problems
    assert not (tmp_path / "recordings" / "2026-11-19-010000.f32").exists() and not list(tmp_path.rglob("*.pulling"))
    assert any(line.startswith("PROBLEM") for line in pp.summary(rep, tmp_path, NOW))
    # and an older laptop copy goes back where it was
    old = tmp_path / "recordings" / "2026-11-19-010000.f32"
    old.write_bytes(b"laptop")
    os.utime(old, ns=((T0 - 1000) * 1_000_000,) * 2)
    rep = run(phone, tmp_path)
    assert rep.damaged == [f"{STEM}.f32"] and old.read_bytes() == b"laptop"


def test_paths_that_leave_the_folder_are_refused(phone, tmp_path):
    phone.put("settings.json", b"{}")
    for i, bad in enumerate(("../outside.txt", "/etc/passwd", "a/../../b", "manifest.json", "")):
        phone.lie[str(i)] = dict(path=bad, bytes=1, sha256=sha(b"x"), modified_ms=T0)
    phone.lie["dup"] = dict(path="settings.json", bytes=2, sha256=sha(b"{}"), modified_ms=T0)
    phone.lie["sha"] = dict(path="x.json", bytes=2, sha256="nope", modified_ms=T0)
    rep = run(phone, tmp_path)
    assert rep.new == ["settings.json"] and len(rep.refused) == 7 and rep.problems
    assert not (tmp_path.parent / "outside.txt").exists()
    assert sorted(p.name for p in tmp_path.rglob("*") if p.is_file()) == ["import-index.json", "pull-state.json", "pulls.jsonl",
                                                                         "settings.json"]


def test_main_wrong_token_no_answer_and_the_loop(phone, tmp_path):
    out: list[str] = []
    phone.put(f"{STEM}.f32", b"\x01" * 40)
    assert pp.main([phone.base, "--token", "wrong", "--once", "--dest", str(tmp_path)], out.append) == 2
    assert "refused the token" in out[-1] and not (tmp_path / "recordings").exists()
    assert pp.main([phone.base, "--once", "--dest", str(tmp_path)], out.append) == 2 and "--token" in out[-1]
    assert pp.main(["http://127.0.0.1:9", "--token", TOKEN, "--once", "--dest", str(tmp_path)], out.append) == 1
    assert "no answer" in out[-1]

    passes = []

    def sleep(seconds: float) -> None:  # between passes: the phone falls asleep once, then the night grows
        passes.append(seconds)
        if len(passes) == 1:
            phone.down = True
        elif len(passes) == 2:
            phone.down = False
            phone.put(f"{STEM}.f32", b"\x01" * 60, growing=True)
        else:
            raise KeyboardInterrupt

    out.clear()
    assert pp.main([phone.base, "--token", TOKEN, "--every", "5", "--dest", str(tmp_path)], out.append, sleep) == 0
    assert passes == [300, 300, 300]
    assert "1 new" in out[0] and "trying again in 5 min" in out[1] and "1 grown" in out[2]
    assert (tmp_path / "recordings" / "2026-11-19-010000.f32").stat().st_size == 60


def test_not_the_apps_list(phone, tmp_path):
    class Other(pp.Phone):
        def _open(self, path, headers=None, timeout=0):
            return super()._open("/state", headers, timeout)

    with pytest.raises(pp.Refused):
        pp.pull(Other(phone.base, TOKEN), tmp_path, now=NOW)


def test_page_server_passes_the_token_on(phone, tmp_path):
    u = urllib.request.urlparse(phone.base)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), page_server.make_handler(u.hostname, u.port, tmp_path, TOKEN))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        assert json.load(urllib.request.urlopen(f"{base}/state"))["via"] == "phone"
        urllib.request.urlopen(urllib.request.Request(f"{base}/marker", data=b"eyes closed start", method="POST"))
        assert ("POST", "/marker", "eyes closed start") in phone.requests
        assert b"<!doctype html" in urllib.request.urlopen(f"{base}/").read().lower()  # the pages still come from the laptop
    finally:
        srv.shutdown(); srv.server_close()
    # without --token the phone refuses, and the page server passes the refusal on
    srv = ThreadingHTTPServer(("127.0.0.1", 0), page_server.make_handler(u.hostname, u.port, tmp_path))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(f"http://127.0.0.1:{srv.server_address[1]}/state")
        assert e.value.code == 401
    finally:
        srv.shutdown(); srv.server_close()
