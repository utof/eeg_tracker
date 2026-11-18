"""Live sleep stages: the reference for the phone's live scorer (app/lib/sleep/live_prep.dart and live_stager.dart)
and a replay of a recorded night through it (DECISIONS rows 79 and 170-173).

The phone hears the headband sample by sample and cannot look ahead, so it prepares the signal causally:
  - a 2nd-order Butterworth 0.3 Hz high-pass run forward only (SciPy `sosfilt`), started at the first sample's
    value so the electrodes' DC offset (tens of mV) gives no start-up swing;
  - 250 -> 128 Hz with SciPy's `resample_poly` over the whole stream. Its filter looks 20 samples (0.08 s) ahead,
    so the phone's streaming resampler gives model sample m once input sample (m * 125 + 1250) // 64 exists; the
    values are then the same as resampling the whole stream at once (checked in analysis/tests/test_live_stager.py);
  - AnySleep's robust scaling (median / IQR, clip at 20 IQR around 0) over the window only;
  - the window = the last 120 epochs (60 min), fewer at the start; a call each time an epoch is complete, from the
    10th epoch on (AnySleep's 5-minute minimum).
A window with over half of its epochs held is not scored: its scaling would be set by the held stretches (after the
high-pass they sit at about 0, so the quartiles become rounding noise); its epochs count as lost.
Each call runs AnySleep's three runs (ONNX, the app's models) and keeps the stage of the epoch 4 epochs (2 min)
behind the newest one. Holes in the stream are held at the last value, as the BDF and the phone do; an epoch with
over 5 s held is not scored ("gap").

The nap coach wakes you when 2 epochs in a row, each scored 2 min behind, are deep sleep (N3).

usage (from the repo root; needs the "onnx" group):
  uv run --project analysis --group onnx python analysis/live_stager.py replay <recordings dir> <night> <out.npz>
      [--window 120] [--every 1] [--threads 4] [--lights-off-min M ...]
  uv run --project analysis --group onnx python analysis/live_stager.py report <out.npz> <night>.sleep.json
      [--json out.json]
  uv run --project analysis --group onnx python analysis/live_stager.py dart <dart windows.bin> <recordings dir> <night>
"""
from __future__ import annotations

import argparse, json, sys, time
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.signal import butter, resample_poly, sosfilt, sosfilt_zi

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

FS = 250
MODEL_HZ = 128
UP, DOWN = Fraction(MODEL_HZ, FS).numerator, Fraction(MODEL_HZ, FS).denominator  # 64, 125
HALF_LEN = 10 * max(UP, DOWN)  # resample_poly's filter half length in upsampled samples
EPOCH_IN = 30 * FS  # 7500 input samples per epoch
EPS = 30 * MODEL_HZ  # 3840 model samples per epoch
HIGH_PASS_HZ = 0.3
LIM = 400_000  # µV: the BDF's (and the phone's) clip
MAX_MISSING = 5 * FS  # an epoch with more held samples than this is not scored
WINDOW_EP = 120  # 60 minutes
BEHIND_EP = 4  # the stage read 2 minutes behind the newest epoch
MIN_EP = 10  # AnySleep's shortest input (5 minutes)
N3_RUN = 2  # deep sleep counts after 2 epochs in a row
MAX_GAP_SHARE = 0.5  # a window with more of its epochs held than this is not scored
STAGES = ["W", "N1", "N2", "N3", "R"]
LAGS = 17  # lags kept by the replay: 0..16 epochs behind the newest


def highpass_sos() -> np.ndarray:
    return butter(2, HIGH_PASS_HZ, "highpass", fs=FS, output="sos")


def causal_highpass(uv: np.ndarray) -> np.ndarray:
    """(n, 4) µV -> (n, 4), forward only, the filter's state set for a steady first value (no start-up swing)."""
    sos = highpass_sos()
    zi = sosfilt_zi(sos)[:, :, None] * uv[0][None, None, :]
    return sosfilt(sos, uv, axis=0, zi=zi)[0]


def resample(x: np.ndarray) -> np.ndarray:
    """(n, 4) at 250 Hz -> (m, 4) at 128 Hz, resample_poly over the stream."""
    return resample_poly(x, UP, DOWN, axis=0)


def ready_model_samples(n_in: int) -> int:
    """Model samples the streaming resampler has given after n_in input samples: m with (m*DOWN+HALF_LEN)//UP < n_in."""
    if n_in <= 0:
        return 0
    # largest m with (m * DOWN + HALF_LEN) // UP <= n_in - 1  <=>  m * DOWN + HALF_LEN < n_in * UP
    return max(0, -(-(n_in * UP - HALF_LEN) // DOWN))


def ready_epochs(n_in: int) -> int:
    return ready_model_samples(n_in) // EPS


def scale(window: np.ndarray) -> np.ndarray:
    """(samples, 4) resampled µV -> AnySleep's robust scaling over the window (float64)."""
    out = np.empty_like(window)
    for c in range(window.shape[1]):
        q25, q50, q75 = np.percentile(window[:, c], [25, 50, 75])
        iqr = (q75 - q25) or 1.0
        out[:, c] = (np.clip(window[:, c], -20 * iqr, 20 * iqr) - q50) / iqr
    return out


def gap_epochs(missing: np.ndarray, n_ep: int) -> np.ndarray:
    """Per epoch: over 5 s held. `missing` is per input sample."""
    m = missing[: n_ep * EPOCH_IN].reshape(n_ep, EPOCH_IN).sum(1)
    return m > MAX_MISSING


def window_ok(gap: np.ndarray, w0: int, e: int) -> bool:
    """The window [w0, e) has at most half of its epochs held."""
    return int(gap[w0:e].sum()) <= (e - w0) * MAX_GAP_SHARE


def mask_gappy(lag: np.ndarray, gap: np.ndarray, window: int = WINDOW_EP, first: int = 0) -> np.ndarray:
    """A copy of a replay's lag array without the scores of windows over half held (for replays made before the
    rule; replay() skips them itself)."""
    out = lag.copy()
    n_ep = lag.shape[2]
    for k in range(lag.shape[1]):
        for ep in range(n_ep):
            e = ep + 1 + k
            if e <= n_ep and not window_ok(gap, max(first, e - window), e):
                out[:, k, ep] = np.nan
    return out


def softmax(z: np.ndarray) -> np.ndarray:
    e = np.exp(z - z.max(-1, keepdims=True))
    return e / e.sum(-1, keepdims=True)


def sessions(threads: int = 4, runs=(1, 2, 3)):
    """The app's three ONNX runs, without the memory arena (as the app opens them)."""
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = threads
    so.enable_cpu_mem_arena = False
    return [ort.InferenceSession(str(ROOT / "app/assets/models" / f"anysleep-run{r}.onnx"), so,
                                 providers=["CPUExecutionProvider"]) for r in runs]


def run_probs(sess, x: np.ndarray) -> np.ndarray:
    """Per run softmax, (runs, epochs, 5), for a scaled window x (samples, 4)."""
    inp = np.ascontiguousarray(x, dtype=np.float32)[None]
    return np.stack([softmax(s.run(None, {"eeg": inp})[0][0].astype(np.float64)) for s in sess])


def load_night(rec_dir: Path, night: str) -> tuple[float, np.ndarray, np.ndarray]:
    """The night's recordings joined as the phone joins them: (start unix, µV (n, 4) clipped, missing (n,) bool)."""
    import night_files, to_bdf
    found = [n for n in night_files.nights(night_files.recordings(rec_dir)) if n.name == night]
    if not found:
        raise SystemExit(f"no night {night} in {rec_dir}")
    start, uv, notes = to_bdf.join([r.path for r in found[0].recs])
    missing = np.zeros(len(uv), bool)
    for onset, dur, text in notes:
        if text.startswith("BAD"):
            lo = round(onset * FS)
            missing[lo:lo + round(dur * FS)] = True
    return start.timestamp(), np.clip(uv, -LIM, LIM), missing


def prepare_stream(uv: np.ndarray) -> np.ndarray:
    """The causal high-pass and the stream resampler: (m, 4) model-rate µV, every sample the phone would have."""
    return resample(causal_highpass(uv))


def replay(res: np.ndarray, gap: np.ndarray, n_in: int, sess, *, window: int = WINDOW_EP, first: int = 0,
           last: int | None = None, every: int = 1, progress=print) -> dict:
    """Calls as the phone makes them, for edges (newest complete epoch + 1) from first + MIN_EP to `last`, the
    stream starting at epoch `first` (lights off). Returns per-run probabilities at lags 0..16 and call times."""
    n_ep = min(ready_epochs(n_in), res.shape[0] // EPS, len(gap))
    last = n_ep if last is None else min(last, n_ep)
    runs = len(sess)
    lag = np.full((runs, LAGS, n_ep, 5), np.nan, np.float32)
    secs = []
    edges = list(range(first + MIN_EP, last + 1, every))
    t_all = time.time()
    for j, e in enumerate(edges):
        w0 = max(first, e - window)
        if not window_ok(gap, w0, e):
            continue
        t = time.perf_counter()
        p = run_probs(sess, scale(res[w0 * EPS:e * EPS]))
        secs.append(time.perf_counter() - t)
        for k in range(LAGS):
            ep = e - 1 - k
            if ep >= w0:
                lag[:, k, ep] = p[:, ep - w0]
        if progress and j % 100 == 0:
            progress(f"edge {e}/{last}  {time.time() - t_all:.0f} s")
    return dict(lag=lag, edges=np.array(edges), call_s=np.array(secs), first=first)


def stages_at(lag: np.ndarray, k: int, gap: np.ndarray, runs=None) -> list[str | None]:
    """Stage per epoch as scored k epochs behind (mean of `runs`, default all); None where never scored."""
    p = lag[:, k] if runs is None else lag[list(runs), k]
    m = p.mean(0)
    out: list[str | None] = []
    for i in range(m.shape[0]):
        if np.isnan(m[i]).any():
            out.append(None)
        else:
            out.append("gap" if gap[i] else STAGES[int(m[i].argmax())])
    return out


def kappa(a: list[str], b: list[str], labels: list[str]) -> float:
    idx = {s: i for i, s in enumerate(labels)}
    cm = np.zeros((len(labels), len(labels)))
    for x, y in zip(a, b):
        cm[idx[x], idx[y]] += 1
    n = cm.sum()
    po = np.trace(cm) / n
    pe = (cm.sum(0) * cm.sum(1)).sum() / n / n
    return float((po - pe) / (1 - pe)) if pe < 1 else 1.0


def deep_trigger(stages: list[str | None], start: int = 0, run: int = N3_RUN) -> int | None:
    """The epoch at which the nap coach knows "deep sleep is starting": the second of `run` consecutive scored
    epochs that are N3, from epoch `start` on; None if never. (The app knows it BEHIND_EP epochs later.)"""
    n = 0
    for i in range(start, len(stages)):
        n = n + 1 if stages[i] == "N3" else 0
        if n >= run:
            return i
    return None


def n3_bouts(offline: list[str], quiet_ep: int = 10) -> list[int]:
    """First epoch of each offline deep-sleep stretch that follows `quiet_ep` epochs (5 min) without N3."""
    out, since = [], quiet_ep
    for i, s in enumerate(offline):
        if s == "N3":
            if since >= quiet_ep:
                out.append(i)
            since = 0
        else:
            since += 1
    return out


def compare(lag: np.ndarray, gap: np.ndarray, offline: list[str], k: int, runs=None, skip_tail: int = 16) -> dict:
    """Live (k behind) vs offline per epoch: share the same, 5-stage kappa, wake/sleep and N3/rest kappa."""
    live = stages_at(lag, k, gap, runs)
    n = len(offline) - skip_tail
    pairs = [(a, b) for a, b in zip(live[:n], offline[:n]) if a is not None and a != "gap" and b != "gap"]
    a = [p[0] for p in pairs]; b = [p[1] for p in pairs]
    ws = lambda v: ["W" if s == "W" else "S" for s in v]  # noqa: E731
    deep = lambda v: ["N3" if s == "N3" else "-" for s in v]  # noqa: E731
    cm = {f"{x}>{y}": sum(1 for p, q in pairs if p == x and q == y) for x in STAGES for y in STAGES if x != y}
    return dict(epochs=len(pairs), same=float(np.mean([x == y for x, y in pairs])) if pairs else float("nan"),
                kappa=kappa(a, b, STAGES), kappa_wake_sleep=kappa(ws(a), ws(b), ["W", "S"]),
                kappa_deep=kappa(deep(a), deep(b), ["N3", "-"]),
                confusions={k_: v for k_, v in sorted(cm.items(), key=lambda kv: -kv[1]) if v >= 3})


def cmd_replay(a) -> None:
    t0 = time.time()
    start, uv, missing = load_night(a.recordings, a.night)
    res = prepare_stream(uv)
    n_in = len(uv)
    n_ep = ready_epochs(n_in)
    gap = gap_epochs(missing, n_ep)
    print(f"{a.night}: {n_in / FS / 3600:.2f} h, {n_ep} epochs, {gap.sum()} gap epochs; prepared in "
          f"{time.time() - t0:.0f} s", flush=True)
    sess = sessions(a.threads)
    out = dict(start=start, gap=gap, night=a.night)
    r = replay(res, gap, n_in, sess, window=a.window, every=a.every, progress=lambda s: print(s, flush=True))
    out.update(lag=r["lag"], edges=r["edges"], call_s=r["call_s"])
    # naps: lights off at each given minute, the stream (filter, resampler, window) restarted there
    naps = []
    for m in a.lights_off_min:
        e0 = int(m * 2)
        s0 = e0 * EPOCH_IN
        res_nap = prepare_stream(uv[s0:])
        r = replay(res_nap, gap[e0:], n_in - s0, sess, window=a.window, last=a.nap_max_ep, progress=None)
        naps.append(dict(lights_off_ep=e0, lag=r["lag"], call_s=r["call_s"]))
        print(f"nap from minute {m}: {len(r['call_s'])} calls", flush=True)
    for i, n in enumerate(naps):
        out[f"nap{i}_ep"] = n["lights_off_ep"]
        out[f"nap{i}_lag"] = n["lag"]
        out[f"nap{i}_call_s"] = n["call_s"]
    np.savez_compressed(a.out, **out)
    print(f"done in {time.time() - t0:.0f} s -> {a.out}", flush=True)


def cmd_report(a) -> None:
    z = np.load(a.npz)
    offline_all = [e["anysleep"] for e in json.loads(Path(a.sleep_json).read_text())["epochs"]]
    gap = z["gap"]
    lag = mask_gappy(z["lag"], gap)
    n = min(len(offline_all), lag.shape[2])
    offline = offline_all[:n]
    lag = lag[:, :, :n]
    gap = gap[:n]
    rep: dict = dict(night=str(z["night"]), epochs=n, calls=len(z["call_s"]),
                     call_s=dict(median=float(np.median(z["call_s"])), p95=float(np.percentile(z["call_s"], 95)),
                                 max=float(z["call_s"].max())))
    rep["agreement"] = {f"{k / 2:g} min": compare(lag, gap, offline, k) for k in (0, 2, 4, 14)}
    rep["agreement_1run"] = {f"{k / 2:g} min": compare(lag, gap, offline, k, runs=[0]) for k in (0, 4)}
    live = stages_at(lag, BEHIND_EP, gap)
    bouts = n3_bouts(offline)
    rows = []
    for b in bouts:
        trig = deep_trigger(live, max(0, b - 10))
        rows.append(dict(offline_first_n3_ep=b, offline_settled_ep=deep_trigger(offline, b),
                         live_trigger_ep=trig, app_knows_ep=None if trig is None else trig + BEHIND_EP,
                         delay_min=None if trig is None else (trig + BEHIND_EP + 1 - b) / 2))
    rep["deep_sleep_starts"] = rows
    # live triggers with no offline N3 within 5 min either side: a wake-up that came too early
    false, i = [], 0
    while True:
        t = deep_trigger(live, i)
        if t is None:
            break
        if not any(s == "N3" for s in offline[max(0, t - 10):t + 11]):
            false.append(t)
        i = t + 1
        while i < len(live) and live[i] == "N3":
            i += 1
    rep["live_deep_without_offline_deep"] = false
    naps = []
    for j in range(8):
        if f"nap{j}_ep" not in z:
            break
        e0 = int(z[f"nap{j}_ep"]); nl = mask_gappy(z[f"nap{j}_lag"], gap[e0:e0 + z[f"nap{j}_lag"].shape[2]])
        st = stages_at(nl, BEHIND_EP, gap[e0:e0 + nl.shape[2]])
        trig = deep_trigger(st)
        off = offline[e0:e0 + nl.shape[2]]
        first_n3 = next((i for i, s in enumerate(off) if s == "N3"), None)
        naps.append(dict(lights_off_min=e0 / 2, minutes=nl.shape[2] / 2,
                         offline_first_n3_min=None if first_n3 is None else first_n3 / 2,
                         live_wake_min=None if trig is None else (trig + BEHIND_EP + 1) / 2,
                         call_s_median=float(np.median(z[f"nap{j}_call_s"])),
                         agreement_2min=compare(nl, gap[e0:e0 + nl.shape[2]], off, BEHIND_EP, skip_tail=BEHIND_EP)))
    rep["naps"] = naps
    text = json.dumps(rep, indent=1)
    if a.json:
        Path(a.json).write_text(text)
    print(text)


def cmd_dart(a) -> None:
    """Compares the windows tool/live_night.dart wrote (the Dart live preparation on a whole night) with this
    reference, and scores them: the same stage at every saved edge?"""
    meta = json.loads(Path(f"{a.windows}.json").read_text())
    start, uv, missing = load_night(a.recordings, a.night)
    res = prepare_stream(uv)
    n_ep = ready_epochs(len(uv))
    gap = gap_epochs(missing, n_ep)
    sess = sessions(4) if a.score else None
    worst, same, n, skipped = 0.0, 0, 0, 0
    with open(a.windows, "rb") as f:
        for w in meta["windows"]:
            e, w0 = w["edge"], w["first"]
            got = np.fromfile(f, dtype="<f4", count=(e - w0) * EPS * 4).reshape(-1, 4)
            if not window_ok(gap, w0, e):  # not scored (ill-conditioned scaling): the app skips it too
                skipped += 1
                continue
            want = scale(res[w0 * EPS:e * EPS]).astype(np.float32)
            d = float(np.abs(got - want).max())
            worst = max(worst, d)
            assert list(map(bool, gap[w0:e])) == w["gap"], f"gap flags differ at edge {e}"
            if sess is not None:
                pg = run_probs(sess, got).mean(0)[e - 1 - BEHIND_EP - w0]
                pw = run_probs(sess, want).mean(0)[e - 1 - BEHIND_EP - w0]
                same += int(pg.argmax() == pw.argmax()); n += 1
    print(json.dumps(dict(windows=len(meta["windows"]), skipped_over_half_held=skipped, max_abs_diff=worst, same_stage=same, scored=n,
                          dart_prep_s=meta.get("prepare_s"), dart_window_ms=meta.get("window_ms")), indent=1))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("replay")
    r.add_argument("recordings", type=Path); r.add_argument("night"); r.add_argument("out", type=Path)
    r.add_argument("--window", type=int, default=WINDOW_EP); r.add_argument("--every", type=int, default=1)
    r.add_argument("--threads", type=int, default=4)
    r.add_argument("--lights-off-min", type=float, nargs="*", default=[])
    r.add_argument("--nap-max-ep", type=int, default=180, help="epochs per simulated nap (180 = 90 min)")
    p = sub.add_parser("report")
    p.add_argument("npz", type=Path); p.add_argument("sleep_json", type=Path); p.add_argument("--json", type=Path)
    d = sub.add_parser("dart")
    d.add_argument("windows", type=Path); d.add_argument("recordings", type=Path); d.add_argument("night")
    d.add_argument("--score", action="store_true")
    a = ap.parse_args()
    {"replay": cmd_replay, "report": cmd_report, "dart": cmd_dart}[a.cmd](a)


if __name__ == "__main__":
    main()
