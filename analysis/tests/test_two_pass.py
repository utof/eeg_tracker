"""The phone's two-pass scorer (analysis/two_pass.py, app/lib/sleep/model.dart): its pieces, and with the app's
real models (the "onnx" group) that two passes over pieces give what one pass over the whole input gives.
  uv run --project analysis --group onnx --with pytest pytest analysis/tests/test_two_pass.py
"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

import two_pass as tp

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / "app" / "assets" / "models"


@pytest.mark.parametrize("n_ep", [1, 175, 176, 200, 300, 1549, 1680, 1681, 2000])
def test_pieces_tile_the_night_on_the_grid_with_context(n_ep):
    plan = tp.pieces(n_ep)
    assert [e for _, _, c0, c1 in plan for e in range(c0, c1)] == list(range(n_ep))
    assert (len(plan) == 1) == (n_ep <= tp.MAX_WINDOW == 175)
    for w0, w1, c0, c1 in (plan if len(plan) > 1 else []):
        assert w0 % tp.GRID == 0 and (n_ep - w1) % tp.GRID == 0 and w1 - w0 <= tp.MAX_WINDOW
        assert c0 - w0 == (0 if c0 == 0 else tp.CONTEXT_EP)
        assert w1 == n_ep or w1 - c1 >= tp.CONTEXT_EP


def night(n_ep: int, seed: int = 0) -> np.ndarray:
    """(4, samples): noise over a slow wander, about the scaled range of a real night."""
    rng = np.random.default_rng(seed)
    t = np.arange(n_ep * tp.EPOCH_SAMPLES) / 128
    slow = np.sin(2 * np.pi * t[None] / np.array([[300], [450], [700], [1100]]))
    return (rng.standard_normal((4, t.size)) + 2 * slow).astype(np.float32)


@pytest.fixture(scope="module")
def run1():
    pytest.importorskip("onnxruntime")
    return tp.sessions([MODELS / "anysleep-run1.onnx"], threads=2)


@pytest.mark.parametrize("n_ep", [200, 213])
def test_the_pieces_counts_add_up_to_the_whole_inputs(run1, n_ep):
    """Pass 1 counts every sample of every connection once, the left pads included, as one pass averages them."""
    x = night(n_ep)
    _, _, whole = run1[0].run(None, tp.feeds(tp.window(x, 0, n_ep)))
    total = sum(run1[0].run(None, tp.feeds(tp.window(x, w0, w1), keep=(c0 - w0, c1 - w0)))[2]
                for w0, w1, c0, c1 in tp.pieces(n_ep, piece=64, context=16))
    np.testing.assert_array_equal(total, whole)


def test_two_passes_over_pieces_give_the_one_pass(run1):
    n_ep = 213  # 3 pieces of 64 epochs, 16 of context; an odd length, so AnySleep pads on the left
    x = night(n_ep, seed=1)
    one = tp.probabilities(run1, x, n_ep, [(0, n_ep, 0, n_ep)])
    two = tp.probabilities(run1, x, n_ep, tp.pieces(n_ep, piece=64, context=16))
    own = tp.probabilities(run1, x, n_ep, tp.pieces(n_ep, piece=64, context=16), two_pass=False)
    old = tp.probabilities(run1, x, n_ep, tp.old_pieces(n_ep))
    assert np.abs(two - one).max() < 1e-4  # float rounding only
    # what each fix alone leaves: the pieces' own averages, and pieces off the grid (the old 1-hour plan)
    assert np.abs(own - one).max() > 1e-3 and np.abs(old - one).max() > 1e-3


def test_the_dart_fixture_is_current(run1):
    sys.path.insert(0, str(ROOT / "app" / "test" / "fixtures"))
    import make_two_pass_fixture as mk
    meta, blob = mk.make()
    want = json.loads((mk.OUT / "expected.json").read_text())
    assert {k: v for k, v in meta.items() if k != "probabilities"} == {k: v for k, v in want.items()
                                                                       if k != "probabilities"}
    np.testing.assert_allclose(meta["probabilities"], want["probabilities"], atol=1e-6)
    np.testing.assert_allclose(blob, np.fromfile(mk.OUT / "outputs.bin", dtype="<f4"), rtol=1e-5, atol=1e-5)
