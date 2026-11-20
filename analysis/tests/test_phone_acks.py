"""The laptop's side of moving raw recordings off the phone (DECISIONS 690-699, 755): scripts/pull_phone.py hashes its
copies again from disk and acks only what equals the phone's list, in a request signed with the pairing's key (POST
/ack; the signature's vectors in app/test/fixtures/phone_link.json); it never deletes; a phone's record of a set that left it is checked against what
this laptop holds; the catalog marks such nights. Against the fake phone of test_pull_phone.py."""
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog  # noqa: E402
import packed  # noqa: E402
import pull_phone as pp  # noqa: E402
from test_catalog import local  # noqa: E402,F401  (the catalog's fake _local, a fixture)
from test_packed import phone_packed, signal  # noqa: E402
from test_pull_phone import NOW, STEM, TOKEN, FakePhone, sha  # noqa: E402

KEY = "a" * 64


@pytest.fixture
def phone():
    f = FakePhone()
    f.key = KEY
    yield f
    f.close()


def run(phone: FakePhone, dest: Path, key: str | None = KEY, **kw) -> pp.Pass:
    """A pass as the paired laptop makes it (signed with the key), or by hand with the token (no key: no acks)."""
    p = pp.Phone(phone.base, key=key, home=True) if key else pp.Phone(phone.base, TOKEN)
    return pp.pull(p, dest, now=NOW, key=key, **kw)


def acks_sent(phone: FakePhone) -> list[str]:
    return [f["path"] for post in phone.ack_posts for f in post]


def test_acks_are_signed_requests_and_the_token_never_leaves(phone, tmp_path):
    phone.put(f"{STEM}.f32", b"\x01" * 4000)
    rep = run(phone, tmp_path / "_local")
    assert rep.acked == [f"{STEM}.f32"]
    assert ("POST", "/ack", True) in phone.signed and phone.bearer == 0


def test_finished_files_are_acked_after_they_are_hashed_again_once_and_nothing_is_deleted(phone, tmp_path):
    dest = tmp_path / "_local"
    phone.put(f"{STEM}.f32", b"\x01" * 4000)
    phone.put(f"{STEM}.idx", b"\x02" * 32)
    phone.put("nights/2026-11-18.report.json", b'{"night_of": "2026-11-18"}')
    phone.put("recordings/2026-11-19-020000.f32", b"\x03" * 100, growing=True)
    rep = run(phone, dest)
    assert sorted(rep.acked) == sorted([f"{STEM}.f32", f"{STEM}.idx", "nights/2026-11-18.report.json"])
    assert "recordings/2026-11-19-020000.f32" not in acks_sent(phone), "still being written: no SHA-256 to ack"
    line = json.loads((dest / "phone" / "acks.jsonl").read_text().splitlines()[-1])
    assert {f["path"] for f in line["files"]} == set(rep.acked)
    assert any("safe here" in s for s in pp.summary(rep, dest, NOW))
    phone.ack_posts.clear()
    rep = run(phone, dest)  # the phone lists them `acked`: nothing is hashed or sent again
    assert rep.acked == [] and phone.ack_posts == []
    assert (dest / f"{STEM}.f32").read_bytes() == b"\x01" * 4000 and len(phone.files) == 4


def test_a_copy_damaged_on_the_laptops_disk_is_never_acked(phone, tmp_path):
    """The index would trust the copy by its size and time; the ack reads it again."""
    dest = tmp_path / "_local"
    body = b"\x01" * 4000
    phone.put(f"{STEM}.f32", body)
    run(phone, dest, key=None)  # copied while not paired
    f = dest / f"{STEM}.f32"
    st = f.stat()
    f.write_bytes(b"\x09" + body[1:])
    os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))
    rep = run(phone, dest)
    assert rep.acked == [] and f"{STEM}.f32" not in phone.acks


def test_a_packed_night_is_acked_by_what_it_holds_also_when_the_laptop_packed_its_copy(phone, tmp_path):
    dest, body = tmp_path / "_local", signal(20000)
    path = f"{STEM}.f32"
    phone.put(f"{path}.gz", phone_packed(body))
    phone.originals[f"{path}.gz"] = dict(path=path, bytes=len(body), sha256=sha(body))
    run(phone, dest, key=None)
    packed.pack(dest / path)  # the laptop packs its copy after a day: the ack unpacks it to hash it
    rep = run(phone, dest)
    assert rep.acked == [f"{path}.gz"] and phone.acks[f"{path}.gz"] == sha(body)


def test_no_acks_without_the_pairing_or_from_an_older_app_and_nothing_hashed_then(phone, tmp_path, monkeypatch):
    dest = tmp_path / "_local"
    phone.put(f"{STEM}.f32", b"\x01" * 4000)
    rep = run(phone, dest, key=None)
    assert rep.acked == [] and phone.ack_posts == [] and "not paired" in (rep.ack_note or "")
    hashed: list[Path] = []
    real = pp._laptop_sha
    monkeypatch.setattr(pp, "_laptop_sha", lambda p: hashed.append(p) or real(p))
    phone.no_ack = True
    rep = run(phone, dest)
    assert rep.acked == [] and hashed == [] and "older" in (rep.ack_note or "")
    phone.no_ack = False
    rep = run(phone, dest)  # asked again only hours later
    assert rep.acked == [] and hashed == []
    phone.key = "0" * 64  # a pairing the phone no longer has: every signed request is refused, acks too
    (dest / "phone" / "pull-state.json").unlink()
    with pytest.raises(pp.Refused):
        run(phone, dest)
    assert hashed == [] and phone.ack_posts == []


def test_a_pass_hashes_at_most_its_budget_oldest_first(phone, tmp_path):
    dest = tmp_path / "_local"
    phone.put("recordings/2026-11-17-230000.f32", b"\x01" * 3000, modified=1_763_000_000_000)
    phone.put("recordings/2026-11-18-230000.f32", b"\x02" * 3000, modified=1_763_100_000_000)
    run(phone, dest, key=None)
    assert run(phone, dest, ack_budget=4000).acked == ["recordings/2026-11-17-230000.f32"]
    assert run(phone, dest, ack_budget=4000).acked == ["recordings/2026-11-18-230000.f32"]


def removed_record(stem: str, files: list[tuple[str, int]], on_laptop: bool = True) -> bytes:
    return json.dumps(dict(format="eeg-tracker-removed", version=1, removed_ms=1, on_laptop=on_laptop, why="moved",
                           files=[dict(name=n, bytes=b, sha256=None, phone_name=n, phone_bytes=b) for n, b in files])).encode()


def test_a_set_that_left_the_phone_is_not_missing_here_and_one_this_laptop_lacks_is_a_problem(phone, tmp_path):
    dest = tmp_path / "_local"
    phone.put(f"{STEM}.f32", b"\x01" * 4000)
    phone.put(f"{STEM}.log", b"started\n")
    run(phone, dest)
    del phone.files[f"{STEM}.f32"]  # the phone removed it after the ack
    phone.put(f"{STEM}.removed.json", removed_record(Path(STEM).name, [(Path(STEM).name + ".f32", 4000)]))
    rep = run(phone, dest)
    assert rep.removed == [f"{STEM}.removed.json"] and not rep.problems
    assert (dest / f"{STEM}.f32").exists() and (dest / f"{STEM}.removed.json").exists()
    assert any("left the phone" in s for s in pp.summary(rep, dest, NOW))
    other = "recordings/2026-11-18-230000"
    phone.put(f"{other}.removed.json", removed_record("2026-11-18-230000", [("2026-11-18-230000.f32", 500)]))
    rep = run(phone, dest)
    assert rep.lost == [f"{other}.f32"] and rep.problems
    assert any(s.startswith("PROBLEM: the phone removed") for s in pp.summary(rep, dest, NOW))


def test_the_catalog_marks_a_night_moved_from_the_phone(local):
    rec = sorted((local / "recordings").glob("*.f32"))[0]
    stem = rec.name.removesuffix(".f32")
    (local / "recordings" / f"{stem}.removed.json").write_bytes(removed_record(stem, [(rec.name, rec.stat().st_size)]))
    cat, _ = catalog.build(local, None, False, datetime(2026, 11, 20, 9).astimezone())
    moved = [n for n in cat["nights"] if n["moved_from_phone"]]
    assert len(moved) == 1 and any(f["path"].endswith(".removed.json") for f in moved[0]["file_list"])
    assert any("moved from phone" in line for line in catalog.table(cat, local, []))
