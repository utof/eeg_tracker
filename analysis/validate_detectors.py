"""Check the detectors in `eeg_detectors.py` on the owner's recordings (laptop only; nothing is written
next to the data).

  uv run --project analysis python analysis/validate_detectors.py onset   NIGHT.bdf NIGHT.sleep.json HH:MM:SS [...]
  uv run --project analysis python analysis/validate_detectors.py stages  NIGHT.bdf NIGHT.sleep.json
  uv run --project analysis python analysis/validate_detectors.py checkin RUN.f32 RUN.markers.jsonl

onset:   the drift-off detector from each "lights off" time against AnySleep's persistent onset (the first
         of 10 sleep epochs in a row, gap epochs skipped), as in the checks of 2026-11-18 (check 6).
stages:  blinks, eye movements, jaw and movement bursts and epoch quality per AnySleep stage.
checkin: blinks and eye movements in the morning check-in's eyes-closed and eyes-open phases.
Prints JSON. A BDF is read with MNE; `.npz` caches next to this script's output are not made.
"""

from __future__ import annotations

import json
import struct
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eeg_detectors as det  # noqa: E402

Floats = det.Floats


def load_bdf(path: Path) -> tuple[Floats, det.Bools, datetime]:
    import mne  # only here: the detectors themselves do not need it

    raw = mne.io.read_raw_bdf(path, preload=True, verbose="error")
    if round(raw.info["sfreq"]) != det.FS:
        raise ValueError(f"{path}: {raw.info['sfreq']} Hz, expected {det.FS}")
    x = raw.get_data(picks=list(det.CHANNELS), units="uV")
    miss = np.zeros(x.shape[1], bool)
    for a in raw.annotations:
        if a["description"].startswith("BAD"):
            lo = int(a["onset"] * det.FS)
            hi = int((a["onset"] + max(a["duration"], 0)) * det.FS)
            miss[lo:hi] = True
    start = raw.info["meas_date"].replace(tzinfo=None)
    return x, miss, start


def load_stages(path: Path) -> tuple[list[str], datetime]:
    d = json.loads(path.read_text())
    if not isinstance(d, dict) or not isinstance(d.get("epochs"), list):
        raise ValueError(f"{path}: not a sleep.json")
    stages = [str(e["anysleep"]) for e in d["epochs"]]
    return stages, datetime.fromisoformat(str(d["start"]))


def persistent_onset(stages: list[str], from_epoch: int, run: int = 10) -> int | None:
    """First epoch of `run` non-wake epochs in a row (gap epochs skipped), at or after from_epoch."""
    idx = [i for i in range(from_epoch, len(stages)) if stages[i] != "gap"]
    for j, i in enumerate(idx):
        seq = idx[j : j + run]
        if len(seq) == run and all(stages[r] != "W" for r in seq):
            return i
    return None


def clock(start: datetime, s: float) -> str:
    return (start + timedelta(seconds=s)).strftime("%H:%M:%S")


def onset(bdf: Path, sleep: Path, offs: list[str]) -> dict[str, Any]:
    x, miss, start = load_bdf(bdf)
    stages, s_start = load_stages(sleep)
    if s_start != start:
        raise ValueError("BDF and sleep.json start differ")
    sec = det.seconds(x, miss)
    del x
    out: list[dict[str, Any]] = []
    for hhmmss in offs:
        t = datetime.combine(start.date(), datetime.strptime(hhmmss, "%H:%M:%S").time())
        if t < start:
            t += timedelta(days=1)
        e0 = int(np.ceil((t - start).total_seconds() / det.EPOCH_S))  # lights off on AnySleep's epoch grid
        lo = e0 * det.EPOCH_S
        d = det.drift_off(sec, lo)
        ref = persistent_onset(stages, e0)
        row: dict[str, Any] = {
            "lights_off": clock(start, lo),
            "baseline_alpha_uv2": None if d.baseline_alpha is None else round(d.baseline_alpha, 2),
            "baseline_done": None if d.baseline_done is None else clock(start, d.baseline_done + 1),
            "anysleep_onset": None if ref is None else clock(start, ref * det.EPOCH_S),
            "onset": None if d.onset is None else clock(start, d.onset),
            "known_at": None if d.asleep_at is None else clock(start, d.asleep_at + 1),
            "drowsy_known_at": None if d.drowsy_at is None else clock(start, d.drowsy_at + 1),
            "diff_min": None
            if d.onset is None or ref is None
            else round((d.onset - ref * det.EPOCH_S) / 60, 2),
            "faded_before_onset": None,
            "later_onsets": [clock(start, a) for a, _ in d.onsets[1:]],
            "wakes": [clock(start, w + 1) for w in d.wakes],
        }
        if ref is not None:
            pre = [e for e in d.epochs if e.faded is not None and e.start < ref * det.EPOCH_S]
            row["faded_before_onset"] = f"{sum(1 for e in pre if e.faded)} of {len(pre)}"
            post = [e for e in d.epochs if e.faded is not None and ref * det.EPOCH_S <= e.start < (ref + 20) * det.EPOCH_S]
            row["faded_next_10_min"] = f"{sum(1 for e in post if e.faded)} of {len(post)}"
            row["rolls_before_onset"] = sum(1 for e in d.epochs if e.rolls and e.start < ref * det.EPOCH_S)
            row["rolls_onset_to_known"] = sum(
                1 for e in d.epochs if e.rolls and ref * det.EPOCH_S <= e.start <= (d.asleep_at or 0)
            )
        tm = det.timers(d, [], 0.5)
        row["sound_fade_from_min"] = round(tm.sound_fade_from / 60, 1)
        row["dream_cue_min"] = round(tm.dream_cue_at / 60, 1)
        out.append(row)
    return {"recording": bdf.name, "rows": out}


def beta_power(x: Floats, n_s: int) -> Floats:
    """20-45 Hz power per second at T3/T4 (mean), zero-phase: how check 2 of 2026-11-18 picked muscle."""
    from scipy.signal import butter, sosfiltfilt

    sos = butter(4, [20, 45], "bandpass", fs=det.FS, output="sos")
    out = np.zeros(n_s)
    for c in det.SIDE:
        y = sosfiltfilt(sos, x[c] - x[c][0])[: n_s * det.FS].reshape(n_s, det.FS)
        out += (y**2).mean(axis=1) / 2
    return out


def per_stage(bdf: Path, sleep: Path) -> dict[str, Any]:
    x, miss, start = load_bdf(bdf)
    stages, _ = load_stages(sleep)
    seen = det.detect(x, miss)
    sec = seen.seconds
    beta = beta_power(x, sec.n)
    del x
    n_ep = min(len(stages), len(seen.epochs))
    st_of_s = [stages[k // det.EPOCH_S] if k // det.EPOCH_S < len(stages) else "gap" for k in range(sec.n)]
    minutes = Counter(st_of_s[k] for k in range(sec.n) if not sec.gap[k])
    names = ["W", "N1", "N2", "N3", "R"]

    def per(counts: Counter[str], scale: float) -> dict[str, float]:
        return {s: round(counts[s] / (minutes[s] / 60) * scale, 1) for s in names if minutes[s] >= 300}

    blink = Counter(st_of_s[b.i // det.FS] for b in seen.blinks)
    eye = Counter(st_of_s[e.i // det.FS] for e in seen.eye_moves)
    kinds = {k: Counter(st_of_s[b.start] for b in seen.bursts if b.kind == k) for k in ("jaw", "one-sided", "movement")}
    mov = Counter(st_of_s[a] for a, _ in seen.movement)
    q = Counter((stages[e.index], e.quality) for e in seen.epochs[:n_ep])
    gap_vs_missing = Counter((stages[e.index] == "gap", e.quality == "missing") for e in seen.epochs[:n_ep])
    musc, _ = det.muscle_seconds(sec)
    # check 2's muscle stretches: the top 10 % of wake seconds by 20-45 Hz power; quiet: the lowest 25 %
    wake = np.array([st_of_s[k] == "W" and not sec.gap[k] and sec.qrange[:, k].max() < 1500 for k in range(sec.n)])
    hi, lo = np.percentile(beta[wake], [90, 25])
    top, quiet = wake & (beta >= hi), wake & (beta <= lo)
    return {
        "recording": bdf.name,
        "minutes": {s: round(minutes[s] / 60, 1) for s in names},
        "per_minute": {"blinks": per(blink, 1), "eye_moves": per(eye, 1)},
        "per_hour": {**{f"{k}_bursts": per(v, 60) for k, v in kinds.items()}, "movement_spans": per(mov, 60)},
        "muscle_second_share": {
            s: round(float(np.mean([musc[k] for k in range(sec.n) if st_of_s[k] == s and not sec.gap[k]])), 3)
            for s in names
            if minutes[s] >= 300
        },
        "check2_muscle_seconds_flagged": round(float(musc[top].mean()), 3),
        "check2_quiet_wake_seconds_flagged": round(float(musc[quiet].mean()), 3),
        "jaw_bursts_total": sum(kinds["jaw"].values()),
        "epoch_quality": {f"{s} {qq}": v for (s, qq), v in sorted(q.items())},
        "gap_epochs_vs_missing": {f"gap={a} missing={b}": v for (a, b), v in gap_vs_missing.items()},
        "blink_depth_median_uv_wake": round(float(np.median([b.depth for b in seen.blinks if st_of_s[b.i // det.FS] == "W"])), 1),
    }


def load_run(f32: Path) -> tuple[Floats, det.Bools]:
    """A recorder run: <I4f records (packet, O1 O2 T3 T4 in volts). Lost packets (a skip in the packet
    number) are filled with the last value and marked missing, as `to_bdf.py` does for gaps."""
    raw = f32.read_bytes()
    n = len(raw) // 20
    rec = np.frombuffer(raw[: n * 20], dtype=np.dtype([("p", "<u4"), ("x", "<f4", (4,))]))
    pack = rec["p"].astype(np.int64)
    x = rec["x"].astype(np.float64).T * 1e6
    skip = np.zeros(n, np.int64)
    skip[1:] = np.clip((pack[1:] - pack[:-1] - 1) % 2048, 0, 250)  # the counter wraps; long holes are runs
    fill = int(skip.sum())
    out = np.zeros((4, n + fill))
    miss = np.zeros(n + fill, bool)
    pos = 0
    for i in range(n):
        for _ in range(int(skip[i])):
            out[:, pos] = out[:, pos - 1] if pos else x[:, i]
            miss[pos] = True
            pos += 1
        out[:, pos] = x[:, i]
        pos += 1
    return out, miss


def checkin(f32: Path, markers: Path) -> dict[str, Any]:
    x, miss = load_run(f32)
    # marker sample numbers count received records; map them to positions after filling
    rec_pos = np.flatnonzero(~miss)
    mk: dict[str, int] = {}
    for line in markers.read_text().splitlines():
        m = json.loads(line)
        txt = str(m["text"])
        if txt.startswith("morning:eyes_"):
            mk[txt] = int(rec_pos[min(int(m["i"]), len(rec_pos) - 1)])
    seen = det.detect(x, miss)
    out: dict[str, Any] = {"run": f32.name, "lost_samples": int(miss.sum())}
    for phase in ("eyes_closed", "eyes_open"):
        a, b = mk[f"morning:{phase}:start"], mk[f"morning:{phase}:end"]
        a += 3 * det.FS  # the first 3 s: settling after the tone, as morning_check.py skips
        mins = (b - a) / det.FS / 60
        bl = [e for e in seen.blinks if a <= e.i < b]
        ey = [e for e in seen.eye_moves if a <= e.i < b]
        jw = [e for e in seen.bursts if a <= e.start * det.FS < b]
        out[phase] = {
            "minutes": round(mins, 2),
            "blinks": len(bl),
            "blinks_per_min": round(len(bl) / mins, 1),
            "blink_depth_median_uv": round(float(np.median([e.depth for e in bl])), 1) if bl else None,
            "blink_t34_median_uv": round(float(np.median([e.t34 for e in bl])), 1) if bl else None,
            "eye_moves_per_min": round(len(ey) / mins, 1),
            "bursts": [(e.start, e.end, e.kind) for e in jw],
            "epochs": [e.quality for e in seen.epochs if a <= e.index * det.EPOCH_S * det.FS < b],
        }
    return out


def main(argv: list[str]) -> None:
    if len(argv) < 3:
        raise SystemExit(__doc__)
    cmd = argv[0]
    if cmd == "onset":
        res = onset(Path(argv[1]), Path(argv[2]), argv[3:])
    elif cmd == "stages":
        res = per_stage(Path(argv[1]), Path(argv[2]))
    elif cmd == "checkin":
        res = checkin(Path(argv[1]), Path(argv[2]))
    else:
        raise SystemExit(__doc__)
    print(json.dumps(res, indent=1, default=str))


if __name__ == "__main__":
    main(sys.argv[1:])
