"""scripts/data_book.py and analysis/epoch_signal.py: the data book's tables from a fake `_local/` (DECISIONS 760-769).

The fake folder holds a 40-minute BrainBit night with the phone's sleep report (stages, probabilities, extras, the
dream sleep check), its logs (contact, a gauge stuck at 6 %, the phone's battery) and the morning check-in after it; an
8-channel DIY board recording at custom positions (no 10-10 site); an 8-channel helmet night whose channels hold O1 O2
T7 T8 among others; a work session's raw EEG; a phone and a laptop work session; and the label stores. Nothing real.
"""
from __future__ import annotations

import csv
import gzip
import io
import json
import math
import sys
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import data_book as db  # noqa: E402
import epoch_signal as es  # noqa: E402
import packed  # noqa: E402
import recording as rc  # noqa: E402
import rem_check  # noqa: E402
from nch_files import MIXED, write_set  # noqa: E402

FS = 250
NIGHT = datetime(2026, 11, 16, 23, 0, 0)  # night of 2026-11-16, 40 minutes
DIY = datetime(2026, 11, 14, 22, 0, 0)  # the DIY board's, 20 minutes
HELMET = datetime(2026, 11, 12, 23, 0, 0)  # the helmet's night, 20 minutes
WORK = datetime(2026, 11, 17, 14, 0, 0)  # a work session's raw EEG, 10 minutes
STAGES = "W" * 10 + "1" * 4 + "2" * 30 + "3" * 20 + "R" * 10 + "W" * 6  # 80 epochs = 40 min
SEED = 20261120


def at(t: datetime) -> str:
    return t.astimezone().isoformat(timespec="seconds")


def logline(t: datetime, text: str) -> str:
    return f"{t.strftime('%Y-%m-%dT%H:%M:%S')}.000 {text}\n"


def stamp(t: datetime) -> str:
    return t.strftime("%Y-%m-%d-%H%M%S")


def signal(n: int, channels: int, alpha_until: int = 0) -> np.ndarray:
    """Volts: 20 µV noise on every channel, a 10 Hz wave of 40 µV on the first channel until sample `alpha_until`."""
    rng = np.random.default_rng(SEED)
    v = rng.normal(0, 20e-6, (n, channels))
    t = np.arange(n) / FS
    v[:alpha_until, 0] += 40e-6 * np.sin(2 * math.pi * 10 * t[:alpha_until])
    return v.astype("<f4")


def probs_for(stages: str) -> list[list[float]]:
    order = {"W": 0, "1": 1, "2": 2, "3": 3, "R": 4}
    out = []
    for c in stages:
        p = [0.05] * 5
        p[order[c]] = 0.8
        out.append(p)
    return out


def phone_report(model: str = "anysleep-test@1 onnx-f16 two-pass", stages: str = STAGES) -> dict:
    """The phone's report of the fake night (docs/data-format.md), its numbers worked out from `stages`."""
    t = lambda i: at(NIGHT + timedelta(seconds=30 * i))  # noqa: E731
    asleep = [i for i, c in enumerate(stages) if c in "123R"]
    first, last = asleep[0], asleep[-1]
    span = stages[first:last + 1]
    mins = {k: span.count(k) / 2 for k in "W123R"}
    period = dict(start=t(first), end=t(last + 1), asleep_min=len(asleep) / 2, light_min=mins["1"] + mins["2"],
                  deep_min=mins["3"], dream_min=mins["R"], awake_min=mins["W"], wake_ups=0, missing_min=0.0)
    names = [rem_check._CHAR[c] for c in stages]  # noqa: SLF001
    probs = rem_check.encode_probs(probs_for(stages))
    return dict(
        version=2, night_of="2026-11-16", data_start=at(NIGHT), data_end=at(NIGHT + timedelta(minutes=40)),
        inputs=[dict(file=f"{stamp(NIGHT)}.f32", bytes=40 * 60 * FS * 20)], scored=True, source="phone",
        epoch_s=30, periods=[period],
        total=dict(asleep_min=period["asleep_min"], light_min=period["light_min"], deep_min=period["deep_min"],
                   dream_min=period["dream_min"], wake_ups=0, periods=1, recorded_min=40.0, missing_min=0.0,
                   stray_sleep_min=0.0),
        model=model, cross_check=None, stages=stages, probs=probs,
        extras=dict(version=1, night=dict(min=40.0, good_min=30.0, degraded_min=8.0, missing_min=2.0, jaw_bursts=6,
                                          moves=4),
                    asleep=dict(min=32.0, good_min=28.0, degraded_min=3.0, missing_min=1.0, jaw_bursts=4, moves=2,
                                jaw_per_hour=7.5, moves_per_hour=3.8)),
        drift_off=dict(version=1, source="button", lights_off=at(NIGHT), model_onset_min=5.0, onset_min=4.5,
                       agree=True, counted=True),
        rem_check=rem_check.night_check(names, [(first, last)], rem_check.decode_probs(probs), None))


def night_log(start: datetime, minutes: int) -> str:
    lines = [logline(start, "connected BB Black 00:00:00:00:00:00 serial 0 battery 98% signal -70 dBm"),
             logline(start + timedelta(seconds=2), "contact ohms O1=120000 O2=950000 T3=inf T4=31000"),
             logline(start + timedelta(seconds=3), "recording started, 250 Hz")]
    for k in range(1, minutes * 6):
        s = start + timedelta(seconds=10 * k)
        lines.append(logline(s, f"samples {2500 * k} (+2500) battery 6%"))
        if k % 6 == 0:
            lines.append(logline(s, f"phone battery {100 - k // 60}% charge {4_000_000 - 1000 * k} uAh current "
                                    "60000 uA unplugged temp 30.0 C"))
    lines.append(logline(start + timedelta(minutes=minutes), "stopped, battery 6%"))
    return "".join(lines)


def custom_header() -> rc.Header:
    """Eight electrodes placed by hand: no 10-10 site, each with its direction on the head."""
    dirs = [(math.cos(a) * 0.6, math.sin(a) * 0.6, 0.8) for a in np.linspace(0, 2 * math.pi, 8, endpoint=False)]
    return rc.Header(tuple(rc.Channel(f"E{i + 1}", None, (round(x, 3), round(y, 3), round(z, 3)))
                           for i, (x, y, z) in enumerate(dirs)), FS, rc.SEQUENCE_NUMBER, device=rc.DIY_BOARD,
                     layout="test custom 8", made_by="test_data_book")


def make_local(root: Path) -> Path:
    loc = root / "_local"
    rec, diy, phone = loc / "recordings", loc / "recordings-diy", loc / "phone"
    for d in (rec, diy, phone / "nights", phone / "mornings", phone / "work-sessions", phone / "archive",
              phone / "auto-start", phone / "sharp-hours", loc / "laptop" / "work"):
        d.mkdir(parents=True, exist_ok=True)
    # the BrainBit night, the phone's report and the check-in the next morning
    f32 = write_set(rec, NIGHT, signal(40 * 60 * FS, 4, alpha_until=5 * 60 * FS), ("O1", "O2", "T3", "T4"),
                    header=rc.brainbit("test"))
    f32.with_suffix(".log").write_text(night_log(NIGHT, 40))
    f32.with_suffix(".markers.jsonl").write_text(json.dumps(dict(t=NIGHT.timestamp() + 30, i=7500, text="lights off"))
                                                 + "\n")
    (phone / "nights" / "2026-11-16.report.json").write_text(json.dumps(phone_report()))
    morning = NIGHT + timedelta(hours=8)
    (phone / "mornings" / f"{stamp(morning)}.morning.json").write_text(json.dumps(dict(
        version="morning-v1", start=at(morning), app="phone", back=dict(clean_share=0.9, iaf_hz=9.8),
        ratings=dict(kss=4, mood=4, tension=2, sleep=4), habits=dict(caffeine_cups=2, alcohol_drinks=0))))
    # the DIY board at custom positions, and a helmet whose eight channels hold O1 O2 T7 T8
    write_set(diy, DIY, signal(20 * 60 * FS, 8), tuple(f"E{i}" for i in range(1, 9)), header=custom_header())
    write_set(rec, HELMET, signal(20 * 60 * FS, 8), MIXED)
    # a work session's raw EEG (no night) and its session file, and the laptop's session
    work = rc.Header(rc.brainbit("test").channels, FS, rc.PACKET_NUMBER, device=rc.BRAINBIT, session="work")
    write_set(rec, WORK, signal(10 * 60 * FS, 4), ("O1", "O2", "T3", "T4"), header=work)
    epochs = [dict(at=(WORK + timedelta(seconds=30 * k)).isoformat(), s=30 * k, muscle_s=6,
                   level=["alert", "getting_drowsy", "drowsy", "unknown"][k % 4], eyes_closed=False) for k in range(20)]
    (phone / "work-sessions" / f"{stamp(WORK)}.work.json").write_text(json.dumps(dict(
        version=1, kind="work_session", app="eeg_tracker work", start=WORK.isoformat(),
        end=(WORK + timedelta(minutes=10)).isoformat(), ended="stopped", raw=stamp(WORK), worn_min=10.0,
        meeting_min=2.0, minutes=dict(eyes_closed=0.5), epochs=epochs,
        breaks=[dict(start=(WORK + timedelta(minutes=8)).isoformat(), end=(WORK + timedelta(minutes=9)).isoformat(),
                     source="tapped")],
        hints=[dict(at=(WORK + timedelta(minutes=7)).isoformat(), reason="drowsy", active_min=7.0, threshold_min=60,
                    answer="onBreak", taken=True)],
        ratings=[dict(at=(WORK + timedelta(minutes=5)).isoformat(), value=3)])))
    lw = datetime(2026, 11, 17, 10, 0, 0)
    (loc / "laptop" / "work" / f"{stamp(lw)}.work.json").write_text(json.dumps(dict(
        version=1, kind="laptop_work_session", app="eeg_tracker tray", start=at(lw), end=at(lw + timedelta(hours=1)),
        ended="stopped", started_by="asked", active_min=50.0, meeting_min=20.0, breaks=[], hints=[],
        settings=dict(hint_threshold_min=60.0))))
    (loc / "laptop" / "work" / "labels.jsonl").write_text(json.dumps(dict(
        version=1, at=at(lw + timedelta(minutes=5)), question="ask", answer="yes", run_start=at(lw), work_min=5.0,
        family="code", app="editor", session=stamp(lw), rule="laptop-detect-v1 ask=5")) + "\n")
    (phone / "archive" / f"{stamp(NIGHT)}.tags.json").write_text(json.dumps(dict(version=1, id=stamp(NIGHT), tags=[
        dict(start=at(NIGHT), end=at(NIGHT + timedelta(minutes=40)), label="sleep", made=at(morning)),
        dict(start=at(NIGHT), end=at(NIGHT + timedelta(minutes=5)), label="reading", made=at(morning))])))
    (phone / "auto-start" / "log.jsonl").write_text("".join(json.dumps(x) + "\n" for x in (
        dict(version=1, at=at(NIGHT - timedelta(minutes=1)), event="check", trigger="bedtime", guess="night",
             choice="ask"),
        dict(version=1, at=at(NIGHT - timedelta(minutes=1)), event="question", kind="night", text="Sleeping?"),
        dict(version=1, at=at(NIGHT), event="answer", kind="night", answer="yes", after_s=60))))
    (phone / "sharp-hours" / "focus-2026-11.jsonl").write_text(json.dumps(dict(
        version=1, day="2026-11-17", sessions=2, list=[dict(start=at(lw), min=40), dict(start=at(lw), min=45)],
        rule="focus-v1 min=35 switch=3")) + "\n")
    return loc


def read(path: Path) -> list[dict]:
    opener = gzip.open if path.name.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def build(loc: Path, *args: str) -> tuple[Path, list[str]]:
    out: list[str] = []
    assert db.main(["--local", str(loc), "--out", str(loc / "data"), *args], out=out.append) == 0, out
    return loc / "data", out


def book(out: Path) -> dict:
    return json.loads((out / "book.json").read_text())


@pytest.fixture
def local(tmp_path: Path) -> Path:
    return make_local(tmp_path)


def test_the_nights_table_holds_the_reports_numbers(local: Path) -> None:
    out, _ = build(local)
    rows = {(r["night"], r["source"]): r for r in read(out / "nights.tsv")}
    n = rows[("2026-11-16", "phone")]
    rep = phone_report()
    assert (n["kind"], n["counts"], n["scored"]) == ("nap", "1", "1")  # 32 min asleep: a nap (DECISIONS 761)
    for col, key in (("asleep_min", "asleep_min"), ("light_min", "light_min"), ("deep_min", "deep_min"),
                     ("dream_min", "dream_min"), ("recorded_min", "recorded_min")):
        assert float(n[col]) == rep["total"][key]
    assert n["start"] == at(NIGHT) and n["sleep_start"] == at(NIGHT + timedelta(minutes=5))
    assert float(n["fall_asleep_min"]) == 5.0 and n["lights_off_from"] == "button" and n["drift_agree"] == "1"
    assert float(n["rem_share_pct"]) == round(5 / 32 * 100, 1) and n["rem_check_from"] == "report"
    assert float(n["rem_prob_min"]) == rep["rem_check"]["rem_prob_min"]
    assert (n["good_pct"], n["jaw_per_h"], n["extras_from"]) == ("75", "7.5", "report")
    assert (n["contact_O1_ohm"], n["contact_O2_ohm"], n["contact_T3_ohm"]) == ("120000", "950000", "")
    # 6 % for 40 minutes is not yet stuck (60 minutes of streaming make it so: test_battery.py)
    assert (n["band_battery_start_pct"], n["band_battery_end_pct"], n["band_stuck_at"]) == ("98", "6", "")
    assert abs(int(n["band_end_est_pct"]) - (98 - 11 * float(n["band_streamed_h"]))) <= 1  # hours shown to 0.1
    assert n["phone_battery_start_pct"] == "100"
    assert n["slept_rating"] == "4" and n["checkin"].startswith("phone/mornings/")
    assert n["model"] == rep["model"] and n["report_file"] == "phone/nights/2026-11-16.report.json"
    assert f"recordings/{stamp(NIGHT)}.f32=" in n["sources"] and len(n["inputs_sha256"]) == 64
    assert rows[("2026-11-14-diy", "diy")]["scored"] == "0"
    assert rows[("2026-11-12", "laptop")]["kind"] == "nap"  # 20 minutes recorded, never scored


def test_the_epochs_line_up_with_the_stages_for_any_layout(local: Path) -> None:
    out, _ = build(local)
    rows = read(out / "epochs.tsv.gz")
    night = [r for r in rows if r["recording"] == "2026-11-16"]
    assert len(night) == 80 and "".join(r["stage"][-1] if r["stage"] != "W" else "W" for r in night) == STAGES
    assert night[0]["start"] == at(NIGHT) and night[1]["start"] == at(NIGHT + timedelta(seconds=30))
    assert float(night[20]["p_N2"]) == 0.8 and night[20]["model"].startswith("anysleep-test@1")
    # the 10 Hz wave on O1 for the first 5 minutes: alpha leads there, not later; T3 has no wave
    assert float(night[2]["O1_alpha_pct"]) > 80 and float(night[30]["O1_alpha_pct"]) < 30
    assert float(night[2]["T3_alpha_pct"]) < 30
    shares = [float(night[5][f"O2_{b}_pct"]) for b in ("delta", "theta", "alpha", "beta")]
    assert sum(shares) == pytest.approx(100, abs=0.5)
    assert night[5]["channels"] == "BrainBit: O1:O1 O2:O2 T3:T7 T4:T8" and night[5]["jaw"] != ""
    # eight electrodes at custom positions: their own columns, the generic quality, no jaw count
    diy = [r for r in rows if r["recording"] == "2026-11-14-diy"]
    assert len(diy) == 40 and all(diy[3][f"E{i}_quality"] == "g" for i in range(1, 9))
    assert diy[3]["E8_alpha_pct"] != "" and diy[3]["jaw"] == "" and diy[3]["O1_alpha_pct"] == ""
    assert diy[3]["kind"] == "diy" and diy[3]["channels"].startswith("DIY board: E1:(0.6,0,0.8)")
    # the helmet: eight channels, the detectors read its O1 O2 T7 T8 by site
    helmet = [r for r in rows if r["recording"] == "2026-11-12"]
    assert len(helmet) == 40 and helmet[3]["Fz_quality"] == "g" and helmet[3]["jaw"] != ""
    work = [r for r in rows if r["recording"] == stamp(WORK)]
    assert len(work) == 20 and work[0]["kind"] == "work" and work[0]["stage"] == ""
    head = gzip.open(out / "epochs.tsv.gz", "rt").readline().rstrip("\n").split("\t")
    assert head[: len(db.BASE_EPOCH_COLUMNS)] == db.BASE_EPOCH_COLUMNS
    assert {"E1_delta_pct", "Fz_beta_pct", "O1_quality", "T4_theta_pct"} <= set(head)


def test_sessions_days_and_labels(local: Path) -> None:
    out, _ = build(local)
    s = {r["kind"]: r for r in read(out / "sessions.tsv")}
    w = s["work"]
    # 20 half minutes, a quarter unknown, two in the break (8-9 min): 13 readable, 9 of them (getting) drowsy
    assert (w["usable_min"], w["drowsy_min"], w["breaks"], w["break_min"]) == ("6.5", "4.5", "1", "1")
    assert (w["talking_min"], w["meeting_min"], w["hints"], w["hints_taken"], w["sharp_mean"]) == \
        ("1.8", "2", "1", "1", "3")
    assert w["raw"] == stamp(WORK) and len(w["file_sha256"]) == 64
    lw = s["laptop_work"]
    assert (lw["active_min"], lw["meeting_min"], lw["started_by"], lw["minutes"]) == ("50", "20", "asked", "60")
    days = {r["day"]: r for r in read(out / "days.tsv")}
    d = days["2026-11-16"]  # the night ended before 04:00 on the 17th: it counts for the 16th
    assert (d["naps"], d["asleep_min"], d["fall_asleep_min"]) == ("1", "32", "5")
    d = days["2026-11-17"]
    assert (d["kss"], d["slept"], d["caffeine_cups"]) == ("4", "4", "2")
    assert (d["focus_sessions"], d["focus_min"], d["laptop_work_min"], d["meeting_min"]) == ("2", "85", "50", "22")
    labels = read(out / "labels.tsv")
    kinds = {(x["source"], x["kind"], x["value"]) for x in labels}
    assert {("archive", "activity", "sleep"), ("archive", "activity", "reading"), ("auto-start", "activity", "night"),
            ("tray", "activity", "work"), ("work-session", "break hint", "onBreak"), ("work-session", "sharp", "3"),
            ("marker", "marker", "lights off"), ("check-in", "slept", "4"), ("check-in", "caffeine", "2")} <= kinds
    auto = next(x for x in labels if x["source"] == "auto-start")
    assert (auto["app_guess"], auto["how_asked"]) == ("night", "question")
    assert auto["start"] == at(NIGHT - timedelta(minutes=1))
    assert all(x["id"] and x["added"] for x in labels)


def test_a_rebuild_works_out_only_what_changed(local: Path) -> None:
    out, _ = build(local)
    assert book(out)["worked_out"] == 4 and book(out)["recordings"] == 4
    first = (out / "epochs.tsv.gz").read_bytes()
    build(local)
    assert book(out)["worked_out"] == 0 and (out / "epochs.tsv.gz").read_bytes() == first
    # packing a raw file keeps its samples: nothing to work out again
    packed.pack(local / "recordings" / f"{stamp(HELMET)}.f32")
    assert (local / "recordings" / f"{stamp(HELMET)}.f32.xz").is_file()
    build(local)
    assert book(out)["worked_out"] == 0 and (out / "epochs.tsv.gz").read_bytes() == first
    # a recording that grew is worked out again, alone
    f = local / "recordings-diy" / f"{stamp(DIY)}.f32"
    with open(f, "ab") as h:
        h.write(f.read_bytes()[: 36 * FS * 60])
    build(local)
    assert book(out)["worked_out"] == 1
    assert len([r for r in read(out / "epochs.tsv.gz") if r["recording"] == "2026-11-14-diy"]) == 42


def test_a_new_model_version_replaces_the_nights_rows(local: Path) -> None:
    """The phone scores the night again with a new model: its rows are worked out again and name the new model;
    no row of the old one is left (a rebuild never mixes versions)."""
    out, _ = build(local)
    new = STAGES.replace("2" * 30, "2" * 20 + "R" * 10)
    (local / "phone" / "nights" / "2026-11-16.report.json").write_text(
        json.dumps(phone_report(model="anysleep-test@2", stages=new)))
    build(local)
    assert book(out)["worked_out"] == 1 and book(out)["models"] == ["anysleep-test@2"]
    night = [r for r in read(out / "epochs.tsv.gz") if r["recording"] == "2026-11-16"]
    assert {r["model"] for r in night} == {"anysleep-test@2"}
    assert "".join(r["stage"][-1] if r["stage"] != "W" else "W" for r in night) == new
    n = next(r for r in read(out / "nights.tsv") if r["night"] == "2026-11-16")
    assert n["model"] == "anysleep-test@2" and float(n["dream_min"]) == 10.0


def test_a_new_signal_version_works_everything_out_again(local: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    out, _ = build(local)
    monkeypatch.setattr(es, "VERSION", "epoch-signal-test")
    build(local)
    assert book(out)["worked_out"] == 4
    assert {r["signal_version"] for r in read(out / "epochs.tsv.gz")} == {"epoch-signal-test"}


def test_labels_are_only_ever_added(local: Path) -> None:
    out, _ = build(local)
    before = (out / "labels.tsv").read_text()
    tags = local / "phone" / "archive" / f"{stamp(NIGHT)}.tags.json"
    j = json.loads(tags.read_text())
    gone = j["tags"].pop(1)  # "reading" taken back
    j["tags"].append(dict(start=at(NIGHT), end=at(NIGHT + timedelta(minutes=2)), label="rest", made=at(NIGHT)))
    tags.write_text(json.dumps(j))
    build(local)
    after = (out / "labels.tsv").read_text()
    assert after.startswith(before)
    new = read(out / "labels.tsv")[len(read_text_rows(before)):]
    assert [(x["kind"], x["value"]) for x in new] == [("activity", "rest"), ("removed", gone["label"])]
    assert new[1]["replaces"].startswith("archive:")
    build(local)
    assert (out / "labels.tsv").read_text() == after  # nothing new: nothing added, no second tombstone


def read_text_rows(text: str) -> list[dict]:
    return list(csv.DictReader(io.StringIO(text), delimiter="\t"))


def test_the_book_only_reads_local(local: Path, tmp_path: Path) -> None:
    def snapshot() -> dict:
        return {p.relative_to(local).as_posix(): (p.stat().st_size, p.stat().st_mtime_ns)
                for p in local.rglob("*") if p.is_file()}
    before = snapshot()
    out: list[str] = []
    assert db.main(["--local", str(local), "--out", str(tmp_path / "elsewhere")], out=out.append) == 0
    assert snapshot() == before
    assert {"nights.tsv", "sessions.tsv", "days.tsv", "epochs.tsv.gz", "labels.tsv", "README.md", "book.json"} <= \
        {p.name for p in (tmp_path / "elsewhere").iterdir()}


def test_band_mix_finds_the_band_of_a_wave() -> None:
    n = 4 * 30 * FS
    t = np.arange(n) / FS
    rng = np.random.default_rng(SEED)
    x = np.stack([30 * np.sin(2 * math.pi * f * t) + rng.normal(0, 1, n) for f in (2.0, 6.0, 10.0, 20.0)], axis=1)
    mix = es.band_mix(x, np.zeros(4, int), FS, 4)
    for c, band in enumerate(("delta", "theta", "alpha", "beta")):
        assert mix[band][:, c].min() > 90, band
    gaps = np.array([0, 6, 0, 0])  # over 5 s missing: no number
    assert np.isnan(es.band_mix(x, gaps, FS, 4)["alpha"][1]).all()


def test_a_flat_channel_is_bad_and_a_gap_is_missing() -> None:
    n = 2 * 30 * FS
    rng = np.random.default_rng(SEED)
    x = rng.normal(0, 20, (n, 3))
    x[:, 1] = 5.0  # flat
    miss = np.zeros(n, bool)
    miss[30 * FS: 30 * FS + 6 * FS] = True  # 6 s missing in the second epoch
    h = rc.Header((rc.Channel("A"), rc.Channel("B"), rc.Channel("C")), FS, rc.SEQUENCE_NUMBER)
    sig = es.run(x, miss, h)
    assert sig.channel_quality == ["gbg", "mmm"] and sig.quality == ["d", "m"] and not sig.detectors
    assert np.isnan(sig.bands["delta"][0, 1]) and not np.isnan(sig.bands["delta"][0, 0])


def test_two_reports_kept_by_hand_the_earlier_counts_and_a_renamed_sleep_json_is_found(local: Path) -> None:
    """DECISIONS 829: two laptop reports kept in analyses/ for one night (a nap, then an awake evening scored for the
    truth labels): the earlier start counts, so the 30 s rows keep every sample; a report's sleep.json kept under the
    report's own name (`<stem>.sleep.json`) gives its stages though the report names `<night>.sleep.json`."""
    hand = local / "analyses"
    hand.mkdir()
    names = [rem_check._CHAR[c] for c in STAGES]  # noqa: SLF001
    for stem, minutes in (("2026-11-16-a-evening", 20), ("2026-11-16-b-nap", 0)):
        rep = phone_report()
        del rep["stages"], rep["probs"]
        rep.update(source="laptop", sleep_json="2026-11-16.sleep.json", data_start=at(NIGHT + timedelta(minutes=minutes)))
        (hand / f"{stem}.report.json").write_text(json.dumps(rep))
    (hand / "2026-11-16-b-nap.sleep.json").write_text(json.dumps(dict(start=NIGHT.isoformat(), epoch_s=30, epochs=[
        dict(t=(NIGHT + timedelta(seconds=30 * i)).isoformat(), anysleep=s, yasa="W", p=[0.2] * 5)
        for i, s in enumerate(names)])))
    reps = db.read_reports(local, db.Hashes(local, local / "h.json"))["2026-11-16"]
    assert [r.rel for r in reps] == ["analyses/2026-11-16-b-nap.report.json", "analyses/2026-11-16-a-evening.report.json",
                                     "phone/nights/2026-11-16.report.json"]
    assert db.sleep_json_of(reps[0], local) == "analyses/2026-11-16-b-nap.sleep.json"
    assert db.sleep_json_of(reps[1], local) is None
    out, _ = build(local)
    counting = [n for n in read(out / "nights.tsv") if n["night"] == "2026-11-16" and n["counts"] == "1"]
    assert [n["report_file"] for n in counting] == ["analyses/2026-11-16-b-nap.report.json"]
    rows = [r for r in read(out / "epochs.tsv.gz") if r["recording"] == "2026-11-16"]
    assert rows[0]["start"] == at(NIGHT) and [r["stage"] for r in rows[: len(names)]] == names
