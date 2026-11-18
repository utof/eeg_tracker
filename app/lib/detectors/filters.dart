// Filter chains of the shared detectors: a line-by-line port of the filter part of analysis/eeg_detectors.py.
// RBJ audio-EQ cookbook biquads with the same formulas, run forward only and starting from the channel's first
// value, so the phone gets the same numbers as the Python reference (detectors_cross_check_test.dart).
import 'dart:math' as math;

import '../feedback/features.dart' show Biquad, fs;

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

/// A chain of biquads that starts from its first input value (a large electrode offset does not ring).
class Chain {
  Chain(List<List<double>> coefs) : _stages = [for (final c in coefs) Biquad(c)];
  final List<Biquad> _stages;
  double? _x0;

  double step(double x) {
    final x0 = _x0 ??= x;
    var y = x - x0;
    for (final s in _stages) {
      y = s.step(y);
    }
    return y;
  }
}
