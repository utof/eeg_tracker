"""scripts/catalog.py: one table of every night on the laptop, SHA-256 of every file, and what changed since.

A fake _local folder: two laptop recordings make the night of 2026-11-16 (with its sleep report and a morning
check-in recorded inside it), a phone recording the night of 2026-11-17 (phone report, phone check-in), and a phone
report alone the night of 2026-11-20 (its raw night was not exported).
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import catalog  # noqa: E402

FS, REC = 250, 20


def stamp(t: datetime) -> str:
    return t.strftime("%Y-%m-%d-%H%M%S")


def write_rec(folder: Path, start: datetime, minutes: float, *, markers: bool = False) -> str:
    """<stamp>.f32 (zeros), .idx (one batch a minute, the last at the end) and .log, like record_night.py's."""
    folder.mkdir(parents=True, exist_ok=True)
    n = int(minutes * 60 * FS)
    s = stamp(start)
    (folder / f"{s}.f32").write_bytes(b"\0" * n * REC)
    rows = [(start.timestamp() + 60 * (k + 1), k * 60 * FS) for k in range(int(minutes))]
    (folder / f"{s}.idx").write_bytes(b"".join(struct.pack("<dQ", t, i) for t, i in rows))
    (folder / f"{s}.log").write_text("connected\n")
    if markers:
        (folder / f"{s}.markers.jsonl").write_text(json.dumps(dict(t=start.timestamp() + 5, i=0, text="lights off")) + "\n")
    return s


def report(asleep: float, deep: float, dream: float, recorded: float = 150.0, missing: float = 30.0, **kw) -> str:
    return json.dumps(dict(version=2, scored=True, total=dict(asleep_min=asleep, deep_min=deep, dream_min=dream,
                                                              light_min=asleep - deep - dream, recorded_min=recorded,
                                                              missing_min=missing), **kw))


A1, A2 = datetime(2026, 11, 16, 23, 0, 0), datetime(2026, 11, 17, 0, 30, 0)
B1 = datetime(2026, 11, 17, 23, 10, 0)
MORNING_B = datetime(2026, 11, 18, 6, 58, 0)


@pytest.fixture
def local(tmp_path: Path) -> Path:
    loc = tmp_path / "_local"
    rec, nights, phone = loc / "recordings", loc / "nights", loc / "phone"
    a1 = write_rec(rec, A1, 60, markers=True)
    (rec / f"{a1}.bdf").write_bytes(b"BDF")  # made by hand from one recording
    empty = stamp(A1 + timedelta(minutes=61))  # a recorder run that got no samples: its log says why
    for suffix, body in ((".f32", b""), (".idx", b""), (".log", b"no data after 20 s; restarting\n")):
        (rec / f"{empty}{suffix}").write_bytes(body)
    a2 = write_rec(rec, A2, 90)
    morning_a = A2 + timedelta(minutes=80)
    (rec / f"{stamp(morning_a)}.morning.json").write_text(json.dumps(dict(
        version="morning-v1", source=f"{a2}.f32", start=morning_a.astimezone().isoformat(), date="2026-11-17")))
    nights.mkdir()
    (nights / "2026-11-16.report.json").write_text(report(120.0, 20.0, 30.0))
    for suffix, body in ((".sleep.json", b"{}"), (".hypnogram.png", b"PNG"), (".bdf", b"BDF" * 100)):
        (nights / f"2026-11-16{suffix}").write_bytes(body)
    (nights / "sleep-report.log").write_text("hub starts\n")
    b1 = write_rec(rec, B1, 45)
    (phone / "nights").mkdir(parents=True)
    (phone / "nights" / "2026-11-17.report.json").write_text(report(40.0, 10.0, 5.0, 45.0, 0.0, source="phone"))
    (phone / "nights" / "2026-11-20.report.json").write_text(report(300.0, 60.0, 70.0, 420.0, 12.0, source="phone"))
    m = write_rec(phone / "mornings", MORNING_B, 5)
    (phone / "mornings" / f"{stamp(MORNING_B + timedelta(minutes=1))}.morning.json").write_text(json.dumps(dict(
        version="morning-v1", source=f"{m}.f32", app="phone",
        start=(MORNING_B + timedelta(minutes=1)).astimezone().isoformat(), date="2026-11-18")))
    (phone / "manifests").mkdir()
    (phone / "manifests" / "2026-11-18-080000.manifest.json").write_text(json.dumps(dict(
        format="eeg-tracker-phone-export", version=1,
        files=[dict(path=f"recordings/{b1}{x}", bytes=1, sha256="0" * 64) for x in (".f32", ".idx", ".log")])))
    (phone / "meditations").mkdir()
    (phone / "meditations" / "2026-11-18-080000.meditation.json").write_text("{}")
    (rec / "current-run.out").write_text("recorder output\n")
    return loc


def run(local: Path, *args: str) -> tuple[int, str]:
    lines: list[str] = []
    code = catalog.main(["--local", str(local), *args], out=lines.append)
    return code, "\n".join(lines)


def load(local: Path) -> dict:
    return json.loads((local / "catalog" / "catalog.json").read_text())


def snapshot(folder: Path) -> dict:
    return {str(p.relative_to(folder)): (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes())
            for p in folder.rglob("*") if p.is_file() and "catalog" not in p.relative_to(folder).parts}


def test_one_row_per_night_with_its_files_hours_report_and_check_in(local: Path) -> None:
    code, text = run(local)
    assert code == 0, text
    rows = {n["date"]: n for n in load(local)["nights"]}
    assert list(rows) == ["2026-11-16", "2026-11-17", "2026-11-20"]
    a, b, c = rows["2026-11-16"], rows["2026-11-17"], rows["2026-11-20"]
    assert (a["source"], a["recordings"], a["hours_recorded"], a["minutes_missing"]) == ("laptop", 2, 2.5, 30.0)
    # two recordings, the markers, a hand-made BDF, an empty run, the check-in, the report and its files
    assert a["files"] == 2 * 3 + 1 + 1 + 3 + 1 + 4
    assert a["bytes"] == sum(f["bytes"] for f in a["file_list"])
    assert a["report"] == dict(by="laptop", asleep_min=120.0, deep_min=20.0, dream_min=30.0)
    assert a["morning"] == [f"recordings/{stamp(A2 + timedelta(minutes=80))}.morning.json"]
    assert (b["source"], b["recordings"], b["hours_recorded"], b["minutes_missing"]) == ("phone", 1, 0.75, 0.0)
    assert b["report"] == dict(by="phone", asleep_min=40.0, deep_min=10.0, dream_min=5.0)
    assert b["files"] == 3 + 1 + 1 + 3 and len(b["morning"]) == 1  # recording, report, check-in and its raw signal
    assert (c["source"], c["recordings"], c["files"], c["hours_recorded"], c["minutes_missing"]) == ("phone", 0, 1, 7.0, 12.0)
    for date in rows:
        assert f"{date} " in text
    assert "not in any night: 4 files" in text  # the recorder's output, the job log, the manifest, a meditation


def test_every_file_has_its_sha256_in_the_nights_sidecar(local: Path) -> None:
    run(local)
    lines = (local / "catalog" / "2026-11-16.sha256").read_text().splitlines()
    listed = dict(reversed(ln.split("  ", 1)) for ln in lines)
    files = [f["path"] for n in load(local)["nights"] if n["date"] == "2026-11-16" for f in n["file_list"]]
    assert sorted(listed) == sorted(files) and len(files) == 16
    for path, digest in listed.items():
        assert hashlib.sha256((local / path).read_bytes()).hexdigest() == digest  # `sha256sum -c` format, from _local


def test_the_catalog_reads_the_data_and_writes_only_its_own_folder(local: Path) -> None:
    before = snapshot(local)
    run(local)
    run(local, "--check")
    assert snapshot(local) == before
    assert sorted(p.name for p in (local / "catalog").iterdir()) == [
        "2026-11-16.sha256", "2026-11-17.sha256", "2026-11-20.sha256", "catalog.json", "catalog.txt", "history.log"]


def test_a_growing_recording_is_fine_and_a_rebuilt_report_is_said(local: Path) -> None:
    run(local)
    with open(local / "recordings" / f"{stamp(A2)}.f32", "ab") as f:
        f.write(b"\0" * REC * FS)
    (local / "nights" / "2026-11-16.report.json").write_text(report(121.0, 20.0, 30.0))
    code, text = run(local)
    assert code == 0, text
    assert f"grew: recordings/{stamp(A2)}.f32" in text
    assert "rebuilt: nights/2026-11-16.report.json" in text
    assert "PROBLEM" not in text


def test_check_rehashes_and_finds_damage_the_quick_run_cannot_see(local: Path) -> None:
    run(local)
    f = local / "recordings" / f"{stamp(A1)}.f32"
    st = f.stat()
    with open(f, "r+b") as h:
        h.seek(1000); h.write(b"\1")
    os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))  # same size and time: only the bytes changed
    assert run(local)[0] == 0
    kept = (local / "catalog" / "catalog.json").read_bytes()
    code, text = run(local, "--check")
    assert code == 1 and f"PROBLEM: damaged: recordings/{stamp(A1)}.f32" in text
    assert (local / "catalog" / "catalog.json").read_bytes() == kept  # --check writes nothing


def test_a_missing_or_changed_raw_file_is_a_problem_every_run_until_it_is_back(local: Path) -> None:
    run(local)
    idx = local / "recordings" / f"{stamp(A1)}.idx"
    body = idx.read_bytes()
    idx.unlink()  # the owner's mistake; the catalog itself never deletes
    with open(local / "recordings" / f"{stamp(B1)}.log", "w") as f:
        f.write("rewritten")  # shorter than before: not an append
    code, text = run(local)
    assert code == 1
    assert f"PROBLEM: missing: recordings/{stamp(A1)}.idx (night 2026-11-16)" in text
    assert f"PROBLEM: changed: recordings/{stamp(B1)}.log" in text
    code, text = run(local)
    assert code == 1 and f"PROBLEM: missing: recordings/{stamp(A1)}.idx" in text  # still said
    assert f"recordings/{stamp(A1)}.idx" in (local / "catalog" / "2026-11-16.sha256").read_text()
    assert "changed:" not in text  # said once, and in history.log
    assert "changed: recordings/" in (local / "catalog" / "history.log").read_text()
    idx.write_bytes(body)
    code, text = run(local)
    assert code == 0 and f"back: recordings/{stamp(A1)}.idx" in text


def test_the_catalog_never_loads_numpy(local: Path) -> None:
    code = ("import sys; sys.path.insert(0, sys.argv[1]); import catalog; "
            "catalog.main(['--local', sys.argv[2]], out=lambda s: None); print('numpy' in sys.modules)")
    r = subprocess.run([sys.executable, "-c", code, str(ROOT / "scripts"), str(local)], capture_output=True, text=True,
                       timeout=60)
    assert r.stdout.strip() == "False", r.stderr
