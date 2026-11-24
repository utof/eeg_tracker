// The harmonic-family helper the walking and the pulse detectors share (DECISIONS 813, 921): a line-by-line port of
// analysis/harmonic.py. Both look for a rhythm with its harmonics (steps: the step rate and twice it; the pulse: the
// rate and its 2nd to 4th multiples) on a "whitened" power spectrum of a band-passed channel. What they share is here,
// once: the band-pass chain (forward-only RBJ biquads, filters.dart), the spectrum's size, the periodic Hann window,
// two channels' power from one complex transform, the whitening (each bin over the mean of the bins around it, so a
// broad hump does not look like a rhythm) and the interpolation between bins. Each detector keeps its own numbers
// (band, bin width, rates, weights of the harmonics) and its own rules. Plain Dart; the detectors' cross-check tests
// compare the results with the Python reference number for number.
import 'dart:math' as math;
import 'dart:typed_data';

import '../sleep/dsp.dart' show Fft;
import 'filters.dart' show Chain, highPass, lowPass, notch;

/// Fourth-order Butterworth as two biquads.
final List<double> butterQ = [1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8))];

/// Python's round(): halves go to the even neighbour.
int roundEven(double v) {
  final f = v.floorToDouble(), d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// The smallest power of two whose bins are at most [binHz] wide.
int harmonicNfft(num rate, double binHz) {
  var n = 1;
  while (rate / n > binHz * (1 + 1e-12)) {
    n *= 2;
  }
  return n;
}

/// The odd number of bins nearest to [whitenHz].
int harmonicWhitenBins(num rate, double binHz, double whitenHz) =>
    2 * roundEven((whitenHz / (rate / harmonicNfft(rate, binHz)) - 1) / 2) + 1;

/// The periodic Hann window of [n] points.
Float64List hannWindow(int n) =>
    Float64List.fromList([for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / n)]);

/// Linear interpolation of [w] (bin k at k * [bin]) at [x]: np.interp's formula.
double interpAt(double x, double bin, Float64List w) {
  var j = (x / bin).floor();
  if ((j + 1) * bin <= x) {
    j++;
  } else if (j * bin > x) {
    j--;
  }
  final x0 = j * bin, x1 = (j + 1) * bin;
  return (w[j + 1] - w[j]) / (x1 - x0) * (x - x0) + w[j];
}

/// The band-pass chain of one channel: mains notches (each only below 0.45 x [rate]), two high-pass and two low-pass
/// biquads (the low-pass at most 0.4 x [rate]).
Chain bandPass(
  int rate, {
  required double highPassHz,
  required double lowPassHz,
  List<double> notchesHz = const [],
  double notchQ = 8,
}) {
  final lo = math.min(lowPassHz, 0.4 * rate);
  return Chain([
    for (final f in notchesHz)
      if (f < 0.45 * rate) notch(f, notchQ, sampleRate: rate),
    for (final q in butterQ) highPass(highPassHz, q: q, sampleRate: rate),
    for (final q in butterQ) lowPass(lo, q: q, sampleRate: rate),
  ]);
}

/// Bins [lo]..[hi] of [p] whitened into [w]: each over the mean of the [bins] around it (zeros below bin 0 and past
/// the end of [p]).
void whitenInto(Float64List p, int lo, int hi, int bins, Float64List w) {
  final half = bins ~/ 2, last = p.length - 1;
  for (var k = lo; k <= hi; k++) {
    var s = 0.0;
    final to = math.min(last, k + half);
    for (var j = math.max(0, k - half); j <= to; j++) {
      s += p[j];
    }
    w[k] = p[k] / (s / bins);
  }
}

/// The harmonic score of rate [f]: [weights][0] x W(f) + [weights][1] x W(2f) + ... (a weight of 1 is not multiplied).
double familyAt(double f, double bin, Float64List w, List<double> weights) {
  var acc = weights[0] == 1 ? interpAt(f, bin, w) : weights[0] * interpAt(f, bin, w);
  for (var k = 1; k < weights.length; k++) {
    final v = interpAt((k + 1) * f, bin, w);
    acc = acc + (weights[k] == 1 ? v : weights[k] * v);
  }
  return acc;
}

/// Two channels' power spectra from one complex transform of [nfft] points: the first channel in the real part, the
/// second in the imaginary part. [load] each (mean removed, window on, zero-padded), [transform], then read the powers.
class PairSpectrum {
  PairSpectrum(this.nfft) : _fft = Fft(nfft), _re = Float64List(nfft), _im = Float64List(nfft);
  final int nfft;
  final Fft _fft;
  final Float64List _re, _im;

  void clear() {
    _re.fillRange(0, nfft, 0);
    _im.fillRange(0, nfft, 0);
  }

  /// [window].length samples of [src] from [from] into the first ([second] false) or the second slot; with [ring] the
  /// samples wrap around the end of [src].
  void load(Float64List src, int from, Float64List window, {bool second = false, bool ring = false}) {
    final n = window.length, out = second ? _im : _re, len = src.length;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += src[ring ? (from + i) % len : from + i];
    }
    final mean = sum / n;
    for (var i = 0; i < n; i++) {
      out[i] = (src[ring ? (from + i) % len : from + i] - mean) * window[i];
    }
  }

  void transform() => _fft.transform(_re, _im);

  /// The first channel's power at bin [k].
  double first(int k) {
    final j = k == 0 ? 0 : nfft - k;
    final xr = (_re[k] + _re[j]) / 2, xi = (_im[k] - _im[j]) / 2;
    return xr * xr + xi * xi;
  }

  /// The second channel's power at bin [k].
  double second(int k) {
    final j = k == 0 ? 0 : nfft - k;
    final yr = (_im[k] + _im[j]) / 2, yi = -(_re[k] - _re[j]) / 2;
    return yr * yr + yi * yi;
  }
}
