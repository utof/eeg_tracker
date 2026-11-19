// Everything the sharp-hours page shows, from the files (DECISIONS rows 280-287). Pure: the screen reads the files
// and the phone's state, this puts them together, the view lays them out.
import '../sleep/report.dart' show SleepReport;
import '../trends/days.dart';
import '../trends/pressure.dart';
import '../trends/trends.dart' show finalWake;
import 'hours.dart';
import 'schedule.dart';
import 'store.dart';

/// One way of grouping the answers: the ratings' or the reaction tests' points, how many could not be placed,
/// and the blocks once the gate is open.
class AxisView {
  const AxisView({required this.points, required this.left, this.profile});
  final List<SharpPoint> points;
  final int left;
  final SharpProfile? profile;
}

class SharpPageModel {
  const SharpPageModel({
    required this.now,
    required this.settings,
    required this.saved,
    required this.gate,
    required this.reach,
    required this.ratings,
    required this.reactions,
    required this.today,
    required this.todayTests,
    this.notificationsOn = true,
    this.xiaomi = false,
  });

  final DateTime now;

  /// The saved settings, or (never switched on) what switching on would use: the window suggested from your
  /// recorded nights, 4 a day.
  final SharpSettings settings;
  final bool saved;
  final GateState gate;
  final Reach reach;
  final Map<SharpAxis, AxisView> ratings, reactions;
  final List<SharpRating> today;
  final List<SharpReaction> todayTests;
  final bool notificationsOn, xiaomi;

  bool get on => settings.on;
}

/// Each scored night's first sleep and final wake-up in the 14 days before [now], for the suggested window.
List<({DateTime start, DateTime end})> recentNights(List<SleepReport> reports, DateTime now) => [
  for (final r in reports)
    if (r.scored && r.periods.isNotEmpty && now.difference(finalWake(r)).inDays < 14)
      (start: r.periods.map((p) => p.start).reduce((a, b) => a.isBefore(b) ? a : b), end: finalWake(r)),
];

/// The settings to show and to use when switching on for the first time.
SharpSettings firstSettings(List<SleepReport> reports, DateTime now, String seed) {
  final (from, until) = suggestWindow(recentNights(reports, now));
  return SharpSettings(on: false, perDay: SharpRule.perDayDefault, fromMin: from, untilMin: until, seed: seed);
}

SharpPageModel buildSharpPage({
  required SharpSettings? saved,
  required List<SharpRating> ratings,
  required List<SharpReaction> reactions,
  required List<PromptEvent> events,
  required List<SleepReport> reports,
  required DateTime now,
  String seed = 'not yet',
  bool notificationsOn = true,
  bool xiaomi = false,
}) {
  final settings = saved ?? firstSettings(reports, now, seed);
  final today = dayKey(now);
  final gate = sharpGate(ratings, reactions, today);
  final wakes = [
    for (final r in reports)
      if (r.scored) finalWake(r),
  ];
  final pressure = PressureModel([
    for (final r in reports)
      if (r.scored)
        for (final p in r.periods) (start: p.start, end: p.end),
  ]);
  Map<SharpAxis, AxisView> views(List<({DateTime at, double value})> values, {required bool open, required bool higherBetter, required int minPerBlock}) => {
    for (final axis in SharpAxis.values)
      axis: () {
        final placed = axisPoints(axis, values, wakes: wakes, pressure: pressure);
        return AxisView(
          points: placed.placed,
          left: placed.left,
          profile: open ? sharpProfile(axis, placed.placed, higherBetter: higherBetter, minPerBlock: minPerBlock) : null,
        );
      }(),
  };
  return SharpPageModel(
    now: now,
    settings: settings,
    saved: saved != null,
    gate: gate,
    reach: reachOf(settings, events, ratings, now),
    ratings: views([for (final r in ratings) (at: r.at, value: r.sharp.toDouble())], open: gate.open, higherBetter: true, minPerBlock: SharpGate.minPerBlock),
    reactions: views(
      [
        for (final t in reactions)
          if (t.medianMs != null) (at: t.ratingAt, value: t.medianMs!.toDouble()),
      ],
      open: gate.testsOpen,
      higherBetter: false,
      minPerBlock: 4,
    ),
    today: [
      for (final r in ratings)
        if (dayKey(r.at) == today) r,
    ]..sort((a, b) => a.at.compareTo(b.at)),
    todayTests: [
      for (final t in reactions)
        if (dayKey(t.ratingAt) == today) t,
    ],
    notificationsOn: notificationsOn,
    xiaomi: xiaomi,
  );
}

/// The Sharp hours section's one line on the Trends page.
String sharpTrendsLine(SharpSettings? s, List<SharpRating> ratings, List<SharpReaction> tests, DateTime now) {
  if (s == null && ratings.isEmpty) {
    return 'The assistant\'s proposal: a few one-tap questions a day, to learn when you are sharpest. Off until you '
        'switch it on.';
  }
  final g = sharpGate(ratings, tests, dayKey(now));
  final state = s?.on == true ? 'On. ' : 'Off. ';
  if (!g.open) return '$state${g.words}';
  final best = sharpProfile(
    SharpAxis.clock,
    axisPoints(SharpAxis.clock, [for (final r in ratings) (at: r.at, value: r.sharp.toDouble())]).placed,
    higherBetter: true,
  ).best;
  return '$state${best == null ? 'No clear best time yet.' : bestWords(SharpAxis.clock, best)}';
}

/// The tests already done today (the question page offers one while fewer than [SharpRule.testsMax]).
int testsToday(List<SharpReaction> reactions, DateTime now) =>
    reactions.where((t) => dayKey(t.ratingAt) == dayKey(now)).length;
