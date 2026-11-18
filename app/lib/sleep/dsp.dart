// The signal steps of the laptop's sleep scoring (scripts/score_sleep.py `prepare`), in plain Dart so the phone
// gives the model the same input: MNE's 0.3 Hz high-pass (one-pass zero-phase FIR, "reflect_limited" edges),
// SciPy's resample_poly (Kaiser-windowed polyphase FIR, zero padding), NumPy's linear percentiles and AnySleep's
// robust scaling. Checked against a fixture made by the Python itself (test/sleep_prep_test.dart).
import 'dart:math' as math;
import 'dart:typed_data';

/// np.sinc: sin(pi x) / (pi x), 1 at 0.
double _sinc(double x) {
  if (x == 0) return 1;
  final y = math.pi * x;
  return math.sin(y) / y;
}

/// Modified Bessel function of the first kind, order 0 (power series; converges fast for the |x| <= 5 used here).
double besselI0(double x) {
  var sum = 1.0, term = 1.0;
  final q = x * x / 4;
  for (var k = 1; k < 200; k++) {
    term *= q / (k * k);
    sum += term;
    if (term < sum * 1e-17) break;
  }
  return sum;
}

/// scipy.signal.windows.hamming(n, sym=True).
Float64List hammingWindow(int n) {
  final w = Float64List(n);
  if (n == 1) return w..[0] = 1;
  final step = 2 * math.pi / (n - 1);
  for (var i = 0; i < n; i++) {
    // SciPy: 0.54 + 0.46 cos(fac), fac = linspace(-pi, pi, n) = i * step - pi, the last exactly pi
    w[i] = 0.54 + 0.46 * math.cos(i == n - 1 ? math.pi : i * step - math.pi);
  }
  return w;
}

/// scipy.signal.windows.kaiser(n, beta, sym=True).
Float64List kaiserWindow(int n, double beta) {
  final w = Float64List(n);
  final alpha = (n - 1) / 2;
  final norm = besselI0(beta);
  for (var i = 0; i < n; i++) {
    final r = alpha == 0 ? 0.0 : (i - alpha) / alpha;
    w[i] = besselI0(beta * math.sqrt(math.max(0.0, 1 - r * r))) / norm;
  }
  return w;
}

/// scipy.signal.firwin(n, cutoff, window, pass_zero=True, scale=True): a low-pass with [cutoff] relative to
/// Nyquist (0..1), DC gain 1.
Float64List firwinLowPass(int n, double cutoff, Float64List window) {
  final h = Float64List(n);
  final alpha = 0.5 * (n - 1);
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    h[i] = cutoff * _sinc(cutoff * (i - alpha)) * window[i];
    s += h[i];
  }
  for (var i = 0; i < n; i++) {
    h[i] /= s;
  }
  return h;
}

/// The taps of `raw.filter(lFreq, None)` in MNE 1.13 (FIR, firwin design, Hamming window, automatic length and
/// transition band): a unit impulse minus a low-pass at lFreq minus half the transition band.
Float64List mneHighPassTaps(double lFreq, double sfreq) {
  final trans = math.min(math.max(lFreq * 0.25, 2.0), lFreq); // l_trans_bandwidth='auto'
  var n = (3.3 * sfreq / trans).round(); // filter_length='auto', Hamming: 3.3 / transition
  if (n.isEven) n += 1;
  final lp = firwinLowPass(n, (lFreq - trans / 2) / (sfreq / 2), hammingWindow(n));
  final h = Float64List(n);
  for (var i = 0; i < n; i++) {
    h[i] = -lp[i];
  }
  h[n ~/ 2] = 1 - lp[n ~/ 2];
  return h;
}

/// In-place radix-2 complex FFT of size n (a power of two).
class Fft {
  Fft(this.n) : _cos = Float64List(n ~/ 2), _sin = Float64List(n ~/ 2), _rev = Int32List(n) {
    if (n < 2 || n & (n - 1) != 0) throw ArgumentError.value(n, 'n', 'a power of two');
    for (var k = 0; k < n ~/ 2; k++) {
      _cos[k] = math.cos(2 * math.pi * k / n);
      _sin[k] = math.sin(2 * math.pi * k / n);
    }
    var bits = 0;
    while (1 << bits < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  void transform(Float64List re, Float64List im, {bool inverse = false}) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (i < j) {
        final tr = re[i], ti = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tr;
        im[j] = ti;
      }
    }
    final sign = inverse ? 1.0 : -1.0;
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = sign * _sin[k * step];
          final a = start + k, b = a + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    if (inverse) {
      final s = 1 / n;
      for (var i = 0; i < n; i++) {
        re[i] *= s;
        im[i] *= s;
      }
    }
  }
}

int _nextPow2(int v) {
  var p = 1;
  while (p < v) {
    p <<= 1;
  }
  return p;
}

/// MNE's one-pass zero-phase FIR filtering (`phase='zero'`, `pad='reflect_limited'`): the signal is extended at
/// both ends by `min(len(h), n) - 1` samples mirrored around the edge value (zeros beyond the signal's own length),
/// convolved with the odd-length [h] by overlap-add FFT, and the centred part kept.
Float64List zeroPhaseFir(Float64List x, Float64List h) {
  final n = x.length, nh = h.length;
  if (nh.isEven) throw ArgumentError('the filter length must be odd');
  final out = Float64List(n);
  if (n == 0) return out;
  final nEdge = math.max(math.min(nh, n) - 1, 0);
  final shift = (nh - 1) ~/ 2 + nEdge;
  final nExt = n + 2 * nEdge;
  final zeros = math.max(nEdge - n + 1, 0);
  double ext(int i) {
    if (i < nEdge) return i < zeros ? 0 : 2 * x[0] - x[nEdge - i];
    final j = i - nEdge;
    if (j < n) return x[j];
    final k = j - n; // right edge: 2 x[n-1] - x[n-2-k]
    return n - 2 - k >= 0 ? 2 * x[n - 1] - x[n - 2 - k] : 0;
  }

  final nfft = math.max(_nextPow2(2 * nh - 1), math.min(16384, _nextPow2(nExt + nh - 1)));
  final seg = nfft - nh + 1;
  final fft = Fft(nfft);
  final hr = Float64List(nfft), hi = Float64List(nfft);
  for (var i = 0; i < nh; i++) {
    hr[i] = h[i];
  }
  fft.transform(hr, hi);
  final re = Float64List(nfft), im = Float64List(nfft);
  // Two segments per transform: one in the real part, the next in the imaginary part (the filter is real).
  for (var s0 = 0; s0 < nExt; s0 += 2 * seg) {
    re.fillRange(0, nfft, 0);
    im.fillRange(0, nfft, 0);
    final s1 = s0 + seg;
    for (var i = 0; i < seg && s0 + i < nExt; i++) {
      re[i] = ext(s0 + i);
    }
    for (var i = 0; i < seg && s1 + i < nExt; i++) {
      im[i] = ext(s1 + i);
    }
    fft.transform(re, im);
    for (var k = 0; k < nfft; k++) {
      final a = re[k], b = im[k];
      re[k] = a * hr[k] - b * hi[k];
      im[k] = a * hi[k] + b * hr[k];
    }
    fft.transform(re, im, inverse: true);
    _addInto(out, re, s0 - shift, nfft);
    if (s1 < nExt) _addInto(out, im, s1 - shift, nfft);
  }
  return out;
}

void _addInto(Float64List out, Float64List part, int at, int len) {
  final from = math.max(0, -at), to = math.min(len, out.length - at);
  for (var j = from; j < to; j++) {
    out[at + j] += part[j];
  }
}

/// scipy.signal.resample_poly(x, up, down) with its defaults (window ('kaiser', 5.0), padtype 'constant'):
/// ceil(n * up / down) samples.
Float64List resamplePoly(Float64List x, int up, int down) {
  final g = _gcd(up, down);
  up ~/= g;
  down ~/= g;
  final maxRate = math.max(up, down);
  final halfLen = 10 * maxRate;
  final h = firwinLowPass(2 * halfLen + 1, 1 / maxRate, kaiserWindow(2 * halfLen + 1, 5.0));
  for (var i = 0; i < h.length; i++) {
    h[i] *= up;
  }
  final n = x.length;
  final nOut = (n * up + down - 1) ~/ down;
  final y = Float64List(nOut);
  for (var m = 0; m < nOut; m++) {
    // output m sits at upsampled position m * down; the filter is centred on it
    final c = m * down + halfLen;
    var acc = 0.0;
    for (var l = c % up; l < h.length; l += up) {
      final i = (c - l) ~/ up;
      if (i < 0) break;
      if (i < n) acc += h[l] * x[i];
    }
    y[m] = acc;
  }
  return y;
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// NumPy's default (linear) percentiles of [x] for [qs] in percent, without sorting all of it.
List<double> percentiles(Float64List x, List<double> qs) {
  if (x.isEmpty) throw ArgumentError('no data');
  final a = Float64List.fromList(x);
  final n = a.length;
  return [
    for (final q in qs) _linear(a, q / 100 * (n - 1)),
  ];
}

double _linear(Float64List a, double index) {
  final lo = index.floor();
  final t = index - lo;
  final below = _select(a, lo);
  if (lo + 1 >= a.length) return below;
  var above = double.infinity; // after selection, everything right of lo is >= a[lo]
  for (var i = lo + 1; i < a.length; i++) {
    if (a[i] < above) above = a[i];
  }
  final d = above - below; // NumPy's _lerp
  return t >= 0.5 ? above - d * (1 - t) : below + d * t;
}

/// The k-th smallest value; reorders [a] so that a[k] holds it, smaller values left and larger right.
double _select(Float64List a, int k) {
  var lo = 0, hi = a.length - 1;
  while (hi > lo) {
    final mid = lo + ((hi - lo) >> 1);
    // median of three as the pivot
    if (a[mid] < a[lo]) _swap(a, mid, lo);
    if (a[hi] < a[lo]) _swap(a, hi, lo);
    if (a[hi] < a[mid]) _swap(a, hi, mid);
    final pivot = a[mid];
    var i = lo, j = hi;
    while (i <= j) {
      while (a[i] < pivot) {
        i++;
      }
      while (a[j] > pivot) {
        j--;
      }
      if (i <= j) {
        _swap(a, i, j);
        i++;
        j--;
      }
    }
    if (k <= j) {
      hi = j;
    } else if (k >= i) {
      lo = i;
    } else {
      return a[k];
    }
  }
  return a[k];
}

void _swap(Float64List a, int i, int j) {
  final t = a[i];
  a[i] = a[j];
  a[j] = t;
}

/// AnySleep's scaling of one channel, in place: clip at 20 x IQR around 0, subtract the median, divide by the
/// IQR (1 when the IQR is 0). Returns the 25th, 50th and 75th percentiles used.
List<double> robustScale(Float64List x) {
  final p = percentiles(x, const [25, 50, 75]);
  final iqr = p[2] - p[0] == 0 ? 1.0 : p[2] - p[0];
  final lim = 20 * iqr;
  for (var i = 0; i < x.length; i++) {
    x[i] = (x[i].clamp(-lim, lim) - p[1]) / iqr;
  }
  return p;
}
