"""Tests for analysis/night_drift.py and the lights-off markers in scripts/night_files.py: when you fell asleep after
lights off by the drift-off detector and by the sleep model (the sleep report's `drift_off`) and the running check
toward "4 of 5 nights within 5 minutes". The same hand-worked cases as app/test/drift_report_test.dart.

Run: uv run --project analysis --with pytest pytest -q analysis/tests/test_night_drift.py
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

import eeg_detectors as det
import night_drift as nd
import night_files as nf

W, N1, N2, GAP = "W", "N1", "N2", "gap"


def at(t: datetime) -> str:
    return t.astimezone().isoformat(timespec="seconds")


def add_marker(f32: Path, t: float, text: str) -> None:
    with open(f32.with_suffix(".markers.jsonl"), "a") as f:
        f.write(json.dumps({"t": t, "i": 0, "text": text}) + "\n")


# ---- lights off ----

def test_which_marker_texts_mean_lights_off():
    assert nf.lights_off_from("lights off") == "button"
    assert nf.lights_off_from("dream catcher: lights off; rounds 4, ending wake, round 1 timer 812 s") == "dream catcher"
    assert nf.lights_off_from("sound: quiet minute (eyes closed)") == "sound"
    assert nf.lights_off_from("sound: quiet minute (eyes open)") is None
    assert nf.lights_off_from("drift-off: drowsy") is None
    assert nf.lights_off_from("morning:start") is None
    assert nf.lights_off_from("Lights off") is None  # only the app's own texts


def test_the_latest_lights_off_marker_of_the_night_by_its_time(tmp_path):
    a, b = tmp_path / "2026-11-18-230000.f32", tmp_path / "2026-11-18-233000.f32"
    a.write_bytes(b"\0" * 20); b.write_bytes(b"\0" * 20)
    add_marker(a, 1000, "dream catcher: lights off; rounds 3")
    add_marker(a, 1500, "lights off")
    add_marker(a, 1600, "drift-off: drowsy")
    add_marker(b, 1200, "sound: quiet minute (eyes closed)")
    with open(b.with_suffix(".markers.jsonl"), "a") as f:
        f.write('not json\n{"text": "lights off"}\n')
    night = nf.Night("2026-11-18", [nf.Rec(a, 0, 1, 20), nf.Rec(b, 1, 2, 20)])
    assert nf.lights_off(night) == (1500.0, "button")
    assert nf.lights_off(nf.Night("2026-11-18", [nf.Rec(b, 1, 2, 20)])) == (1200.0, "sound")
    assert nf.lights_off(nf.Night("2026-11-18", [nf.Rec(tmp_path / "2026-11-18-235959.f32", 0, 1, 20)])) is None


def test_lights_off_lands_on_the_next_epoch_never_before_the_first_sample():
    start = 1795468320
    assert nd.lights_off_second(start + 31.2, start) == 60
    assert nd.lights_off_second(start + 30.0, start) == 30
    assert nd.lights_off_second(start + 0.0, start) == 0
    assert nd.lights_off_second(start - 400.0, start) == 0  # tapped while the headband was still being found


def test_the_sleep_models_onset_ten_epochs_not_awake_gaps_skipped():
    stages = [W] * 3 + [N1] * 9 + [W] + [N2] * 4 + [GAP] * 3 + [N2] * 7 + [W] * 2
    assert nd.model_onset(stages, 0) == 13  # 9 then a wake epoch; the run from 13 jumps the gap
    assert nd.model_onset(stages, 14) == 14
    assert nd.model_onset(stages, 16) is None  # only 8 sleep epochs from 16 on
    assert nd.model_onset([N2] * 10, 0) == 0
    assert nd.model_onset([N2] * 9, 0) is None
    assert nd.model_onset([N2] * 12, 40) is None  # lights off after the last epoch


# ---- the report's drift_off ----

START = datetime(2026, 11, 18, 23, 10)
STAGES = [W] * 96 + [N2] * 60  # lights off at 23:40 (epoch 60); sleep from epoch 96, 18 min after


def seen(**kw) -> dict:
    base = dict(lights_off_s=1800, source="button", tapped=None, baseline_s=None, drowsy_s=None, onset_s=None,
                known_s=None, epochs="")
    return {**base, **kw}


def test_both_found_sleep_half_a_minute_apart_they_agree_and_the_night_counts():
    s = seen(tapped=1795468320 + 1790.4, baseline_s=1889, drowsy_s=2909, onset_s=2850, known_s=3029,
             epochs="bbaaaaaaaadds")
    j = json.loads(json.dumps(nd.report(s, STAGES, START)))
    assert j["version"] == nd.VERSION and j["validated"] is False
    assert j["lights_off"] == at(START + timedelta(seconds=1800)) and j["lights_off_s"] == 1800
    assert j["source"] == "button"
    assert j["tapped"] == at(datetime.fromtimestamp(1795468320 + 1790.4))
    assert (j["baseline_s"], j["drowsy_s"], j["onset_s"], j["known_s"]) == (1889, 2909, 2850, 3029)
    assert j["model_onset_s"] == 2880
    assert (j["onset_min"], j["model_onset_min"], j["diff_min"]) == (17.5, 18.0, -0.5)
    assert (j["agree"], j["counted"]) == (True, True)
    assert j["epochs"] == "bbaaaaaaaadds"
    assert j["onset"] == at(START + timedelta(seconds=2850))
    assert j["model_onset"] == at(START + timedelta(seconds=2880))


def test_five_minutes_apart_still_agree_five_and_a_half_do_not():
    assert nd.report(seen(onset_s=2880 + 300), STAGES, START)["agree"] is True
    assert nd.report(seen(onset_s=2880 - 300), STAGES, START)["agree"] is True
    late = nd.report(seen(onset_s=2880 + 330), STAGES, START)
    assert late["agree"] is False and late["diff_min"] == 5.5


def test_only_one_found_sleep_they_disagree_neither_not_counted():
    missed = nd.report(seen(), STAGES, START)
    assert (missed["onset_min"], missed["model_onset_min"], missed["diff_min"]) == (None, 18.0, None)
    assert (missed["agree"], missed["counted"]) == (False, True)
    awake = nd.report(seen(source="dream catcher", onset_s=2850), [W] * 156, START)
    assert (awake["model_onset_min"], awake["agree"], awake["counted"]) == (None, False, True)
    neither = nd.report(seen(source="sound"), [W] * 156, START)
    assert (neither["agree"], neither["counted"]) == (None, False)


def test_lights_off_never_given_is_shown_not_counted():
    j = nd.report(seen(lights_off_s=0, source="night start", onset_s=2880), STAGES, START)
    assert (j["source"], j["tapped"], j["onset_min"], j["model_onset_min"]) == ("night start", None, 48.0, 48.0)
    assert (j["agree"], j["counted"]) == (True, False)


# ---- the check ----

def test_the_check_counts_the_newest_five_counted_nights():
    def night(name: str, agree: bool | None = None, source: str = "button", has: bool = True) -> dict:
        d = dict(lights_off=f"{name}T23:30:00+03:00", source=source, agree=agree,
                 counted=source != "night start" and agree is not None)
        return dict(night_of=name, **({"drift_off": d} if has else {}))

    assert nf.drift_check([]) == (0, 0)
    reports = [night("2026-11-25", True), night("2026-11-24", None), night("2026-11-23", False, "night start"),
               night("2026-11-22", True), night("2026-11-21", has=False), night("2026-11-20", False),
               night("2026-11-19", True)]
    assert nf.drift_check(reports) == (3, 4)
    assert nf.drift_check([night("2026-11-26", True)] + reports) == (4, 5)
    assert nf.drift_check([night("2026-11-27", False), night("2026-11-26", True)] + reports) == (3, 5)
    assert "4 of 5" in nf.drift_check_line(4, 5) and "trusted" in nf.drift_check_line(4, 5)
    assert "3 of 4" in nf.drift_check_line(3, 4) and "so far" in nf.drift_check_line(3, 4)
    assert "not yet" in nf.drift_check_line(3, 5) and "1 night " in nf.drift_check_line(0, 1)


# ---- the night pass ----

def drift_signal(seconds: int, fade_at_s: int) -> np.ndarray:
    """Eyes closed: 10 Hz alpha of 25 µV at O1/O2 until fade_at_s, then a quarter of it; small noise elsewhere."""
    rng = np.random.default_rng(5)
    t = np.arange(seconds * det.FS) / det.FS
    alpha = 25 * np.sin(2 * np.pi * 10 * t) * np.where(t < fade_at_s, 1.0, 0.25)
    x = rng.normal(0, 4, (4, t.size))
    x[0] += alpha; x[1] += 0.9 * alpha
    return x


def test_the_night_pass_runs_the_detector_from_lights_off():
    start = 1795468320
    full = det.detect(drift_signal(480, 240))
    s = nd.night(full, (start + 65.3, "button"), start)
    assert (s["lights_off_s"], s["source"], s["tapped"]) == (90, "button", start + 65.3)
    assert (s["baseline_s"], s["drowsy_s"], s["onset_s"], s["known_s"]) == (149, 299, 240, 419)
    assert s["epochs"] == "baaaaaddddsss"
    auto = nd.night(det.detect(drift_signal(330, 120)), None, start)
    assert (auto["lights_off_s"], auto["source"], auto["tapped"]) == (0, "night start", None)
    assert (auto["baseline_s"], auto["onset_s"], auto["known_s"]) == (59, 120, 299)
