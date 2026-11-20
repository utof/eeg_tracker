"""The recorder hub writes <stamp>.header.json for every file set it opens, before the first sample, and the
BrainBit's .f32 bytes stay what they were (docs/data-format.md "The recording header")."""
import json
import random
import struct
from pathlib import Path

import pytest

import record_diy
import recorder_hub
import recording as rc

ROOT = Path(__file__).resolve().parents[2]


def test_the_brainbit_hub_writes_its_header_and_the_same_bytes_as_before(tmp_path: Path) -> None:
    rng = random.Random(11)
    rows = [(i, *(rng.uniform(-4e-4, 4e-4) for _ in range(4))) for i in range(500)]
    hub = recorder_hub.Hub(tmp_path)
    stamp = hub.open_files("2026-11-20-010203")
    header = tmp_path / f"{stamp}.header.json"
    assert header.is_file() and (tmp_path / f"{stamp}.f32").stat().st_size == 0  # there before the first sample
    hub.add_batch(rows[:200], now=1000.0); hub.write_pending(); hub.add_batch(rows[200:], now=1001.0)
    hub.finish(); hub.close()
    assert (tmp_path / f"{stamp}.f32").read_bytes() == b"".join(struct.pack("<I4f", *r) for r in rows)
    d = json.loads(header.read_text())
    assert d["format"] == "eeg-tracker-recording" and d["version"] == 1
    assert d["device"] == "BrainBit" and d["layout"] == "BrainBit"
    assert d["channels"] == [{"name": "O1", "site": "O1", "xyz": None}, {"name": "O2", "site": "O2", "xyz": None},
                             {"name": "T3", "site": "T7", "xyz": None}, {"name": "T4", "site": "T8", "xyz": None}]
    assert d["reference"] == {"name": "Ref", "where": "forehead", "site": "Fpz"} and d["ground"] is None
    assert (d["sample_rate"], d["unit"], d["record"], d["counter"]) == (250, "V", "<I4f", "packet number")
    assert "recorder_hub.py" in d["made_by"]
    assert rc.read(tmp_path / f"{stamp}.f32") == rc.brainbit(made_by=d["made_by"])
    assert sorted(p.name for p in tmp_path.iterdir()) == [f"{stamp}{s}" for s in (".f32", ".header.json", ".idx", ".log",
                                                                                 ".markers.jsonl")]


@pytest.mark.parametrize("n", [8, 16])
def test_a_hub_with_n_channels_writes_their_header_per_file_set(tmp_path: Path, n: int) -> None:
    names = tuple(f"Ch{i}" for i in range(1, n + 1))
    first_header = rc.diy_board(names, 500, layout="Helmet plan", reference="A1", bias="the other earlobe", made_by="t")
    hub = recorder_hub.Hub(tmp_path, names=names, reports=False)
    hub.configure(names, 500, header=first_header)
    first = hub.open_files("2026-11-20-010203")
    hub.add_batch([(7, *(c * 1e-6 for c in range(n)))], now=1000.0); hub.write_pending()
    hub.end_file_set()
    hub.configure(("O1", "O2", "Fz", "Fp1"), 250)  # no header given: one from the names
    second = hub.open_files()
    hub.add_batch([(1, 1e-6, 2e-6, 3e-6, 4e-6)], now=1001.0); hub.finish(); hub.close()
    a = rc.read(tmp_path / f"{first}.f32")
    assert a == first_header and a.record == f"<I{n}f" and a.sample_rate == 500
    assert a.reference == rc.Electrode("Ref", "A1", "A1") and a.ground == rc.Electrode("Bias", "the other earlobe", None)
    assert len((tmp_path / f"{first}.f32").read_bytes()) == 4 + 4 * n
    b = rc.read(tmp_path / f"{second}.f32")
    assert b.source == "header" and b.names == ("O1", "O2", "Fz", "Fp1") and b.sample_rate == 250
    assert [c.site for c in b.channels] == ["O1", "O2", "Fz", "Fp1"] and b.device is None


def test_a_header_must_match_the_channels_it_is_configured_with(tmp_path: Path) -> None:
    hub = recorder_hub.Hub(tmp_path)
    with pytest.raises(ValueError):
        hub.configure(("A", "B"), 250, header=rc.brainbit())
    with pytest.raises(ValueError):
        hub.configure(rc.BRAINBIT_NAMES, 500, header=rc.brainbit())


def test_a_new_stamp_steps_past_a_header_left_alone(tmp_path: Path) -> None:
    """A stamp is not reused when only its header is there (a recorder killed right after writing it)."""
    hub = recorder_hub.Hub(tmp_path)
    first = hub.open_files(); hub.end_file_set()
    (tmp_path / f"{first}.f32").unlink()
    second = hub.open_files(); hub.end_file_set()
    assert second != first


def test_the_diy_recorders_header_from_its_montage() -> None:
    montage = record_diy.load_montage(None)
    h = record_diy.header_for(montage, montage.names, 250, mismatch=False)
    assert h.device == "DIY board" and h.counter == "board sequence number" and h.sample_rate == 250
    assert h.layout == "scripts/montages/diy-breadboard-4.json" and "record_diy.py" in (h.made_by or "")
    assert [(c.name, c.site) for c in h.channels] == [("O1", "O1"), ("O2", "O2"), ("Fz", "Fz"), ("Fp1", "Fp1")]
    assert h.reference == rc.Electrode("Ref", "an earlobe, to SRB1 (chip leg 17) through 4.7 kohm", None)
    assert h.ground == rc.Electrode("Bias", "the other earlobe, to BIASOUT (chip leg 63) through 1 Mohm", None)
    names = tuple(f"Ch{i}" for i in range(1, 9))
    h = record_diy.header_for(montage, names, 500, mismatch=True)  # the montage's names do not fit the board
    assert h.names == names and h.layout == "DIY board" and h.sample_rate == 500 and h.record == "<I8f"
    listed = record_diy.load_montage("C3,C4,T3,Pz")
    h = record_diy.header_for(listed, listed.names, 250, mismatch=False)
    assert h.layout == "from --montage" and h.reference is None and h.ground is None
    assert [c.site for c in h.channels] == ["C3", "C4", "T7", "Pz"]
