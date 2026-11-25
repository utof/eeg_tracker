"""scripts/to_bdf.py: a file set that goes on from the one before it without a gap (a roll-over, DECISIONS 1036) is
joined to it sample to sample. The phone's twin, on the same numbers: app/test/roll_over_join_test.dart.
"""
from __future__ import annotations

import dataclasses
import sys
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import recording as rc  # noqa: E402
import to_bdf  # noqa: E402

T0 = datetime(2026, 11, 25, 9, 0, 0)
NAMES = ("O1", "O2", "T3", "T4")


def ms(n: int) -> datetime:
    return T0 + timedelta(milliseconds=n)


def make_set(folder: Path, start: datetime, first: datetime, batches: int, value0: int, recording: str | None) -> Path:
    """`batches` batches of 25 samples, the first arriving at `first`, one every 100 ms (250 Hz to the sample); O1
    counts up from value0 + 1 µV."""
    folder.mkdir(parents=True, exist_ok=True)
    n = batches * 25
    rec = np.zeros(n, dtype=[("pack", "<u4"), ("v", "<f4", (4,))])
    rec["pack"] = np.arange(n)
    rec["v"][:, 0] = (value0 + 1 + np.arange(n)) * 1e-6
    f32 = folder / f"{start.strftime('%Y-%m-%d-%H%M%S')}.f32"
    rec.tofile(f32)
    idx = np.zeros(batches, dtype=[("t", "<f8"), ("i", "<u8")])
    idx["t"] = first.timestamp() + 0.1 * np.arange(batches)
    idx["i"] = 25 * np.arange(batches)
    idx.tofile(f32.with_suffix(".idx"))
    rc.write(f32, dataclasses.replace(rc.diy_board(NAMES, 250, layout="test"), recording=recording))
    return f32


def gaps(notes: list[tuple[float, float, str]]) -> list[tuple[float, float]]:
    return [(round(a, 3), round(d, 3)) for a, d, t in notes if t == "BAD_gap"]


def test_the_next_set_of_the_same_recording_40_ms_late_has_no_held_samples(tmp_path: Path) -> None:
    a = make_set(tmp_path, T0, ms(100), 100, 0, "r1")
    b = make_set(tmp_path, ms(10000), ms(10140), 100, 2500, "r1")
    start, uv, notes = to_bdf.join([a, b])
    assert gaps(notes) == []
    assert len(uv) == 5000
    assert np.allclose(uv[:, 0], np.arange(5000) + 1, atol=1e-3)  # every sample once, in order, none held


def test_40_ms_early_changes_nothing(tmp_path: Path) -> None:
    a = make_set(tmp_path, T0, ms(100), 100, 0, "r1")
    b = make_set(tmp_path, ms(10000), ms(10060), 100, 2500, "r1")
    _, uv, notes = to_bdf.join([a, b])
    assert gaps(notes) == [] and len(uv) == 5000


def test_a_real_gap_stays_a_gap(tmp_path: Path) -> None:
    a = make_set(tmp_path / "late", T0, ms(100), 100, 0, "r1")
    late = make_set(tmp_path / "late", ms(10000), ms(10700), 100, 2500, "r1")  # 0.6 s of nothing
    assert gaps(to_bdf.join([a, late])[2]) == [(10.0, 0.6)]

    a = make_set(tmp_path / "other", T0, ms(100), 100, 0, "r1")
    other = make_set(tmp_path / "other", ms(11000), ms(10140), 100, 2500, "r2")  # another recording
    assert gaps(to_bdf.join([a, other])[2]) == [(10.0, 0.04)]

    x = make_set(tmp_path / "old", T0, ms(100), 100, 0, None)  # sets from before Record first
    y = make_set(tmp_path / "old", ms(10000), ms(10140), 100, 2500, None)
    assert gaps(to_bdf.join([x, y])[2]) == [(10.0, 0.04)]


def test_a_window_across_the_seam_is_one_stretch(tmp_path: Path) -> None:
    a = make_set(tmp_path, T0, ms(100), 100, 0, "r1")
    b = make_set(tmp_path, ms(10000), ms(10140), 100, 2500, "r1")
    _, uv, notes = to_bdf.join([a, b], [(ms(8000).timestamp(), ms(12000).timestamp())])
    assert gaps(notes) == []
    assert np.allclose(uv[:, 0], 2000 + np.arange(1000) + 1, atol=1e-3)
    # two windows, the second inside the second set: the time between them is missing, as between any two windows
    _, uv, notes = to_bdf.join([a, b], [(ms(2000).timestamp(), ms(4000).timestamp()),
                                        (ms(14000).timestamp(), ms(16000).timestamp())])
    assert gaps(notes) == [(2.0, 10.0)]
    assert abs(uv[3000, 0] - 3501) < 1e-3


def test_three_sets_in_a_row_are_one_chain(tmp_path: Path) -> None:
    a = make_set(tmp_path, T0, ms(100), 50, 0, "r1")
    b = make_set(tmp_path, ms(5000), ms(5130), 50, 1250, "r1")
    c = make_set(tmp_path, ms(10000), ms(10160), 50, 2500, "r1")
    _, uv, notes = to_bdf.join([a, b, c])
    assert gaps(notes) == [] and len(uv) == 3750
    assert len(to_bdf.runs(b)) == 1  # one file's own runs are as before
