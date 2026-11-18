// The sleep model's input made live, sample by sample, for the nap coach and later the smart alarm (DECISIONS rows
// 79 and 170): the same steps as the night's preparation (prep.dart), but only with the past. The reference is
// analysis/live_stager.py; test/live_prep_test.dart checks this file against it.
//   - a 2nd-order Butterworth 0.3 Hz high-pass run forward only (SciPy `sosfilt`), its state set for a steady first
//     value, so the electrodes' offset of tens of mV gives no start-up swing (the night uses MNE's zero-phase FIR,
//     which needs the future);
//   - 250 -> 128 Hz by SciPy's resample_poly, streamed: a model sample is made once the 20 input samples (0.08 s)
//     its filter looks ahead have arrived, so it equals resampling the whole stream at once;
//   - AnySleep's robust scaling over the window only (the night scales over the whole night).
// Holes are held at the last value and counted; an epoch with over 5 s held is not scored ("gap"), as at night.
// Values are clipped at ±400 000 µV, as the night's BDF does. Pure Dart: no Flutter, no plugin.
import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';
import 'night_signal.dart' show limitMicrovolts, sampleRate;
import 'prep.dart' show epochSamples, highPassHz, modelRate;

/// The window: the last 60 minutes (DECISIONS row 79); fewer at the start.
const int liveWindowEpochs = 120;

/// Input samples (250 Hz) per 30 s epoch.
const int inputEpochSamples = 30 * sampleRate;

/// Over this many held samples (5 s) an epoch is not scored, as the night's `gapEpochs`.
const int maxHeldSamples = 5 * sampleRate;

/// scipy.signal.butter(2, hz, 'highpass', fs, output='sos'): one second-order section run forward in SciPy's
/// transposed direct form II, started with sosfilt_zi times the first value.
class HighPass2 {
  HighPass2._(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// The bilinear transform of the analogue Butterworth with the cutoff pre-warped, as SciPy designs it.
  factory HighPass2.butterworth(double hz, double fs) {
    final k = math.tan(math.pi * hz / fs), q = math.sqrt1_2;
    final norm = 1 / (1 + k / q + k * k);
    return HighPass2._(norm, -2 * norm, norm, 2 * (k * k - 1) * norm, (1 - k / q + k * k) * norm);
  }

  final double b0, b1, b2, a1, a2;
  double _z0 = 0, _z1 = 0;
  bool _started = false;

  /// The state for a signal that has been [x] for ever (output 0): SciPy's `sosfilt_zi(sos) * x`.
  List<double> startState(double x) => [-b0 * x, b2 * x];

  double step(double x) {
    if (!_started) {
      _started = true;
      _z0 = -b0 * x;
      _z1 = b2 * x;
    }
    final y = b0 * x + _z0;
    _z0 = b1 * x - a1 * y + _z1;
    _z1 = b2 * x - a2 * y;
    return y;
  }
}

/// SciPy's resample_poly(x, up, down) (Kaiser window, beta 5) for four channels at once, streamed: [add] takes one
/// input row and hands out each model row as soon as every input its filter needs has arrived. The arithmetic is
/// `resamplePoly`'s, so the values are those of resampling the whole stream.
class StreamResampler {
  StreamResampler({int up = modelRate, int down = sampleRate}) : _up = up ~/ _gcd(up, down), _down = down ~/ _gcd(up, down) {
    final maxRate = math.max(_up, _down);
    _halfLen = 10 * maxRate;
    _h = firwinLowPass(2 * _halfLen + 1, 1 / maxRate, kaiserWindow(2 * _halfLen + 1, 5.0));
    for (var i = 0; i < _h.length; i++) {
      _h[i] *= _up;
    }
    var size = 1;
    while (size < _h.length ~/ _up + 2) {
      size <<= 1;
    }
    _mask = size - 1;
    _ring = Float64List(size * 4);
  }

  final int _up, _down;
  late final int _halfLen;
  late final Float64List _h;
  late final int _mask;
  late final Float64List _ring;
  final Float64List _out = Float64List(4);

  /// Input rows received and model rows handed out.
  int inputs = 0;
  int outputs = 0;

  void add(Float64List row, void Function(Float64List out) emit) {
    final at = (inputs & _mask) * 4;
    for (var c = 0; c < 4; c++) {
      _ring[at + c] = row[c];
    }
    inputs++;
    // model row m needs input (m * down + halfLen) ~/ up
    while ((outputs * _down + _halfLen) ~/ _up < inputs) {
      _make(outputs);
      emit(_out);
      outputs++;
    }
  }

  void _make(int m) {
    final c0 = m * _down + _halfLen;
    _out.fillRange(0, 4, 0);
    for (var l = c0 % _up; l < _h.length; l += _up) {
      final i = (c0 - l) ~/ _up;
      if (i < 0) break;
      final at = (i & _mask) * 4, h = _h[l];
      _out[0] += h * _ring[at];
      _out[1] += h * _ring[at + 1];
      _out[2] += h * _ring[at + 2];
      _out[3] += h * _ring[at + 3];
    }
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
}

/// One call's input before scaling: model-rate µV of epochs [first, end) per channel, and their gap flags.
class LiveWindow {
  LiveWindow(this.first, this.end, this.channels, this.gap);
  final int first;
  final int end;
  final List<Float64List> channels;
  final List<bool> gap;
  int get epochs => end - first;

  /// NumPy's 25th, 50th and 75th percentile of channel [c] in µV (before scaling).
  List<double> percentiles(int c) => percentilesOf(channels[c], const [25, 50, 75]);
}

/// The model's input for [w]: AnySleep's robust scaling of each channel over the window, as one (time x 4 channels)
/// float32 block. Pure: runs in a background isolate (the stager's default).
Float32List scaleWindow(LiveWindow w) {
  final n = w.channels[0].length;
  final out = Float32List(n * 4);
  for (var c = 0; c < 4; c++) {
    final x = Float64List.fromList(w.channels[c]);
    robustScale(x);
    for (var i = 0; i < n; i++) {
      out[i * 4 + c] = x[i];
    }
  }
  return out;
}

/// NumPy's linear percentiles (dsp.dart's, on a copy).
List<double> percentilesOf(Float64List x, List<double> qs) => percentiles(x, qs);

/// The stream prepared for the live scorer: fed every sample as it arrives; keeps the last [window] epochs (plus the
/// epoch being filled) at the model's rate.
class LivePrep {
  LivePrep({int window = liveWindowEpochs}) : windowEpochs = window, _cap = (window + 1) * epochSamples {
    _res = [for (var c = 0; c < 4; c++) Float64List(_cap)];
  }

  /// Epochs a window holds at most.
  final int windowEpochs;
  final int _cap;
  late final List<Float64List> _res;
  final List<HighPass2> _hp = [for (var c = 0; c < 4; c++) HighPass2.butterworth(highPassHz, sampleRate.toDouble())];
  final StreamResampler _rs = StreamResampler();
  final Float64List _row = Float64List(4);
  List<double>? _last;
  final List<int> _held = [];

  /// The largest clipped value seen (µV), for tests and the log.
  double lastClipped = 0;

  /// Input samples received (held ones included).
  int get samples => _rs.inputs;

  /// Model samples made so far.
  int get modelSamples => _rs.outputs;

  /// Epochs whose model samples are all made.
  int get epochs => _rs.outputs ~/ epochSamples;

  /// Memory held by the window (bytes), about 15 MB for 60 minutes.
  int get heldBytes => _cap * 4 * 8;

  bool gapAt(int epoch) => epoch < _held.length && _held[epoch] > maxHeldSamples;

  /// One row of µV (O1, O2, T3, T4). [missing]: a held value standing in for a lost sample.
  void push(List<double> row, {bool missing = false}) {
    if (row.length != 4) throw ArgumentError.value(row, 'row', 'four values');
    _last = row;
    final e = samples ~/ inputEpochSamples;
    while (_held.length <= e) {
      _held.add(0);
    }
    if (missing) _held[e]++;
    for (var c = 0; c < 4; c++) {
      var v = row[c];
      if (v.isNaN) throw ArgumentError.value(row, 'row', 'four numbers');
      if (v > limitMicrovolts || v < -limitMicrovolts) {
        v = v.clamp(-limitMicrovolts, limitMicrovolts);
        lastClipped = v.abs();
      }
      _row[c] = _hp[c].step(v);
    }
    _rs.add(_row, _store);
  }

  /// A hole of [n] lost samples: the last row is held and counted as missing.
  void hold(int n) {
    final last = _last;
    if (last == null) return;
    for (var i = 0; i < n; i++) {
      push(last, missing: true);
    }
  }

  void _store(Float64List out) {
    final at = _rs.outputs % _cap;
    for (var c = 0; c < 4; c++) {
      _res[c][at] = out[c];
    }
  }

  /// The window ending at epoch [end] (exclusive), a copy: the last [window] epochs before it. Only the newest
  /// complete edge is guaranteed whole, so [end] must be [epochs].
  LiveWindow window(int end) {
    if (end != epochs || end <= 0) throw StateError('only the newest complete epoch ($epochs) can end a window');
    final first = math.max(0, end - windowEpochs);
    final a = first * epochSamples, n = (end - first) * epochSamples;
    final channels = <Float64List>[];
    for (var c = 0; c < 4; c++) {
      final out = Float64List(n), src = _res[c];
      final s0 = a % _cap, part = math.min(n, _cap - s0);
      out.setRange(0, part, src, s0);
      if (part < n) out.setRange(part, n, src, 0);
      channels.add(out);
    }
    return LiveWindow(first, end, channels, [for (var e = first; e < end; e++) gapAt(e)]);
  }
}
