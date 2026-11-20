"""The walking detector against what is known: scored sleep (no walking may be found there) and a walk (how much of it
is found). DECISIONS 801; docs/detectors.md "Sleep is no walk".

  uv run --project analysis python analysis/validate_walking.py sleep NIGHT.bdf NIGHT.sleep.json [...]
      per night: epochs by stage with any walking stretch in them, and the windows that walked
  uv run --project analysis python analysis/validate_walking.py walk REC.f32 [REC2.f32 ...] --from HH:MM --to HH:MM
      walking minutes inside and outside the span, steps, pace, the walks

A night's stages are placed from its .sleep.json's first epoch time (the BDF's own start is written as UTC by the
laptop's old BDFs). Every channel of the BDF is read, as the phone reads every channel of a recording.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "analysis"))
import walking as wk  # noqa: E402

STAGES = ("W", "N1", "N2", "N3", "R")
SLEEP = ("N1", "N2", "N3", "R")


def bdf_signal(path: Path) -> tuple[np.ndarray, float, np.ndarray]:
    import mne
    raw = mne.io.read_raw_bdf(path, preload=True, verbose="error")
    fs = float(raw.info["sfreq"])
    x = raw.get_data() * 1e6
    miss = np.zeros(x.shape[1], dtype=bool)
    for a in raw.annotations:
        if str(a["description"]).startswith("BAD") and a["duration"] > 0:
            i = int(round(a["onset"] * fs))
            miss[i:i + int(round(a["duration"] * fs))] = True
    return np.clip(x, -400_000, 400_000), fs, miss


def sleep(bdf: Path, sleep_json: Path) -> tuple[int, int]:
    """Prints a night's check; returns (sleep epochs with walking, sleep epochs)."""
    ep = json.loads(sleep_json.read_text())["epochs"]
    x, fs, miss = bdf_signal(bdf)
    start = datetime.fromisoformat(ep[0]["t"]).astimezone().timestamp()
    found = wk.find(wk.windows(x, fs, miss))
    moving = np.zeros(len(found.windows), dtype=bool)
    for s in found.moving:
        moving[s.first:s.last + 1] = True
    t = np.array([start + w.t for w in found.windows])
    cnt: collections.Counter = collections.Counter()
    hit: collections.Counter = collections.Counter()
    for e in ep:
        t0 = datetime.fromisoformat(e["t"]).astimezone().timestamp()
        m = (t >= t0) & (t < t0 + 30)
        st = e.get("anysleep") or e.get("stage")
        if not m.any() or st not in STAGES:
            continue
        cnt[st] += 1
        hit[st] += bool(moving[m].any())
    raw_walks = sum(w.walks for w in found.windows)
    n, h = sum(cnt[k] for k in SLEEP), sum(hit[k] for k in SLEEP)
    print(f"{bdf.name}: walking epochs by stage {', '.join(f'{k} {hit[k]}/{cnt[k]}' for k in STAGES)}; sleep {h}/{n}; "
          f"single windows that walked {raw_walks} of {len(found.windows)}, smoothed {sum(found.smoothed)}")
    return h, n


def walk(paths: list[Path], a: str, b: str) -> None:
    import to_bdf
    start, uv, notes = to_bdf.join(paths)
    fs = to_bdf.night_header(paths).sample_rate
    x = np.ascontiguousarray(np.clip(uv, -400_000, 400_000).T)
    miss = np.zeros(x.shape[1], dtype=bool)
    for onset, dur, text in notes:
        if text.startswith("BAD") and dur > 0:
            miss[round(onset * fs):round((onset + dur) * fs)] = True
    found = wk.find(wk.windows(x, fs, miss))
    day = start.date()

    def at(hhmm: str) -> float:
        h, m = map(int, hhmm.split(":"))
        t = datetime.combine(day, datetime.min.time()).replace(hour=h, minute=m)
        return (t if t >= start else t + timedelta(days=1)).timestamp()

    lo, hi = at(a), at(b)
    inside = outside = 0.0
    for s in found.moving:
        for i in range(s.first, s.last + 1):
            t = start.timestamp() + found.windows[i].t
            if lo <= t < hi:
                inside += wk.HOP_S
            else:
                outside += wk.HOP_S
    clear = [found.windows[i].pace for s in found.moving for i in range(s.first, s.last + 1) if found.windows[i].walks]
    print(f"walking {inside / 60:.1f} min inside {a}-{b}, {outside / 60:.1f} min outside; "
          f"{sum(s.steps for s in found.moving):.0f} steps; pace {wk.det.median(clear) if clear else float('nan'):.1f}")
    for w in found.walks:
        s0 = datetime.fromtimestamp(start.timestamp() + found.windows[w.stretches[0].first].t - wk.HOP_S / 2)
        s1 = datetime.fromtimestamp(start.timestamp() + found.windows[w.stretches[-1].last].t + wk.HOP_S / 2)
        print(f"  walk {s0:%H:%M}-{s1:%H:%M}: {w.walking_s / 60:.1f} min walking, {w.stopped_s / 60:.1f} stopped, "
              f"{sum(1 for s in w.stretches if s.kind == 'stopped')} stops, {w.steps:.0f} steps")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="what", required=True)
    s = sub.add_parser("sleep")
    s.add_argument("pairs", nargs="+", type=Path, help="NIGHT.bdf NIGHT.sleep.json, as many pairs as you like")
    w = sub.add_parser("walk")
    w.add_argument("files", nargs="+", type=Path)
    w.add_argument("--from", dest="a", required=True)
    w.add_argument("--to", dest="b", required=True)
    a = ap.parse_args()
    if a.what == "sleep":
        if len(a.pairs) % 2:
            ap.error("give pairs: NIGHT.bdf NIGHT.sleep.json")
        h = n = 0
        for i in range(0, len(a.pairs), 2):
            dh, dn = sleep(a.pairs[i], a.pairs[i + 1])
            h, n = h + dh, n + dn
        print(f"all: {h}/{n} sleep epochs with walking ({100 * h / max(1, n):.2f} %)")
    else:
        walk(a.files, a.a, a.b)


if __name__ == "__main__":
    main()
