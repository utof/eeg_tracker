"""The phone's sleep model (app/assets/models/anysleep-run*.onnx from scripts/export_anysleep_onnx.py).

ONNX Runtime cannot run inside `flutter test`, so the models are checked here, with the ONNX Runtime version the
phone has. Needs the "onnx" group:  uv run --project analysis --group onnx --with pytest pytest analysis/tests
Without AnySleep's code (_local/vendor/AnySleep, or ANYSLEEP_DIR) the PyTorch comparison is skipped; the full
check on a recorded night is `scripts/export_anysleep_onnx.py --check-only --night ...`.
"""
import json
import os
import re
from pathlib import Path

import numpy as np
import pytest

ort = pytest.importorskip("onnxruntime")
onnx = pytest.importorskip("onnx")

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / "app" / "assets" / "models"
PATHS = [MODELS / f"anysleep-run{r}.onnx" for r in (1, 2, 3)]


def sessions():
    so = ort.SessionOptions()
    so.intra_op_num_threads = 2
    return [ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"]) for p in PATHS]


def test_the_three_runs_fit_the_app_and_say_where_they_come_from():
    assert sum(p.stat().st_size for p in PATHS) < 20e6
    assert (MODELS / "LICENSE-AnySleep.txt").read_text().startswith("MIT License")
    for r, p in enumerate(PATHS, 1):
        m = onnx.load(str(p), load_external_data=False)
        meta = {e.key: e.value for e in m.metadata_props}
        assert meta["licence"] == "MIT" and meta["run"] == str(r) and meta["commit"] == "88e13e3"
        assert max(o.version for o in m.opset_import if o.domain in ("", "ai.onnx")) <= 17
        assert [i.name for i in m.graph.input] == ["eeg", "keep", "means", "use_means"]
        assert [o.name for o in m.graph.output] == ["logits", "sums", "counts"] and meta["graph"] == "two-pass"


@pytest.mark.parametrize("n_ep", [10, 11, 13, 37])
def test_any_length_gives_one_finite_row_per_epoch(n_ep):
    x = np.random.default_rng(n_ep).standard_normal((1, n_ep * 3840, 4)).astype(np.float32)
    import two_pass
    for s in sessions():
        y, sums, counts = s.run(None, two_pass.feeds(x))
        assert y.shape == (1, n_ep, 5) and np.isfinite(y).all()
        assert sums.shape == (4, two_pass.MEANS_WIDTH) and counts.shape == (two_pass.MEANS_WIDTH,)


def test_the_phone_input_fixture_scores():
    """The model input made by the laptop's code for the Dart cross-check (app/test/fixtures/sleep_night)."""
    fx = ROOT / "app" / "test" / "fixtures" / "sleep_night"
    meta = json.loads((fx / "expected.json").read_text())
    x = np.fromfile(fx / "model_input.bin", dtype="<f4").reshape(1, *meta["model_input_shape"])
    import two_pass
    probs = np.mean([np.exp(z) / np.exp(z).sum(-1, keepdims=True)
                     for z in (s.run(None, two_pass.feeds(x))[0][0] for s in sessions())], axis=0)
    assert probs.shape == (meta["n_ep"], 5) and np.allclose(probs.sum(1), 1, atol=1e-5)


def test_the_python_check_and_the_app_cut_the_night_into_the_same_pieces():
    import two_pass
    dart = (ROOT / "app" / "lib" / "sleep" / "model.dart").read_text()
    const = {k: int(re.search(rf"const int {k} = (\d+);", dart).group(1))
             for k in ("pieceEpochs", "contextEpochs", "gridEpochs", "meansWidth")}
    assert const == dict(pieceEpochs=two_pass.PIECE_EP, contextEpochs=two_pass.CONTEXT_EP,
                         gridEpochs=two_pass.GRID, meansWidth=two_pass.MEANS_WIDTH)
    kept = [e for _, _, c0, c1 in two_pass.pieces(1549) for e in range(c0, c1)]
    assert kept == list(range(1549))


def test_onnx_matches_pytorch_at_every_length():
    repo = Path(os.environ.get("ANYSLEEP_DIR", ROOT / "_local" / "vendor" / "AnySleep"))
    if not (repo / "models" / "anysleep-run1.pth").exists():
        pytest.skip("AnySleep's code and weights are not here (scripts/get_anysleep.sh)")
    pytest.importorskip("torch")
    import export_anysleep_onnx as ex
    worst = ex.check_lengths(ex.load_anysleep(repo), repo, sessions())
    # float16 weights: logits move by under 0.02 (they span about +-10); stages stay the same on real nights.
    # The same holds with the input's averages fed back in through `means` (run*_fed), as pass 2 does
    assert max(worst.values()) < 0.02, worst
