"""The recording header (<stamp>.header.json, docs/data-format.md): what a .f32 holds, for any number of channels;
files from before it read by the .log's format line, else as the BrainBit's; channels picked by name or 10-10 site.
"""
import json
import struct
from pathlib import Path

import pytest

import packed
import recording as rc

EXAMPLE = {
    "format": "eeg-tracker-recording", "version": 1, "device": "BrainBit", "layout": "BrainBit",
    "channels": [{"name": "O1", "site": "O1", "xyz": [-0.309, -0.951, 0.0]},
                 {"name": "O2", "site": "O2", "xyz": [0.309, -0.951, 0.0]},
                 {"name": "T3", "site": "T7", "xyz": [-1.0, 0.0, 0.0]}, {"name": "T4", "site": "T8", "xyz": [1.0, 0.0, 0.0]}],
    "reference": {"name": "Ref", "where": "forehead", "site": "Fpz"}, "ground": None,
    "sample_rate": 250, "unit": "V", "record": "<I4f", "counter": "packet number", "made_by": "eeg_tracker app"}

HELMET_16 = ("Fp1", "Fp2", "F3", "F4", "C3", "C4", "P3", "P4", "O1", "O2", "F7", "F8", "T7", "T8", "P7", "P8")


def put(path: Path, obj: object) -> Path:
    path.write_text(obj if isinstance(obj, str) else json.dumps(obj))
    return path


@pytest.mark.parametrize("n", [4, 8, 16])
def test_record_size_and_struct_for_n_channels(n: int) -> None:
    assert rc.record_format(n) == f"<I{n}f"
    assert rc.record_bytes(n) == 4 + 4 * n == rc.record_struct(n).size
    assert rc.record_struct(n).pack(7, *range(n)) == struct.pack(f"<I{n}f", 7, *range(n))


def test_record_formats_the_spec_names() -> None:
    assert [rc.record_bytes(n) for n in (4, 8, 16)] == [20, 36, 68]
    for bad in (0, 65, -1):
        with pytest.raises(ValueError):
            rc.record_format(bad)


@pytest.mark.parametrize("names", [("O1", "O2", "T3", "T4"), tuple(f"Ch{i}" for i in range(1, 9)), HELMET_16])
def test_header_round_trip(tmp_path: Path, names: tuple[str, ...]) -> None:
    h = rc.diy_board(names, 500, layout="Helmet plan", reference="an earlobe, to SRB1", bias="the other earlobe",
                     made_by="test")
    f32 = tmp_path / "2026-11-20-010203.f32"
    where = rc.write(f32, h)
    assert where == tmp_path / "2026-11-20-010203.header.json"
    assert [p.name for p in tmp_path.iterdir()] == [where.name]  # the temporary name is gone
    assert len(where.read_bytes()) < 4096
    d = json.loads(where.read_text())
    assert d["format"] == "eeg-tracker-recording" and d["version"] == 1
    assert d["record"] == f"<I{len(names)}f" and d["unit"] == "V" and d["sample_rate"] == 500
    assert d["counter"] == "board sequence number" and d["device"] == "DIY board" and d["layout"] == "Helmet plan"
    assert [c["name"] for c in d["channels"]] == list(names)
    assert d["reference"] == {"name": "Ref", "where": "an earlobe, to SRB1", "site": None}
    assert d["ground"] == {"name": "Bias", "where": "the other earlobe", "site": None}
    back = rc.read(f32)
    assert back == h and back.source == "header"
    assert back.names == names and back.n == len(names) and back.record == f"<I{len(names)}f"
    assert back.record_bytes == 4 + 4 * len(names) and back.sample_rate == 500


def test_sites_come_from_the_names_old_names_as_the_new() -> None:
    h = rc.diy_board(("O1", "t3", "T4", "T5", "T6", "Ch5", "fpz", "Left ear"), 250)
    assert [c.site for c in h.channels] == ["O1", "T7", "T8", "P7", "P8", None, "Fpz", None]
    assert rc.site_of("T7") == "T7" and rc.site_of("oz") == "Oz" and rc.site_of("AF7") == "AF7"
    assert rc.site_of("") is None and rc.site_of("Ch1") is None


def test_the_brainbit_header_is_the_documented_one(tmp_path: Path) -> None:
    h = rc.brainbit(made_by="scripts/recorder_hub.py")
    d = rc.to_json(h)
    assert [(c["name"], c["site"], c["xyz"]) for c in d["channels"]] == [
        ("O1", "O1", None), ("O2", "O2", None), ("T3", "T7", None), ("T4", "T8", None)]
    assert d["reference"] == {"name": "Ref", "where": "forehead", "site": "Fpz"} and d["ground"] is None
    assert (d["device"], d["layout"], d["sample_rate"], d["unit"], d["record"], d["counter"]) == (
        "BrainBit", "BrainBit", 250, "V", "<I4f", "packet number")
    assert rc.parse(EXAMPLE, "x").names == h.names  # the app's example, with positions, reads too
    assert rc.parse(EXAMPLE, "x").channels[2].xyz == (-1.0, 0.0, 0.0)


def test_write_never_replaces_a_header(tmp_path: Path) -> None:
    f32 = tmp_path / "a.f32"
    rc.write(f32, rc.brainbit())
    with pytest.raises(FileExistsError):
        rc.write(f32, rc.diy_board(("Ch1",), 250))
    assert rc.read(f32).names == ("O1", "O2", "T3", "T4")


def test_unknown_fields_are_ignored(tmp_path: Path) -> None:
    f32 = tmp_path / "a.f32"
    put(tmp_path / "a.header.json", {**EXAMPLE, "later": {"x": 1}, "channels": [dict(c, gain=24) for c in EXAMPLE["channels"]]})
    assert rc.read(f32).names == ("O1", "O2", "T3", "T4")


BROKEN = {
    "not json": "{",
    "not an object": "[1]",
    "another format": {**EXAMPLE, "format": "something"},
    "no version": {k: v for k, v in EXAMPLE.items() if k != "version"},
    "version 0": {**EXAMPLE, "version": 0},
    "version true": {**EXAMPLE, "version": True},
    "no channels": {**EXAMPLE, "channels": [], "record": "<I0f"},
    "channels not a list": {**EXAMPLE, "channels": "O1"},
    "65 channels": {**EXAMPLE, "channels": [{"name": f"C{i}", "site": None, "xyz": None} for i in range(65)],
                    "record": "<I65f"},
    "a name twice": {**EXAMPLE, "channels": [EXAMPLE["channels"][0]] * 4},
    "an empty name": {**EXAMPLE, "channels": [{"name": "", "site": None, "xyz": None}], "record": "<I1f"},
    "a long name": {**EXAMPLE, "channels": [{"name": "x" * 33, "site": None, "xyz": None}], "record": "<I1f"},
    "a name that is a number": {**EXAMPLE, "channels": [{"name": 1, "site": None, "xyz": None}], "record": "<I1f"},
    "a channel that is a string": {**EXAMPLE, "channels": ["O1"], "record": "<I1f"},
    "site a number": {**EXAMPLE, "channels": [{"name": "O1", "site": 3, "xyz": None}], "record": "<I1f"},
    "xyz of two": {**EXAMPLE, "channels": [{"name": "O1", "site": None, "xyz": [1, 0]}], "record": "<I1f"},
    "xyz not unit length": {**EXAMPLE, "channels": [{"name": "O1", "site": None, "xyz": [1, 1, 0]}], "record": "<I1f"},
    "xyz of strings": {**EXAMPLE, "channels": [{"name": "O1", "site": None, "xyz": ["1", 0, 0]}], "record": "<I1f"},
    "record of another width": {**EXAMPLE, "record": "<I8f"},
    "no record": {k: v for k, v in EXAMPLE.items() if k != "record"},
    "rate zero": {**EXAMPLE, "sample_rate": 0},
    "rate a string": {**EXAMPLE, "sample_rate": "250"},
    "rate true": {**EXAMPLE, "sample_rate": True},
    "microvolts": {**EXAMPLE, "unit": "uV"},
    "no counter": {k: v for k, v in EXAMPLE.items() if k != "counter"},
    "counter empty": {**EXAMPLE, "counter": ""},
    "device a number": {**EXAMPLE, "device": 4},
    "reference a string": {**EXAMPLE, "reference": "forehead"},
    "reference without a name": {**EXAMPLE, "reference": {"where": "forehead", "site": None}},
    "ground site a number": {**EXAMPLE, "ground": {"name": "Bias", "where": "ear", "site": 2}},
}


@pytest.mark.parametrize("why", sorted(BROKEN))
def test_a_damaged_header_is_an_error_that_names_the_file_never_a_guess(tmp_path: Path, why: str) -> None:
    f32 = tmp_path / "2026-11-20-010203.f32"
    f32.write_bytes(bytes(40))
    (tmp_path / "2026-11-20-010203.log").write_text("x format .f32 records <I4f: board sequence number, then A B C D in volts; 250 Hz\n")
    put(tmp_path / "2026-11-20-010203.header.json", BROKEN[why])
    with pytest.raises(rc.HeaderError) as e:
        rc.read(f32)
    assert "2026-11-20-010203.header.json" in str(e.value)


def test_a_newer_version_is_refused_in_words(tmp_path: Path) -> None:
    put(tmp_path / "a.header.json", {**EXAMPLE, "version": 2})
    with pytest.raises(rc.HeaderError, match=r"a\.header\.json.*version 2.*newer"):
        rc.read(tmp_path / "a.f32")


def test_an_empty_header_file_is_an_error_too(tmp_path: Path) -> None:
    (tmp_path / "a.header.json").write_bytes(b"")
    with pytest.raises(rc.HeaderError, match=r"a\.header\.json"):
        rc.read(tmp_path / "a.f32")


def test_without_a_header_or_a_format_line_it_is_the_brainbits(tmp_path: Path) -> None:
    f32 = tmp_path / "2026-11-01-230000.f32"
    for log in (None, "2026-11-01T23:00:00.000 connected BrainBit\n2026-11-01T23:00:10.000 samples 2500 (+2500) battery 80%\n"):
        if log is not None:
            f32.with_suffix(".log").write_text(log)
        h = rc.read(f32)
        assert h.source == "default" and h.names == ("O1", "O2", "T3", "T4") and h.sample_rate == 250
        assert h.record == "<I4f" and h.device == "BrainBit" and h.counter == "packet number"
        assert [c.site for c in h.channels] == ["O1", "O2", "T7", "T8"]


def test_the_logs_format_line_gives_an_old_diy_files_channels(tmp_path: Path) -> None:
    f32 = tmp_path / "2026-11-15-120000.f32"
    f32.with_suffix(".log").write_text(
        "2026-11-15T12:00:00.000 driver DIY board (scripts/record_diy.py): ...\n"
        "2026-11-15T12:00:00.001 format .f32 records <I8f: board sequence number, then Fz O1 O2 T7 T8 C3 C4 Pz in volts; 500 Hz\n"
        "2026-11-15T12:00:00.002 mode test signal\n")
    h = rc.read(f32)
    assert h.source == "log" and h.names == ("Fz", "O1", "O2", "T7", "T8", "C3", "C4", "Pz")
    assert h.sample_rate == 500 and h.record == "<I8f" and h.record_bytes == 36
    assert h.device == "DIY board" and h.counter == "board sequence number"
    assert h.reference is None and h.ground is None


def test_a_format_line_without_n_names_gives_ch1_to_chn(tmp_path: Path) -> None:
    f32 = tmp_path / "a.f32"
    f32.with_suffix(".log").write_text("t format .f32 records <I6f: board sequence number, then O1 O2 Fz Fp1 in volts; 250 Hz\n")
    assert rc.read(f32).names == ("Ch1", "Ch2", "Ch3", "Ch4", "Ch5", "Ch6")
    f32.with_suffix(".log").write_text("t format .f32 records <I4f: board sequence number, then O1 O1 Fz Fp1 in volts; 250 Hz\n")
    assert rc.read(f32).names == ("Ch1", "Ch2", "Ch3", "Ch4")  # a name twice is not n names


def test_the_header_wins_over_the_log_line(tmp_path: Path) -> None:
    f32 = tmp_path / "a.f32"
    f32.with_suffix(".log").write_text("t format .f32 records <I8f: board sequence number, then A B C D E F G H in volts; 500 Hz\n")
    rc.write(f32, rc.brainbit())
    assert rc.read(f32).names == ("O1", "O2", "T3", "T4") and rc.read(f32).source == "header"


def test_reading_takes_the_packed_name_too(tmp_path: Path) -> None:
    f32 = tmp_path / "2026-11-20-010203.f32"
    h = rc.diy_board(tuple(f"Ch{i}" for i in range(1, 9)), 250)
    rc.write(f32, h)
    f32.write_bytes(bytes(36) * 4000)
    packed.pack(f32)
    assert not f32.exists()
    assert rc.read(f32) == h and rc.read(tmp_path / "2026-11-20-010203.f32.xz") == h
    assert rc.read(tmp_path / "2026-11-20-010203.f32.gz") == h
    assert rc.header_path(tmp_path / "2026-11-20-010203.f32.xz") == tmp_path / "2026-11-20-010203.header.json"


def test_a_header_read_twice_is_read_again_when_the_file_changes(tmp_path: Path) -> None:
    f32 = tmp_path / "a.f32"
    assert rc.read(f32).source == "default"
    rc.write(f32, rc.diy_board(("A", "B"), 100))
    assert rc.read(f32).names == ("A", "B")


# ---- channels by name -----------------------------------------------------------------------------------------

SLEEP = ("O1", "O2", "T3", "T4")


def test_pick_by_exact_name() -> None:
    assert rc.pick(rc.brainbit(), SLEEP) == [0, 1, 2, 3]
    assert rc.pick(rc.brainbit(), ("T4", "O1")) == [3, 0]


def test_pick_by_site_with_the_old_names_as_the_new() -> None:
    h = rc.diy_board(("Fz", "O1", "O2", "T7", "T8", "C3", "C4", "Pz"), 250)
    assert rc.pick(h, SLEEP) == [1, 2, 3, 4]
    assert rc.pick(h, ("t3", "o2")) == [3, 2]
    assert rc.pick(rc.brainbit(), ("T7", "T8")) == [2, 3]
    assert rc.pick(rc.diy_board(("P7", "P8"), 250), ("T5", "T6")) == [0, 1]


def test_the_exact_name_wins_over_a_site() -> None:
    h = rc.parse({**EXAMPLE, "channels": [{"name": "A", "site": "T7", "xyz": None}, {"name": "T3", "site": None, "xyz": None}],
                  "record": "<I2f"}, "x")
    assert rc.pick(h, ("T3",)) == [1]


def test_a_missing_site_is_said_in_words_and_no_other_channel_is_read() -> None:
    h = rc.diy_board(tuple(f"Ch{i}" for i in range(1, 9)), 250)
    with pytest.raises(rc.MissingChannels) as e:
        rc.pick(h, SLEEP, "the sleep model")
    assert str(e.value) == ("the sleep model needs O1 O2 T3 T4; this recording (DIY board: Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 Ch8) "
                            "has no O1, O2, T3, T4")
    assert e.value.missing == ("O1", "O2", "T3", "T4")
    h = rc.diy_board(("O1", "O2", "Fz", "Fp1"), 250)
    with pytest.raises(rc.MissingChannels, match=r"needs O1 O2 T3 T4; this recording \(DIY board: O1 O2 Fz Fp1\) has no T3, T4$"):
        rc.pick(h, SLEEP, "the sleep model")


def test_pick_names_matches_plain_labels_like_a_bdfs() -> None:
    assert rc.pick_names(("Fz", "O1", "O2", "T7", "T8"), SLEEP) == [1, 2, 3, 4]
    with pytest.raises(rc.MissingChannels, match=r"this recording \(Ch1 Ch2\) has no O1, O2, T3, T4"):
        rc.pick_names(("Ch1", "Ch2"), SLEEP, "the sleep model")


def test_the_module_is_standard_library_only() -> None:
    import ast, sys
    names: set[str] = set()
    for node in ast.walk(ast.parse(Path(rc.__file__).read_text())):
        if isinstance(node, ast.Import):
            names |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module.split(".")[0])
    assert names - set(sys.stdlib_module_names) - {"__future__", "packed"} == set()
