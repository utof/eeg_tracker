// What the brain does during a sound-for-states session (ROADMAP row 18, DECISIONS row 133), against the quiet minute
// before the sound. A port of the laptop page's readout (scripts/web/beats.html: power at 1-19 Hz of the last 2 s of
// O1/O2, Hann window, band means against the quiet minute, the beat rate ± 1 Hz left out), with three changes:
//   - twice the beat rate ± 1 Hz is left out as well (a pulse's echo has harmonics);
//   - each window's mean is removed first, so an electrode's offset cannot leak into the low bins;
//   - a second counts only when the shared detectors call it clean (rows 85-87): a usable back electrode in it and
//     in the second before (the window spans both), no movement, no blink, no hole.
// Alpha is 8-12 Hz, slow waves 4-7 Hz. The echo is the power at the beat rate against the quiet minute's power there:
// expected, since the hearing part of the brain follows a pulse; it is not "entrainment", and a tone leaking into the
// headband from earbuds can add to it. Pure and clock-free: seconds are counted by the caller.
import 'dart:math' as math;

import '../detectors/detectors.dart' show Second;

const int readoutTopHz = 19;

/// 2 s at 250 samples a second.
const int windowSamples = 500;
const int _fs = 250;

final List<double> _hann = [for (var i = 0; i < windowSamples; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (windowSamples - 1))];
final List<List<double>> _cos = [
  for (var f = 0; f <= readoutTopHz; f++) [for (var i = 0; i < windowSamples; i++) math.cos(2 * math.pi * f * i / _fs)],
];
final List<List<double>> _sin = [
  for (var f = 0; f <= readoutTopHz; f++) [for (var i = 0; i < windowSamples; i++) math.sin(2 * math.pi * f * i / _fs)],
];

/// Power at 1..19 Hz (index = Hz; index 0 unused) of [x], the last 2 s of one channel in µV.
List<double> powers(List<double> x) {
  if (x.length != windowSamples) throw ArgumentError.value(x.length, 'x', '$windowSamples samples');
  final mean = x.fold(0.0, (a, b) => a + b) / windowSamples;
  final w = [for (var i = 0; i < windowSamples; i++) _hann[i] * (x[i] - mean)];
  final p = List<double>.filled(readoutTopHz + 1, 0);
  for (var f = 1; f <= readoutTopHz; f++) {
    final c = _cos[f], s = _sin[f];
    var re = 0.0, im = 0.0;
    for (var i = 0; i < windowSamples; i++) {
      re += w[i] * c[i];
      im -= w[i] * s[i];
    }
    p[f] = re * re + im * im;
  }
  return p;
}

/// The whole-Hz bins left out of the bands: the beat rate ± 1 Hz and twice it ± 1 Hz (rounded), within 1..19 Hz.
Set<int> leftOut(double? beatHz) {
  if (beatHz == null) return const {};
  final f = beatHz.round();
  return {
    for (final c in [f, 2 * f])
      for (var k = c - 1; k <= c + 1; k++)
        if (k >= 1 && k <= readoutTopHz) k,
  };
}

/// Mean power over [lo]..[hi] Hz without the [skip] bins; NaN when every bin is left out.
double band(List<double> p, int lo, int hi, Set<int> skip) {
  var s = 0.0, n = 0;
  for (var f = lo; f <= hi; f++) {
    if (skip.contains(f)) continue;
    s += p[f];
    n++;
  }
  return n == 0 ? double.nan : s / n;
}

const List<int> alphaHz = [8, 12];
const List<int> slowHz = [4, 7];

/// One clean second of sound against the quiet minute: alpha and slow waves as ratios (1 = the same), and the
/// echo at the beat rate (null without a beat).
class SecondRead {
  const SecondRead(this.soundS, this.alpha, this.slow, this.echo);
  final int soundS;
  final double alpha;
  final double slow;
  final double? echo;
}

/// Medians over a stretch: 30 s of sound (an epoch), the last 30 clean seconds (live), or the whole session.
class ReadSummary {
  const ReadSummary(this.index, this.cleanS, this.alpha, this.slow, this.echo);

  /// Epoch number from the start of the sound (0 for live and the whole session).
  final int index;
  final int cleanS;
  final double alpha;
  final double slow;
  final double? echo;

  Map<String, Object?> toJson() => {'i': index, 'cleanS': cleanS, 'alpha': _r3(alpha), 'slow': _r3(slow), 'echo': _r3(echo)};

  /// Null when damaged. A ratio that could not be computed was saved as null and comes back as NaN.
  static ReadSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    final i = j['i'], clean = j['cleanS'], a = j['alpha'], s = j['slow'], e = j['echo'];
    if (i is! int || clean is! int || clean < 0) return null;
    if ((a != null && a is! num) || (s != null && s is! num) || (e != null && e is! num)) return null;
    return ReadSummary(i, clean, (a as num?)?.toDouble() ?? double.nan, (s as num?)?.toDouble() ?? double.nan, (e as num?)?.toDouble());
  }
}

double? _r3(double? v) => v == null || !v.isFinite ? null : (v * 1000).round() / 1000;

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

ReadSummary? _summarise(int index, List<SecondRead> reads) {
  if (reads.isEmpty) return null;
  final echoes = [
    for (final r in reads)
      if (r.echo != null && r.echo!.isFinite) r.echo!,
  ];
  return ReadSummary(
    index,
    reads.length,
    _median([for (final r in reads) r.alpha]),
    _median([for (final r in reads) r.slow]),
    echoes.isEmpty ? null : _median(echoes),
  );
}

class Readout {
  /// A comparison needs at least this many clean quiet seconds.
  static const int minBaselineS = 20;

  /// Live medians need this many clean seconds among the last 30.
  static const int minLiveS = 10;
  static const int epochS = 30;

  final List<double> _base = List<double>.filled(readoutTopHz + 1, 0);
  int baselineS = 0;
  final List<SecondRead> reads = [];

  bool get hasBaseline => baselineS >= minBaselineS;

  /// The quiet minute's mean power per Hz (null until it has enough seconds).
  List<double>? get baseline => hasBaseline ? [for (final v in _base) v / baselineS] : null;

  /// A clean second of the quiet minute.
  void quiet(List<double> p) {
    for (var f = 0; f <= readoutTopHz; f++) {
      _base[f] += p[f];
    }
    baselineS++;
  }

  /// A clean second [soundS] seconds after the sound started, with the beat at [beatHz] (null: no beat). Null when
  /// there is no quiet minute to compare with.
  SecondRead? sound(int soundS, List<double> p, double? beatHz) {
    final b = baseline;
    if (b == null) return null;
    final skip = leftOut(beatHz);
    final f = beatHz?.round();
    final r = SecondRead(
      soundS,
      band(p, alphaHz[0], alphaHz[1], skip) / band(b, alphaHz[0], alphaHz[1], skip),
      band(p, slowHz[0], slowHz[1], skip) / band(b, slowHz[0], slowHz[1], skip),
      f == null || f < 1 || f > readoutTopHz || b[f] <= 0 ? null : p[f] / b[f],
    );
    reads.add(r);
    return r;
  }

  /// The last 30 seconds of sound (by the sound's clock), once 10 of them were clean.
  ReadSummary? get live {
    if (reads.isEmpty) return null;
    final last = reads.last.soundS;
    final recent = [
      for (final r in reads.reversed.takeWhile((r) => r.soundS > last - epochS)) r,
    ];
    return recent.length < minLiveS ? null : _summarise(0, recent);
  }

  /// One summary per 30 s of sound that had a clean second.
  List<ReadSummary> get epochs {
    final by = <int, List<SecondRead>>{};
    for (final r in reads) {
      (by[r.soundS ~/ epochS] ??= []).add(r);
    }
    return [for (final k in by.keys.toList()..sort()) _summarise(k, by[k]!)!];
  }

  /// The whole session.
  ReadSummary? get summary => _summarise(0, reads);
}

/// The two back electrodes' spectra at every whole second, kept until the detectors hand that second out (one
/// second late, once its blinks are known), then combined over the electrodes that were clean in it and the second
/// before it. Fed the same rows as the detectors, held rows of a hole included, so the seconds line up.
class SpectrumFeed {
  final List<List<double>> _x = [List<double>.filled(windowSamples, 0), List<double>.filled(windowSamples, 0)];
  int _n = 0;
  final Map<int, List<List<double>>> _pending = {};
  Second? _prev;

  /// One sample of O1 and O2 (µV).
  void push(double o1, double o2) {
    final at = _n % windowSamples;
    _x[0][at] = o1;
    _x[1][at] = o2;
    _n++;
    if (_n % _fs != 0 || _n < windowSamples) return;
    final k = _n ~/ _fs - 1;
    _pending[k] = [for (final ch in _x) powers([for (var i = 0; i < windowSamples; i++) ch[(_n + i) % windowSamples]])];
    _pending.removeWhere((key, _) => key < k - 8); // the detectors are one second behind; keep a few
  }

  /// The spectrum of second [s] (index = Hz), or null when it is not usable.
  List<double>? take(Second s) {
    final prev = _prev;
    _prev = s;
    final p = _pending.remove(s.k);
    if (p == null || prev == null || prev.k != s.k - 1) return null;
    bool ok(Second x) => !x.gap && !x.movement && x.blinks == 0;
    if (!ok(s) || !ok(prev)) return null;
    final use = [
      for (var b = 0; b < 2; b++)
        if (s.backClean(b) && prev.backClean(b)) p[b],
    ];
    if (use.isEmpty) return null;
    return [for (var f = 0; f <= readoutTopHz; f++) use.fold(0.0, (a, q) => a + q[f]) / use.length];
  }
}
