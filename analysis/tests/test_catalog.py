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


# ---- the DIY board's recordings (DECISIONS 381: their own source, away from the BrainBit nights) ----


def write_diy(folder: Path, start: datetime, minutes: float, *, channels: int = 4, fs: int = 250, log: bool = True) -> str:
    """A DIY board file set like record_diy.py's: <I + one f per channel records, the format line in the .log."""
    folder.mkdir(parents=True, exist_ok=True)
    rec = 4 + 4 * channels
    n = int(minutes * 60 * fs)
    s = stamp(start)
    (folder / f"{s}.f32").write_bytes(b"\0" * n * rec)
    rows = [(start.timestamp() + 60 * (k + 1), k * 60 * fs) for k in range(int(minutes))]
    (folder / f"{s}.idx").write_bytes(b"".join(struct.pack("<dQ", t, i) for t, i in rows))
    text = f"driver DIY board\nformat .f32 records <I{channels}f: board sequence number, then Ch in volts; {fs} Hz\n"
    (folder / f"{s}.log").write_text(text if log else "recording started\n")
    return s


D1, D2 = datetime(2026, 11, 16, 23, 30, 0), datetime(2026, 11, 19, 23, 0, 0)  # D1 is the evening of a BrainBit night


@pytest.fixture
def with_diy(local: Path) -> Path:
    diy = local / "recordings-diy"
    write_diy(diy, D1, 30, channels=8, fs=500)  # 30 min of 8 channels at 500 Hz: 36-byte records
    write_diy(diy, D2, 20)
    write_diy(diy, D2 + timedelta(minutes=25), 10, log=False)  # no format line: the 4-channel 250 Hz default
    (diy / "current-run.out").write_text("recorder output\n")
    return local


def test_diy_recordings_are_their_own_rows_and_never_mixed_with_the_brainbit_night_of_the_same_date(with_diy: Path) -> None:
    code, text = run(with_diy)
    assert code == 0, text
    rows = load(with_diy)["nights"]
    assert [(n["date"], n["source"]) for n in rows] == [
        ("2026-11-16", "laptop"), ("2026-11-16", "diy"), ("2026-11-17", "phone"), ("2026-11-19", "diy"), ("2026-11-20", "phone")]
    brain, d1, _, d2, _ = rows
    assert (brain["recordings"], brain["hours_recorded"], brain["files"]) == (2, 2.5, 2 * 3 + 1 + 1 + 3 + 1 + 4)
    assert all(not f["path"].startswith("recordings-diy/") for f in brain["file_list"])
    assert (d1["id"], d1["raw"], d1["recordings"], d1["hours_recorded"], d1["minutes_missing"]) == ("2026-11-16-diy", True, 1, 0.5, 0.0)
    assert d1["report"] is None and d1["morning"] == []
    assert d1["bytes"] == sum(f["bytes"] for f in d1["file_list"])
    assert next(f["bytes"] for f in d1["file_list"] if f["path"].endswith(".f32")) == 30 * 60 * 500 * 36
    assert {f["kind"] for f in d1["file_list"]} == {"raw"}
    # two runs of the same evening chain into one night: 20 min of the log's format, 10 min of the default
    assert (d2["id"], d2["recordings"], d2["hours_recorded"], d2["minutes_missing"]) == ("2026-11-19-diy", 2, 0.5, 5.0)
    assert d2["files"] == 6
    assert "diy" in text and "2026-11-19" in text


def test_diy_sidecars_are_apart_and_stray_diy_files_are_counted(with_diy: Path) -> None:
    code, text = run(with_diy)
    assert code == 0, text
    out = with_diy / "catalog"
    brain = (out / "2026-11-16.sha256").read_text()
    diy = (out / "2026-11-16-diy.sha256").read_text()
    assert "recordings-diy/" not in brain and "recordings/" in brain
    assert diy.count("recordings-diy/") == 3 and "recordings/" not in diy.replace("recordings-diy/", "")
    assert (out / "2026-11-19-diy.sha256").exists()
    assert "not in any night: 5 files" in text  # the four of the BrainBit data, and the DIY recorder's output
    assert "recordings-diy/current-run.out" in text


def test_a_diy_raw_file_that_goes_missing_is_a_problem_named_for_its_diy_night(with_diy: Path) -> None:
    run(with_diy)
    (with_diy / "recordings-diy" / f"{stamp(D2)}.f32").unlink()
    code, text = run(with_diy)
    assert code == 1
    assert f"missing: recordings-diy/{stamp(D2)}.f32 (night 2026-11-19-diy)" in text
    assert [n["date"] for n in load(with_diy)["nights"] if n["source"] == "diy"] == ["2026-11-16", "2026-11-19"]


# ---- the recording header (docs/data-format.md): a raw file of its set; width and rate come from it first ----


def write_header(folder: Path, s: str, names: tuple[str, ...], fs: int) -> Path:
    import recording
    return recording.write(folder / f"{s}.f32", recording.diy_board(names, fs, layout="test"))


H1 = datetime(2026, 11, 21, 23, 0, 0)


@pytest.fixture
def with_headers(local: Path) -> Path:
    """A 16-channel night at 500 Hz in recordings-diy/ whose header disagrees with its log line (the header wins),
    an 8-channel night with a header in recordings/, and a header beside the phone's check-in recording."""
    s = write_diy(local / "recordings-diy", H1, 30, channels=16, fs=500)
    (local / "recordings-diy" / f"{s}.log").write_text("format .f32 records <I4f: board sequence number, then A B C D in volts; 250 Hz\n")
    write_header(local / "recordings-diy", s, tuple(f"E{i}" for i in range(1, 17)), 500)
    s = write_diy(local / "recordings", H1, 20, channels=8, fs=250, log=False)
    write_header(local / "recordings", s, tuple(f"Ch{i}" for i in range(1, 9)), 250)
    write_header(local / "phone" / "mornings", stamp(MORNING_B), ("O1", "O2", "T3", "T4"), 250)
    return local


def test_the_header_is_a_raw_file_of_its_night_and_gives_the_width_and_rate(with_headers: Path) -> None:
    code, text = run(with_headers)
    assert code == 0, text
    rows = {n["id"]: n for n in load(with_headers)["nights"]}
    diy, brain, phone = rows["2026-11-21-diy"], rows["2026-11-21"], rows["2026-11-17"]
    assert (diy["hours_recorded"], diy["minutes_missing"]) == (0.5, 0.0)  # 68-byte records at 500 Hz, by the header
    assert (brain["hours_recorded"], brain["minutes_missing"]) == (0.33, 0.0)  # 36-byte records in recordings/
    for row, rel in ((diy, f"recordings-diy/{stamp(H1)}.header.json"), (brain, f"recordings/{stamp(H1)}.header.json"),
                     (phone, f"phone/mornings/{stamp(MORNING_B)}.header.json")):
        f = next(f for f in row["file_list"] if f["path"] == rel)
        assert f["kind"] == "raw" and f["sha256"] == hashlib.sha256((with_headers / rel).read_bytes()).hexdigest()
    assert f"recordings-diy/{stamp(H1)}.header.json" in (with_headers / "catalog" / "2026-11-21-diy.sha256").read_text()


def test_a_header_that_goes_missing_or_changes_is_a_problem(with_headers: Path) -> None:
    run(with_headers)
    gone = with_headers / "recordings" / f"{stamp(H1)}.header.json"
    body = gone.read_bytes()
    gone.unlink()
    changed = with_headers / "recordings-diy" / f"{stamp(H1)}.header.json"
    changed.write_text(changed.read_text().replace('"test"', '"other"'))
    code, text = run(with_headers)
    assert code == 1
    assert f"PROBLEM: missing: recordings/{stamp(H1)}.header.json (night 2026-11-21)" in text
    assert f"PROBLEM: changed: recordings-diy/{stamp(H1)}.header.json" in text
    gone.write_bytes(body)
    code, text = run(with_headers)
    assert f"back: recordings/{stamp(H1)}.header.json" in text


def test_a_damaged_header_is_a_problem_on_every_run_and_its_width_is_not_guessed(with_headers: Path) -> None:
    run(with_headers)
    bad = with_headers / "recordings-diy" / f"{stamp(H1)}.header.json"
    bad.write_text("{")
    for _ in range(2):
        code, text = run(with_headers)
        assert code == 1 and f"PROBLEM: damaged: recordings-diy/{stamp(H1)}.header.json" in text
    assert "2026-11-21-diy" not in {n["id"] for n in load(with_headers)["nights"]}  # no hours from a guessed width
    assert f"recordings-diy/{stamp(H1)}.f32" in text  # its files are named among those in no night
