"""A small generator of night recordings as the phone app writes them (app/lib/recorder/night_recorder.dart), for the
tests of scripts/phone_night_check.py: drops with reconnect tries, lost packets, data held back by Android, a killed
process, Android's restart, a stuck SDK call, the phone and headband battery lines.

Nothing real: the signal is made up (alpha-like sines and noise, T3 with mains hum, T4 flat), the address and the
serial are zeros. Times are seconds after the run's file stamp, the stamp is local time like the app's.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

FS = 250
BATCH = 8  # samples per batch, as BrainBit's SDK delivers them
ADDRESS = "00:00:00:00:00:00"
SETTINGS = ("android 34, battery-opt exempt yes, background restricted no, power save no, standby bucket 10, "
            "notifications yes, xiaomi OS1.0.0.0")
REC = np.dtype([("pack", "<u4"), ("v", "<f4", 4)])
IDX = np.dtype([("t", "<f8"), ("i", "<u8")])


def stem(t: datetime) -> str:
    return t.strftime("%Y-%m-%d-%H%M%S")


def logtime(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}"


@dataclass
class PhoneRun:
    """One recorder run (one connection): `<stamp>.f32 .idx .log`."""
    start: datetime
    seconds: float  # of signal
    data_at: float = 8.0  # the first sample, seconds after the stamp
    lost: list[tuple[float, int]] = field(default_factory=list)  # (second of signal, packet numbers skipped)
    late: list[tuple[float, float]] = field(default_factory=list)  # (second of signal, hold): batches due then arrive
    # `hold` seconds late, in one burst
    pack0: int = 8
    stale_first: int | None = None  # the first batch carries these numbers (the SDK's leftover), then pack0 on
    band_battery: tuple[int, int] = (90, 88)
    phone_battery: tuple[int, int] | None = (100, 99)
    contact: str | None = "O1=120000 O2=95000 T3=48000 T4=31000"
    signal: str = "-70 dBm"
    head: list[str] = field(default_factory=list)  # notes before "connected": a restart, how it reconnected
    end: str = "stop"  # stop | drop | stall | killed | stuck
    night_end: bool = False  # Stop ended the night: the end-of-night lines follow
    after: list[tuple[float, str]] = field(default_factory=list)  # (seconds after the last data, line): reconnect
    # tries, which the app appends to the last closed run's log
    hum_t3: bool = True
    flat_t4: bool = True
    log: list[tuple[float, str]] | None = None  # the whole log instead (seconds after the stamp, line)
    app_counts: str | None = None  # the app's packet line ("N samples, missing ..."), the night's; else this run's

    @property
    def first(self) -> datetime:
        return self.start + timedelta(seconds=self.data_at)

    @property
    def last(self) -> datetime:
        return self.start + timedelta(seconds=self.data_at + self.seconds)


def signal(n: int, run: PhoneRun, seed: int = 1) -> np.ndarray:
    t = np.arange(n) / FS
    noise = np.random.default_rng(seed).normal(0, 5e-6, (n, 3))
    v = np.zeros((n, 4))
    v[:, 0] = 30e-6 * np.sin(2 * np.pi * 10 * t) + noise[:, 0]
    v[:, 1] = 25e-6 * np.sin(2 * np.pi * 11 * t) + noise[:, 1]
    v[:, 2] = 20e-6 * np.sin(2 * np.pi * 6 * t) + noise[:, 2] + (300e-6 * np.sin(2 * np.pi * 50 * t) if run.hum_t3
                                                                 else 0)
    if not run.flat_t4:
        v[:, 3] = 15e-6 * np.sin(2 * np.pi * 9 * t) + noise[:, 0] * 0.8
    return v


def packets(run: PhoneRun, n: int) -> np.ndarray:
    p = run.pack0 + np.arange(n, dtype=np.int64)
    for sec, skip in run.lost:
        p[int(sec * FS):] += skip
    if run.stale_first is not None:
        p[:BATCH] = run.stale_first + np.arange(BATCH)
    return p


def arrivals(run: PhoneRun, n: int) -> tuple[np.ndarray, np.ndarray]:
    first = np.arange(0, n, BATCH)
    t0 = run.first.timestamp()
    t = t0 + np.minimum(first + BATCH, n) / FS + 0.002
    for sec, hold in run.late:
        due = (t >= t0 + sec) & (t < t0 + sec + hold)
        t[due] = t0 + sec + hold + np.arange(due.sum()) * 1e-4
    return t, first


def counts(run: PhoneRun, n: int) -> str:
    missing = sum(k for _, k in run.lost)
    longest = max((k for _, k in run.lost), default=0)
    return (f"{max(0, n - 1)} samples, missing {missing} in {len(run.lost)} gaps, repeated 0, "
            f"longest gap {longest} samples")


def phone_battery(run: PhoneRun, frac: float) -> str:
    a, z = run.phone_battery or (0, 0)
    pct = round(a + (z - a) * frac)
    return f"phone battery {pct}% charge {3_900_000 - int(frac * 40_000)} uAh current -310250 uA unplugged temp 30.5 C"


def log_lines(run: PhoneRun, n: int) -> list[tuple[float, str]]:
    if run.log is not None:
        return run.log
    lines: list[tuple[float, str]] = [(0.01 * k, line) for k, line in enumerate(run.head)]
    b0, b1 = run.band_battery
    lines.append((0.5, f"connected BB Black {ADDRESS} serial 0000000000 battery {b0}% signal {run.signal}"))
    lines.append((0.6, f"phone {SETTINGS}"))
    if run.phone_battery:
        lines.append((0.7, phone_battery(run, 0)))
    if run.contact:
        lines.append((run.data_at - 1.0, f"contact ohms {run.contact}"))
    lines.append((run.data_at - 0.5, "recording started, 250 Hz"))
    end = run.data_at + run.seconds
    for s in np.arange(10, run.seconds + 1e-9, 10):
        frac = s / run.seconds
        got = 2500
        lines.append((run.data_at + s, f"samples {int(s * FS)} (+{got}) battery {round(b0 + (b1 - b0) * frac)}%"))
        if run.phone_battery and int(s) % 60 == 0:
            lines.append((run.data_at + s + 0.01, phone_battery(run, frac)))
    last = logtime(run.last)
    total = [(0.2, f"packets: {run.app_counts or counts(run, n)}"), (0.3, f"total samples {n}, {n / FS / 60:.1f} min")]
    if run.end == "stop":
        lines += [(end + d, x) for d, x in total] + [(end + 0.4, f"stopped, battery {b1}%")]
    elif run.end == "drop":
        lines += [(end + 0.1, "headband out of range; saving")] + [(end + d, x) for d, x in total]
        lines.append((end + 0.4, f"drop (out of range); last data {last}; reconnecting"))
    elif run.end == "stall":
        lines += [(end + 10 * k, f"no data, state inRange; restarting stream (try {k})") for k in (1, 2, 3)]
        lines += [(end + 10 * k + 0.1, "stream restarted") for k in (1, 2, 3)]
        lines.append((end + 40, "still no data; reconnecting"))
        lines += [(end + 40 + d, x) for d, x in total]
        lines += [(end + 40.4, f"drop (no data); last data {last}; reconnecting"),
                  (end + 40.5, f"stopped, battery {b1}%")]
    elif run.end == "stuck":
        lines.append((end + 30, 'SDK call "battery" stuck for 30 s; saved, restarting the app process'))
    if run.night_end:
        lines.append((end + 1.0, phone_battery(run, 1)))
        lines.append((end + 1.1, f"end of night, packets: {run.app_counts or counts(run, n)}"))
        lines.append((end + 1.2, "phone battery summary: 1% in 0.2 h = 5.00 %/h, 40 mAh = 200 mAh/h"))
    after = run.data_at + run.seconds
    lines += [(after + d, x) for d, x in run.after]
    return sorted(lines, key=lambda x: x[0])


def write_run(folder: Path, run: PhoneRun, seed: int = 1) -> Path:
    """Writes the run's three files; returns its `.f32` path."""
    folder.mkdir(parents=True, exist_ok=True)
    n = int(round(run.seconds * FS))
    rec = np.zeros(n, dtype=REC)
    rec["pack"] = packets(run, n) % 2**32
    rec["v"] = signal(n, run, seed)
    name = stem(run.start)
    rec.tofile(folder / f"{name}.f32")
    t, first = arrivals(run, n)
    idx = np.zeros(len(t), dtype=IDX)
    idx["t"], idx["i"] = t, first
    idx.tofile(folder / f"{name}.idx")
    text = "".join(f"{logtime(run.start + timedelta(seconds=s))} {line}\n" for s, line in log_lines(run, n))
    (folder / f"{name}.log").write_text(text)
    return folder / f"{name}.f32"


def write_empty_run(folder: Path, start: datetime, lines: list[tuple[float, str]]) -> None:
    """A run that connected but recorded nothing (empty .f32 and .idx)."""
    name = stem(start)
    (folder / f"{name}.f32").write_bytes(b"")
    (folder / f"{name}.idx").write_bytes(b"")
    (folder / f"{name}.log").write_text(
        "".join(f"{logtime(start + timedelta(seconds=s))} {line}\n" for s, line in lines))


def write_report(folder: Path, night: str, runs: list[Path], scoring_s: float = 95.0) -> None:
    """A phone sleep report (`files/nights/<date>.report.json`) with the fields the check reads."""
    folder.mkdir(parents=True, exist_ok=True)
    rep = {"version": 2, "night_of": night, "source": "phone", "scoring_s": scoring_s, "scored": True,
           "inputs": [{"file": p.name, "bytes": p.stat().st_size} for p in runs],
           "total": {"asleep_min": 6.5, "periods": 1, "recorded_min": 14.0, "missing_min": 2.0},
           "extras": {"night": {"min": 14.0, "good_min": 11.0, "degraded_min": 1.0, "missing_min": 2.0}}}
    (folder / f"{night}.report.json").write_text(json.dumps(rep))
