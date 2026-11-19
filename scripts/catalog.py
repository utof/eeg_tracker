"""A catalog of every night on the laptop: one table, and the SHA-256 of every file so later runs notice damage.

usage: catalog.py [--local _local] [--out <local>/catalog] [--check]

Nights come from <local>/recordings/ (the laptop's own recordings and the phone's raw nights that
scripts/import_phone.py copied in), cut by night_files.py's chain rule and named by the evening date, and from the
phone's sleep reports in <local>/phone/nights/ (a night whose raw signal was never exported is listed from its
report alone). Per night: source (laptop, phone, or laptop+phone, by the import manifests in <local>/phone/manifests/),
files and bytes, hours recorded (samples at 250 Hz), minutes missing (time between the first and the last data with
no samples: drops and restarts), the sleep report (the laptop's <local>/nights/<date>.report.json, else the phone's)
with its asleep, deep and dream minutes, and the morning check-in (a <start>.morning.json recorded inside the night
or starting within 12 hours after it).

The DIY board's recordings (<local>/recordings-diy/, DECISIONS 381: scripts/record_diy.py) are nights of their
own, source "diy", cut by the same chain rule and never mixed into a BrainBit night of the same evening (a DIY row has
`id` <date>-diy and the sidecar <date>-diy.sha256). Their records are as wide as the board's channels and their rate is
the board's: both are read from the file's .log ("format .f32 records <I4f ...; 250 Hz"; without that line, 4 channels
at 250 Hz). They have no sleep report and no check-in.

Writes <out>/catalog.json (the table and every file's size, time and SHA-256), <out>/<date>.sha256 per night
(`sha256sum -c` format, paths from <local>), <out>/catalog.txt (the summary it prints), and appends what changed to
<out>/history.log. A run hashes only the files whose size or time changed since the last catalog; --check re-hashes
every file, reports damage and writes nothing.

Raw files (.f32 .idx .log .markers.jsonl: the recorders only ever append to them) that got longer with their earlier
bytes intact "grew"; any other change to one is a PROBLEM, as are a file whose bytes changed under the same size and
time ("damaged", --check) and a raw file gone ("missing", said on every run until it is back). Reports, charts and
BDFs are rebuilt by the scripts, so a new copy of one is only "rebuilt". Exit status 1 when there is a PROBLEM.

A raw .f32 packed after a day (<stamp>.f32.xz, scripts/pack_old.py and packed.py) is listed under its own name with
its own size and SHA-256 (so `sha256sum -c` of the sidecar still works) and, in catalog.json, `original`: the path,
bytes and SHA-256 of the .f32 it holds, read from the xz file's end. A .f32 that became a .f32.xz holding the same
bytes is "packed", not missing; holding other bytes it is a PROBLEM ("changed"). --check unpacks every packed file
and compares what comes out with `original` ("damaged" when it differs or does not unpack).
Read-only on the data: it never deletes, moves or packs a recording or a report. Standard library only.
"""
from __future__ import annotations

import argparse, hashlib, json, lzma, os, re, sys, zlib
from datetime import datetime
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import night_files as nf  # noqa: E402
import packed  # noqa: E402

FORMAT, VERSION = "eeg-tracker-catalog", 1
RAW = (".f32", *packed.PACKED_FORMS, ".idx", ".log", ".markers.jsonl")
LAPTOP_REPORT = (".report.json", ".sleep.json", ".hypnogram.png", ".bdf")  # scripts/sleep_report.py's files
MORNING_WITHIN_S = 12 * 3600
DIY = "recordings-diy"
DIY_FORMAT = re.compile(r"format \.f32 records <I(\d+)f\b.*?; (\d+(?:\.\d+)?) Hz")
CHUNK = 1 << 20
SHOW = 5  # names listed before "and N more"
DEFAULT_LOCAL = Path(__file__).resolve().parents[1] / "_local"


def _json(p: Path) -> dict | None:
    try:
        d = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def _time(iso: object) -> float | None:
    try:
        return datetime.fromisoformat(str(iso)).timestamp()
    except ValueError:
        return None


def _iso(t: float | None) -> str | None:
    return None if t is None else datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def phone_recordings(local: Path) -> set[str]:
    """File names of the raw nights the phone exported (every manifest ever imported lists them)."""
    names: set[str] = set()
    for m in sorted((local / "phone" / "manifests").glob("*.json")):
        for f in (_json(m) or {}).get("files") or []:
            p = f.get("path") if isinstance(f, dict) else None
            if isinstance(p, str) and p.startswith("recordings/") and p.count("/") == 1:
                names.add(p.split("/", 1)[1].removesuffix(".gz"))  # the phone's packed form names its .f32
    return names


def _numbers(rep: dict | None, by: str) -> dict | None:
    t = rep.get("total") if rep else None
    if not isinstance(t, dict):
        return None
    return dict(by=by, **{k: t.get(k) for k in ("asleep_min", "deep_min", "dream_min")})


def _row(date: str, start: float | None, end: float | None) -> dict:
    return dict(date=date, id=date, source="", recordings=0, start=start, end=end, hours_recorded=0.0, minutes_missing=0.0,
                raw=False, report=None, morning=[], paths=[])


def _add(local: Path, row: dict, rel: str, kind: str) -> None:
    if (local / rel).is_file():
        row["paths"].append((rel, kind))


def diy_format(log: Path) -> tuple[int, float]:
    """(bytes of one record, samples a second) of a DIY file set, from its .log's format line."""
    try:
        m = DIY_FORMAT.search(log.read_text(errors="replace"))
    except OSError:
        m = None
    return (4 + 4 * int(m.group(1)), float(m.group(2))) if m else (nf.REC_BYTES, float(nf.FS))


def _recording_nights(local: Path, phone: set[str], folder: str = "recordings", diy: bool = False) -> dict[str, dict]:
    """The nights in <folder>/ by night_files.py's chain rule, each with its runs' files: the raw ones and anything
    else made from one run alone (a hand-made BDF). Runs without samples join the night they fall in. For the DIY
    board's folder (`diy`) the row's id carries "-diy" and a run's seconds come from its own record width and rate."""
    rows: dict[str, dict] = {}
    stems: dict[str, list[str]] = {}
    where = local / folder

    def seconds(r: nf.Rec) -> float:
        width, fs = diy_format(r.path.with_suffix(".log")) if diy else (nf.REC_BYTES, nf.FS)
        return r.size // width / fs

    for n in nf.nights(nf.recordings(where)):
        row = _row(n.name, n.start, n.end)
        samples_s = sum(seconds(r) for r in n.recs)
        source = "diy" if diy else "+".join(sorted({"phone" if r.path.name in phone else "laptop" for r in n.recs}))
        row.update(recordings=len(n.recs), raw=True, hours_recorded=round(samples_s / 3600, 2),
                   minutes_missing=round(max(0.0, n.end - n.start - samples_s) / 60, 1), source=source)
        key = n.name + "-diy" if diy else n.name
        row["id"] = key
        rows[key], stems[key] = row, [r.path.stem for r in n.recs]
    for p in packed.raw_files(where):
        t = nf.stamp_time(p)
        try:
            empty = packed.size(p) < nf.REC_BYTES
        except OSError:  # a packed file whose end cannot be read: unreadable() names it
            continue
        if t is not None and empty:
            near = [d for d, r in rows.items() if r["start"] <= t < r["end"] + nf.CHAIN_GAP_S]
            if near:
                stems[max(near)].append(p.stem)
    for key, names in stems.items():
        for stem in names:
            for f in sorted(where.glob(f"{stem}.*")):
                if f.is_file() and not f.name.endswith(".morning.json"):
                    rows[key]["paths"].append((f"{folder}/{f.name}", "raw" if f.name.endswith(RAW) else "derived"))
    return rows


def _add_phone_reports(local: Path, rows: dict[str, dict]) -> None:
    """The phone's sleep reports; a night whose raw signal is not on the laptop gets a row from its report alone."""
    for p in sorted((local / "phone" / "nights").glob("*.report.json")):
        date = p.name[:-len(".report.json")]
        if not nf.DATE.match(date):
            continue
        rep = _json(p) or {}
        if date not in rows:
            row = rows[date] = _row(date, _time(rep.get("data_start")), _time(rep.get("data_end")))
            t = rep.get("total") if isinstance(rep.get("total"), dict) else {}
            row.update(source="phone", hours_recorded=round(float(t.get("recorded_min") or 0) / 60, 2),
                       minutes_missing=float(t.get("missing_min") or 0))
        rows[date]["report"] = _numbers(rep, "phone")
        _add(local, rows[date], f"phone/nights/{p.name}", "derived")


def unreadable(local: Path) -> list[str]:
    """Packed raw files whose length cannot be read (their end is damaged): no night can take them, so they are named
    as damaged on every run."""
    out = []
    for folder in ("recordings", DIY, "phone/mornings"):
        for p in packed.raw_files(local / folder):
            d = packed.on_disk(p)
            if d is not None and packed.is_packed(d):
                try:
                    packed.size(d)
                except OSError:
                    out.append(d.relative_to(local).as_posix())
    return out


def nights_on(local: Path) -> list[dict]:
    """One row per night, oldest first, with the files that belong to it as (path from local, raw | derived)."""
    rows = _recording_nights(local, phone_recordings(local))
    _add_phone_reports(local, rows)
    for date, row in rows.items():  # the laptop's report comes first when both made one
        row["report"] = _numbers(_json(local / "nights" / f"{date}.report.json"), "laptop") or row["report"]
        for suffix in LAPTOP_REPORT:
            _add(local, row, f"nights/{date}{suffix}", "derived")
    out = [rows[d] for d in sorted(rows)]
    _attach_mornings(local, out)
    diy = _recording_nights(local, set(), DIY, diy=True)
    return sorted(out + list(diy.values()), key=lambda r: (r["date"], r["source"] == "diy"))


def _attach_mornings(local: Path, rows: list[dict]) -> None:
    """A check-in belongs to the night recorded in its `source` file, else to the last night that started before it
    and ended at most 12 hours before it. The phone's keep their raw signal beside them in phone/mornings/."""
    by_file = {packed.logical(Path(rel)).name: row for row in rows for rel, kind in row["paths"]
               if rel.endswith((packed.RAW, *packed.PACKED_FORMS))}
    found = [(p, f"recordings/{p.name}") for p in sorted((local / "recordings").glob("*.morning.json"))]
    found += [(p, f"phone/mornings/{p.name}") for p in sorted((local / "phone" / "mornings").glob("*.morning.json"))]
    for p, rel in found:
        m = _json(p) or {}
        src, t = str(m.get("source") or ""), _time(m.get("start"))
        row = by_file.get(src) if rel.startswith("recordings/") else None
        if row is None and t is not None:
            near = [r for r in rows if r["start"] is not None and r["end"] is not None
                    and r["start"] <= t <= r["end"] + MORNING_WITHIN_S]
            row = near[-1] if near else None
        if row is None:
            continue
        row["morning"].append(rel)
        row["paths"].append((rel, "derived"))
        if rel.startswith("phone/") and src.endswith(".f32"):
            for suffix in RAW:
                _add(local, row, f"phone/mornings/{src[:-4]}{suffix}", "raw")


def digest(path: Path, size: int, prefix: int | None = None, unpack: bool = False) -> tuple[str, str | None]:
    """SHA-256 of the file's first `size` bytes (a recording may grow while it is read) and, when asked, of its
    first `prefix` bytes, in one read. With [unpack], of a packed file's original bytes."""
    h, pre, done = hashlib.sha256(), None, 0
    if prefix == 0:
        pre = h.hexdigest()
    with (packed.open_raw(path) if unpack else open(path, "rb")) as f:
        while done < size:
            want = min(CHUNK, size - done)
            if prefix is not None and done < prefix < done + want:
                want = prefix - done
            b = f.read(want)
            if not b:
                break
            h.update(b)
            done += len(b)
            if done == prefix:
                pre = h.hexdigest()
    return h.hexdigest(), pre


def _compare(path: Path, kind: str, st: os.stat_result, prev: dict | None, gone: dict | None,
             check: bool) -> tuple[str, str | None]:
    """The file's SHA-256 and what happened to it since the last catalog (None: nothing)."""
    if prev and not check and prev["bytes"] == st.st_size and prev["mtime_ns"] == st.st_mtime_ns:
        return prev["sha256"], None
    old = prev or gone
    prefix = old["bytes"] if old and kind == "raw" and st.st_size >= old["bytes"] else None
    sha, pre = digest(path, st.st_size, prefix)
    if old is None:
        return sha, "new"
    if sha == old["sha256"]:
        return sha, "back" if prev is None else None
    if prev and prev["bytes"] == st.st_size and prev["mtime_ns"] == st.st_mtime_ns:
        return sha, "damaged"
    if kind == "raw":
        return sha, "grew" if pre == old["sha256"] and prev else "changed"
    return sha, "rebuilt"


def _content(f: dict | None) -> tuple[int, str] | None:
    """(bytes, SHA-256) of what a catalog file row holds: for a packed file, its original's."""
    if f is None:
        return None
    o = f.get("original")
    return (o["bytes"], o["sha256"]) if isinstance(o, dict) else (f["bytes"], f["sha256"])


def _twin(rel: str) -> str | None:
    """The other form of a raw .f32's path: packed for plain, plain for packed."""
    if rel.endswith(packed.PACKED_FORMS):
        return rel[:-3]
    return rel + packed.SUFFIX if rel.endswith(packed.RAW) else None


def _compare_packed(path: Path, rel: str, st: os.stat_result, prev: dict | None, gone: dict | None,
                    check: bool) -> tuple[str, dict | None, str | None]:
    """A packed raw file's own SHA-256, what it holds (`original`: path, bytes, SHA-256 of the .f32) and what happened
    to it since the last catalog. With [check] it is unpacked whole and what comes out is hashed."""
    if prev and not check and prev["bytes"] == st.st_size and prev["mtime_ns"] == st.st_mtime_ns \
            and isinstance(prev.get("original"), dict):
        return prev["sha256"], prev["original"], None
    sha, _ = digest(path, st.st_size)
    try:
        o = packed.unpacked(path) if check else packed.info(path)
        if o.sha256 is None:  # not packed by pack_old.py: its check is not a SHA-256
            o = packed.unpacked(path)
    except (OSError, lzma.LZMAError, zlib.error, EOFError):
        return sha, (prev or {}).get("original"), "damaged"
    original = dict(path=rel[:-3], bytes=o.bytes, sha256=o.sha256)
    old = prev or gone
    if old is None:
        return sha, original, "new"
    if _content(old) == (o.bytes, o.sha256):
        return sha, original, "back" if prev is None else None
    if prev and prev["bytes"] == st.st_size and prev["mtime_ns"] == st.st_mtime_ns:
        return sha, original, "damaged"
    return sha, original, "changed"


def _form_changed(path: Path, rel: str, twin: dict, content: tuple[int, str]) -> str:
    """A raw .f32 that was plain at the last catalog and is packed now (or the other way round): "packed" or
    "unpacked" when it holds the same bytes, "grew" when the earlier bytes are its start, else "changed"."""
    if _content(twin) == content:
        return "packed" if rel.endswith(packed.PACKED_FORMS) else "unpacked"
    before = _content(twin)
    if before and before[0] <= content[0]:
        _, pre = digest(path, content[0], before[0], unpack=rel.endswith(packed.PACKED_FORMS))
        if pre == before[1]:
            return "grew"
    return "changed"


PROBLEMS = ("damaged", "changed", "missing")
QUIET = ("new", "packed")  # counted, not listed one by one


def build(local: Path, previous: dict | None, check: bool, now: datetime) -> tuple[dict, list[tuple[str, str, str]]]:
    """The new catalog and the events since `previous`: (what, path, night)."""
    old = {f["path"]: f for n in (previous or {}).get("nights", []) for f in n.get("file_list", [])}
    gone = {f["path"]: f for f in (previous or {}).get("missing", [])}
    events: list[tuple[str, str, str]] = []
    rows = nights_on(local)
    events += [("damaged", rel, "?") for rel in unreadable(local)]
    for row in rows:
        files = []
        for rel, kind in sorted(set(row.pop("paths"))):
            p = local / rel
            st = p.stat()
            original = None
            if kind == "raw" and rel.endswith(packed.PACKED_FORMS):
                sha, original, what = _compare_packed(p, rel, st, old.get(rel), gone.get(rel), check)
            else:
                sha, what = _compare(p, kind, st, old.get(rel), gone.get(rel), check)
            twin = old.get(_twin(rel) or "") or gone.get(_twin(rel) or "") if kind == "raw" else None
            if what in ("new", "back") and twin is not None:
                content = (original["bytes"], original["sha256"]) if original else (st.st_size, sha)
                what = _form_changed(p, rel, twin, content)
            if what:
                events.append((what, rel, row["id"]))
            f = dict(path=rel, bytes=st.st_size, mtime_ns=st.st_mtime_ns, sha256=sha, kind=kind)
            if original:
                f["original"] = original
            files.append(f)
        row.update(files=len(files), bytes=sum(f["bytes"] for f in files), file_list=files,
                   start=_iso(row["start"]), end=_iso(row["end"]))
    listed = {f["path"] for r in rows for f in r["file_list"]}
    listed |= {t for p in list(listed) if (t := _twin(p)) and (local / p).exists()}  # either form of a raw .f32
    before = dict(gone)  # raw files already missing last time, then everything the last catalog listed
    for n in (previous or {}).get("nights", []):
        for f in n.get("file_list", []):
            before.setdefault(f["path"], dict(f, night=n.get("id", n["date"])))
    missing = []
    for path, f in sorted(before.items()):
        if path in listed or (local / path).exists():
            continue  # still here (a file that left every night is counted under "not in any night")
        if f.get("kind") == "raw":
            missing.append(dict(f, since=f.get("since") or now.isoformat(timespec="seconds")))
            events.append(("missing", path, f.get("night", "?")))
        else:  # a report or chart the scripts can make again: said once
            events.append(("removed", path, f.get("night", "?")))
    cat = dict(format=FORMAT, version=VERSION, made=now.isoformat(timespec="seconds"), local=str(local.resolve()),
               nights=rows, missing=missing)
    return cat, events


def other_files(local: Path, cat: dict, out: Path) -> list[Path]:
    """Files in recordings/, recordings-diy/, nights/ and phone/ that belong to no night (logs, hand-made files, meditations...)."""
    listed = {f["path"] for n in cat["nights"] for f in n["file_list"]}
    found = []
    for top in ("recordings", "nights", "phone", DIY):
        for p in sorted((local / top).rglob("*")):
            if p.is_file() and str(p.relative_to(local)) not in listed and out not in p.resolve().parents:
                found.append(p)
    return found


def _names(items: list[str]) -> str:
    more = f" and {len(items) - SHOW} more" if len(items) > SHOW else ""
    return ", ".join(items[:SHOW]) + more


def _num(v: object) -> str:
    return f"{v:.0f}" if isinstance(v, (int, float)) else "-"


def table(cat: dict, local: Path, others: list[Path]) -> list[str]:
    rows = cat["nights"]
    total_b = sum(n["bytes"] for n in rows)
    out = [f"Nights on this laptop ({local}, {cat['made'][:16].replace('T', ' ')}): {len(rows)} night"
           f"{'' if len(rows) == 1 else 's'}, {sum(n['files'] for n in rows)} files, {total_b / 1e6:.1f} MB",
           f"{'date':<11} {'source':<12} {'files':>5} {'MB':>7} {'recorded':>8} {'missing':>8}  {'report':<7}"
           f"{'asleep':>6} {'deep':>5} {'dream':>5}  check-in"]
    for n in rows:
        r = n["report"] or {}
        note = "" if n["raw"] else "  (report only: the raw night is not on the laptop)"
        out.append(f"{n['date']:<11} {n['source']:<12} {n['files']:>5} {n['bytes'] / 1e6:>7.1f} "
                   f"{n['hours_recorded']:>6.1f} h {n['minutes_missing']:>4.0f} min  {r.get('by', 'none'):<7}"
                   f"{_num(r.get('asleep_min')):>6} {_num(r.get('deep_min')):>5} {_num(r.get('dream_min')):>5}  "
                   f"{'yes' if n['morning'] else 'no'}{note}")
    out.append(f"not in any night: {len(others)} files, {sum(p.stat().st_size for p in others) / 1e6:.1f} MB"
               + (f" ({_names([str(p.relative_to(local)) for p in others])})" if others else ""))
    packs = [f for n in rows for f in n["file_list"] if isinstance(f.get("original"), dict)]
    if packs:
        out.append(f"packed after a day (scripts/pack_old.py): {len(packs)} raw files, "
                   f"{sum(f['bytes'] for f in packs) / 1e6:.1f} MB on disk for "
                   f"{sum(f['original']['bytes'] for f in packs) / 1e6:.1f} MB of signal")
    return out


def changes(events: list[tuple[str, str, str]], previous: dict | None, check: bool) -> list[str]:
    if previous is None:
        return ["first catalog: every file hashed"]
    head = "re-hashed every file against" if check else "since"
    counts: dict[str, int] = {}
    for what, _, _ in events:
        counts[what] = counts.get(what, 0) + 1
    out = [f"{head} the last catalog ({previous.get('made', '?')}): "
           + (", ".join(f"{v} {k}" for k, v in sorted(counts.items())) or "nothing changed")]
    for what, path, night in events:
        if what not in QUIET:
            out.append(f"{'PROBLEM: ' if what in PROBLEMS else ''}{what}: {path} (night {night})")
    return out


def _write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def save(cat: dict, out: Path, summary: list[str], events: list[tuple[str, str, str]]) -> None:
    """catalog.json, catalog.txt, one <id>.sha256 per night (and its missing raw files), a line in history.log."""
    out.mkdir(parents=True, exist_ok=True)
    _write(out / "catalog.json", json.dumps(cat, indent=1) + "\n")
    _write(out / "catalog.txt", "\n".join(summary) + "\n")
    per: dict[str, list[dict]] = {n["id"]: list(n["file_list"]) for n in cat["nights"]}
    for f in cat["missing"]:
        per.setdefault(f.get("night", "missing"), []).append(f)
    for date, files in per.items():
        _write(out / f"{date}.sha256", "".join(f"{f['sha256']}  {f['path']}\n" for f in sorted(files, key=lambda f: f["path"])))
    for p in out.glob("*.sha256"):  # the sidecars are this script's own output, rewritten every run
        if p.name[:-len(".sha256")] not in per:
            p.unlink()
    with open(out / "history.log", "a", encoding="utf-8") as h:
        packs = sum(1 for e in events if e[0] == "packed")
        h.write(f"{cat['made']} {len(cat['nights'])} nights, {sum(n['files'] for n in cat['nights'])} files, "
                f"{sum(1 for e in events if e[0] == 'new')} new" + (f", {packs} packed" if packs else "") + "".join(
                    f"\n  {'PROBLEM: ' if what in PROBLEMS else ''}{what}: {path} (night {night})"
                    for what, path, night in events if what not in QUIET) + "\n")


def main(argv: list[str] | None = None, out: Callable[[str], object] = print) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--local", type=Path, default=DEFAULT_LOCAL, help="the data folder (default: the repo's _local)")
    ap.add_argument("--out", type=Path, help="where the catalog goes (default: <local>/catalog)")
    ap.add_argument("--check", action="store_true", help="re-hash every file against the last catalog; write nothing")
    a = ap.parse_args(argv)
    local = a.local.resolve()
    dest = (a.out or local / "catalog").resolve()
    previous = _json(dest / "catalog.json")
    if a.check and previous is None:
        out(f"no catalog in {dest} to check against: run scripts/catalog.py first")
        return 2
    cat, events = build(local, previous, a.check, datetime.now().astimezone())
    others = other_files(local, cat, dest.resolve())
    summary = table(cat, local, others) + changes(events, previous, a.check)
    summary.append(f"SHA-256 of every file: {dest}/<date>.sha256 (scripts/catalog.py --check re-hashes them)")
    for line in summary:
        out(line)
    if not a.check:
        save(cat, dest, summary, events)
    return 1 if any(what in PROBLEMS for what, _, _ in events) else 0


if __name__ == "__main__":
    sys.exit(main())
