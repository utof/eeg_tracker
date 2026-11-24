"""Automatic sleep report: score the nights recorded in the last hours and split them into sleep periods.

usage: sleep_report.py [--recordings _local/recordings] [--nights _local/nights] [--export _local/export]
                       [--hours 20] [--anysleep _local/vendor/AnySleep] [--device cpu] [--force]
Run with the analysis environment:  uv run --project analysis python scripts/sleep_report.py
The recorder hub starts it from the Sleep page (POST /sleep-report) under systemd-run with MemoryMax=3500M.

For every night with data in the last --hours hours (night_files.py: recordings chained in time, named by the
evening date) whose report is missing or lacks 10+ minutes of newer samples, it joins the recordings with
to_bdf.py's code into <nights>/<date>.bdf, scores it with score_sleep.py's code (<date>.sleep.json and
<date>.hypnogram.png), splits the AnySleep stages into sleep periods, runs the shared detectors over the same samples
for the night extras (analysis/night_extras.py: jaw, movement and signal quality, as on the phone) and the
drift-off detector from the night's lights off against the model's sleep onset (analysis/night_drift.py) and the
dream sleep check (analysis/rem_check.py: the model's per-epoch probabilities and side-to-side eye movements on the
night's eye pair, T3-T4 on the BrainBit; measurement only, as on the phone), scores every epoch the walking detector
calls walking as awake (analysis/walking.py over every channel of the night; DECISIONS 920), writes
<date>.report.json
(docs/data-format.md) and appends the eeg_sleep_night event (export_events.py). Nights already up to date are
skipped, so running it twice does nothing the second time. A night may hold any number of channels (its files'
<stamp>.header.json, scripts/recording.py): its BDF keeps them all under their names, and the model and the detectors
read O1 O2 T3 T4, found by name or 10-10 site. A night without those four (or whose files hold different channels)
is refused in words, nothing is written for it, and the other nights are still built (exit status 1). One run at a time (a lock file); it lowers its own
CPU priority and stops itself past --max-minutes or --max-mb, so the recorder keeps going.
"""
from __future__ import annotations

import argparse, json, os, resource, subprocess, sys, threading, time, traceback
from datetime import datetime, timedelta
from pathlib import Path

import night_files as nf
import recording

ROOT = Path(__file__).resolve().parent.parent
EPOCH = 30
ASLEEP = {"N1", "N2", "N3", "R"}
SPLIT_MIN = 60  # asleep stretches separated by this much wake or missing data are separate periods
MIN_PERIOD_SLEEP_MIN = 10  # shorter "periods" are scorer noise; their minutes count as stray sleep
WAKE_UP_OVER_MIN = 5
NOTE = "first guess; the scorer is not yet validated on this headband"


SCORED = {"W"} | ASLEEP
STAGE_CHAR = {"W": "W", "N1": "1", "N2": "2", "N3": "3", "R": "R"}  # the report's `stages`, as the phone's; `-` gap


def _agreement(pairs: list[tuple[str, str]]) -> dict | None:
    if not pairs:
        return None
    coarse = lambda s: "W" if s == "W" else "R" if s == "R" else "NREM"  # noqa: E731
    return dict(five_stage=round(sum(x == y for x, y in pairs) / len(pairs), 3),
                wake_nrem_rem=round(sum(coarse(x) == coarse(y) for x, y in pairs) / len(pairs), 3), epochs=len(pairs))


def _wake_ups(stages: list[str], a: int, b: int, over_min: float) -> list[dict]:
    """Stretches of not-asleep epochs between a and b with more than over_min minutes scored awake."""
    out, k = [], a
    while k <= b:
        if stages[k] in ASLEEP:
            k += 1
            continue
        j = k
        while j <= b and stages[j] not in ASLEEP:
            j += 1
        awake = sum(s == "W" for s in stages[k:j]) * EPOCH / 60
        if awake > over_min:
            out.append(dict(epoch=k, awake_min=awake))
        k = j
    return out


def periods(stages: list[str], other: list[str] | None = None, conf: list[float] | None = None,
            split_min: float = SPLIT_MIN, min_sleep_min: float = MIN_PERIOD_SLEEP_MIN,
            wake_over_min: float = WAKE_UP_OVER_MIN) -> tuple[list[dict], float]:
    """Sleep periods from one stage per 30 s epoch (W N1 N2 N3 R, "gap" for missing data, anything else unscored).

    Asleep epochs belong to one period unless 60+ minutes of other epochs separate them. Returns the periods (epoch
    indices `first` and `last`, inclusive, and minutes) and the asleep minutes left out as too short to count."""
    runs: list[list[int]] = []
    for i in (i for i, s in enumerate(stages) if s in ASLEEP):
        if runs and (i - runs[-1][-1] - 1) * EPOCH < split_min * 60:
            runs[-1].append(i)
        else:
            runs.append([i])
    out, stray = [], 0.0
    for run in runs:
        if len(run) * EPOCH / 60 < min_sleep_min:
            stray += len(run) * EPOCH / 60
            continue
        a, b = run[0], run[-1]
        span = stages[a:b + 1]
        pairs = [(stages[i], other[i]) for i in range(a, b + 1) if other and stages[i] in SCORED and other[i] in SCORED]
        sure = [conf[i] for i in range(a, b + 1) if conf and stages[i] in SCORED]
        out.append(dict(first=a, last=b, asleep_min=len(run) * EPOCH / 60,
                        stage_min={s: span.count(s) * EPOCH / 60 for s in ("W", "N1", "N2", "N3", "R")},
                        wake_ups=_wake_ups(stages, a, b, wake_over_min), missing_min=span.count("gap") * EPOCH / 60,
                        agreement=_agreement(pairs), confidence=round(sum(sure) / len(sure), 3) if sure else None))
    return out, stray


def _extras(seen: tuple | None, stages: list[str], found: list[dict], start: datetime, at) -> dict | None:
    """The report's `extras` (night_extras.summary) with each hour's clock time; None without the detectors' pass."""
    if seen is None:
        return None
    import night_extras as nx
    quality, bursts, moves = seen
    x = nx.summary(quality, bursts, moves, stages, [(p["first"], p["last"]) for p in found], nx.first_edge_s(start))
    for h in x["hours"]:
        h["start"] = at(start + timedelta(seconds=h["from_s"]))
    return x


def night_walking(uv, notes: list, sample_rate: float) -> list:
    """The walking detector's windows over the joined night (every channel, `uv` samples x channels in µV), only as
    far as the veto needs them (analysis/walking.py, `quick`)."""
    sys.path.insert(0, str(ROOT / "analysis"))
    import numpy as np
    import walking as wk
    import walks
    if sample_rate != round(sample_rate) or sample_rate < 50:
        raise recording.RecordingError(f"walking reads a whole number of samples a second from 50; this night has "
                                       f"{sample_rate:g}")
    x = np.ascontiguousarray(uv.T, dtype=np.float64)
    np.clip(x, -walks.LIMIT_UV, walks.LIMIT_UV, out=x)
    return wk.windows(x, sample_rate, walks.missing_mask(x.shape[1], sample_rate, notes), quick=True)


def walking_veto(scored: dict, windows: list) -> dict:
    """Scores the walking epochs of score_sleep's result awake, in place: both models' stage of an epoch the walking
    detector calls walking becomes W (the model's own word stays beside it as `anysleep_model` / `yasa_model`, the
    epoch gets `walking`), the summary is counted again, and the report's `walking` object is returned."""
    import numpy as np
    import score_sleep
    import walking as wk
    ep = scored["epochs"]
    flags = wk.epoch_flags(windows, len(ep))
    changed = {"anysleep": 0, "yasa": 0}
    for e, on in zip(ep, flags):
        if not on:
            continue
        e["walking"] = True
        for k in changed:
            if e.get(k) in ASLEEP:
                e[f"{k}_model"], e[k] = e[k], "W"
                changed[k] += 1
    gap = np.array([e["anysleep"] == "gap" for e in ep])
    scored["summary"] = score_sleep.summary([e["anysleep"] for e in ep], gap, [e["yasa"] for e in ep],
                                            np.array([max(e["p"]) for e in ep]))
    out = dict(detector=wk.VERSION, rule="an asleep epoch with half or more of it in a walking stretch is scored awake",
               epochs="".join("1" if f else "0" for f in flags), walking_min=sum(flags) * EPOCH / 60,
               changed_min=changed["anysleep"] * EPOCH / 60, cross_check_changed_min=changed["yasa"] * EPOCH / 60)
    scored["walking"] = {k: v for k, v in out.items() if k != "epochs"}
    return out


def make_report(name: str, night: nf.Night, scored: dict | None, seconds: float, data: tuple[datetime, float],
                seen: tuple | None = None, extras_error: str | None = None, drift: dict | None = None,
                drift_error: str | None = None, eye: dict | None = None, walking: dict | None = None,
                walking_error: str | None = None) -> dict:
    """<name>.report.json from score_sleep's result (None when there was too little data to score), what the
    detectors saw (`night_extras.events`, None when that pass did not run), the drift-off detector from lights
    off (`night_drift.night`, None when it did not run; drift_error says why) and the eye movements for the dream
    sleep check (`rem_check.eye_measured` / `eye_not`; None: not measured)."""
    start, length_s = data
    at = lambda t: t.astimezone().isoformat(timespec="seconds")  # noqa: E731
    rep: dict = dict(version=nf.VERSION, night_of=name, built=at(datetime.now()), scoring_s=round(seconds, 1),
                     data_start=at(start), data_end=at(start + timedelta(seconds=length_s)),
                     inputs=[dict(file=r.path.name, bytes=r.size) for r in night.recs], scored=scored is not None,
                     note=NOTE, validated=False,
                     rules=dict(split_min=SPLIT_MIN, min_period_sleep_min=MIN_PERIOD_SLEEP_MIN,
                                wake_up_over_min=WAKE_UP_OVER_MIN))
    if scored is None:
        rep.update(periods=[], total=dict(asleep_min=0.0, light_min=0.0, deep_min=0.0, dream_min=0.0, wake_ups=0,
                                          periods=0, recorded_min=round(length_s / 60, 1), missing_min=0.0,
                                          stray_sleep_min=0.0),
                   hypnogram=None, sleep_json=None, bdf=None, model=None, cross_check=None, extras=None,
                   extras_error=extras_error, drift_off=None, drift_off_error=None, stages="", probs=None,
                   rem_check=None, walking=None, walking_error=None)
        return rep
    import export_events
    ep = scored["epochs"]
    t0 = datetime.fromisoformat(scored["start"])
    t = lambda i: at(t0 + timedelta(seconds=EPOCH * i))  # noqa: E731
    found, stray = periods([e["anysleep"] for e in ep], [e["yasa"] for e in ep], [max(e["p"]) for e in ep])
    drift_off, drift_error = None, extras_error or drift_error  # a failed detectors' pass ran no drift-off either
    if drift is not None and drift_error is None:
        import night_drift as nd
        try:
            drift_off = nd.report(drift, [e["anysleep"] for e in ep], start)
        except Exception as e:  # noqa: BLE001 - the night is still scored without it; the report says why
            drift_error = f"{type(e).__name__}: {e}"
    try:
        extras = _extras(seen, [e["anysleep"] for e in ep], found, start, at)
    except Exception as e:  # noqa: BLE001 - the night is still scored without the extras; the report says why
        extras, extras_error = None, f"{type(e).__name__}: {e}"
    out = []
    for p in found:
        sm = p["stage_min"]
        out.append(dict(start=t(p["first"]), end=t(p["last"] + 1), asleep_min=p["asleep_min"],
                        light_min=sm["N1"] + sm["N2"], deep_min=sm["N3"], dream_min=sm["R"], awake_min=sm["W"],
                        stage_min=sm, wake_ups=len(p["wake_ups"]),
                        wake_up_list=[dict(start=t(w["epoch"]), awake_min=w["awake_min"]) for w in p["wake_ups"]],
                        missing_min=p["missing_min"], agreement=p["agreement"], confidence=p["confidence"]))
    if str(ROOT / "analysis") not in sys.path:
        sys.path.insert(0, str(ROOT / "analysis"))
    import rem_check as rc
    stages = [e["anysleep"] for e in ep]
    probs = rc.encode_probs([e["p"] for e in ep])
    if eye is None:
        eye = rc.eye_not("not measured: the signal pass failed (see extras_error)" if extras_error else "not measured")
    check = rc.night_check(stages, [(p["first"], p["last"]) for p in found], rc.decode_probs(probs), eye)
    s = scored["summary"]
    total = {k: sum(p[k] for p in out) for k in ("asleep_min", "light_min", "deep_min", "dream_min", "wake_ups")}
    total.update(periods=len(out), recorded_min=s["recorded_min"], missing_min=s["gap_min"], stray_sleep_min=stray)
    rep.update(periods=out, total=total, hypnogram=f"{name}.hypnogram.png", sleep_json=f"{name}.sleep.json",
               bdf=f"{name}.bdf", model=export_events.MODEL,
               cross_check=dict(model=export_events.CROSS, agreement_5_stage=s.get("agreement_5_stage"),
                                agreement_w_nrem_rem=s.get("agreement_w_nrem_rem")),
               extras=extras, extras_error=extras_error, drift_off=drift_off, drift_off_error=drift_error,
               stages="".join(STAGE_CHAR.get(x, "-") for x in stages), probs=probs, rem_check=check,
               walking=walking, walking_error=walking_error)
    return rep


def _keep_foreign(folder: Path, name: str) -> None:
    """Files of this name made by hand (no report beside them) are renamed <name>-manual.*, never overwritten."""
    if (folder / f"{name}.report.json").exists():
        return
    for suffix in (".bdf", ".sleep.json", ".hypnogram.png"):
        p = folder / f"{name}{suffix}"
        if p.exists():
            k, dst = 1, folder / f"{name}-manual{suffix}"
            while dst.exists():
                k += 1; dst = folder / f"{name}-manual{k}{suffix}"
            os.replace(p, dst)
            print(f"kept an earlier {p.name} as {dst.name}", flush=True)


def night_eye(head: recording.Header, uv, notes: list) -> dict:
    """Side-to-side eye movements per epoch on the night's eye pair (analysis/rem_check.py), for the dream sleep
    check: `eye_measured`, or `eye_not` with why (no pair on this layout, or the detector failed). `uv` (n x channels,
    µV) as to_bdf.join gives it; the pair's columns are clipped to the BDF's range as the phone reads them."""
    sys.path.insert(0, str(ROOT / "analysis"))
    import night_extras as nx
    import numpy as np
    import rem_check as rc
    pair = rc.eye_pair(head)
    if pair is None:
        return rc.eye_not(rc.NO_PAIR)
    try:
        lim = nx.LIMIT_UV
        left, right = (np.clip(uv[:, k], -lim, lim) for k in (pair.left, pair.right))
        return rc.eye_measured(pair.label, rc.eye_epochs(left, right, nx.missing_mask(len(uv), notes),
                                                         int(round(head.sample_rate))))
    except Exception as e:  # noqa: BLE001 - the night is still scored without them; the check says why
        return rc.eye_not(f"not measured: {type(e).__name__}: {e}")


def build(night: nf.Night, a: argparse.Namespace, status: nf.Job) -> dict:
    import score_sleep, to_bdf
    name, folder = night.name, a.nights
    t_start = time.time()
    hours = sum(r.minutes for r in night.recs) / 60
    paths = [r.path for r in night.recs]
    head = to_bdf.night_header(paths)  # the files hold the same channels, else refused here
    four = recording.pick(head, score_sleep.CHANNELS, score_sleep.WHO)  # refused here without O1 O2 T3 T4
    status.step(f"Night of {name}: joining {len(night.recs)} recordings ({hours:.1f} h)")
    start, uv, notes = to_bdf.join(paths)
    length_s = len(uv) / head.sample_rate
    if length_s < 10 * EPOCH:
        rep = make_report(name, night, None, time.time() - t_start, (start, length_s))
    else:
        status.step("Counting jaw, movement and signal")
        seen, why, drift, drift_why = None, None, None, None
        try:  # before scoring, so its memory is free again when the model runs
            sys.path.insert(0, str(ROOT / "analysis"))
            import night_extras as nx
            if head.sample_rate != nx.det.FS:
                raise recording.RecordingError(f"the detectors read {nx.det.FS} Hz; this night is "
                                               f"{head.sample_rate:g} Hz")
            if four == list(range(uv.shape[1])):
                full = nx.see(uv, notes, in_place=True)  # clipped as the BDF below clips it: no second copy
            else:  # more channels than the four: the detectors get those four, the BDF keeps them all
                full = nx.see(uv[:, four], notes, in_place=True)
            seen = nx.events(full)
            try:  # the drift-off detector from the night's lights off (night_drift.py)
                import night_drift as nd
                drift = nd.night(full, nf.lights_off(night), int(start.timestamp()))
            except Exception as e:  # noqa: BLE001 - the extras and the stages do not need it
                drift_why = f"{type(e).__name__}: {e}"
            del full
        except Exception as e:  # noqa: BLE001 - the night is still scored without the extras
            why = f"{type(e).__name__}: {e}"
        eye = night_eye(head, uv, notes) if why is None else None
        status.step("Looking for walking")
        walk_windows, walk_why = None, None
        try:  # the night is still scored without it; the report says why
            walk_windows = night_walking(uv, notes, head.sample_rate)
        except Exception as e:  # noqa: BLE001
            walk_why = f"{type(e).__name__}: {e}"
        part = folder / f"{name}.part.bdf"
        to_bdf.write(part, start, uv, notes, head.names, head.sample_rate, to_bdf.equipment(head))
        del uv
        scored = score_sleep.score(part, a.anysleep, a.device, progress=status.step)
        scored["source"] = f"{name}.bdf"
        walked = None
        if walk_windows is not None:
            try:
                walked = walking_veto(scored, walk_windows)
            except Exception as e:  # noqa: BLE001
                walk_why = f"{type(e).__name__}: {e}"
        _keep_foreign(folder, name)
        os.replace(part, folder / f"{name}.bdf")
        status.step("Drawing the chart")
        score_sleep.save(scored, folder / name, title=f"Night of {name}")
        status.step("Finding sleep periods")
        rep = make_report(name, night, scored, time.time() - t_start, (start, length_s), seen, why, drift, drift_why,
                          eye, walked, walk_why)
    tmp = folder / f"{name}.report.tmp"
    tmp.write_text(json.dumps(rep, indent=1)); os.replace(tmp, folder / f"{name}.report.json")
    if rep["scored"]:
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "export_events.py"),
                            str(folder / f"{name}.sleep.json"), "--root", str(a.export)],
                           capture_output=True, text=True, timeout=120)
        print((r.stdout + r.stderr).strip(), flush=True)
    t = rep["total"]
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    print(f"night of {name}: {t['asleep_min'] / 60:.1f} h asleep in {t['periods']} period(s), "
          f"{t['missing_min']} min missing, {rep['scoring_s']:.0f} s, peak memory {peak:.0f} MB", flush=True)
    return rep


def _watchdog(status: nf.Job, max_s: float, max_mb: float, done: threading.Event) -> None:
    """Stops the run past max_s seconds or max_mb MB resident, so it never starves the recorder."""
    t0 = time.time()
    while not done.wait(2):
        try:
            rss_mb = int(Path("/proc/self/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 2**20
        except (OSError, ValueError):
            rss_mb = 0.0
        why = (f"took over {max_s / 60:.0f} min" if time.time() - t0 > max_s
               else f"needed over {max_mb:.0f} MB of memory" if rss_mb > max_mb else None)
        if why:
            try:
                status.write(state="failed", error=f"{why}; stopped")
            finally:
                print(f"{why}; stopped", flush=True)
                os._exit(4)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--recordings", type=Path, default=Path("_local/recordings"))
    ap.add_argument("--nights", type=Path, default=Path("_local/nights"))
    ap.add_argument("--export", type=Path, default=Path("_local/export"))
    ap.add_argument("--hours", type=float, default=nf.WINDOW_H, help="nights with data in the last N hours")
    ap.add_argument("--anysleep", type=Path, default=Path("_local/vendor/AnySleep"))
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--force", action="store_true", help="rebuild even if up to date")
    ap.add_argument("--max-minutes", type=float, default=45)
    ap.add_argument("--max-mb", type=float, default=3400)
    a = ap.parse_args(argv)
    status, done = nf.Job(a.nights, "sleep-report"), threading.Event()
    if not status.acquire():
        print("another sleep report is running; nothing to do", flush=True)
        return 0
    try:
        try:
            os.nice(10)  # the recorder comes first
        except OSError:
            pass
        threading.Thread(target=_watchdog, args=(status, a.max_minutes * 60, a.max_mb, done), daemon=True).start()
        for p in a.nights.glob("*.part.bdf"):  # left by a run that was stopped
            p.unlink()
        todo = [n for n in nf.recent_nights(a.recordings, time.time(), a.hours)
                if a.force or nf.is_stale(n, nf.read_report(a.nights, n.name))]
        if not todo:
            print("sleep reports are up to date", flush=True)
        refused: list[str] = []
        for n in todo:
            status.write(nights=[x.name for x in todo])
            try:
                build(n, a, status)
            except recording.RecordingError as e:  # not a night this can score: say so, go on with the others
                refused.append(f"night of {n.name}: {e}")
                print(f"{refused[-1]}; not scored", flush=True)
        if todo:
            print(nf.drift_check_line(*nf.drift_check([r for p in nf.reports(a.nights) if (r := nf.read_json(p))])),
                  flush=True)
        if refused:
            status.write(state="failed", step="Done", error="; ".join(refused)[:600])
            return 1
        status.write(state="done", step="Done", error=None)
        return 0
    except BaseException as e:
        traceback.print_exc()
        status.write(state="failed", error=f"{type(e).__name__}: {e}"[:300])
        return 1
    finally:
        done.set()
        status.release()


if __name__ == "__main__":
    sys.exit(main())
