// The dream catcher's round rules (DECISIONS row 111), pure and clock-free: seconds after lights off and the drift-off
// detector's state in, "ask now, and why" out.
//
// Round 1 asks when the detector first says drowsy (alpha under half its eyes-closed baseline for a minute, so
// 30-60 s after it flattened), or at the timer: a random moment inside the usual time to fall asleep
// (dreamFallbackS). A later round asks when alpha has come back (an awake epoch after the last round ended) and
// faded again, at least 2 minutes after the last round ended, or at its own timer: a random moment 4-7 minutes
// after it (Dormio Light's rounds took up to 7 minutes to drift back). No round starts 45 minutes after lights off
// or later. The timers make every round happen even when the detector is wrong: it is not validated yet (row 62).
import '../detectors/drift_off.dart';

abstract final class DreamRule {
  /// Rounds on offer.
  static const List<int> rounds = [3, 4];

  /// No new round starts this long after lights off (s).
  static const int capS = 45 * 60;

  /// A later round waits at least this long after the last round ended (s).
  static const int gapS = 120;

  /// A later round's timer: a random moment this many minutes after the last round ended (planning values).
  static const List<double> againWindowMin = [4, 7];
}

/// Why a round asked: the detector said drowsy, or a timer ran out.
enum DreamCause { drowsy, timer }

class RoundPlan {
  /// [firstTimerS]: round 1's timer, seconds after lights off; [random]: uniforms in 0..1 for the later timers.
  RoundPlan({required this.rounds, required this.firstTimerS, required this._random}) : timerS = firstTimerS.toDouble() {
    if (rounds < 1) throw ArgumentError.value(rounds, 'rounds', 'at least 1');
  }

  final int rounds;
  final int firstTimerS;
  final double Function() _random;

  /// Rounds finished.
  int done = 0;

  /// A round is under way (question, answer, the drifting tap).
  bool inRound = false;

  /// When the last round ended (s after lights off).
  double? lastEnd;

  /// When the next round's timer runs out (s after lights off).
  double timerS;
  bool _awakeSince = false;

  /// Alpha has come back since the last round ended (an awake epoch that started after it).
  bool get awakeSince => _awakeSince;

  /// A finished drift-off epoch: its first second after lights off and the detector's state after it.
  void epoch(int start, DriftState state) {
    final end = lastEnd;
    if (end != null && start >= end && state == DriftState.awake) _awakeSince = true;
  }

  /// Whether a round should start at [t] (s after lights off) with the detector in [state] (null before its
  /// baseline is complete), and why. Null: not now.
  DreamCause? due(double t, DriftState? state) {
    if (inRound || done >= rounds || t >= DreamRule.capS) return null;
    final faded = state == DriftState.drowsy || state == DriftState.asleep;
    final end = lastEnd;
    if (faded && (end == null || (t >= end + DreamRule.gapS && _awakeSince))) return DreamCause.drowsy;
    if (t >= timerS) return DreamCause.timer;
    return null;
  }

  void start() => inRound = true;

  /// The round under way ended at [t]: the next one waits for alpha to come back, and its timer is drawn.
  void finish(double t) {
    inRound = false;
    done++;
    lastEnd = t;
    _awakeSince = false;
    final w = DreamRule.againWindowMin, u = _random();
    if (!(u >= 0 && u <= 1)) throw StateError('random must give 0..1, gave $u');
    timerS = t + (w[0] + (w[1] - w[0]) * u) * 60;
  }

  /// No round can come any more: all are done, or the cap has passed with none under way.
  bool over(double t) => !inRound && (done >= rounds || t >= DreamRule.capS);
}
