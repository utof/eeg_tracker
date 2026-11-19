// Self-experiments (ROADMAP row 14; DECISIONS rows 12, 200-209): the app picks random days for a few weeks ("no
// screens in the last hour before bed" against "screens as usual") and at the planned end says what it did to one
// number chosen up front. Pure: the question, the plan, the hidden order and what a day shows; analysis.dart has
// the test and the words, store.dart keeps it all on disk.
//
// - One question (a preset or your own "do" against "don't"), ONE primary outcome from the trends' per-day
//   numbers, a length in weeks. Fixed at the start; nothing can be changed afterwards.
// - The order is drawn once from a random secret made on the phone, in shuffled blocks of 4 days (2 do, 2 don't;
//   a last block of 2 when the length is not a multiple of 4), with the replay check's own draw
//   (training/check.dart), redrawn until every weekday has both kinds. The plan and the SHA-256 of the order are
//   saved before day 1.
// - The app shows a day's task only when that day has come; the days ahead stay sealed.
// - The outcome of a day's task is the number of the NEXT day: the night you woke from and that morning's
//   check-in (trends/days.dart: a night counts for the day it ends).
// - Results open at the planned end. An early look is possible, asks first, and is marked on the results for good.
import '../training/check.dart' show allocate, Arm, canonicalJson, sha256Hex;
import '../trends/days.dart';
import '../trends/trends.dart' show MeasureSpec, measureSpecs;
import '../trends/usual.dart' show Scale;

/// Planning values (DECISIONS rows 200-204).
abstract final class ExpRule {
  static const int blockSize = 4, doPerBlock = 2;

  /// Lengths offered, in weeks; the first is the default.
  static const List<int> weeks = [4, 6, 8];

  /// Days of each kind with a value before any range or verdict is given.
  static const int minPerArm = 5;

  /// A result is "likely real for you" when the test's p is under this (the range then leaves out zero).
  static const double alpha = 0.05;
}

/// A ready-made question. [outcome]: the number it most likely moves, preselected in the setup.
class Preset {
  const Preset(this.id, this.doText, this.dontText, this.outcome);
  final String id, doText, dontText, outcome;
}

const List<Preset> presets = [
  Preset('caffeine', 'No caffeine in the last 8 hours before bed', 'Caffeine as usual', 'asleep'),
  Preset('screens', 'No screens in the last hour before bed', 'Screens as usual', 'asleep'),
  Preset('meditation', 'A 10-minute meditation before bed', 'No meditation before bed', 'kss'),
  Preset('sound', 'Sound for Fall asleep at bedtime', 'Silence at bedtime', 'asleep'),
  // the study reminders' recall (DECISIONS row 401): the next morning's answer, from the page on morning-study days
  Preset('study', 'Study in the evening, a few hours before bed', 'Study in the morning instead', 'recall'),
];

/// A number an experiment can test: one of the trends' per-day numbers, with the words for a difference.
class Outcome {
  const Outcome(this.id, this.noun, this.more, this.less, {required this.matters, this.plural = false});
  final String id;

  /// "time asleep", "reaction time": follows "your".
  final String noun;

  /// The words for a higher and a lower value ("longer", "shorter").
  final String more, less;

  /// The smallest difference between the two kinds of day that would matter (a planning value, in the units the
  /// difference is judged in: minutes, points, a share of the "don't" days' mean, or a ratio's natural log).
  final double matters;
  final bool plural;

  MeasureSpec get spec => measureSpecs.firstWhere((m) => m.id == id);
  String get label => spec.label;
  Scale get scale => spec.scale;

  /// Powers and ratios are compared as ratios (on a log scale), everything else as plain differences.
  bool get logScale => scale.logScale;

  /// [matters] is a share of the "don't" days' mean (reaction time, jaw bursts) and not a fixed amount.
  bool get relative => scale == Scale.reaction || scale == Scale.rate;
}

/// The numbers offered as the primary outcome: what a day's habit can move by the next morning. Practice minutes,
/// the settled share and the cups you note are things you do, not outcomes, so they are not offered.
const List<Outcome> outcomes = [
  Outcome('asleep', 'time asleep', 'longer', 'shorter', matters: 30),
  Outcome('kss', 'morning sleepiness', 'higher', 'lower', matters: 1),
  Outcome('reaction', 'reaction time', 'slower', 'quicker', matters: 0.05),
  Outcome('mood', 'mood', 'higher', 'lower', matters: 1),
  // the sharp-hours log's day numbers (DECISIONS row 287): the mean of the next day's ratings, half a point
  Outcome('sharp', 'sharpness in the day', 'higher', 'lower', matters: 0.5),
  Outcome('dayrt', 'reaction time in the day', 'slower', 'quicker', matters: 0.05),
  // the study reminders' morning recall (DECISIONS row 401): 1 a little, 2 some, 3 well; half a step
  Outcome('recall', 'recall of what you studied', 'better', 'worse', matters: 0.5),
  // the work sessions' day numbers (DECISIONS row 480): the next day's share of usable work time at getting drowsy
  // or drowsy (10 percentage points) and the mean of its "how sharp" taps (half a point)
  Outcome('workdrowsy', 'share of work time drowsy', 'higher', 'lower', matters: 10),
  Outcome('worksharp', 'sharpness at work', 'higher', 'lower', matters: 0.5),
  Outcome('tension', 'tension', 'higher', 'lower', matters: 1),
  Outcome('jaw', 'jaw muscle bursts an hour', 'higher', 'lower', matters: 0.25, plural: true),
  Outcome('iaf', 'alpha speed', 'faster', 'slower', matters: 0.2),
  Outcome('alpha', 'alpha strength', 'higher', 'lower', matters: 0.182), // ln 1.2: a fifth
  Outcome('rise', 'eyes-closed rise', 'larger', 'smaller', matters: 0.182),
];

Outcome? outcomeById(Object? id) => outcomes.where((o) => o.id == id).firstOrNull;

/// Both kinds of day fall on every weekday: of the days 7 apart (a weekday's days), no set of 3 or more is all
/// "do" or all "don't". (With only 2 weeks a weekday has 2 days, and the rule would fix week 2 from week 1.)
bool spreadOk(List<bool> order) {
  for (var col = 0; col < 7; col++) {
    var n = 0, doDays = 0;
    for (var i = col; i < order.length; i += 7) {
      n++;
      if (order[i]) doDays++;
    }
    if (n >= 3 && (doDays == 0 || doDays == n)) return false;
  }
  return true;
}

/// The size of every block of [days] days: fours, then a last pair when 2 days are left over.
List<int> blockSizes(int days) => [
  for (var b = 0; b < days ~/ ExpRule.blockSize; b++) ExpRule.blockSize,
  if (days % ExpRule.blockSize == 2) 2,
];

/// The order for [days] days, drawn from [salt] alone: true = a "do" day. Whole blocks of 4 with exactly 2 of
/// each (the replay check's draw); a remainder of 2 is one more pair. A draw that leaves a weekday with one kind
/// only ([spreadOk]) is thrown away and drawn again from `salt#1`, `salt#2`...: about 4 in 10 pass for 4 weeks.
/// [days] must be even.
List<bool> drawDays(String salt, int days) {
  if (days < 2 || days.isOdd) throw ArgumentError('an experiment needs an even number of days');
  for (var round = 0; ; round++) {
    final s = round == 0 ? salt : '$salt#$round';
    final order = [
      for (final a in allocate(s, days ~/ ExpRule.blockSize)) a == Arm.live,
      if (days % ExpRule.blockSize == 2)
        for (final a in allocate('$s:tail', 1, size: 2, live: 1)) a == Arm.live,
    ];
    if (spreadOk(order)) return order;
  }
}

/// The block a day belongs to (labels are reshuffled only inside a block).
int blockOf(int dayIndex) => dayIndex ~/ ExpRule.blockSize;

String orderText(List<bool> order) => order.map((d) => d ? '1' : '0').join();
List<bool>? orderFrom(Object? text) {
  if (text is! String || text.isEmpty || !RegExp(r'^[01]+$').hasMatch(text)) return null;
  return [for (final c in text.split('')) c == '1'];
}

/// The hidden part: the secret and the order it gives. Read only to show a day that has come and for the results.
class SealedOrder {
  const SealedOrder(this.salt, this.order);
  factory SealedOrder.draw(String salt, int days) => SealedOrder(salt, drawDays(salt, days));

  final String salt;
  final List<bool> order;

  Map<String, Object?> toJson() => {'salt': salt, 'allocation': orderText(order)};
  String get sha => sha256Hex(canonicalJson(toJson()));

  /// True when the order is the one the secret gives (nobody edited one without the other).
  bool get consistent => order.length.isEven && orderText(drawDays(salt, order.length)) == orderText(order);

  static SealedOrder? fromJson(Object? j) {
    if (j is! Map || j['salt'] is! String) return null;
    final o = orderFrom(j['allocation']);
    return o == null ? null : SealedOrder(j['salt'] as String, o);
  }
}

/// The frozen plan, saved with its hash before day 1.
class ExperimentPlan {
  const ExperimentPlan({
    required this.id,
    required this.created,
    required this.preset,
    required this.doText,
    required this.dontText,
    required this.outcome,
    required this.start,
    required this.days,
    required this.allocationSha256,
  });

  /// The folder's name: when it was made, `2026-11-19-143000`.
  final String id;
  final DateTime created;

  /// A preset's id, or `custom`.
  final String preset;
  final String doText, dontText;
  final Outcome outcome;

  /// Day key of day 1, and how many days are assigned.
  final String start;
  final int days;
  final String allocationSha256;

  String get lastDay => addDays(start, days - 1);

  /// The first day the results open: the last day's number comes the day after it, and that day must be over.
  String get unlocks => addDays(start, days + 1);

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'created': created.toIso8601String(),
    'question': {'preset': preset, 'do': doText, 'dont': dontText},
    'primary': {
      'id': outcome.id,
      'label': outcome.label,
      'day': 'the day after the assigned day (the night you wake from and that morning\'s check-in)',
      'compared': outcome.logScale ? 'as a ratio (difference of natural logs)' : 'as a difference of means',
      'matters': outcome.matters,
      'mattersIs': outcome.relative
          ? 'a share of the mean of the "don\'t" days'
          : outcome.logScale
          ? 'a natural log of a ratio'
          : 'in the number\'s own units',
    },
    'start': start,
    'days': days,
    'unlocks': unlocks,
    'design':
        'every day is a "do" or a "don\'t" day, drawn once in shuffled blocks of ${ExpRule.blockSize} '
        '(${ExpRule.doPerBlock} of each; a last block of 2 when the days are not a multiple of 4), redrawn until '
        'every weekday has both kinds; a day runs '
        '04:00 to 04:00; the app shows a day\'s task only once that day has come',
    'blockSize': ExpRule.blockSize,
    'analysis':
        'do minus don\'t of the mean primary number, days counted as assigned whether kept or not; two-sided '
        'randomisation test over the orders the draw could have given (blocks and the weekday rule; every order '
        'up to 300000, else 50000 seeded draws); the range is every constant effect that test does not reject at ${ExpRule.alpha}; days without a '
        'number are left out; needs ${ExpRule.minPerArm} days of each kind',
    'words':
        'likely real for you: p under ${ExpRule.alpha}; little or no effect: the whole range is smaller than '
        '"matters"; else not clear yet',
    'secondary':
        'the same difference by what you say you did (not kept = the other kind of day), and the other numbers: '
        'all shown as seen together, not tested',
    'honesty':
        'one primary number, fixed here; results open on the "unlocks" day; an early look or a stop is logged '
        'and shown with the results; every assigned day with a number is counted',
    'allocationSha256': allocationSha256,
  };

  String get sha => sha256Hex(canonicalJson(toJson()));

  static ExperimentPlan? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final q = j['question'], p = j['primary'];
    final created = DateTime.tryParse('${j['created']}');
    final id = j['id'], start = j['start'], days = j['days'], a = j['allocationSha256'];
    if (q is! Map || p is! Map || created == null || id is! String || !RegExp(r'^[0-9-]{10,20}$').hasMatch(id)) {
      return null;
    }
    final outcome = outcomeById(p['id']);
    final doText = q['do'], dontText = q['dont'], preset = q['preset'];
    if (outcome == null || doText is! String || dontText is! String || preset is! String) return null;
    if (start is! String || !RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(start)) return null;
    if (days is! int || days < 2 || days.isOdd || days > 366 || a is! String || a.length != 64) return null;
    return ExperimentPlan(
      id: id,
      created: created,
      preset: preset,
      doText: doText,
      dontText: dontText,
      outcome: outcome,
      start: start,
      days: days,
      allocationSha256: a,
    );
  }
}

/// What the owner did to the run itself: an early look, or a stop before the end.
class Mark {
  const Mark(this.at, this.day, this.daysDone);
  final DateTime at;

  /// The day key it happened on, and how many assigned days were over by then.
  final String day;
  final int daysDone;

  Map<String, Object?> toJson() => {'at': at.toIso8601String(), 'day': day, 'daysDone': daysDone};
  static Mark? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}'), day = j['day'], n = j['daysDone'];
    return at == null || day is! String || n is! int ? null : Mark(at, day, n);
  }
}

/// What changes while an experiment runs: the answers to "did you keep to it?", early looks and a stop.
class Progress {
  const Progress({this.kept = const {}, this.earlyLooks = const [], this.stopped});

  /// Day key -> kept to the day's task (true) or not (false). No entry: not answered.
  final Map<String, bool> kept;
  final List<Mark> earlyLooks;
  final Mark? stopped;

  Progress answer(String day, bool wasKept) =>
      Progress(kept: {...kept, day: wasKept}, earlyLooks: earlyLooks, stopped: stopped);
  Progress look(Mark m) => Progress(kept: kept, earlyLooks: [...earlyLooks, m], stopped: stopped);
  Progress stop(Mark m) => Progress(kept: kept, earlyLooks: earlyLooks, stopped: stopped ?? m);

  Map<String, Object?> toJson() => {
    'kept': {for (final k in kept.keys.toList()..sort()) k: kept[k]},
    'early_looks': [for (final m in earlyLooks) m.toJson()],
    if (stopped != null) 'stopped': stopped!.toJson(),
  };

  static Progress fromJson(Object? j) {
    if (j is! Map) return const Progress();
    final k = j['kept'], looks = j['early_looks'];
    return Progress(
      kept: {
        if (k is Map)
          for (final e in k.entries)
            if (e.key is String && e.value is bool) e.key as String: e.value as bool,
      },
      earlyLooks: [
        if (looks is List)
          for (final m in looks) ?Mark.fromJson(m),
      ],
      stopped: Mark.fromJson(j['stopped']),
    );
  }
}

enum ExpPhase {
  /// Saved; day 1 is tomorrow.
  waiting,

  /// A day with a task.
  running,

  /// Every day is assigned; the last number is still coming in.
  lastNumber,

  /// The planned end has come: results are open.
  finished,

  /// Stopped by the owner before the end: results are open, and marked.
  stopped,
}

/// One past or present day as the screen may show it. Days ahead never become a [DayView].
class DayView {
  const DayView(this.index, this.day, this.doIt, this.kept);
  final int index;
  final String day;
  final bool doIt;

  /// The answer to "did you keep to it?"; null while not answered.
  final bool? kept;
}

/// An experiment as of [today] (a day key). The only door to the sealed order: it gives out the days that have
/// come and nothing else until the results are open.
class ExperimentState {
  ExperimentState({
    required this.plan,
    required this.planSha,
    required SealedOrder sealed,
    required this.progress,
    required this.today,
  }) : _sealed = sealed; // ignore: prefer_initializing_formals (the field stays private)

  final ExperimentPlan plan;

  /// The hash saved with the plan.
  final String planSha;
  final SealedOrder _sealed;
  final Progress progress;
  final String today;

  /// The plan's hash, the order's hash and the order drawn again from the secret all agree.
  bool get planOk =>
      plan.sha == planSha &&
      _sealed.sha == plan.allocationSha256 &&
      _sealed.order.length == plan.days &&
      _sealed.consistent;

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

  /// Results may be read without it being an early look.
  bool get open => phase == ExpPhase.finished || phase == ExpPhase.stopped;

  /// Assigned days that are over (their task can no longer change).
  int get daysDone => todayIndex.clamp(0, assignedDays);

  bool _doOn(int i) => i < _sealed.order.length && _sealed.order[i];

  /// Today's task, while the experiment runs.
  DayView? get todayView {
    if (phase != ExpPhase.running) return null;
    final i = todayIndex;
    return DayView(i, today, _doOn(i), progress.kept[today]);
  }

  /// The days that are over, oldest first.
  List<DayView> get pastDays => [
    for (var i = 0; i < daysDone; i++) DayView(i, addDays(plan.start, i), _doOn(i), progress.kept[addDays(plan.start, i)]),
  ];

  /// Past days still waiting for "did you keep to it?", newest first; at most the last [limit].
  List<DayView> unanswered({int limit = 7}) {
    if (open) return const [];
    final p = pastDays.reversed.take(limit);
    return [
      for (final d in p)
        if (d.kept == null) d,
    ];
  }

  /// The days the analysis counts, given the per-day numbers of the primary outcome and the others: every
  /// assigned day that is over, with the number of the day after it. Call for results only.
  List<ExpDay> analysisDays(Map<String, Map<String, double>> series) => [
    for (final d in pastDays)
      ExpDay(
        index: d.index,
        day: d.day,
        doIt: d.doIt,
        kept: d.kept,
        values: {
          for (final o in outcomes)
            if (series[o.id]?[addDays(d.day, 1)] != null) o.id: series[o.id]![addDays(d.day, 1)]!,
        },
      ),
  ];

  /// The whole planned order, for the results' test only (it reshuffles all planned days). Null while the
  /// results are closed and no early look was asked for ([early]).
  List<bool>? orderForResults({bool early = false}) => open || early ? List.unmodifiable(_sealed.order) : null;

  String textFor(bool doIt) => doIt ? plan.doText : plan.dontText;
}

/// One counted day for the analysis: what was assigned, whether it was kept, and the next day's numbers.
class ExpDay {
  const ExpDay({required this.index, required this.day, required this.doIt, this.kept, this.values = const {}});
  final int index;
  final String day;
  final bool doIt;
  final bool? kept;

  /// Outcome id -> the number of the day after [day].
  final Map<String, double> values;
  int get block => blockOf(index);
}

/// The id (and folder name) of an experiment made at [now]: `2026-11-19-143000`.
String experimentId(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// A custom line as kept: trimmed, one line, at most 80 characters.
String cleanLine(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 80 ? t.substring(0, 80).trim() : t;
}
