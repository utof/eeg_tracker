"""Bring the phone app's export onto the laptop: check every file against the export's manifest, then copy it in.

usage: import_phone.py <export folder> [--dest _local] [--dry-run] [--rehash]

<export folder> is the `eeg-export` folder the app writes (Export data; docs/data-format.md, "The phone's export
folder"), or the folder holding it: the Syncthing folder, or a copy taken with
`adb pull /sdcard/Download/EEG/eeg-export`.

- Raw nights (`recordings/<stamp>.f32 .idx .log .markers.jsonl`) go into `<dest>/recordings/`, next to the laptop's
  own recordings; the DIY board's (`recordings-diy/...`) into `<dest>/recordings-diy/`, next to the laptop's DIY
  recordings and never among the BrainBit nights (docs/diy-board.md); everything else keeps its place under
  `<dest>/phone/` (`phone/nights/<date>.report.json`, `phone/meditations/...`, `phone/dream-catcher/...`).
- A file is copied only when its size and SHA-256 match the manifest (the copy is checked, then renamed into place).
- Nothing is overwritten silently: when the laptop already has a different copy, the phone's replaces it only if the
  phone changed it later, and the older copy is moved to `<dest>/phone/replaced/<import time>/`; otherwise the laptop's
  copy is left alone. Both are counted in the summary. Nothing is ever deleted.
- A file listed in the manifest but gone from the folder is fine when the laptop already has it (the owner may clear
  the export folder after an import); otherwise it is reported as missing.
- `<dest>/phone/manifests/` keeps every manifest imported, `<dest>/phone/imports.jsonl` one line per import, and
  `<dest>/phone/import-index.json` the SHA-256 of the copies (by size and modified time), so a later import does not
  read every old file again (`--rehash` does).
- A raw file the phone packed after a day (`recordings/<stamp>.f32.gz`, DECISIONS 540-549) is listed with its
  `original` (the `.f32`'s path, bytes and SHA-256). It is checked as sent (the gzip file's size and SHA-256), unpacked
  and checked again (the original's), and lands as the plain `<stamp>.f32`, where scripts/pack_old.py packs it with
  xz after a day like any other. It is "already here" when the laptop holds the same `.f32`, plain or packed: a night
  is never copied twice because the phone renamed it.

Exit status: 0 when everything in the phone's list is on the laptop, 1 when something is damaged, missing or not yet
exported, 2 when the manifest cannot be used. Standard library only.
"""
from __future__ import annotations

import argparse, hashlib, json, os, shutil, sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import packed  # noqa: E402  (raw files packed after a day: the phone's .f32.gz, the laptop's .f32.xz)

FORMAT = "eeg-tracker-phone-export"
VERSION = 1
FOLDER = "eeg-export"  # the folder the app creates inside the one the owner picked
OWN = {"manifest.json", "exports.jsonl"}  # the export's own files, not data
CHUNK = 1 << 20
SHOW = 5  # names listed per line before "and N more"
DEFAULT_DEST = Path(__file__).resolve().parents[1] / "_local"


class ManifestError(Exception):
    pass


@dataclass(frozen=True)
class Original:
    """What a packed phone file holds: the plain file's path, bytes and SHA-256."""
    path: PurePosixPath
    bytes: int
    sha256: str


@dataclass(frozen=True)
class Entry:
    path: PurePosixPath
    bytes: int
    sha256: str
    modified_ms: int
    original: Original | None = None  # set for the phone's packed form (`.f32.gz`)

    @property
    def lands(self) -> tuple[PurePosixPath, int, str]:
        """Path, bytes and SHA-256 of what lands on the laptop: the plain file, also for a packed one."""
        o = self.original
        return (o.path, o.bytes, o.sha256) if o else (self.path, self.bytes, self.sha256)


def is_sha256(v: object) -> bool:
    return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)


def original_of(p: PurePosixPath, o: object) -> Original | None:
    """A file list's `original` (DECISIONS 540-549): None when absent; ValueError when it is not the plain form of
    [p] (`<path>.gz` holds `<path>`) with a size and SHA-256."""
    if o is None:
        return None
    if not isinstance(o, dict):
        raise ValueError("original is not an object")
    op = safe_path(o.get("path"))
    size, digest = o.get("bytes"), o.get("sha256")
    if str(p) != f"{op}.gz" or not op.name.endswith(packed.RAW) or not (isinstance(size, int) and size >= 0) \
            or not is_sha256(digest):
        raise ValueError(f"original of {p} is not its plain .f32")
    return Original(op, size, str(digest))


@dataclass
class Report:
    folder: Path
    dest: Path
    manifest: dict
    entries: list[Entry]
    new: list[Entry] = field(default_factory=list)
    updated: list[Entry] = field(default_factory=list)
    same: list[Entry] = field(default_factory=list)
    kept: list[Entry] = field(default_factory=list)
    damaged: list[Entry] = field(default_factory=list)
    missing: list[Entry] = field(default_factory=list)
    extra: list[str] = field(default_factory=list)
    replaced_dir: Path | None = None

    @property
    def not_exported(self) -> list[str]:
        return [p for p in self.manifest.get("not_exported") or [] if isinstance(p, str)]

    @property
    def problems(self) -> bool:
        return bool(self.damaged or self.missing or self.not_exported)


def safe_path(p: object) -> PurePosixPath:
    """A manifest path as a relative path inside the folder; anything else stops the import."""
    if not isinstance(p, str) or not p or "\\" in p or p.startswith("/"):
        raise ManifestError(f"the manifest names a path that is not inside the folder: {p!r}")
    pp = PurePosixPath(p)
    if any(part in ("", ".", "..") for part in p.split("/")) or pp.name in OWN and len(pp.parts) == 1:
        raise ManifestError(f"the manifest names a path that is not inside the folder: {p}")
    return pp


def find_root(folder: Path) -> Path:
    for root in (folder, folder / FOLDER):
        if (root / "manifest.json").is_file():
            return root
    raise ManifestError(f"no manifest.json in {folder} (nor in {folder / FOLDER}): is this the phone's export folder?")


def load_manifest(root: Path) -> tuple[dict, list[Entry]]:
    try:
        m = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ManifestError(f"manifest.json cannot be read ({e}); if Syncthing is still copying, wait and run again, "
                            "else export again on the phone") from e
    if not isinstance(m, dict) or m.get("format") != FORMAT or not isinstance(m.get("files"), list):
        raise ManifestError("manifest.json is not a phone export's manifest")
    if m.get("version") != VERSION:
        raise ManifestError(f"manifest.json is version {m.get('version')}; this script reads version {VERSION}")
    entries, seen = [], set()
    for f in m["files"]:
        if not isinstance(f, dict):
            raise ManifestError("manifest.json has a damaged file entry")
        p = safe_path(f.get("path"))
        size, digest, mod = f.get("bytes"), f.get("sha256"), f.get("modified_ms")
        if not (isinstance(size, int) and size >= 0 and isinstance(mod, int) and is_sha256(digest)):
            raise ManifestError(f"manifest.json has a damaged entry for {p}")
        try:
            orig = original_of(p, f.get("original"))
        except (ValueError, ManifestError) as e:
            raise ManifestError(f"manifest.json has a damaged entry for {p} ({e})") from e
        if p in seen:
            raise ManifestError(f"manifest.json lists {p} twice")
        seen.add(p)
        entries.append(Entry(p, size, str(digest), mod, orig))
    return m, entries


RAW = ("recordings", "recordings-diy")  # the BrainBit's nights, and the DIY board's in their own folder


def target_for(dest: Path, p: PurePosixPath) -> Path:
    """Raw recordings next to the laptop's own (BrainBit and DIY board apart); the rest in the phone's own layout under
    phone/."""
    if len(p.parts) == 2 and p.parts[0] in RAW:
        return dest / p.parts[0] / p.name
    return dest.joinpath("phone", *p.parts)


def hash_file(f: Path) -> str:
    h = hashlib.sha256()
    with f.open("rb") as r:
        while b := r.read(CHUNK):
            h.update(b)
    return h.hexdigest()


def on_laptop(f: Path) -> Path | None:
    """The laptop's copy of [f]: the file itself, or for a raw .f32 its packed form (.f32.xz) after a day."""
    return packed.on_disk(f) if f.name.endswith(packed.RAW) else (f if f.is_file() else None)


def size_of(f: Path) -> int:
    """The bytes the laptop's copy holds (a packed .f32's original length)."""
    d = on_laptop(f)
    if d is None:
        raise FileNotFoundError(str(f))
    return packed.size(f) if packed.is_packed(d) else d.stat().st_size


class Index:
    """SHA-256 of the copies on the laptop, trusted while a copy's size and modified time are unchanged. A raw .f32
    that the laptop packed after a day keeps its row under the plain name, with the original's SHA-256 (read from the
    packed file's end, or unpacked with --rehash)."""

    def __init__(self, dest: Path, rehash: bool) -> None:
        self.file = dest / "phone" / "import-index.json"
        self.rehash = rehash
        try:
            raw = json.loads(self.file.read_text(encoding="utf-8"))
            self.rows: dict[str, list] = raw if isinstance(raw, dict) else {}
        except (OSError, ValueError):
            self.rows = {}
        self.dest = dest

    def _key(self, f: Path) -> str:
        return f.relative_to(self.dest).as_posix()

    def sha(self, f: Path) -> str:
        d = on_laptop(f) or f
        st = d.stat()
        row = self.rows.get(self._key(f))
        if not self.rehash and isinstance(row, list) and len(row) == 3 and row[:2] == [st.st_size, st.st_mtime_ns]:
            return str(row[2])
        if packed.is_packed(d):
            o = None if self.rehash else packed.info(d)
            digest = o.sha256 if o and o.sha256 else packed.content_sha256(d)
        else:
            digest = hash_file(d)
        self.put(f, digest)
        return digest

    def put(self, f: Path, digest: str) -> None:
        st = (on_laptop(f) or f).stat()
        self.rows[self._key(f)] = [st.st_size, st.st_mtime_ns, digest]

    def save(self) -> None:
        self.file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.file.with_name(self.file.name + ".tmp")
        tmp.write_text(json.dumps(self.rows, sort_keys=True), encoding="utf-8")
        os.replace(tmp, self.file)


def copy_checked(src: Path, tmp: Path | None, e: Entry) -> bool:
    """Copies [src] to [tmp] (or only reads it when tmp is None) and checks size and SHA-256 against the manifest."""
    h, n = hashlib.sha256(), 0
    out = None
    try:
        if tmp is not None:
            tmp.parent.mkdir(parents=True, exist_ok=True)
            out = tmp.open("wb")
        with src.open("rb") as r:
            while b := r.read(CHUNK):
                h.update(b)
                n += len(b)
                if out:
                    out.write(b)
        if out:
            out.flush()
            os.fsync(out.fileno())
    finally:
        if out:
            out.close()
    ok = n == e.bytes and h.hexdigest() == e.sha256
    if not ok and tmp is not None:
        tmp.unlink(missing_ok=True)
    return ok


def unpack_checked(src: Path, tmp: Path | None, e: Entry) -> bool:
    """For the phone's packed form: checks [src] against the manifest (the gzip file's size and SHA-256), unpacks it
    into [tmp] (or only checks it when tmp is None) and checks what came out against `original`."""
    assert e.original is not None
    out = None
    try:
        if tmp is not None:
            tmp.parent.mkdir(parents=True, exist_ok=True)
            out = tmp.open("wb")
        with src.open("rb") as r:
            ok = packed.gunzip_checked(r, out, packed.Original(e.bytes, e.sha256),
                                       packed.Original(e.original.bytes, e.original.sha256))
        if out:
            out.flush()
            os.fsync(out.fileno())
    finally:
        if out:
            out.close()
    if not ok and tmp is not None:
        tmp.unlink(missing_ok=True)
    return ok


def _noise(rel: PurePosixPath) -> bool:
    """Syncthing's own files, which sit in a synced folder but are not data."""
    return any(p.startswith(".st") or ".syncthing." in p or "~syncthing~" in p for p in rel.parts)


def extra_files(root: Path, listed: set[PurePosixPath]) -> list[str]:
    out = []
    for f in sorted(root.rglob("*")):
        rel = PurePosixPath(f.relative_to(root).as_posix())
        if f.is_file() and rel not in listed and str(rel) not in OWN and not _noise(rel):
            out.append(str(rel))
    return out


def _stamp(t: datetime) -> str:
    return t.strftime("%Y-%m-%d-%H%M%S")


def run(folder: Path, dest: Path, *, dry_run: bool = False, rehash: bool = False,
        now: datetime | None = None) -> Report:
    root = find_root(folder)
    manifest, entries = load_manifest(root)
    now = now or datetime.now().astimezone()
    rep = Report(root, dest, manifest, entries)
    index = Index(dest, rehash)
    replaced = dest / "phone" / "replaced" / _stamp(now)
    for e in entries:
        path, size, digest = e.lands  # a packed phone file lands unpacked, under the plain name
        dst, src = target_for(dest, path), root.joinpath(*e.path.parts)
        have = on_laptop(dst)  # the laptop's copy, plain or packed after a day
        if have is not None and size_of(dst) == size and index.sha(dst) == digest:
            rep.same.append(e)
            continue
        if have is not None and e.modified_ms <= have.stat().st_mtime_ns // 1_000_000:
            rep.kept.append(e)  # the laptop's copy is as new or newer
            continue
        if not src.is_file():
            rep.missing.append(e)
            continue
        tmp = None if dry_run else dst.with_name(dst.name + ".importing")
        if not (unpack_checked if e.original else copy_checked)(src, tmp, e):
            rep.damaged.append(e)
            continue
        if have is not None:
            rep.updated.append(e)
            rep.replaced_dir = replaced
            if not dry_run:
                old = replaced / have.relative_to(dest)
                old.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(have, old)
        else:
            rep.new.append(e)
        if tmp is not None:
            os.replace(tmp, dst)
            ns = e.modified_ms * 1_000_000
            os.utime(dst, ns=(ns, ns))
            index.put(dst, digest)
    rep.extra = extra_files(root, {e.path for e in entries})
    if not dry_run:
        _record(rep, root, dest, now)
        index.save()
    return rep


def _record(rep: Report, root: Path, dest: Path, now: datetime) -> None:
    """Keeps the manifest and a line about this import under phone/."""
    phone = dest / "phone"
    (phone / "manifests").mkdir(parents=True, exist_ok=True)
    try:
        stamp = _stamp(datetime.fromisoformat(str(rep.manifest.get("exported"))))
    except ValueError:
        stamp = _stamp(now)
    body = (root / "manifest.json").read_bytes()
    target, n = phone / "manifests" / f"{stamp}.manifest.json", 1
    while target.exists() and target.read_bytes() != body:
        n += 1
        target = phone / "manifests" / f"{stamp}-{n}.manifest.json"
    target.write_bytes(body)
    line = dict(imported=now.isoformat(timespec="seconds"), folder=str(root), exported=rep.manifest.get("exported"),
                listed=len(rep.entries), new=len(rep.new), updated=len(rep.updated), same=len(rep.same),
                kept=len(rep.kept), damaged=len(rep.damaged), missing=len(rep.missing),
                not_exported=len(rep.not_exported))
    with (phone / "imports.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(line) + "\n")


def _mb(n: int) -> str:
    return f"{n / 1e6:.1f} MB" if n < 1e10 else f"{n / 1e9:.1f} GB"


def _names(items: list) -> str:
    names = [str(getattr(x, "path", x)) for x in items]
    more = f" and {len(names) - SHOW} more" if len(names) > SHOW else ""
    return ", ".join(names[:SHOW]) + more


def _files(n: int) -> str:
    return "1 file" if n == 1 else f"{n} files"


def summary(rep: Report) -> list[str]:
    m = rep.manifest
    try:
        when = datetime.fromisoformat(str(m.get("exported"))).strftime("%a %d %b %H:%M")
    except ValueError:
        when = str(m.get("exported"))
    total = sum(e.bytes for e in rep.entries)
    state = "complete" if m.get("complete") else "stopped early"
    out = [f'Phone export of {when} ("{m.get("mode")}", {state}): {_files(len(rep.entries))}, {_mb(total)} in its list.']
    if rep.new:
        raw = {d: sum(1 for e in rep.new if target_for(rep.dest, e.path).parent == rep.dest / d) for d in RAW}
        where = ", ".join([f"{raw['recordings']} into {rep.dest.name}/recordings"]
                          + [f"{n} into {rep.dest.name}/{d}" for d, n in raw.items() if n and d != "recordings"]
                          + [f"{len(rep.new) - sum(raw.values())} into {rep.dest.name}/phone"])
        out.append(f"  {len(rep.new)} new, copied ({_mb(sum(e.bytes for e in rep.new))}): {where}")
    if rep.same:
        out.append(f"  {len(rep.same)} already here")
    if rep.updated:
        kept = rep.replaced_dir.relative_to(rep.dest.parent) if rep.replaced_dir else "-"
        out.append(f"  {len(rep.updated)} updated (the phone changed them later); the older copies are in {kept}: "
                   f"{_names(rep.updated)}")
    if rep.kept:
        out.append(f"  {len(rep.kept)} left alone: the laptop's copy is as new or newer: {_names(rep.kept)}")
    if rep.extra:
        out.append(f"  {_files(len(rep.extra))} in the folder {'is' if len(rep.extra) == 1 else 'are'} not in the list "
                   f"(left alone): {_names(rep.extra)}")
    if rep.damaged:
        out.append(f"PROBLEM: {len(rep.damaged)} damaged or still syncing, not copied: {_names(rep.damaged)}. Wait for "
                   "Syncthing to finish (or export everything again on the phone), then run this again.")
    if rep.missing:
        out.append(f"PROBLEM: {len(rep.missing)} missing, neither in this folder nor on the laptop: "
                   f"{_names(rep.missing)}. On the phone: Export data, then Export everything.")
    if rep.not_exported:
        n = len(rep.not_exported)
        verb = "was" if n == 1 else "were"
        out.append(f"PROBLEM: {_files(n)} on the phone {verb} not exported yet (the export stopped early): "
                   f"{_names(rep.not_exported)}. On the phone: Export data again.")
    if not rep.problems:
        out.append("Everything in the phone's list is on the laptop.")
    return out


def main(argv: list[str] | None = None, out: Callable[[str], object] = print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("folder", type=Path, help="the phone's eeg-export folder, or the folder that holds it")
    ap.add_argument("--dest", type=Path, default=DEFAULT_DEST, help="where to copy (default: <repo>/_local)")
    ap.add_argument("--dry-run", action="store_true", help="check and say what would happen; copy nothing")
    ap.add_argument("--rehash", action="store_true", help="read every laptop copy again instead of trusting the index")
    a = ap.parse_args(argv)
    try:
        rep = run(a.folder, a.dest, dry_run=a.dry_run, rehash=a.rehash)
    except ManifestError as e:
        out(f"Cannot import: {e}")
        return 2
    for line in summary(rep):
        out(line)
    if a.dry_run:
        out("(dry run: nothing was copied)")
    return 1 if rep.problems else 0


if __name__ == "__main__":
    sys.exit(main())
