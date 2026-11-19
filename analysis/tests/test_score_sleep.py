"""score_sleep.anysleep: nights up to 14 h in one PyTorch pass (as before), longer ones the phone's way (two passes
over 64-minute pieces with the app's ONNX models, analysis/two_pass.py; DECISIONS 260-264 and 310).

The model is a fake here whose one pass over the whole night is known in closed form, so the tests run in seconds;
the last test runs the app's real ONNX models on a short synthetic night.
"""
from pathlib import Path

import numpy as np
import pytest

import score_sleep
import two_pass

WEIGHTS = np.arange(20, dtype=np.float64).reshape(4, 5) / 10


def epoch_means(x: np.ndarray) -> np.ndarray:
    """(epochs, 4): each channel's mean over each 30 s epoch of x (samples, 4)."""
    n = x.shape[0] // two_pass.EPOCH_SAMPLES
    return x[:n * two_pass.EPOCH_SAMPLES].reshape(n, two_pass.EPOCH_SAMPLES, 4).mean(1)


def one_pass_of_fake(x: np.ndarray) -> np.ndarray:
    """What FakeRun gives in one pass over the whole night x (4, samples): softmax of (epoch means less the
    night's averages) @ WEIGHTS."""
    f = epoch_means(x.T.astype(np.float32))
    return two_pass.softmax((f - f.mean(0)) @ WEIGHTS)


class FakeRun:
    """An ONNX run of AnySleep with the two-pass inputs, in miniature: an epoch's logits are its channel means less
    the averages it is weighed by (the input's own, or `means` when `use_means` is 1) times WEIGHTS; `sums` and
    `counts` add up the kept epochs' channel means (in the first of the 1037 columns)."""

    def __init__(self) -> None:
        self.calls = 0

    def run(self, names, feeds):
        self.calls += 1
        f = epoch_means(feeds["eeg"][0].astype(np.float64))
        a, b = (int(v) for v in feeds["keep"])
        means = feeds["means"][:, 0] if feeds["use_means"][0] == 1 else f.mean(0)
        sums = np.zeros((4, two_pass.MEANS_WIDTH)); sums[:, 0] = f[a:b].sum(0)
        out = dict(logits=((f - means) @ WEIGHTS)[None].astype(np.float32), sums=sums,
                   counts=np.full(two_pass.MEANS_WIDTH, float(b - a)))
        return [out[k] for k in (names or ["logits", "sums", "counts"])]


def night(n_ep: int, seed: int = 0) -> np.ndarray:
    """(4, samples): noise over a slow wander, so each stretch of the night has its own averages."""
    rng = np.random.default_rng(seed)
    t = np.arange(n_ep * two_pass.EPOCH_SAMPLES) / 128
    return rng.standard_normal((4, t.size)) + 3 * np.sin(2 * np.pi * t[None] / np.array([[900], [1300], [2100], [3700]]))


@pytest.fixture
def fake_runs(monkeypatch):
    """two_pass.sessions loads FakeRuns; returns the paths it was asked for."""
    loaded: list[Path] = []

    def sessions(paths, threads=4):
        loaded.extend(paths)
        return [FakeRun() for _ in paths]

    monkeypatch.setattr(two_pass, "sessions", sessions)
    return loaded


def test_a_long_night_is_scored_as_the_phone_scores_it(monkeypatch, fake_runs, tmp_path):
    n_ep = 500  # over the (lowered) one-pass limit: 4 pieces of 128 epochs
    x = night(n_ep)
    monkeypatch.setattr(score_sleep, "ONE_PASS_EP", 300)
    monkeypatch.setattr(score_sleep, "prepare", lambda raw: x)
    steps: list[str] = []
    p = score_sleep.anysleep(None, tmp_path / "no-anysleep-here", n_ep, "cpu", steps.append, models=tmp_path)
    assert fake_runs == [tmp_path / f"anysleep-run{r}.onnx" for r in (1, 2, 3)]  # one run at a time
    np.testing.assert_allclose(p, one_pass_of_fake(x), atol=1e-6)  # the whole night's averages, not each piece's
    own = two_pass.probabilities([FakeRun()], x, n_ep, two_pass=False)
    assert np.abs(own - one_pass_of_fake(x)).max() > 1e-3  # what the pieces alone would give
    assert steps == [f"Sleep model AnySleep, run {r} of 3 (two passes, as on the phone)" for r in (1, 2, 3)]
    assert score_sleep.scorer(n_ep) == score_sleep.TWO_PASS == "onnx-f16 two-pass-64min+8min"


FAKE_ANYSLEEP = '''
import torch

class AnySleep(torch.nn.Module):
    """Logits = epoch channel means @ WEIGHTS * the run number (the file name's digit)."""

    def __init__(self, path, sleep_stage_frequency):
        super().__init__()
        self.k = float(path[-5])

    def forward(self, x):
        n = x.shape[1] // 3840
        w = torch.arange(20, dtype=x.dtype).reshape(4, 5) / 10
        return x[:, :n * 3840].reshape(1, n, 3840, 4).mean(2) @ w * self.k
'''


def test_a_night_up_to_14_hours_stays_one_pytorch_pass(monkeypatch, fake_runs, tmp_path):
    (tmp_path / "examples").mkdir()
    (tmp_path / "examples" / "anysleep_no_hydra.py").write_text(FAKE_ANYSLEEP)
    n_ep = 300
    x = night(n_ep, seed=2)
    monkeypatch.setattr(score_sleep, "ONE_PASS_EP", 300)
    monkeypatch.setattr(score_sleep, "prepare", lambda raw: x)
    steps: list[str] = []
    p = score_sleep.anysleep(None, tmp_path, n_ep, "cpu", steps.append, models=tmp_path)
    f = epoch_means(x.T.astype(np.float32))
    want = np.mean([two_pass.softmax(f @ WEIGHTS * k) for k in (1, 2, 3)], axis=0)
    np.testing.assert_allclose(p, want, atol=1e-6)
    assert fake_runs == [] and steps == [f"Sleep model AnySleep, run {r} of 3" for r in (1, 2, 3)]
    assert score_sleep.scorer(n_ep) == score_sleep.ONE_PASS == "pytorch one-pass"


def test_the_laptop_long_path_is_the_phone_reference_with_the_real_models(monkeypatch):
    pytest.importorskip("onnxruntime")
    n_ep = 213  # 2 pieces; an odd length, so AnySleep pads on the left
    x = night(n_ep, seed=3)
    monkeypatch.setattr(score_sleep, "ONE_PASS_EP", 175)
    monkeypatch.setattr(score_sleep, "prepare", lambda raw: x)
    p = score_sleep.anysleep(None, Path("no-anysleep-here"), n_ep, "cpu", lambda _s: None)
    ref = two_pass.probabilities(two_pass.sessions([score_sleep.MODELS / f"anysleep-run{r}.onnx" for r in (1, 2, 3)]),
                                 x, n_ep)
    np.testing.assert_array_equal(p, ref)
