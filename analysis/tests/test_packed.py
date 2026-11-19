"""Raw recordings packed after a day (scripts/packed.py, scripts/pack_old.py; DECISIONS 540-549): lossless, checked
before the original goes, skipped while a file may still grow, and read the same as the plain file by every reader;
the catalog, import_phone.py and pull_phone.py know the packed forms (the laptop's .f32.xz, the phone's .f32.gz)."""
import gzip
import hashlib
import json
import lzma
import os
import shutil
import struct
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog  # noqa: E402
import import_phone as ip  # noqa: E402
import night_files as nf  # noqa: E402
import pack_old  # noqa: E402
import packed  # noqa: E402
import phone_night_check as pnc  # noqa: E402
import to_bdf  # noqa: E402
from test_catalog import local  # noqa: E402,F401  (the catalog's fake _local, a fixture)
from test_import_phone import make_export  # noqa: E402
from test_phone_night_check import NIGHT, mixed_night, short_nights_count  # noqa: E402,F401
from test_pull_phone import TOKEN, FakePhone  # noqa: E402

FS, REC = 250, 20
DAY = 86400


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def signal(n: int, seed: int = 0) -> bytes:
    """n records of <I4f: a packet counter and four noisy channels, like a recording."""
    rng = np.random.default_rng(seed)
    rec = np.zeros(n, dtype=[("p", "<u4"), ("v", "<f4", 4)])
    rec["p"] = np.arange(n) % 2048
    rec["v"] = (rng.normal(0, 20e-6, (n, 4)) + np.sin(np.arange(n) / 25)[:, None] * 30e-6).astype("<f4")
    return rec.tobytes()


def write_run(folder: Path, start: datetime, seconds: int, *, age_s: float = 2 * DAY, seed: int = 0) -> Path:
    """<stamp>.f32 + .idx (a batch a second) + .log, last written [age_s] ago."""
    folder.mkdir(parents=True, exist_ok=True)
    stem = start.strftime("%Y-%m-%d-%H%M%S")
    f32 = folder / f"{stem}.f32"
    f32.write_bytes(signal(seconds * FS, seed))
    rows = [struct.pack("<dQ", start.timestamp() + k + 1, k * FS) for k in range(seconds)]
    (folder / f"{stem}.idx").write_bytes(b"".join(rows))
    (folder / f"{stem}.log").write_text("connected\n")
    old = time.time() - age_s
    for f in folder.glob(f"{stem}.*"):
        os.utime(f, (old, old))
    return f32


T = datetime(2026, 11, 10, 23, 0, 0)


# ---- packing one file -------------------------------------------------------------------------------------------

def test_a_packed_file_gives_back_the_same_bytes_and_says_what_it_holds(tmp_path: Path) -> None:
    f32 = write_run(tmp_path, T, 120)
    body, mtime = f32.read_bytes(), f32.stat().st_mtime_ns
    p = packed.pack(f32)
    assert not f32.exists() and p.path == tmp_path / f"{f32.name}.xz"
    assert (p.bytes, p.sha256) == (len(body), sha(body)) and p.packed_bytes < len(body) * 0.8
    assert p.path.stat().st_mtime_ns == mtime  # the original's modified time stays
    assert lzma.decompress(p.path.read_bytes()) == body  # plain xz: any tool unpacks it
    assert packed.info(p.path) == packed.Original(len(body), sha(body))  # from the file's end, without unpacking
    assert packed.unpacked(p.path) == packed.Original(len(body), sha(body))
    assert packed.size(f32) == len(body) and packed.read_bytes(f32) == body and packed.exists(f32)
    assert packed.raw_files(tmp_path) == [f32] and packed.on_disk(f32) == p.path
    with packed.open_raw(f32) as f:  # seeks forward and back
        f.seek(4000)
        a = f.read(20)
        f.seek(20)
        assert (a, f.read(20)) == (body[4000:4020], body[20:40])
    if shutil.which("xz"):  # `xz -lvv` shows the original's SHA-256 as the block's check
        out = subprocess.run(["xz", "-lvv", str(p.path)], capture_output=True, text=True, check=True).stdout
        assert sha(body) in out


def test_a_file_from_another_xz_tool_is_read_by_unpacking_it(tmp_path: Path) -> None:
    body = signal(5000)
    f = tmp_path / "2026-11-10-230000.f32.xz"
    f.write_bytes(lzma.compress(body, check=lzma.CHECK_CRC64))  # xz's own default check: no SHA-256 inside
    assert packed.info(f) == packed.Original(len(body), None)  # the length from its index; no SHA-256 to read
    assert packed.size(f) == len(body) and packed.read_bytes(f) == body
    assert packed.unpacked(f) == packed.Original(len(body), sha(body))
    f.write_bytes(lzma.compress(body[:100]) + lzma.compress(body[100:]))  # two streams: unpacked to know
    os.utime(f, (2, 2))
    assert packed.info(f) == packed.Original(len(body), sha(body))
    f.write_bytes(lzma.compress(body)[:-40])  # cut short
    os.utime(f, (1, 1))
    with pytest.raises(packed.Damaged):
        packed.size(f)


def test_a_crash_while_packing_leaves_the_original_and_no_temporary_file(tmp_path: Path, monkeypatch) -> None:
    f32 = write_run(tmp_path, T, 60)
    body = f32.read_bytes()

    def crash(*_a, **_k):
        raise KeyboardInterrupt  # the process stopped after the copy was written, before it was checked

    monkeypatch.setattr(packed, "unpacked", crash)
    with pytest.raises(KeyboardInterrupt):
        packed.pack(f32)
    assert f32.read_bytes() == body and sorted(p.name for p in tmp_path.iterdir()) == sorted(
        [f32.name, f32.with_suffix(".idx").name, f32.with_suffix(".log").name])


def test_a_copy_that_does_not_unpack_to_the_same_bytes_is_never_used(tmp_path: Path, monkeypatch) -> None:
    f32 = write_run(tmp_path, T, 60)
    body = f32.read_bytes()
    real = lzma.LZMACompressor

    class Flipping:  # a bit flipped on the way to the disk
        def __init__(self, **kw):
            self.c = real(**kw)
            self.buf = b""

        def compress(self, b):
            return self.c.compress(b)

        def flush(self):
            out = bytearray(self.c.flush())
            out[len(out) // 2] ^= 1
            return bytes(out)

    monkeypatch.setattr(packed.lzma, "LZMACompressor", Flipping)
    with pytest.raises(packed.PackError):
        packed.pack(f32)
    assert f32.read_bytes() == body and not packed.packed_path(f32).exists()
    assert not packed.temp_path(f32).exists()


def test_a_file_written_while_it_is_packed_stays_plain(tmp_path: Path, monkeypatch) -> None:
    f32 = write_run(tmp_path, T, 60)
    real = packed.unpacked

    def grow_then_check(path):
        with open(f32, "ab") as f:  # the recorder appended while the copy was checked
            f.write(b"\0" * REC)
        return real(path)

    monkeypatch.setattr(packed, "unpacked", grow_then_check)
    with pytest.raises(packed.PackError, match="changed while it was packed"):
        packed.pack(f32)
    assert f32.stat().st_size == 60 * FS * REC + REC and not packed.packed_path(f32).exists()


def test_a_run_stopped_between_the_copy_and_the_removal_is_finished(tmp_path: Path) -> None:
    f32 = write_run(tmp_path, T, 60)
    body = f32.read_bytes()
    packed.packed_path(f32).write_bytes(lzma.compress(body, check=lzma.CHECK_SHA256))
    p = packed.finish(f32)
    assert p is not None and not f32.exists() and packed.read_bytes(f32) == body
    g32 = write_run(tmp_path, T + timedelta(hours=1), 60, seed=1)
    packed.packed_path(g32).write_bytes(lzma.compress(b"something else"))
    assert packed.finish(g32) is None and g32.exists() and not packed.packed_path(g32).exists()


# ---- the daily run ----------------------------------------------------------------------------------------------

def pack_cli(local: Path, *args: str) -> tuple[int, str]:
    lines: list[str] = []
    code = pack_old.main(["--local", str(local), *args], out=lines.append)
    return code, "\n".join(lines)


def test_the_daily_run_packs_closed_old_files_and_leaves_the_rest(tmp_path: Path) -> None:
    local = tmp_path / "_local"
    old = write_run(local / "recordings", T, 120)
    morning = write_run(local / "phone" / "mornings", T + timedelta(hours=8), 60, seed=2)
    diy = write_run(local / "recordings-diy", T, 60, seed=3)
    tonight = write_run(local / "recordings", T + timedelta(days=9), 60, age_s=600, seed=4)  # still recording
    tiny = write_run(local / "recordings", T + timedelta(hours=3), 2, seed=5)  # 10 KB
    pulling = write_run(local / "recordings", T + timedelta(hours=5), 60, seed=6)  # the phone's, still arriving
    (local / "phone" / "pull-state.json").write_text(json.dumps(dict(version=1, partial={
        f"recordings/{pulling.name}": pulling.stat().st_size}, raw={})))
    before = {p: p.read_bytes() for p in (old, morning, diy, tonight, tiny, pulling)}

    code, text = pack_cli(local, "--dry-run")
    assert code == 0 and "Would pack 3 raw files" in text, text
    assert "1 written in the last day, 1 partial copies still arriving from the phone, 1 under 64 KiB" in text
    assert all(p.read_bytes() == b for p, b in before.items()) and not (local / "packing.jsonl").exists()

    code, text = pack_cli(local)
    assert code == 0 and "Packed 3 raw files" in text, text
    for p in (old, morning, diy):
        assert not p.exists() and packed.read_bytes(p) == before[p]
        assert p.with_suffix(".idx").exists() and p.with_suffix(".log").exists()  # only the .f32 is packed
    for p in (tonight, tiny, pulling):
        assert p.read_bytes() == before[p] and not packed.packed_path(p).exists()
    log = [json.loads(x) for x in (local / "packing.jsonl").read_text().splitlines()]
    assert len(log) == 1 and log[0]["files"] == 3 and log[0]["failed"] == 0
    assert {r["path"]: r["sha256"] for r in log[0]["list"]}[f"recordings/{old.name}.xz"] == sha(before[old])

    code, text = pack_cli(local)  # again: nothing new
    assert code == 0 and text.startswith("Nothing to pack."), text
    assert len((local / "packing.jsonl").read_text().splitlines()) == 1


def test_the_daily_run_cleans_up_after_a_killed_run_and_packs_again(tmp_path: Path) -> None:
    local = tmp_path / "_local"
    a = write_run(local / "recordings", T, 60)
    b = write_run(local / "recordings", T + timedelta(hours=1), 60, seed=1)
    body_a, body_b = a.read_bytes(), b.read_bytes()
    packed.temp_path(a).write_bytes(b"half a copy")  # killed while writing
    packed.packed_path(b).write_bytes(lzma.compress(body_b, check=lzma.CHECK_SHA256))  # killed before the removal
    code, text = pack_cli(local)
    assert code == 0 and "Packed 2 raw files" in text and "1 found half-way" in text, text
    assert not packed.temp_path(a).exists() and not a.exists() and not b.exists()
    assert packed.read_bytes(a) == body_a and packed.read_bytes(b) == body_b


def test_a_file_that_cannot_be_packed_is_a_problem_and_stays(tmp_path: Path, monkeypatch) -> None:
    local = tmp_path / "_local"
    a = write_run(local / "recordings", T, 60)

    def refuse(_p, preset=6):
        raise packed.PackError("the packed copy of it does not give back the same bytes; left as it was")

    monkeypatch.setattr(packed, "pack", refuse)
    code, text = pack_cli(local)
    assert code == 1 and f"PROBLEM: recordings/{a.name} not packed" in text and a.exists()


# ---- the readers --------------------------------------------------------------------------------------------------

def test_the_nights_and_their_samples_read_the_same_packed(tmp_path: Path) -> None:
    rec = tmp_path / "recordings"
    a = write_run(rec, T, 300)
    b = write_run(rec, T + timedelta(minutes=10), 300, seed=1)
    plain_recs = nf.recordings(rec)
    plain = [to_bdf.load(p) for p in (a, b)]
    joined = to_bdf.join([a, b])
    packed.pack(a)
    assert nf.recordings(rec) == plain_recs  # same plain names, sizes and ends
    for p, (uv, idx) in zip((a, b), plain):
        uv2, idx2 = to_bdf.load(p)
        assert np.array_equal(uv, uv2) and np.array_equal(idx, idx2)
    uv3, _ = to_bdf.load(packed.packed_path(a))  # by the packed name too
    assert np.array_equal(plain[0][0], uv3)
    again = to_bdf.join([a, b])
    assert again[0] == joined[0] and np.array_equal(again[1], joined[1]) and again[2] == joined[2]
    night = nf.nights(nf.recordings(rec))[0]
    report = dict(version=nf.VERSION, drift_off=None, inputs=[dict(file=r.path.name, bytes=r.size) for r in plain_recs])
    assert not nf.is_stale(night, report)  # a report made before packing stays up to date


def test_the_phone_night_check_reads_a_packed_night_the_same(tmp_path: Path) -> None:
    mixed_night(tmp_path / "eeg-export")
    want = pnc.render(pnc.check(tmp_path / "eeg-export", NIGHT, signal=True))
    for f in packed.raw_files(tmp_path / "eeg-export" / "recordings"):
        if f.stat().st_size >= packed.MIN_BYTES:
            packed.pack(f)
    assert list((tmp_path / "eeg-export" / "recordings").glob("*.f32.xz"))
    pnc._unpacked.clear()
    assert pnc.render(pnc.check(tmp_path / "eeg-export", NIGHT, signal=True)) == want


def test_the_morning_check_and_the_detectors_loader_read_a_packed_recording(tmp_path: Path) -> None:
    import morning_check
    import validate_detectors as val
    f32 = write_run(tmp_path, T, 60)
    x, miss = val.load_run(f32)
    packed.pack(f32)
    x2, miss2 = val.load_run(f32)
    assert np.array_equal(x, x2) and np.array_equal(miss, miss2)
    assert morning_check.read_markers(f32) == [] and packed.raw_files(tmp_path) == [f32]


# ---- the catalog --------------------------------------------------------------------------------------------------

def catalog_run(local: Path, *args: str) -> tuple[int, str]:
    lines: list[str] = []
    code = catalog.main(["--local", str(local), *args], out=lines.append)
    return code, "\n".join(lines)


def test_the_catalog_calls_a_packed_night_packed_and_checks_it_unpacks(local: Path) -> None:  # noqa: F811
    assert catalog_run(local)[0] == 0
    first = json.loads((local / "catalog" / "catalog.json").read_text())
    plain = {f["path"]: f for n in first["nights"] for f in n["file_list"]}
    rec = local / "recordings"
    for f in packed.raw_files(rec):
        if f.stat().st_size >= packed.MIN_BYTES:
            packed.pack(f)
    code, text = catalog_run(local)
    assert code == 0, text
    assert "PROBLEM" not in text and "missing:" not in text and "packed after a day" in text
    cat = json.loads((local / "catalog" / "catalog.json").read_text())
    files = {f["path"]: f for n in cat["nights"] for f in n["file_list"]}
    packs = {p: f for p, f in files.items() if p.endswith(".f32.xz")}
    assert len(packs) == 3
    for p, f in packs.items():
        o = f["original"]
        assert o["path"] == p[:-3] and (o["bytes"], o["sha256"]) == (plain[p[:-3]]["bytes"], plain[p[:-3]]["sha256"])
        assert f["sha256"] == sha((local / p).read_bytes()) and f["kind"] == "raw"
    assert cat["missing"] == []
    history = (local / "catalog" / "history.log").read_text()
    assert "3 packed" in history and "missing" not in history
    sidecar = (local / "catalog" / "2026-11-16.sha256").read_text()
    assert ".f32.xz" in sidecar
    if shutil.which("sha256sum"):
        for name in ("2026-11-16.sha256",):
            r = subprocess.run(["sha256sum", "-c", str(local / "catalog" / name)], cwd=local, capture_output=True)
            assert r.returncode == 0, r.stdout
    code, text = catalog_run(local, "--check")
    assert code == 0 and "PROBLEM" not in text, text
    # a packed file damaged in place (same size and time): --check unpacks it and says so
    victim = local / next(iter(packs))
    st = victim.stat()
    raw = bytearray(victim.read_bytes())
    raw[len(raw) // 2] ^= 0xFF
    victim.write_bytes(bytes(raw))
    os.utime(victim, ns=(st.st_atime_ns, st.st_mtime_ns))
    code, text = catalog_run(local, "--check")
    assert code == 1 and f"PROBLEM: damaged: {victim.relative_to(local)}" in text, text


def test_a_packed_file_that_holds_other_bytes_is_a_problem(local: Path) -> None:  # noqa: F811
    assert catalog_run(local)[0] == 0
    f = next(p for p in packed.raw_files(local / "recordings") if p.stat().st_size >= packed.MIN_BYTES)
    other = bytes(b ^ 1 for b in f.read_bytes())  # as long as the night, other bytes
    packed.packed_path(f).write_bytes(lzma.compress(other, check=lzma.CHECK_SHA256))
    f.unlink()
    code, text = catalog_run(local)
    assert code == 1 and f"PROBLEM: changed: recordings/{f.name}.xz" in text, text


# ---- the phone's packed files on the laptop -------------------------------------------------------------------------

def phone_packed(body: bytes) -> bytes:
    return gzip.compress(body, mtime=0)


def gz_export(root: Path, files: dict[str, bytes], packs: dict[str, bytes]) -> Path:
    """An export folder holding [files] plain and [packs] as the phone packs them (`<path>.gz` with `original`)."""
    gz = {f"{p}.gz": phone_packed(b) for p, b in packs.items()}
    extra = {f"{p}.gz": dict(original=dict(path=p, bytes=len(b), sha256=sha(b))) for p, b in packs.items()}
    return make_export(root, {**files, **gz}, extra=extra)


NIGHT_F32 = "recordings/2026-11-18-231200.f32"


def import_run(folder: Path, dest: Path, *args: str) -> tuple[int, str]:
    lines: list[str] = []
    code = ip.main([str(folder), "--dest", str(dest), *args], out=lines.append)
    return code, "\n".join(lines)


def test_an_export_of_a_packed_night_lands_unpacked_and_is_never_copied_twice(tmp_path: Path) -> None:
    body = signal(20000)
    dest = tmp_path / "_local"
    exp = gz_export(tmp_path / "eeg-export", {"recordings/2026-11-18-231200.log": b"connected\n"}, {NIGHT_F32: body})
    code, text = import_run(exp, dest, "--dry-run")
    assert code == 0 and not (dest / NIGHT_F32).exists(), text
    code, text = import_run(exp, dest)
    assert code == 0 and "2 new" in text, text
    got = dest / NIGHT_F32
    assert got.read_bytes() == body and not (dest / f"{NIGHT_F32}.gz").exists()
    assert got.stat().st_mtime_ns == 1_763_500_000_000 * 1_000_000  # the phone's modified time
    assert import_run(exp, dest)[1].count("already here") == 1
    packed.pack(got)  # the laptop packed it after a day
    code, text = import_run(exp, dest)
    assert code == 0 and "2 already here" in text, text
    exp2 = make_export(tmp_path / "plain" / "eeg-export", {NIGHT_F32: body})  # the plain form, exported before
    code, text = import_run(exp2, dest)
    assert code == 0 and "1 already here" in text and not got.exists(), text


def test_a_damaged_packed_export_is_not_copied_and_a_bad_original_stops_the_import(tmp_path: Path) -> None:
    body = signal(20000)
    exp = gz_export(tmp_path / "eeg-export", {}, {NIGHT_F32: body})
    m = json.loads((exp / "manifest.json").read_text())
    m["files"][0]["original"]["sha256"] = sha(b"other bytes")  # the gzip file is as listed, what it holds is not
    (exp / "manifest.json").write_text(json.dumps(m))
    code, text = import_run(exp, tmp_path / "_local")
    assert code == 1 and "1 damaged" in text and not (tmp_path / "_local" / NIGHT_F32).exists(), text
    m["files"][0]["original"]["path"] = "recordings/another.f32"
    (exp / "manifest.json").write_text(json.dumps(m))
    code, text = import_run(exp, tmp_path / "_local")
    assert code == 2 and "damaged entry" in text, text


@pytest.fixture
def phone():
    f = FakePhone()
    yield f
    f.close()


def pull(phone: FakePhone, dest: Path):
    import pull_phone as pp
    return pp.pull(pp.Phone(phone.base, TOKEN), dest, now=datetime(2026, 11, 20, 9, 0).astimezone())


def put_packed(phone: FakePhone, path: str, body: bytes, *, holds: bytes | None = None) -> None:
    """The phone's packed night, listed with its original ([holds]'s numbers, to fake a wrong one)."""
    held = body if holds is None else holds
    phone.put(f"{path}.gz", phone_packed(body))
    phone.originals[f"{path}.gz"] = dict(path=path, bytes=len(held), sha256=sha(held))


def test_pull_fetches_a_packed_night_once_whatever_side_packed_it(phone: FakePhone, tmp_path: Path) -> None:
    body, dest = signal(20000), tmp_path / "_local"
    put_packed(phone, NIGHT_F32, body)
    rep = pull(phone, dest)
    assert rep.new == [NIGHT_F32] and not rep.problems
    assert (dest / NIGHT_F32).read_bytes() == body and not list((dest / "recordings").glob("*pulling*"))
    assert phone.fetched() == [(f"{NIGHT_F32}.gz", f"bytes=0-{len(phone_packed(body)) - 1}")]
    rep = pull(phone, dest)  # again: already here
    assert rep.same == 1 and not rep.changed and phone.fetched() == []
    packed.pack(dest / NIGHT_F32)  # the laptop packs its copy after a day
    rep = pull(phone, dest)
    assert rep.same == 1 and not rep.changed and phone.fetched() == []
    del phone.files[f"{NIGHT_F32}.gz"]  # the phone lists the plain file (as before it packed it)
    phone.put(NIGHT_F32, body)
    rep = pull(phone, dest)
    assert rep.same == 1 and not rep.changed and phone.fetched() == []
    assert not (dest / NIGHT_F32).exists() and packed.read_bytes(dest / NIGHT_F32) == body


def test_pull_never_takes_a_packed_night_that_does_not_hold_what_it_says(phone: FakePhone, tmp_path: Path) -> None:
    body, dest = signal(20000), tmp_path / "_local"
    put_packed(phone, NIGHT_F32, body, holds=signal(20000, seed=9))
    rep = pull(phone, dest)
    assert rep.damaged == [NIGHT_F32] and not (dest / NIGHT_F32).exists()
    assert not list((dest / "recordings").glob("*pulling*"))


def test_pull_replaces_its_own_unfinished_copy_with_the_packed_night(phone: FakePhone, tmp_path: Path) -> None:
    body, dest = signal(20000), tmp_path / "_local"
    phone.put(NIGHT_F32, body[:100000], growing=True)  # the night as it was being recorded
    assert pull(phone, dest).new == [NIGHT_F32]
    del phone.files[NIGHT_F32]  # the laptop was away until the phone had packed it
    put_packed(phone, NIGHT_F32, body)
    rep = pull(phone, dest)
    assert rep.updated == [NIGHT_F32] and not rep.problems
    assert (dest / NIGHT_F32).read_bytes() == body
