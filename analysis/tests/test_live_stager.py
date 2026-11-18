"""The live scorer's reference (analysis/live_stager.py): what the phone may compute with only the past, and the
nap coach's deep-sleep rule. The ONNX part needs the "onnx" group and is skipped without it."""
import numpy as np
import pytest
from scipy.signal import resample_poly

import live_stager as ls


def test_the_streaming_resampler_gives_the_whole_stream_values_once_ready():
    """Model sample m needs input (m*125+1250)//64: up to then a prefix gives the same value as the whole stream."""
    rng = np.random.default_rng(1)
    x = rng.standard_normal((9000, 4)).cumsum(0)
    whole = resample_poly(x, ls.UP, ls.DOWN, axis=0)
    for n in (1, 20, 21, 2000, 7519, 7520, 8999):
        ready = ls.ready_model_samples(n)
        part = resample_poly(x[:n], ls.UP, ls.DOWN, axis=0)
        assert np.allclose(part[:ready], whole[:ready], rtol=0, atol=1e-9), n
    # one sample later than the rule allows, a prefix still misses input (the zero padding at its end shows)
    part = resample_poly(x[:7519], ls.UP, ls.DOWN, axis=0)
    assert ls.ready_model_samples(7519) == 3840 and np.abs(part[3840] - whole[3840]).max() > 1e-3


def test_ready_epochs_count_only_whole_epochs_whose_samples_all_exist():
    assert ls.ready_epochs(7500) == 0  # the epoch's last model samples need 20 more inputs
    assert ls.ready_epochs(7520) == 1
    assert ls.ready_epochs(75020) == 10
    assert ls.ready_model_samples(0) == 0


def test_the_high_pass_is_causal_and_starts_without_a_swing():
    rng = np.random.default_rng(2)
    x = 12000 + rng.standard_normal((5000, 4)) * 20  # a dry electrode sits 12 mV off
    y = ls.causal_highpass(x)
    assert np.allclose(ls.causal_highpass(x[:3000]), y[:3000])
    assert np.abs(y[:250]).max() < 200  # no 12 000 µV start-up swing
    flat = ls.causal_highpass(np.full((1000, 4), 3000.0))
    assert np.abs(flat).max() < 1e-6


def test_scaling_is_anysleeps_over_the_window():
    rng = np.random.default_rng(3)
    w = rng.standard_normal((3840 * 3, 4)) * 30
    w[100] = 1e6  # clipped at 20 IQR
    s = ls.scale(w)
    q = np.percentile(w, [25, 50, 75], axis=0)
    iqr = q[2] - q[0]
    assert np.allclose(s, (np.clip(w, -20 * iqr, 20 * iqr) - q[1]) / iqr)


def test_gap_epochs_need_over_five_seconds_held():
    m = np.zeros(3 * ls.EPOCH_IN, bool)
    m[:1250] = True  # exactly 5 s: still scored
    m[ls.EPOCH_IN:ls.EPOCH_IN + 1251] = True
    assert ls.gap_epochs(m, 3).tolist() == [False, True, False]


def test_deep_sleep_counts_after_two_epochs_in_a_row():
    assert ls.deep_trigger(["W", "N2", "N3", "N2", "N3", "N3", "N3"]) == 5
    assert ls.deep_trigger(["N3", "gap", "N3", None, "N3"]) is None
    assert ls.deep_trigger(["N3", "N3"], start=1) is None


def test_deep_sleep_stretches_follow_five_quiet_minutes():
    off = ["W"] * 12 + ["N3"] * 3 + ["N2"] * 4 + ["N3"] + ["N2"] * 10 + ["N3"]
    assert ls.n3_bouts(off) == [12, 30]


def test_kappa_is_one_for_identical_and_zero_for_chance():
    assert ls.kappa(["W", "N2", "N3"], ["W", "N2", "N3"], ls.STAGES) == pytest.approx(1)
    assert ls.kappa(["W", "W", "N2", "N2"], ["W", "N2", "W", "N2"], ls.STAGES) == pytest.approx(0)


def test_a_replay_scores_each_edge_with_only_the_past():
    pytest.importorskip("onnxruntime")
    rng = np.random.default_rng(4)
    n_in = 13 * ls.EPOCH_IN + 30
    uv = rng.standard_normal((n_in, 4)) * 20
    res = ls.prepare_stream(uv)
    gap = np.zeros(13, bool)
    r = ls.replay(res, gap, n_in, ls.sessions(2, runs=(1,)), window=11, progress=None)
    assert r["edges"].tolist() == [10, 11, 12, 13]
    lag = r["lag"]
    assert lag.shape == (1, ls.LAGS, 13, 5)
    assert np.isnan(lag[0, 0, 10:12]).all() == False  # noqa: E712  (scored at the edge)
    # 2 min behind: edge 10 scores epoch 5, edge 13 epoch 8; nothing else
    assert np.isnan(lag[0, ls.BEHIND_EP, :5]).all() and np.isnan(lag[0, ls.BEHIND_EP, 9:]).all()
    assert np.allclose(lag[0, ls.BEHIND_EP, 5:9].sum(-1), 1, atol=1e-5)
    # the call at edge 13 used the window 2..13 only: its scores of epoch 12 match a direct call on that window
    direct = ls.run_probs(ls.sessions(2, runs=(1,)), ls.scale(res[2 * ls.EPS:13 * ls.EPS]))[0, -1]
    assert np.allclose(lag[0, 0, 12], direct, atol=1e-6)


def test_a_window_over_half_held_is_not_scored():
    gap = np.array([False, True, True, False, True, False])
    assert ls.window_ok(gap, 0, 4) and not ls.window_ok(gap, 1, 5) and ls.window_ok(gap, 3, 6)
    lag = np.ones((1, 3, 6, 5), np.float32)
    m = ls.mask_gappy(lag, gap, window=3)
    # lag 0 of epoch 2: edge 3, window 0..3 has 2 of 3 held -> not scored; epoch 3: edge 4, window 1..4 the same
    assert np.isnan(m[0, 0, 2]).all() and np.isnan(m[0, 0, 3]).all() and not np.isnan(m[0, 0, 5]).any()
    assert not np.isnan(lag).any(), "the input is left alone"
