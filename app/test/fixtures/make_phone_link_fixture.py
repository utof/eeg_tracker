"""Writes phone_link.json: the pairing proofs (scripts/phone_link.py <-> app/lib/share/link.dart) and reference QR
matrices for scripts/qr_code.py made by an independent encoder (python-qrcode, BSD).

    /usr/bin/python3 app/test/fixtures/make_phone_link_fixture.py     # needs python-qrcode (Debian: python3-qrcode)

The proofs are HMAC-SHA256 from Python's standard library, written out here by hand (not through phone_link.py), so
both the laptop's and the app's code are checked against the same independent numbers.
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


def proofs() -> list[dict]:
    cases = [
        ("code", "Zm9yLXRoZS1maXh0dXJlLW9ubHk", "cGhvbmUtbm9uY2UtMDAwMQ", "bGFwdG9wLW5vbmNlLTAwMDE"),
        ("key", "a2V5LWZvci10aGUtZml4dHVyZS1vbmx5LTMyLWJ5dGVzLWxvbmc", "cGhvbmUtbm9uY2UtMDAwMg",
         "bGFwdG9wLW5vbmNlLTAwMDI"),
    ]
    out = []
    for via, secret, phone_nonce, laptop_nonce in cases:
        out.append({
            "via": via, "secret": secret, "phone_nonce": phone_nonce, "laptop_nonce": laptop_nonce,
            "laptop_proof": hm(secret, f"eeg-tracker link v1|laptop|{via}|{phone_nonce}|{laptop_nonce}"),
            "phone_proof": hm(secret, f"eeg-tracker link v1|phone|{via}|{laptop_nonce}|{phone_nonce}"),
        })
    return out


def matrix(text: str, level: str, version: int, mask: int) -> list[str]:
    q = qrcode.QRCode(version=version, error_correction=LEVELS[level], mask_pattern=mask, border=0)
    q.add_data(qu.QRData(text.encode("utf-8"), mode=qu.MODE_8BIT_BYTE))
    q.make(fit=False)
    return ["".join("1" if c else "0" for c in row) for row in q.get_matrix()]


def qr_cases() -> list[dict]:
    cases = [
        ("http://192.168.1.10:8771/p?s=AbCdEfGhIjKlMnOpQrStUv", "M", 4, range(8)),
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
                               "proofs": proofs(), "qr": qr_cases()}, indent=1) + "\n")
    print(f"wrote {OUT}")
