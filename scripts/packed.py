"""Packed raw recordings: `<stamp>.f32.xz` in place of `<stamp>.f32`, read as if it were the plain file.

A raw `.f32` that nothing has written for a day is packed with xz (scripts/pack_old.py; DECISIONS 540-549): lossless,
the same bytes come back. Every laptop reader of a raw `.f32` goes through this module, so it opens either form:

- `on_disk(path)`, `exists(path)`: the file that holds a raw file's bytes (the plain one first, else the packed one).
- `size(path)`: the original's length without unpacking (the xz index holds it).
- `open_raw(path)`, `read_bytes(path)`: the original's bytes.
- `raw_files(folder)`: every `<stamp>.f32` in a folder, packed or not, by its plain name.

The phone packs its own after a day as `<stamp>.f32.gz` (app/lib/recorder/packed.dart: gzip, whose header names
the .f32 and holds its length and SHA-256). import_phone.py and pull_phone.py unpack those as they arrive, but an
export folder or a copy of the phone's files may still hold them, so the readers here open that form too.

Readers keep using the plain name (`<stamp>.f32`): the sleep report's `inputs`, `with_suffix(".idx")` and the
catalog's night rows stay as they were. Only `.f32` is packed; `.idx`, `.log` and `.markers.jsonl` stay plain (the
nights' chaining reads the last `.idx` row of every recording, often).

A packed file says what it holds: xz's own SHA-256 check over the one block it has is the SHA-256 of the original
(`xz -lvv` shows it as CheckVal), and every unpacking checks it. `info()` reads it and the original's length from the
file's end without unpacking. `pack()` writes the packed copy under a temporary name, unpacks it to check that it gives
back the original's bytes (length and SHA-256), gives it the original's modified time, puts it in place, and only then
removes the original. Standard library only (the recorder hub imports night_files.py, which imports this).
"""
from __future__ import annotations

import gzip, hashlib, json, lzma, os, struct, zlib
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

SUFFIX = ".xz"  # what the laptop writes
FORMS = (SUFFIX, ".gz")  # what it reads: its own form, and the phone's
RAW = ".f32"
PACKED = RAW + SUFFIX
PACKED_FORMS = tuple(RAW + s for s in FORMS)
PRESET = 6  # xz -6, the default: 61 % smaller on a real night (DECISIONS 541)
MIN_BYTES = 64 * 1024  # smaller files are left plain: under 13 s of signal, little to gain
CHUNK = 1 << 20
_MAGIC, _FOOT = b"\xfd7zXZ\x00", b"YZ"
_SHA256_CHECK = 0x0A


class PackError(Exception):
    """A file was not packed; it stays as it was."""


class Damaged(OSError):
    """A packed file that does not unpack."""


@dataclass(frozen=True)
class Original:
    bytes: int
    sha256: str | None  # None when the packed file does not say (not one block with a SHA-256 check)


@dataclass(frozen=True)
class Packed:
    path: Path  # the packed file
    bytes: int  # of the original
    packed_bytes: int
    sha256: str  # of the original


def packed_path(path: Path) -> Path:
    return path.with_name(path.name + SUFFIX)


def is_packed(path: Path) -> bool:
    """A packed raw file: `<stamp>.f32.xz` (the laptop's) or `<stamp>.f32.gz` (the phone's)."""
    return path.name.endswith(PACKED_FORMS)


def logical(path: Path) -> Path:
    """The plain name of a raw file: `<stamp>.f32` for `<stamp>.f32.xz` or `.f32.gz`."""
    return path.with_name(path.name[:-3]) if is_packed(path) else path  # both suffixes are 3 characters


def on_disk(path: Path | str) -> Path | None:
    """The file holding a raw file's bytes: the plain one, else a packed one (the laptop's form first); None when
    neither is there."""
    p = Path(path)
    if is_packed(p):
        return p if p.is_file() else None
    if p.is_file():
        return p
    for s in FORMS:
        x = p.with_name(p.name + s)
        if x.is_file():
            return x
    return None


def exists(path: Path | str) -> bool:
    return on_disk(path) is not None


def raw_files(folder: Path | str, ext: str = RAW) -> list[Path]:
    """Every `*<ext>` in [folder] by its plain name, whether it is packed or not, sorted."""
    d = Path(folder)
    found = {p for p in d.glob(f"*{ext}") if p.is_file()}
    for s in FORMS:
        found |= {logical(p) for p in d.glob(f"*{ext}{s}") if p.is_file()}
    return sorted(found)


def _vli(b: bytes, pos: int) -> tuple[int, int]:
    """xz's variable-length integer at [pos]: (value, next position)."""
    value = 0
    for k in range(9):
        if pos >= len(b):
            raise ValueError("cut short")
        byte = b[pos]
        pos += 1
        value |= (byte & 0x7F) << (7 * k)
        if not byte & 0x80:
            return value, pos
    raise ValueError("too long")


def _up4(n: int) -> int:
    return (n + 3) & ~3


def _parse(path: Path, size: int) -> Original | None:
    """The original's length and SHA-256 from the xz file's index and its block's check, for a file of one stream
    with one block (what pack() writes); None for anything else."""
    if size < 32:
        return None
    with open(path, "rb") as f:
        head = f.read(12)
        f.seek(size - 12)
        foot = f.read(12)
        if head[:6] != _MAGIC or foot[10:] != _FOOT or foot[8:10] != head[6:8]:
            return None
        if zlib.crc32(foot[4:10]) != struct.unpack("<I", foot[:4])[0]:
            return None
        index_size = (struct.unpack("<I", foot[4:8])[0] + 1) * 4
        start = size - 12 - index_size
        if start < 12:
            return None
        f.seek(start)
        index = f.read(index_size)
        if index[:1] != b"\0" or zlib.crc32(index[:-4]) != struct.unpack("<I", index[-4:])[0]:
            return None
        try:
            records, pos = _vli(index, 1)
            unpadded, pos = _vli(index, pos)
            uncompressed, pos = _vli(index, pos)
        except ValueError:
            return None
        if records != 1 or 12 + _up4(unpadded) != start:
            return None  # more than one block, or padding between streams: unpack to know
        sha = None
        if head[7] & 0x0F == _SHA256_CHECK and unpadded > 32:
            f.seek(12 + _up4(unpadded - 32))
            sha = f.read(32).hex()
        return Original(uncompressed, sha)


def _parse_gz(path: Path) -> Original | None:
    """The original's length and SHA-256 from the phone's gzip header (its comment field); None without them."""
    with open(path, "rb") as f:
        h = f.read(4096)
    if len(h) < 10 or h[:3] != b"\x1f\x8b\x08" or not h[3] & 16:
        return None
    o = 10
    if h[3] & 4:
        o += 2 + int.from_bytes(h[o:o + 2], "little")
    if h[3] & 8:
        o = h.find(b"\0", o) + 1
        if o == 0:
            return None
    z = h.find(b"\0", o)
    try:
        j = json.loads(h[o:z].decode("latin-1")) if z > o else None
    except ValueError:
        return None
    size, sha = (j.get("bytes"), j.get("sha256")) if isinstance(j, dict) else (None, None)
    if isinstance(size, int) and size >= 0 and isinstance(sha, str) and len(sha) == 64:
        return Original(size, sha)
    return None


def _open_packed(path: Path) -> BinaryIO:
    return gzip.open(path, "rb") if path.name.endswith(".gz") else lzma.open(path, "rb")  # type: ignore[return-value]


def unpacked(path: Path) -> Original:
    """Unpacks the whole file (xz checks its own check, gzip its CRC, on the way) and returns the length and SHA-256
    of what came out. Raises lzma.LZMAError, zlib.error, gzip.BadGzipFile or EOFError for a damaged file."""
    h, n = hashlib.sha256(), 0
    with _open_packed(path) as r:
        while b := r.read(CHUNK):
            h.update(b)
            n += len(b)
    return Original(n, h.hexdigest())


_infos: dict[tuple[str, int, int], Original] = {}


def info(path: Path) -> Original:
    """What a packed file holds: the original's length and SHA-256, read from its end (unpacked only when it is not
    pack()'s single-block form). Cached while the file's size and modified time stay the same. Raises Damaged (an
    OSError) for a file that has to be unpacked and does not unpack."""
    st = path.stat()
    key = (str(path), st.st_size, st.st_mtime_ns)
    if key not in _infos:
        try:
            told = _parse_gz(path) if path.name.endswith(".gz") else _parse(path, st.st_size)
            _infos[key] = told or unpacked(path)
        except (lzma.LZMAError, zlib.error, EOFError, gzip.BadGzipFile) as e:
            raise Damaged(f"{path.name} does not unpack ({e})") from e
    return _infos[key]


def size(path: Path | str) -> int:
    """The original's length in bytes, packed or not. Raises FileNotFoundError when neither form is there."""
    d = on_disk(path)
    if d is None:
        raise FileNotFoundError(str(path))
    return info(d).bytes if is_packed(d) else d.stat().st_size


def open_raw(path: Path | str) -> BinaryIO:
    """The original's bytes, packed or not (a packed file can seek, slowly backwards)."""
    d = on_disk(path)
    if d is None:
        raise FileNotFoundError(str(path))
    return _open_packed(d) if is_packed(d) else open(d, "rb")


def read_bytes(path: Path | str) -> bytes:
    with open_raw(path) as f:
        return f.read()


def content_sha256(path: Path | str) -> str:
    """SHA-256 of the original's bytes, packed or not (reads, and unpacks, everything)."""
    h = hashlib.sha256()
    with open_raw(path) as f:
        while b := f.read(CHUNK):
            h.update(b)
    return h.hexdigest()


def _same(path: Path, st: os.stat_result) -> bool:
    try:
        now = path.stat()
    except OSError:
        return False
    return now.st_size == st.st_size and now.st_mtime_ns == st.st_mtime_ns


def _sync_dir(d: Path) -> None:
    try:
        fd = os.open(d, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def temp_path(path: Path) -> Path:
    """Where pack() writes before the check: hidden, and named so no reader takes it for a recording."""
    return path.with_name(f".{path.name}{SUFFIX}.packing")


def pack(path: Path, preset: int = PRESET) -> Packed:
    """Packs one raw file that nothing writes any more. Raises PackError (the original untouched, nothing left
    behind) when it changed while it was read or the packed copy does not give back the same bytes."""
    src = Path(path)
    dst, tmp = packed_path(src), temp_path(src)
    st = src.stat()
    h, n = hashlib.sha256(), 0
    comp = lzma.LZMACompressor(format=lzma.FORMAT_XZ, check=lzma.CHECK_SHA256, preset=preset)
    try:
        with open(src, "rb") as r, open(tmp, "wb") as w:
            while b := r.read(CHUNK):
                h.update(b)
                n += len(b)
                w.write(comp.compress(b))
            w.write(comp.flush())
            w.flush()
            os.fsync(w.fileno())
        want = Original(n, h.hexdigest())
        if n != st.st_size or not _same(src, st):
            raise PackError(f"{src.name} changed while it was packed; left as it was")
        try:
            back = unpacked(tmp)
        except (lzma.LZMAError, EOFError) as e:
            raise PackError(f"the packed copy of {src.name} does not unpack ({e}); left as it was") from e
        if back != want or _parse(tmp, tmp.stat().st_size) != want:
            raise PackError(f"the packed copy of {src.name} does not give back the same bytes; left as it was")
        os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
        os.replace(tmp, dst)
        _sync_dir(src.parent)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    if not _same(src, st):  # written to in the last moment: the packed copy is behind; keep the original
        dst.unlink(missing_ok=True)
        raise PackError(f"{src.name} changed while it was packed; left as it was")
    src.unlink()
    _sync_dir(src.parent)
    return Packed(dst, n, dst.stat().st_size, want.sha256 or "")


def finish(path: Path) -> Packed | None:
    """A plain file whose packed copy is already there (a run stopped between putting the copy in place and removing
    the original): when the copy unpacks to the same bytes the original goes and the copy is returned; otherwise the
    copy (ours, and wrong) goes and None is returned, so the file is packed again."""
    src, dst = Path(path), packed_path(Path(path))
    st = src.stat()
    want = Original(st.st_size, content_sha256(src))
    try:
        back = unpacked(dst)
    except (lzma.LZMAError, EOFError, OSError):
        back = None
    if back == want and _same(src, st):
        src.unlink()
        _sync_dir(src.parent)
        return Packed(dst, want.bytes, dst.stat().st_size, want.sha256 or "")
    dst.unlink(missing_ok=True)
    return None


def gunzip_checked(src: BinaryIO, out: BinaryIO | None, gz: Original, original: Original) -> bool:
    """Reads a gzip file (the phone's packed form, `.f32.gz`) from [src], unpacks it into [out] (or only checks it
    when out is None), and says whether the gzip file had [gz]'s length and SHA-256 and what came out of it
    [original]'s. A damaged or cut-short file is False, never an error."""
    hz, ho = hashlib.sha256(), hashlib.sha256()
    nz = no = 0
    d = zlib.decompressobj(31)
    ended = False  # the last gzip member read so far was complete, with nothing after it yet
    try:
        while b := src.read(CHUNK):
            hz.update(b)
            nz += len(b)
            while b:
                ended = False
                piece = d.decompress(b)
                ho.update(piece)
                no += len(piece)
                if out is not None:
                    out.write(piece)
                if not d.eof:
                    break
                b, d, ended = d.unused_data, zlib.decompressobj(31), True  # gzip allows members one after another
    except zlib.error:
        return False
    return (ended and nz == gz.bytes and hz.hexdigest() == gz.sha256 and no == original.bytes
            and ho.hexdigest() == original.sha256)
