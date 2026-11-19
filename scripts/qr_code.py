"""A small QR code encoder: byte mode, versions 1-10, for the pairing link of scripts/phone_link.py.

Standard library only. `encode(text)` gives the matrix (rows of booleans, True = dark, no quiet zone); `terminal()`
draws it with half-block characters in black on white, `svg()` as a picture for a web page.

Checked in analysis/tests/test_qr_code.py against python-qrcode's matrices (app/test/fixtures/phone_link.json, 840
version/level/mask cases matched when written) and by decoding the drawings with the system's zbar library.

The encoding steps (Reed-Solomon, the block interleave, the module placement, the format and version bits) follow
Project Nayuki's QR Code generator library, cut down to byte mode and versions 1-10:
  Copyright (c) Project Nayuki. (MIT License) https://www.nayuki.io/page/qr-code-generator-library
  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
  documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright
  notice and this permission notice shall be included in all copies or substantial portions of the Software.
  The Software is provided "as is", without warranty of any kind, express or implied, including but not limited to
  the warranties of merchantability, fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other liability, whether in an action of contract,
  tort or otherwise, arising from, out of or in connection with the Software or the use or other dealings in the
  Software.
"""
from __future__ import annotations

LEVELS = {"L": 1, "M": 0, "Q": 3, "H": 2}  # the format bits of each error correction level
_LEVEL_INDEX = {"L": 0, "M": 1, "Q": 2, "H": 3}
MAX_VERSION = 10

# Error correction codewords per block and number of blocks, per level (L, M, Q, H) and version (index 0 unused).
_ECC_PER_BLOCK = (
    (0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18),
    (0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26),
    (0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24),
    (0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28),
)
_BLOCKS = (
    (0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4),
    (0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5),
    (0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8),
    (0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8),
)

Matrix = list[list[bool]]


def _raw_modules(ver: int) -> int:
    """Modules left for data and error correction once the function patterns are drawn."""
    n = (16 * ver + 128) * ver + 64
    if ver >= 2:
        align = ver // 7 + 2
        n -= (25 * align - 10) * align - 55
        if ver >= 7:
            n -= 36
    return n


def data_capacity(ver: int, level: str) -> int:
    """Data codewords (bytes) of a version at a level."""
    i = _LEVEL_INDEX[level]
    return _raw_modules(ver) // 8 - _ECC_PER_BLOCK[i][ver] * _BLOCKS[i][ver]


def _gf_mul(x: int, y: int) -> int:
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_divisor(degree: int) -> list[int]:
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _gf_mul(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _gf_mul(root, 0x02)
    return result


def _rs_remainder(data: list[int], divisor: list[int]) -> list[int]:
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _gf_mul(coef, factor)
    return result


def _codewords(payload: bytes, ver: int, level: str) -> list[int]:
    """Mode, length, data, terminator and padding, split into blocks with their error correction, interleaved."""
    bits: list[int] = []

    def put(value: int, n: int) -> None:
        bits.extend((value >> i) & 1 for i in reversed(range(n)))

    cap = data_capacity(ver, level)
    put(0b0100, 4)  # byte mode
    put(len(payload), 8 if ver <= 9 else 16)
    for b in payload:
        put(b, 8)
    put(0, min(4, cap * 8 - len(bits)))
    put(0, -len(bits) % 8)
    data = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(data) < cap:
        data.append(pad)
        pad ^= 0xEC ^ 0x11

    i = _LEVEL_INDEX[level]
    nblocks, ecc_len = _BLOCKS[i][ver], _ECC_PER_BLOCK[i][ver]
    raw = _raw_modules(ver) // 8
    nshort, short_len = nblocks - raw % nblocks, raw // nblocks
    divisor = _rs_divisor(ecc_len)
    blocks, k = [], 0
    for b in range(nblocks):
        part = data[k:k + short_len - ecc_len + (0 if b < nshort else 1)]
        k += len(part)
        ecc = _rs_remainder(part, divisor)
        if b < nshort:
            part = part + [0]
        blocks.append(part + ecc)
    out = []
    for col in range(len(blocks[0])):
        for b, blk in enumerate(blocks):
            if col != short_len - ecc_len or b >= nshort:
                out.append(blk[col])
    return out


def _alignment_positions(ver: int, size: int) -> list[int]:
    if ver == 1:
        return []
    n = ver // 7 + 2
    step = (ver * 8 + n * 3 + 5) // (n * 4 - 4) * 2
    return [6] + sorted(size - 7 - i * step for i in range(n - 1))


class _Grid:
    def __init__(self, ver: int) -> None:
        self.ver = ver
        self.size = ver * 4 + 17
        self.dark = [[False] * self.size for _ in range(self.size)]
        self.fixed = [[False] * self.size for _ in range(self.size)]

    def set_fixed(self, x: int, y: int, dark: bool) -> None:
        self.dark[y][x] = dark
        self.fixed[y][x] = True

    def draw_functions(self) -> None:
        s = self.size
        for i in range(s):
            self.set_fixed(6, i, i % 2 == 0)
            self.set_fixed(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (s - 4, 3), (3, s - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < s and 0 <= y < s:
                        self.set_fixed(x, y, max(abs(dx), abs(dy)) not in (2, 4))
        pos = _alignment_positions(self.ver, s)
        last = len(pos) - 1
        for i, a in enumerate(pos):
            for j, b in enumerate(pos):
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.set_fixed(a + dx, b + dy, max(abs(dx), abs(dy)) != 1)
        self.draw_format("M", 0)  # reserves the area; drawn again with the real mask
        if self.ver >= 7:
            rem = self.ver
            for _ in range(12):
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
            bits = self.ver << 12 | rem
            for i in range(18):
                bit = (bits >> i) & 1 == 1
                a, b = s - 11 + i % 3, i // 3
                self.set_fixed(a, b, bit)
                self.set_fixed(b, a, bit)

    def draw_format(self, level: str, mask: int) -> None:
        data = LEVELS[level] << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412
        s = self.size

        def bit(i: int) -> bool:
            return (bits >> i) & 1 == 1

        for i in range(6):
            self.set_fixed(8, i, bit(i))
        self.set_fixed(8, 7, bit(6))
        self.set_fixed(8, 8, bit(7))
        self.set_fixed(7, 8, bit(8))
        for i in range(9, 15):
            self.set_fixed(14 - i, 8, bit(i))
        for i in range(8):
            self.set_fixed(s - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self.set_fixed(8, s - 15 + i, bit(i))
        self.set_fixed(8, s - 8, True)

    def draw_data(self, codewords: list[int]) -> None:
        s, i, total = self.size, 0, len(codewords) * 8
        right = s - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(s):
                for j in range(2):
                    x = right - j
                    upward = (right + 1) & 2 == 0
                    y = s - 1 - vert if upward else vert
                    if not self.fixed[y][x] and i < total:
                        self.dark[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
            right -= 2

    def apply_mask(self, mask: int) -> None:
        for y in range(self.size):
            for x in range(self.size):
                if not self.fixed[y][x] and _MASKS[mask](x, y):
                    self.dark[y][x] = not self.dark[y][x]


_MASKS = (
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
)

_FINDER_LIKE = ((True, False, True, True, True, False, True, False, False, False, False),
                (False, False, False, False, True, False, True, True, True, False, True))


def penalty(m: Matrix) -> int:
    """The standard's four penalty rules; the mask with the lowest score is used."""
    n, score = len(m), 0
    lines = [list(r) for r in m] + [[m[y][x] for y in range(n)] for x in range(n)]
    for line in lines:
        run = 1
        for i in range(1, n + 1):
            if i < n and line[i] == line[i - 1]:
                run += 1
                continue
            if run >= 5:
                score += 3 + run - 5
            run = 1
        for i in range(n - 10):
            if tuple(line[i:i + 11]) in _FINDER_LIKE:
                score += 40
    for y in range(n - 1):
        for x in range(n - 1):
            c = m[y][x]
            if c == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                score += 3
    dark = sum(map(sum, m))
    total = n * n
    score += 10 * ((abs(dark * 20 - total * 10) + total - 1) // total - 1)
    return score


def encode(text: str | bytes, level: str = "M", *, version: int | None = None, mask: int | None = None) -> Matrix:
    """The QR code of [text] (UTF-8) at [level]: the smallest version that holds it, the best mask, unless given."""
    payload = text.encode("utf-8") if isinstance(text, str) else bytes(text)
    if level not in LEVELS:
        raise ValueError(f"level must be one of {sorted(LEVELS)}")
    need = lambda v: 4 + (8 if v <= 9 else 16) + 8 * len(payload)  # noqa: E731
    fits = [v for v in range(1, MAX_VERSION + 1) if need(v) <= data_capacity(v, level) * 8]
    if version is None:
        if not fits:
            raise ValueError(f"{len(payload)} bytes do not fit in a version {MAX_VERSION} QR code at level {level}")
        version = fits[0]
    elif version not in fits:
        raise ValueError(f"{len(payload)} bytes do not fit in version {version} at level {level}")
    codewords = _codewords(payload, version, level)
    best: tuple[int, Matrix] | None = None
    for k in range(8) if mask is None else (mask,):
        g = _Grid(version)
        g.draw_functions()
        g.draw_data(codewords)
        g.apply_mask(k)
        g.draw_format(level, k)
        score = penalty(g.dark) if mask is None else 0
        if best is None or score < best[0]:
            best = (score, g.dark)
    assert best is not None
    return best[1]


def with_border(m: Matrix, border: int = 4) -> Matrix:
    n = len(m) + 2 * border
    out = [[False] * n for _ in range(n)]
    for y, row in enumerate(m):
        for x, dark in enumerate(row):
            out[y + border][x + border] = dark
    return out


# Black on white whatever the terminal's own colours are: a camera reads dark modules on a light field.
_INK = "\x1b[38;5;16m\x1b[48;5;231m"
_RESET = "\x1b[0m"


def terminal(m: Matrix, *, border: int = 4, color: bool = True) -> str:
    """Two module rows per text line: "▀" dark above, "▄" dark below, "█" both, " " neither."""
    b = with_border(m, border)
    width = len(b)
    if len(b) % 2:
        b.append([False] * width)
    chars = {(False, False): " ", (True, False): "▀", (False, True): "▄", (True, True): "█"}
    lines = []
    for y in range(0, len(b), 2):
        row = "".join(chars[(b[y][x], b[y + 1][x])] for x in range(width))
        lines.append(f"{_INK}{row}{_RESET}" if color else row)
    return "\n".join(lines)


def svg(m: Matrix, *, border: int = 4, scale: int = 8) -> str:
    """A crisp picture: one path of dark squares on white."""
    n = len(m) + 2 * border
    cells = "".join(f"M{x + border},{y + border}h1v1h-1z" for y, row in enumerate(m) for x, d in enumerate(row) if d)
    px = n * scale
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}" width="{px}" height="{px}" '
            f'shape-rendering="crispEdges"><rect width="{n}" height="{n}" fill="#fff"/>'
            f'<path d="{cells}" fill="#000"/></svg>')
