"""scripts/qr_code.py: the same matrices as an independent encoder (python-qrcode, in the fixture), and drawings that
the system's zbar library reads back."""
import ctypes
import ctypes.util
import json
from pathlib import Path

import pytest

import qr_code as q

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "app" / "test" / "fixtures" / "phone_link.json").read_text())


@pytest.mark.parametrize("case", FIXTURE["qr"], ids=lambda c: f"{c['text'][:12]}-{c['level']}{c['version']}-m{c['mask']}")
def test_same_matrix_as_python_qrcode(case: dict) -> None:
    got = q.encode(case["text"], case["level"], version=case["version"], mask=case["mask"])
    assert ["".join("1" if d else "0" for d in row) for row in got] == case["rows"]


def test_smallest_version_and_limits() -> None:
    assert len(q.encode("hi", "L")) == 21  # version 1
    link = "http://192.168.100.200:8771/p?s=" + "A" * 22  # the longest pairing link: 54 bytes
    assert len(q.encode(link, "M")) == 33  # version 4: 21 terminal lines with the quiet zone
    with pytest.raises(ValueError):
        q.encode("z" * 300, "M")
    with pytest.raises(ValueError):
        q.encode("z" * 30, "M", version=1)


def _zbar():
    name = ctypes.util.find_library("zbar") or "libzbar.so.0"
    try:
        z = ctypes.CDLL(name)
    except OSError:
        pytest.skip("the zbar library is not on this computer (Debian: libzbar0)")
    vp = ctypes.c_void_p
    for f, res, args in (
        ("zbar_image_scanner_create", vp, []), ("zbar_image_create", vp, []),
        ("zbar_image_scanner_set_config", ctypes.c_int, [vp, ctypes.c_int, ctypes.c_int, ctypes.c_int]),
        ("zbar_image_set_format", None, [vp, ctypes.c_ulong]), ("zbar_image_set_size", None, [vp, ctypes.c_uint, ctypes.c_uint]),
        ("zbar_image_set_data", None, [vp, vp, ctypes.c_ulong, vp]), ("zbar_scan_image", ctypes.c_int, [vp, vp]),
        ("zbar_image_first_symbol", vp, [vp]), ("zbar_symbol_next", vp, [vp]),
        ("zbar_symbol_get_data", vp, [vp]), ("zbar_symbol_get_data_length", ctypes.c_uint, [vp]),
        ("zbar_image_destroy", None, [vp]), ("zbar_image_scanner_destroy", None, [vp]),
    ):
        getattr(z, f).restype = res
        getattr(z, f).argtypes = args
    return z


def decode(rows: list[list[bool]], scale: int = 4) -> list[bytes]:
    """Dark modules as black pixels on white, read by zbar."""
    z = _zbar()
    n = len(rows) * scale
    px = bytes(0 if rows[y // scale][x // scale] else 255 for y in range(n) for x in range(n))
    scanner, img = z.zbar_image_scanner_create(), z.zbar_image_create()
    try:
        z.zbar_image_scanner_set_config(scanner, 0, 0, 1)
        z.zbar_image_set_format(img, int.from_bytes(b"Y800", "little"))
        z.zbar_image_set_size(img, n, n)
        buf = ctypes.create_string_buffer(px, len(px))
        z.zbar_image_set_data(img, ctypes.cast(buf, ctypes.c_void_p), len(px), None)
        z.zbar_scan_image(scanner, img)
        out, s = [], z.zbar_image_first_symbol(img)
        while s:
            out.append(ctypes.string_at(z.zbar_symbol_get_data(s), z.zbar_symbol_get_data_length(s)))
            s = z.zbar_symbol_next(s)
        return out
    finally:
        z.zbar_image_destroy(img)
        z.zbar_image_scanner_destroy(scanner)


@pytest.mark.parametrize("text", [
    "http://192.168.1.10:8771/p?s=AbCdEfGhIjKlMnOpQrStUv",
    "eegtracker://pair?h=10.0.2.2&p=8771&s=AbCdEfGhIjKlMnOpQrStUv&n=my-laptop",
    "a long one, 16-bit length: " + "z" * 150,  # the links are ASCII (the name is %-encoded): no ECI needed
])
def test_zbar_reads_it(text: str) -> None:
    assert decode(q.with_border(q.encode(text))) == [text.encode("utf-8")]


def test_terminal_drawing_is_the_matrix() -> None:
    """Read the half blocks back into modules: what the terminal shows is the code, with its quiet zone."""
    m = q.encode("http://192.168.1.10:8771/p?s=AbCdEfGhIjKlMnOpQrStUv")
    text = q.terminal(m, color=False)
    top = {" ": (False, False), "▀": (True, False), "▄": (False, True), "█": (True, True)}
    rows: list[list[bool]] = []
    for line in text.split("\n"):
        pairs = [top[c] for c in line]
        rows.append([p[0] for p in pairs])
        rows.append([p[1] for p in pairs])
    framed = q.with_border(m)
    assert rows[:len(framed)] == framed
    assert decode(rows[:len(framed)]) == [b"http://192.168.1.10:8771/p?s=AbCdEfGhIjKlMnOpQrStUv"]
    coloured = q.terminal(m)
    assert coloured.count("\x1b[38;5;16m\x1b[48;5;231m") == len(text.split("\n"))  # black on white, every line


def test_svg() -> None:
    m = q.encode("hi", "L")
    s = q.svg(m)
    assert s.startswith("<svg") and s.count("h1v1h-1z") == sum(map(sum, m))
