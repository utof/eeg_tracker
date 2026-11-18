// What a meditation session shows and keeps (pure; DECISIONS row 74). Reads the feedback core's steps and
// gives the live state chip and, at the end, a small summary that is saved as JSON and compared with earlier
// sessions. Words follow docs/evidence/meditation-feedback.md:
//   settled  : eyes-closed alpha above your line, with no muscle, blink or drowsiness flag
//   settling : no flag, alpha under the line
//   restless : jaw or neck muscle, blinks or eye movement, or the electrodes moving
//   drifting : the core's drift-to-sleep gate, or the shared drift-off detector (app/lib/detectors) saying
//              drowsy or probably asleep (the core's gate cannot tell eyes open from dozing)
// No "depth" or score: there is no reliable meditation-depth signal at these electrodes.
import 'dart:math' as math;

import '../detectors/drift_off.dart' show DriftState;
import '../feedback/mapping.dart' show jawBlock;
import '../feedback/session.dart';
import '../training/control.dart' show SessionKind;

enum Moment { calibrating, settled, settling, restless, drifting, noSignal }

enum Restless { jaw, blinks, movement }

/// One moment per analysis step of the run phase. Null outside it. [drift]: the drift-off detector's state
/// (null before its baseline); drowsy or asleep makes an otherwise calm step a drifting one. [coreDrowsy]:
/// false in alpha-theta, where theta rising is the aim, so only the drift-off detector says drifting.
({Moment moment, Restless? why})? momentOf(StepResult r, {DriftState? drift, bool coreDrowsy = true}) {
  if (r.phase != 'run') return null;
  if (r.quality == 'poor') {
    return r.channels['O1'] == 'noisy' || r.channels['O2'] == 'noisy'
        ? (moment: Moment.restless, why: Restless.movement)
        : (moment: Moment.noSignal, why: null);
  }
  if (r.quality != 'good') return (moment: Moment.settling, why: null);
  switch (r.veto) {
    case 'muscle':
      return (moment: Moment.restless, why: (r.jaw ?? 0) > jawBlock ? Restless.jaw : Restless.movement);
    case 'blink':
      return (moment: Moment.restless, why: Restless.blinks);
    case 'drowsy' when coreDrowsy:
      return (moment: Moment.drifting, why: null);
  }
  if (drift == DriftState.drowsy || drift == DriftState.asleep) return (moment: Moment.drifting, why: null);
  return (moment: (r.z ?? 0) > 0 ? Moment.settled : Moment.settling, why: null);
}

/// The kinds of marks a session keeps.
const Set<String> markKinds = {'jaw', 'blinks', 'movement', 'drifting'};

/// Restless steps closer than this belong to one restless moment (a clench held, blinks in a row).
const double restlessJoinS = 2;

/// Drowsy steps closer than this belong to one drifting moment.
const double driftJoinS = 5;

/// Width of one sparkline point.
const double calmBinS = 30;

class MeditationTracker {
  MeditationTracker(this.length);

  /// Seconds of signal the session runs for after calibration.
  final Duration length;

  int _steps = 0;
  int _settled = 0;
  int _settledRun = 0;
  int _longestSettled = 0;
  int _drowsy = 0;
  final Map<Restless, int> restless = {for (final k in Restless.values) k: 0};
  int drifting = 0;
  int _sinceRestless = 1 << 30;
  int _sinceDrowsy = 1 << 30;
  int bells = 0;

  /// Seconds into the session when the drift-off detector first said "probably asleep" (null: it did not).
  double? asleepS;

  /// Each restless or drifting moment: seconds into the session and its kind ('jaw', 'blinks', 'movement',
  /// 'drifting'), for the marks on the report's track.
  final List<(double, String)> marks = [];
  final List<double> _calm = [];
  double _binSum = 0;
  int _binN = 0;
  final List<Moment> _recent = [];

  /// Seconds of signal since calibration ended.
  double get runSeconds => _steps * stepS;
  bool get done => runSeconds >= length.inMilliseconds / 1000 - 1e-9;
  double get settledSeconds => _settled * stepS;
  double get longestSettledSeconds => _longestSettled * stepS;
  double get drowsySeconds => _drowsy * stepS;
  int get restlessTotal => restless.values.fold(0, (a, b) => a + b);

  /// Mean calm (the sound: 0 = brightest rain, 1 = calmest) per 30 s, the last bin as far as it got.
  List<double> get calm => [..._calm, if (_binN > 0) _binSum / _binN];

  /// [level]: the bed setting played (default the core's calm; a replay or alpha-theta passes its own);
  /// [reward]: whether a reward sounded (default the core's bell).
  void add(StepResult r, {DriftState? drift, double? level, bool? reward, bool coreDrowsy = true}) {
    final m = momentOf(r, drift: drift, coreDrowsy: coreDrowsy);
    if (m == null) return;
    _steps++;
    if (drift == DriftState.asleep) asleepS ??= runSeconds;
    if (reward ?? r.ring) bells++;
    _recent.add(m.moment);
    if (_recent.length > 20) _recent.removeAt(0);

    if (m.moment == Moment.settled) {
      _settled++;
      _settledRun++;
      _longestSettled = math.max(_longestSettled, _settledRun);
    } else {
      _settledRun = 0;
    }

    if (m.moment == Moment.restless) {
      if (_sinceRestless * stepS >= restlessJoinS) {
        restless[m.why!] = restless[m.why!]! + 1;
        marks.add((runSeconds, m.why!.name));
      }
      _sinceRestless = 0;
    } else {
      _sinceRestless++;
    }
    if (m.moment == Moment.drifting) {
      _drowsy++;
      if (_sinceDrowsy * stepS >= driftJoinS) {
        drifting++;
        marks.add((runSeconds, 'drifting'));
      }
      _sinceDrowsy = 0;
    } else {
      _sinceDrowsy++;
    }

    _binSum += level ?? r.targets.calm;
    _binN++;
    if (_binN * stepS >= calmBinS - 1e-9) {
      _calm.add(_binSum / _binN);
      _binSum = 0;
      _binN = 0;
    }
  }

  /// The chip: restless if any step of the last second was; otherwise the commonest moment of the last 2 s.
  Moment get chip {
    if (_recent.isEmpty) return Moment.settling;
    final lastSecond = _recent.sublist(math.max(0, _recent.length - 10));
    if (lastSecond.contains(Moment.restless)) return Moment.restless;
    final counts = <Moment, int>{};
    for (final m in _recent) {
      counts[m] = (counts[m] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  MeditationSummary summary({
    required DateTime start,
    required bool complete,
    required double? iafHz,
    required String note,
    required String logFile,
    SessionKind kind = SessionKind.meditation,
    Map<String, Object?>? check,
    double? outcome,
    double? excludedShare,
    Map<String, Object?>? at,
  }) => MeditationSummary(
    kind: kind,
    check: check,
    outcome: outcome,
    excludedShare: excludedShare,
    at: at,
    start: start,
    lengthMin: length.inSeconds / 60,
    runS: _round1(runSeconds),
    complete: complete,
    settledS: _round1(settledSeconds),
    longestSettledS: _round1(longestSettledSeconds),
    bells: bells,
    restless: {for (final e in restless.entries) e.key: e.value},
    drifting: drifting,
    drowsyS: _round1(drowsySeconds),
    asleepS: asleepS == null ? null : _round1(asleepS!),
    calm: [for (final c in calm) (c * 1000).round() / 1000],
    marks: [for (final (t, k) in marks) (_round1(t), k)],
    iafHz: iafHz,
    note: note,
    logFile: logFile,
  );
}

double _round1(double v) => (v * 10).round() / 10;

/// One finished session, as kept next to the recordings (`<stamp>.meditation.json`; an alpha-theta session the
/// same in its own folder as `<stamp>.alphatheta.json`).
class MeditationSummary {
  const MeditationSummary({
    this.kind = SessionKind.meditation,
    this.check,
    this.outcome,
    this.excludedShare,
    this.at,
    required this.start,
    required this.lengthMin,
    required this.runS,
    required this.complete,
    required this.settledS,
    required this.longestSettledS,
    required this.bells,
    required this.restless,
    required this.drifting,
    required this.drowsyS,
    this.asleepS,
    required this.calm,
    this.marks = const [],
    required this.iafHz,
    required this.note,
    required this.logFile,
  });

  static const int version = 1;
  final SessionKind kind;

  /// While the replay check was on: {'phase': 'donor' | 'randomised' | 'finished', 'index': n}. Never the arm.
  final Map<String, Object?>? check;

  /// The replay check's primary measure (training/outcome.dart) and the share of the run it could not count.
  final double? outcome;
  final double? excludedShare;

  /// Alpha-theta: seconds of alpha and theta above their lines, crossover, asleep, counted; chimes, gongs.
  final Map<String, Object?>? at;
  final DateTime start;

  /// The length chosen, in minutes.
  final double lengthMin;

  /// Seconds of signal after calibration (less than the length when stopped early).
  final double runS;
  final bool complete;
  final double settledS;
  final double longestSettledS;
  final int bells;
  final Map<Restless, int> restless;
  final int drifting;
  final double drowsyS;

  /// Seconds into the session when the drift-off detector said "probably asleep" (3 min of faded alpha), or
  /// null. Kept for later features (dream catcher, sound auto-stop); the screen shows it as drifting time.
  final double? asleepS;

  /// Mean calm per 30 s, 0..1.
  final List<double> calm;

  /// Restless and drifting moments: seconds into the session, kind ('jaw', 'blinks', 'movement', 'drifting').
  final List<(double, String)> marks;
  final double? iafHz;
  final String note;

  /// The replayable session log next to this file (same format as the laptop page's).
  final String logFile;

  /// Share of the session spent settled, 0..1 (sessions of different lengths compare by this).
  double get settledShare => runS > 0 ? settledS / runS : 0;
  int get restlessTotal => restless.values.fold(0, (a, b) => a + b);

  Map<String, Object?> toJson() => {
    'version': version,
    'kind': kind.name,
    if (check != null) 'check': check,
    if (outcome != null) 'outcome': outcome,
    if (excludedShare != null) 'excludedShare': excludedShare,
    if (at != null) 'at': at,
    'start': start.toIso8601String(),
    'lengthMin': lengthMin,
    'runS': runS,
    'complete': complete,
    'settledS': settledS,
    'longestSettledS': longestSettledS,
    'bells': bells,
    'restless': {for (final e in restless.entries) e.key.name: e.value},
    'drifting': drifting,
    'drowsyS': drowsyS,
    if (asleepS != null) 'asleepS': asleepS,
    'calm': calm,
    'calmBinS': calmBinS,
    'marks': [for (final (t, k) in marks) [t, k]],
    'iafHz': iafHz,
    'note': note,
    'log': logFile,
  };

  /// Null when [j] is not a summary this version can read (a damaged or foreign file is skipped, not trusted).
  static MeditationSummary? fromJson(Object? j) {
    if (j is! Map || j['version'] != version) return null;
    final kind = SessionKind.byName(j['kind']);
    if (kind == null) return null;
    final start = DateTime.tryParse('${j['start']}');
    final r = j['restless'], calm = j['calm'];
    double? num_(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
    final lengthMin = num_(j['lengthMin']), runS = num_(j['runS']), settledS = num_(j['settledS']);
    final longest = num_(j['longestSettledS']), drowsyS = num_(j['drowsyS']);
    final bells = j['bells'], drifting = j['drifting'], complete = j['complete'];
    if (start == null || lengthMin == null || runS == null || settledS == null || longest == null) return null;
    if (drowsyS == null || bells is! int || bells < 0 || drifting is! int || drifting < 0 || complete is! bool) {
      return null;
    }
    if (r is! Map || calm is! List || settledS > runS + 0.05) return null;
    final restless = <Restless, int>{};
    for (final k in Restless.values) {
      final v = r[k.name];
      if (v is! int || v < 0) return null;
      restless[k] = v;
    }
    final calmV = <double>[];
    for (final c in calm) {
      if (c is! num || !c.isFinite || c < 0 || c > 1) return null;
      calmV.add(c.toDouble());
    }
    final marks = <(double, String)>[];
    final m = j['marks'];
    if (m is List) {
      for (final e in m) {
        if (e is List && e.length == 2 && e[0] is num && e[1] is String && markKinds.contains(e[1])) {
          marks.add(((e[0] as num).toDouble(), e[1] as String));
        }
      }
    }
    final iaf = j['iafHz'], asleep = num_(j['asleepS']), outcome = j['outcome'], check = j['check'], at = j['at'];
    return MeditationSummary(
      kind: kind,
      check: check is Map<String, Object?> ? check : null,
      outcome: outcome is num && outcome.isFinite ? outcome.toDouble() : null,
      excludedShare: num_(j['excludedShare']),
      at: at is Map<String, Object?> ? at : null,
      start: start,
      lengthMin: lengthMin,
      runS: runS,
      complete: complete,
      settledS: settledS,
      longestSettledS: longest,
      bells: bells,
      restless: restless,
      drifting: drifting,
      drowsyS: drowsyS,
      asleepS: asleep != null && asleep <= runS + 0.05 ? asleep : null,
      calm: calmV,
      marks: marks,
      iafHz: iaf is num && iaf.isFinite ? iaf.toDouble() : null,
      note: j['note'] is String ? j['note'] as String : '',
      logFile: j['log'] is String ? j['log'] as String : '',
    );
  }
}

/// This session against the earlier ones: the share of settled time against the range of the last 14 (as the
/// morning check-in does, DECISIONS row 26). No verdict about learning before 8 sessions (evidence note).
({String line, double? low, double? high, int earlier}) compareWithEarlier(
  MeditationSummary now,
  List<MeditationSummary> earlier,
) {
  final last = [
    for (final s in earlier)
      if (s.runS >= 60 && s.start.isBefore(now.start)) s,
  ]..sort((a, b) => b.start.compareTo(a.start));
  final use = last.take(14).toList();
  final count = use.length + 1;
  if (use.length < 3) {
    return (
      line: 'Session $count. Your usual range shows after 4 sessions; a trend needs about 8.',
      low: null,
      high: null,
      earlier: use.length,
    );
  }
  final shares = [for (final s in use) s.settledShare]..sort();
  final low = shares.first, high = shares.last, pct = (now.settledShare * 100).round();
  final where = now.settledShare > high
      ? 'above'
      : now.settledShare < low
      ? 'below'
      : 'within';
  final range = '${(low * 100).round()}-${(high * 100).round()} %';
  final trend = count < 8 ? ' A trend needs about 8 sessions.' : '';
  return (
    line: 'Settled $pct % of the time: $where the range of your last ${use.length} sessions ($range).$trend',
    low: low,
    high: high,
    earlier: use.length,
  );
}
