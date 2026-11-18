// The nap coach's rules (DECISIONS rows 173-175), pure and clock-free: the live stages and seconds after lights off
// in, "wake now, and why" out.
//
// A nap ends at the first of: deep sleep starting (two epochs in a row that the live scorer, reading 2 minutes
// behind, calls N3: about 3 minutes into deep sleep, before it settles), or the length you picked, counted from
// Lights off. Waking out of deep sleep is what makes you groggy; the length is the safety net that always works,
// with or without the sleep model. The wake sound is a soft rising cue, repeated a little louder every 20 seconds
// until you tap "I'm awake" (5 minutes at most).
import 'dart:math' as math;

import '../sleep/live_stager.dart' show LiveStage;

abstract final class NapRule {
  /// Lengths on offer (minutes from Lights off) and the one picked first.
  static const List<int> lengthsMin = [20, 30, 45, 90];
  static const int defaultMin = 30;

  /// Deep sleep counts after this many epochs in a row, each read 2 minutes behind (DECISIONS row 79).
  static const int deepRun = 2;

  /// The wake cue repeats this often, and gives up after [wakeForS] without a tap.
  static const int wakeEveryS = 20;
  static const int wakeForS = 5 * 60;

  /// The wake cue's loudness, step by step, as multiples of the first (the dream catcher's quiet cue); then the
  /// last one stays. 1.5x a step is about +3.5 dB; the fifth is +14 dB.
  static const List<double> wakeSteps = [1, 1.5, 2.25, 3.4, 5];
}

/// Why a nap ended.
enum NapEnd {
  /// The sleep model saw deep sleep starting.
  deepSleep,

  /// The length you picked was up.
  length,

  /// You pressed Stop.
  stopped,
}

class NapRules {
  NapRules({required this.lengthS}) {
    if (lengthS <= 0) throw ArgumentError.value(lengthS, 'lengthS', 'must be positive');
  }

  final int lengthS;

  /// The epoch that completed the deep-sleep run (counted from Lights off), once seen.
  int? deepEpoch;
  int _run = 0;
  int _last = -1;

  /// Feeds the next live stage (epoch order). True when this one starts the wake.
  bool stage(LiveStage s) {
    if (deepEpoch != null) return false;
    _run = s.stage == 'N3' && s.epoch == _last + 1 ? _run + 1 : (s.stage == 'N3' ? 1 : 0);
    _last = s.epoch;
    if (_run >= NapRule.deepRun) {
      deepEpoch = s.epoch;
      return true;
    }
    return false;
  }

  /// Wake now? [tS]: seconds after lights off.
  NapEnd? due(double tS) => deepEpoch != null ? NapEnd.deepSleep : (tS >= lengthS ? NapEnd.length : null);
}

/// The wake cue's volume at step [k] (0, 1, ...) for a first volume [first]: never over 1.
double wakeVolume(int k, double first) => math.min(1.0, first * NapRule.wakeSteps[math.min(k, NapRule.wakeSteps.length - 1)]);
