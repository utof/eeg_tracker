"""When you fell asleep after lights off, by the drift-off detector (DECISIONS 62, 88) and by the sleep model: the
sleep report's `drift_off` (DECISIONS 180-184). The Python reference for the phone's `app/lib/sleep/drift.dart`
(the same hand-worked cases in `analysis/tests/test_night_drift.py` and `app/test/drift_report_test.dart`);
`scripts/sleep_report.py` writes the same fields on the laptop.

- Lights off: the latest lights-off marker of the night's recordings (`night_files.lights_off`: the phone's Lights
  off button, the dream catcher's, a fall-asleep sound session's quiet minute), else the night's first sample
  ("night start").
- It lands on the next of the night's 30 s epochs (the sleep model's), so both count the same epochs.
- The detector runs over the night from there; the sleep model's onset is the first of 10 epochs in a row not
  scored awake, missing epochs skipped (`validate_detectors.persistent_onset`).
- They agree when the onsets are at most 5 minutes apart and disagree when only one found sleep; a night counts
  toward the check (4 of 5 nights) when lights off was given (not the night start) and either found sleep.
"""

from __future__ import annotations

import math
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402

VERSION = 1
RULES = ("drift-off detector (DECISIONS 88, planning values) from lights off against the sleep model's first 10 "
         "epochs in a row not scored awake; they agree within 5 min")
MODEL_ONSET_RUN = 10
AGREE_MIN = 5.0
EPOCH_S = det.EPOCH_S
NIGHT_START = "night start"


def lights_off_second(t: float, start_unix: int) -> int:
    """The second (from the night's first sample, a whole second) the detector starts at: lights off at unix time t
    rounded up to the night's 30 s epochs, 0 when it came before the first sample."""
    return max(0, math.ceil((t - start_unix) / EPOCH_S) * EPOCH_S)


def model_onset(stages: list[str], from_epoch: int, run: int = MODEL_ONSET_RUN) -> int | None:
    """The first epoch at or after from_epoch of `run` epochs in a row not scored awake, gap epochs skipped."""
    scored = [i for i in range(max(0, from_epoch), len(stages)) if stages[i] != "gap"]
    in_row = 0
    for j, i in enumerate(scored):
        in_row = 0 if stages[i] == "W" else in_row + 1
        if in_row == run:
            return scored[j - run + 1]
    return None


def epochs_text(d: det.Drift) -> str:
    """The detector's state after each epoch: b (learning the baseline), a, d, s, or - (skipped)."""
    char = {"baseline": "b", "awake": "a", "drowsy": "d", "asleep": "s"}
    return "".join(("b" if e.state == "baseline" else "-") if e.faded is None else char[e.state] for e in d.epochs)


def night(seen: det.Seen, lights_off: tuple[float, str] | None, start_unix: int) -> dict[str, Any]:
    """The detector over a night from lights off (`night_files.lights_off`, None = the night's start): what it saw,
    seconds from the night's first sample (`start_unix`)."""
    k = 0 if lights_off is None else lights_off_second(lights_off[0], start_unix)
    d = det.drift_off(seen.seconds, k, seen.blinks)
    return dict(lights_off_s=k, source=NIGHT_START if lights_off is None else lights_off[1],
                tapped=None if lights_off is None else lights_off[0], baseline_s=d.baseline_done,
                drowsy_s=d.drowsy_at, onset_s=d.onset, known_s=d.asleep_at, epochs=epochs_text(d))


def report(s: dict[str, Any], stages: list[str], start: datetime) -> dict[str, Any]:
    """The report's `drift_off` from `night()` and the night's stages (per 30 s from `start`, its first sample)."""
    lo = s["lights_off_s"]
    ref = model_onset(stages, lo // EPOCH_S)
    model_s = None if ref is None else ref * EPOCH_S
    after = lambda k: None if k is None else (k - lo) / 60  # noqa: E731
    at = lambda k: None if k is None else (start + timedelta(seconds=k)).astimezone().isoformat(timespec="seconds")  # noqa: E731
    on, model = after(s["onset_s"]), after(model_s)
    diff = on - model if on is not None and model is not None else None
    agree = None if on is None and model is None else diff is not None and abs(diff) <= AGREE_MIN
    tapped = s["tapped"]
    return dict(version=VERSION, rules=RULES, validated=False, lights_off=at(lo), lights_off_s=lo, source=s["source"],
                tapped=None if tapped is None else datetime.fromtimestamp(tapped).astimezone().isoformat(timespec="seconds"),
                baseline_s=s["baseline_s"], drowsy_s=s["drowsy_s"], onset_s=s["onset_s"], known_s=s["known_s"],
                model_onset_s=model_s, onset=at(s["onset_s"]), model_onset=at(model_s), onset_min=on,
                model_onset_min=model, diff_min=diff, agree=agree,
                counted=s["source"] != NIGHT_START and agree is not None, epochs=s["epochs"])
