"""Mirror the phone app's files onto the laptop over Wi-Fi while it records: new files, and the new end of growing ones.

usage: pull_phone.py [http://<phone-ip>:8765] [--every 2] [--once] [--dest _local] [--raw-only] [--no-ack]
       with EEG_PHONE_TOKEN=<t> (or --token <t>) for a phone not paired with this laptop

On the phone: switch "Share on Wi-Fi" on (main screen, Your data; app/README.md). It shows the address and the
token. Give the token in EEG_PHONE_TOKEN (the command line is readable by other users' `ps`). Without an address and
token it uses the phone paired with this laptop (`<dest>/phone/link.json`, scripts/phone_link.py): every request is
then signed with the pairing's key and the phone's answers must prove it (DECISIONS 751); the token is not used.

Every --every minutes (default 2) this asks the phone for its list (GET /files: path, bytes, SHA-256, modified time;
the list Export data's manifest holds) and fetches what the laptop lacks, into the layout of scripts/import_phone.py:

- Raw nights (`recordings/<stamp>.f32 .idx .log .markers.jsonl .header.json`) go into `<dest>/recordings/`, next to
  the laptop's own recordings, so sleep_report.py, morning_check.py and to_bdf.py work on them; a work session's raw
  EEG lands there too, and its header (`session: work`, DECISIONS 683) keeps night_files.py from taking it for a night; the DIY board's
  (`recordings-diy/...`) into `<dest>/recordings-diy/`; everything else keeps its place under `<dest>/phone/` (a
  check-in's raw files and its header in `phone/mornings/`). Raw files come first, tonight's before older ones.
  The `.header.json` says what its `.f32` holds (channels, rate; scripts/recording.py) and travels with it.
- A finished file is fetched under a temporary name, checked against the phone's size and SHA-256, then renamed.
- A file the phone is still writing (the night being recorded) has no SHA-256 yet: the laptop keeps a partial copy and
  fetches only the new bytes each time (HTTP Range). When the phone lists its SHA-256, the copy is checked whole; a
  copy that fails is fetched again from the start. A raw file that grows again after it was checked (a closed run's
  `.log` gets the reconnect tries added) is continued the same way.
- Nothing is overwritten silently, by import_phone.py's rules: when the laptop already has a different copy that this
  script did not make, the phone's replaces it only if the phone changed it later, and the older copy is moved to
  `<dest>/phone/replaced/<time>/`; otherwise the laptop's copy is left alone. Nothing is ever deleted on the laptop.
- `<dest>/phone/pull-state.json` remembers the partial copies, `<dest>/phone/pulls.jsonl` gets a line per pass that
  fetched something or found a problem. A later import_phone.py of the same files finds them "already here".
- Packed raw files (DECISIONS 540-549): the phone lists a night it packed after a day as `recordings/<stamp>.f32.gz`
  with its `original` (the `.f32`'s path, bytes and SHA-256). It is "already here" when the laptop holds that `.f32`,
  plain or packed (`.f32.xz`, scripts/pack_old.py), so a night is never fetched twice because the phone renamed it;
  otherwise it is fetched whole, checked as sent, unpacked, checked again and saved as the plain `.f32`. A copy the
  laptop packed is compared by what it holds and never continued in place.

- Acknowledged receipt (DECISIONS 690-699): when this laptop is paired with the phone (`<dest>/phone/link.json`, made
  by scripts/phone_link.py, holds the pairing's key; `--no-ack` turns it off), it hashes each copy the phone lists as
  finished and not yet acked again from its own disk (a packed `.f32.xz` unpacked; at most 4 GB a pass, oldest first)
  and, where it equals the phone's SHA-256 (a packed `.f32.gz`'s `original`), tells the phone so: a signed
  `POST /ack` with the paths and hashes. The phone keeps the acks; its Storage page deletes old raw recordings from
  the phone only once they are acked (3 days after, by default), never anything else, and only after this laptop
  proved again that it holds them: each pass answers the phone's questions (`GET /recheck`: random byte ranges and a
  nonce) with an HMAC over those bytes of this laptop's own copy (`POST /recheck`; DECISIONS 756), or says it does
  not hold the file. This script never deletes anything: `<dest>/phone/acks.jsonl` gets a line per ack. A raw set that left the phone leaves its
  `<stamp>.removed.json`, fetched like any file; a record whose files this laptop does not hold is a PROBLEM.

A phone that does not answer (asleep, out of Wi-Fi, sharing off) is tried again at the next pass. Exit status with
--once: 0 everything listed is on the laptop (growing files up to their listed size), 1 something is damaged or the
phone did not answer, 2 the token is wrong or the answer is not the app's. Standard library only.
"""
from __future__ import annotations

import argparse, hashlib, hmac, json, os, shutil, sys, time, urllib.error, urllib.parse, urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))  # find import_phone.py even under `python3 -I`
import import_phone as ip  # noqa: E402  (the layout, the index of copies and the path check are its own)
import packed  # noqa: E402  (raw files packed after a day: the phone's .f32.gz, the laptop's .f32.xz)
import phone_auth as pa  # noqa: E402  (the paired laptop's signatures: DECISIONS 751-755)

FORMAT = "eeg-tracker-phone-files"
VERSION = 1
RAW = (".f32", ".f32.gz", ".idx", ".log", ".markers.jsonl", ".header.json")  # a file set (docs/data-format.md)
LIST_TIMEOUT = 600  # the phone may be working out SHA-256 of files it never listed before
FILE_TIMEOUT = 60
ACK_BUDGET = 4 * 1024 ** 3  # bytes hashed again for acks in one pass
ACK_BATCH = 400  # files per POST /ack (the phone takes up to 256 KB)
ACK_RETRY_S = 6 * 3600  # an app without /ack is asked again after this long


class PhoneError(Exception):
    """The phone did not answer, or not as expected; the next pass tries again."""


class Refused(Exception):
    """The token or the key is refused, or this is not the app: trying again will not help."""


class NotThePhone(Refused):
    """What answered at the phone's address did not prove the pairing's key: nothing it says is used."""


class Held(Exception):
    """The phone holds this file back for now (409): it asked this laptop to prove it still holds it before deleting it
    (DECISIONS 756). The answer must come from this laptop's own copy; the file is copied again later if needed."""


class Paused(PhoneError):
    """The phone does not share on this Wi-Fi: not its home network and not allowed there by hand (DECISIONS 752)."""


class AckRefused(Exception):
    """POST /ack was refused whole: no route (an older app), not paired, or a wrong key."""


@dataclass(frozen=True)
class Listed:
    path: PurePosixPath
    bytes: int
    sha256: str | None  # None while the phone is still writing the file
    modified_ms: int
    original: ip.Original | None = None  # set for the phone's packed form (`.f32.gz`)
    acked: bool = False  # the phone holds this laptop's ack of it as it is now (DECISIONS 690-699)

    @property
    def lands(self) -> tuple[PurePosixPath, int, str | None]:
        """Path, bytes and SHA-256 of what lands on the laptop: the plain file, also for a packed one."""
        o = self.original
        return (o.path, o.bytes, o.sha256) if o else (self.path, self.bytes, self.sha256)


@dataclass
class Pass:
    listed: int = 0
    fetched: int = 0  # bytes
    new: list[str] = field(default_factory=list)
    grown: list[str] = field(default_factory=list)
    checked: list[str] = field(default_factory=list)  # partial copies now whole and equal to the phone's SHA-256
    updated: list[str] = field(default_factory=list)
    kept: list[str] = field(default_factory=list)
    damaged: list[str] = field(default_factory=list)
    waiting: list[str] = field(default_factory=list)  # differs, and the phone is still writing it
    refused: list[str] = field(default_factory=list)  # paths that do not stay inside the folder
    same: int = 0
    growing: int = 0
    replaced_dir: Path | None = None
    acked: list[str] = field(default_factory=list)  # told the phone: a checked copy is here
    ack_refused: list[str] = field(default_factory=list)  # the phone did not take the ack (its bytes changed meanwhile)
    ack_note: str | None = None  # why nothing was acked this pass (not paired, an older app)
    removed: list[str] = field(default_factory=list)  # raw sets that left the phone, their files here
    lost: list[str] = field(default_factory=list)  # raw files the phone removed that this laptop does not hold
    here: str | None = None  # what the paired phone says of its Wi-Fi: home, here (allowed by hand) or paused
    proven: list[str] = field(default_factory=list)  # asked about before deleting: proven from this laptop's own copy
    unproven: list[str] = field(default_factory=list)  # asked about: not held here as acked (missing or other bytes)

    @property
    def problems(self) -> bool:
        return bool(self.damaged or self.refused or self.lost)

    @property
    def changed(self) -> bool:
        return bool(self.new or self.grown or self.checked or self.updated or self.acked)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_a, **_k):  # the token must never follow a redirect to another host
        return None


class Phone:
    """The phone's Share on Wi-Fi server. With the pairing's [key] (scripts/phone_link.py) every request is signed
    (phone_auth.py) and the token never leaves this laptop; each answer must prove the key too, or it is not the
    paired phone. [home]: whether this laptop is on the network where it paired, said in each signature. Without a
    key (a phone shared by hand: --token), the token goes in a header, never in the address."""

    def __init__(self, base: str, token: str | None = None, *, key: str | None = None,
                 home: Callable[[], bool] | bool = False) -> None:
        self.base = base.rstrip("/")
        self.token = token
        self.key = key
        self._home = home if callable(home) else (lambda: bool(home))
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)

    def _send(self, path: str, headers: dict[str, str] | None = None, timeout: float = FILE_TIMEOUT,
              data: bytes | None = None):
        """The response, or urllib's HTTPError for an error answer; a signed request's answer is checked first."""
        method = "POST" if data is not None else "GET"
        h = dict(headers or {})
        nonce = None
        if self.key:
            signed = pa.signed_headers(self.key, method, path, data or b"", home=self._home())
            nonce = signed[pa.NONCE_H]
            h.update(signed)
        elif self.token:
            h["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            r = self.opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            if nonce is not None and e.code != 401 and not pa.reply_ok(self.key or "", nonce, e.headers.get(pa.REPLY_H)):
                raise NotThePhone("it did not prove the pairing's key") from e
            raise
        except (OSError, urllib.error.URLError) as e:
            raise PhoneError(f"no answer: {getattr(e, 'reason', e)}") from e
        if nonce is not None and not pa.reply_ok(self.key or "", nonce, r.headers.get(pa.REPLY_H)):
            r.close()
            raise NotThePhone("it did not prove the pairing's key")
        return r

    @staticmethod
    def _why(e: urllib.error.HTTPError) -> str | None:
        try:
            w = json.loads(e.read().decode("utf-8")).get("error")
        except (OSError, ValueError, AttributeError):
            return None
        return w if isinstance(w, str) else None

    def _open(self, path: str, headers: dict[str, str] | None = None, timeout: float = FILE_TIMEOUT,
              data: bytes | None = None):
        try:
            return self._send(path, headers, timeout, data)
        except urllib.error.HTTPError as e:
            why = self._why(e)
            if e.code == 401:
                raise Refused(f"the phone refused this laptop's signature ({why})" if self.key and why else
                              "the phone refused the token") from e
            if e.code == 403 and why == "not sharing on this Wi-Fi":
                raise Paused(why) from e
            if e.code == 409:
                raise Held(why or "being re-checked") from e
            if e.code in (401, 403):
                raise Refused(f"the phone refused ({why or 'local network only'})") from e
            raise PhoneError(f"the phone answered {e.code} for {path}") from e

    def who(self) -> dict | None:
        """GET /who (signed only): the app's word that it is there and what it says of its Wi-Fi (`here`: home, here
        or paused); None when it is not the paired phone's answer."""
        try:
            with self._open("/who", timeout=5) as r:
                m = json.loads(r.read(4096).decode("utf-8"))
        except (OSError, ValueError, Refused):
            return None
        return m if isinstance(m, dict) and m.get("app") == "eeg-tracker" else None

    def files(self) -> tuple[list[Listed], list[str]]:
        """The phone's list, and the paths in it that are not usable."""
        try:
            with self._open("/files", timeout=LIST_TIMEOUT) as r:
                m = json.loads(r.read().decode("utf-8"))
        except (OSError, ValueError) as e:
            raise PhoneError(f"the phone's list could not be read ({e})") from e
        if not isinstance(m, dict) or m.get("format") != FORMAT or not isinstance(m.get("files"), list):
            raise Refused(f"{self.base}/files is not the EEG Tracker app's list")
        if m.get("version") != VERSION:
            raise Refused(f"the phone's list is version {m.get('version')}; this script reads version {VERSION}")
        out, bad, seen = [], [], set()
        for f in m["files"]:
            try:
                p = ip.safe_path(f.get("path") if isinstance(f, dict) else None)
            except ip.ManifestError:
                bad.append(str(f.get("path") if isinstance(f, dict) else f)[:80])
                continue
            size, digest, mod = f.get("bytes"), f.get("sha256"), f.get("modified_ms")
            ok_digest = digest is None or (isinstance(digest, str) and len(digest) == 64
                                           and all(c in "0123456789abcdef" for c in digest))
            try:
                orig = ip.original_of(p, f.get("original"))
            except (ValueError, ip.ManifestError):
                orig = None
                ok_digest = False
            if not (isinstance(size, int) and size >= 0 and isinstance(mod, int) and ok_digest) or p in seen:
                bad.append(str(p))
                continue
            seen.add(p)
            out.append(Listed(p, size, digest, mod, orig, f.get("acked") is True))
        return out, bad

    def ack(self, files: list[dict[str, str]], key: str | None = None) -> tuple[list[str], list[dict]]:
        """POST /ack, signed with the pairing's key: (paths the phone took, [{path, why}] it did not). Raises
        AckRefused when it refused all of it."""
        if not self.key:
            raise AckRefused("only the paired laptop acks (no key here)")
        body = json.dumps({"v": 1, "files": files}, separators=(",", ":")).encode()
        try:
            with self._send("/ack", {"Content-Type": "application/json"}, FILE_TIMEOUT, body) as r:
                m = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            why = self._why(e)
            if e.code == 401:
                raise Refused(f"the phone refused this laptop's signature ({why})") from e
            if e.code == 403 and why == "not sharing on this Wi-Fi":
                raise Paused(why) from e
            raise AckRefused({404: "the phone's app is older than acks (update it)",
                              403: f"the phone refused the ack ({why or 'local network only'})"}.get(
                                  e.code, f"the phone answered {e.code} to the ack")) from e
        except ValueError as e:
            raise PhoneError(f"the ack's answer could not be read ({e})") from e
        acked = [a for a in m.get("acked") or [] if isinstance(a, str)] if isinstance(m, dict) else []
        refused = [r for r in m.get("refused") or [] if isinstance(r, dict)] if isinstance(m, dict) else []
        return acked, refused

    def fetch(self, path: PurePosixPath, start: int, end: int, out, digest=None) -> int:
        """Writes bytes [start, end) of the phone's file to [out]; returns how many arrived."""
        if end <= start:
            return 0
        quoted = "/files/" + "/".join(urllib.parse.quote(part, safe="") for part in path.parts)
        n = 0
        try:
            with self._open(quoted, {"Range": f"bytes={start}-{end - 1}"}) as r:
                if start > 0 and r.status != 206:
                    raise PhoneError(f"the phone ignored the range asked for {path}")
                while n < end - start and (b := r.read(min(ip.CHUNK, end - start - n))):
                    out.write(b)
                    if digest is not None:
                        digest.update(b)
                    n += len(b)
        except OSError as e:
            raise PhoneError(f"{path} stopped arriving ({e})") from e
        return n


class State:
    """`phone/pull-state.json`: the copies this script made. `partial`: not yet checked against a SHA-256, with the
    size they have; `raw`: checked raw files with their size, which the phone may still add to (only a copy still of
    that size is continued: any other is not ours to touch)."""

    def __init__(self, dest: Path) -> None:
        self.file = dest / "phone" / "pull-state.json"
        try:
            raw = json.loads(self.file.read_text(encoding="utf-8"))
            self.partial: dict[str, int] = {k: v for k, v in raw.get("partial", {}).items() if isinstance(v, int)}
            self.raw: dict[str, int] = {k: v for k, v in raw.get("raw", {}).items() if isinstance(v, int)}
            # acks the phone did not take (path -> the SHA-256 sent: not sent again for the same bytes), and when an
            # app without /ack was last asked
            self.ack_refused: dict[str, str] = {k: v for k, v in raw.get("ack_refused", {}).items() if isinstance(v, str)}
            self.no_ack_at: float = float(raw.get("no_ack_at") or 0)
        except (OSError, ValueError, AttributeError, TypeError):
            self.partial, self.raw, self.ack_refused, self.no_ack_at = {}, {}, {}, 0.0

    def checked(self, e: "Listed") -> None:
        path, size, _ = e.lands
        self.partial.pop(str(path), None)
        if is_raw(path):
            self.raw[str(path)] = size

    def save(self) -> None:
        self.file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.file.with_name(self.file.name + ".tmp")
        tmp.write_text(json.dumps({"version": 1, "partial": self.partial, "raw": self.raw, "ack_refused": self.ack_refused,
                                   "no_ack_at": self.no_ack_at}, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.file)


def is_raw(p: PurePosixPath) -> bool:
    """A file of a raw file set, the BrainBit's (`recordings/`) or the DIY board's (`recordings-diy/`): its samples,
    index, log, markers and recording header."""
    return len(p.parts) == 2 and p.parts[0] in ip.RAW and p.name.endswith(RAW)


def order(files: list[Listed]) -> list[Listed]:
    """Raw samples first, tonight's before older ones; then the reports and sessions."""
    return sorted(files, key=lambda e: (0 if is_raw(e.path) else 1, -e.modified_ms, str(e.path)))


def _set_time(f: Path, modified_ms: int) -> None:
    ns = modified_ms * 1_000_000
    os.utime(f, ns=(ns, ns))


def _whole(phone: Phone, e: Listed, dst: Path) -> bool:
    """Fetches the whole file under a temporary name; True when it arrived whole (and equal to the SHA-256, if the
    phone gave one) and now stands at [dst]. The caller has moved any older copy away."""
    tmp = dst.with_name(dst.name + ".pulling")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    try:
        with tmp.open("wb") as out:
            n = phone.fetch(e.path, 0, e.bytes, out, h)
            out.flush()
            os.fsync(out.fileno())
        if n != e.bytes or (e.sha256 is not None and h.hexdigest() != e.sha256):
            return False
        os.replace(tmp, dst)
        _set_time(dst, e.modified_ms)
        return True
    finally:
        tmp.unlink(missing_ok=True)


def _whole_packed(phone: Phone, e: Listed, dst: Path) -> bool:
    """The phone's packed form (`.f32.gz`): fetched whole and checked as sent, unpacked and checked against its
    `original`; True when the plain file now stands at [dst]."""
    assert e.original is not None and e.sha256 is not None
    gz, tmp = dst.with_name(dst.name + ".gz.pulling"), dst.with_name(dst.name + ".pulling")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    try:
        with gz.open("wb") as out:
            n = phone.fetch(e.path, 0, e.bytes, out)
        if n != e.bytes:
            return False
        with gz.open("rb") as r, tmp.open("wb") as out:
            ok = packed.gunzip_checked(r, out, packed.Original(e.bytes, e.sha256),
                                       packed.Original(e.original.bytes, e.original.sha256))
            out.flush()
            os.fsync(out.fileno())
        if not ok:
            return False
        os.replace(tmp, dst)
        _set_time(dst, e.modified_ms)
        return True
    finally:
        gz.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)


def _replace(phone: Phone, e: Listed, dst: Path, old: Path, rep: Pass, index: ip.Index, *, have: Path | None = None,
             whole: Callable[[Phone, Listed, Path], bool] = _whole) -> bool:
    """The phone's checked copy takes the place of the laptop's ([have], else [dst]), which moves to [old]; if the
    phone's does not arrive whole, the laptop's copy goes back where it was."""
    have = have or dst
    path, _, digest = e.lands
    old.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(have, old)
    ok = False
    try:
        ok = whole(phone, e, dst)
    finally:
        if not ok:
            shutil.move(old, have)
    if ok:
        index.put(dst, str(digest)); rep.updated.append(str(path)); rep.fetched += e.bytes
        rep.replaced_dir = old.parents[len(dst.relative_to(index.dest).parts) - 1]
    else:
        rep.damaged.append(str(path))
    return ok


def _pull_packed(phone: Phone, e: Listed, dest: Path, index: ip.Index, state: State, rep: Pass,
                 replaced: Path) -> None:
    """A raw file packed on either side (the phone's `.f32.gz`, or the laptop's `.f32.xz` after a day): compared by
    what it holds; fetched whole when the laptop lacks it or holds another copy that the phone changed later, or that
    is this script's own unfinished one (a packed file is never continued in place)."""
    path, size, digest = e.lands
    key, dst = str(path), ip.target_for(dest, path)
    whole = _whole_packed if e.original else _whole
    have = ip.on_laptop(dst)
    if digest is None or e.sha256 is None:
        rep.waiting.append(key)  # the phone is still writing it, or could not read it whole this time
        return
    if have is None:
        if whole(phone, e, dst):
            rep.new.append(key); rep.fetched += e.bytes
            state.checked(e); index.put(dst, digest)
        else:
            rep.damaged.append(key)
        return
    try:
        have_bytes = ip.size_of(dst)
        same = have_bytes == size and index.sha(dst) == digest
    except OSError:  # a packed copy that does not unpack holds nothing
        have_bytes, same = -1, False
    if same:
        if key in state.partial:
            rep.checked.append(key)
        else:
            rep.same += 1
        state.checked(e)
        return
    ours = key in state.partial or state.raw.get(key) == have_bytes
    if not ours and e.modified_ms <= have.stat().st_mtime_ns // 1_000_000:
        rep.kept.append(key)  # the laptop's copy is as new or newer
        return
    state.partial.pop(key, None); state.raw.pop(key, None)
    if _replace(phone, e, dst, replaced / have.relative_to(dest), rep, index, have=have, whole=whole):
        state.checked(e)


def pull(phone: Phone, dest: Path, *, raw_only: bool = False, now: datetime | None = None, key: str | None = None,
         ack_budget: int = ACK_BUDGET) -> Pass:
    """One pass: the phone's list, then everything the laptop lacks; with the pairing's [key], then the acks."""
    pairing = key
    now = now or datetime.now().astimezone()
    here = phone.who() if phone.key else None
    listed, bad = phone.files()
    rep = Pass(listed=len(listed), refused=bad, here=here.get("here") if here and isinstance(here.get("here"), str) else None)
    index, state = ip.Index(dest, False), State(dest)
    replaced = dest / "phone" / "replaced" / ip._stamp(now)
    try:
        for e in order(listed):
            try:
                if raw_only and not is_raw(e.path):
                    continue
                key, dst = str(e.path), ip.target_for(dest, e.path)
                if e.sha256 is None:
                    rep.growing += 1
                if e.original is not None or packed.is_packed(ip.on_laptop(dst) or dst):
                    _pull_packed(phone, e, dest, index, state, rep, replaced)
                    continue
                if not dst.is_file():
                    if _whole(phone, e, dst):
                        rep.new.append(key); rep.fetched += e.bytes
                        if e.sha256 is None:
                            state.partial[key] = e.bytes
                        else:
                            state.checked(e); index.put(dst, e.sha256)
                    else:
                        rep.damaged.append(key)
                    continue
                have = dst.stat().st_size
                if e.sha256 is not None and have == e.bytes and index.sha(dst) == e.sha256:
                    if key in state.partial:
                        rep.checked.append(key)
                    else:
                        rep.same += 1
                    state.checked(e)
                    continue
                if state.raw.get(key) == have and have < e.bytes:
                    state.partial[key] = have  # our checked copy, and the phone added to the file since
                if key in state.partial and have <= e.bytes:
                    # our own partial copy of a file the phone only ever adds to: fetch the new end
                    if have < e.bytes:
                        with dst.open("ab") as out:
                            got = phone.fetch(e.path, have, e.bytes, out)
                            out.flush()
                            os.fsync(out.fileno())
                        rep.fetched += got
                        if got:
                            rep.grown.append(key)
                        _set_time(dst, e.modified_ms)
                        have = dst.stat().st_size
                    state.partial[key] = have
                    if e.sha256 is None or have != e.bytes:
                        if e.sha256 is None and have == e.bytes and key not in rep.grown:
                            rep.same += 1
                        continue
                    if ip.hash_file(dst) == e.sha256:
                        state.checked(e); index.put(dst, e.sha256); rep.checked.append(key)
                        continue
                    # the partial copy does not add up to the phone's file: keep it aside, fetch the file whole
                    state.partial.pop(key); state.raw.pop(key, None)
                    if _replace(phone, e, dst, replaced / dst.relative_to(dest), rep, index):
                        state.checked(e)
                    continue
                # a different copy that is not ours to continue: import_phone.py's rule
                if e.modified_ms <= dst.stat().st_mtime_ns // 1_000_000:
                    rep.kept.append(key)  # the laptop's copy is as new or newer
                    continue
                if e.sha256 is None:
                    rep.waiting.append(key)  # replace only with a copy that can be checked
                    continue
                if _replace(phone, e, dst, replaced / dst.relative_to(dest), rep, index):
                    state.checked(e)
            except Held:  # asked about before the phone deletes it: not handed out now (DECISIONS 756)
                rep.waiting.append(str(e.path))
        _check_removed(dest, rep)
        if pairing:
            acknowledge(phone, dest, listed, pairing, rep, state, raw_only=raw_only, budget=ack_budget, now=now)
            answer_rechecks(phone, dest, rep)
        else:
            rep.ack_note = "not paired: no acks (scripts/phone_link.py pairs)"
    finally:
        state.save()
        index.save()
        if rep.changed or rep.problems:
            _record(rep, dest, "paired" if phone.key else "by code", now)
    return rep


REMOVED = ".removed.json"  # a raw set that left the phone (app/lib/recorder/remove.dart)


def _check_removed(dest: Path, rep: Pass) -> None:
    """The records fetched in this pass of raw sets that left the phone: this laptop holds the files a record says the
    laptop had checked (by their size; their bytes were hashed when they were acked), else that is a PROBLEM."""
    for key in rep.new + rep.updated:
        p = PurePosixPath(key)
        if not (p.name.endswith(REMOVED) and len(p.parts) == 2 and p.parts[0] in ip.RAW + ("mornings",)):
            continue
        try:
            m = json.loads(ip.target_for(dest, p).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(m, dict) or m.get("format") != "eeg-tracker-removed":
            continue
        rep.removed.append(key)
        if m.get("on_laptop") is not True:
            continue  # deleted on the phone only: there is nothing here to hold
        for f in m.get("files") or []:
            name, size = (f.get("name"), f.get("bytes")) if isinstance(f, dict) else (None, None)
            if not isinstance(name, str) or "/" in name or not isinstance(size, int):
                continue
            here = ip.target_for(dest, PurePosixPath(p.parts[0]) / name)
            try:
                ok = ip.on_laptop(here) is not None and ip.size_of(here) == size
            except OSError:
                ok = False
            if not ok:
                rep.lost.append(f"{p.parts[0]}/{name}")


def _laptop_sha(dst: Path) -> str:
    """SHA-256 of the laptop's copy, read from its disk now (a packed .f32.xz unpacked), never from the index."""
    return packed.content_sha256(dst) if dst.name.endswith(packed.RAW) else ip.hash_file(dst)


def acknowledge(phone: Phone, dest: Path, listed: list[Listed], key: str, rep: Pass, state: State, *,
                raw_only: bool = False, budget: int = ACK_BUDGET, now: datetime | None = None) -> None:
    """Tells the phone which of its finished files this laptop holds, byte for byte: each copy is hashed again from
    disk (oldest first, up to [budget] bytes a pass) and acked only when it equals what the phone lists. Before any
    hashing an empty ack asks whether the phone takes acks from this key at all; when it does not (an older app, a
    pairing the phone forgot), nothing is hashed and it is asked again after 6 hours. A file the phone does not take
    is not sent again for the same bytes."""
    t = (now or datetime.now().astimezone()).timestamp()
    if state.no_ack_at and t - state.no_ack_at < ACK_RETRY_S:
        rep.ack_note = "the phone took no acks lately; asked again later"
        return
    due: list[tuple[Listed, Path, int, str]] = []
    for e in sorted(listed, key=lambda e: (e.modified_ms, str(e.path))):
        path, size, digest = e.lands
        if e.acked or digest is None or e.sha256 is None or (raw_only and not is_raw(e.path)):
            continue
        if state.ack_refused.get(str(e.path)) == digest:
            continue
        dst = ip.target_for(dest, path)
        try:
            if ip.on_laptop(dst) is None or ip.size_of(dst) != size:
                continue
        except OSError:
            continue
        due.append((e, dst, size, digest))
    if not due:
        return
    try:
        phone.ack([], key)  # does the phone take acks from this key?
    except AckRefused as e:
        rep.ack_note = str(e)
        state.no_ack_at = t
        return
    state.no_ack_at = 0.0
    todo: list[dict[str, str]] = []
    spent = 0
    for e, dst, size, digest in due:
        if todo and spent + size > budget:
            break  # the rest at the next pass
        spent += size
        try:
            if _laptop_sha(dst) == digest:
                todo.append({"path": str(e.path), "sha256": digest})
        except (OSError, EOFError, ValueError):
            continue
    acked: list[str] = []
    try:
        for k in range(0, len(todo), ACK_BATCH):
            batch = todo[k:k + ACK_BATCH]
            took, refused = phone.ack(batch, key)
            acked += took
            sent = {a["path"]: a["sha256"] for a in batch}
            for r in refused:
                p = r.get("path")
                if isinstance(p, str) and p in sent:
                    rep.ack_refused.append(f"{p} ({r.get('why')})")
                    if r.get("why") == "different bytes":
                        state.ack_refused[p] = sent[p]
    except AckRefused as e:
        rep.ack_note = str(e)
    finally:
        if acked:
            rep.acked += acked
            f = dest / "phone" / "acks.jsonl"
            f.parent.mkdir(parents=True, exist_ok=True)
            by = {a["path"]: a["sha256"] for a in todo}
            with f.open("a", encoding="utf-8") as out:
                out.write(json.dumps({"acked": datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds"),
                                      "files": [{"path": p, "sha256": by.get(p)} for p in acked]})
                          + "\n")


RECHECK_MAX = 4000  # questions answered in one pass (each reads 8 x 4 KB, or a whole small file)


def _ranges(dst: Path, ranges: list[tuple[int, int]]):
    """The bytes of [ranges] of this laptop's copy (a raw .f32 plain or packed .f32.xz, unpacked as it is read), in
    order. Ranges in order and not overlapping are read in one pass; others reopen the copy."""
    raw = dst.name.endswith(packed.RAW)
    f = packed.open_raw(dst) if raw else open(ip.on_laptop(dst) or dst, "rb")
    try:
        pos = 0
        for start, n in ranges:
            if start < pos:  # not in order: from the start again
                f.close()
                f = packed.open_raw(dst) if raw else open(ip.on_laptop(dst) or dst, "rb")
                pos = 0
            while pos < start:  # forward: an unpacking reader cannot jump
                skipped = len(f.read(min(start - pos, 1 << 20)))
                if not skipped:
                    break
                pos += skipped
            b = f.read(n)
            pos += len(b)
            yield b
    finally:
        f.close()


def answer_rechecks(phone: Phone, dest: Path, rep: Pass) -> None:
    """The phone's questions before it deletes raw recordings by itself (DECISIONS 756): for each, an HMAC with the
    phone's nonce over the asked byte ranges of THIS laptop's own copy (phone_auth.recheck_mac; a packed .f32.xz
    unpacked), never over bytes fetched from the phone; "missing" when this laptop does not hold those bytes (no copy,
    or one of another length). The phone deletes only on a fresh proof. An app without /recheck: nothing to answer."""
    if not phone.key:
        return
    try:
        with phone._open("/recheck", timeout=FILE_TIMEOUT) as r:
            m = json.loads(r.read(4_000_000).decode("utf-8"))
    except (PhoneError, Refused, OSError, ValueError):
        return
    asks = m.get("asks") if isinstance(m, dict) else None
    if not isinstance(asks, list):
        return
    proofs: list[dict] = []
    for a in asks[:RECHECK_MAX]:
        if not isinstance(a, dict):
            continue
        nonce, size, ranges = a.get("nonce"), a.get("bytes"), a.get("ranges")
        try:
            path = ip.safe_path(a.get("path"))
        except ip.ManifestError:
            continue
        if not (isinstance(nonce, str) and pa.NONCE.fullmatch(nonce) and isinstance(size, int) and size >= 0
                and isinstance(ranges, list) and 0 < len(ranges) <= 64
                and all(isinstance(x, list) and len(x) == 2 and all(isinstance(v, int) and not isinstance(v, bool)
                                                                       for v in x)
                        and x[0] >= 0 and 0 <= x[1] <= 1 << 20 and x[0] + x[1] <= size for x in ranges)):
            continue
        rs = [(x[0], x[1]) for x in ranges]
        dst = ip.target_for(dest, path)
        try:
            held = ip.on_laptop(dst) is not None and ip.size_of(dst) == size
            mac = pa.recheck_mac(phone.key, str(path), nonce, size, rs, _ranges(dst, rs)) if held else None
        except (OSError, EOFError, ValueError):
            mac = None
        proofs.append({"path": str(path), "nonce": nonce, "mac": mac} if mac else
                      {"path": str(path), "nonce": nonce, "missing": True})
    if not proofs:
        return
    body = json.dumps({"v": 1, "proofs": proofs}, separators=(",", ":")).encode()
    try:
        with phone._open("/recheck", {"Content-Type": "application/json"}, FILE_TIMEOUT, body) as r:
            m = json.loads(r.read().decode("utf-8"))
    except (PhoneError, Refused, OSError, ValueError):
        return
    if isinstance(m, dict):
        rep.proven += [p for p in m.get("proven") or [] if isinstance(p, str)]
        rep.unproven += [f"{f.get('path')} ({f.get('why')})" for f in m.get("failed") or [] if isinstance(f, dict)]


def _record(rep: Pass, dest: Path, how: str, now: datetime) -> None:
    """One line of pulls.jsonl: how the phone was reached (paired, or by code), never its address (DECISIONS 757)."""
    line = dict(pulled=now.isoformat(timespec="seconds"), phone=how, listed=rep.listed, bytes=rep.fetched,
                new=len(rep.new), grown=len(rep.grown), checked=len(rep.checked), updated=len(rep.updated),
                kept=len(rep.kept), damaged=len(rep.damaged), waiting=len(rep.waiting), refused=len(rep.refused),
                acked=len(rep.acked), removed=len(rep.removed), lost=len(rep.lost))
    f = dest / "phone" / "pulls.jsonl"
    f.parent.mkdir(parents=True, exist_ok=True)
    with f.open("a", encoding="utf-8") as out:
        out.write(json.dumps(line) + "\n")


def summary(rep: Pass, dest: Path, now: datetime) -> list[str]:
    parts = []
    if rep.new:
        parts.append(f"{len(rep.new)} new")
    if rep.grown:
        parts.append(f"{len(rep.grown)} grown")
    if rep.checked:
        parts.append(f"{len(rep.checked)} finished and checked")
    if rep.updated:
        parts.append(f"{len(rep.updated)} updated")
    head = f"{now.strftime('%H:%M')} "
    if parts:
        head += f"fetched {ip._mb(rep.fetched)}: {', '.join(parts)}; {rep.same} already here"
    else:
        head += f"nothing new; {rep.same} of {rep.listed} already here"
    if rep.growing:
        head += f"; {rep.growing} still being written on the phone"
    out = [head]
    if rep.updated:
        kept = rep.replaced_dir.relative_to(dest.parent) if rep.replaced_dir else "-"
        out.append(f"  updated (the phone changed them later); the older copies are in {kept}: {ip._names(rep.updated)}")
    if rep.kept:
        out.append(f"  {len(rep.kept)} left alone: the laptop's copy is as new or newer: {ip._names(rep.kept)}")
    if rep.waiting:
        out.append(f"  {len(rep.waiting)} differ and are still being written on the phone; checked when they rest: "
                   f"{ip._names(rep.waiting)}")
    if rep.acked:
        out.append(f"  told the phone {len(rep.acked)} file{'s are' if len(rep.acked) != 1 else ' is'} safe here (hashed "
                   "again on this disk); its Storage settings decide when old raw recordings leave the phone")
    if rep.ack_refused:
        out.append(f"  {len(rep.ack_refused)} not acked (the phone's copy changed meanwhile): {ip._names(rep.ack_refused)}")
    if rep.proven:
        out.append(f"  proved to the phone that {len(rep.proven)} file{'s are' if len(rep.proven) != 1 else ' is'} still "
                   "here, byte for byte: it may remove them now")
    if rep.unproven:
        out.append(f"  {len(rep.unproven)} the phone asked about are not here as acked: it keeps them, and they are "
                   f"copied again: {ip._names(rep.unproven)}")
    if rep.removed:
        out.append(f"  {len(rep.removed)} recording{'s' if len(rep.removed) != 1 else ''} left the phone; "
                   f"the raw files stay here: {ip._names(rep.removed)}")
    if rep.lost:
        out.append(f"PROBLEM: the phone removed {len(rep.lost)} raw files this laptop does not hold: {ip._names(rep.lost)}")
    if rep.damaged:
        out.append(f"PROBLEM: {len(rep.damaged)} did not arrive whole (tried again at the next pass): {ip._names(rep.damaged)}")
    if rep.refused:
        out.append(f"PROBLEM: {len(rep.refused)} entries of the phone's list are not usable: {ip._names(rep.refused)}")
    return out


def pairing_key(dest: Path) -> str | None:
    """The key of this laptop's pairing with the phone (`<dest>/phone/link.json` version 2, scripts/phone_link.py);
    None without one (a pairing of the first version needs one new scan)."""
    try:
        raw = json.loads((dest / "phone" / "link.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    k = raw.get("key") if isinstance(raw, dict) and raw.get("version") == 2 else None
    return k if isinstance(k, str) and pa.KEY.fullmatch(k) else None


def main(argv: list[str] | None = None, out: Callable[[str], object] = print,
         sleep: Callable[[float], object] = time.sleep) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("phone", nargs="?", help="the address the app shows, e.g. http://192.168.1.23:8765 (default: the "
                                             "paired phone's, from <dest>/phone/link.json)")
    ap.add_argument("--token", default=os.environ.get("EEG_PHONE_TOKEN"),
                    help="the code the app shows (or EEG_PHONE_TOKEN), for a phone not paired with this laptop")
    ap.add_argument("--every", type=float, default=2, help="minutes between passes (default 2)")
    ap.add_argument("--once", action="store_true", help="one pass, then exit")
    ap.add_argument("--dest", type=Path, default=ip.DEFAULT_DEST, help="where to copy (default: <repo>/_local)")
    ap.add_argument("--no-ack", action="store_true",
                    help="never tell the phone its files are safe here (by default: when <dest>/phone/link.json holds the "
                         "pairing's key)")
    ap.add_argument("--raw-only", action="store_true",
                    help="only the raw recordings in recordings/ and recordings-diy/ (.f32 .idx .log .markers.jsonl "
                         ".header.json, and the phone's packed .f32.gz)")
    a = ap.parse_args(argv)
    paired = pairing_key(a.dest)
    if a.phone is None:
        import phone_link  # the paired phone's address and this laptop's home network
        p = phone_link.paired_phone(a.dest / "phone" / "link.json")
        if p is None:
            out("No phone is paired with this laptop: pair it (python3 scripts/phone_link.py), or give its address "
                "and the code the app shows (--token or EEG_PHONE_TOKEN).")
            return 2
        home = p[3]
        phone = Phone(f"http://{p[0]}:{p[1]}", key=p[2], home=lambda: home is not None and phone_link.home_id() == home)
    elif a.token:
        base = a.phone if "://" in a.phone else f"http://{a.phone}"
        phone = Phone(base.split("?")[0], a.token)
    elif paired:  # the paired phone at another address (adb forward): signed with the key
        base = a.phone if "://" in a.phone else f"http://{a.phone}"
        phone = Phone(base.split("?")[0], key=paired, home=False)
    else:
        out("Give the code the app shows: --token <t> (or set EEG_PHONE_TOKEN), or pair the phone with this laptop.")
        return 2
    key = None if a.no_ack or phone.key is None else phone.key
    while True:
        now = datetime.now().astimezone()
        code = 0
        try:
            rep = pull(phone, a.dest, raw_only=a.raw_only, now=now, key=key)
            for line in summary(rep, a.dest, now):
                out(line)
            code = 1 if rep.problems else 0
        except Refused as e:
            out(f"Cannot pull: {e}. Check the address and code on the phone (Your data, Share on Wi-Fi).")
            return 2
        except PhoneError as e:
            out(f"{now.strftime('%H:%M')} {e}" + ("" if a.once else f"; trying again in {a.every:g} min"))
            code = 1
        if a.once:
            return code
        try:
            sleep(max(a.every, 0.1) * 60)
        except KeyboardInterrupt:
            return code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
