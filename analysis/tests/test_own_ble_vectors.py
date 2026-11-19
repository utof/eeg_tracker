"""The golden vectors shared by the laptop's and the phone's BrainBit parsers (app/test/fixtures/own_ble_vectors.json).

The file is made from the Python parser (scripts/brainbit_ble.py) and the fake headband; the phone's Dart parser is
checked against it in app/test/own_ble_protocol_test.dart. This test fails when the Python side changed and the
file was not made again, so the two parsers cannot drift apart unnoticed.
"""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAKER = ROOT / "app" / "test" / "fixtures" / "make_own_ble_vectors.py"


def load_maker():
    spec = importlib.util.spec_from_file_location("make_own_ble_vectors", MAKER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_the_vector_file_matches_the_python_parser():
    maker = load_maker()
    assert maker.OUT.read_text() == maker.text(), (
        "run: python3 app/test/fixtures/make_own_ble_vectors.py (then rerun the Dart test)")


def test_the_vectors_cover_what_the_phone_must_agree_on():
    v = json.loads(load_maker().OUT.read_text())
    good = [c for c in v["signal"] if not c.get("error")]
    assert len(good) >= 13 and sum(len(c["samples"]) for c in good) >= 80
    assert sum(1 for c in v["signal"] if c.get("error")) == 7
    assert {tuple(c["order"]) for c in good} >= {("O2", "T3", "T4", "O1"), ("T3", "T4", "O1", "O2")}
    assert any(c["counter"] > 0xFFFFFFF0 for c in good)  # the 32-bit wrap
    assert any("inf" in c.get("ohms", {}).values() for c in v["resist"])
    assert v["constants"]["backoff"] == [1.0, 2.0, 5.0, 10.0, 20.0, 30.0]


def test_the_phones_probe_result_reaches_the_laptop_through_export_and_import(tmp_path):
    """The phone keeps the probe's result in files/own-ble/ (app-private); Export data takes everything, and the
    importer files it under _local/phone/own-ble/, beside the settings that say which connection was in use."""
    from test_import_phone import FILES, make_export, run

    files = dict(FILES)
    files["own-ble/settings.json"] = b'{"useOwn": false}'
    for name in ("summary.txt", "summary.json", "raw.txt", "decoded.csv", "gatt.txt", "probe.log"):
        files[f"own-ble/probe/2026-11-19-081500/{name}"] = name.encode()
    code, text = run(make_export(tmp_path / "eeg-export", files), tmp_path / "_local")
    assert code == 0, text
    probe = tmp_path / "_local" / "phone" / "own-ble" / "probe" / "2026-11-19-081500"
    assert sorted(p.name for p in probe.iterdir()) == [
        "decoded.csv", "gatt.txt", "probe.log", "raw.txt", "summary.json", "summary.txt"]
    assert (tmp_path / "_local" / "phone" / "own-ble" / "settings.json").exists()
    assert "summary.txt" not in text or "VERDICT" not in text  # the importer never prints file contents
