"""scripts/import_phone.py: the phone's export folder checked against its manifest and copied into _local/."""
import hashlib
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import import_phone as ip  # noqa: E402

EXPORTED = "2026-11-19T07:42:10+03:00"
T0 = 1_763_500_000_000  # ms, the phone's modified time of the files below


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


FILES = {
    "recordings/2026-11-18-231200.f32": b"\x01\x00\x00\x00" + b"\x00" * 16,
    "recordings/2026-11-18-231200.idx": b"\x00" * 16,
    "recordings/2026-11-18-231200.log": b"connected\n",
    "nights/2026-11-18.report.json": b'{"version": 2}',
    "meditations/2026-11-19-080000.meditation.json": b"{}",
    "dream-catcher/2026-11-18-230000-r1.wav": b"RIFF....WAVE",
    "replay-check/meditation/plan.json": b'{"plan": 1}',
    "settings.json": b'{"replayCheck": false}',
}


def make_export(root: Path, files: dict[str, bytes] = FILES, *, modified: int = T0, write: dict[str, bytes] | None = None,
                not_exported: tuple[str, ...] = (), extra: dict[str, dict] | None = None) -> Path:
    """An export folder as the phone writes it: the files (or [write] instead, to fake damage) and manifest.json."""
    root.mkdir(parents=True, exist_ok=True)
    for p, b in (files if write is None else write).items():
        f = root / p
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b)
    entries = [dict(path=p, bytes=len(b), sha256=sha(b), modified_ms=modified, written=EXPORTED, **(extra or {}).get(p, {}))
               for p, b in sorted(files.items())]
    manifest = dict(format="eeg-tracker-phone-export", version=1, exported=EXPORTED, mode="new",
                    complete=not not_exported, files=entries, not_exported=list(not_exported),
                    totals=dict(files=len(entries), bytes=sum(e["bytes"] for e in entries)))
    (root / "manifest.json").write_text(json.dumps(manifest))
    return root


def run(folder: Path, dest: Path, *args: str) -> tuple[int, str]:
    lines: list[str] = []
    code = ip.main([str(folder), "--dest", str(dest), *args], out=lines.append)
    return code, "\n".join(lines)


def test_a_fresh_import_puts_raw_nights_with_the_laptops_and_the_rest_under_phone(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    code, text = run(exp, dest)
    assert code == 0, text
    assert (dest / "recordings" / "2026-11-18-231200.f32").read_bytes() == FILES["recordings/2026-11-18-231200.f32"]
    assert (dest / "phone" / "nights" / "2026-11-18.report.json").read_bytes() == FILES["nights/2026-11-18.report.json"]
    assert (dest / "phone" / "replay-check" / "meditation" / "plan.json").exists()
    assert (dest / "phone" / "settings.json").exists()
    assert not (dest / "phone" / "recordings").exists()
    # the phone's modified time is kept, so a later export can tell which copy is newer
    assert os.stat(dest / "phone" / "settings.json").st_mtime_ns == T0 * 1_000_000
    assert "8 new" in text and "3 into _local/recordings" in text
    assert "Everything in the phone's list is on the laptop." in text
    assert (dest / "phone" / "manifests" / "2026-11-19-074210.manifest.json").exists()
    log = [json.loads(x) for x in (dest / "phone" / "imports.jsonl").read_text().splitlines()]
    assert log[-1]["new"] == 8 and log[-1]["exported"] == EXPORTED
    assert not list(dest.rglob("*.importing"))


def test_importing_the_same_folder_again_copies_nothing(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    run(exp, dest)
    code, text = run(exp, dest)
    assert code == 0 and "8 already here" in text and "new, copied" not in text


def test_the_parent_folder_works_too(tmp_path: Path) -> None:
    make_export(tmp_path / "Sync" / "eeg-export")
    code, _ = run(tmp_path / "Sync", tmp_path / "_local")
    assert code == 0 and (tmp_path / "_local" / "phone" / "settings.json").exists()


def test_a_damaged_file_is_not_copied_and_says_so(tmp_path: Path) -> None:
    bad = dict(FILES, **{"recordings/2026-11-18-231200.idx": b"\x00" * 15 + b"\x01"})
    exp, dest = make_export(tmp_path / "eeg-export", write=bad), tmp_path / "_local"
    code, text = run(exp, dest)
    assert code == 1
    assert not (dest / "recordings" / "2026-11-18-231200.idx").exists()
    assert "PROBLEM" in text and "recordings/2026-11-18-231200.idx" in text
    assert not list(dest.rglob("*.importing"))


def test_a_file_cleared_from_the_folder_is_fine_once_the_laptop_has_it(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    run(exp, dest)
    (exp / "recordings" / "2026-11-18-231200.f32").unlink()  # the owner freed space on the phone
    code, text = run(exp, dest)
    assert code == 0 and "8 already here" in text


def test_a_file_missing_everywhere_is_a_problem(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    (exp / "settings.json").unlink()
    code, text = run(exp, dest)
    assert code == 1 and "missing" in text and "settings.json" in text


def test_a_newer_phone_copy_replaces_the_old_one_and_keeps_it(tmp_path: Path) -> None:
    dest = tmp_path / "_local"
    run(make_export(tmp_path / "a"), dest)
    newer = dict(FILES, **{"meditations/2026-11-19-080000.meditation.json": b'{"note": "x"}'})
    code, text = run(make_export(tmp_path / "b", newer, modified=T0 + 60_000), dest)
    assert code == 0, text
    target = dest / "phone" / "meditations" / "2026-11-19-080000.meditation.json"
    assert target.read_bytes() == b'{"note": "x"}'
    kept = list((dest / "phone" / "replaced").rglob("2026-11-19-080000.meditation.json"))
    assert len(kept) == 1 and kept[0].read_bytes() == b"{}"
    assert "1 updated" in text and "replaced" in text


def test_an_older_phone_copy_never_replaces_a_newer_one(tmp_path: Path) -> None:
    dest = tmp_path / "_local"
    newer = dict(FILES, **{"settings.json": b'{"replayCheck": true}'})
    run(make_export(tmp_path / "new", newer, modified=T0 + 60_000), dest)
    code, text = run(make_export(tmp_path / "old"), dest)
    assert (dest / "phone" / "settings.json").read_bytes() == b'{"replayCheck": true}'
    assert code == 0 and "1 left alone" in text and "settings.json" in text


def test_a_path_outside_the_folder_is_refused(tmp_path: Path) -> None:
    exp = make_export(tmp_path / "eeg-export", {"../evil.json": b"x", "settings.json": b"{}"},
                      write={"settings.json": b"{}"})
    code, text = run(exp, tmp_path / "_local")
    assert code == 2 and "../evil.json" in text
    assert not (tmp_path / "evil.json").exists() and not (tmp_path / "_local").exists()


def test_a_cut_off_manifest_is_reported_plainly(tmp_path: Path) -> None:
    exp = make_export(tmp_path / "eeg-export")
    m = exp / "manifest.json"
    m.write_text(m.read_text()[:50])
    code, text = run(exp, tmp_path / "_local")
    assert code == 2 and "manifest" in text.lower()


def test_no_manifest_at_all(tmp_path: Path) -> None:
    (tmp_path / "empty").mkdir()
    code, text = run(tmp_path / "empty", tmp_path / "_local")
    assert code == 2 and "manifest.json" in text


def test_a_dry_run_writes_nothing(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    code, text = run(exp, dest, "--dry-run")
    assert code == 0 and "8 new" in text and not dest.exists()


def test_files_the_export_stopped_before_are_named(tmp_path: Path) -> None:
    exp = make_export(tmp_path / "eeg-export", not_exported=("sound-states/2026-11-19-230000.sound.json",))
    code, text = run(exp, tmp_path / "_local")
    assert code == 1 and "1 file on the phone was not exported yet" in text


def test_files_outside_the_list_are_left_alone(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    (exp / ".stfolder").mkdir()
    (exp / "stray.txt").write_text("x")
    code, text = run(exp, dest)
    assert code == 0 and "1 file in the folder is not in the list" in text
    assert not (dest / "phone" / "stray.txt").exists()


def test_rehash_finds_a_laptop_copy_changed_behind_the_index(tmp_path: Path) -> None:
    exp, dest = make_export(tmp_path / "eeg-export"), tmp_path / "_local"
    run(exp, dest)
    f = dest / "phone" / "settings.json"
    st = f.stat()
    f.write_bytes(b'{"replayCheck": falsX}')  # same size, same time: only a hash can tell
    os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert "8 already here" in run(exp, dest)[1]  # the index trusts an unchanged size and time
    code, text = run(exp, dest, "--rehash")
    assert "1 left alone" in text  # same age as the phone's: kept, and said


def test_the_fixture_the_phone_app_wrote_imports_cleanly(tmp_path: Path) -> None:
    fixture = ROOT / "app" / "test" / "fixtures" / "phone_export"
    if not (fixture / "eeg-export" / "manifest.json").exists():
        pytest.skip("app/test/fixtures/phone_export is made by app/test/export_test.dart")
    code, text = run(fixture, tmp_path / "_local")
    assert code == 0, text
    assert list((tmp_path / "_local" / "recordings").glob("*.f32"))
    assert (tmp_path / "_local" / "phone" / "dream-catcher" / "prompts").is_dir()
