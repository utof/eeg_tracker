// Sound for states over weeks (ROADMAP row 18, DECISIONS rows 430-433): what each session says about its sound, and
// the sounds you used compared per state. Pure: sessions and nights in, numbers and words out.
//
// One number per session, by state (planning values, DECISIONS row 431):
//   fall asleep     minutes from lights off until probably asleep: the session's own drift-off detector; else that
//                   night's report (its detector, else the sleep model) when the report's lights off is within
//                   5 minutes of the session's; counted up to 45 (the sound's cap), and still awake when the sound
//                   stopped at its cap counts as 45;
//   relax           alpha (8-12 Hz) during the sound against the quiet minute (the session's readout), with at
//                   least a minute of clean signal;
//   break           slow waves (4-7 Hz) the same way: drowsiness (a good break rests without dozing off);
//   focus, wake up  your answer afterwards (1-5): weak, since you knew what played and these electrodes show no
//                   sign of either.
// Without the headband nothing is measured (an answer still counts). A session the phone cut short, or that failed,
// has no number.
//
// SEEN TOGETHER (never tested): per sound, the sessions played, those with a number and, from 14 with a number,
// the median and the middle half. You choose the sound on some days and not others, so this is not a test;
// trial.dart is the fair test.
import 'dart:math' as math;

import '../feedback/features.dart' show percentile;
import '../sleep/drift.dart' show DriftResult;
import 'presets.dart';
import 'readout.dart' show ReadSummary;
import 'store.dart';

/// Planning values (DECISIONS rows 431-432).
abstract final class WeeksRule {
  /// Sessions with a number before a sound's typical value is shown: the research's floor for any seen-together
  /// hint (14 with and 14 without, stricter than the 3 + 3 or 7 + 7 of commercial apps); two sounds at 14 each are
  /// 4 weeks of daily sessions, inside the 3-6 weeks per state the research expects.
  static const int minSessions = 14;

  /// Fall asleep: minutes are counted up to this, the sound's own cap (Drift.soundCapS).
  static const double capMin = 45;

  /// A night's report speaks for a session when its lights off is this close to the session's start.
  static const Duration nightMatch = Duration(minutes: 5);

  /// Relax and break: clean seconds during the sound, at least.
  static const int minCleanS = 60;
}

/// Where a session's number came from.
enum NumberFrom {
  /// The session's own drift-off detector.
  detector,

  /// The drift-off detector run over that night's recording (it kept watching after the session).
  nightDetector,

  /// The sleep model of that night: its first 10 epochs in a row not scored awake.
  sleepModel,

  /// Still awake when the sound stopped at its 45-minute cap: counted as 45.
  notAsleep,

  /// The readout against the quiet minute.
  readout,

  /// Your answer afterwards.
  rating,
}

typedef SessionNumber = ({double value, NumberFrom from});

/// What one state's sessions are compared by.
class StateMeasure {
  const StateMeasure({
    required this.label,
    required this.noun,
    required this.more,
    required this.less,
    required this.how,
    required this.matters,
    this.logScale = false,
    this.rating = false,
    this.weak = false,
  });

  /// "Time to fall asleep" (a heading).
  final String label;

  /// "time to fall asleep": follows "your".
  final String noun;

  /// The words for a higher and a lower value ("longer", "shorter").
  final String more, less;

  /// What it is and where it comes from, in one or two plain sentences.
  final String how;

  /// The smallest difference between two sounds that would matter (a planning value, on the judging scale:
  /// minutes, points, or the natural log of a ratio).
  final double matters;

  /// A ratio to the quiet minute, compared on a log scale and said as a percentage.
  final bool logScale;

  /// Your 1-5 answer.
  final bool rating;

  /// Your own answer, while you know what played: weak evidence.
  final bool weak;

  /// The value a difference is judged on.
  double judge(double v) => logScale ? math.log(v) : v;

  String _pct(double ratio) {
    final p = ((ratio - 1) * 100).round();
    return '${p > 0 ? '+' : (p < 0 ? '−' : '')}${p.abs()} %';
  }

  String _bare(double v) => logScale ? _pct(v).replaceAll(' %', '') : (rating ? v.toStringAsFixed(1) : '${v.round()}');

  String get _unit => logScale ? '%' : (rating ? '' : 'min');

  /// A session's value or a median: "18 min", "+12 %", "3.5 of 5".
  String show(double v) => logScale ? _pct(v) : (rating ? '${v.toStringAsFixed(1)} of 5' : '${v.round()} min');

  /// "between 4 and 11 min", "between −5 and +20 %", "between 3.0 and 4.0".
  String between(double low, double high) => 'between ${_bare(low)} and ${_bare(high)}${_unit.isEmpty ? '' : ' $_unit'}';

  /// A difference on the judging scale as a number and its unit: (12, "min"), (20, "%"), (0.6, "points").
  (double, String) shown(double d) {
    if (logScale) return (((math.exp(d) - 1) * 100).roundToDouble(), '%');
    if (rating) return ((d * 10).round() / 10, 'points');
    return (d.roundToDouble(), 'min');
  }

  String _digits(double n) => rating ? n.abs().toStringAsFixed(1) : n.abs().round().toString();

  /// "+12 min", "−0.6 points", "0 min".
  String signed(double d) {
    final (n, unit) = shown(d);
    return '${n > 0 ? '+' : (n < 0 ? '−' : '')}${_digits(n)} $unit';
  }

  /// "−9 to +1 min": the unit said once.
  String range(double low, double high) {
    final a = signed(low), b = signed(high);
    return '${a.substring(0, a.indexOf(' '))} to $b';
  }

  /// "12 min shorter", "20 % higher", or "the same".
  String size(double d) {
    final (n, unit) = shown(d);
    if (n == 0) return 'the same';
    return '${_digits(n)} $unit ${n > 0 ? more : less}';
  }
}

const Map<SoundState, StateMeasure> stateMeasures = {
  SoundState.asleep: StateMeasure(
    label: 'Time to fall asleep',
    noun: 'time to fall asleep',
    more: 'longer',
    less: 'shorter',
    how: 'Minutes from lights off until probably asleep, by the drift-off detector, else by that night\'s sleep '
        'report; still awake at 45 minutes counts as 45. Needs the headband.',
    matters: 5,
  ),
  SoundState.relax: StateMeasure(
    label: 'Alpha against the quiet minute',
    noun: 'alpha against the quiet minute',
    more: 'higher',
    less: 'lower',
    how: 'Alpha (8-12 Hz) during the sound against your quiet minute before it: higher is more relaxed with eyes '
        'closed. Needs the headband and a minute of clean signal.',
    matters: 0.182, // ln 1.2: a fifth
    logScale: true,
  ),
  SoundState.pause: StateMeasure(
    label: 'Drowsiness (slow waves)',
    noun: 'slow waves against the quiet minute',
    more: 'higher',
    less: 'lower',
    how: 'Slow waves (4-7 Hz) during the sound against your quiet minute: higher means drowsier. A good break '
        'rests without dozing off. Needs the headband and a minute of clean signal.',
    matters: 0.182,
    logScale: true,
  ),
  SoundState.focus: StateMeasure(
    label: 'Your answer',
    noun: 'answer',
    more: 'higher',
    less: 'lower',
    how: 'Your answer afterwards, 1 to 5. Weak: you knew which sound played, and focus has no clear sign in these '
        'electrodes.',
    matters: 1,
    rating: true,
    weak: true,
  ),
  SoundState.wake: StateMeasure(
    label: 'Your answer',
    noun: 'answer',
    more: 'higher',
    less: 'lower',
    how: 'Your answer afterwards, 1 to 5. Weak: you knew which sound played, and waking up has no clear sign in '
        'these electrodes.',
    matters: 1,
    rating: true,
    weak: true,
  ),
};

/// The fall-asleep number of [s]: its own detector, the night's report, or still awake at the cap.
SessionNumber? _asleep(SoundSession s, Iterable<DriftResult> nights) {
  final cap = WeeksRule.capMin;
  final onset = s.drift['onsetS'];
  if (s.headband == HeadbandUse.used && onset is int && onset >= 0) {
    return (value: math.min(onset / 60, cap), from: NumberFrom.detector);
  }
  DriftResult? near;
  var best = WeeksRule.nightMatch;
  for (final n in nights) {
    final d = n.lightsOff.difference(s.start).abs();
    if (d <= best) {
      best = d;
      near = n;
    }
  }
  if (near != null) {
    final m = near.onsetMin ?? near.modelOnsetMin;
    if (m != null && m.isFinite && m >= 0) {
      return (value: math.min(m, cap), from: near.onsetMin != null ? NumberFrom.nightDetector : NumberFrom.sleepModel);
    }
  }
  final watched = s.headband == HeadbandUse.used && s.drift['baselineS'] is int;
  return watched && s.end == SoundEnd.cap ? (value: cap, from: NumberFrom.notAsleep) : null;
}

/// The readout's value [pick]s (a ratio to the quiet minute) when it rests on a minute of clean signal with the headband.
SessionNumber? _ratio(SoundSession s, double Function(ReadSummary sum) pick) {
  final sum = s.summary;
  if (s.headband != HeadbandUse.used || sum == null || sum.cleanS < WeeksRule.minCleanS) return null;
  final v = pick(sum);
  return v.isFinite && v > 0 ? (value: v, from: NumberFrom.readout) : null;
}

/// [s]'s number for its state's comparison (display scale: minutes, a ratio, or 1-5); null when it has none.
/// [nights]: the sleep reports' "falling asleep" results, for fall-asleep sessions the session itself did not see
/// end.
SessionNumber? sessionNumber(SoundSession s, {Iterable<DriftResult> nights = const []}) {
  if (s.end == SoundEnd.running || s.end == SoundEnd.failed) return null;
  return switch (s.plan.state) {
    SoundState.asleep => _asleep(s, nights),
    SoundState.relax => _ratio(s, (sum) => sum.alpha),
    SoundState.pause => _ratio(s, (sum) => sum.slow),
    SoundState.focus || SoundState.wake => s.rating == null ? null : (value: s.rating!.toDouble(), from: NumberFrom.rating),
  };
}

/// A sound as the comparison tells sounds apart: the bed and the beat (each state has its own beat rates).
class SoundPick {
  const SoundPick(this.bed, this.beat);
  final Bed bed;
  final Beat beat;

  /// Something plays.
  bool get valid => bed != Bed.none || beat != Beat.none;

  /// "Pink noise, pulsed noise 10 to 3 Hz" for [state].
  String line(SoundState state) => SoundPlan.of(state, bed: bed, beat: beat).line;

  Map<String, Object?> toJson() => {'bed': bed.name, 'beat': beat.name};

  static SoundPick? fromJson(Object? j) {
    if (j is! Map) return null;
    final bed = Bed.values.where((b) => b.name == j['bed']).firstOrNull;
    final beat = Beat.values.where((b) => b.name == j['beat']).firstOrNull;
    return bed == null || beat == null ? null : SoundPick(bed, beat);
  }

  @override
  bool operator ==(Object other) => other is SoundPick && other.bed == bed && other.beat == beat;

  @override
  int get hashCode => Object.hash(bed, beat);

  @override
  String toString() => '${bed.name}/${beat.name}';
}

/// One sound of one state over the weeks.
class SoundRow {
  SoundRow(this.sound, this.line, this.played, this.values);
  final SoundPick sound;
  final String line;

  /// Sessions that played it, and the numbers of those that have one (display scale, oldest first).
  final int played;
  final List<double> values;

  bool get enough => values.length >= WeeksRule.minSessions;

  /// The median and the middle half (25th to 75th percentile); null until [enough].
  double? get median => enough ? percentile(values, 0.5) : null;
  double? get low => enough ? percentile(values, 0.25) : null;
  double? get high => enough ? percentile(values, 0.75) : null;
}

class StateComparison {
  const StateComparison(this.state, this.rows);
  final SoundState state;

  /// The most played sound first.
  final List<SoundRow> rows;

  StateMeasure get measure => stateMeasures[state]!;
  int get played => rows.fold(0, (a, r) => a + r.played);
  int get counted => rows.fold(0, (a, r) => a + r.values.length);
}

/// The sounds of [state] in [sessions] side by side: seen together, not tested.
StateComparison compareSounds(SoundState state, Iterable<SoundSession> sessions, {Iterable<DriftResult> nights = const []}) {
  final played = <SoundPick, int>{};
  final values = <SoundPick, List<double>>{};
  final ordered = [
    for (final s in sessions)
      if (s.plan.state == state && s.soundStartS != null) s,
  ]..sort((a, b) => a.start.compareTo(b.start));
  for (final s in ordered) {
    final k = SoundPick(s.plan.bed, s.plan.beat);
    played[k] = (played[k] ?? 0) + 1;
    final n = sessionNumber(s, nights: nights);
    (values[k] ??= []).addAll([?n?.value]);
  }
  final rows = [for (final k in played.keys) SoundRow(k, k.line(state), played[k]!, values[k]!)]
    ..sort((a, b) => a.played != b.played ? b.played.compareTo(a.played) : a.line.compareTo(b.line));
  return StateComparison(state, rows);
}

String _sessions(int n) => n == 1 ? '1 session' : '$n sessions';

/// A row's value: the median, or the count toward [WeeksRule.minSessions] ("5 of 14").
String rowValue(StateMeasure m, SoundRow r) => r.enough ? m.show(r.median!) : '${r.values.length} of ${WeeksRule.minSessions}';

/// A row's second line: "Half of 14 sessions between 4 and 11 min", or "2 sessions, 1 with a number: not enough
/// yet".
String rowDetail(StateMeasure m, SoundRow r) {
  final n = r.values.length, without = r.played - n;
  if (!r.enough) {
    final have = without == 0 ? '${_sessions(n)} with a number' : '${_sessions(r.played)}, ${n == 0 ? 'none' : '$n'} with a number';
    return '$have: not enough yet';
  }
  final more = without == 0 ? '' : '; $without more without a number';
  return 'Half of ${_sessions(n)} ${m.between(r.low!, r.high!)}$more';
}
