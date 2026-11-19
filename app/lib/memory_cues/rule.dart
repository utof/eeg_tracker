// Memory cues: the rule that decides, second by second, whether a soft sound may play now (DECISIONS 502). A
// line-by-line port of analysis/memory_cues.py with the same constants; memory_rule_test.dart runs the hand-worked
// cases both read (test/fixtures/memory_cases.json).
//
// The protocol is targeted memory reactivation (TMR) as a self-test: in the evening each half of the objects on a
// board is learned with its own soft sound; in the night's first hours one of the two sounds plays softly again in
// light or deep NREM sleep (N2/N3). A sound may play only when all of these hold:
// - the cue hours: from 30 minutes to 4.5 hours after Lights off (or the night's first sample);
// - the live sleep model (sleep/live_stager.dart, 2 minutes behind) read the two newest epochs as N2 or N3, each with
//   a top probability of at least 0.6, and that reading is fresh;
// - away from waking: no awake epoch (or lost one, which may hide waking) read in the 5 minutes before the newest;
// - away from stirs: no movement in the last 3 minutes, no jaw muscle in the last 30 s, and the drift-off detector
//   does not say awake;
// - at most one sound every 10 s and 120 a night.
// Each sound plays 3 dB under the loudness just heard in the evening, never louder. The lucid cues' stir rule: awake,
// or 3 seconds of movement, within 30 s after a sound (or an awake epoch read later for those 30 s) is an arousal:
// 3 dB quieter and 5 minutes without sounds; after 3 arousals no more that night. Pure: seconds are counted on the
// signal, not the clock. A cue's step is dB against the evening's loudness (negative); its period the stretch of
// N2/N3 it fell in.
import 'dart:math' as math;

import '../cues/night_cues.dart' show NightRule, RuleCue;
import '../sleep/live_stager.dart' show behindEpochs;

/// Planning values (DECISIONS 502).
abstract final class MemoryRule {
  /// The cue hours, after Lights off (or the night's first sample).
  static const Duration cuesFrom = Duration(minutes: 30), cuesUntil = Duration(minutes: 270);
  static const int behindEpochs = 4, staleEpochs = 3, wakeGuardEpochs = 10;
  static const double minConfidence = 0.6;
  static const int stillS = 180, jawStillS = 30, spacingS = 10, perNight = 120;
  static const int arousalS = 30, arousalMoves = 3, arousalPauseS = 300, arousalDownDb = 3, stopAfterArousals = 3;

  /// Under the evening's "just heard" loudness.
  static const int marginDb = 3;
}

const List<String> _nrem = ['N2', 'N3'];
const int _epochS = 30;

/// The rule, stepped once a second of signal; the live stages are given as they are handed out.
class SoundRule implements NightRule {
  SoundRule({required this.cuesFrom, required this.cuesUntil}) : assert(behindEpochs == MemoryRule.behindEpochs);

  /// The second (on this rule's clock) from which sounds may play, and the one at which the cue hours end.
  int cuesFrom, cuesUntil;

  (int, String, double)? _newest, _prev;
  int? _lastWake, _lastMoved, _lastJaw;
  int _down = MemoryRule.marginDb, _period = 0, _pauseUntil = 0, _movesSinceCue = 0;
  bool _periodOpen = false;
  @override
  final List<RuleCue> cues = [];
  @override
  final List<int> arousals = [];

  /// Why the sounds ended for the night, with the second: 'hours over', 'per night' or 'three arousals'.
  @override
  final List<(int, String)> stops = [];
  @override
  String? done;

  /// The step the next sound would play at (dB against the evening's loudness).
  int get step => -_down;

  /// Lights off moved the cue hours: both ends move together.
  @override
  void startAt(int k) {
    cuesUntil += k - cuesFrom;
    cuesFrom = k;
  }

  @override
  void stage(int epoch, String stage, double conf, int k) {
    if (stage == 'W' || stage == 'gap') _lastWake = _lastWake == null ? epoch : math.max(_lastWake!, epoch);
    if (!_nrem.contains(stage)) _periodOpen = false;
    _prev = _newest;
    _newest = (epoch, stage, conf);
    if (stage == 'W') {
      final lo = epoch * _epochS, hi = (epoch + 1) * _epochS - 1;
      final hit = [
        for (final c in cues)
          if (!c.aroused && c.k <= hi && c.k + MemoryRule.arousalS >= lo) c,
      ];
      if (hit.isNotEmpty) {
        for (final c in hit) {
          c.aroused = true;
        }
        _arousal(k);
      }
    }
  }

  /// Why no sound may play at second [k] (null: it may). [drift]: the drift-off detector's state name, null when it
  /// is not running.
  String? whyNot(int k, String? drift) {
    if (k < cuesFrom) return 'before';
    if (done != null) return 'done';
    if (k < _pauseUntil) return 'pause';
    final n = _newest, p = _prev;
    if (n == null || p == null || p.$1 != n.$1 - 1 || !_nrem.contains(n.$2) || !_nrem.contains(p.$2)) {
      return 'not N2/N3';
    }
    if (math.min(n.$3, p.$3) < MemoryRule.minConfidence) return 'not N2/N3';
    if (n.$1 < k ~/ _epochS - MemoryRule.behindEpochs - MemoryRule.staleEpochs) return 'stale';
    if (_lastWake != null && n.$1 - _lastWake! <= MemoryRule.wakeGuardEpochs) return 'waking';
    if (_lastMoved != null && k - _lastMoved! <= MemoryRule.stillS) return 'moving';
    if (_lastJaw != null && k - _lastJaw! <= MemoryRule.jawStillS) return 'jaw';
    if (drift == 'awake') return 'awake';
    if (cues.isNotEmpty && k - cues.last.k < MemoryRule.spacingS) return 'spacing';
    return null;
  }

  /// [burst] is not used: eye bursts are the lucid cues' sign of dream sleep.
  @override
  RuleCue? second(int k, {required bool moved, required bool jaw, required bool burst, required String? drift}) {
    final last = cues.isEmpty ? null : cues.last;
    if (last != null && k - last.k > 0 && k - last.k <= MemoryRule.arousalS) {
      if (moved) _movesSinceCue++;
      if (!last.aroused && (drift == 'awake' || _movesSinceCue >= MemoryRule.arousalMoves)) {
        last.aroused = true;
        _arousal(k);
      }
    }
    if (moved) _lastMoved = k;
    if (jaw) _lastJaw = k;
    if (k >= cuesUntil && k >= cuesFrom) _stop(k, 'hours over');
    if (whyNot(k, drift) != null) return null;
    if (!_periodOpen) {
      _period++;
      _periodOpen = true;
    }
    final c = RuleCue(k, -_down, _period);
    cues.add(c);
    _movesSinceCue = 0;
    if (cues.length >= MemoryRule.perNight) _stop(k, 'per night');
    return c;
  }

  void _arousal(int k) {
    arousals.add(k);
    _down += MemoryRule.arousalDownDb;
    _pauseUntil = math.max(_pauseUntil, k + MemoryRule.arousalPauseS);
    if (arousals.length >= MemoryRule.stopAfterArousals) _stop(k, 'three arousals');
  }

  void _stop(int k, String why) {
    if (done != null) return;
    done = why;
    stops.add((k, why));
  }
}
