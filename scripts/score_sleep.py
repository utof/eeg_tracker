"""Score sleep in a BDF from to_bdf.py with AnySleep (O1 O2 T3 T4) and YASA (O1-T3), and draw a hypnogram.

usage: score_sleep.py night.bdf [--anysleep _local/vendor/AnySleep] [--device cpu]

Writes <night>.sleep.json (per 30 s epoch: both models' stages, AnySleep probabilities, gap flag; and a
summary) and <night>.hypnogram.png. Epochs touching a BAD_gap / BAD_padding annotation are reported as "gap".
The BDF may hold any channels: O1 O2 T3 T4 are found by name, else by 10-10 site (T7 for T3, T8 for T4); a night
without them is refused in words and no other channel is scored in their place (docs/data-format.md).
Neither model was validated on dry BrainBit electrodes (DECISIONS.md row 8): the result is a first guess.
AnySleep code and weights: github.com/dslaborg/AnySleep (MIT), fetched by scripts/get_anysleep.sh.
A night up to 14 h goes through AnySleep (PyTorch) in one pass; a longer one is scored as the phone scores every
night (two passes over 64-minute pieces with the app's ONNX models, analysis/two_pass.py; DECISIONS 260-264, 310),
which gives what one pass over the whole night gives without its memory.
"""
import argparse, importlib.util, json, sys
from collections.abc import Callable
from datetime import datetime, timedelta
from fractions import Fraction
from pathlib import Path

import mne
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import recording  # noqa: E402  (channels by name or 10-10 site)

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "app" / "assets" / "models"  # the phone's AnySleep runs (scripts/export_anysleep_onnx.py)
STAGES = ["W", "N1", "N2", "N3", "R"]
EPOCH = 30
ASLEEP = {"N1", "N2", "N3", "R"}


MAX_MISSING_S = 5  # an epoch with more filled-in time than this is not scored


def gap_mask(raw: mne.io.BaseRaw, n_ep: int) -> np.ndarray:
    missing = np.zeros(n_ep)
    for a in raw.annotations:
        if a["description"].startswith("BAD"):
            lo, hi = a["onset"], a["onset"] + max(a["duration"], 0.0)
            for e in range(int(lo // EPOCH), min(int(np.ceil(hi / EPOCH)), n_ep)):
                missing[e] += min(hi, (e + 1) * EPOCH) - max(lo, e * EPOCH)
    return missing > MAX_MISSING_S


CHANNELS = ["O1", "O2", "T3", "T4"]
WHO = "the sleep model"
HIGH_PASS_HZ = 0.3
MODEL_HZ = 128


def sleep_channels(raw: mne.io.BaseRaw) -> mne.io.BaseRaw:
    """The night with the model's O1 O2 T3 T4 under those names, found among its channels by name, else by 10-10
    site (T7 for T3, T8 for T4; scripts/recording.py), wherever they are and whatever else it holds. A night that
    lacks one is a recording.MissingChannels in words: no other channel is ever scored in its place. A night that
    already names all four is returned as it is."""
    names = list(raw.ch_names)
    if all(c in names for c in CHANNELS):
        return raw
    found = [names[i] for i in recording.pick_names(names, CHANNELS, WHO)]
    r = raw.copy().pick(found)
    r.reorder_channels(found)
    r.rename_channels(dict(zip(found, CHANNELS)))
    return r


def prepare(raw: mne.io.BaseRaw) -> np.ndarray:
    """The model's input before epoching: (4, samples at 128 Hz), O1 O2 T3 T4, each channel robust-scaled.

    The phone app does the same in Dart (app/lib/sleep/prep.dart; cross-checked by app/test/sleep_prep_test.dart)."""
    from scipy.signal import resample_poly
    # PSG amplifiers high-pass the signal; the BrainBit drifts by tens of mV, which would swamp the robust scaling.
    # The 0.3 Hz high-pass is our choice, not part of the AnySleep recipe.
    r = sleep_channels(raw).copy().pick(CHANNELS).filter(HIGH_PASS_HZ, None, verbose="error")
    f = Fraction(MODEL_HZ, round(r.info["sfreq"]))
    x = resample_poly(r.get_data(), f.numerator, f.denominator, axis=1)
    del r
    for c in range(len(x)):  # AnySleep's recipe: clip at 20 x IQR around 0, then robust scaling
        q25, q50, q75 = np.percentile(x[c], [25, 50, 75]); iqr = (q75 - q25) or 1.0
        x[c] = (np.clip(x[c], -20 * iqr, 20 * iqr) - q50) / iqr
    return x


ONE_PASS_EP = 14 * 120  # up to 14 h in one PyTorch pass (sleep_report peaked at 2.8 GB on a 12.8 h night here)
ONE_PASS, TWO_PASS = "pytorch one-pass", "onnx-f16 two-pass-64min+8min"  # sleep.json `scorer`; the second as the phone


def scorer(n_ep: int) -> str:
    """How a night of n_ep epochs goes through AnySleep (sleep.json `scorer`)."""
    return ONE_PASS if n_ep <= ONE_PASS_EP else TWO_PASS


def anysleep(raw: mne.io.BaseRaw, repo: Path, n_ep: int, device: str,
             progress: Callable[[str], None] = print, models: Path = MODELS) -> np.ndarray:
    """Mean softmax of the three AnySleep runs, shape (n_ep, 5) in STAGES order: one PyTorch pass over a night up
    to 14 h (`repo`: AnySleep's code and weights), the phone's two passes over a longer one (`models`)."""
    if scorer(n_ep) == TWO_PASS:
        return phone_passes(prepare(raw)[:, : n_ep * 3840], n_ep, models, progress)
    import torch
    spec = importlib.util.spec_from_file_location("anysleep_no_hydra", repo / "examples" / "anysleep_no_hydra.py")
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    x = prepare(raw)
    t = torch.from_numpy(np.ascontiguousarray(x[:, : n_ep * 3840].T)).float().unsqueeze(0).to(device)
    del x
    probs = []
    with torch.no_grad():
        for run in (1, 2, 3):
            progress(f"Sleep model AnySleep, run {run} of 3")
            m = mod.AnySleep(path=str(repo / "models" / f"anysleep-run{run}.pth"), sleep_stage_frequency=1).eval().to(device)
            probs.append(torch.softmax(m(t)[0], dim=1).cpu().numpy().astype(np.float64))  # as before: mean in float64
    return np.mean(probs, axis=0)


def phone_passes(x: np.ndarray, n_ep: int, models: Path, progress: Callable[[str], None] = print) -> np.ndarray:
    """The phone's scorer (analysis/two_pass.py, app/lib/sleep/model.dart) on x (4, samples at 128 Hz): per run,
    pass 1 sums AnySleep's channel-weighting features over the night's 64-minute pieces, pass 2 scores each piece
    with the night's averages. One run in memory at a time, about 150 MB a model call (DECISIONS 264)."""
    if str(ROOT / "analysis") not in sys.path:
        sys.path.insert(0, str(ROOT / "analysis"))
    import two_pass
    out = np.zeros((n_ep, len(STAGES)))
    for run in (1, 2, 3):
        progress(f"Sleep model AnySleep, run {run} of 3 (two passes, as on the phone)")
        out += two_pass.probabilities(two_pass.sessions([models / f"anysleep-run{run}.onnx"]), x, n_ep)
    return out / 3


def yasa_stages(raw: mne.io.BaseRaw, n_ep: int) -> list[str]:
    import yasa
    r = mne.set_bipolar_reference(raw.copy().pick(["O1", "T3"]), anode="O1", cathode="T3", ch_name="O1-T3",
                                  verbose="error")
    hyp = yasa.SleepStaging(r, eeg_name="O1-T3").predict()
    names = {"WAKE": "W", "W": "W", "N1": "N1", "N2": "N2", "N3": "N3", "REM": "R", "R": "R"}
    out = [names.get(str(s), "?") for s in list(hyp.hypno)][:n_ep]
    return out + ["?"] * (n_ep - len(out))


def summary(stage: list[str], gap: np.ndarray, other: list[str], conf: np.ndarray) -> dict:
    ok = ~gap
    sleep = [i for i, s in enumerate(stage) if s in ASLEEP and ok[i]]
    res: dict = dict(epochs=len(stage), recorded_min=round(ok.sum() * EPOCH / 60, 1),
                     gap_min=round(gap.sum() * EPOCH / 60, 1))
    if sleep:
        a, b = sleep[0], sleep[-1]
        res.update(sleep_onset_epoch=a, final_wake_epoch=b + 1,
                   total_sleep_min=round(len(sleep) * EPOCH / 60, 1),
                   wake_after_onset_min=round(sum(stage[i] == "W" and ok[i] for i in range(a, b + 1)) * EPOCH / 60, 1))
    res["stage_min"] = {s: round(sum(st == s and ok[i] for i, st in enumerate(stage)) * EPOCH / 60, 1) for s in STAGES}
    both = [(x, y) for i, (x, y) in enumerate(zip(stage, other)) if ok[i] and y != "?"]
    if both:
        coarse = lambda s: "W" if s == "W" else "R" if s == "R" else "NREM"  # noqa: E731
        res["agreement_5_stage"] = round(np.mean([x == y for x, y in both]), 3)
        res["agreement_w_nrem_rem"] = round(np.mean([coarse(x) == coarse(y) for x, y in both]), 3)
    res["anysleep_mean_confidence"] = round(float(conf[ok].mean()), 3) if ok.any() else None
    return res


def plot(path: Path, start, stage: list[str], other: list[str], gap: np.ndarray, title: str | None = None) -> None:
    import matplotlib; matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    level = {"W": 4, "R": 3, "N1": 2, "N2": 1, "N3": 0}
    t = [start + timedelta(seconds=i * EPOCH) for i in range(len(stage) + 1)]
    fig, axes = plt.subplots(2, 1, figsize=(12, 4.5), sharex=True)
    for ax, st, name in zip(axes, (stage, other), ("AnySleep, 4 channels", "YASA, O1-T3")):
        y = [np.nan if gap[i] or s not in level else level[s] for i, s in enumerate(st)]
        ax.step(t, y + [y[-1]], where="post", color="#3b6ea5", lw=1.2)
        for i in np.nonzero(gap)[0]:
            ax.axvspan(t[i], t[i + 1], color="#bbbbbb", lw=0)
        ax.set_yticks(list(level.values()), list(level.keys())); ax.set_ylim(-0.5, 4.5)
        ax.set_title(name, loc="left", fontsize=10); ax.grid(axis="y", alpha=0.3)
    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    fig.suptitle(f"{title or f'Night of {start:%Y-%m-%d}'}  (grey = no data; a first guess, not validated on BrainBit)",
                 fontsize=10)
    fig.tight_layout(); fig.savefig(path, dpi=110); plt.close(fig)


def score(bdf: Path, repo: Path, device: str = "cpu", progress: Callable[[str], None] = print) -> dict:
    """Both models on one BDF from to_bdf.py; returns the content of <night>.sleep.json (see main)."""
    progress("Reading the night file")
    raw = sleep_channels(mne.io.read_raw_bdf(bdf, preload=True, verbose="error"))  # refuses a night without them
    n_ep = int(raw.n_times / raw.info["sfreq"] // EPOCH)
    if n_ep < 10:
        raise SystemExit("need at least 5 minutes")
    start = raw.info["meas_date"].replace(tzinfo=None)  # to_bdf writes local clock time; MNE labels it UTC
    gap = gap_mask(raw, n_ep)
    p = anysleep(raw, repo, n_ep, device, progress)
    stage = [STAGES[k] for k in p.argmax(1)]
    progress("Second opinion: YASA")
    other = yasa_stages(raw, n_ep)
    res = summary(stage, gap, other, p.max(1))
    return dict(source=bdf.name, start=start.isoformat(), epoch_s=EPOCH, scorer=scorer(n_ep), summary=res,
                epochs=[dict(t=(start + timedelta(seconds=i * EPOCH)).isoformat(timespec="seconds"),
                             anysleep="gap" if gap[i] else stage[i], yasa="gap" if gap[i] else other[i],
                             p=[round(float(v), 3) for v in p[i]]) for i in range(n_ep)])


def save(out: dict, base: Path, title: str | None = None) -> None:
    """Write <base>.sleep.json and <base>.hypnogram.png from score()'s result."""
    Path(f"{base}.sleep.json").write_text(json.dumps(out, indent=1))
    ep = out["epochs"]
    gap = np.array([e["anysleep"] == "gap" for e in ep])
    plot(Path(f"{base}.hypnogram.png"), datetime.fromisoformat(out["start"]), [e["anysleep"] for e in ep],
         [e["yasa"] for e in ep], gap, title)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("bdf", type=Path)
    ap.add_argument("--anysleep", type=Path, default=Path("_local/vendor/AnySleep"))
    ap.add_argument("--device", default="cpu")
    a = ap.parse_args()
    try:
        out = score(a.bdf, a.anysleep, a.device, progress=lambda _s: None)
    except recording.RecordingError as e:
        raise SystemExit(f"{a.bdf.name}: {e}") from e
    base = a.bdf.with_suffix("")
    save(out, base)
    print(json.dumps(out["summary"], indent=1))
    print(f"wrote {base}.sleep.json and {base}.hypnogram.png")


if __name__ == "__main__":
    main()
