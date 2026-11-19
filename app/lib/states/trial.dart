// "Which sound works for me": a fair test of two sounds for one state (ROADMAP row 18, DECISIONS rows 434-438). The
// self-experiments' design (rows 200-206) with sound sessions for days, reusing their draw and their test:
// - two sounds of one state and one length, for 4, 6 or 8 weeks; fixed at the start, nothing can be changed later;
// - every day draws one of the two, in shuffled blocks of 4 (2 of each) from a secret made on the phone, redrawn
//   until every weekday has both (experiments/experiment.dart, drawDays); the plan and the order's SHA-256 are saved
//   before day 1, which is tomorrow (trial_store.dart);
// - on a plan day that state plays that day's sound, and the session carries the plan's tag (store.dart);
// - a day's number is the first tagged session of that day that has one (weeks.dart); a day without one is left out;
// - the answer opens the day after the last day's number can come in: the difference between the two sounds, tested
//   with the self-experiments' randomisation test over every order the draw could have given (analysis.dart), with
//   its range and verdict, labelled "tested". Without a plan the comparison is only "seen together, not tested".
// Pure: no files, no clock (today is a day key).
import 'dart:math' as math;

import '../experiments/analysis.dart' show Orders, Tested, Verdict, pWords, shiftRange;
import '../experiments/experiment.dart' show ExpPhase, ExpRule, Progress, SealedOrder;
import '../sleep/drift.dart' show DriftResult;
import '../training/check.dart' show canonicalJson, sha256Hex;
import '../trends/days.dart';
import 'presets.dart';
import 'store.dart';
import 'weeks.dart';

/// Planning values: the self-experiments' own (DECISIONS rows 200, 203).
abstract final class TrialRule {
  /// Lengths offered, in weeks; the first is the default.
  static const List<int> weeks = ExpRule.weeks;

  /// Days of each sound with a number before a range or a verdict is given.
  static const int minPerSound = ExpRule.minPerArm;
}

/// The frozen plan, saved with its hash before day 1.
class TrialPlan {
  const TrialPlan({
    required this.id,
    required this.created,
    required this.state,
    required this.a,
    required this.b,
    required this.minutes,
    required this.start,
    required this.days,
    required this.allocationSha256,
  });

  /// The folder's name: when it was made and the state, `2026-11-19-090000-asleep`.
  final String id;
  final DateTime created;
  final SoundState state;

  /// The two sounds: "a" on the days the draw marks, "b" on the others.
  final SoundPick a, b;

  /// Minutes of sound in every session of the test.
  final int minutes;

  /// Day key of day 1, and how many days are assigned.
  final String start;
  final int days;
  final String allocationSha256;

  StateMeasure get measure => stateMeasures[state]!;
  String get lastDay => addDays(start, days - 1);

  /// The first day the answer opens: the last day's number can come the morning after it (a night's report).
  String get unlocks => addDays(start, days + 1);

  /// The session plan of sound [isA] (a) or b.
  SoundPlan planFor(bool isA) {
    final p = isA ? a : b;
    return SoundPlan.of(state, bed: p.bed, beat: p.beat, minutes: minutes);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'created': created.toIso8601String(),
    'state': state.name,
    'sounds': {
      'a': {...a.toJson(), 'line': a.line(state)},
      'b': {...b.toJson(), 'line': b.line(state)},
    },
    'minutes': minutes,
    'start': start,
    'days': days,
    'unlocks': unlocks,
    'primary': {
      'label': measure.label,
      'how': measure.how,
      'compared': measure.logScale ? 'as a ratio (difference of natural logs)' : 'as a difference of means',
      'matters': measure.matters,
      'weak': measure.weak,
    },
    'design':
        'every day plays sound a or sound b of this state, drawn once in shuffled blocks of 4 (2 of each; a last '
        'block of 2 when the days are not a multiple of 4), redrawn until every weekday has both; a day runs 04:00 '
        'to 04:00; the app sets a day\'s sound only once that day has come',
    'analysis':
        'a minus b of the mean number, each day counted as drawn; a day\'s number is the first session of the state '
        'that day played for this plan (its tag) and its sound that has one; two-sided randomisation test over the '
        'orders the draw could have given (blocks and the weekday rule; every order up to 300000, else 50000 seeded '
        'draws); the range is every constant difference that test does not reject at ${ExpRule.alpha}; days '
        'without a number are left out; needs ${TrialRule.minPerSound} days of each sound',
    'words':
        'likely real for you: p under ${ExpRule.alpha}; little or no effect: the whole range is smaller than '
        '"matters"; else not clear yet',
    'honesty':
        'one number, fixed here; the answer opens on the "unlocks" day; a stop is logged and shown with the '
        'answer; you know which sound plays, so expectation is part of any difference',
    'allocationSha256': allocationSha256,
  };

  String get sha => sha256Hex(canonicalJson(toJson()));

  static TrialPlan? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final created = DateTime.tryParse('${j['created']}');
    final id = j['id'], start = j['start'], days = j['days'], sha = j['allocationSha256'], minutes = j['minutes'];
    final state = SoundState.values.where((s) => s.name == j['state']).firstOrNull, sounds = j['sounds'];
    if (created == null || id is! String || !RegExp(r'^\d{4}-\d\d-\d\d-\d{6}-[a-z]+$').hasMatch(id) || state == null) return null;
    if (sounds is! Map || start is! String || !RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(start)) return null;
    if (days is! int || days < 2 || days.isOdd || days > 366 || sha is! String || sha.length != 64 || minutes is! int) return null;
    final a = SoundPick.fromJson(sounds['a']), b = SoundPick.fromJson(sounds['b']);
    if (a == null || b == null || !a.valid || !b.valid || a == b) return null;
    return TrialPlan(id: id, created: created, state: state, a: a, b: b, minutes: minutes, start: start, days: days, allocationSha256: sha);
  }
}

/// A past day of the test: its place, its key, and whether it drew sound a.
typedef TrialDay = ({int index, String day, bool a});

/// A test as of [today] (a day key). The only door to the sealed order: it gives out the days that have come and
/// nothing else until the answer is open.
class TrialState {
  TrialState({required this.plan, required this.planSha, required SealedOrder sealed, required this.progress, required this.today})
    : _sealed = sealed; // ignore: prefer_initializing_formals (the field stays private)

  final TrialPlan plan;

  /// The hash saved with the plan.
  final String planSha;
  final SealedOrder _sealed;

  /// Only its stop is used (the self-experiments' record of it).
  final Progress progress;
  final String today;

  /// The plan's hash, the order's hash and the order drawn again from the secret all agree.
  bool get planOk =>
      plan.sha == planSha && _sealed.sha == plan.allocationSha256 && _sealed.order.length == plan.days && _sealed.consistent;

  /// Today's place: 0 on day 1, negative before it.
  int get todayIndex => daysBetween(plan.start, today);

  /// Assigned days: the plan's, or up to the day before a stop.
  int get assignedDays => progress.stopped == null ? plan.days : progress.stopped!.daysDone.clamp(0, plan.days);

  ExpPhase get phase {
    if (progress.stopped != null) return ExpPhase.stopped;
    final i = todayIndex;
    if (i < 0) return ExpPhase.waiting;
    if (i < plan.days) return ExpPhase.running;
    return today.compareTo(plan.unlocks) >= 0 ? ExpPhase.finished : ExpPhase.lastNumber;
  }

  /// The answer may be read.
  bool get open => phase == ExpPhase.finished || phase == ExpPhase.stopped;

  /// Assigned days that are over.
  int get daysDone => todayIndex.clamp(0, assignedDays);

  bool _aOn(int i) => i < _sealed.order.length && _sealed.order[i];

  /// Today's draw (true: sound a) while the test runs; null otherwise.
  bool? get todayIsA => phase == ExpPhase.running ? _aOn(todayIndex) : null;

  /// Today's sound while the test runs.
  SoundPick? get todaySound => switch (todayIsA) {
    null => null,
    final isA => isA ? plan.a : plan.b,
  };

  /// The tag a session of [state] started today carries; null when today is not a day of this test for it.
  TrialTag? tagFor(SoundState state) {
    final isA = todayIsA;
    return isA == null || state != plan.state ? null : TrialTag(plan.id, today, isA ? 'a' : 'b');
  }

  /// The days that are over, oldest first.
  List<TrialDay> get pastDays => [for (var i = 0; i < daysDone; i++) (index: i, day: addDays(plan.start, i), a: _aOn(i))];

  /// The whole planned order, for the answer's test only. Null while the answer is closed, unless [early].
  List<bool>? orderForResults({bool early = false}) => open || early ? List.unmodifiable(_sealed.order) : null;
}

class TrialResults {
  const TrialResults({required this.state, required this.days, required this.withNumber, required this.tested, required this.verdict});
  final TrialState state;

  /// Assigned days that are over, and how many of them have a number.
  final int days, withNumber;
  final Tested? tested;
  final Verdict verdict;

  TrialPlan get plan => state.plan;
  StateMeasure get measure => plan.measure;
}

/// The day's number: the first session of the plan's state played for this plan on [d] with that day's sound.
double? _dayValue(TrialState s, TrialDay d, List<SoundSession> sorted, Iterable<DriftResult> nights) {
  final p = s.plan, sound = d.a ? p.a : p.b;
  for (final x in sorted) {
    final tag = x.trial;
    if (tag == null || tag.plan != p.id || tag.day != d.day || tag.sound != (d.a ? 'a' : 'b')) continue;
    if (x.plan.state != p.state || SoundPick(x.plan.bed, x.plan.beat) != sound) continue;
    final n = sessionNumber(x, nights: nights);
    if (n != null) return p.measure.judge(n.value);
  }
  return null;
}

/// The answer of [s] from [sessions] (and [nights], the sleep reports' falling-asleep results). Throws while the
/// answer is sealed.
TrialResults trialResults(TrialState s, Iterable<SoundSession> sessions, {Iterable<DriftResult> nights = const []}) {
  final order = s.orderForResults();
  if (order == null) throw StateError('the answer is sealed until ${s.plan.unlocks}');
  final sorted = [...sessions]..sort((a, b) => a.start.compareTo(b.start));
  final values = List<double?>.filled(order.length, null);
  final past = s.pastDays;
  for (final d in past) {
    values[d.index] = _dayValue(s, d, sorted, nights);
  }
  final v = [for (final x in values) ?x];
  final o = Orders.of(order, values), m = s.plan.measure;
  final nA = o.realDo, nB = o.have - o.realDo;
  Tested? tested;
  var verdict = Verdict.tooFew;
  if (o.bothKinds) {
    final enough = nA >= TrialRule.minPerSound && nB >= TrialRule.minPerSound;
    final range = enough ? shiftRange(o, v.reduce(math.max) - v.reduce(math.min)) : null;
    final p = o.p();
    tested = Tested(diff: o.diff(), p: p, orders: o.count, exact: o.exact, nDo: nA, nDont: nB, low: range?.low, high: range?.high, matters: m.matters);
    if (range != null) {
      verdict = p < ExpRule.alpha
          ? Verdict.likelyReal
          : (range.low > -m.matters && range.high < m.matters ? Verdict.littleOrNone : Verdict.notClear);
    }
  }
  return TrialResults(state: s, days: past.length, withNumber: v.length, tested: tested, verdict: verdict);
}

String _days(int n) => n == 1 ? '1 day' : '$n days';

/// The answer in one sentence, in the self-experiments' words. "With “Pink noise, pulsed noise 10 to 3 Hz” your time
/// to fall asleep was 4 min shorter than with “Pink noise, no beat” (range −9 to +1 min): not clear yet."
String trialSentence(TrialResults r) {
  final t = r.tested, m = r.measure, p = r.plan;
  final a = p.a.line(p.state), b = p.b.line(p.state);
  if (t == null || t.low == null) {
    final have = t == null
        ? 'no day of each sound has a number yet'
        : '${_days(t.nDo)} of “$a” and ${_days(t.nDont)} of “$b” have a number';
    return 'Too few days to say: $have, and it takes ${TrialRule.minPerSound} of each.';
  }
  final size = m.size(t.diff);
  final compare = size == 'the same' ? 'the same as' : '$size than';
  return 'With “$a” your ${m.noun} was $compare with “$b” (range ${m.range(t.low!, t.high!)}): ${r.verdict.words}.';
}

/// What the verdict means, in plain words (under the sentence).
String trialNote(TrialResults r) {
  final t = r.tested, m = r.measure;
  final known = m.weak
      ? 'You knew which sound played and the number is your own answer, so expectation can be all of it.'
      : 'You knew which sound played, so expectation can be part of it.';
  return switch (r.verdict) {
    Verdict.tooFew =>
      'A fair test needs days of both sounds with a number. ${m.rating ? 'Answer the question after each session' : 'Wear the headband for the sessions'} on more days of the plan.',
    Verdict.likelyReal =>
      'The app drew each day\'s sound by chance, and a difference this large would come up by chance alone in fewer '
          'than 1 of 20 draws (${pWords(t!.p)}). The range is where the true difference most likely lies. $known It '
          'is one test on one person: run it once more before you rely on it.',
    Verdict.littleOrNone =>
      'Whatever the difference is, the range says it is smaller than what would matter for this number. That is a '
          'real answer too: picking one of these sounds over the other does not change it much for you.',
    Verdict.notClear =>
      'The range includes zero and also differences large enough to matter, so these days cannot tell '
          '(${pWords(t!.p)}). It does not mean there is no difference. A longer test narrows the range.',
  };
}
