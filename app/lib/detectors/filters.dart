// Filter chains of the shared detectors: a line-by-line port of the filter part of analysis/eeg_detectors.py.
// RBJ audio-EQ cookbook biquads with the same formulas, run forward only and starting from the channel's first
// value, so the phone gets the same numbers as the Python reference (detectors_cross_check_test.dart).
import 'dart:math' as math;

import '../feedback/features.dart' show fs;

final double _sqrt12 = math.sqrt(0.5);

/// Two equal band-pass stages: -3 dB at lo and hi.
final double qPair = math.sqrt(math.sqrt(2) - 1);

List<double> _norm(double b0, double b1, double b2, double a0, double a1, double a2) => [
  b0 / a0,
  b1 / a0,
  b2 / a0,
  a1 / a0,
  a2 / a0,
];

({double al, double cw}) _w(double f0, double q, int sampleRate) {
  final w = 2 * math.pi * f0 / sampleRate;
  return (al: math.sin(w) / (2 * q), cw: math.cos(w));
}

List<double> highPass(double f0, {double? q, int sampleRate = fs}) {
  final (:al, :cw) = _w(f0, q ?? _sqrt12, sampleRate);
  return _norm((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + al, -2 * cw, 1 - al);
}

List<double> lowPass(double f0, {double? q, int sampleRate = fs}) {
  final (:al, :cw) = _w(f0, q ?? _sqrt12, sampleRate);
  return _norm((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + al, -2 * cw, 1 - al);
}

/// 0 dB at f0.
List<double> bandPass(double f0, double q, {int sampleRate = fs}) {
  final (:al, :cw) = _w(f0, q, sampleRate);
  return _norm(al, 0, -al, 1 + al, -2 * cw, 1 - al);
}

List<double> notch(double f0, double q, {int sampleRate = fs}) {
  final (:al, :cw) = _w(f0, q, sampleRate);
  return _norm(1, -2 * cw, 1, 1 + al, -2 * cw, 1 - al);
}

List<List<double>> bandPair(double lo, double hi) {
  final f0 = math.sqrt(lo * hi), c = bandPass(f0, qPair * f0 / (hi - lo));
  return [c, [...c]];
}

/// One biquad stage with its coefficients and state in plain double fields (unboxed: twice as fast as a list on a
/// whole night of 11 million samples); the same arithmetic in the same order as features.dart's `Biquad.step`.
final class _Stage {
  _Stage(List<double> c) : c0 = c[0], c1 = c[1], c2 = c[2], c3 = c[3], c4 = c[4];
  final double c0, c1, c2, c3, c4;
  double z1 = 0, z2 = 0;

  @pragma('vm:prefer-inline')
  double step(double x) {
    final y = c0 * x + z1;
    z1 = c1 * x - c3 * y + z2;
    z2 = c2 * x - c4 * y;
    return y;
  }
}

/// A chain of biquads that starts from its first input value (a large electrode offset does not ring).
final class Chain {
  Chain(List<List<double>> coefs) : _stages = [for (final c in coefs) _Stage(c)];
  final List<_Stage> _stages;
  bool _started = false;
  double _x0 = 0;

  double step(double x) {
    if (!_started) {
      _started = true;
      _x0 = x;
    }
    var y = x - _x0;
    final st = _stages;
    for (var i = 0; i < st.length; i++) {
      y = st[i].step(y);
    }
    return y;
  }
}
