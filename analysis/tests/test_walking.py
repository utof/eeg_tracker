"""Walking, pace and steps from the headband's own signal (analysis/walking.py), the laptop's walk files
(scripts/walks.py) and the made-up recordings shared with the phone's port (analysis/make_walking_fixture.py,
app/test/fixtures/walking.json; app/test/walking_cross_check_test.dart)."""
import base64
import gzip
import importlib.util
import json
import math
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

import nch_files as nch
import walking as wk

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("make_walking_fixture", ROOT / "analysis" / "make_walking_fixture.py")
mwf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mwf)
spec = importlib.util.spec_from_file_location("walks", ROOT / "scripts" / "walks.py")
walks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walks)


def found_of(make):
    x, fs, miss, readings, info = make()
    return wk.find(wk.windows(x, fs, miss)), info


# ---- the method ------------------------------------------------------------------------------------------------

def _epochs_by_stretches(found: wk.Found, n: int) -> list[bool]:
    """Walking per epoch from the whole recording's stretches: the rule epoch_walks reads locally."""
    moving = {i for s in found.moving for i in range(s.first, s.last + 1)}
    return [sum(i in moving for i in range(max(0, 6 * e - 1), 6 * e + 5)) >= 3 for e in range(n)]


def test_walking_per_epoch_is_half_or_more_of_it_in_a_walking_stretch():
    found, _ = found_of(mwf.four_channels)  # 250 s: a walk 15-95 s, a stop, a run 160-240 s
    flags = wk.epoch_flags(found.windows, 8)
    assert flags == [True, True, True, False, False, True, True, True]
    assert flags == _epochs_by_stretches(found, 8)
    assert wk.epoch_flags(found.windows, 12)[8:] == [False] * 4  # past the signal: not walking
    assert wk.epoch_flags([], 3) == [False] * 3


def test_walking_per_epoch_reads_only_the_windows_near_it():
    rng = np.random.default_rng(5)
    for _ in range(30):
        raw = []
        while len(raw) < 400:  # runs of walking and not, 1 to 20 windows long
            raw += [bool(rng.integers(2))] * int(rng.integers(1, 21))
        ws = [wk.Window(5.0 * i + 5, 8.0 if f else 1.0, 110.0, 500.0, 4, True, 0.5) for i, f in enumerate(raw)]
        n = len(ws) // 6
        want = _epochs_by_stretches(wk.find(ws), n)
        assert wk.epoch_flags(ws, n) == want
        # the live scorer at epoch e knows the windows up to 2 minutes past it: the same answer
        for e in range(0, n - 4, 7):
            assert wk.epoch_walks(raw[:6 * (e + 5)], e) == want[e]


def test_quick_windows_walk_exactly_where_the_full_ones_do():
    skipped = 0
    for make in mwf.CASES.values():
        x, fs, miss, _, _ = make()
        full, quick = wk.windows(x, fs, miss), wk.windows(x, fs, miss, quick=True)
        assert [w.walks for w in quick] == [w.walks for w in full]
        assert [(w.t, w.read, w.channels) for w in quick] == [(w.t, w.read, w.channels) for w in full]
        skipped += sum(w.read and math.isnan(w.score) for w in quick)  # under walking size: no spectrum worked out
        assert all(math.isnan(q.score) or q.score == f.score for q, f in zip(quick, full))
    assert skipped > 10


def test_the_veto_scores_walking_sleep_awake_and_nothing_else():
    stages = ["W", "N1", "N2", "N3", "R", "gap", "N2", "N2"]
    out, changed = wk.veto(stages, [True, True, True, True, True, True, False])
    assert out == ["W", "W", "W", "W", "W", "gap", "N2", "N2"] and changed == 4
    assert stages[1] == "N1"  # a copy
    assert wk.veto(stages, []) == (stages, 0)


def test_a_walk_a_stop_and_a_run_on_four_channels():
    found, info = found_of(mwf.four_channels)
    kinds = [s.kind for s in found.moving]
    assert kinds == ["walking", "running"]
    walk, run = found.moving
    assert abs(walk.pace - 112) <= 2 and abs(run.pace - 162) <= 2
    # steps within 10 % of the drawn ones (the run 15 %: its 3 s hole and one window read at the stride are not
    # counted); running is told apart by its pace held over 150 a minute
    assert abs(walk.steps - info["walked"]) <= 0.1 * info["walked"]
    assert abs(run.steps - info["ran"]) <= 0.15 * info["ran"]
    (w,) = found.walks  # 65 s apart: one walk with a stop between
    assert [s.kind for s in w.stretches] == ["walking", "stopped", "running"]
    assert w.stopped_s >= wk.MIN_STOP_S and w.walking_s == walk.seconds() + run.seconds()
    assert walk.confidence == "sure" and run.confidence == "sure"


def test_a_hole_in_the_signal_is_not_read_and_never_walking():
    x, fs, miss, _, _ = mwf.four_channels()
    ws = wk.windows(x, fs, miss)
    holes = [w for w in ws if not w.read]
    assert holes and all(not w.walks and math.isnan(w.score) and w.channels == 0 for w in holes)
    for w in holes:  # every unread window overlaps the 3 s hole at 200 s
        assert 190 < w.t < 213


def test_any_layout_eight_channels_with_a_dead_and_a_railed_electrode():
    found, info = found_of(mwf.eight_channels)
    (walk,) = found.moving
    assert walk.kind == "walking" and abs(walk.pace - 104) <= 2
    assert abs(walk.steps - info["walked"]) <= 0.1 * info["walked"]
    used = {w.channels for w in found.windows}
    assert used == {6, 7}  # the dead one never; the railed one not while at the rails


def test_another_rate_uses_finer_bins_of_the_same_width():
    assert wk.nfft_for(250) == 8192 and wk.whiten_bins(250) == 41
    assert wk.nfft_for(500) == 16384 and wk.whiten_bins(500) == 41
    assert wk.nfft_for(256) == 16384 and wk.whiten_bins(256) == 81
    found, _ = found_of(mwf.fast_rate)
    (walk,) = found.moving
    assert abs(walk.pace - 120) <= 2


def test_rest_alone_never_walks():
    x = mwf.background(4, 300, 250, seed=5)
    found = wk.find(wk.windows(x, 250))
    assert found.moving == [] and found.walks == []
    assert max(w.score for w in found.windows) < wk.SCORE_WALK


def test_a_single_channel_works_too():
    x = mwf.background(1, 90, 250, seed=6)
    mwf.add_steps(x, 250, 10, 80, 116, 400, seed=7)
    found = wk.find(wk.windows(x, 250))
    assert [s.kind for s in found.moving] == ["walking"] and abs(found.moving[0].pace - 116) <= 2


def test_a_pulse_is_not_walking_however_rhythmic():
    """A sleeping heart (about 57 a minute) shows as a family at 57, 115 and 172 a minute; the score's grid starts at
    72, so it reads the pulse as 115 or 172 (the sleep false positives of walk-v1, DECISIONS 801)."""
    x = mwf.background(4, 120, 250, seed=8)
    mwf.add_pulse(x, 250, 0, 120, 57, 40)  # a small pulse: rhythmic, but no walking-sized shake
    ws = wk.windows(x, 250)
    strong = [w for w in ws if w.score >= wk.SCORE_WALK and wk.PACE_MIN_SPM <= w.pace <= wk.PACE_MAX_SPM]
    assert len(strong) > len(ws) // 2 and all(w.amp < wk.MIN_SHAKE_UV for w in strong)
    assert wk.find(ws).moving == []
    y = mwf.background(4, 120, 250, seed=9)
    mwf.add_pulse(y, 250, 0, 120, 58, 150)  # large, read at 3 times its rate: the family at a third and two thirds
    ws = wk.windows(y, 250)
    big = [w for w in ws if w.score >= wk.SCORE_WALK and w.amp >= wk.MIN_SHAKE_UV]
    assert big and all(abs(w.pace - 174) <= 2 and w.thirds >= wk.MAX_THIRDS for w in big)
    assert wk.find(ws).moving == []


def test_short_runs_are_not_walking_and_walks_split_after_fifteen_minutes():
    def win(walks: bool) -> wk.Window:
        return wk.Window(0, 6.0 if walks else 1.5, 110.0, 400.0, 4, True, 0.1)

    # 5 walking windows (25 s): under 30 s, nothing
    assert wk.find([win(False)] * 10 + [win(True)] * 5 + [win(False)] * 10).moving == []
    # two 1-minute stretches 16 minutes apart: two walks; 5 minutes apart: one walk with a stop
    far = [win(True)] * 12 + [win(False)] * 192 + [win(True)] * 12
    assert len(wk.find(far).walks) == 2
    near = [win(True)] * 12 + [win(False)] * 60 + [win(True)] * 12
    (w,) = wk.find(near).walks
    assert [s.kind for s in w.stretches] == ["walking", "stopped", "walking"] and w.stopped_s == 300
    # a stop with a hole in it is not called a stop (the time is not known)
    hole = [win(True)] * 12 + [win(False)] * 30 + [wk.Window(0, math.nan, math.nan, math.nan, 0, False)] * 30 + \
        [win(True)] * 12
    (w,) = wk.find(hole).walks
    assert [s.kind for s in w.stretches] == ["walking", "walking"] and w.stopped_s == 0


def test_steps_count_only_windows_whose_own_rhythm_is_clear():
    ws = [wk.Window(i * 5.0, 6.0, 120.0, 400.0, 4, True, 0.1) for i in range(12)]
    ws[5] = wk.Window(25.0, 3.0, 120.0, 400.0, 4, True, 0.1)  # a weak window inside the stretch
    (s,) = wk.find(ws).moving
    assert s.first == 0 and s.last == 11
    assert s.steps == pytest.approx(11 * 120 / 60 * 5)  # 11 clear windows of 5 s at 120 a minute


# ---- the phone's step counter ------------------------------------------------------------------------------------

def test_phone_minutes_go_to_the_minute_of_the_middle_never_split():
    t = 1795190400.0  # a whole minute
    readings = [(t + 5, 1000), (t + 65, 1100), (t + 125, 1150), (t + 245, 1270), (t + 305, 1200), (t + 365, 1260),
                (t + 900, 1300)]
    m = wk.phone_minutes(readings)
    assert m == {
        int(t): 100.0,  # 5-65: middle at 35 s
        int(t) + 60: 50.0,  # 65-125
        int(t) + 120: 60.0, int(t) + 180: 60.0,  # 125-245: two minute-long parts
        # 245-305: the counter went down (the phone restarted): nothing; 305-365 again
        int(t) + 300: 60.0,
        # 365-900: over 3 minutes between readings: nothing known
    }


def test_the_phones_steps_win_where_it_counted_and_each_minute_says_its_source():
    ws = [wk.Window(2.5 + 5.0 * i, 6.0, 114.0, 400.0, 4, True, 0.1) for i in range(36)]  # 3 minutes of walking
    found = wk.find(ws)
    start = 1795190400.0 - 2.5 + 2.5  # window centres at 2.5 + 5 i: minute k holds windows 12 k .. 12 k + 11
    rows = wk.minutes(found, start, {1795190400: 118.0, 1795190460: 0.0, 1795190580: 30.0})
    assert [(r.t - 1795190400, r.source, r.steps, r.walking_s) for r in rows] == [
        (0, "phone", 118.0, 60.0),  # the phone counted: its steps
        (60, "headband", pytest.approx(114.0), 60.0),  # the phone lay still: the headband's
        (120, "headband", pytest.approx(114.0), 60.0),  # no reading: the headband's
        (180, "phone", 30.0, 0.0),  # the phone alone (30 steps: not a walking minute)
    ]
    assert rows[0].hb_steps == pytest.approx(114.0) and rows[0].phone == 118.0


def test_the_check_needs_ten_whole_minutes_then_eight_in_ten_right_and_the_totals_close():
    def row(hb: float, ph: float) -> wk.Minute:
        return wk.Minute(0, 60.0, 0.0, hb, hb, ph, ph, "phone", 60.0)

    assert wk.check([row(114, 112)] * 9).status == "unchecked"
    ok = wk.check([row(114, 112)] * 8 + [row(140, 112)] * 2)
    assert (ok.paired, ok.right, ok.status) == (10, 8, "passed")
    assert wk.check([row(114, 112)] * 7 + [row(140, 112)] * 3).status == "failed"  # 7 of 10
    assert wk.check([row(57, 112)] * 10).status == "failed"  # half the pace (the stride): wrong every minute
    # a minute the headband walked only part of, or the phone counted under 60, is no pair
    part = wk.Minute(0, 30.0, 0.0, 57, 114, 112, 112, "phone", 60.0)
    few = wk.Minute(0, 60.0, 0.0, 114, 114, 20, 20, "phone", 60.0)
    assert wk.check([part, few] * 10).paired == 0


# ---- the laptop's walk files -------------------------------------------------------------------------------------

def write_walk_set(folder: Path, start: datetime, steps: list[tuple[float, int]] | None = None) -> Path:
    x, fs, _, _, _ = mwf.four_channels()
    f32 = nch.write_set(folder, start, (x.T * 1e-6).astype("<f4"), ("O1", "O2", "T3", "T4"), fs=int(fs))
    if steps is not None:
        lines = [f"{start.isoformat(timespec='milliseconds')} phone step counter: on"]
        lines += [f"{(start + timedelta(seconds=t)).isoformat(timespec='milliseconds')} phone steps {c}"
                  for t, c in steps]
        f32.with_suffix(".log").write_text("\n".join(lines) + "\n")
    return f32


def test_a_walk_file_from_a_recording_with_the_phones_lines(tmp_path: Path):
    start = datetime(2026, 11, 20, 19, 0, 0)
    f32 = write_walk_set(tmp_path, start, [(4, 50000), (64, 50098), (124, 50110), (184, 50110)])
    d = walks.walk_files([f32])
    assert d["format"] == "eeg-tracker-walking" and d["detector"] == wk.VERSION
    assert d["recording"] == f32.stem and d["channels"] == ["O1", "O2", "T3", "T4"] and d["sample_rate"] == 250
    assert d["phone_counter"] == "on"
    (w,) = d["walks"]
    assert [s["kind"] for s in w["stretches"]] == ["walking", "stopped", "running"]
    first = d["minutes"][0]
    assert first[0] == int(start.timestamp()) and first[5] == 98 and first[7] == "phone"
    assert d["steps"] == d["steps_phone"] + d["steps_headband"] and d["steps_phone"] == 110
    assert datetime.fromisoformat(w["start"]).tzinfo is not None
    out = walks.write(tmp_path / "walking", d, walks.key_of([f32]))
    assert json.loads(out.read_text())["key"].startswith(wk.VERSION)


def test_all_groups_sets_as_the_archive_does(tmp_path: Path):
    rec = tmp_path / "recordings"
    rec.mkdir()
    a = write_walk_set(rec, datetime(2026, 11, 20, 19, 0, 0))
    b = write_walk_set(rec, datetime(2026, 11, 20, 19, 10, 0))  # 6 minutes after a's end: joins it
    c = write_walk_set(rec, datetime(2026, 11, 20, 21, 0, 0))  # its own
    assert [[r.path for r in g] for g in walks.groups(rec)] == [[a, b], [c]]


# ---- the phone's cross-check fixture -------------------------------------------------------------------------------

def _close(a, b, where: str) -> None:
    if isinstance(a, list):
        assert isinstance(b, list) and len(a) == len(b), where
        for i, (x, y) in enumerate(zip(a, b)):
            _close(x, y, f"{where}[{i}]")
    elif isinstance(a, dict):
        assert isinstance(b, dict) and a.keys() == b.keys(), where
        for k in a:
            if k == "signal":  # zlib versions pack the same bytes differently: compare what they hold
                assert gzip.decompress(base64.b64decode(a[k])) == gzip.decompress(base64.b64decode(b[k])), where
            else:
                _close(a[k], b[k], f"{where}.{k}")
    elif isinstance(a, float) and isinstance(b, (int, float)) and not isinstance(b, bool):
        assert math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9), f"{where}: {a} != {b}"
    else:
        assert a == b, f"{where}: {a!r} != {b!r}"


def test_the_fixture_matches_the_python_reference():
    """Fails when walking.py changed and the fixture was not made again: the phone's port is checked against it."""
    have = json.loads(mwf.OUT.read_text())
    _close(have, json.loads(mwf.text()), "walking.json")
    for c in have["cases"]:
        assert c["moving"], c["name"]
    assert {c["sample_rate"] for c in have["cases"]} == {250, 500}
    assert {len(c["channels"]) for c in have["cases"]} == {4, 8}
    assert any(s["kind"] == "running" for c in have["cases"] for s in c["moving"])
    assert any(m[7] == "phone" for c in have["cases"] for m in c["minutes"])
    # windows with a strong rhythm in the pace range turned down as a pulse: by their size, and by the family alone
    strong = [w for c in have["cases"] for w in c["windows"] if w[1] and w[2] >= 4 and 90 <= w[3] <= 200]
    assert any(not w[7] and w[4] < wk.MIN_SHAKE_UV for w in strong)
    assert any(not w[7] and w[4] >= wk.MIN_SHAKE_UV and w[6] >= wk.MAX_THIRDS for w in strong)
