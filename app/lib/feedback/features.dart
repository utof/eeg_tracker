// Streaming brain measures, one sample at a time (pure: no clock, no I/O). A line-by-line port of
// scripts/web/sound-features.js with the same constants, so the phone and the laptop page agree.
// Input: µV at 250 Hz, channels O1 O2 T3 T4. Each filter keeps its own state, so feeding the same samples
// gives the same numbers on any device. Expressions keep the JS order of operations on purpose: a "tidier"
// form can change the last bit, and the replay test compares logs exactly.
import 'dart:math' as math;
import 'dart:typed_data';

const int fs = 250;
const List<String> channelNames = ['O1', 'O2', 'T3', 'T4'];

/// O1, O2: alpha (eyes closed, relaxed).
const List<int> back = [0, 1];

/// T3, T4: jaw and temple muscle.
const List<int> side = [2, 3];

/// Hz, used when no personal alpha peak was found.
const List<double> alphaBand = [8, 12];

/// Hz, same fallback.
const List<double> thetaBand = [4, 8];

/// Hz, below the 50 Hz mains hum (DECISIONS row 19; row 65 plans 20-70 Hz, for both ports at once).
const List<double> muscleBand = [30, 45];

/// Hz, notched out before the muscle band.
const double mains = 50;

const double _tauAlpha = 0.05; // s, smoothing of the alpha and theta envelopes (after a ~0.1 s band-pass)
const double _tauMuscle = 0.1; // s, muscle power is noise-like, so it needs a little more averaging
final double _qPair = math.sqrt(math.sqrt2 - 1); // two equal band-pass stages: -3 dB exactly at lo and hi

/// `Math.log10` (the JS name; Dart has no log10).
double log10(double v) => math.log(v) / math.ln10;

/// JS `Math.round`: halves go up (towards +infinity), unlike Dart's `round()`, which goes away from zero.
double jsRound(double x) {
  final f = x.floorToDouble();
  return x - f >= 0.5 ? f + 1 : f;
}

/// A number as JS prints it: `10`, not `10.0`.
String jsNum(double v) => v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

final Float32List _f32 = Float32List(1);

/// `Math.fround`: the nearest float32.
double fround(double v) {
  _f32[0] = v;
  return _f32[0];
}

/// One second-order IIR section (RBJ audio-EQ cookbook), transposed direct form II.
/// c = [b0, b1, b2, a1, a2], already divided by a0.
class Biquad {
  Biquad(this.c);
  final List<double> c;
  double z1 = 0;
  double z2 = 0;

  double step(double x) {
    final y = c[0] * x + z1;
    z1 = c[1] * x - c[3] * y + z2;
    z2 = c[2] * x - c[4] * y;
    return y;
  }
}

List<double> _norm(double b0, double b1, double b2, double a0, double a1, double a2) => [
  b0 / a0,
  b1 / a0,
  b2 / a0,
  a1 / a0,
  a2 / a0,
];

/// Band-pass with 0 dB at f0.
List<double> bandPassCoefs(double f0, double q, [int sampleRate = fs]) {
  final w = (2 * math.pi * f0) / sampleRate, al = math.sin(w) / (2 * q), cw = math.cos(w);
  return _norm(al, 0, -al, 1 + al, -2 * cw, 1 - al);
}

List<double> notchCoefs(double f0, double q, [int sampleRate = fs]) {
  final w = (2 * math.pi * f0) / sampleRate, al = math.sin(w) / (2 * q), cw = math.cos(w);
  return _norm(1, -2 * cw, 1, 1 + al, -2 * cw, 1 - al);
}

List<double> lowPassCoefs(double f0, [int sampleRate = fs]) {
  final w = (2 * math.pi * f0) / sampleRate, al = math.sin(w) / (2 * math.sqrt1_2), cw = math.cos(w);
  return _norm((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + al, -2 * cw, 1 - al);
}

/// Removes the electrode's DC offset (one-pole high-pass). Starts at the first sample, so a large offset
/// does not ring through the band-pass filters after a start or a gap.
class _DcBlock {
  _DcBlock(double tauS, int sampleRate) : k = 1 - math.exp(-1 / (sampleRate * tauS));
  final double k;
  double? m;

  double step(double x) {
    var mm = m ?? x;
    mm += k * (x - mm);
    m = mm;
    return x - mm;
  }
}

/// Power in a band, µV², updated every sample. A sine of amplitude A inside the band gives A²/2.
/// Two equal band-pass stages (about 0.1 s delay at 8-12 Hz). For narrow bands (alpha, theta) the envelope
/// is taken from the signal and its slope (y² + (dy/dω)², exact for a sine at the centre frequency); muscle
/// is noise-like: plain y².
class BandPower {
  BandPower(this.lo, this.hi, {int sampleRate = fs, double notch = 0, this.quadrature = true, double? tau})
    : _dc = _DcBlock(1, sampleRate),
      _twoSin = 2 * math.sin((2 * math.pi * math.sqrt(lo * hi)) / sampleRate),
      _k = 1 - math.exp(-1 / (sampleRate * (tau ?? (quadrature ? _tauAlpha : _tauMuscle)))) {
    final f0 = math.sqrt(lo * hi), q = (_qPair * f0) / (hi - lo);
    if (notch != 0) _stages.add(Biquad(notchCoefs(notch, 8, sampleRate)));
    _stages
      ..add(Biquad(bandPassCoefs(f0, q, sampleRate)))
      ..add(Biquad(bandPassCoefs(f0, q, sampleRate)));
  }

  final double lo;
  final double hi;
  final bool quadrature;
  final _DcBlock _dc;
  final List<Biquad> _stages = [];
  final double _twoSin;
  final double _k;
  double _y1 = 0;
  double _y2 = 0;
  double value = 0;

  double step(double x) {
    var y = _dc.step(x);
    for (final s in _stages) {
      y = s.step(y);
    }
    final double p;
    if (quadrature) {
      final q = (y - _y2) / _twoSin;
      p = (_y1 * _y1 + q * q) / 2;
    } else {
      p = y * y;
    }
    _y2 = _y1;
    _y1 = y;
    value += _k * (p - value);
    return value;
  }
}

/// Slow waves (blinks, eye movements): the signal under 4 Hz minus its 0.5 s mean, in µV. The forehead
/// reference carries blinks into O1/O2 (BrainBit's reference pads sit on the forehead).
class SlowWave {
  SlowWave([int sampleRate = fs]) : _dc = _DcBlock(0.5, sampleRate), _lp = Biquad(lowPassCoefs(4, sampleRate));
  final _DcBlock _dc;
  final Biquad _lp;

  double step(double x) => _lp.step(_dc.step(x));
}

/// Fixed-size history of one channel (float32, like the JS Float32Array).
class Ring {
  Ring(int size) : _a = Float32List(size);
  final Float32List _a;
  int n = 0;

  void push(double v) {
    _a[n % _a.length] = v;
    n++;
  }

  /// The last k values (fewer if not yet there), oldest first.
  Float32List last(int k) {
    final m = math.min(k, math.min(n, _a.length)), out = Float32List(m);
    for (var j = 0; j < m; j++) {
      out[j] = _a[(n - m + j) % _a.length];
    }
    return out;
  }
}

/// 'ok', 'off' (no contact or a flat line) or 'noisy' (movement: swings over 300 µV in the last second).
/// [noContact]: the headband measured no contact on this channel (JS: contact null). An unknown contact
/// (JS: undefined) is not held against the channel.
String channelQuality(Float32List? x, {bool noContact = false}) {
  if (noContact || x == null || x.isEmpty) return 'off';
  var lo = double.infinity, hi = double.negativeInfinity;
  for (final v in x) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final p2p = hi - lo;
  if (p2p < 1) return 'off';
  if (p2p > 300) return 'noisy';
  return 'ok';
}

/// A power spectrum at evenly spaced frequencies.
class Spectrum {
  const Spectrum(this.f, this.p);
  final List<double> f;
  final List<double> p;
}

/// Power spectrum (any unit; only shapes are compared) at lo..hi Hz in steps of df, Hann window, mean
/// removed. Goertzel per frequency, so the steps need not be whole bins.
Spectrum spectrum(Float32List x, int sampleRate, double lo, double hi, [double df = 0.25]) {
  final n = x.length, w = Float64List(n);
  var mean = 0.0;
  for (var i = 0; i < n; i++) {
    mean += x[i];
  }
  mean /= n;
  for (var i = 0; i < n; i++) {
    w[i] = (x[i] - mean) * (0.5 - 0.5 * math.cos((2 * math.pi * i) / (n - 1)));
  }
  final f = <double>[], p = <double>[];
  for (var k = 0; lo + k * df <= hi + 1e-9; k++) {
    final hz = lo + k * df, c = 2 * math.cos((2 * math.pi * hz) / sampleRate);
    var s1 = 0.0, s2 = 0.0;
    for (var i = 0; i < n; i++) {
      final s = w[i] + c * s1 - s2;
      s2 = s1;
      s1 = s;
    }
    f.add(hz);
    p.add(s1 * s1 + s2 * s2 - c * s1 * s2);
  }
  return Spectrum(f, p);
}

/// Highest point between lo and hi, and how far it stands above the median of the whole spectrum.
/// hz is null when the top sits on the edge of lo..hi (no real peak inside).
({double? hz, double ratio}) findPeak(Spectrum spec, double lo, double hi) {
  var best = -1;
  for (var i = 0; i < spec.f.length; i++) {
    if (spec.f[i] < lo - 1e-9 || spec.f[i] > hi + 1e-9) continue;
    if (best < 0 || spec.p[i] > spec.p[best]) best = i;
  }
  if (best < 0) return (hz: null, ratio: 0);
  final sorted = [...spec.p]..sort(), med = sorted[sorted.length ~/ 2];
  final edge = spec.f[best] < lo + 1e-9 || spec.f[best] > hi - 1e-9;
  return (hz: edge ? null : spec.f[best], ratio: med > 0 ? spec.p[best] / med : 0);
}

double percentile(List<double> a, double p) {
  if (a.isEmpty) return double.nan;
  final s = [...a]..sort(), i = (s.length - 1) * p, lo = i.floor();
  return lo + 1 < s.length ? s[lo] + (s[lo + 1] - s[lo]) * (i - lo) : s[lo];
}

double median(List<double> a) => percentile(a, 0.5);
