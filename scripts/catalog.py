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

Writes <out>/catalog.json (the table and every file's size, time and SHA-256), <out>/<date>.sha256 per night
(`sha256sum -c` format, paths from <local>), <out>/catalog.txt (the summary it prints), and appends what changed to
<out>/history.log. A run hashes only the files whose size or time changed since the last catalog; --check re-hashes
every file, reports damage and writes nothing.

Raw files (.f32 .idx .log .markers.jsonl: the recorders only ever append to them) that got longer with their earlier
bytes intact "grew"; any other change to one is a PROBLEM, as are a file whose bytes changed under the same size and
time ("damaged", --check) and a raw file gone ("missing", said on every run until it is back). Reports, charts and
BDFs are rebuilt by the scripts, so a new copy of one is only "rebuilt". Exit status 1 when there is a PROBLEM.
Read-only on the data: it never deletes, moves or compresses a recording or a report. Standard library only.
"""
from __future__ import annotations

import argparse, hashlib, json, os, sys
from datetime import datetime
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import night_files as nf  # noqa: E402

FORMAT, VERSION = "eeg-tracker-catalog", 1
RAW = (".f32", ".idx", ".log", ".markers.jsonl")
LAPTOP_REPORT = (".report.json", ".sleep.json", ".hypnogram.png", ".bdf")  # scripts/sleep_report.py's files
MORNING_WITHIN_S = 12 * 3600
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
                names.add(p.split("/", 1)[1])
    return names


def _numbers(rep: dict | None, by: str) -> dict | None:
    t = rep.get("total") if rep else None
    if not isinstance(t, dict):
        return None
    return dict(by=by, **{k: t.get(k) for k in ("asleep_min", "deep_min", "dream_min")})


def _row(date: str, start: float | None, end: float | None) -> dict:
    return dict(date=date, source="", recordings=0, start=start, end=end, hours_recorded=0.0, minutes_missing=0.0,
                raw=False, report=None, morning=[], paths=[])


def _add(local: Path, row: dict, rel: str, kind: str) -> None:
    if (local / rel).is_file():
        row["paths"].append((rel, kind))


def _recording_nights(local: Path, phone: set[str]) -> dict[str, dict]:
    """The nights in recordings/ by night_files.py's chain rule, each with its runs' files: the raw ones and anything
    else made from one run alone (a hand-made BDF). Runs without samples join the night they fall in."""
    rows: dict[str, dict] = {}
    stems: dict[str, list[str]] = {}
    for n in nf.nights(nf.recordings(local / "recordings")):
        row = _row(n.name, n.start, n.end)
        samples_s = sum(r.size // nf.REC_BYTES for r in n.recs) / nf.FS
        row.update(recordings=len(n.recs), raw=True, hours_recorded=round(samples_s / 3600, 2),
                   minutes_missing=round(max(0.0, n.end - n.start - samples_s) / 60, 1),
                   source="+".join(sorted({"phone" if r.path.name in phone else "laptop" for r in n.recs})))
        rows[n.name], stems[n.name] = row, [r.path.stem for r in n.recs]
    for p in (local / "recordings").glob("*.f32"):
        t = nf.stamp_time(p)
        if t is not None and p.stat().st_size < nf.REC_BYTES:
            near = [d for d, r in rows.items() if r["start"] <= t < r["end"] + nf.CHAIN_GAP_S]
            if near:
                stems[max(near)].append(p.stem)
    for date, names in stems.items():
        for stem in names:
            for f in sorted((local / "recordings").glob(f"{stem}.*")):
                if f.is_file() and not f.name.endswith(".morning.json"):
                    rows[date]["paths"].append((f"recordings/{f.name}", "raw" if f.name.endswith(RAW) else "derived"))
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
    return out


def _attach_mornings(local: Path, rows: list[dict]) -> None:
    """A check-in belongs to the night recorded in its `source` file, else to the last night that started before it
    and ended at most 12 hours before it. The phone's keep their raw signal beside them in phone/mornings/."""
    by_file = {Path(rel).name: row for row in rows for rel, kind in row["paths"] if rel.endswith(".f32")}
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


def digest(path: Path, size: int, prefix: int | None = None) -> tuple[str, str | None]:
    """SHA-256 of the file's first `size` bytes (a recording may grow while it is read) and, when asked, of its
    first `prefix` bytes, in one read."""
    h, pre, done = hashlib.sha256(), None, 0
    if prefix == 0:
        pre = h.hexdigest()
    with open(path, "rb") as f:
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


PROBLEMS = ("damaged", "changed", "missing")


def build(local: Path, previous: dict | None, check: bool, now: datetime) -> tuple[dict, list[tuple[str, str, str]]]:
    """The new catalog and the events since `previous`: (what, path, night)."""
    old = {f["path"]: f for n in (previous or {}).get("nights", []) for f in n.get("file_list", [])}
    gone = {f["path"]: f for f in (previous or {}).get("missing", [])}
    events: list[tuple[str, str, str]] = []
    rows = nights_on(local)
    for row in rows:
        files = []
        for rel, kind in sorted(set(row.pop("paths"))):
            p = local / rel
            st = p.stat()
            sha, what = _compare(p, kind, st, old.get(rel), gone.get(rel), check)
            if what:
                events.append((what, rel, row["date"]))
            files.append(dict(path=rel, bytes=st.st_size, mtime_ns=st.st_mtime_ns, sha256=sha, kind=kind))
        row.update(files=len(files), bytes=sum(f["bytes"] for f in files), file_list=files,
                   start=_iso(row["start"]), end=_iso(row["end"]))
    listed = {f["path"] for r in rows for f in r["file_list"]}
    before = dict(gone)  # raw files already missing last time, then everything the last catalog listed
    for n in (previous or {}).get("nights", []):
        for f in n.get("file_list", []):
            before.setdefault(f["path"], dict(f, night=n["date"]))
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
    """Files in recordings/, nights/ and phone/ that belong to no night (logs, hand-made files, meditations...)."""
    listed = {f["path"] for n in cat["nights"] for f in n["file_list"]}
    found = []
    for top in ("recordings", "nights", "phone"):
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
        if what != "new":
            out.append(f"{'PROBLEM: ' if what in PROBLEMS else ''}{what}: {path} (night {night})")
    return out


def _write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def save(cat: dict, out: Path, summary: list[str], events: list[tuple[str, str, str]]) -> None:
    """catalog.json, catalog.txt, one <date>.sha256 per night (and its missing raw files), a line in history.log."""
    out.mkdir(parents=True, exist_ok=True)
    _write(out / "catalog.json", json.dumps(cat, indent=1) + "\n")
    _write(out / "catalog.txt", "\n".join(summary) + "\n")
    per: dict[str, list[dict]] = {n["date"]: list(n["file_list"]) for n in cat["nights"]}
    for f in cat["missing"]:
        per.setdefault(f.get("night", "missing"), []).append(f)
    for date, files in per.items():
        _write(out / f"{date}.sha256", "".join(f"{f['sha256']}  {f['path']}\n" for f in sorted(files, key=lambda f: f["path"])))
    for p in out.glob("*.sha256"):  # the sidecars are this script's own output, rewritten every run
        if p.name[:-len(".sha256")] not in per:
            p.unlink()
    with open(out / "history.log", "a", encoding="utf-8") as h:
        h.write(f"{cat['made']} {len(cat['nights'])} nights, {sum(n['files'] for n in cat['nights'])} files, "
                f"{sum(1 for e in events if e[0] == 'new')} new" + "".join(
                    f"\n  {'PROBLEM: ' if what in PROBLEMS else ''}{what}: {path} (night {night})"
                    for what, path, night in events if what != "new") + "\n")


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
