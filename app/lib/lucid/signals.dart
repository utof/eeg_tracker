// Dream signals (DECISIONS 304): a lucid dreamer can answer a cue from inside the dream with the eyes, left-right-
// left-right (LRLR), large and at an even pace, or with a double jaw clench when the hands-free calibration has one.
// Found in the morning over the whole night. A line-by-line port of analysis/lucid_signals.py with the same constants;
// lucid_signals_test.dart runs recorded excerpts with drawn signals through both.
//
// On this headband T3-T4 carries sideways eye movements (DECISIONS 86), so a signal is a run of the detectors' eye
// movements: at least 3 sweeps across, each the other way from the one before; each at least the sweep size (80 µV,
// or the hands-free calibration's look size) and of even size (the largest at most 1.75 times the smallest, so a
// glance out, across and back is no signal); each 0.2-1.5 s after the one before, at an even pace (the longest gap at
// most 2.5 times the shortest). In a run the longest stretch that passes, from its earliest start, is the signal.
import 'dart:math' as math;

import '../detectors/detectors.dart';
import '../detectors/gestures.dart';

/// Planning values (DECISIONS 304).
abstract final class SignalRule {
  static const double sweepUv = 80;
  static const int minSweeps = 3;

  /// Samples between sweeps: 0.2-1.5 s.
  static const int gapMin = 50, gapMax = 375;
  static const double paceEven = 2.5, sizeEven = 1.75;

  /// A signal within this long after a cue moment answers it.
  static const int answerS = 120;
}

/// One LRLR signal: the first and last sweep's samples, how many sweeps, the smallest sweep (µV).
class DreamSignal {
  const DreamSignal(this.start, this.end, this.sweeps, this.size);
  final int start, end, sweeps;
  final double size;

  /// Left-right pairs: LRLR is 3 sweeps and 2 pairs.
  int get pairs => (sweeps + 1) ~/ 2;
}

/// Runs of eye movements, each the other way from the one before and 0.2-1.5 s after it.
List<List<EyeMove>> eyeRuns(List<EyeMove> moves) {
  final out = <List<EyeMove>>[];
  for (final m in moves) {
    if (out.isNotEmpty) {
      final r = out.last, p = r.last;
      final gap = m.i - p.i;
      if (p.step * m.step < 0 && gap >= SignalRule.gapMin && gap <= SignalRule.gapMax) {
        r.add(m);
        continue;
      }
    }
    out.add([m]);
  }
  return out;
}

bool _ok(List<EyeMove> w, double sweep) {
  if (w.length < SignalRule.minSweeps) return false;
  var lo = double.infinity, hi = 0.0;
  for (final m in w) {
    lo = math.min(lo, m.step.abs());
    hi = math.max(hi, m.step.abs());
  }
  if (lo < sweep || hi > SignalRule.sizeEven * lo) return false;
  var gLo = 1 << 30, gHi = 0;
  for (var j = 1; j < w.length; j++) {
    final g = w[j].i - w[j - 1].i;
    gLo = math.min(gLo, g);
    gHi = math.max(gHi, g);
  }
  return gHi <= SignalRule.paceEven * gLo;
}

/// The LRLR signals among the eye movements (in sample order).
List<DreamSignal> lrlrSignals(List<EyeMove> moves, {double sweepUv = SignalRule.sweepUv}) {
  final out = <DreamSignal>[];
  for (final r in eyeRuns(moves)) {
    var a = 0;
    while (a + SignalRule.minSweeps <= r.length) {
      var found = false;
      for (var b = r.length; b >= a + SignalRule.minSweeps; b--) {
        final w = r.sublist(a, b);
        if (_ok(w, sweepUv)) {
          out.add(DreamSignal(w.first.i, w.last.i, w.length, w.map((m) => m.step.abs()).reduce(math.min)));
          a = b;
          found = true;
          break;
        }
      }
      if (!found) a++;
    }
  }
  return out;
}

/// What the morning pass found over a night (sample numbers from the night's first sample).
class FoundSignals {
  const FoundSignals(this.lrlr, this.clenches);
  final List<DreamSignal> lrlr;
  final List<Gesture> clenches;
}

/// Streams a night through the detectors and finds its LRLR signals and, with the owner's calibrated [clench]
/// settings, its double clenches. Feed every row (µV O1 O2 T3 T4; a held value with [missing] for a lost sample).
class SignalFinder {
  SignalFinder({this.sweepUv = SignalRule.sweepUv, GestureSettings? clench})
    : _gestures = clench == null ? null : Gestures(settings: clench, keepClusters: false) {
    final g = _gestures;
    if (g != null) _det.tap = GestureTap((s) => g.second(s));
  }

  final double sweepUv;
  final Gestures? _gestures;
  final Detectors _det = Detectors();

  void push(List<double> row, {bool missing = false}) {
    _det.push(row, missing: missing);
    // only the eye movements are needed; keep the night's memory flat
    if (_det.blinks.length > 256) _det.blinks.clear();
    if (_det.bursts.length > 256) _det.bursts.clear();
    if (_det.movement.length > 256) _det.movement.clear();
    if (_det.epochs.length > 256) _det.epochs.clear();
  }

  FoundSignals finish() =>
      FoundSignals(lrlrSignals(_det.eyeMoves, sweepUv: sweepUv), List.of(_gestures?.gestures ?? const <Gesture>[]));
}
