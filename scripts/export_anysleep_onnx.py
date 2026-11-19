"""Export AnySleep's three runs to ONNX for the phone app and check them against PyTorch.

usage (from the repo root):
  uv run --project analysis --group onnx python scripts/export_anysleep_onnx.py \
      [--anysleep _local/vendor/AnySleep] [--out app/assets/models] [--night _local/nights/<date>.bdf] \
      [--slice-h 3] [--check-only]

Writes <out>/anysleep-run{1,2,3}.onnx: input `eeg` float32 (1, samples, 4) at 128 Hz (O1 O2 T3 T4, robust-scaled
as score_sleep.prepare does; samples a multiple of 3840), output `logits` float32 (1, samples / 3840, 5) in the
order W N1 N2 N3 R. Three more inputs and two more outputs open up AnySleep's channel weighting for the phone's
two-pass scorer (`two_pass_module` below, analysis/two_pass.py): `keep`, `means`, `use_means` in, `sums` and `counts` out;
with `use_means` 0 the logits are AnySleep's own. Opset 17 for ONNX Runtime 1.28 (flutter_onnxruntime 1.9.0).
Weights are stored as float16 and cast back to float32 when the model loads, so the three files fit the app (about
6.6 MB each instead of 12.9 MB); the arithmetic stays float32.

Two lines of AnySleep depend on the input length (the odd-length pad in each encoder block and the crop in each
decoder block). The tracing exporter fixes Python-level decisions to the traced length, so for the export only
they are rewritten as tensor arithmetic that gives the same numbers for every length (checked below against the
unchanged model at lengths with every parity pattern).

Checks, printed at the end:
1. random inputs of 10, 11, 13, 37, 64 and 121 epochs: largest logit difference, unchanged PyTorch model vs ONNX
   (own averages), and the same input weighed by its averages fed back in (`means`, as pass 2 does); then one call
   on the phone's longest piece (175 epochs): its time and peak memory (`piece_call`, Linux);
2. with --night: the night's model input (score_sleep.prepare on the whole night, as on the laptop), a slice of
   --slice-h hours from its middle: mean probabilities of the three runs, PyTorch vs ONNX, and the stage
   agreement; then the whole night as the phone scores it (two passes over pieces, analysis/two_pass.py and
   app/lib/sleep/model.dart) against the night's <date>.sleep.json from score_sleep.py, with the report's
   whole-night numbers for both;
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
sys.path.insert(0, str(ROOT / "analysis"))
import two_pass  # noqa: E402  (the phone's pieces and passes)
from two_pass import EPOCH_SAMPLES, MEANS_WIDTH  # noqa: E402

RUNS = (1, 2, 3)
OPSET = 17
STAGES = ["W", "N1", "N2", "N3", "R"]


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


def two_pass_module(net):
    """AnySleep with its channel weighting opened up, for the phone's two-pass scorer (DECISIONS row 260).

    AnySleep fuses the four channels at each of its 13 skip connections with weights from a small network fed the
    connection's features averaged over the whole input (`SkipConnectionBlock`: `x.mean(dim=-1)`), so a piece of the
    night weighs its channels by the piece's averages, not the night's. This wrapper adds inputs and outputs for the
    night's averages; the network and its weights are AnySleep's own, and its forward is AnySleep's with the
    skip connections spelled out.

    Inputs: `eeg` (1, samples, 4) as before; `keep` (2,) float32, the first and end epoch of the input whose features
    count in `sums`; `means` (4, 1037) float32, the averages to weigh the channels with (13 connections side by side,
    6 + 9 + ... + 302 features); `use_means` (1,) float32: 0 weighs by the input's own averages (AnySleep as is,
    `means` unused), 1 by `means`. Outputs: `logits` (1, epochs, 5); `sums` (4, 1037), each feature summed over the
    kept epochs; `counts` (1037,), how many samples each sum covers. Pass 1 adds `sums` and `counts` over the night's
    pieces; their ratio is what one pass over the whole night averages, sample for sample, when the pieces sit on
    the 16-epoch grid (analysis/two_pass.py); pass 2 feeds it back as `means`.
    """
    import torch
    import torch.nn.functional as F

    class TwoPass(torch.nn.Module):
        def __init__(self, net):
            super().__init__()
            self.net = net

        def skip(self, block, x, m, means, use_means, at):
            """One skip connection: x (channels, filters, time), m (time,) the kept samples, one run of ones."""
            n_f = x.shape[1]
            own = x.mean(dim=-1)
            use = own + use_means * (means[:, at:at + n_f] - own)  # exactly `own` when use_means is 0
            alpha = block.softmax(block.mlp(use).reshape(1, -1)).unsqueeze(-1).unsqueeze(-1)
            # the kept sum as the whole sum less the context on each side (a and r samples: the mask's leading
            # and trailing zeros). ONNX Runtime's MatMul with the mask took longer than the rest of the model, and
            # a product with the mask would copy the feature map. Its ReduceSum fails on an empty slice, so each
            # side sums at least one sample and is then zeroed when it has none
            a, r = m.argmax(), m.flip(0).argmax()
            left = x[:, :, :a.clamp(min=1)].sum(-1) * (a > 0)
            right = x[:, :, -r.clamp(min=1):].sum(-1) * (r > 0)
            kept = (x.sum(-1) - left - right) * (m.sum() > 0)
            return (x.unsqueeze(0) * alpha).sum(1), kept, m.sum().expand(n_f)

        def forward(self, eeg, keep, means, use_means):
            net = self.net
            n_ch = eeg.shape[2]
            x = eeg.transpose(1, 2).reshape(n_ch, 1, -1)
            t = torch.arange(eeg.shape[1], dtype=torch.float32)
            m = ((t >= keep[0] * EPOCH_SAMPLES) & (t < keep[1] * EPOCH_SAMPLES)).float()
            res, sums, counts, at = [], [], [], 0
            for i, enc in enumerate(net.encoders):
                x_r, x = enc(x)
                # the kept samples follow the data: AnySleep's left pad on odd lengths counts where the first
                # sample does (only the night's first piece keeps it, as the whole night would), then every
                # pooled sample belongs where its left half does
                m = F.pad(m.reshape(1, 1, -1), (m.shape[-1] % 2, 0), mode="replicate").reshape(-1)
                out, s, c = self.skip(net.skip_connections[i], x_r, m, means, use_means, at)
                res.append(out); sums.append(s); counts.append(c)
                at += x_r.shape[1]
                m = m[::2]
                # adds exactly 0 (clamped, so even an overflow to infinity adds 0), but the next level now waits
                # for this connection's fusion and sums, so ONNX Runtime frees each four-channel feature map at
                # once. Without it, its own order ran every connection after the last level and kept all 13 maps:
                # about 260 instead of 140 MB for a 175-epoch input (the earlier graph's peak)
                x = x + (out.sum() + s.sum()).clamp(0.0, 0.0)
            x = net.connector(x)
            x, s, c = self.skip(net.skip_connections[-1], x, m, means, use_means, at)
            sums.append(s); counts.append(c)
            for dec in net.decoders:
                x = dec(x, res.pop())
            return net.segment_classifier(x).transpose(1, 2), torch.cat(sums, 1), torch.cat(counts)

    return TwoPass(net).eval()


INPUTS, OUTPUTS = ["eeg", "keep", "means", "use_means"], ["logits", "sums", "counts"]


def example_inputs(n_ep: int):
    """Torch inputs of the exported graph for n_ep epochs: all kept, weighed by the input's own averages."""
    import torch
    return (torch.zeros(1, n_ep * EPOCH_SAMPLES, 4), torch.tensor([0.0, n_ep]), torch.zeros(4, MEANS_WIDTH),
            torch.zeros(1))


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


def short_names(model) -> None:
    """Drop node names and name the inner values t0, t1, ... (graph inputs, outputs and weights keep theirs): the
    tracer's long names took about 0.18 MB a run once the two-pass ops were in."""
    g = model.graph
    keep = {v.name for v in g.input} | {v.name for v in g.output} | {i.name for i in g.initializer}
    new: dict[str, str] = {}
    for node in g.node:
        node.name = ""
        for k, name in enumerate(node.output):
            if name and name not in keep:
                new[name] = node.output[k] = f"t{len(new):x}"
    for node in g.node:
        for k, name in enumerate(node.input):
            if name in new:
                node.input[k] = new[name]


def export(mod, repo: Path, out: Path, commit: str) -> list[Path]:
    import onnx, torch
    out.mkdir(parents=True, exist_ok=True)
    paths = []
    for run in RUNS:
        net = mod.AnySleep(path=str(repo / "models" / f"anysleep-run{run}.pth"), sleep_stage_frequency=1).eval()
        tmp, dst = out / f"anysleep-run{run}.tmp.onnx", out / f"anysleep-run{run}.onnx"
        with traceable(mod), torch.no_grad():
            torch.onnx.export(two_pass_module(net), example_inputs(37), str(tmp), input_names=INPUTS,
                              output_names=OUTPUTS, dynamic_axes={"eeg": {1: "samples"}, "logits": {1: "epochs"}},
                              opset_version=OPSET, dynamo=False, do_constant_folding=True)
        model = onnx.load(str(tmp))
        tmp.unlink()
        n = weights_to_float16(model)
        short_names(model)
        model.doc_string = (f"AnySleep run {run} (mid fusion), github.com/dslaborg/AnySleep commit {commit}, MIT licence, "
                            "Copyright (c) 2026 dslaborg. Input eeg: (1, samples, 4) float32 at 128 Hz, O1 O2 T3 T4, "
                            "robust-scaled per channel over the night; samples a multiple of 3840. Output logits: "
                            "(1, samples / 3840, 5), W N1 N2 N3 R. Inputs keep (2,), means (4, 1037), use_means (1,) "
                            "and outputs sums (4, 1037), counts (1037,) open up the channel weighting for a two-pass "
                            "scorer (use_means 0: AnySleep as is). Exported by scripts/export_anysleep_onnx.py.")
        for k, v in dict(source="https://github.com/dslaborg/AnySleep", commit=commit, licence="MIT", run=str(run),
                         weights="float16 stored, float32 computed", graph="two-pass").items():
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
    so.enable_cpu_mem_arena = False  # as on the phone (app/lib/sleep/onnx_runs.dart)
    return [ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"]) for p in paths]


def torch_models(mod, repo: Path):
    return [mod.AnySleep(path=str(repo / "models" / f"anysleep-run{r}.pth"), sleep_stage_frequency=1).eval()
            for r in RUNS]


def check_lengths(mod, repo: Path, sess) -> dict:
    """Largest logit difference per run on random inputs whose lengths cover every pad and crop pattern: the
    unchanged PyTorch model against ONNX weighing by the input's own averages (`own`), and against ONNX fed those
    averages through `means` (`fed`, from its own `sums` / `counts`, as pass 2 does)."""
    import torch
    g = torch.Generator().manual_seed(1)
    worst = {}
    with torch.no_grad():
        for net, s, run in zip(torch_models(mod, repo), sess, RUNS):
            own = fed = 0.0
            for n_ep in (10, 11, 13, 37, 64, 121):
                x = torch.randn(1, n_ep * EPOCH_SAMPLES, 4, generator=g)
                a = net(x).numpy()
                b, sums, counts = s.run(None, two_pass.feeds(x.numpy()))
                c = s.run(["logits"], two_pass.feeds(x.numpy(), means=sums / counts))[0]
                assert a.shape == b.shape == c.shape == (1, n_ep, 5), (a.shape, b.shape, c.shape)
                own, fed = max(own, float(np.abs(a - b).max())), max(fed, float(np.abs(a - c).max()))
            worst[f"run{run}"], worst[f"run{run}_fed"] = own, fed
    return worst


def piece_cost(sess, n_ep: int = two_pass.MAX_WINDOW) -> dict:
    """One model call on the longest piece the phone makes: seconds (median of 3) and the peak memory above the
    process's before it (Linux; the peak is reset through /proc/self/clear_refs before each call). The earlier
    1-hour graph on its longest piece (180 epochs): about 0.44 s and 141-147 MB on this laptop."""
    x = np.random.default_rng(0).standard_normal((1, n_ep * EPOCH_SAMPLES, 4)).astype(np.float32)
    f = two_pass.feeds(x, keep=(two_pass.CONTEXT_EP, n_ep - two_pass.CONTEXT_EP))
    kb = lambda key: int(next(ln for ln in open("/proc/self/status") if ln.startswith(key)).split()[1])  # noqa: E731
    sess[0].run(None, f)
    secs, peaks = [], []
    for _ in range(3):
        Path("/proc/self/clear_refs").write_text("5")
        before, t0 = kb("VmRSS:"), time.time()
        sess[0].run(None, f)
        secs.append(time.time() - t0)
        peaks.append(round((kb("VmHWM:") - before) / 1024))
    return dict(epochs=n_ep, seconds=round(sorted(secs)[1], 3), peak_mb_above=peaks)


def ort_probs(sess, x: np.ndarray, n_ep: int, plan, two: bool = False) -> np.ndarray:
    """Mean softmax of the runs; x is (4, samples) at 128 Hz; two: the two-pass scorer."""
    return two_pass.probabilities(sess, x, n_ep, plan, two_pass=two)


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
    phone = stages_of(ort_probs(sess, x, n_ep, two_pass.pieces(n_ep), two=True), gap)
    both = [i for i in range(min(n_ep, len(laptop))) if laptop[i] != "gap" and phone[i] != "gap"]
    res["whole_night"] = dict(epochs=len(both), hours=round(n_ep / 120, 2), pieces=len(two_pass.pieces(n_ep)),
                              seconds=round(time.time() - t0, 1),
                              stage_agreement=float(np.mean([phone[i] == laptop[i] for i in both])),
                              laptop=period_totals(laptop), two_pass_from_bdf=period_totals(phone))
    if dart_input:  # the phone's own preprocessing (app/tool/prep_night.dart) on the night's raw recordings
        meta = json.loads(Path(f"{dart_input}.json").read_text())
        xd = np.fromfile(dart_input, dtype="<f4").reshape(-1, 4).T
        gd = np.array(meta["gap"])
        assert xd.shape[1] == meta["epochs"] * EPOCH_SAMPLES
        k = min(n_ep, meta["epochs"]) * EPOCH_SAMPLES
        dart = stages_of(ort_probs(sess, xd, meta["epochs"], two_pass.pieces(meta["epochs"]), two=True), gd)
        both = [i for i in range(min(len(dart), len(laptop))) if laptop[i] != "gap" and dart[i] != "gap"]
        res["dart_prep"] = dict(epochs=meta["epochs"], same_gap_flags=bool(np.array_equal(gd[:n_ep], gap[:len(gd)])),
                                max_abs_input_diff=float(np.abs(xd[:, :k] - x[:, :k]).max()),
                                mean_abs_input_diff=float(np.abs(xd[:, :k] - x[:, :k]).mean()),
                                stage_agreement_with_two_pass_from_bdf=float(np.mean([dart[i] == phone[i] for i in both])),
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
    if Path("/proc/self/clear_refs").exists():
        result["piece_call"] = piece_cost(sess)
    if a.night:
        result["night"] = check_night(mod, a.anysleep, sess, a.night, a.slice_h, a.dart_input)
    result["peak_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
