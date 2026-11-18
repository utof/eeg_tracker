"""Export AnySleep's three runs to ONNX for the phone app and check them against PyTorch.

usage (from the repo root):
  uv run --project analysis --group onnx python scripts/export_anysleep_onnx.py \
      [--anysleep _local/vendor/AnySleep] [--out app/assets/models] [--night _local/nights/<date>.bdf] \
      [--slice-h 3] [--check-only]

Writes <out>/anysleep-run{1,2,3}.onnx: input `eeg` float32 (1, samples, 4) at 128 Hz (O1 O2 T3 T4, robust-scaled
as score_sleep.prepare does; samples a multiple of 3840), output `logits` float32 (1, samples / 3840, 5) in the
order W N1 N2 N3 R. Opset 17 for ONNX Runtime 1.28 (flutter_onnxruntime 1.9.0). Weights are stored as float16
and cast back to float32 when the model loads, so the three files fit the app (about 6.4 MB each instead of
12.8 MB); the arithmetic stays float32.

Two lines of AnySleep depend on the input length (the odd-length pad in each encoder block and the crop in each
decoder block). The tracing exporter fixes Python-level decisions to the traced length, so for the export only
they are rewritten as tensor arithmetic that gives the same numbers for every length (checked below against the
unchanged model at lengths with every parity pattern).

Checks, printed at the end:
1. random inputs of 10, 11, 13, 37, 64 and 121 epochs: largest logit difference, unchanged PyTorch model vs ONNX;
2. with --night: the night's model input (score_sleep.prepare on the whole night, as on the laptop), a slice of
   --slice-h hours from its middle: mean probabilities of the three runs, PyTorch vs ONNX, and the stage
   agreement; then the whole night as the phone scores it (pieces, app/lib/sleep/model.dart) against the
   night's <date>.sleep.json from score_sleep.py, with the report's whole-night numbers for both;
3. with --dart-input (app/tool/prep_night.dart run on the night's recordings): the phone's own preprocessing
   against score_sleep.prepare on the BDF, and its stages scored the phone's way.
AnySleep code and weights: github.com/dslaborg/AnySleep (MIT, Copyright (c) 2026 dslaborg), commit 88e13e3.
"""
from __future__ import annotations

import argparse, importlib.util, json, resource, subprocess, sys, time
from contextlib import contextmanager
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
RUNS = (1, 2, 3)
EPOCH_SAMPLES = 3840  # 30 s at 128 Hz
OPSET = 17
STAGES = ["W", "N1", "N2", "N3", "R"]
# The phone's pieces (app/lib/sleep/model.dart): 1 hour scored per model call, with 15 minutes of context each side.
PIECE_EP, CONTEXT_EP = 120, 30


def load_anysleep(repo: Path):
    spec = importlib.util.spec_from_file_location("anysleep_no_hydra", repo / "examples" / "anysleep_no_hydra.py")
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def commit_of(repo: Path) -> str:
    try:
        return subprocess.run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, timeout=10).stdout.strip() or "unknown"
    except OSError:
        return "unknown"


@contextmanager
def traceable(mod):
    """AnySleep's length-dependent lines as tensor arithmetic, for the tracer only (same numbers in PyTorch)."""
    import torch.nn.functional as F
    enc, crop = mod.USleepEncoderBlock.forward, mod.USleepDecoderBlock.crop

    def enc_forward(self, x):  # pad one zero on the left when the length is odd, then pool
        x_res = self.enc(x)
        x_res = F.pad(x_res, (x_res.shape[-1] % 2, 0))
        return x_res, self.pool(x_res)

    def crop_traced(self, x, x_res):  # the upsampled length is never shorter, so max(0, diff) is diff
        diff = x.shape[-1] - x_res.shape[-1]
        start = diff // 2 + diff % 2
        return x[:, :, start:start + x_res.shape[-1]]

    mod.USleepEncoderBlock.forward, mod.USleepDecoderBlock.crop = enc_forward, crop_traced
    try:
        yield
    finally:
        mod.USleepEncoderBlock.forward, mod.USleepDecoderBlock.crop = enc, crop


def weights_to_float16(model, min_elements: int = 1024) -> int:
    """Store large float32 weights as float16, each followed by a Cast back to float32. Returns how many."""
    import onnx
    from onnx import helper, numpy_helper
    g, casts, n = model.graph, [], 0
    for i, init in enumerate(list(g.initializer)):
        if init.data_type != onnx.TensorProto.FLOAT or int(np.prod(init.dims)) < min_elements:
            continue
        name = init.name  # init is the message CopyFrom overwrites
        half = numpy_helper.from_array(numpy_helper.to_array(init).astype(np.float16), f"{name}__f16")
        g.initializer[i].CopyFrom(half)
        casts.append(helper.make_node("Cast", [half.name], [name], to=onnx.TensorProto.FLOAT, name=f"{name}__to_f32"))
        n += 1
    for c in reversed(casts):
        g.node.insert(0, c)
    return n


def export(mod, repo: Path, out: Path, commit: str) -> list[Path]:
    import onnx, torch
    out.mkdir(parents=True, exist_ok=True)
    paths = []
    for run in RUNS:
        net = mod.AnySleep(path=str(repo / "models" / f"anysleep-run{run}.pth"), sleep_stage_frequency=1).eval()
        tmp, dst = out / f"anysleep-run{run}.tmp.onnx", out / f"anysleep-run{run}.onnx"
        with traceable(mod), torch.no_grad():
            torch.onnx.export(net, (torch.zeros(1, 37 * EPOCH_SAMPLES, 4),), str(tmp), input_names=["eeg"],
                              output_names=["logits"], dynamic_axes={"eeg": {1: "samples"}, "logits": {1: "epochs"}},
                              opset_version=OPSET, dynamo=False, do_constant_folding=True)
        model = onnx.load(str(tmp))
        tmp.unlink()
        n = weights_to_float16(model)
        model.doc_string = (f"AnySleep run {run} (mid fusion), github.com/dslaborg/AnySleep commit {commit}, MIT licence, "
                            "Copyright (c) 2026 dslaborg. Input eeg: (1, samples, 4) float32 at 128 Hz, O1 O2 T3 T4, "
                            "robust-scaled per channel over the night; samples a multiple of 3840. Output logits: "
                            "(1, samples / 3840, 5), W N1 N2 N3 R. Exported by scripts/export_anysleep_onnx.py.")
        for k, v in dict(source="https://github.com/dslaborg/AnySleep", commit=commit, licence="MIT", run=str(run),
                         weights="float16 stored, float32 computed").items():
            model.metadata_props.append(onnx.StringStringEntryProto(key=k, value=v))
        onnx.checker.check_model(model)
        onnx.save(model, str(dst))
        print(f"run {run}: {n} weight tensors as float16, {dst.stat().st_size / 1e6:.2f} MB, IR {model.ir_version}",
              flush=True)
        paths.append(dst)
    return paths


def sessions(paths: list[Path]):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    so.enable_cpu_mem_arena = False  # as on the phone (app/lib/sleep/model.dart)
    return [ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"]) for p in paths]


def torch_models(mod, repo: Path):
    return [mod.AnySleep(path=str(repo / "models" / f"anysleep-run{r}.pth"), sleep_stage_frequency=1).eval()
            for r in RUNS]


def check_lengths(mod, repo: Path, sess) -> dict:
    """Largest logit difference per run on random inputs whose lengths cover every pad and crop pattern."""
    import torch
    g = torch.Generator().manual_seed(1)
    worst = {}
    with torch.no_grad():
        for net, s, run in zip(torch_models(mod, repo), sess, RUNS):
            d = 0.0
            for n_ep in (10, 11, 13, 37, 64, 121):
                x = torch.randn(1, n_ep * EPOCH_SAMPLES, 4, generator=g)
                a, b = net(x).numpy(), s.run(None, {"eeg": x.numpy()})[0]
                assert a.shape == b.shape == (1, n_ep, 5), (a.shape, b.shape)
                d = max(d, float(np.abs(a - b).max()))
            worst[f"run{run}"] = d
    return worst


def softmax(z: np.ndarray) -> np.ndarray:
    e = np.exp(z - z.max(-1, keepdims=True))
    return e / e.sum(-1, keepdims=True)


def pieces(n_ep: int, piece: int = PIECE_EP, context: int = CONTEXT_EP) -> list[tuple[int, int, int, int]]:
    """(first, end) epochs of each model input and (first, end) of the epochs kept from it; the phone's rule."""
    if n_ep <= piece + 2 * context:
        return [(0, n_ep, 0, n_ep)]
    out = []
    for c0 in range(0, n_ep, piece):
        c1 = min(n_ep, c0 + piece)
        w0, w1 = max(0, c0 - context), min(n_ep, c1 + context)
        out.append((w0, w1, c0, c1))
    return out


def ort_probs(sess, x: np.ndarray, n_ep: int, plan) -> np.ndarray:
    """Mean softmax of the runs; x is (4, samples) at 128 Hz."""
    out = np.zeros((n_ep, 5))
    for s in sess:
        for w0, w1, c0, c1 in plan:
            inp = np.ascontiguousarray(x[:, w0 * EPOCH_SAMPLES:w1 * EPOCH_SAMPLES].T, dtype=np.float32)[None]
            out[c0:c1] += softmax(s.run(None, {"eeg": inp})[0][0].astype(np.float64))[c0 - w0:c1 - w0]
    return out / len(sess)


def period_totals(stages: list[str]) -> dict:
    """The report's whole-night numbers (sleep_report.py) for a list of stages."""
    import sleep_report
    found, stray = sleep_report.periods(stages)
    tot = {k: sum(p["stage_min"][s] for p in found for s in v) for k, v in
           dict(asleep_min=("N1", "N2", "N3", "R"), light_min=("N1", "N2"), deep_min=("N3",), dream_min=("R",)).items()}
    return dict(tot, periods=len(found), wake_ups=sum(len(p["wake_ups"]) for p in found), stray_sleep_min=stray)


def stages_of(p: np.ndarray, gap: np.ndarray) -> list[str]:
    return ["gap" if gap[i] else STAGES[int(p[i].argmax())] for i in range(len(gap))]


def check_night(mod, repo: Path, sess, bdf: Path, slice_h: float, dart_input: Path | None) -> dict:
    import mne, torch
    import score_sleep
    raw = mne.io.read_raw_bdf(bdf, preload=True, verbose="error")
    n_ep = int(raw.n_times / raw.info["sfreq"] // score_sleep.EPOCH)
    gap = score_sleep.gap_mask(raw, n_ep)
    x = score_sleep.prepare(raw)
    del raw
    a = max(0, n_ep // 2 - int(slice_h * 60))
    b = min(n_ep, a + int(slice_h * 120))
    xs = x[:, a * EPOCH_SAMPLES:b * EPOCH_SAMPLES]
    t = torch.from_numpy(np.ascontiguousarray(xs.T)).float().unsqueeze(0)
    with torch.no_grad():
        p_torch = np.mean([torch.softmax(net(t)[0], dim=1).numpy() for net in torch_models(mod, repo)], axis=0)
    del t
    p_onnx = ort_probs(sess, xs, b - a, [(0, b - a, 0, b - a)])
    ok = ~gap[a:b]
    res = dict(night=bdf.name, slice_epochs=[a, b], slice_hours=round((b - a) / 120, 2),
               max_abs_prob_diff=float(np.abs(p_torch - p_onnx).max()),
               mean_abs_prob_diff=float(np.abs(p_torch - p_onnx).mean()),
               stage_agreement=float(np.mean(p_torch.argmax(1)[ok] == p_onnx.argmax(1)[ok])), epochs_compared=int(ok.sum()))
    sj = bdf.with_name(bdf.stem + ".sleep.json")
    if not sj.exists():
        return res
    # the whole night the phone's way (pieces) against the laptop's one pass (<night>.sleep.json)
    laptop = [e["anysleep"] for e in json.loads(sj.read_text())["epochs"]]
    t0 = time.time()
    phone = stages_of(ort_probs(sess, x, n_ep, pieces(n_ep)), gap)
    both = [i for i in range(min(n_ep, len(laptop))) if laptop[i] != "gap" and phone[i] != "gap"]
    res["whole_night"] = dict(epochs=len(both), hours=round(n_ep / 120, 2), pieces=len(pieces(n_ep)),
                              seconds=round(time.time() - t0, 1),
                              stage_agreement=float(np.mean([phone[i] == laptop[i] for i in both])),
                              laptop=period_totals(laptop), pieces_from_bdf=period_totals(phone))
    if dart_input:  # the phone's own preprocessing (app/tool/prep_night.dart) on the night's raw recordings
        meta = json.loads(Path(f"{dart_input}.json").read_text())
        xd = np.fromfile(dart_input, dtype="<f4").reshape(-1, 4).T
        gd = np.array(meta["gap"])
        assert xd.shape[1] == meta["epochs"] * EPOCH_SAMPLES
        k = min(n_ep, meta["epochs"]) * EPOCH_SAMPLES
        dart = stages_of(ort_probs(sess, xd, meta["epochs"], pieces(meta["epochs"])), gd)
        both = [i for i in range(min(len(dart), len(laptop))) if laptop[i] != "gap" and dart[i] != "gap"]
        res["dart_prep"] = dict(epochs=meta["epochs"], same_gap_flags=bool(np.array_equal(gd[:n_ep], gap[:len(gd)])),
                                max_abs_input_diff=float(np.abs(xd[:, :k] - x[:, :k]).max()),
                                mean_abs_input_diff=float(np.abs(xd[:, :k] - x[:, :k]).mean()),
                                stage_agreement_with_pieces_from_bdf=float(np.mean([dart[i] == phone[i] for i in both])),
                                stage_agreement_with_laptop=float(np.mean([dart[i] == laptop[i] for i in both])),
                                phone=period_totals(dart))
    return res


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--anysleep", type=Path, default=Path("_local/vendor/AnySleep"))
    ap.add_argument("--out", type=Path, default=ROOT / "app" / "assets" / "models")
    ap.add_argument("--night", type=Path, help="a night's BDF from to_bdf.py / sleep_report.py, for check 2")
    ap.add_argument("--slice-h", type=float, default=3.0)
    ap.add_argument("--dart-input", type=Path, help="the night prepared by app/tool/prep_night.dart, for check 3")
    ap.add_argument("--check-only", action="store_true", help="check the existing .onnx files, do not export")
    a = ap.parse_args()
    mod = load_anysleep(a.anysleep)
    paths = [a.out / f"anysleep-run{r}.onnx" for r in RUNS] if a.check_only else export(mod, a.anysleep, a.out,
                                                                                        commit_of(a.anysleep))
    sess = sessions(paths)
    result = dict(sizes_mb={p.name: round(p.stat().st_size / 1e6, 2) for p in paths},
                  lengths_max_abs_logit_diff=check_lengths(mod, a.anysleep, sess))
    if a.night:
        result["night"] = check_night(mod, a.anysleep, sess, a.night, a.slice_h, a.dart_input)
    result["peak_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
