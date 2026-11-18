"""Analyse the latest morning check-in (scripts/web/morning.html) in a recording and compare it with earlier ones.

usage: morning_check.py <folder or <stamp>.f32 ...> [--out-dir DIR]
Run in the analysis environment:  uv run --project analysis python scripts/morning_check.py _local/recordings

Reads <stamp>.f32 + .markers.jsonl (docs/data-format.md), finds the newest morning session (markers
morning:eyes_closed:start/end, morning:eyes_open:start/end, morning:ratings {...}) and computes, for each
back channel (O1, O2):
- alpha power (8-13 Hz, µV²) eyes closed and eyes open, from the mean spectrum of clean 2 s segments;
- the eyes-closed rise: alpha eyes closed / alpha eyes open;
- the individual alpha frequency ("alpha speed"): centre of gravity of the power above the 1/f line in 7-14 Hz
  (headline), and the peak frequency of that excess (also reported);
- the aperiodic (1/f) slope eyes closed: straight-line fit of log power on log frequency, 2-40 Hz without 7-14 Hz;
- the share of clean data.
A 2 s segment is rejected when, after a 1-40 Hz band-pass, its peak-to-peak exceeds 150 µV, it is flat
(spread under 0.5 µV), or its spread is over 3x the phase median. The first 3 s and last 1 s of each phase are
skipped (eyes settling after the tone).
Writes <session start>.morning.json next to the recording (or in --out-dir) and prints a short summary that
compares today with the last 14 earlier *.morning.json files in that folder (median and range).

If the recording also holds a setup test (setup:* markers from the same page), it reports whether blinks,
left-right glances (T3 minus T4) and jaw clenches stand out from the background (signal-to-noise per event type).
"""
import argparse, json, sys
from datetime import datetime
from pathlib import Path

import numpy as np
from scipy import signal

sys.path.insert(0, str(Path(__file__).parent))
from to_bdf import load  # noqa: E402

FS = 250
NAMES = ["O1", "O2", "T3", "T4"]
BACK = ["O1", "O2"]
VERSION = "morning-v1"
SEG_S = 2.0
P2P_UV = 150.0
FLAT_UV = 0.5
REL_SPREAD = 3.0
SKIP_START_S, SKIP_END_S = 3.0, 1.0
ALPHA = (8.0, 13.0)
IAF_RANGE = (7.0, 14.0)
FIT = (2.0, 40.0)
MIN_CLEAN_SEGS = 10  # 20 s of clean data per phase, or the channel's values are left empty
PEAK_MIN = 0.1  # log10 units above the 1/f line (about +26 %) for an alpha peak to count as present
HISTORY_N = 14
HISTORY_MIN = 5


# ---------------------------------------------------------------- markers and sessions
def read_markers(path: Path) -> list[dict]:
    mf = path.with_suffix(".markers.jsonl")
    out = []
    for line in (mf.read_text(encoding="utf-8").splitlines() if mf.exists() else []):
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(m, dict) and "text" in m and "i" in m:
            out.append(m)
    return out


def sessions(markers: list[dict], prefix: str) -> list[list[dict]]:
    """Split markers into sessions: each starts at '<prefix>:start' (or the first marker of the prefix)."""
    out: list[list[dict]] = []
    for m in markers:
        text = str(m["text"])
        if not text.startswith(prefix + ":"):
            continue
        if text == f"{prefix}:start" or not out:
            out.append([])
        out[-1].append(m)
    return out


def morning_windows(sess: list[dict]) -> dict | None:
    """{'eyes_closed': (i0, i1), 'eyes_open': (i0, i1), 'ratings': {...} | None, 't': start time} or None if unusable."""
    if any(m["text"] == "morning:abort" for m in sess):
        return None
    edge = {m["text"]: m for m in sess}
    win = {}
    for ph in ("eyes_closed", "eyes_open"):
        a, b = edge.get(f"morning:{ph}:start"), edge.get(f"morning:{ph}:end")
        if a and b and b["i"] > a["i"]:
            win[ph] = (int(a["i"]), int(b["i"]), float(a["t"]), float(b["t"]))
    if "eyes_closed" not in win:
        return None
    ratings = None
    for m in sess:
        if m["text"].startswith("morning:ratings"):
            try:
                ratings = json.loads(m["text"].split(" ", 1)[1])
            except (IndexError, json.JSONDecodeError):
                pass
    return dict(win=win, ratings=ratings, t=win["eyes_closed"][2])


# ---------------------------------------------------------------- signal measures
def bandpass(x: np.ndarray, lo: float | None, hi: float | None, fs: float = FS) -> np.ndarray:
    if lo and hi:
        sos = signal.butter(4, [lo, hi], btype="bandpass", fs=fs, output="sos")
    elif lo:
        sos = signal.butter(4, lo, btype="highpass", fs=fs, output="sos")
    else:
        sos = signal.butter(4, hi, btype="lowpass", fs=fs, output="sos")
    return signal.sosfiltfilt(sos, x, axis=0)


def clean_segments(x: np.ndarray, fs: float = FS) -> tuple[np.ndarray, np.ndarray]:
    """Cut one channel of one phase into 2 s segments; returns (segments k x n, keep mask)."""
    n = int(SEG_S * fs)
    k = len(x) // n
    if k == 0:
        return np.empty((0, n)), np.zeros(0, bool)
    raw = x[: k * n].reshape(k, n)
    f = bandpass(x, 1.0, 40.0, fs)[: k * n].reshape(k, n) if len(x) > 3 * n else raw - raw.mean(1, keepdims=True)
    p2p = f.max(1) - f.min(1)
    sd = f.std(1)
    keep = (p2p <= P2P_UV) & (sd >= FLAT_UV)
    if keep.any():
        keep &= sd <= REL_SPREAD * np.median(sd[keep])
    return raw, keep


def spectrum(segs: np.ndarray, fs: float = FS) -> tuple[np.ndarray, np.ndarray]:
    """Mean power spectral density (µV²/Hz) of the segments: Hann window, linear detrend, zero-padded to 0.25 Hz."""
    nfft = int(fs / 0.25)
    f, p = signal.periodogram(segs, fs=fs, window="hann", nfft=nfft, detrend="linear", axis=-1)
    return f, p.mean(0)


def band_power(f: np.ndarray, p: np.ndarray, lo: float, hi: float) -> float:
    m = (f >= lo) & (f <= hi)
    return float(np.trapezoid(p[m], f[m]))


def aperiodic(f: np.ndarray, p: np.ndarray) -> tuple[float, float]:
    """(slope, intercept) of log10 power on log10 frequency, 2-40 Hz without the alpha search range."""
    m = (f >= FIT[0]) & (f <= FIT[1]) & ~((f >= IAF_RANGE[0]) & (f <= IAF_RANGE[1])) & (p > 0)
    slope, icpt = np.polyfit(np.log10(f[m]), np.log10(p[m]), 1)
    return float(slope), float(icpt)


def alpha_frequency(f: np.ndarray, p: np.ndarray, slope: float, icpt: float) -> dict:
    """Centre of gravity and peak of the power above the 1/f line in 7-14 Hz."""
    m = (f >= IAF_RANGE[0]) & (f <= IAF_RANGE[1])
    fm, pm = f[m], p[m]
    line = 10 ** (icpt + slope * np.log10(fm))
    resid = np.log10(np.maximum(pm, 1e-12)) - np.log10(line)
    k = int(np.argmax(resid))
    peak = float(fm[k])
    if 0 < k < len(fm) - 1:  # parabolic interpolation on the log residual
        a, b, c = resid[k - 1 : k + 2]
        d = a - 2 * b + c
        if d < 0:
            peak += float(0.5 * (a - c) / d * (fm[1] - fm[0]))
    excess = np.clip(pm - line, 0, None)
    present = bool(resid[k] >= PEAK_MIN)
    cog = float(np.sum(fm * excess) / np.sum(excess)) if present and excess.sum() > 0 else None
    return dict(iaf_hz=None if cog is None else round(cog, 2), iaf_peak_hz=round(peak, 2) if present else None,
                alpha_peak_present=present, alpha_peak_above_1f=round(float(resid[k]), 3))


def channel_measures(ec: np.ndarray, eo: np.ndarray | None, fs: float = FS) -> dict:
    """All measures for one channel from its eyes-closed and eyes-open samples (µV)."""
    out: dict = {}
    segs, keep = clean_segments(ec, fs)
    out["clean_share_ec"] = round(float(keep.mean()), 3) if len(keep) else 0.0
    out["clean_s_ec"] = float(keep.sum() * SEG_S)
    ok_ec = keep.sum() >= MIN_CLEAN_SEGS
    if ok_ec:
        f, p = spectrum(segs[keep], fs)
        out["alpha_ec_uv2"] = round(band_power(f, p, *ALPHA), 2)
        slope, icpt = aperiodic(f, p)
        out["aperiodic_slope_ec"] = round(slope, 3)
        out.update(alpha_frequency(f, p, slope, icpt))
    else:
        out.update(alpha_ec_uv2=None, aperiodic_slope_ec=None, iaf_hz=None, iaf_peak_hz=None,
                   alpha_peak_present=None, alpha_peak_above_1f=None)
    out["alpha_eo_uv2"] = None; out["ec_rise"] = None
    out["clean_share_eo"] = None; out["clean_s_eo"] = None
    if eo is not None:
        segs, keep = clean_segments(eo, fs)
        out["clean_share_eo"] = round(float(keep.mean()), 3) if len(keep) else 0.0
        out["clean_s_eo"] = float(keep.sum() * SEG_S)
        if keep.sum() >= MIN_CLEAN_SEGS:
            f, p = spectrum(segs[keep], fs)
            out["alpha_eo_uv2"] = round(band_power(f, p, *ALPHA), 2)
            if ok_ec and out["alpha_eo_uv2"] > 0:
                out["ec_rise"] = round(out["alpha_ec_uv2"] / out["alpha_eo_uv2"], 2)
    return out


def back_summary(ch: dict) -> dict:
    """O1 and O2 combined: geometric mean for powers and the rise, plain mean for frequency and slope."""
    def comb(key: str, geo: bool):
        v = [ch[n][key] for n in BACK if ch.get(n, {}).get(key) is not None]
        if not v:
            return None
        return round(float(np.exp(np.mean(np.log(v)))) if geo else float(np.mean(v)), 3 if not geo else 2)
    shares = [ch[n][k] for n in BACK for k in ("clean_share_ec", "clean_share_eo") if ch.get(n, {}).get(k) is not None]
    return dict(alpha_ec_uv2=comb("alpha_ec_uv2", True), alpha_eo_uv2=comb("alpha_eo_uv2", True),
                ec_rise=comb("ec_rise", True), iaf_hz=comb("iaf_hz", False),
                aperiodic_slope_ec=comb("aperiodic_slope_ec", False),
                clean_share=round(float(np.mean(shares)), 3) if shares else None)


# ---------------------------------------------------------------- setup test
def _snr(event: list[float], base: list[float]) -> float | None:
    if not event or not base or np.median(base) <= 0:
        return None
    return round(float(np.median(event) / np.median(base)), 2)


def setup_test(uv: np.ndarray, sess: list[dict], fs: float = FS) -> dict:
    """Signal-to-noise per event type. Blinks: median peak-to-peak (0.5-10 Hz) 0.1-1.2 s after the cue over the
    1.1 s before it, best channel. Glances: T3 minus T4 (below 5 Hz), mean 0.3-1.3 s after the cue minus the
    0.5 s before; separation of left and right = |mean left - mean right| / pooled spread. Clenches: spread at
    T3 and T4 in 20-45 Hz while clenching over the 3 s after relaxing. 'visible' means 2 or more."""
    s = lambda t: int(round(t * fs))  # noqa: E731
    n = len(uv)
    out: dict = {}
    blinks = [int(m["i"]) for m in sess if m["text"] == "setup:blink"]
    if blinks:
        lo = bandpass(uv, 0.5, 10.0, fs)
        per = {}
        for c, name in enumerate(NAMES):
            ev = [np.ptp(lo[i + s(0.1) : i + s(1.2), c]) for i in blinks if i - s(1.2) >= 0 and i + s(1.2) <= n]
            bs = [np.ptp(lo[i - s(1.2) : i - s(0.1), c]) for i in blinks if i - s(1.2) >= 0 and i + s(1.2) <= n]
            per[name] = _snr(ev, bs)
        best = max((v for v in per.values() if v is not None), default=None)
        out["blink"] = dict(n=len(blinks), snr=per, best=best, visible=best is not None and best >= 2)
    glances = [(int(m["i"]), m["text"].rsplit(":", 1)[1]) for m in sess if m["text"].startswith("setup:glance:")]
    if glances:
        h = bandpass(uv[:, 2] - uv[:, 3], None, 5.0, fs)
        d = {"left": [], "right": []}
        for i, side in glances:
            if i - s(0.5) >= 0 and i + s(1.3) <= n and side in d:
                d[side].append(float(h[i + s(0.3) : i + s(1.3)].mean() - h[i - s(0.5) : i].mean()))
        sep = None
        if len(d["left"]) >= 2 and len(d["right"]) >= 2:
            pooled = np.sqrt((np.var(d["left"], ddof=1) + np.var(d["right"], ddof=1)) / 2)
            sep = round(float(abs(np.mean(d["left"]) - np.mean(d["right"])) / max(pooled, 1e-9)), 2)
        out["glance"] = dict(n=len(glances), left_uv=round(float(np.mean(d["left"])), 1) if d["left"] else None,
                             right_uv=round(float(np.mean(d["right"])), 1) if d["right"] else None,
                             separation=sep, visible=sep is not None and sep >= 2)
    starts = [int(m["i"]) for m in sess if m["text"] == "setup:clench:start"]
    ends = [int(m["i"]) for m in sess if m["text"] == "setup:clench:end"]
    pairs = [(a, min(e for e in ends if e > a)) for a in starts if any(e > a for e in ends)]
    if pairs:
        hi = bandpass(uv, 20.0, 45.0, fs)
        per = {}
        for c, name in ((2, "T3"), (3, "T4")):
            ev = [hi[a + s(0.3) : b, c].std() for a, b in pairs if b - a > s(0.5) and b + s(3.5) <= n]
            bs = [hi[b + s(0.5) : b + s(3.5), c].std() for a, b in pairs if b - a > s(0.5) and b + s(3.5) <= n]
            per[name] = _snr(ev, bs)
        best = max((v for v in per.values() if v is not None), default=None)
        out["clench"] = dict(n=len(pairs), snr=per, best=best, visible=best is not None and best >= 2)
    return out


# ---------------------------------------------------------------- history and summary
def history(folder: Path, start: str) -> list[dict]:
    """Earlier check-ins in the folder (by start time), oldest first, at most the last 14."""
    old = []
    for f in folder.glob("*.morning.json"):
        try:
            r = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        try:
            when = datetime.fromisoformat(r["start"])
            if when < datetime.fromisoformat(start):
                old.append((when, r))
        except (KeyError, TypeError, ValueError):  # TypeError: a start without a UTC offset
            continue
    old = [r for _, r in sorted(old, key=lambda x: x[0])]
    return old[-HISTORY_N:]


def get(r: dict, path: str):
    for k in path.split("."):
        r = r.get(k) if isinstance(r, dict) else None
    return r


def compare(today, past: list) -> str:
    past = [v for v in past if v is not None]
    if today is None:
        return ""
    if not past:
        return ""
    med, lo, hi = np.median(past), min(past), max(past)
    fmt = lambda v: f"{v:.3g}"  # noqa: E731
    where = "within your range" if lo <= today <= hi else ("above your range" if today > hi else "below your range")
    note = "" if len(past) >= HISTORY_MIN else f"; only {len(past)} earlier, wait for {HISTORY_MIN}+"
    return f"  (your last {len(past)}: median {fmt(med)}, range {fmt(lo)}-{fmt(hi)}: {where}{note})"


def summary(res: dict, past: list[dict]) -> str:
    b = res["back"]; ch = res["channels"]
    L = [f"Morning check-in {res['start'][:16].replace('T', ' ')}: "
         f"{res['phase_s'].get('eyes_closed', 0):.0f} s eyes closed, {res['phase_s'].get('eyes_open', 0):.0f} s eyes open"]
    if not past:
        L.append("First check-in in this folder: nothing to compare with yet.")
    L.append("Clean data: " + ", ".join(
        f"{n} {ch[n]['clean_share_ec'] * 100:.0f}% closed / "
        + (f"{ch[n]['clean_share_eo'] * 100:.0f}% open" if ch[n]['clean_share_eo'] is not None else "no open phase")
        for n in BACK))
    rows = [("Alpha strength, eyes closed (µV²)", "back.alpha_ec_uv2", "{:.1f}"),
            ("Eyes-closed rise (closed / open)", "back.ec_rise", "{:.1f}x"),
            ("Alpha speed (Hz)", "back.iaf_hz", "{:.2f}"),
            ("1/f slope, eyes closed", "back.aperiodic_slope_ec", "{:.2f}"),
            ("Sleepiness (KSS 1-9)", "ratings.kss", "{}"), ("Mood (1-5)", "ratings.mood", "{}"),
            ("Tension (1-5)", "ratings.tension", "{}")]
    for label, key, fmt in rows:
        v = get(res, key)
        L.append(f"  {label}: " + ("not enough clean data" if v is None and key.startswith("back") else
                                    "not rated" if v is None else fmt.format(v))
                 + compare(v, [get(r, key) for r in past]))
    if b.get("iaf_hz") is None and b.get("alpha_ec_uv2") is not None:
        L.append("  No clear alpha peak with eyes closed today (contact, or an alert / tense start can do this).")
    st = res.get("setup_test")
    if st:
        L.append("Setup test (signal-to-noise; 2 or more = clearly visible):")
        for k, label in (("blink", "blinks"), ("glance", "left-right glances (T3-T4)"), ("clench", "jaw clenches")):
            if k in st:
                v = st[k].get("best", st[k].get("separation"))
                L.append(f"  {label}: {'visible' if st[k]['visible'] else 'not clear'} ({v})")
    L.append("One morning means little; look at the trend over weeks. Lower alpha speed than usual often goes with "
             "sleepiness. These are your own numbers, not norms.")
    return "\n".join(L)


# ---------------------------------------------------------------- main
def find_latest(paths: list[Path], prefix: str):
    """(path, session markers) of the newest usable session with this prefix across the files."""
    best = None
    for p in paths:
        for sess in sessions(read_markers(p), prefix):
            ok = morning_windows(sess) if prefix == "morning" else sess
            if ok and (best is None or sess[0]["t"] > best[1][0]["t"]):
                best = (p, sess)
    return best


def analyse(path: Path, sess: list[dict], fs: float = FS) -> dict:
    uv, _ = load(path)
    w = morning_windows(sess)
    cut = {}
    for ph, (i0, i1, _t0, _t1) in w["win"].items():
        a, b = i0 + int(SKIP_START_S * fs), min(i1 - int(SKIP_END_S * fs), len(uv))
        cut[ph] = uv[a:b] if b > a else uv[0:0]
    channels = {}
    for name in BACK:
        c = NAMES.index(name)
        channels[name] = channel_measures(cut["eyes_closed"][:, c], cut["eyes_open"][:, c] if "eyes_open" in cut else None, fs)
    start = datetime.fromtimestamp(w["t"]).astimezone()
    return dict(
        version=VERSION, source=path.name, start=start.isoformat(timespec="seconds"), date=start.date().isoformat(),
        phase_s={ph: round((i1 - i0) / fs, 1) for ph, (i0, i1, _a, _b) in w["win"].items()},
        channels=channels, back=back_summary(channels), ratings=w["ratings"], setup_test=None,
        method=dict(segment_s=SEG_S, reject_p2p_uv=P2P_UV, reject_rel_spread=REL_SPREAD, alpha_band_hz=list(ALPHA),
                    iaf="centre of gravity of power above the 1/f line, 7-14 Hz", fit_hz=list(FIT),
                    fit_excludes_hz=list(IAF_RANGE), skip_s=[SKIP_START_S, SKIP_END_S]),
        device=dict(model="BrainBit Black", channels=NAMES), validated=False)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("inputs", nargs="+", type=Path, help="a recordings folder, or <stamp>.f32 files")
    ap.add_argument("--out-dir", type=Path, help="where to write and look for earlier *.morning.json (default: next to the recording)")
    a = ap.parse_args()
    paths = sorted({p for x in a.inputs for p in ([*x.glob("*.f32")] if x.is_dir() else [x])})
    if not paths:
        raise SystemExit("no .f32 recordings found")
    found = find_latest(paths, "morning")
    setup = find_latest(paths, "setup")
    if not found and not setup:
        raise SystemExit("no morning check-in or setup test markers found (did the page reach the recorder?)")
    if found:
        path, sess = found
        res = analyse(path, sess)
        if setup and setup[0] == path:
            uv, _ = load(path)
            res["setup_test"] = setup_test(uv, setup[1])
        kind = "morning"
    else:
        path, sess = setup
        uv, _ = load(path)
        start = datetime.fromtimestamp(sess[0]["t"]).astimezone()
        res = dict(version=VERSION, source=path.name, start=start.isoformat(timespec="seconds"),
                   setup_test=setup_test(uv, sess))
        kind = "setup"
    out = a.out_dir or path.parent
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.fromisoformat(res["start"]).strftime("%Y-%m-%d-%H%M%S")
    dst = out / f"{stamp}.{kind}.json"
    dst.write_text(json.dumps(res, indent=1, ensure_ascii=False) + "\n")
    if kind == "morning":
        print(summary(res, history(out, res["start"])))
    else:
        print(json.dumps(res["setup_test"], indent=1))
    print(f"-> {dst}")


if __name__ == "__main__":
    main()
