// The work session's drowsiness level (ROADMAP row 35, DECISIONS 440-442). While you work with eyes open, heavy eyelids
// show in two ways these electrodes can see: more alpha (8-12 Hz) at the back of the head (O1/O2), and still eyes:
// fewer blinks and sideways eye movements (T3-T4). Both are read against your own first minutes of work.
// Theta (4-7 Hz) and slow eye power (T3-T4 at 0.2-0.7 Hz) are kept in the file but not used: against the forehead
// reference both follow eye activity, and on the owner's recordings both FELL as he got drowsy (docs/evidence/
// work-session.md, tool/work_check.dart).
//
// Pure and second-driven: feed one [WorkInput] a second (from the shared detectors' [Second], handed out one second
// late with its blinks known). Every 30 s epoch:
//   - clean seconds: a back channel usable, no movement, no muscle (jaw, talking, chewing), no blink, no hole; under
//     10 of them and the epoch is not scored ("noisy"); alpha is the median over them;
//   - eye events: blinks and sideways eye movements per 30 seconds without a hole or movement (at least 20 of them);
//   - eyes closed: alpha 3 times the baseline (or half your eyes-closed minute's alpha) with no blink and at most one
//     sideways eye movement in 30 s; not scored (closed eyes raise alpha without drowsiness), shown as "eyes closed";
//   - after 1 minute of settling in, the next 6 scored epochs (3 minutes) are the baseline (medians); after it each
//     epoch's index is the mean of a = log2(alpha / baseline) and still = log2((baseline events + 1) / (events + 1)),
//     each clipped to -2..3; with alpha under its baseline the index stays at 0.25 at most (still eyes alone may be
//     focus);
//   - the level is the median index of the scored epochs among the last 10 (5 minutes; at least 6 needed, else
//     "not sure"): under 0.5 alert, 0.5 getting drowsy, 1.0 drowsy, with 0.1 of hysteresis on the way down.
// Planning values (docs/evidence/work-session.md).
import 'dart:math' as math;

import '../detectors/detectors.dart' show Second, backChannels, sideChannels, epochS;
import '../feedback/features.dart' show median;

abstract final class WorkRule {
  static const int settleEpochs = 2, baselineEpochs = 6, minCleanS = 10, windowEpochs = 10, minScored = 6;

  /// Eye events (blinks and sideways movements) are counted per 30 usable seconds; at least this many needed.
  static const int minEyeS = 20;

  /// Still eyes alone never raise the index above this: without alpha up they may be focus, not drowsiness.
  static const double stillAloneCap = 0.25;
  static const double gettingDrowsy = 0.5, drowsy = 1.0, hysteresis = 0.1;
  static const double clipLo = -2, clipHi = 3;

  /// Eyes closed: alpha this many times the eyes-open baseline, or this share of the eyes-closed minute's alpha.
  static const double closedX = 3, closedOfCal = 0.5;
  static const int closedMaxBlinks = 0, closedMaxEyeMoves = 1;

  /// "Eyes closed" on screen when this many of the last 10 epochs were.
  static const int closedEpochs = 4;
}

enum DrowsyLevel { unknown, alert, gettingDrowsy, drowsy }

/// The words on the screen and in the files.
const Map<DrowsyLevel, String> levelWords = {
  DrowsyLevel.unknown: 'Not sure',
  DrowsyLevel.alert: 'Alert',
  DrowsyLevel.gettingDrowsy: 'Getting drowsy',
  DrowsyLevel.drowsy: 'Drowsy',
};

String levelKey(DrowsyLevel l) => switch (l) {
  DrowsyLevel.unknown => 'unknown',
  DrowsyLevel.alert => 'alert',
  DrowsyLevel.gettingDrowsy => 'getting_drowsy',
  DrowsyLevel.drowsy => 'drowsy',
};

DrowsyLevel levelOf(String? key) => DrowsyLevel.values.firstWhere((l) => levelKey(l) == key, orElse: () => DrowsyLevel.unknown);

/// One second of what the drowsiness level reads.
class WorkInput {
  const WorkInput({
    required this.alpha,
    required this.theta,
    required this.sem,
    required this.backClean,
    required this.sideClean,
    this.blinks = 0,
    this.eyeMoves = 0,
    this.muscle = false,
    this.movement = false,
    this.gap = false,
  });

  /// µV², the mean of the usable back channels (O1, O2).
  final double alpha, theta;

  /// µV², T3-T4 at 0.2-0.7 Hz.
  final double sem;

  /// At least one back channel usable / both side channels usable.
  final bool backClean, sideClean;
  final int blinks, eyeMoves;
  final bool muscle, movement, gap;
}

/// One detector second as the drowsiness level's input; [eyeMoves]: the sideways eye movements found in it.
WorkInput workInputOf(Second s, {int eyeMoves = 0}) {
  var n = 0;
  var a = 0.0, t = 0.0;
  for (var b = 0; b < backChannels.length; b++) {
    if (!s.backClean(b)) continue;
    n++;
    a += s.alpha[b];
    t += s.theta[b];
  }
  bool sideOk(int c) => !(s.flat[c] || s.railed[c] || s.extreme(c));
  return WorkInput(
    alpha: n > 0 ? a / n : 0,
    theta: n > 0 ? t / n : 0,
    sem: s.sem,
    backClean: n > 0,
    sideClean: !s.gap && sideChannels.every(sideOk),
    blinks: s.blinks,
    eyeMoves: eyeMoves,
    muscle: s.muscleOn,
    movement: s.movement,
    gap: s.gap,
  );
}

class WorkBaseline {
  const WorkBaseline(this.alpha, this.events, this.theta, this.sem);

  /// µV² (back channels, 8-12 Hz), and blinks plus sideways eye movements per 30 s (null: never countable).
  final double alpha;
  final double? events;

  /// Logged only (µV²): 4-7 Hz at the back, T3-T4 at 0.2-0.7 Hz (null when the side channels were never clean).
  final double theta;
  final double? sem;

  Map<String, Object?> toJson() => {
    'alpha': _r(alpha),
    'events': events == null ? null : _r(events!),
    'theta': _r(theta),
    'sem': sem == null ? null : _r(sem!),
  };

  static WorkBaseline? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['alpha'], th = j['theta'];
    if (a is! num || th is! num) return null;
    final ev = j['events'], sem = j['sem'];
    return WorkBaseline(a.toDouble(), ev is num ? ev.toDouble() : null, th.toDouble(), sem is num ? sem.toDouble() : null);
  }
}

class WorkEpoch {
  WorkEpoch({
    required this.n,
    required this.startS,
    required this.cleanS,
    required this.muscleS,
    required this.movementS,
    required this.gapS,
    required this.blinks,
    required this.eyeMoves,
    this.alpha,
    this.theta,
    this.sem,
    this.events,
    this.eyesClosed = false,
  });

  /// Epoch number and its first second, counted from the session's first second of signal.
  final int n, startS;
  final int cleanS, muscleS, movementS, gapS, blinks, eyeMoves;

  /// Medians over the clean seconds (null: under 10 clean seconds).
  final double? alpha, theta, sem;

  /// Blinks and sideways eye movements per 30 usable seconds (null: under 20 usable seconds).
  final double? events;
  final bool eyesClosed;

  /// log2 against the baseline, after it exists (null otherwise, or when not scored): alpha, still eyes, and the
  /// logged-only theta and slow eye power.
  double? a, still, t, s, index;

  /// The level's median at this epoch, and the level after it.
  double? window;
  DrowsyLevel level = DrowsyLevel.unknown;

  bool get scored => index != null;

  Map<String, Object?> toJson() => {
    's': startS,
    'clean_s': cleanS,
    'muscle_s': muscleS,
    'movement_s': movementS,
    'gap_s': gapS,
    'blinks': blinks,
    'eye_moves': eyeMoves,
    'alpha': alpha == null ? null : _r(alpha!),
    'theta': theta == null ? null : _r(theta!),
    'sem': sem == null ? null : _r(sem!),
    'events': events == null ? null : _r(events!),
    'eyes_closed': eyesClosed,
    'a': a == null ? null : _r(a!),
    'still': still == null ? null : _r(still!),
    't': t == null ? null : _r(t!),
    's_eye': s == null ? null : _r(s!),
    'index': index == null ? null : _r(index!),
    'window': window == null ? null : _r(window!),
    'level': levelKey(level),
  };
}

double _r(double v) => (v * 1000).roundToDouble() / 1000;

double _clip(double v) => math.min(WorkRule.clipHi, math.max(WorkRule.clipLo, v));

double _log2(double v) => math.log(v) / math.ln2;

class WorkDrowsiness {
  /// [closedAlpha]: the back channels' alpha of the optional eyes-closed minute (µV², the median of its clean
  /// seconds); null when it was skipped.
  WorkDrowsiness({this.closedAlpha, this.onEpoch});

  final double? closedAlpha;
  final void Function(WorkEpoch e)? onEpoch;

  final List<WorkEpoch> epochs = [];
  WorkBaseline? baseline;

  /// The second the baseline was complete (seconds fed).
  int? calibratedAtS;
  DrowsyLevel level = DrowsyLevel.unknown;

  /// The median index of the last 5 minutes (null: not enough clean signal, or before the baseline).
  double? window;

  /// Seconds fed.
  int seconds = 0;
  final List<WorkInput> _ep = [];
  final List<WorkEpoch> _base = [];

  bool get calibrated => baseline != null;

  /// Calibrating: the scored epochs still needed for the baseline.
  int get baselineLeft => calibrated ? 0 : WorkRule.baselineEpochs - _base.length;

  /// Over half of the last 5 minutes were too noisy to read (after the baseline).
  bool get noisy => calibrated && epochs.length >= WorkRule.windowEpochs && window == null && !eyesClosed;

  /// At least 2 of the last 5 minutes with eyes closed.
  bool get eyesClosed {
    final last = epochs.length <= WorkRule.windowEpochs ? epochs : epochs.sublist(epochs.length - WorkRule.windowEpochs);
    return last.where((e) => e.eyesClosed).length >= WorkRule.closedEpochs;
  }

  void second(WorkInput x) {
    seconds++;
    _ep.add(x);
    if (_ep.length == epochS) {
      _endEpoch();
      _ep.clear();
    }
  }

  void _endEpoch() {
    final back = <WorkInput>[], side = <double>[];
    var muscle = 0, moved = 0, gaps = 0, blinks = 0, moves = 0, eyeS = 0, eyeEvents = 0;
    for (final x in _ep) {
      if (x.muscle) muscle++;
      if (x.movement) moved++;
      if (x.gap) gaps++;
      blinks += x.blinks;
      moves += x.eyeMoves;
      if (!x.gap && !x.movement) {
        eyeS++;
        eyeEvents += x.blinks + x.eyeMoves;
      }
      final quiet = !x.movement && !x.muscle && !x.gap;
      if (quiet && x.backClean && x.blinks == 0) back.add(x);
      if (quiet && x.sideClean) side.add(x.sem);
    }
    final enough = back.length >= WorkRule.minCleanS;
    final alpha = enough ? median([for (final x in back) x.alpha]) : null;
    final e = WorkEpoch(
      n: epochs.length,
      startS: seconds - epochS,
      cleanS: back.length,
      muscleS: muscle,
      movementS: moved,
      gapS: gaps,
      blinks: blinks,
      eyeMoves: moves,
      alpha: alpha,
      theta: enough ? median([for (final x in back) x.theta]) : null,
      sem: side.length >= WorkRule.minCleanS ? median(side) : null,
      events: eyeS >= WorkRule.minEyeS ? eyeEvents * epochS / eyeS : null,
      eyesClosed: alpha != null && blinks <= WorkRule.closedMaxBlinks && moves <= WorkRule.closedMaxEyeMoves && alpha >= _closedLine(),
    );
    epochs.add(e);
    final b = baseline;
    if (b == null) {
      if (epochs.length > WorkRule.settleEpochs && alpha != null && !e.eyesClosed) _base.add(e);
      if (_base.length == WorkRule.baselineEpochs) _setBaseline();
    } else {
      _score(e, b);
    }
    if (calibrated) _level();
    e
      ..window = window
      ..level = level;
    onEpoch?.call(e);
  }

  void _setBaseline() {
    List<double> of(double? Function(WorkEpoch e) f) => [
      for (final x in _base)
        if (f(x) != null) f(x)!,
    ];
    final ev = of((e) => e.events), sems = of((e) => e.sem);
    final half = WorkRule.baselineEpochs ~/ 2;
    baseline = WorkBaseline(
      median(of((e) => e.alpha)),
      ev.length >= half ? median(ev) : null,
      median(of((e) => e.theta)),
      sems.length >= half ? median(sems) : null,
    );
    calibratedAtS = seconds;
  }

  /// The index of an epoch after the baseline; theta and slow eye power only logged.
  static void _score(WorkEpoch e, WorkBaseline b) {
    final alpha = e.alpha;
    if (alpha == null || e.eyesClosed || !(alpha > 0) || !(b.alpha > 0)) return;
    double? ratio(double? x, double? base) => x != null && base != null && x > 0 && base > 0 ? _clip(_log2(x / base)) : null;
    e.a = _clip(_log2(alpha / b.alpha));
    e.t = ratio(e.theta, b.theta);
    e.s = ratio(e.sem, b.sem);
    final ev = e.events, bev = b.events;
    if (ev != null && bev != null) e.still = _clip(_log2((bev + 1) / (ev + 1)));
    final a = e.a!, still = e.still;
    var index = still == null ? a : (a + still) / 2;
    if (a < 0) index = math.min(index, WorkRule.stillAloneCap);
    e.index = index;
  }

  double _closedLine() {
    final cal = closedAlpha, b = baseline;
    final lines = [
      if (cal != null && cal > 0) WorkRule.closedOfCal * cal,
      if (b != null) WorkRule.closedX * b.alpha,
    ];
    if (lines.isEmpty) return double.infinity; // nothing to compare with yet
    return lines.reduce(math.max);
  }

  void _level() {
    final from = math.max(0, epochs.length - WorkRule.windowEpochs);
    final scored = [
      for (var i = from; i < epochs.length; i++)
        if (epochs[i].index != null) epochs[i].index!,
    ];
    if (scored.length < WorkRule.minScored) {
      window = null;
      level = DrowsyLevel.unknown;
      return;
    }
    final w = median(scored);
    window = w;
    level = _withHysteresis(w, level);
  }
}

/// The level for median [w], given the level before (it steps down only 0.1 below a line).
DrowsyLevel _withHysteresis(double w, DrowsyLevel before) {
  final up = w >= WorkRule.drowsy
      ? DrowsyLevel.drowsy
      : w >= WorkRule.gettingDrowsy
      ? DrowsyLevel.gettingDrowsy
      : DrowsyLevel.alert;
  if (up.index >= before.index || before == DrowsyLevel.unknown) return up;
  // going down: stay unless clearly under the line of the level held
  final line = before == DrowsyLevel.drowsy ? WorkRule.drowsy : WorkRule.gettingDrowsy;
  return w > line - WorkRule.hysteresis ? before : up;
}
