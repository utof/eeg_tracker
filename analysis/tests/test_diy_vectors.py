"""The golden vectors shared by the laptop's and the phone's E9 decoders for the DIY ADS1299 board
(app/test/fixtures/diy_vectors.json), and the phone's DIY recordings on their way to the laptop.

The file is made from the Python driver (scripts/diy_board.py), the firmware's own golden frames and the fake board
(tests/fake_diy); the phone's Dart decoder is checked against it in app/test/diy_e9_test.dart. This test fails when
the Python side changed and the file was not made again, so the two decoders cannot drift apart unnoticed.
"""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAKER = ROOT / "app" / "test" / "fixtures" / "make_diy_vectors.py"


def load_maker():
    spec = importlib.util.spec_from_file_location("make_diy_vectors", MAKER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_the_vector_file_matches_the_python_driver():
    maker = load_maker()
    assert maker.OUT.read_text() == maker.text(), (
        "run: python3 app/test/fixtures/make_diy_vectors.py (then rerun the Dart test)")


def test_the_vectors_cover_what_the_phone_must_agree_on():
    v = json.loads(load_maker().OUT.read_text())
    good = [c for c in v["frames"] if "frame" in c]
    assert sum(1 for c in good if c["name"].startswith("golden ")) == 4  # every frame made by the firmware's code
    assert {c["frame"]["channels"] for c in good} == {4, 6, 8}
    assert {c["frame"]["mode"] for c in good} >= {"test", "short", "synthetic", "electrodes"}
    assert {c["error"] for c in v["frames"] if "error" in c} == {"short", "magic", "channels", "length", "range", "status"}
    assert set(v["bit_flips"]["refused_by"]) == {"crc", "magic", "channels", "length"}  # no single flip gets through
    s = {x["name"]: x for x in v["streams"]}
    assert s["text, cut frame, damage, garbage"]["frames"] == 38 and s["text, cut frame, damage, garbage"]["bad_frames"] >= 2
    assert any(x[1] for x in s["prompts and long text"]["steps"])  # firmware text lines come out
    kinds = {st["kind"] for t in v["tracker"] for st in t["steps"]}
    assert kinds == {"first", "next", "duplicate", "stale", "restart", "config"}


def test_the_phones_diy_recordings_reach_the_laptop_in_their_own_folder(tmp_path):
    """The phone keeps DIY nights in files/recordings-diy/ (away from the BrainBit nights in recordings/); Export data
    takes everything, and the importer files them under _local/recordings-diy/, as the laptop's DIY recorder does,
    never beside the BrainBit nights the sleep and morning tools read."""
    from test_import_phone import FILES, make_export, run

    files = dict(FILES)
    for ext in ("f32", "idx", "log", "markers.jsonl"):
        files[f"recordings-diy/2026-11-20-001500.{ext}"] = f"diy {ext}".encode()
    files["diy-board/settings.json"] = b'{"useDiy": true}'
    code, text = run(make_export(tmp_path / "eeg-export", files), tmp_path / "_local")
    assert code == 0, text
    diy = tmp_path / "_local" / "recordings-diy"
    assert sorted(p.name for p in diy.iterdir()) == [
        "2026-11-20-001500.f32", "2026-11-20-001500.idx", "2026-11-20-001500.log", "2026-11-20-001500.markers.jsonl"]
    assert (diy / "2026-11-20-001500.f32").read_bytes() == b"diy f32"
    assert not list((tmp_path / "_local" / "recordings").glob("2026-11-20-*"))  # never with the BrainBit nights
    assert not (tmp_path / "_local" / "phone" / "recordings-diy").exists()
    assert (tmp_path / "_local" / "phone" / "diy-board" / "settings.json").exists()
    assert "4 into _local/recordings-diy" in text
