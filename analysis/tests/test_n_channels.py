"""Recordings with any number of channels through the laptop readers (docs/data-format.md "The recording header"):
night_files (record size per file), to_bdf (N labelled signals; a night of mixed channel sets refused), the sleep
scorer and the sleep report (O1 O2 T3 T4 picked by name or site; refused in words without them). Old files, with no
header, read as before."""
import json
import struct
from datetime import datetime, timedelta
from pathlib import Path

import mne
import numpy as np
import pytest

import nch_files as nch
import night_files as nf
import packed
import recording as rc
import score_sleep
import sleep_report as sr
import to_bdf

T0 = datetime(2026, 11, 20, 1, 2, 3)
BB = ("O1", "O2", "T3", "T4")


# ---- night_files: the record size and rate of each file -------------------------------------------------------

def test_minutes_come_from_each_files_own_record_and_rate(tmp_path: Path) -> None:
    nch.write_set(tmp_path, T0, nch.volts(250 * 60, 8), nch.EIGHT)  # 1 min of 8 channels at 250 Hz
    nch.write_set(tmp_path, T0 + timedelta(minutes=5), nch.volts(500 * 120, 16), tuple(f"C{i}" for i in range(16)),
                  fs=500)  # 2 min of 16 channels at 500 Hz
    nch.write_set(tmp_path, T0 + timedelta(minutes=10), nch.volts(250 * 180, 4), BB, how="none")  # 3 min, old file
    nch.write_set(tmp_path, T0 + timedelta(minutes=15), nch.volts(250 * 240, 6), tuple("ABCDEF"), how="log")  # 4 min
    recs = nf.recordings(tmp_path)
    assert [round(r.minutes, 6) for r in recs] == [1.0, 2.0, 3.0, 4.0]
    assert [(r.rec_bytes, r.fs) for r in recs] == [(36, 250), (68, 500), (20, 250), (28, 250)]


def test_a_work_sessions_raw_eeg_is_no_night_and_never_scored_as_sleep(tmp_path: Path) -> None:
    """The phone's work session keeps its raw EEG beside the nights (DECISIONS 683); its header says `session: work`.
    A night's morning: the work recording at 09:00 would chain into the night by its evening date."""
    from dataclasses import replace
    work_header = replace(rc.brainbit(made_by="eeg_tracker app"), session="work")
    night = nch.write_set(tmp_path, datetime(2026, 11, 19, 23), nch.volts(250 * 60, 4), BB, header=rc.brainbit())
    nap = nch.write_set(tmp_path, datetime(2026, 11, 20, 0, 30), nch.volts(250 * 60, 4), BB,
                        header=replace(rc.brainbit(), session="nap"))
    work = nch.write_set(tmp_path, datetime(2026, 11, 20, 9), nch.volts(250 * 120, 4), BB, header=work_header)
    assert rc.read(work).session == "work" and not rc.read(work).is_sleep
    assert rc.read(night).is_sleep and rc.read(nap).is_sleep
    recs = nf.recordings(tmp_path)
    assert [r.path for r in recs] == [night, nap]
    (n,) = nf.nights(recs)
    assert n.name == "2026-11-19" and work not in [r.path for r in n.recs]
    packed.pack(work)  # packed after a day as any recording: still no night
    assert [r.path for r in nf.recordings(tmp_path)] == [night, nap]


def test_a_file_shorter_than_one_of_its_records_is_no_recording(tmp_path: Path) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(1, 8), nch.EIGHT)
    assert len(nf.recordings(tmp_path)) == 1
    f.write_bytes(bytes(20))  # a whole BrainBit record, but not one of this file's 36-byte records
    assert nf.recordings(tmp_path) == []


def test_the_end_without_an_index_uses_the_files_rate(tmp_path: Path) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(500 * 60, 8), nch.EIGHT, fs=500)
    f.with_suffix(".idx").unlink()
    (r,) = nf.recordings(tmp_path)
    assert r.end == T0.timestamp() + 60


def test_out_of_date_counts_minutes_by_each_files_record(tmp_path: Path) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(250 * 60 * 11, 8), nch.EIGHT)
    night = nf.Night("2026-11-19", nf.recordings(tmp_path))
    rep = {"version": nf.VERSION, "drift_off": None, "rem_check": None,
           "inputs": [{"file": f.name, "bytes": 36 * 250 * 60 * 2}]}
    assert not nf.is_stale(night, rep)  # 9 min newer: 4 860 000 bytes, which 20-byte records would call 16 min
    rep["inputs"][0]["bytes"] = 36 * 250 * 60
    assert nf.is_stale(night, rep)  # 10 min newer


def test_a_damaged_header_stops_the_listing_and_names_the_file(tmp_path: Path) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(250, 4), BB, how="none")
    f.with_suffix(".header.json").write_text("{")
    with pytest.raises(rc.HeaderError, match="2026-11-20-010203.header.json"):
        nf.recordings(tmp_path)
    bad: list[tuple[Path, Exception]] = []
    assert nf.recordings(tmp_path, on_bad=lambda p, e: bad.append((p, e))) == []
    assert [p.name for p, _ in bad] == ["2026-11-20-010203.f32"]


# ---- to_bdf ---------------------------------------------------------------------------------------------------

def test_old_files_read_as_before(tmp_path: Path) -> None:
    v = nch.volts(1000, 4)
    f = nch.write_set(tmp_path, T0, v, BB, how="none")
    uv, idx = to_bdf.load(f)
    assert uv.shape == (1000, 4) and np.array_equal(uv, v.astype(np.float64) * 1e6) and len(idx) == 4
    start, joined, notes = to_bdf.join([f])
    assert start == T0 and np.array_equal(joined, uv) and notes == []


@pytest.mark.parametrize("how", ["header", "log"])
def test_an_eight_channel_night_becomes_a_bdf_with_its_eight_labels(tmp_path: Path, how: str) -> None:
    names = ("Fz", "O1", "O2", "T7", "T8", "C3", "C4", "Pz")
    a = nch.volts(250 * 20, 8, seed=1); b = nch.volts(250 * 10, 8, seed=2)
    fa = nch.write_set(tmp_path, T0, a, names, how=how)
    fb = nch.write_set(tmp_path, T0 + timedelta(seconds=30), b, names, how=how)
    uv, _ = to_bdf.load(fa)
    assert uv.shape == (5000, 8) and np.array_equal(uv, a.astype(np.float64) * 1e6)
    assert to_bdf.night_header([fa, fb]).names == names
    start, joined, notes = to_bdf.join([fa, fb])
    assert joined.shape == (250 * 40, 8) and [n for n in notes if n[2] == "BAD_gap"] == [(20.0, 10.0, "BAD_gap")]
    assert np.array_equal(joined[-2500:], b.astype(np.float64) * 1e6)
    dst = tmp_path / "night.bdf"
    to_bdf.write(dst, start, joined, notes, names=names)
    raw = mne.io.read_raw_bdf(dst, preload=True, verbose="error")
    assert raw.ch_names == list(names) and raw.info["sfreq"] == 250
    got = raw.get_data(units="uV")
    assert got.shape == (8, 250 * 40) and np.allclose(got[:, :5000].T, a.astype(np.float64) * 1e6, atol=0.06)  # 24-bit step


def test_the_command_writes_n_channels_at_the_files_rate(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(500 * 20, 16), tuple(f"E{i}" for i in range(1, 17)), fs=500)
    packed.pack(f)
    import sys
    argv, sys.argv = sys.argv, ["to_bdf.py", str(f)]
    try:
        to_bdf.main()
    finally:
        sys.argv = argv
    raw = mne.io.read_raw_bdf(f.with_suffix(".bdf"), preload=False, verbose="error")
    assert raw.ch_names == [f"E{i}" for i in range(1, 17)] and raw.info["sfreq"] == 500 and raw.n_times == 500 * 20
    out = capsys.readouterr().out
    assert "0.01 h" in out and "  E16: at the rail" in out and "O1" not in out


def test_files_of_one_night_with_other_channels_are_refused(tmp_path: Path) -> None:
    fa = nch.write_set(tmp_path, T0, nch.volts(500, 4), BB, how="none")
    fb = nch.write_set(tmp_path, T0 + timedelta(seconds=30), nch.volts(500, 8), nch.EIGHT)
    with pytest.raises(rc.RecordingError) as e:
        to_bdf.join([fa, fb])
    text = str(e.value)
    assert "2026-11-20-010203.f32" in text and "O1 O2 T3 T4" in text and "2026-11-20-010233.f32" in text
    assert "Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 Ch8" in text and "same channels" in text
    fc = nch.write_set(tmp_path, T0 + timedelta(seconds=60), nch.volts(500, 4), BB, fs=500)
    with pytest.raises(rc.RecordingError, match="250 Hz.*500 Hz"):
        to_bdf.join([fa, fc])


def test_the_bdf_refuses_a_label_it_cannot_hold(tmp_path: Path) -> None:
    with pytest.raises(rc.RecordingError, match="16"):
        to_bdf.write(tmp_path / "x.bdf", T0, np.zeros((250, 1)), [], names=("a name of more than sixteen",))


def test_join_sites_gives_the_four_the_detectors_read_by_name(tmp_path: Path) -> None:
    v = nch.volts(1000, 8)
    f = nch.write_set(tmp_path, T0, v, nch.MIXED)
    _, uv, _ = to_bdf.join_sites([f], BB, "the detector pass")
    assert np.array_equal(uv, v[:, [4, 2, 5, 1]].astype(np.float64) * 1e6)
    g = nch.write_set(tmp_path, T0 + timedelta(hours=1), nch.volts(1000, 8), nch.EIGHT)
    with pytest.raises(rc.MissingChannels, match=r"the detector pass needs O1 O2 T3 T4; this recording \(DIY board: Ch1 .* Ch8\) has no O1, O2, T3, T4"):
        to_bdf.join_sites([g], BB, "the detector pass")
    h = nch.write_set(tmp_path, T0 + timedelta(hours=2), nch.volts(1000, 4), BB, fs=500)
    with pytest.raises(rc.RecordingError, match="250 Hz.*500 Hz"):
        to_bdf.join_sites([h], BB, "the detector pass")


# ---- the sleep scorer -----------------------------------------------------------------------------------------

def raw_of(names: tuple[str, ...], data: np.ndarray) -> mne.io.RawArray:
    return mne.io.RawArray(data, mne.create_info(list(names), 250, "eeg"), verbose="error")


def test_the_model_reads_o1_o2_t3_t4_by_name_or_site_wherever_they_are() -> None:
    rng = np.random.default_rng(nch.SEED)
    four = rng.normal(0, 20e-6, (4, 250 * 60)) * np.array([[1.0], [2.0], [3.0], [4.0]])
    other = rng.normal(0, 500e-6, (4, 250 * 60))
    want = score_sleep.prepare(raw_of(BB, four))
    mixed = np.stack([other[0], four[3], four[1], other[1], four[0], four[2], other[2], other[3]])
    assert np.array_equal(score_sleep.prepare(raw_of(nch.MIXED, mixed)), want)
    lead = np.vstack([other[:1], four])
    assert np.array_equal(score_sleep.prepare(raw_of(("Fz", "O1", "O2", "T7", "T8"), lead)), want)
    r = score_sleep.sleep_channels(raw_of(nch.MIXED, mixed))
    assert r.ch_names == list(BB) and np.array_equal(r.get_data(), four)


def test_the_scorer_refuses_a_night_without_the_four_sites_in_words(tmp_path: Path) -> None:
    f = nch.write_set(tmp_path, T0, nch.volts(250 * 320, 8), nch.EIGHT)
    start, uv, notes = to_bdf.join([f])
    bdf = tmp_path / "night.bdf"
    to_bdf.write(bdf, start, uv, notes, names=nch.EIGHT)
    with pytest.raises(rc.MissingChannels) as e:
        score_sleep.score(bdf, tmp_path / "no-model-needed")
    assert str(e.value) == ("the sleep model needs O1 O2 T3 T4; this recording (Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 Ch8) has no "
                            "O1, O2, T3, T4")


# ---- the sleep report -----------------------------------------------------------------------------------------

@pytest.fixture
def scorer(monkeypatch: pytest.MonkeyPatch) -> list[np.ndarray]:
    """score_sleep.score with the model replaced: it keeps what the model would be given (prepare's output)."""
    seen: list[np.ndarray] = []

    def score(bdf: Path, repo: Path, device: str = "cpu", progress=print) -> dict:
        raw = mne.io.read_raw_bdf(bdf, preload=True, verbose="error")
        seen.append(score_sleep.prepare(raw))
        n_ep = int(raw.n_times / raw.info["sfreq"] // 30)
        start = raw.info["meas_date"].replace(tzinfo=None)
        stage = (["W"] * 2 + ["N2"] * 10)[:n_ep] + ["N2"] * max(0, n_ep - 12)
        return dict(source=bdf.name, start=start.isoformat(), epoch_s=30,
                    summary=score_sleep.summary(stage, np.zeros(n_ep, bool), stage, np.full(n_ep, 0.6)),
                    epochs=[dict(t=(start + timedelta(seconds=30 * i)).isoformat(timespec="seconds"), anysleep=s, yasa=s,
                                 p=[0.6, 0.1, 0.1, 0.1, 0.1]) for i, s in enumerate(stage)])

    monkeypatch.setattr(score_sleep, "score", score)
    return seen


def run_report(tmp_path: Path, *more: str) -> tuple[int, Path, Path]:
    rec, nights = tmp_path / "recordings", tmp_path / "nights"
    code = sr.main(["--recordings", str(rec), "--nights", str(nights), "--export", str(tmp_path / "export"), *more])
    return code, rec, nights


def test_the_sleep_report_refuses_an_eight_channel_night_without_the_sites(tmp_path: Path, scorer: list,
                                                                          capsys: pytest.CaptureFixture) -> None:
    rec = tmp_path / "recordings"; rec.mkdir()
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=40)
    nch.write_set(rec, start, nch.volts(250 * 60 * 12, 8), nch.EIGHT)
    code, _, nights = run_report(tmp_path)
    said = "the sleep model needs O1 O2 T3 T4; this recording (DIY board: Ch1 Ch2 Ch3 Ch4 Ch5 Ch6 Ch7 Ch8) has no O1, O2, T3, T4"
    assert code == 1 and scorer == []
    assert said in capsys.readouterr().out
    assert not list(nights.glob("*.bdf")) and not list(nights.glob("*.report.json"))  # nothing scored, nothing written
    status = json.loads((nights / nf.STATUS).read_text())
    assert status["state"] == "failed" and said in status["error"]


def test_the_sleep_report_scores_the_four_sites_of_an_eight_channel_night(tmp_path: Path, scorer: list) -> None:
    rec = tmp_path / "recordings"; rec.mkdir()
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=40)
    v = nch.volts(250 * 60 * 12, 8)
    nch.write_set(rec, start, v, nch.MIXED)
    four = tmp_path / "four" / "recordings"; four.mkdir(parents=True)
    nch.write_set(four, start, v[:, [4, 2, 5, 1]], BB, how="none")  # the same four as an old BrainBit file
    code, _, nights = run_report(tmp_path)
    code4, _, nights4 = run_report(tmp_path / "four")
    assert code == 0 and code4 == 0 and len(scorer) == 2
    assert np.array_equal(scorer[0], scorer[1])  # the model was given the same O1 O2 T3 T4
    name = nf.evening_date(start.timestamp())
    rep, rep4 = (json.loads((d / f"{name}.report.json").read_text()) for d in (nights, nights4))
    assert rep["scored"] and rep["extras_error"] is None and rep["drift_off_error"] is None
    for key in ("periods", "total", "extras", "drift_off", "stages", "probs"):  # the detectors read the same four too
        assert rep[key] == rep4[key], key
    eye, eye4 = rep["rem_check"]["eye"], rep4["rem_check"]["eye"]  # the eye pair by its own names: T7 T8 are T3 T4
    assert (eye["pair"], eye4["pair"]) == ("T7-T8", "T3-T4") and eye["epochs"] == eye4["epochs"]
    assert {**eye, "pair": None} == {**eye4, "pair": None}
    raw = mne.io.read_raw_bdf(nights / f"{name}.bdf", preload=False, verbose="error")
    assert raw.ch_names == list(nch.MIXED)  # the night's BDF keeps every channel under its own name
    assert rep["inputs"] == [{"file": f"{start:%Y-%m-%d-%H%M%S}.f32", "bytes": 36 * 250 * 60 * 12}]
    assert not nf.is_stale(nf.recent_nights(rec, datetime.now().timestamp())[0], rep)


def test_one_refused_night_does_not_stop_the_others(tmp_path: Path, scorer: list) -> None:
    rec = tmp_path / "recordings"; rec.mkdir()
    now = datetime.now().replace(microsecond=0)
    nch.write_set(rec, now - timedelta(hours=40), nch.volts(250 * 60 * 6, 8), nch.EIGHT)  # another night: 40 h before
    good = now - timedelta(minutes=30)
    nch.write_set(rec, good, nch.volts(250 * 60 * 12, 4), BB, how="none")
    code, _, nights = run_report(tmp_path, "--hours", "60")
    assert code == 1 and len(scorer) == 1
    assert (nights / f"{nf.evening_date(good.timestamp())}.report.json").is_file()


# ---- packing: the header stays plain, the packed .f32 reads by it -----------------------------------------------

def test_the_daily_packing_leaves_the_header_plain_and_the_readers_read_on(tmp_path: Path) -> None:
    import os, time
    import pack_old
    rec = tmp_path / "_local" / "recordings-diy"; rec.mkdir(parents=True)
    v = nch.volts(250 * 60, 8)
    f = nch.write_set(rec, T0, v, nch.EIGHT)
    head = f.with_suffix(".header.json").read_bytes()
    before = nf.recordings(rec)
    old = time.time() - 2 * 86400
    for p in rec.iterdir():
        os.utime(p, (old, old))
    lines: list[str] = []
    assert pack_old.main(["--local", str(tmp_path / "_local")], out=lines.append) == 0, lines
    assert sorted(p.name for p in rec.iterdir()) == [f"{f.stem}{s}" for s in (".f32.xz", ".header.json", ".idx")]
    assert f.with_suffix(".header.json").read_bytes() == head  # only the .f32 is packed
    assert nf.recordings(rec) == before and before[0].rec_bytes == 36
    uv, _ = to_bdf.load(f)
    assert np.array_equal(uv, v.astype(np.float64) * 1e6)
    assert to_bdf.night_header([rec / f"{f.stem}.f32.xz"]).names == nch.EIGHT
