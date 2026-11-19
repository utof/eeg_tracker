// Lucid dream cues: the rule that decides, second by second, whether a soft cue may play now (DECISIONS 302-303).
// A line-by-line port of analysis/lucid_cues.py with the same constants; lucid_rule_test.dart runs the hand-worked
// cases both read (test/fixtures/lucid_cases.json) and checks the eye bursts against recorded excerpts.
//
// The protocol is targeted lucidity reactivation (TLR): in the evening a soft cue is paired with "am I dreaming?";
// in dream sleep (REM) the same cue is played softly again. A cue may play only when all of these hold:
// - the night's second half (from 4.5 h after Lights off, or the night's first sample);
// - the live sleep model (sleep/live_stager.dart, 2 minutes behind) read the two newest epochs as dream sleep, each
//   with a top probability of at least 0.6, and that reading is fresh;
// - no deep sleep read in the 10 minutes before the newest epoch;
// - an eye burst ([EyeBursts]) in the last 2 minutes: the eye-movement part of dream sleep, where the lab studies cue;
// - lying still: no movement in the last minute, no jaw muscle in the last 15 s;
// - the drift-off detector does not say awake;
// - at most one cue every 30 s, 10 in a dream-sleep period, 30 a night.
// Each cue is 1 dB louder than the one before, from the evening's level up to +6 dB. Awake, or 3 seconds of movement,
// within 30 s after a cue (or an awake epoch read later for those 30 s) is an arousal: 3 dB quieter and 5 minutes
// without cues; after 3 arousals no more cues that night. Pure: seconds are counted on the signal, not the clock.
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/detectors.dart';
import '../detectors/filters.dart';

/// Planning values (DECISIONS 302).
abstract final class LucidRule {
  /// Cues from this long after Lights off (or the night's first sample).
  static const Duration cuesFrom = Duration(minutes: 270);

  /// The live model and the eye bursts start this long before, so the model has its full hour of window.
  static const Duration modelBefore = Duration(minutes: 60);
  static const int remRun = 2, behindEpochs = 4, staleEpochs = 3, deepGuardEpochs = 20;
  static const double minConfidence = 0.6;
  static const int eyeRecentS = 120, stillS = 60, jawStillS = 15, spacingS = 30;
  static const int perPeriod = 10, perNight = 30, periodEndEpochs = 2;
  static const int arousalS = 30, arousalMoves = 3, arousalPauseS = 300, arousalDown = 3, stopAfterArousals = 3;
  static const int maxSteps = 6;
  static const double stepDb = 1;

  /// Eye bursts: two sideways eye movements at most 2 s apart, the back of the head looked at from 1 s before to
  /// 1 s after each, quiet when its 0.5-15 Hz O1/O2 mean stays within 80 µV peak to peak.
  static const int burstGap = 500, backHalf = 250;
  static const double backQuietUv = 80;
}

/// The cue's amplitude against the evening's level: +1 dB a step, at most +6 dB.
double cueGain(int step) => math.pow(10, step.clamp(0, LucidRule.maxSteps) * LucidRule.stepDb / 20).toDouble();

/// One cue the rule let play: its second, its step (dB over the evening's level) and its dream-sleep period (from 1).
class RuleCue {
  RuleCue(this.k, this.step, this.period);
  final int k, step, period;
  bool aroused = false;
}

/// The rule, stepped once a second of signal; the live stages are given as they are handed out.
class CueRule {
  CueRule({required this.cuesFrom});

  /// The second (on this rule's clock) from which cues may play.
  final int cuesFrom;

  (int, String, double)? _newest, _prev;
  int? _lastN3, _lastBurst, _lastMoved, _lastJaw;
  int _notRRun = 0, _step = 0, _period = 0, _periodCues = 0, _pauseUntil = 0, _movesSinceCue = 0;
  bool _periodOpen = false;
  final List<RuleCue> cues = [];
  final List<int> arousals = [];

  /// Why the cues ended for the night, with the second: 'per night' or 'three arousals'.
  final List<(int, String)> stops = [];
  String? done;

  /// The step the next cue would play at.
  int get step => _step;

  /// Epoch [epoch] read as [stage] (W N1 N2 N3 R or gap) with top probability [conf], known at second [k].
  void stage(int epoch, String stage, double conf, int k) {
    if (stage == 'N3') _lastN3 = _lastN3 == null ? epoch : math.max(_lastN3!, epoch);
    _prev = _newest;
    _newest = (epoch, stage, conf);
    _notRRun = stage == 'R' ? 0 : _notRRun + 1;
    if (_periodOpen && _notRRun >= LucidRule.periodEndEpochs) _periodOpen = false;
    if (stage == 'W') {
      final lo = epoch * epochS, hi = (epoch + 1) * epochS - 1;
      final hit = [
        for (final c in cues)
          if (!c.aroused && c.k <= hi && c.k + LucidRule.arousalS >= lo) c,
      ];
      if (hit.isNotEmpty) {
        for (final c in hit) {
          c.aroused = true;
        }
        _arousal(k);
      }
    }
  }

  /// Why no cue may play at second [k] (null: it may). [drift]: the drift-off detector's state name, null when it
  /// is not running.
  String? whyNot(int k, String? drift) {
    if (k < cuesFrom) return 'before';
    if (done != null) return 'done';
    if (k < _pauseUntil) return 'pause';
    final n = _newest, p = _prev;
    if (n == null || p == null || p.$1 != n.$1 - 1 || n.$2 != 'R' || p.$2 != 'R') return 'no dream sleep';
    if (math.min(n.$3, p.$3) < LucidRule.minConfidence) return 'no dream sleep';
    if (n.$1 < k ~/ epochS - LucidRule.behindEpochs - LucidRule.staleEpochs) return 'stale';
    if (_lastN3 != null && n.$1 - _lastN3! <= LucidRule.deepGuardEpochs) return 'deep sleep';
    if (_lastBurst == null || k - _lastBurst! > LucidRule.eyeRecentS) return 'eyes';
    if (_lastMoved != null && k - _lastMoved! <= LucidRule.stillS) return 'moving';
    if (_lastJaw != null && k - _lastJaw! <= LucidRule.jawStillS) return 'jaw';
    if (drift == 'awake') return 'awake';
    if (_periodOpen && _periodCues >= LucidRule.perPeriod) return 'period full';
    if (cues.isNotEmpty && k - cues.last.k < LucidRule.spacingS) return 'spacing';
    return null;
  }

  /// Second [k]: [moved] movement in it (3+ channels jumping), [jaw] jaw muscle, [burst] an eye burst became known in
  /// it, [drift] the drift-off detector's state. Returns the cue to play now, if any.
  RuleCue? second(int k, {required bool moved, required bool jaw, required bool burst, required String? drift}) {
    if (burst) _lastBurst = k;
    final last = cues.isEmpty ? null : cues.last;
    if (last != null && k - last.k > 0 && k - last.k <= LucidRule.arousalS) {
      if (moved) _movesSinceCue++;
      if (!last.aroused && (drift == 'awake' || _movesSinceCue >= LucidRule.arousalMoves)) {
        last.aroused = true;
        _arousal(k);
      }
    }
    if (moved) _lastMoved = k;
    if (jaw) _lastJaw = k;
    if (whyNot(k, drift) != null) return null;
    if (!_periodOpen) {
      _period++;
      _periodOpen = true;
      _periodCues = 0;
    }
    final c = RuleCue(k, _step, _period);
    cues.add(c);
    _movesSinceCue = 0;
    _periodCues++;
    _step = math.min(_step + 1, LucidRule.maxSteps);
    if (cues.length >= LucidRule.perNight) _stop(k, 'per night');
    return c;
  }

  void _arousal(int k) {
    arousals.add(k);
    _step = math.max(0, _step - LucidRule.arousalDown);
    _pauseUntil = math.max(_pauseUntil, k + LucidRule.arousalPauseS);
    if (arousals.length >= LucidRule.stopAfterArousals) _stop(k, 'three arousals');
  }

  void _stop(int k, String why) {
    if (done != null) return;
    done = why;
    stops.add((k, why));
  }
}

/// Eye bursts as the cue rule wants them (analysis/lucid_cues.py `quiet_back`, `burst_seconds`): the detectors' sideways
/// eye movements (given through the [DetectorTap]) with the back of the head quiet around them, two at most 2 s apart.
/// Feed every row right after the detectors; [push] returns the second in which a burst became known.
class EyeBursts implements DetectorTap {
  static const int _ring = 512;
  final Chain _back = Chain(detectorChains()['blink']!);
  final Float64List _b = Float64List(_ring);
  final List<int> _pending = [];
  int _n = 0;
  int? _lastQuiet;

  /// Samples of the eye movements that had the back of the head quiet (kept for the cross-check; cleared by
  /// [trim]).
  final List<int> quiet = [];

  @override
  void eyeMove(EyeMove e) => _pending.add(e.i);

  @override
  void muscle(double t3, double t4, bool missing) {}

  @override
  void secondEnd(Second s) {}

  /// One row (µV O1 O2 T3 T4, a held value for a lost sample), after the detectors had it.
  int? push(List<double> row) {
    _b[_n & (_ring - 1)] = _back.step((row[0] + row[1]) / 2);
    final last = _n;
    _n++;
    int? burst;
    while (_pending.isNotEmpty && _pending.first + LucidRule.backHalf <= last) {
      final i = _pending.removeAt(0);
      if (i - LucidRule.backHalf < 0) continue;
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var j = i - LucidRule.backHalf; j <= i + LucidRule.backHalf; j++) {
        final v = _b[j & (_ring - 1)];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      if (hi - lo >= LucidRule.backQuietUv) continue;
      quiet.add(i);
      final q = _lastQuiet;
      if (q != null && i - q <= LucidRule.burstGap) burst = (i + LucidRule.backHalf) ~/ fsSamples;
      _lastQuiet = i;
    }
    return burst;
  }

  /// Keeps the night's memory flat (the live watch does not need the list).
  void trim() => quiet.clear();
}

/// Samples a second (the detectors' rate).
const int fsSamples = 250;
