"""The phone's two-pass sleep scorer: the reference for app/lib/sleep/model.dart (DECISIONS rows 260-264).

AnySleep fuses its four channels at each of its 13 skip connections with weights from a small network fed that
connection's features averaged over the model's whole input. Scored in pieces, a piece weighs its channels by its
own averages, not the night's, and the stages drift from one pass over the night (96.6 % the same; row 96). So:
  pass 1: each piece adds up the features of the epochs it keeps (the models' outputs `sums` and `counts`;
          scripts/export_anysleep_onnx.py `two_pass_module`); their ratio is the night's averages;
  pass 2: each piece is scored with the night's averages fed in (`means`, `use_means` = 1).
The pieces also sit on a 16-epoch (8-minute) grid: each starts on it and ends a multiple of 16 epochs before the
night ends. AnySleep halves its time axis 12 times, padding on the left when a length is odd, so only then does a
piece pool and pad its samples exactly as one pass over the night does. With at least 16 epochs of context on each
side (the network sees about 7 minutes either way) every piece then computes, on the epochs it keeps, what one
pass over the whole night computes, up to float rounding. A night of up to 175 epochs is one piece and one pass.

usage (from the repo root, needs the "onnx" group):
  uv run --project analysis --group onnx python analysis/two_pass.py <night.bdf> [...] [--one-pass] [--json out.json]
compares, for each night with its <night>.sleep.json (scripts/score_sleep.py, the laptop's one pass; over 14 h the
laptop scores with this module, DECISIONS 310): the old 1-hour pieces, the two-pass scorer, and with --one-pass the
ONNX models over the whole night at once.
"""
from __future__ import annotations

import argparse, json, resource, sys, time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
EPOCH_SAMPLES = 3840  # 30 s at 128 Hz
MEANS_WIDTH = 1037  # features over AnySleep's 13 skip connections: 6 + 9 + ... + 214 + 302
GRID = 16  # epochs: 2**12 samples (12 halvings) fit a whole number of times into 16 epochs, not fewer
PIECE_EP = 128  # epochs kept per piece (64 minutes)
CONTEXT_EP = 16  # epochs of context, at least, on each side (8 minutes); the right side takes up to 15 more
MAX_WINDOW = PIECE_EP + 2 * CONTEXT_EP + GRID - 1  # 175 epochs: the longest model input
OLD_PIECE_EP, OLD_CONTEXT_EP = 120, 30  # the phone's pieces until 2026-11-19, each weighed by its own averages

Piece = tuple[int, int, int, int]  # (first, end) epoch of the model input, (first, end) epoch kept from it


def pieces(n_ep: int, piece: int = PIECE_EP, context: int = CONTEXT_EP) -> list[Piece]:
    """The two-pass scorer's pieces: kept epochs [c0, c1) tile the night; w0 and n_ep - w1 are multiples of 16
    (piece and context must be too). A night that fits the longest input is one piece."""
    assert piece % GRID == 0 and context % GRID == 0, (piece, context)
    if n_ep <= piece + 2 * context + GRID - 1:
        return [(0, n_ep, 0, n_ep)]
    out = []
    for c0 in range(0, n_ep, piece):
        c1 = min(n_ep, c0 + piece)
        w1 = c1 + context
        out.append((max(0, c0 - context), min(n_ep, w1 + (n_ep - w1) % GRID), c0, c1))
    return out


def old_pieces(n_ep: int) -> list[Piece]:
    """The phone's pieces before the two passes (1 hour kept, 15 minutes of context each side)."""
    if n_ep <= OLD_PIECE_EP + 2 * OLD_CONTEXT_EP:
        return [(0, n_ep, 0, n_ep)]
    return [(max(0, c0 - OLD_CONTEXT_EP), min(n_ep, c0 + OLD_PIECE_EP + OLD_CONTEXT_EP), c0,
             min(n_ep, c0 + OLD_PIECE_EP)) for c0 in range(0, n_ep, OLD_PIECE_EP)]


def feeds(x: np.ndarray, keep: tuple[int, int] | None = None, means: np.ndarray | None = None) -> dict:
    """The models' inputs for x (1, samples, 4): weighed by the input's own averages, or by `means` if given."""
    n_ep = x.shape[1] // EPOCH_SAMPLES
    return {"eeg": np.ascontiguousarray(x, dtype=np.float32),
            "keep": np.array(keep or (0, n_ep), dtype=np.float32),
            "means": np.zeros((4, MEANS_WIDTH), np.float32) if means is None else means.astype(np.float32),
            "use_means": np.array([0.0 if means is None else 1.0], dtype=np.float32)}


def softmax(z: np.ndarray) -> np.ndarray:
    e = np.exp(z - z.max(-1, keepdims=True))
    return e / e.sum(-1, keepdims=True)


def window(x: np.ndarray, w0: int, w1: int) -> np.ndarray:
    """Epochs [w0, w1) of x (4, samples) as one model input (1, samples, 4)."""
    return np.ascontiguousarray(x[:, w0 * EPOCH_SAMPLES:w1 * EPOCH_SAMPLES].T, dtype=np.float32)[None]


def night_means(sess, x: np.ndarray, plan: list[Piece]) -> np.ndarray:
    """Pass 1: the night's average of every skip-connection feature per channel, (4, 1037) float32."""
    sums, counts = np.zeros((4, MEANS_WIDTH)), np.zeros(MEANS_WIDTH)
    for w0, w1, c0, c1 in plan:
        _, s, c = sess.run(None, feeds(window(x, w0, w1), keep=(c0 - w0, c1 - w0)))
        sums += s
        counts += c
    return (sums / counts).astype(np.float32)


def probabilities(sessions, x: np.ndarray, n_ep: int, plan: list[Piece] | None = None,
                  two_pass: bool = True) -> np.ndarray:
    """Mean softmax of the runs, (n_ep, 5); x is (4, samples). two_pass=False: each piece by its own averages."""
    plan = plan or pieces(n_ep)
    out = np.zeros((n_ep, 5))
    for s in sessions:
        means = night_means(s, x, plan) if two_pass and len(plan) > 1 else None
        for w0, w1, c0, c1 in plan:
            z = s.run(["logits"], feeds(window(x, w0, w1), means=means))[0][0]
            out[c0:c1] += softmax(z.astype(np.float64))[c0 - w0:c1 - w0]
    return out / len(sessions)


def sessions(paths: list[Path], threads: int = 4):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = threads
    so.enable_cpu_mem_arena = False  # as on the phone (app/lib/sleep/onnx_runs.dart)
    return [ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"]) for p in paths]


def compare(bdf: Path, sess, one_pass: bool = False) -> dict:
    """A night's stages three ways against the laptop's one pass (<night>.sleep.json from score_sleep.py)."""
    import mne
    sys.path.insert(0, str(ROOT / "scripts"))
    import score_sleep
    from export_anysleep_onnx import period_totals, stages_of
    raw = mne.io.read_raw_bdf(bdf, preload=True, verbose="error")
    n_ep = int(raw.n_times / raw.info["sfreq"] // score_sleep.EPOCH)
    gap = score_sleep.gap_mask(raw, n_ep)
    x = score_sleep.prepare(raw)[:, :n_ep * EPOCH_SAMPLES]
    del raw
    laptop = [e["anysleep"] for e in json.loads(bdf.with_name(bdf.stem + ".sleep.json").read_text())["epochs"]]
    scored = [i for i in range(min(n_ep, len(laptop))) if laptop[i] != "gap" and not gap[i]]
    res = dict(night=bdf.name, epochs=n_ep, hours=round(n_ep / 120, 2), compared=len(scored),
               laptop=period_totals(laptop))
    ways = [("old_pieces", old_pieces(n_ep), False), ("two_pass", pieces(n_ep), True)]
    if one_pass:
        ways.append(("one_pass_onnx", [(0, n_ep, 0, n_ep)], False))
    probs = {}
    for name, plan, two in ways:
        t0 = time.time()
        probs[name] = probabilities(sess, x, n_ep, plan, two_pass=two)
        st = stages_of(probs[name], gap)
        res[name] = dict(pieces=len(plan), seconds=round(time.time() - t0, 1),
                         same_stage=round(float(np.mean([st[i] == laptop[i] for i in scored])), 4),
                         differ=int(sum(st[i] != laptop[i] for i in scored)), **period_totals(st))
    if one_pass:
        for name in ("old_pieces", "two_pass"):
            res[name]["max_prob_diff_vs_one_pass_onnx"] = float(np.abs(probs[name] - probs["one_pass_onnx"]).max())
    return res


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("nights", type=Path, nargs="+", help="BDFs from scripts/sleep_report.py with their .sleep.json")
    ap.add_argument("--models", type=Path, default=ROOT / "app" / "assets" / "models")
    ap.add_argument("--one-pass", action="store_true", help="also the ONNX models over the whole night at once")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args()
    sess = sessions([a.models / f"anysleep-run{r}.onnx" for r in (1, 2, 3)], a.threads)
    out = [compare(b, sess, a.one_pass) for b in a.nights]
    result = dict(nights=out, peak_mb=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024))
    text = json.dumps(result, indent=1)
    print(text)
    if a.json:
        a.json.write_text(text + "\n")


if __name__ == "__main__":
    main()
