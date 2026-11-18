// The replay check's primary measure, one number per session (DECISIONS row 102), on awake, clean steps only
// (good signal, no muscle or blink gate, not "probably asleep" by the drift-off detector; for meditation also
// not the core's drowsy gate):
//   meditation:  alpha during the sound against the same session's silent eyes-closed minute,
//                mean log10 alpha - the calibration's median log10 alpha (0.1 = 26 % more alpha)
//   alpha-theta: the change in log10(theta / alpha) against the same silent minute
// Alpha drifts up with time on task whatever the sound does, so only live minus replay means anything.
import '../detectors/drift_off.dart' show DriftState;
import '../feedback/session.dart';
import 'control.dart';

/// A session is left out of the primary test (but still reported) when more than this share of its run was
/// not counted (asleep, gated, no signal): a rule fixed in the plan before any reveal.
const double excludeAbove = 0.3;

/// Seconds of counted steps a session needs for an outcome at all.
const double minCountedS = 30;

class OutcomeMeter {
  OutcomeMeter(this.kind);
  final SessionKind kind;
  int _steps = 0;
  int _counted = 0;
  double _sum = 0;

  /// One run step, with the drift-off detector's state; [baseline]: the session's calibration numbers.
  void add(StepResult r, CalBaseline? baseline, {DriftState? drift}) {
    if (r.phase != 'run') return;
    _steps++;
    if (baseline == null || r.quality != 'good' || drift == DriftState.asleep) return;
    final a = r.alphaLog, t = r.thetaLog;
    if (a == null || t == null) return;
    if (r.veto == 'muscle' || r.veto == 'blink') return;
    if (kind == SessionKind.meditation && r.veto != null) return;
    _counted++;
    _sum += kind == SessionKind.meditation ? a - baseline.alpha : (t - a) - baseline.ratio;
  }

  /// Null when under [minCountedS] were counted.
  double? get value => _counted * stepS >= minCountedS ? _sum / _counted : null;

  /// Share of the run not counted, 0..1.
  double get excludedShare => _steps == 0 ? 1 : 1 - _counted / _steps;
}
