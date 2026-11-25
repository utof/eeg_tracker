"""The harmonic-family helper the walking and the pulse detectors share (analysis/harmonic.py; DECISIONS 921)."""
import math

import numpy as np

import harmonic as hm
import pulse as pl
import walking as wk


def test_the_spectrum_keeps_its_bin_width_at_any_rate():
    assert [hm.nfft_for(fs, 250 / 8192) for fs in (50, 250, 256, 500, 1000)] == [2048, 8192, 16384, 16384, 32768]
    assert hm.whiten_bins(250, 250 / 8192, 41 * 250 / 8192) == 41
    assert hm.whiten_bins(500, 250 / 8192, 41 * 250 / 8192) == 41  # the same 0.0305 Hz bins at 500 a second
    assert hm.whiten_bins(256, 250 / 4096, 15 * 250 / 4096) % 2 == 1


def test_interp_is_numpys():
    rng = np.random.default_rng(1)
    w = rng.random(400)
    x = rng.uniform(0, 398 * 0.03, 500)
    assert np.allclose(hm.interp(x, 0.03, w), np.interp(x, np.arange(400) * 0.03, w), rtol=1e-12, atol=1e-12)
    assert hm.at(0.06, 0.03, w) == w[2]  # on a bin: the bin itself


def test_a_sine_and_its_harmonics_stand_out_of_a_whitened_spectrum_and_a_hump_does_not():
    fs, n = 250.0, 2500
    t = np.arange(n) / fs
    rng = np.random.default_rng(2)
    x = rng.normal(0, 1, n) + 5 * np.sin(2 * math.pi * 1.9 * t) + 3 * np.sin(2 * math.pi * 3.8 * t)
    nfft = hm.nfft_for(fs, 250 / 8192)
    bin_hz = fs / nfft
    p = hm.power(x, hm.hann(n), nfft)
    hi = int(8 / bin_hz)
    w = hm.whiten(p, 3, hi, 41)
    assert w[:3].tolist() == [0, 0, 0] and len(w) == hi + 1
    rates = np.array([1.5, 1.9, 2.3])
    score = hm.family(rates, bin_hz, w, (1.0, 0.5))
    assert score[1] > 5 * max(score[0], score[2])
    assert score[1] == hm.at(1.9, bin_hz, w) + 0.5 * hm.at(3.8, bin_hz, w)
    flat = hm.whiten(np.full(len(p), 7.0), 3, hi, 41)  # a flat spectrum whitens to 1 away from bin 0
    assert np.allclose(flat[21:], 1.0)


def test_the_band_pass_has_the_notches_only_below_the_rates_reach():
    assert len(hm.band_pass(250, 0.5, 20, (50.0, 60.0))) == 6
    assert len(hm.band_pass(100, 0.5, 20, (50.0, 60.0))) == 4  # 50 and 60 Hz are not under 45 Hz
    assert len(hm.band_pass(250, 0.7, 20)) == 4
    x = np.vstack([np.full(500, 1000.0), np.zeros(500)])
    y = hm.filter_channels(x, hm.band_pass(250, 0.7, 20))
    assert np.abs(y).max() < 1e-6  # forward from the first value: an offset gives no swing


def test_both_detectors_use_it():
    assert wk.hm is hm and pl.hm is hm
    assert wk.nfft_for(250) == 8192 and pl.nfft_for(250) == 4096
    assert wk.whiten_bins(250) == 41 and pl.whiten_bins(250) == 15
