"""The phone link's signatures, laptop side (DECISIONS 750-759; docs/phone-link.md). The app's are in
app/lib/share/auth.dart; both are checked against app/test/fixtures/phone_link.json.

- Pairing: the one-time code proves itself both ways (`link_proof`), then both sides work the key out
  (`derive_key`): it is never sent. The laptop's `confirm` shows the phone it got the same key.
- Every request of the paired laptop to the phone is signed with that key (`signed_headers`): the method, the path and
  query, a time, a nonce used once, whether this laptop is on the network where it paired, and the body's SHA-256. The
  phone's token never leaves this laptop. The phone answers with `reply_proof` over the same nonce, so the laptop knows
  it reached the phone that holds the key, not whatever device took its old address.
- Before the phone deletes a raw recording by itself it asks for `recheck_mac`: an HMAC over random byte ranges of the
  laptop's own copy and a fresh nonce, which only a laptop holding those bytes can make.

Standard library only.
"""
from __future__ import annotations

import hashlib, hmac, re, secrets, time
from typing import Iterable
from urllib.parse import unquote, urlsplit

LINK_TAG = "eeg-tracker link v2"
KEY_TAG = "eeg-tracker key v2"
REQUEST_TAG = "eeg-tracker request v2"
REPLY_TAG = "eeg-tracker reply v2"
RECHECK_TAG = "eeg-tracker recheck v1"
NONCE = re.compile(r"[A-Za-z0-9_-]{16,64}")
KEY = re.compile(r"[0-9a-f]{64}")

# the headers of a signed request
TIME_H, NONCE_H, HOME_H, SIGN_H, REPLY_H = "X-Eeg-Time", "X-Eeg-Nonce", "X-Eeg-Home", "X-Eeg-Sign", "X-Eeg-Reply"


def _hmac(key: str, msg: bytes) -> str:
    return hmac.new(key.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def new_nonce() -> str:
    return secrets.token_urlsafe(16)  # 128 bits, 22 characters


def link_proof(code: str, who: str, first: str, second: str) -> str:
    """HMAC-SHA256(code, `eeg-tracker link v2|<who>|<first>|<second>`): the laptop answers the phone's nonce with
    who=laptop (phone nonce, laptop nonce); the phone answers with who=phone (laptop nonce, phone nonce)."""
    return _hmac(code, "|".join((LINK_TAG, who, first, second)).encode("utf-8"))


def derive_key(code: str, phone_nonce: str, laptop_nonce: str) -> str:
    """The pairing's key, worked out on both sides from the code (never sent) and the two nonces: 64 hex."""
    return _hmac(code, "|".join((KEY_TAG, phone_nonce, laptop_nonce)).encode("utf-8"))


def confirm(key: str, phone_nonce: str, laptop_nonce: str) -> str:
    """The laptop's last word at pairing: it holds the same key."""
    return _hmac(key, "|".join((LINK_TAG, "laptop", "confirm", phone_nonce, laptop_nonce)).encode("utf-8"))


def target_parts(target: str) -> tuple[str, str]:
    """(path, query) of a request target, percent-decoded: what both sides sign (`/files/a%20b?sha=0`)."""
    u = urlsplit(target)
    return unquote(u.path), unquote(u.query)


def request_sign(key: str, method: str, target: str, time_ms: int, nonce: str, home: bool, body: bytes = b"") -> str:
    """HMAC-SHA256(key, `eeg-tracker request v2|METHOD|time|nonce|home|sha256(body)|sha256(path)|sha256(query)`).
    The path and the query go in as hashes, so no character in them can move a field boundary."""
    path, query = target_parts(target)
    msg = "|".join((REQUEST_TAG, method.upper(), str(time_ms), nonce, "1" if home else "0", _sha(body),
                    _sha(path.encode("utf-8")), _sha(query.encode("utf-8"))))
    return _hmac(key, msg.encode("utf-8"))


def signed_headers(key: str, method: str, target: str, body: bytes = b"", *, home: bool,
                   now_ms: int | None = None, nonce: str | None = None) -> dict[str, str]:
    t = int(time.time() * 1000) if now_ms is None else now_ms
    n = nonce or new_nonce()
    return {TIME_H: str(t), NONCE_H: n, HOME_H: "1" if home else "0",
            SIGN_H: request_sign(key, method, target, t, n, home, body)}


def reply_proof(key: str, nonce: str) -> str:
    """The phone's answer to a signed request carries HMAC-SHA256(key, `eeg-tracker reply v2|<the request's nonce>`)."""
    return _hmac(key, f"{REPLY_TAG}|{nonce}".encode("utf-8"))


def reply_ok(key: str, nonce: str, given: str | None) -> bool:
    return given is not None and hmac.compare_digest(reply_proof(key, nonce).encode(), given.encode())


def ranges_text(ranges: Iterable[tuple[int, int]]) -> str:
    return ",".join(f"{s}+{n}" for s, n in ranges)


def recheck_mac(key: str, path: str, nonce: str, size: int, ranges: list[tuple[int, int]],
                chunks: Iterable[bytes]) -> str:
    """HMAC-SHA256(key, `eeg-tracker recheck v1|sha256(path)|nonce|size|s+n,...|` + the bytes of each range in order)."""
    m = hmac.new(key.encode("utf-8"), digestmod=hashlib.sha256)
    m.update("|".join((RECHECK_TAG, _sha(path.encode("utf-8")), nonce, str(size), ranges_text(ranges), "")).encode())
    for c in chunks:
        m.update(c)
    return m.hexdigest()
