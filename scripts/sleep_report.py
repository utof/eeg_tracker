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
drift-off detector from the night's lights off against the model's sleep onset (analysis/night_drift.py), writes
<date>.report.json
(docs/data-format.md) and appends the eeg_sleep_night event (export_events.py). Nights already up to date are
skipped, so running it twice does nothing the second time. One run at a time (a lock file); it lowers its own
CPU priority and stops itself past --max-minutes or --max-mb, so the recorder keeps going.
"""
from __future__ import annotations

import argparse, json, os, resource, subprocess, sys, threading, time, traceback
from datetime import datetime, timedelta
from pathlib import Path

import night_files as nf

ROOT = Path(__file__).resolve().parent.parent
EPOCH = 30
ASLEEP = {"N1", "N2", "N3", "R"}
SPLIT_MIN = 60  # asleep stretches separated by this much wake or missing data are separate periods
MIN_PERIOD_SLEEP_MIN = 10  # shorter "periods" are scorer noise; their minutes count as stray sleep
WAKE_UP_OVER_MIN = 5
NOTE = "first guess; the scorer is not yet validated on this headband"


SCORED = {"W"} | ASLEEP


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


def make_report(name: str, night: nf.Night, scored: dict | None, seconds: float, data: tuple[datetime, float],
                seen: tuple | None = None, extras_error: str | None = None, drift: dict | None = None,
                drift_error: str | None = None) -> dict:
    """<name>.report.json from score_sleep's result (None when there was too little data to score), what the
    detectors saw (`night_extras.events`, None when that pass did not run) and the drift-off detector from lights
    off (`night_drift.night`, None when it did not run; drift_error says why)."""
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
                   extras_error=extras_error, drift_off=None, drift_off_error=None)
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
    s = scored["summary"]
    total = {k: sum(p[k] for p in out) for k in ("asleep_min", "light_min", "deep_min", "dream_min", "wake_ups")}
    total.update(periods=len(out), recorded_min=s["recorded_min"], missing_min=s["gap_min"], stray_sleep_min=stray)
    rep.update(periods=out, total=total, hypnogram=f"{name}.hypnogram.png", sleep_json=f"{name}.sleep.json",
               bdf=f"{name}.bdf", model=export_events.MODEL,
               cross_check=dict(model=export_events.CROSS, agreement_5_stage=s.get("agreement_5_stage"),
                                agreement_w_nrem_rem=s.get("agreement_w_nrem_rem")),
               extras=extras, extras_error=extras_error, drift_off=drift_off, drift_off_error=drift_error)
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


def build(night: nf.Night, a: argparse.Namespace, status: nf.Job) -> dict:
    import score_sleep, to_bdf
    name, folder = night.name, a.nights
    t_start = time.time()
    hours = sum(r.minutes for r in night.recs) / 60
    status.step(f"Night of {name}: joining {len(night.recs)} recordings ({hours:.1f} h)")
    start, uv, notes = to_bdf.join([r.path for r in night.recs])
    length_s = len(uv) / to_bdf.FS
    if length_s < 10 * EPOCH:
        rep = make_report(name, night, None, time.time() - t_start, (start, length_s))
    else:
        status.step("Counting jaw, movement and signal")
        seen, why, drift, drift_why = None, None, None, None
        try:  # before scoring, so its memory is free again when the model runs
            sys.path.insert(0, str(ROOT / "analysis"))
            import night_extras as nx
            full = nx.see(uv, notes)
            seen = nx.events(full)
            try:  # the drift-off detector from the night's lights off (night_drift.py)
                import night_drift as nd
                drift = nd.night(full, nf.lights_off(night), int(start.timestamp()))
            except Exception as e:  # noqa: BLE001 - the extras and the stages do not need it
                drift_why = f"{type(e).__name__}: {e}"
            del full
        except Exception as e:  # noqa: BLE001 - the night is still scored without the extras
            why = f"{type(e).__name__}: {e}"
        part = folder / f"{name}.part.bdf"
        to_bdf.write(part, start, uv, notes)
        del uv
        scored = score_sleep.score(part, a.anysleep, a.device, progress=status.step)
        scored["source"] = f"{name}.bdf"
        _keep_foreign(folder, name)
        os.replace(part, folder / f"{name}.bdf")
        status.step("Drawing the chart")
        score_sleep.save(scored, folder / name, title=f"Night of {name}")
        status.step("Finding sleep periods")
        rep = make_report(name, night, scored, time.time() - t_start, (start, length_s), seen, why, drift, drift_why)
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
        for n in todo:
            status.write(nights=[x.name for x in todo])
            build(n, a, status)
        if todo:
            print(nf.drift_check_line(*nf.drift_check([r for p in nf.reports(a.nights) if (r := nf.read_json(p))])),
                  flush=True)
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
