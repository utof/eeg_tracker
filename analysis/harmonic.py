"""The harmonic-family helper the walking and the pulse detectors share (DECISIONS 813, 921).

Both look for a rhythm with its harmonics (steps: the step rate and twice it; the pulse: the rate and its 2nd to 4th
multiples) on a "whitened" power spectrum of a band-passed channel. What they share is here, once: the band-pass
chain (forward-only RBJ biquads, eeg_detectors.run_chain), the spectrum's size, the periodic Hann window, the power
of one window, the whitening (each bin over the mean of the bins around it, so a broad hump does not look like a
rhythm) and the interpolation between bins. Each detector keeps its own numbers (band, bin width, rates, weights of
the harmonics) and its own rules.
The phone has a line-by-line port in app/lib/detectors/harmonic.dart; the detectors' cross-check tests compare the
results number for number. Pure functions on arrays: nothing here reads files, clocks or devices.
"""

from __future__ import annotations

import math

import numpy as np
from numpy.typing import NDArray

import eeg_detectors as det

BUTTER_Q = (1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8)))  # fourth order: two biquads

Floats = NDArray[np.float64]


def nfft_for(fs: float, bin_hz: float) -> int:
    """The smallest power of two whose bins are at most bin_hz wide."""
    n = 1
    while fs / n > bin_hz * (1 + 1e-12):
        n *= 2
    return n


def whiten_bins(fs: float, bin_hz: float, whiten_hz: float) -> int:
    """The odd number of bins nearest to whiten_hz."""
    return 2 * round((whiten_hz / (fs / nfft_for(fs, bin_hz)) - 1) / 2) + 1


def hann(n: int) -> Floats:
    """The periodic Hann window (scipy's for spectra), written out so Dart computes the same."""
    return 0.5 - 0.5 * np.cos(2 * math.pi * np.arange(n) / n)


def interp(x: Floats, bin_hz: float, w: Floats) -> Floats:
    """Linear interpolation of the spectrum w (bin k at k x bin_hz) at each x (np.interp's formula, written out)."""
    j = np.floor(x / bin_hz).astype(np.int64)
    j = np.where((j + 1) * bin_hz <= x, j + 1, np.where(j * bin_hz > x, j - 1, j))
    x0, x1 = j * bin_hz, (j + 1) * bin_hz
    return (w[j + 1] - w[j]) / (x1 - x0) * (x - x0) + w[j]


def at(x: float, bin_hz: float, w: Floats) -> float:
    """interp at one frequency."""
    return float(interp(np.array([x]), bin_hz, w)[0])


def band_pass(fs: float, high_pass_hz: float, low_pass_hz: float, notches_hz: tuple[float, ...] = (),
              notch_q: float = 8.0) -> list[list[float]]:
    """The chain: mains notches (each only below 0.45 fs), two high-pass and two low-pass biquads (fourth-order
    Butterworth each way; the low-pass at most 0.4 fs)."""
    lo = min(low_pass_hz, 0.4 * fs)
    return ([det.notch(f, notch_q, fs) for f in notches_hz if f < 0.45 * fs]  # type: ignore[arg-type]
            + [det.highpass(high_pass_hz, q, fs) for q in BUTTER_Q]  # type: ignore[arg-type]
            + [det.lowpass(lo, q, fs) for q in BUTTER_Q])  # type: ignore[arg-type]


def filter_channels(x: Floats, chain: list[list[float]]) -> Floats:
    """Each row of x (channels x samples, µV) through the chain, forward only from its first value."""
    return np.vstack([det.run_chain(chain, row) for row in x]) if len(x) else np.zeros_like(x)


def power(seg: Floats, window: Floats, nfft: int) -> Floats:
    """The power spectrum of one stretch of samples: its mean removed, the window on, zero-padded to nfft."""
    spec = np.fft.rfft((seg - seg.sum() / len(seg)) * window, n=nfft)
    return spec.real * spec.real + spec.imag * spec.imag


def whiten(p: Floats, lo: int, hi: int, bins: int) -> Floats:
    """Bins 0..hi of the whitened spectrum: each of lo..hi over the mean of the `bins` around it (zeros below bin 0);
    the bins under lo stay 0."""
    half = bins // 2
    w = np.zeros(hi + 1)
    for k in range(lo, hi + 1):
        w[k] = p[k] / (p[max(0, k - half):k + half + 1].sum() / bins)
    return w


def family(rates: Floats, bin_hz: float, w: Floats, weights: tuple[float, ...]) -> Floats:
    """The harmonic score of every candidate rate: weights[0] x W(f) + weights[1] x W(2f) + ... (not divided)."""
    acc = weights[0] * interp(rates, bin_hz, w) if weights[0] != 1 else interp(rates, bin_hz, w)
    for k in range(1, len(weights)):
        v = interp((k + 1) * rates, bin_hz, w)
        acc = acc + (v if weights[k] == 1 else weights[k] * v)
    return acc
