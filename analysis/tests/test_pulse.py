"""Pulse from the headband's own signal (analysis/pulse.py), the laptop's comparison with a watch
(scripts/compare_pulse.py) and the made-up recordings shared with the phone's port (analysis/make_pulse_fixture.py,
app/test/fixtures/pulse.json; app/test/pulse_cross_check_test.dart)."""
import base64
import gzip
import importlib.util
import json
import math
import sqlite3
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest

import pulse as pl

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("make_pulse_fixture", ROOT / "analysis" / "make_pulse_fixture.py")
mpf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mpf)
spec = importlib.util.spec_from_file_location("compare_pulse", ROOT / "scripts" / "compare_pulse.py")
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

FS = 250.0


def codes(eps: list[pl.Epoch]) -> str:
    return "".join(e.code for e in eps)


# ---- the detector -----------------------------------------------------------------------------------------------


def test_a_pulse_in_noise_is_read_at_its_rate_on_the_electrode_that_shows_it():
    x, fs, miss, _ = mpf.four_channels()
    eps = pl.epochs(x, fs, miss)
    assert len(eps) == 14
    for e in range(6):  # 0-3 minutes: 57 a minute, strongest on T4 (index 3)
        assert eps[e].read and abs(eps[e].bpm - 57) <= 1.0, (e, eps[e])
    assert {e.channel for e in eps[:6]} <= {2, 3} and eps[0].code == "r" and eps[0].conf >= pl.sure_for(4)  # T3, T4
    assert eps[6].code == "g"  # the 3 s hole
    assert eps[7].code == "m"  # big swings: moving
    assert codes(eps[12:]) == "ss"  # steps at 110 a minute, too small for the movement rule


def test_another_rhythm_for_half_a_minute_is_the_odd_one_out_and_its_neighbours_find_the_pulse_under_it():
    x, fs, miss, _ = mpf.four_channels()
    eps = pl.epochs(x, fs, miss)
    assert eps[3].best == pytest.approx(88, abs=1)  # the epoch's own best rate: the other rhythm...
    assert eps[3].code == "n" and abs(eps[3].bpm - 57) <= 1  # ... dropped, and the pulse found with its neighbours


def test_a_weak_pulse_is_read_with_its_neighbours_and_nothing_is_said_without_one():
    x, fs, miss, _ = mpf.four_channels()
    eps = pl.epochs(x, fs, miss)
    assert codes(eps[8:12]) == "rrnu"
    assert pl.NEAR_CONF <= eps[10].conf < pl.sure_for(4)
    assert all(abs(eps[e].bpm - 64) <= 1.5 for e in (8, 9, 10))
    assert math.isnan(eps[11].bpm) and eps[11].channel == -1


@pytest.mark.parametrize("spm", [90, 100, 110, 120, 130])
@pytest.mark.parametrize("uv", [30, 120])
def test_steps_are_never_read_as_a_pulse(spm: int, uv: int):
    x = mpf.background(4, 150, FS, seed=spm + uv)
    mpf.add_steps(x, FS, 0, 150, spm, uv, seed=spm * 7 + uv, gains=[1.0, 0.9, 0.6, 0.7])
    eps = pl.epochs(x, FS)
    assert not any(e.read for e in eps), codes(eps)


def test_big_steps_are_moving_or_walking():
    x = mpf.background(4, 90, FS, seed=3)
    mpf.add_steps(x, FS, 0, 90, 112, 600, seed=4, gains=[1.0, 0.9, 0.6, 0.7])
    assert codes(pl.epochs(x, FS, walking=[False] * 3)) == "mmm"  # by its own movement rule
    assert codes(pl.epochs(x, FS)) == "www"  # the walking detector says more: a walk


def test_no_reading_while_the_walking_detector_says_walking():
    x, fs, miss, _ = mpf.soft_walk()  # a pulse at 60 throughout; a walk on soft steps from 1:02 to 2:50
    eps = pl.epochs(x, fs, miss)
    assert codes(eps) == "rrwwwwrr"
    assert all(math.isnan(e.bpm) and e.channel == -1 for e in eps[2:6])
    assert all(abs(e.bpm - 60) <= 1 for e in eps if e.read)
    # the caller's own answer is taken as given; a gap stays a gap; a walking epoch never carries a neighbour
    told = pl.epochs(x, fs, miss, walking=[True] + [False] * 7)
    assert codes(told)[0] == "w" and "w" not in codes(told)[1:]
    miss[: int(5 * fs)] = True
    assert codes(pl.epochs(x, fs, miss, walking=[True] * 8)) == "g" + "w" * 7
    assert pl.VERSION == "pulse-v2"


def test_noise_alone_gives_no_reading():
    x = mpf.background(4, 1800, FS, seed=100)
    assert set(codes(pl.epochs(x, FS))) == {"u"}


@pytest.mark.parametrize("hz", [50.0, 60.0])
def test_mains_hum_is_no_pulse_and_does_not_hide_one(hz: float):
    x = mpf.background(4, 120, FS, seed=8)
    mpf.add_hum(x, FS, 5000, [1.0, 0.7, 0.4, 0.2], hz=hz)
    # the first epoch may be "moving": the filters start from the first value, and the hum is 1 400 µV off it there
    assert codes(pl.epochs(x, FS))[1:] == "uuu"
    mpf.add_pulse(x, FS, 0, 120, 61, 12, [0.1, 0.1, 1.0, 0.3])
    eps = pl.epochs(x, FS)[1:]
    assert all(e.read and abs(e.bpm - 61) <= 1 for e in eps), codes(eps)


def test_any_layout_eight_channels_with_a_dead_and_a_railed_electrode_and_loud_hum():
    x, fs, miss, _ = mpf.eight_channels()
    eps = pl.epochs(x, fs, miss)
    assert all(e.read and e.channel == 5 and abs(e.bpm - 66) <= 1 for e in eps), [(e.code, e.bpm) for e in eps]
    assert [e.channels for e in eps] == [7, 6, 6, 7]  # the dead one never, the railed one while at the rails


def test_another_rate_and_a_single_channel():
    for make, bpm in ((mpf.fast_rate, 74), (mpf.one_channel, 50)):
        x, fs, miss, _ = make()
        eps = pl.epochs(x, fs, miss)
        assert all(e.read and abs(e.bpm - bpm) <= 1 for e in eps), (make.__name__, codes(eps))
    assert pl.nfft_for(500) == 8192 and pl.whiten_bins(500) == 15 and pl.whiten_bins(250) == 15  # the same bins
    assert pl.nfft_for(256) == 8192 and pl.whiten_bins(256) == 29  # finer bins, the same 0.9 Hz
    assert pl.sure_for(1) == pytest.approx(2.2) and pl.sure_for(4) == pytest.approx(2.4)
    assert pl.sure_for(16) == pytest.approx(2.6)


def test_no_usable_channel_and_a_partial_last_epoch():
    x = np.full((4, int(75 * FS)), 1200.0)
    eps = pl.epochs(x, FS)
    assert codes(eps) == "xx"  # 75 s: two whole epochs, the rest is not an epoch


@pytest.mark.parametrize(("bpm", "code"), [(36, "u"), (39, "u"), (125, "s"), (140, "s")])
def test_a_pulse_outside_the_range_is_never_read_at_another_rate(bpm: int, code: str):
    """Under 42 its 2nd and 4th harmonics look like a pulse at twice its rate, but its own rate shows at half that;
    over 120, half its rate looks like the stride under steps."""
    x = mpf.background(4, 60, FS, seed=12)
    mpf.add_pulse(x, FS, 0, 60, bpm, 20, [1.0, 1.0, 1.0, 1.0], swing=0.0)
    assert codes(pl.epochs(x, FS)) == code * 2


def _ep(code: str, bpm: float = math.nan, peaks=None) -> pl.Epoch:
    return pl.Epoch(code, bpm, 3.0 if code == "r" else 1.9, 0 if code == "r" else -1, best=bpm, channels=4,
                    peaks=peaks or [])


def _i(bpm: float) -> int:
    return round((bpm / 60 - pl.RATE_LO_HZ) / pl.RATE_STEP_HZ)


def test_the_neighbours_rules_on_made_up_epochs():
    eps = [_ep("r", 60), _ep("r", 61), _ep("r", 80, [(1.9, 2, _i(60.6))]), _ep("r", 60.5), _ep("u", math.nan,
           [(2.0, 1, _i(59.7)), (2.9, 0, _i(75))]), _ep("m"), _ep("u", math.nan, [(1.85, 3, _i(66))]),
           _ep("u", math.nan, [(1.9, 0, _i(63))]), _ep("r", 59)]
    pl.neighbours(eps)
    assert codes(eps) == "rrnrnmunr"
    assert eps[2].bpm == pytest.approx(60.6) and eps[2].channel == 2  # the odd one out, found again under it
    assert eps[4].bpm == pytest.approx(59.7) and eps[4].conf == 2.0  # the peak near them, not its stronger one at 75
    assert math.isnan(eps[6].bpm)  # 66 is over 4 from 59-60.5
    assert eps[7].bpm == pytest.approx(63) or abs(eps[7].bpm - 59) <= 4  # only the reading at 59 is within 1 minute


def test_the_odd_one_out_needs_two_agreeing_neighbours():
    eps = [_ep("r", 60), _ep("r", 80), _ep("u"), _ep("u"), _ep("r", 70)]
    pl.neighbours(eps)
    assert codes(eps) == "rruur"  # 60 and 70 disagree: nothing is the odd one


def test_readings_with_their_neighbours_never_carry_another():
    eps = [_ep("r", 60), _ep("u", math.nan, [(1.9, 0, _i(61))]), _ep("u", math.nan, [(1.9, 0, _i(62))]),
           _ep("u", math.nan, [(1.9, 0, _i(62))])]
    pl.neighbours(eps)
    assert codes(eps) == "rnnu"  # the third is 3 epochs from the only reading


# ---- summaries --------------------------------------------------------------------------------------------------


def test_aligned_puts_each_reading_in_the_epoch_holding_its_middle():
    assert pl.aligned(1000.0, [50.0, None, 52.0], 1010.0, 4) == [50.0, None, 52.0, None]
    assert pl.aligned(1000.0, [50.0, 51.0], 1020.0, 2) == [51.0, None]  # the first's middle is before the start
    assert pl.aligned(1000.0, [50.0], 900.0, 3) == [None, None, None]  # past the end


def test_pulse_while_asleep_its_share_and_the_lowest_five_minutes():
    stages = ["W"] * 4 + ["N2"] * 20 + ["R"] * 6
    bpm: list[float | None] = [70.0] * 4 + [None] * 20 + [None] * 6
    for i, v in zip(range(4, 24, 2), [56, 55, 54, 52, 51, 52, 53, 55, 56, 57]):
        bpm[i] = float(v)
    a = pl.asleep(bpm, stages)
    assert (a.epochs, a.read) == (26, 10) and a.share == pytest.approx(10 / 26)
    assert a.median == pytest.approx(54.5)  # the awake 70s never count
    assert a.lowest == pytest.approx(52.0)  # 10 epochs from 8: 54 52 51 52 53
    assert pl.asleep(bpm[:20], stages[:20]).median is None  # 8 readings: too few for a night's number


def test_by_stage_counts_and_medians():
    s = pl.by_stage([60.0, None, 50.0, 52.0], ["W", "W", "N2", "N2"])
    assert s["W"] == (2, 1, 60.0) and s["N2"] == (2, 2, 51.0) and s["N3"] == (0, 0, None)


# ---- the comparison with a watch ---------------------------------------------------------------------------------


def test_reference_formats(tmp_path: Path):
    t0 = datetime(2026, 11, 20, 23, 0, tzinfo=timezone.utc).timestamp()
    gen = tmp_path / "hr.csv"
    gen.write_text("time,bpm\n2026-11-21T02:00:00+03:00,55\n2026-11-21T02:01:00+03:00,0\n1795222920,57\n")
    name, s = cp.read_reference(gen)
    assert name == "CSV/TSV" and s == [(t0, 55.0), (1795222920.0, 57.0)]
    tsv = tmp_path / "hr.tsv"
    tsv.write_text(f"Timestamp\tHeart Rate (bpm)\n{int(t0 * 1000)}\t58\n2026-11-21 02:01:00\t59\n")
    s = cp.read_reference(tsv, cp.offset("+03:00"))[1]
    assert s == [(t0, 58.0), (t0 + 60, 59.0)]

    mi = tmp_path / "20261121_123_MiFitness_hlth_center_fitness_data.csv"
    mi.write_text('\ufeff"Uid,Sid,Key,Time,Value,UpdateTime"\n'
                  f'"1,2,heart_rate,{int(t0)},"{{""time"":{int(t0)},""bpm"":59,""type"":0}}",{int(t0) + 99}"\n'
                  f'1,2,single_heart_rate,{int(t0) + 60},"{{""time"":{int(t0) + 60},""bpm"":61,""timezone"":12}}",0\n'
                  f'1,2,heart_rate,{int(t0) + 120},"{{""time"":{int(t0) + 120},""bpm"":0,""type"":0}}",0\n'
                  '1,2,steps,1,"{}",0\n')
    assert cp.read_reference(mi) == ("Mi Fitness", [(t0, 59.0), (t0 + 60, 61.0)])

    hc = tmp_path / "health_connect_export.db"
    con = sqlite3.connect(hc)
    con.execute("CREATE TABLE heart_rate_record_series_table (parent_key INTEGER, beats_per_minute INTEGER, "
                "epoch_millis INTEGER)")
    con.executemany("INSERT INTO heart_rate_record_series_table VALUES (1, ?, ?)",
                    [(54, int(t0 * 1000)), (56, int(t0 * 1000) + 5000)])
    con.commit()
    con.close()
    assert cp.read_reference(hc) == ("Health Connect", [(t0, 54.0), (t0 + 5, 56.0)])
    zp = tmp_path / "Health Connect.zip"
    with zipfile.ZipFile(zp, "w") as z:
        z.write(hc, "health_connect_export.db")
    assert cp.read_reference(zp)[1] == [(t0, 54.0), (t0 + 5, 56.0)]

    sam = tmp_path / "com.samsung.shealth.tracker.heart_rate.20261121091343.csv"
    p = "com.samsung.health.heart_rate."
    sam.write_text("\ufeffcom.samsung.shealth.tracker.heart_rate,6305105,3\n"
                   f"source,tag_id,{p}start_time,{p}binning_data,{p}time_offset,{p}end_time,{p}heart_rate\n"
                   ",21313,2026-11-20 23:00:00.000,abc.binning_data.json,UTC+0300,2026-11-20 23:59:59.999,60.0,\n"
                   ",21313,2026-11-21 00:00:00.000,,UTC+0300,2026-11-21 00:00:59.999,62.0,\n")
    bins = tmp_path / "jsons" / "com.samsung.shealth.tracker.heart_rate" / "2"
    bins.mkdir(parents=True)
    (bins / "abc.binning_data.json").write_text(json.dumps(
        [{"heart_rate": 57.0, "start_time": int(t0 * 1000), "end_time": int(t0 * 1000) + 59000}]))
    name, s = cp.read_reference(sam)
    assert name == "Samsung Health" and s == [(t0 + 29.5, 57.0), (t0 + 3600 + 29.9995, 62.0)]

    fit = tmp_path / "monitor.csv"
    ft = int(t0) - cp.FIT_EPOCH
    fit.write_text("Type,Local Number,Message,Field 1,Value 1,Units 1,Field 2,Value 2,Units 2\n"
                   "Definition,0,monitoring,timestamp,1,,heart_rate,1,\n"
                   f'Data,0,monitoring,timestamp,"{ft}",s,heart_rate,"53",bpm\n'
                   f'Data,1,monitoring,timestamp_16,"{(ft + 60) & 0xFFFF}",s,heart_rate,"55",bpm\n'
                   f'Data,7,record,timestamp,"{ft + 90}",s,heart_rate,"58",bpm\n')
    assert cp.read_reference(fit) == ("Garmin (FitCSVTool)", [(t0, 53.0), (t0 + 60, 55.0), (t0 + 90, 58.0)])

    xml = tmp_path / "export.xml"
    xml.write_text('<?xml version="1.0"?><HealthData><Record type="HKQuantityTypeIdentifierHeartRate" unit="count/min" '
                   'startDate="2026-11-21 02:00:00 +0300" value="61"/><Record type="HKQuantityTypeIdentifierStepCount" '
                   'startDate="2026-11-21 02:00:00 +0300" value="12"/></HealthData>')
    assert cp.read_reference(xml) == ("Apple Health", [(t0, 61.0)])

    fb = tmp_path / "heart_rate-2026-11-21.json"
    fb.write_text(json.dumps([{"dateTime": "11/21/26 02:00:00", "value": {"bpm": 63, "confidence": 2}},
                              {"dateTime": "11/21/26 02:00:05", "value": {"bpm": 90, "confidence": 0}}]))
    assert cp.read_reference(fb, cp.offset("+03:00")) == ("Fitbit", [(t0, 63.0)])

    bad = tmp_path / "bad.csv"
    bad.write_text("when,what\n1,2\n")
    with pytest.raises(cp.ReferenceError):
        cp.read_reference(bad)


def test_reference_per_epoch_and_agreement():
    samples = [(100.0, 50.0), (110.0, 54.0), (200.0, 60.0)]
    ref = cp.reference_per_epoch(samples, 90.0, 6)
    assert ref == [52.0, 52.0, 60.0, 60.0, 60.0, None]  # each epoch: half a minute before it to half a minute after
    g = cp.agreement([53.0, None, 59.0, 61.0, None, 70.0], ref)
    assert g["pairs"] == 3 and g["reference_epochs"] == 5 and g["read_where_reference"] == 0.6
    assert g["bias"] == pytest.approx(0.33, abs=0.01) and g["within_5"] == 1.0 and g["mae"] == pytest.approx(1.0)
    assert g["loa_low"] < g["bias"] < g["loa_high"]
    assert cp.agreement([None], [50.0]) == dict(pairs=0, reference_epochs=1, read_where_reference=0.0)


def test_a_recording_against_a_made_up_watch(tmp_path: Path, capsys):
    """The whole route: a recording's .f32 files with a pulse at 57, a watch's CSV of the same time, the agreement."""
    import nch_files as nch
    import recording as rc

    x, fs, _, _ = mpf.four_channels()
    start = datetime(2026, 11, 21, 2, 0, 0)
    f32 = nch.write_set(tmp_path, start, (x[:, :int(180 * fs)].T / 1e6).astype("<f4"), ("O1", "O2", "T3", "T4"),
                        header=rc.brainbit())
    t0 = start.timestamp() - 1  # the join's start: the first batch arrives a second after its first sample
    watch = tmp_path / "watch.csv"
    watch.write_text("time,bpm\n" + "".join(f"{datetime.fromtimestamp(t0 + t).isoformat()},{57 + (t // 60) % 2}\n"
                                             for t in range(0, 180, 20)))
    out = tmp_path / "x.pulse.json"
    assert cp.main([str(f32), "--reference", str(watch), "--out", str(out)]) == 0
    text = capsys.readouterr().out
    assert "reference: watch.csv (CSV/TSV)" in text and "within 5: 100 %" in text
    pf = json.loads(out.read_text())
    assert pf["format"] == "eeg-tracker-pulse" and pf["detector"] == pl.VERSION and pf["epochs"] == 6
    assert pf["recording"] == f32.stem and pf["channels"] == ["O1", "O2", "T3", "T4"] and pf["sample_rate"] == 250
    assert pf["read"] == 6 and all(abs(b - 57) <= 1 for b in pf["bpm"]) and pf["channel"][0] in (2, 3)
    r = cp.report([out])  # the file reads back as a recording
    assert r["read"] == 6 and r["median_bpm"] == pf["median_bpm"]


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
    """Fails when pulse.py changed and the fixture was not made again: the phone's port is checked against it."""
    have = json.loads(mpf.OUT.read_text())
    _close(have, json.loads(mpf.text()), "pulse.json")
    assert {c["sample_rate"] for c in have["cases"]} == {250, 500, 256}
    assert {len(c["channels"]) for c in have["cases"]} == {1, 4, 8}
    seen = {e[0] for c in have["cases"] for e in c["epochs"]}
    assert {"r", "n", "u", "g", "m", "s", "w"} <= seen
    walked = next(c for c in have["cases"] if "soft steps" in c["name"])
    assert [e[0] == "w" for e in walked["epochs"]] == walked["walking"] and any(walked["walking"])
