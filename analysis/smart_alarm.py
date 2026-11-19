"""The smart alarm's rule (DECISIONS 230-239), the reference for app/lib/alarm/rule.dart, and its check on a recorded
night: for several windows, when would it have woken you, and in which stage does the full-night scoring put that
moment?

The rule (both sides read the hand-worked cases in app/test/fixtures/smart_alarm_cases.json):
  - you set "wake me by" a time and a window that ends there; the live sleep model (live_stager.py: AnySleep every
    30 s on the last 60 minutes, prepared with only the past) starts 60 minutes before the window. It hands out the
    stage of each epoch 4 epochs (2 min) behind the newest, at max(e + 1 + 4, 10) epochs after it started;
  - inside the window [start, end) the first epoch read N1, N2, R or W wakes you, unless it is within 10 minutes after
    an epoch read N3 (epoch <= last N3 + 20); lost epochs ("gap") never wake you;
  - with no such moment, the window's end wakes you (a plain system alarm in the app).

usage (from the repo root):
  # exact: the live scorer restarted 60 min before each window, as the app runs it (needs the "onnx" group; about
  # 9 minutes a 30-minute window with 4 threads)
  uv run --project analysis --group onnx python analysis/smart_alarm.py replay <recordings dir> <night> <out.npz> \\
      --ends 04:15 04:45 10:30 [--window 30] [--threads 4]
  # the report: those windows, plus a sweep of every window end on a 15-minute grid from a whole-night replay
  # (live_stager.py replay: its scorer ran all night, a little more context in the first hour than the app's)
  uv run --project analysis python analysis/smart_alarm.py report <out.npz> <night>.sleep.json \\
      [--night-replay night.npz] [--json out.json]
"""
from __future__ import annotations

import argparse, json, sys, time
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_stager as ls  # noqa: E402

BEHIND = ls.BEHIND_EP  # 4 epochs, 2 minutes
MIN_EP = ls.MIN_EP  # the first call comes once 10 epochs are in
SCORE_BEFORE_MIN = 60
DEEP_GUARD_EP = 20  # 10 minutes: an epoch may wake you when epoch > last N3 + 20
WAKE_STAGES = {"N1": "light", "N2": "light", "R": "dream", "W": "awake"}
WINDOW_END = "window end"


def handed_s(n: int, behind: int = BEHIND, min_epochs: int = MIN_EP) -> list[int]:
    """Seconds after the live scorer's start at which epoch e's stage is handed out (no delay for the call itself)."""
    return [max(e + 1 + behind, min_epochs) * 30 for e in range(n)]


def wake(stages: list[str | None], handed: list[int], window: tuple[int, int],
         guard: int = DEEP_GUARD_EP) -> tuple[int | None, str, int]:
    """(epoch read or None, why, seconds) on the scorer's clock. `stages`: per live epoch W N1 N2 N3 R, "gap" or None
    (never scored: counted as lost); `handed`: when each was handed out; `window`: [start, end) seconds."""
    start, end = window
    last_deep = None
    for e, (s, t) in sorted(enumerate(zip(stages, handed)), key=lambda x: (x[1][1], x[0])):
        if t >= end:
            break
        if s == "N3":
            last_deep = e
            continue
        if s not in WAKE_STAGES or t < start:
            continue
        if last_deep is not None and e - last_deep <= guard:
            continue
        return e, WAKE_STAGES[s], t
    return None, WINDOW_END, end


def clock(t: float) -> str:
    return datetime.fromtimestamp(t).strftime("%H:%M:%S")


def end_times(night_start: float, ends: list[str]) -> list[float]:
    """Each HH:MM as the first such moment after the night's start."""
    t0 = datetime.fromtimestamp(night_start)
    out = []
    for hm in ends:
        h, m = map(int, hm.split(":"))
        t = t0.replace(hour=h, minute=m, second=0, microsecond=0)
        if t <= t0:
            t += timedelta(days=1)
        out.append(t.timestamp())
    return out


def cmd_replay(a) -> None:
    t0 = time.time()
    start, uv, missing = ls.load_night(a.recordings, a.night)
    n_in = len(uv)
    gap = ls.gap_epochs(missing, ls.ready_epochs(n_in))
    sess = ls.sessions(a.threads)
    out: dict = dict(start=start, night=a.night, gap=gap, window_min=a.window, ends=np.array(end_times(start, a.ends)))
    for j, end in enumerate(out["ends"]):
        score_from = end - (a.window + SCORE_BEFORE_MIN) * 60
        e0 = max(0, int(np.ceil((score_from - start) / 30)))  # the night's first epoch at or after it
        s0 = e0 * ls.EPOCH_IN
        last = int((end - (start + e0 * 30)) // 30) + 1  # epochs whose stage could be handed out before the end
        res = ls.prepare_stream(uv[s0:])
        r = ls.replay(res, gap[e0:], n_in - s0, sess, last=last, progress=None)
        out[f"w{j}_e0"] = e0
        out[f"w{j}_lag"] = r["lag"]
        out[f"w{j}_call_s"] = r["call_s"]
        print(f"window ending {clock(end)}: scorer from {clock(start + e0 * 30)}, {len(r['call_s'])} calls, "
              f"{time.time() - t0:.0f} s", flush=True)
    np.savez_compressed(a.out, **out)
    print(f"done in {time.time() - t0:.0f} s -> {a.out}", flush=True)


def _offline(offline: list[str], e: int) -> str | None:
    return offline[e] if 0 <= e < len(offline) else None


def _row(start: float, offline: list[str], e0: int, stages: list[str | None], handed: list[int], end: float,
         window_min: int, scorer_start: float) -> dict:
    w0 = end - window_min * 60
    ep, why, at = wake(stages, handed, (int(round(w0 - scorer_start)), int(round(end - scorer_start))))
    at_t = scorer_start + at
    at_ep = int((at_t - start) // 30)
    plain_ep = int((end - start) // 30)
    return dict(window=f"{clock(w0)[:5]}-{clock(end)[:5]}", wake=clock(at_t), why=why,
                min_before_end=round((end - at_t) / 60, 1),
                read_epoch=None if ep is None else clock(start + (e0 + ep) * 30),
                live_stage=None if ep is None else stages[ep],
                offline_read=None if ep is None else _offline(offline, e0 + ep),
                offline_at_wake=_offline(offline, at_ep),
                offline_at_end=_offline(offline, plain_ep))


def summary(rows: list[dict]) -> dict:
    """How often the wake (and a plain alarm at the window's end) lands in deep sleep by the full-night scoring."""
    asleep = [r for r in rows if r["offline_at_end"] not in (None, "W", "gap")]
    n = len(asleep)
    deep = lambda key: sum(1 for r in asleep if r[key] == "N3")  # noqa: E731
    return dict(windows=len(rows), ending_asleep=n,
                smart_wake_in_deep=deep("offline_at_wake"), plain_alarm_in_deep=deep("offline_at_end"),
                smart_by_stage=sorted({w for r in asleep for w in [r["why"]]}),
                median_min_early=float(np.median([r["min_before_end"] for r in asleep])) if asleep else None)


def cmd_report(a) -> None:
    offline = [e["anysleep"] for e in json.loads(Path(a.sleep_json).read_text())["epochs"]]
    rep: dict = dict(rules=dict(behind_epochs=BEHIND, min_epochs=MIN_EP, score_before_min=SCORE_BEFORE_MIN,
                                deep_guard_epochs=DEEP_GUARD_EP, wake_stages=WAKE_STAGES))
    if a.npz:
        z = np.load(a.npz)
        start, gap, wmin = float(z["start"]), z["gap"], int(z["window_min"])
        rows = []
        for j, end in enumerate(z["ends"]):
            e0 = int(z[f"w{j}_e0"])
            lag = z[f"w{j}_lag"]
            g = gap[e0:e0 + lag.shape[2]]
            st = ls.stages_at(ls.mask_gappy(lag, g), BEHIND, g)
            row = _row(start, offline, e0, st, handed_s(len(st)), float(end), wmin, start + e0 * 30)
            row["calls"] = len(z[f"w{j}_call_s"])
            rows.append(row)
        rep["exact"] = rows
        rep["exact_summary"] = summary(rows)
    if a.night_replay:
        z = np.load(a.night_replay)
        start, gap = float(z["start"]), z["gap"]
        st_all = ls.stages_at(ls.mask_gappy(z["lag"], gap), BEHIND, gap)
        n = min(len(st_all), len(offline))
        rows = []
        first = start + (SCORE_BEFORE_MIN + a.window) * 60
        t = (int(first // 900) + 1) * 900
        while t <= start + n * 30 - 300:
            e_from = max(0, int(np.ceil((t - (a.window + SCORE_BEFORE_MIN) * 60 - start) / 30)))
            st = [st_all[e] for e in range(e_from, n)]
            handed = [(e - e_from + 1 + BEHIND) * 30 for e in range(e_from, n)]  # its scorer was running already
            rows.append(_row(start, offline, e_from, st, handed, float(t), a.window, start + e_from * 30))
            t += 900
        rep["sweep"] = rows
        rep["sweep_summary"] = summary(rows)
    text = json.dumps(rep, indent=1)
    if a.json:
        Path(a.json).write_text(text)
    print(text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("replay")
    r.add_argument("recordings", type=Path); r.add_argument("night"); r.add_argument("out", type=Path)
    r.add_argument("--ends", nargs="+", required=True, help="wake-by times, HH:MM")
    r.add_argument("--window", type=int, default=30); r.add_argument("--threads", type=int, default=4)
    p = sub.add_parser("report")
    p.add_argument("npz", type=Path, nargs="?"); p.add_argument("sleep_json", type=Path)
    p.add_argument("--night-replay", type=Path); p.add_argument("--window", type=int, default=30)
    p.add_argument("--json", type=Path)
    a = ap.parse_args()
    {"replay": cmd_replay, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
