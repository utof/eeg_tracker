"""Writes phone_link.json: the link's signatures (scripts/phone_auth.py <-> app/lib/share/auth.dart: the pairing
proofs, the key both sides work out, the laptop's confirm, a signed request, the phone's reply, a delete re-check's
proof, the phone's signed push requests and the laptop's answers; DECISIONS 750-759) and reference QR matrices for
scripts/qr_code.py made by an independent encoder (python-qrcode, BSD).

    /usr/bin/python3 app/test/fixtures/make_phone_link_fixture.py     # needs python-qrcode (Debian: python3-qrcode)

The signatures are HMAC-SHA256 from Python's standard library, written out here by hand (not through phone_auth.py),
so both the laptop's and the app's code are checked against the same independent numbers.
"""
import hashlib
import hmac
import json
from pathlib import Path

import qrcode
import qrcode.util as qu

OUT = Path(__file__).with_name("phone_link.json")
LEVELS = {"L": qrcode.constants.ERROR_CORRECT_L, "M": qrcode.constants.ERROR_CORRECT_M,
          "Q": qrcode.constants.ERROR_CORRECT_Q, "H": qrcode.constants.ERROR_CORRECT_H}


def hm(key: str, msg: str) -> str:
    return hmac.new(key.encode(), msg.encode(), hashlib.sha256).hexdigest()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def proofs() -> list[dict]:
    """Pairing v2: the code proves itself both ways, then both sides derive the key and the laptop confirms it."""
    cases = [
        ("Zm9yLXRoZS1maXh0dXJlLW9ubHk", "cGhvbmUtbm9uY2UtMDAwMQ", "bGFwdG9wLW5vbmNlLTAwMDE"),
        ("YW5vdGhlci1maXh0dXJlLWNvZGU", "cGhvbmUtbm9uY2UtMDAwMg", "bGFwdG9wLW5vbmNlLTAwMDI"),
    ]
    out = []
    for code, phone_nonce, laptop_nonce in cases:
        key = hm(code, f"eeg-tracker key v2|{phone_nonce}|{laptop_nonce}")
        out.append({
            "code": code, "phone_nonce": phone_nonce, "laptop_nonce": laptop_nonce,
            "laptop_proof": hm(code, f"eeg-tracker link v2|laptop|{phone_nonce}|{laptop_nonce}"),
            "phone_proof": hm(code, f"eeg-tracker link v2|phone|{laptop_nonce}|{phone_nonce}"),
            "key": key,
            "confirm": hm(key, f"eeg-tracker link v2|laptop|confirm|{phone_nonce}|{laptop_nonce}"),
        })
    return out


def requests() -> list[dict]:
    """Signed requests of the paired laptop and the phone's reply over the same nonce."""
    key = "7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544"
    cases = [
        ("GET", "/files", "", "", 1763500000123, "cmVxdWVzdC1ub25jZS0wMDE", True, b""),
        ("GET", "/files/recordings/2026-11-19-010000.f32", "/files/recordings/2026-11-19-010000.f32", "", 1763500000456,
         "cmVxdWVzdC1ub25jZS0wMDI", False, b""),
        ("GET", "/files?sha=0", "/files", "sha=0", 1763500000789, "cmVxdWVzdC1ub25jZS0wMDM", True, b""),
        ("POST", "/work", "/work", "", 1763500001000, "cmVxdWVzdC1ub25jZS0wMDQ", True, b'{"working":true}'),
        ("GET", "/files/dream-catcher/a%20b.wav", "/files/dream-catcher/a b.wav", "", 1763500002000,
         "cmVxdWVzdC1ub25jZS0wMDU", True, b""),
    ]
    out = []
    for method, target, path, query, t, nonce, home, body in cases:
        path = path or target
        msg = "|".join(("eeg-tracker request v2", method, str(t), nonce, "1" if home else "0", sha(body),
                        sha(path.encode()), sha(query.encode())))
        out.append({"key": key, "method": method, "target": target, "time_ms": t, "nonce": nonce, "home": home,
                    "body": body.decode(), "sign": hm(key, msg), "reply": hm(key, f"eeg-tracker reply v2|{nonce}")})
    return out


def rechecks() -> list[dict]:
    """A delete re-check: the phone's ranges of a file and the laptop's HMAC over those bytes of its own copy."""
    key = "7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544"
    data = bytes((i * 7 + 3) % 256 for i in range(10_000))  # the file both sides hold
    out = []
    for path, nonce, ranges in [
        ("recordings/2026-11-19-010000.f32", "cmVjaGVjay1ub25jZS0wMDE", [(0, 16), (4096, 100), (9990, 10)]),
        ("dream-catcher/2026-11-19-040000-r1.wav", "cmVjaGVjay1ub25jZS0wMDI", [(0, 10_000)]),
    ]:
        head = "|".join(("eeg-tracker recheck v1", sha(path.encode()), nonce, str(len(data)),
                         ",".join(f"{s}+{n}" for s, n in ranges), ""))
        mac = hmac.new(key.encode(), head.encode() + b"".join(data[s:s + n] for s, n in ranges), hashlib.sha256)
        out.append({"key": key, "path": path, "nonce": nonce, "size": len(data), "ranges": [list(r) for r in ranges],
                    "data": "(i * 7 + 3) % 256 for i in range(10000)", "mac": mac.hexdigest()})
    return out


def pushes() -> list[dict]:
    """The phone's signed requests to the laptop's receiver (scripts/push_receiver.py) and the laptop's proof over
    the same nonce and its answer's bytes."""
    key = "7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544"
    cases = [
        ("POST", "/push/hello", "/push/hello", "", 1763700000123, "cHVzaC1ub25jZS0wMDAwMQ", "", '{"error":"bad request"}'),
        ("POST", "/push/begin", "/push/begin", "", 1763700000456, "cHVzaC1ub25jZS0wMDAwMg",
         '{"v":1,"port":8765,"files":{"format":"eeg-tracker-phone-files","version":1,"files":[]},"asks":[]}',
         '{"v":1,"session":"c2Vzc2lvbi1maXh0dXJlLTE","max_chunk":4194304,"want":[]}'),
        ("POST", "/push/chunk?s=abc&p=recordings%2F2026-11-19-010000.f32&at=4096", "/push/chunk",
         "s=abc&p=recordings/2026-11-19-010000.f32&at=4096", 1763700000789, "cHVzaC1ub25jZS0wMDAwMw",
         "sixteen bytes \u00e9\u00e8", '{"v":1,"staged":4112}'),
        ("POST", "/push/commit?s=abc", "/push/commit", "s=abc", 1763700001000, "cHVzaC1ub25jZS0wMDAwNA", '{"v":1}',
         '{"error":"busy"}'),
    ]
    out = []
    for method, target, path, query, t, nonce, body, reply_body in cases:
        msg = "|".join(("eeg-tracker push v1", method, str(t), nonce, sha(body.encode()), sha(path.encode()),
                        sha(query.encode())))
        out.append({"key": key, "method": method, "target": target, "time_ms": t, "nonce": nonce, "body": body,
                    "sign": hm(key, msg), "reply_body": reply_body,
                    "reply": hm(key, f"eeg-tracker push reply v1|{nonce}|{sha(reply_body.encode())}")})
    return out


def matrix(text: str, level: str, version: int, mask: int) -> list[str]:
    q = qrcode.QRCode(version=version, error_correction=LEVELS[level], mask_pattern=mask, border=0)
    q.add_data(qu.QRData(text.encode("utf-8"), mode=qu.MODE_8BIT_BYTE))
    q.make(fit=False)
    return ["".join("1" if c else "0" for c in row) for row in q.get_matrix()]


def qr_cases() -> list[dict]:
    cases = [
        ("http://192.168.1.10:8771/p?s=AbCdEfGhIjKlMnOpQrStUv", "M", 4, range(8)),
        ("http://192.168.1.10:8771/p#s=AbCdEfGhIjKlMnOpQrStUv", "M", 4, (5,)),  # the code in the part never sent
        ("eegtracker://pair?h=10.0.2.2&p=8771&s=AbCdEfGhIjKlMnOpQrStUv&n=my-laptop", "M", 5, (3,)),
        ("hi", "L", 1, (0, 5)),
        ("x" * 60, "Q", 7, (6,)),  # carries the version bits
        ("y" * 150, "M", 10, (2,)),  # 16-bit length, two block sizes
    ]
    return [{"text": t, "level": lv, "version": v, "mask": m, "rows": matrix(t, lv, v, m)}
            for t, lv, v, masks in cases for m in masks]


if __name__ == "__main__":
    OUT.write_text(json.dumps({"made_by": "make_phone_link_fixture.py (python-qrcode " +
                               getattr(qrcode, "__version__", "7.4.2 (Debian python3-qrcode)") + ")",
                               "proofs": proofs(), "requests": requests(), "rechecks": rechecks(), "push": pushes(),
                               "qr": qr_cases()}, indent=1) + "\n")
    print(f"wrote {OUT}")
