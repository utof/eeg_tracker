// The silent minutes at the end of a meditation: the research's no-feedback "transfer" block (DECISIONS 420).
// After the session's length with sound, a cue sounds and the sound fades out for [silentBlockLength] while the
// headband keeps measuring, eyes still closed: can you reach the state without the sound? Its one number is the
// replay check's measure (training/outcome.dart) on these steps: mean log10 alpha on awake, clean steps minus the
// same session's silent eyes-closed calibration minute. Session after session, its trend is the research's best
// sign of learning (an upward trend across sessions in short no-feedback blocks), and against the calibration
// minute it is also the second best (silent rest after the session against before). Beside it, the shares of the
// block held by jaw or neck muscle and spent drowsy: the learning verdict does not count a rise that came with
// more of either. Pure.
import '../detectors/drift_off.dart' show DriftState;
import '../feedback/session.dart';
import '../training/control.dart' show SessionKind;
import '../training/outcome.dart';

/// How long the silent minutes last (planning value: the research's 2-minute transfer block; DECISIONS 420).
const Duration silentBlockLength = Duration(minutes: 2);

/// Seconds of awake, clean signal the block needs for its number: half of it (planning value).
const double silentMinCountedS = 60;

/// One session's silent minutes, as kept in its summary.
class SilentBlock {
  const SilentBlock({
    required this.plannedS,
    required this.seconds,
    required this.countedS,
    required this.alpha,
    required this.muscleShare,
    required this.drowsyShare,
  });

  /// The planned length and the seconds of signal it ran (less when stopped).
  final double plannedS, seconds;

  /// Seconds of awake, clean steps the number stands on.
  final double countedS;

  /// Mean log10 alpha minus the calibration's silent eyes-closed median (0.1 = 26 % more alpha); null when under
  /// [silentMinCountedS] were counted.
  final double? alpha;

  /// Shares of its steps (0..1) held by the muscle gate, and drowsy (the core's gate or the drift-off detector).
  final double muscleShare, drowsyShare;

  Map<String, Object?> toJson() => {
    'plannedS': plannedS,
    'seconds': seconds,
    'countedS': countedS,
    'alpha': alpha,
    'muscleShare': muscleShare,
    'drowsyShare': drowsyShare,
  };

  /// Null when [j] is not a block this version wrote (a damaged block is left out, not trusted).
  static SilentBlock? fromJson(Object? j) {
    if (j is! Map) return null;
    double? num_(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
    double? share(Object? v) => v is num && v.isFinite && v >= 0 && v <= 1 ? v.toDouble() : null;
    final planned = num_(j['plannedS']), seconds = num_(j['seconds']), counted = num_(j['countedS']);
    final muscle = share(j['muscleShare']), drowsy = share(j['drowsyShare']), alpha = j['alpha'];
    if (planned == null || seconds == null || counted == null || muscle == null || drowsy == null) return null;
    if (alpha != null && (alpha is! num || !alpha.isFinite)) return null;
    if (counted > seconds + 0.05) return null;
    return SilentBlock(
      plannedS: planned,
      seconds: seconds,
      countedS: counted,
      alpha: (alpha as num?)?.toDouble(),
      muscleShare: muscle,
      drowsyShare: drowsy,
    );
  }
}

/// Counts the silent block's steps (the core keeps running; nothing is played).
class SilentMeter {
  final OutcomeMeter _alpha = OutcomeMeter(SessionKind.meditation);
  int _steps = 0, _muscle = 0, _drowsy = 0;

  /// Seconds of signal in the block so far.
  double get seconds => _steps * stepS;

  /// One run step after the sound stopped; [baseline]: the session's calibration numbers; [drift]: the drift-off
  /// detector's state (null before its baseline).
  void add(StepResult r, CalBaseline? baseline, {DriftState? drift}) {
    if (r.phase != 'run') return;
    _steps++;
    _alpha.add(r, baseline, drift: drift);
    final good = r.quality == 'good';
    if (good && r.veto == 'muscle') _muscle++;
    if ((good && r.veto == 'drowsy') || drift == DriftState.drowsy || drift == DriftState.asleep) _drowsy++;
  }

  SilentBlock block(double plannedS) {
    double r3(double v) => (v * 1000).round() / 1000;
    final counted = _alpha.countedS, mean = _alpha.mean;
    return SilentBlock(
      plannedS: plannedS,
      seconds: (seconds * 10).round() / 10,
      countedS: (counted * 10).round() / 10,
      alpha: counted >= silentMinCountedS - 1e-9 && mean != null ? (mean * 10000).round() / 10000 : null,
      muscleShare: _steps == 0 ? 0 : r3(_muscle / _steps),
      drowsyShare: _steps == 0 ? 0 : r3(_drowsy / _steps),
    );
  }
}
