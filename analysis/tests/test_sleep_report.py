"""sleep_report.py: sleep periods from a stages list, nights from recordings, and runs that skip up-to-date nights.

The scorer is replaced by a fake that returns a fixed stages list, so these tests run in seconds without AnySleep;
joining (to_bdf), saving (score_sleep.save) and exporting (export_events) are the real code.
"""
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import fcntl
import mne
import numpy as np
import pytest

import night_files as nf
import score_sleep
import sleep_report as sr

W, N1, N2, N3, R, GAP = "W", "N1", "N2", "N3", "R", "gap"


# ---- periods ----

def test_periods_split_on_an_hour_of_wake_or_missing_data():
    stages = ([W] * 40 + [N2] * 240 + [W] * 14 + [N3] * 60 + [W] * 6 + [R] * 40 + [W] * 60 + [N2] * 20
              + [W] * 80 + [GAP] * 40  # 40 min awake + 20 min missing = 60 min: a new period
              + [N1] * 4 + [N2] * 116 + [W] * 240 + [N1] * 6 + [W] * 10)
    found, stray = sr.periods(stages)
    assert [(p["first"], p["last"]) for p in found] == [(40, 479), (600, 719)]
    night, nap = found
    assert night["asleep_min"] == 180
    assert night["stage_min"] == {"W": 40, "N1": 0, "N2": 130, "N3": 30, "R": 20}
    assert [w["awake_min"] for w in night["wake_ups"]] == [7, 30]  # the 3-minute one is not over 5 min
    assert night["missing_min"] == 0
    assert nap["asleep_min"] == 60 and nap["stage_min"]["N1"] == 2 and nap["wake_ups"] == []
    assert stray == 3  # the 3-minute blip after 2 h awake is too short to be a period


def test_periods_boundaries():
    # 59.5 min of wake joins, 60 min splits
    assert len(sr.periods([N2] * 30 + [W] * 119 + [N2] * 30)[0]) == 1
    assert len(sr.periods([N2] * 30 + [W] * 120 + [N2] * 30)[0]) == 2
    # a wake-up must be over 5 minutes; missing epochs in it do not count as awake
    assert sr.periods([N2] * 30 + [W] * 10 + [N2] * 30)[0][0]["wake_ups"] == []
    assert len(sr.periods([N2] * 30 + [W] * 11 + [N2] * 30)[0][0]["wake_ups"]) == 1
    p = sr.periods([N2] * 30 + [W] * 6 + [GAP] * 20 + [W] * 4 + [N2] * 30)[0][0]
    assert p["wake_ups"] == [] and p["missing_min"] == 10
    # under 10 minutes asleep is not a period
    assert sr.periods([W] * 10 + [N2] * 19 + [W] * 10) == ([], 9.5)
    assert sr.periods([]) == ([], 0.0)


def test_periods_agreement_and_confidence():
    stages = [N2] * 20 + [W] * 2 + [R] * 2
    other = [N2] * 16 + [N3] * 4 + [W] * 2 + [N2] + ["?"]  # "?": YASA gave no stage
    p = sr.periods(stages, other, [0.9] * 12 + [0.5] * 12)[0][0]
    assert p["agreement"] == {"five_stage": round(18 / 23, 3), "wake_nrem_rem": round(22 / 23, 3), "epochs": 23}
    assert p["confidence"] == 0.7


def test_periods_are_the_same_every_time():
    rng = np.random.default_rng(3)
    stages = list(rng.choice([W, N1, N2, N3, R, GAP], size=2000, p=[0.3, 0.05, 0.4, 0.1, 0.1, 0.05]))
    assert sr.periods(stages) == sr.periods(list(stages))


# ---- nights from recordings ----

def _t(day: int, hour: float) -> float:
    return (datetime(2026, 11, day) + timedelta(hours=hour)).timestamp()


def _rec(name: str, start: float, end: float, minutes: float = 10) -> nf.Rec:
    return nf.Rec(Path(name), start, end, int(minutes * 60 * nf.FS) * nf.REC_BYTES)


def test_nights_chain_recordings_and_name_them_by_the_evening():
    recs = [_rec("a", _t(17, 23), _t(18, 2)), _rec("b", _t(18, 2.1), _t(18, 7.5)),
            _rec("c", _t(18, 9), _t(18, 14.3)),  # late-morning sleep, 1.5 h later: same night
            _rec("d", _t(18, 18), _t(18, 19)),  # 3.7 h later and after noon: the next night
            _rec("e", _t(18, 23.5), _t(19, 7))]  # 4.5 h later but the same evening date: joins d
    ns = nf.nights(recs)
    assert [(n.name, [r.path.name for r in n.recs]) for n in ns] == [
        ("2026-11-17", ["a", "b", "c"]), ("2026-11-18", ["d", "e"])]
    # a night never takes a recording that starts 24 h or more after its first one
    chain = [_rec(f"r{k}", _t(17, 9 + 2 * k), _t(17, 11 + 2 * k)) for k in range(14)]
    ns = nf.nights(chain)
    assert [(n.name, len(n.recs)) for n in ns] == [("2026-11-16", 12), ("2026-11-17", 2)]


def test_stale_when_missing_old_or_10_minutes_behind():
    night = nf.Night("2026-11-17", [_rec("a.f32", 0, 1, 60), _rec("b.f32", 2, 3, 30)])
    rep = {"version": nf.VERSION, "inputs": [{"file": "a.f32", "bytes": night.recs[0].size},
                                             {"file": "b.f32", "bytes": night.recs[1].size}]}
    assert nf.is_stale(night, None)
    assert nf.is_stale(night, dict(rep, version=0))
    assert not nf.is_stale(night, rep)
    def behind(minutes: float) -> dict:
        b = {"file": "b.f32", "bytes": int((30 - minutes) * 60 * nf.FS) * nf.REC_BYTES}
        return dict(rep, inputs=[rep["inputs"][0], b])
    assert not nf.is_stale(night, behind(9.9))
    assert nf.is_stale(night, behind(10))
    assert nf.is_stale(night, dict(rep, inputs=[rep["inputs"][0]]))  # b.f32 (30 min) is new
    assert nf.is_stale(night, dict(rep, inputs=rep["inputs"] + [{"file": "gone.f32", "bytes": 20}]))


# ---- whole runs with a fake scorer ----

def write_rec(folder: Path, start: datetime, minutes: float, seed: int = 0) -> Path:
    """A recording like record_night.py's: <stamp>.f32 (<I4f, volts) and <stamp>.idx (one batch a second)."""
    n = int(minutes * 60 * nf.FS)
    rec = np.zeros(n, dtype=[("pack", "<u4"), ("v", "<f4", 4)])
    rec["pack"] = np.arange(n) % 65536
    rec["v"] = np.random.default_rng(seed).normal(0, 20e-6, (n, 4))
    stem = start.strftime("%Y-%m-%d-%H%M%S")
    rec.tofile(folder / f"{stem}.f32")
    k = np.arange(n // nf.FS)
    idx = np.zeros(len(k), dtype=[("t", "<f8"), ("i", "<u8")])
    idx["t"] = start.timestamp() + k + 1
    idx["i"] = k * nf.FS
    idx.tofile(folder / f"{stem}.idx")
    return folder / f"{stem}.f32"


PATTERN = [W] * 2 + [N2] * 12 + [N3] * 4 + [R] * 4 + [W] * 2  # 10 min asleep in a 12-minute block


@pytest.fixture
def fake_scorer(monkeypatch):
    calls = []

    def score(bdf, repo, device="cpu", progress=print):
        raw = mne.io.read_raw_bdf(bdf, preload=False, verbose="error")
        n_ep = int(raw.n_times / raw.info["sfreq"] // 30)
        start = raw.info["meas_date"].replace(tzinfo=None)
        stage = (PATTERN * (n_ep // len(PATTERN) + 1))[:n_ep]
        p = np.full((n_ep, 5), 0.1); p[np.arange(n_ep), [score_sleep.STAGES.index(s) for s in stage]] = 0.6
        calls.append(bdf.name)
        return dict(source=bdf.name, start=start.isoformat(), epoch_s=30,
                    summary=score_sleep.summary(stage, np.zeros(n_ep, bool), stage, p.max(1)),
                    epochs=[dict(t=(start + timedelta(seconds=30 * i)).isoformat(timespec="seconds"), anysleep=s,
                                 yasa=s, p=list(p[i])) for i, s in enumerate(stage)])

    monkeypatch.setattr(score_sleep, "score", score)
    return calls


def dirs(tmp_path: Path) -> tuple[Path, Path, Path, list[str]]:
    rec, nights, export = tmp_path / "recordings", tmp_path / "nights", tmp_path / "export"
    rec.mkdir()
    return rec, nights, export, ["--recordings", str(rec), "--nights", str(nights), "--export", str(export)]


def events(export: Path) -> list[dict]:
    return [json.loads(ln) for f in export.glob("events/*/eeg-*.jsonl") for ln in f.read_text().splitlines()]


def test_a_second_run_skips_an_up_to_date_night(tmp_path, fake_scorer, capsys):
    rec, nights, export, args = dirs(tmp_path)
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=40)
    write_rec(rec, start, 12)
    assert sr.main(args) == 0
    name = nf.evening_date(start.timestamp())
    rep_file = nights / f"{name}.report.json"
    rep = json.loads(rep_file.read_text())
    assert fake_scorer == [f"{name}.part.bdf"]
    assert rep["scored"] and rep["night_of"] == name and rep["note"].startswith("first guess")
    assert [(p["asleep_min"], p["deep_min"], p["dream_min"], p["light_min"]) for p in rep["periods"]] == [(10, 2, 2, 6)]
    assert rep["total"]["asleep_min"] == 10 and rep["total"]["periods"] == 1
    assert rep["periods"][0]["start"] == (start + timedelta(minutes=1)).astimezone().isoformat(timespec="seconds")
    for f in (f"{name}.bdf", f"{name}.sleep.json", f"{name}.hypnogram.png"):
        assert (nights / f).is_file(), f
    assert not list(nights.glob("*.part.*"))
    assert json.loads((nights / f"{name}.sleep.json").read_text())["source"] == f"{name}.bdf"
    assert len(events(export)) == 1
    x = rep["extras"]  # the shared detectors over the same samples, as the phone's report (night_extras.py)
    assert rep["version"] == 2 and rep["extras_error"] is None
    assert len(x["quality"]) == 24 and x["asleep"]["min"] == 10.0 and x["night"]["min"] == 12.0
    assert x["hours"][0]["start"] == rep["data_start"] and x["hours"][0]["from_s"] == 0
    assert sum(h["min"] for h in x["hours"]) == 12.0
    before = (rep_file.read_bytes(), rep_file.stat().st_mtime_ns)

    assert sr.main(args) == 0  # nothing new: nothing scored, nothing written, nothing exported
    assert len(fake_scorer) == 1 and (rep_file.read_bytes(), rep_file.stat().st_mtime_ns) == before
    assert len(events(export)) == 1
    assert "up to date" in capsys.readouterr().out
    assert json.loads((nights / nf.STATUS).read_text())["state"] == "done"

    write_rec(rec, start + timedelta(minutes=14), 12, seed=1)  # 12 more minutes: out of date
    assert sr.main(args) == 0
    rep = json.loads(rep_file.read_text())
    assert len(fake_scorer) == 2 and len(rep["inputs"]) == 2
    ev = events(export)
    assert len(ev) == 2 and ev[1]["data"]["replaces"] == ev[0]["id"]


def test_too_little_data_gives_an_unscored_report(tmp_path, fake_scorer):
    rec, nights, export, args = dirs(tmp_path)
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=10)
    write_rec(rec, start, 3)
    assert sr.main(args) == 0
    rep = nf.read_report(nights, nf.evening_date(start.timestamp()))
    assert rep and not rep["scored"] and rep["periods"] == [] and rep["hypnogram"] is None
    assert fake_scorer == [] and not events(export)
    assert not nf.stale_nights(rec, nights, time.time())


def test_files_made_by_hand_are_kept(tmp_path, fake_scorer):
    rec, nights, export, args = dirs(tmp_path)
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=30)
    write_rec(rec, start, 12)
    name = nf.evening_date(start.timestamp())
    nights.mkdir()
    (nights / f"{name}.bdf").write_bytes(b"made by hand")
    (nights / f"{name}.sleep.json").write_text("{}")
    assert sr.main(args) == 0
    assert (nights / f"{name}-manual.bdf").read_bytes() == b"made by hand"
    assert (nights / f"{name}-manual.sleep.json").read_text() == "{}"
    assert (nights / f"{name}.bdf").read_bytes()[:8] == b"\xffBIOSEMI"
    assert sr.main(args + ["--force"]) == 0  # ours now: overwritten, not moved again
    assert not (nights / f"{name}-manual2.bdf").exists()


def test_only_one_run_at_a_time(tmp_path, fake_scorer, capsys):
    rec, nights, export, args = dirs(tmp_path)
    write_rec(rec, datetime.now().replace(microsecond=0) - timedelta(minutes=30), 12)
    nights.mkdir()
    with open(nights / nf.LOCK, "a+") as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert sr.main(args) == 0
    assert "another sleep report is running" in capsys.readouterr().out
    assert fake_scorer == [] and not list(nights.glob("*.report.json"))


# ---- the hub's side (standard library only) ----

def test_job_state_for_the_sleep_page(tmp_path, fake_scorer):
    rec, nights, export, args = dirs(tmp_path)
    start = datetime.now().replace(microsecond=0) - timedelta(minutes=30)
    write_rec(rec, start, 12)
    st = nf.job_state(rec, nights)
    assert st["stale"] and not st["running"] and st["report"] is None and st["updated"] is None
    assert sr.main(args) == 0
    st = nf.job_state(rec, nights)
    name = nf.evening_date(start.timestamp())
    assert not st["stale"] and st["report"]["night_of"] == name and st["updated"] and "failed" not in st
    assert nf.hypnogram(nights) == nights / f"{name}.hypnogram.png"
    assert nf.hypnogram(nights, name) == nights / f"{name}.hypnogram.png"
    assert nf.hypnogram(nights, "../../etc/passwd") is None
    # a run that died without finishing (e.g. out of memory) leaves "running" behind with nobody holding the lock
    (nights / nf.STATUS).write_text(json.dumps({"state": "running", "step": "Sleep model AnySleep, run 2 of 3"}))
    assert "stopped before it finished" in nf.job_state(rec, nights)["failed"]
    # a live sleep_report.py process holding the lock counts as running, and no second one is started
    fake = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "sleep_report.py"])
    try:
        (nights / nf.LOCK).write_text(str(fake.pid))
        assert nf.job_state(rec, nights)["running"]
        assert {k: v for k, v in nf.start_job(rec, nights, export).items() if k != "now"} == {"running": True,
                                                                                            "started": False}
    finally:
        fake.kill(); fake.wait()
    assert not nf.job_state(rec, nights)["running"]


def test_long_nights_go_through_the_model_in_pieces():
    assert score_sleep.windows(100) == [(0, 100, 0, 100)]
    assert score_sleep.windows(score_sleep.ONE_PASS_EP) == [(0, score_sleep.ONE_PASS_EP, 0, score_sleep.ONE_PASS_EP)]
    n = 20 * 120 + 7  # 20 h and a bit
    w = score_sleep.windows(n)
    kept = [i for _, _, c0, c1 in w for i in range(c0, c1)]
    assert kept == list(range(n))  # every epoch kept exactly once, in order
    for w0, w1, c0, c1 in w:
        assert 0 <= w0 <= c0 < c1 <= w1 <= n
        assert w1 - w0 <= score_sleep.PIECE_EP + 2 * score_sleep.CONTEXT_EP
        assert c0 - w0 == min(c0, score_sleep.CONTEXT_EP) and w1 - c1 == min(n - c1, score_sleep.CONTEXT_EP)


def test_page_server_answers_results_while_the_recorder_is_away(tmp_path, fake_scorer):
    """Headband off after waking: the recorder has no page server, the always-on one still serves the results."""
    import socket
    import threading
    import urllib.error
    import urllib.request
    from http.server import ThreadingHTTPServer

    import page_server

    rec, nights, export, args = dirs(tmp_path)
    write_rec(rec, datetime.now().replace(microsecond=0) - timedelta(minutes=30), 12)
    with socket.socket() as s:  # a port nobody listens on: the recorder is away
        s.bind(("127.0.0.1", 0)); away = s.getsockname()[1]
    srv = ThreadingHTTPServer(("127.0.0.1", 0), page_server.make_handler("127.0.0.1", away, rec))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}/"
    get = lambda p: urllib.request.urlopen(base + p, timeout=10)  # noqa: E731
    try:
        assert json.loads(get("state").read())["status"] == "reconnecting"
        st = json.loads(get("sleep-report").read())
        assert st["stale"] and not st["running"] and st["report"] is None
        assert json.loads(get("morning-report").read())["report"] is None
        with pytest.raises(urllib.error.HTTPError) as no_chart:
            get("hypnogram.png")
        assert no_chart.value.code == 404
        assert sr.main(args) == 0
        st = json.loads(get("sleep-report").read())
        assert not st["stale"] and st["report"]["total"]["asleep_min"] == 10
        png = get(f"hypnogram.png?date={st['report']['night_of']}")
        assert png.headers["Content-Type"] == "image/png" and png.read()[:4] == b"\x89PNG"
        assert b"Sleep" in get("sleep.html").read()
    finally:
        srv.shutdown()
