// The sharp-hours log's sampling schedule (ROADMAP "Sharp-hours log"; DECISIONS rows 281-283). Pure: when to ask
// "how sharp do you feel?", worked out again the same way whenever it is needed.
//
// - A few moments a day (4 by default; 3 or 6) inside the waking window ("awake from" to "until"; outside it are
//   the quiet hours). Stratified random sampling: the window is cut into equal parts and each part gets one moment
//   at a random minute, so every day has early and late answers to compare within the day, every waking hour is
//   covered over the weeks, and no fixed hour can be expected (fixed hours would tie each hour to the question).
// - Moments at least an hour apart (a day is redrawn until they are); a short window gets fewer.
// - Two of a day's moments, at random, suggest the 1-minute reaction test.
// - Drawn from a secret made on the phone and the day, so the moments are the same each time the app works them
//   out (to arm the next ones, and to count which ones arrived), and nobody, the owner included, can tell them
//   in advance from the clock.
//
// The Android side (SharpPrompts.kt) only rings the moments it is given, and skips one during a night recording
// or a session.
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../trends/days.dart';

/// Planning values (DECISIONS rows 281-283).
abstract final class SharpRule {
  /// How many moments a day the owner can choose; [perDayDefault] first.
  static const List<int> perDayChoices = [3, 4, 6];
  static const int perDayDefault = 4;

  /// The least time between two moments of a day.
  static const int minGapMin = 60;

  /// Moments a day that suggest the reaction test, and the most tests a day the rating page offers.
  static const int testsSuggested = 2;
  static const int testsMax = 3;

  /// The waking window: at least this long, and the quiet hours too.
  static const int minWindowMin = 4 * 60, minQuietMin = 4 * 60;

  /// Without 3 recorded nights in the last 14 days.
  static const int defaultFromMin = 10 * 60, defaultUntilMin = 22 * 60;

  /// The suggested window starts this long after your usual wake-up and ends this long before your usual sleep.
  static const int afterWakeMin = 30, beforeSleepMin = 60;

  /// How many days ahead the phone is given moments (re-armed at every app start and every answer).
  static const int armDays = 14;

  /// A moment that rings later than this is dropped (logged "late"); the notification goes after the same time.
  /// The same values are in SharpPrompts.kt.
  static const int lateMin = 60, snoozeMin = 15;
}

/// `09:05`.
String clockText(int minutes) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// Minutes after midnight from `HH:MM` (two digits each); null for anything else.
int? parseClock(Object? s) {
  if (s is! String) return null;
  final m = RegExp(r'^(\d\d):(\d\d)$').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m[1]!), mi = int.parse(m[2]!);
  return h < 24 && mi < 60 ? h * 60 + mi : null;
}

/// Minutes from [from] to [until] on the clock (past midnight when [until] is earlier).
int windowLength(int from, int until) => ((until - from) % 1440 + 1440) % 1440;

/// A usable window: at least 4 hours awake and at least 4 quiet hours.
bool windowOk(int from, int until) {
  final w = windowLength(from, until);
  return w >= SharpRule.minWindowMin && 1440 - w >= SharpRule.minQuietMin;
}

class SharpSettings {
  const SharpSettings({
    required this.on,
    required this.perDay,
    required this.fromMin,
    required this.untilMin,
    required this.seed,
    this.firstOn,
    this.changed,
  });

  /// Questions during the day (the owner's switch; off until switched on).
  final bool on;
  final int perDay;

  /// The waking window, minutes after midnight.
  final int fromMin, untilMin;

  /// The phone-made secret the moments are drawn from.
  final String seed;

  /// When the questions were first switched on, and when the switch, the window or the count last changed.
  final DateTime? firstOn, changed;

  int get windowMin => windowLength(fromMin, untilMin);

  SharpSettings copyWith({bool? on, int? perDay, int? fromMin, int? untilMin, DateTime? firstOn, DateTime? changed}) =>
      SharpSettings(
        on: on ?? this.on,
        perDay: perDay ?? this.perDay,
        fromMin: fromMin ?? this.fromMin,
        untilMin: untilMin ?? this.untilMin,
        seed: seed,
        firstOn: firstOn ?? this.firstOn,
        changed: changed ?? this.changed,
      );

  Map<String, Object?> toJson() => {
    'version': 1,
    'on': on,
    'per_day': perDay,
    'awake_from': clockText(fromMin),
    'awake_until': clockText(untilMin),
    'seed': seed,
    'first_on': firstOn?.toIso8601String(),
    'changed': changed?.toIso8601String(),
  };

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

  /// Null for anything that is not a settings file this version wrote.
  static SharpSettings? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1 || j['on'] is! bool) return null;
    final perDay = j['per_day'], from = parseClock(j['awake_from']), until = parseClock(j['awake_until']);
    final seed = j['seed'];
    if (perDay is! int || !SharpRule.perDayChoices.contains(perDay)) return null;
    if (from == null || until == null || !windowOk(from, until)) return null;
    if (seed is! String || seed.isEmpty) return null;
    final first = _time(j['first_on']), changed = _time(j['changed']);
    if ((j['first_on'] != null && first == null) || (j['changed'] != null && changed == null)) return null;
    return SharpSettings(
      on: j['on'] as bool,
      perDay: perDay,
      fromMin: from,
      untilMin: until,
      seed: seed,
      firstOn: first,
      changed: changed,
    );
  }
}

/// What a planned moment asks. The phone's one alarm chain rings them all (SharpPrompts.kt): the sharp-hours
/// question, and the two study reminders (lib/study/, DECISIONS rows 400-401).
enum PromptKind {
  sharp('sharp'),
  studyEvening('study_evening'),
  studyMorning('study_morning');

  const PromptKind(this.wire);

  /// The name the Android side knows it by.
  final String wire;

  bool get isStudy => this != sharp;
}

/// One planned moment: when, what it asks, and (sharp-hours questions) whether it suggests the reaction test.
class PlannedPrompt {
  const PlannedPrompt(this.at, {this.test = false, this.kind = PromptKind.sharp});
  final DateTime at;
  final bool test;
  final PromptKind kind;

  @override
  String toString() => 'PlannedPrompt($at${test ? ', test' : ''}${kind == PromptKind.sharp ? '' : ', ${kind.name}'})';
}

/// A day's seed from the secret and the day key (SHA-256, so it does not depend on Dart's hash codes).
int daySeed(String seed, String day) {
  final b = sha256.convert(utf8.encode('sharp-hours|$seed|$day')).bytes;
  var v = 0;
  for (var i = 0; i < 6; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

/// The start of [day]'s window: its calendar date at [fromMin], or the next date when the window starts before
/// the day does (04:00).
DateTime windowStart(String day, int fromMin) {
  final d = dayNoon(day);
  final shift = fromMin < dayStartHour * 60 ? 1 : 0;
  return DateTime(d.year, d.month, d.day + shift, 0, fromMin);
}

/// The moments of [day] (a 04:00-04:00 day key), oldest first; none when off.
List<PlannedPrompt> promptsForDay(String day, SharpSettings s) {
  if (!s.on) return const [];
  final window = s.windowMin;
  final n = math.min(s.perDay, window ~/ SharpRule.minGapMin);
  if (n <= 0) return const [];
  final start = windowStart(day, s.fromMin);
  final part = window / n;
  final r = math.Random(daySeed(s.seed, day));
  List<int> draw() => [for (var k = 0; k < n; k++) (k * part + r.nextDouble() * part).floor()];
  bool spaced(List<int> m) {
    for (var i = 1; i < m.length; i++) {
      if (m[i] - m[i - 1] < SharpRule.minGapMin) return false;
    }
    return true;
  }

  var minutes = draw();
  for (var tries = 0; !spaced(minutes) && tries < 1000; tries++) {
    minutes = draw();
  }
  // practically never: the parts' middles are always far enough apart
  if (!spaced(minutes)) minutes = [for (var k = 0; k < n; k++) (k * part + part / 2).floor()];
  final tests = ([for (var k = 0; k < n; k++) k]..shuffle(r)).take(SharpRule.testsSuggested).toSet();
  return [
    for (var k = 0; k < n; k++)
      PlannedPrompt(DateTime(start.year, start.month, start.day, start.hour, start.minute + minutes[k]), test: tests.contains(k)),
  ];
}

/// The moments still ahead of [now]: the rest of today's window (and of yesterday's, when it runs past midnight)
/// and the next [days] days, oldest first.
List<PlannedPrompt> upcomingPrompts(DateTime now, SharpSettings s, {int days = SharpRule.armDays}) {
  if (!s.on) return const [];
  final today = dayKey(now);
  return [
    for (var d = -1; d <= days; d++)
      for (final p in promptsForDay(addDays(today, d), s))
        if (p.at.isAfter(now)) p,
  ];
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// The median of clock times (minutes after midnight) around the clock: each is taken as the nearest turn of the
/// clock to their circular mean, so 23:40 and 00:20 have 00:00 between them, not 12:00.
int clockMedian(List<int> minutes) {
  var sx = 0.0, sy = 0.0;
  for (final m in minutes) {
    sx += math.cos(m / 1440 * 2 * math.pi);
    sy += math.sin(m / 1440 * 2 * math.pi);
  }
  final mean = (math.atan2(sy, sx) / (2 * math.pi) * 1440 + 1440) % 1440;
  final near = [
    for (final m in minutes) mean + (((m - mean) % 1440 + 2160) % 1440 - 720),
  ];
  return ((_median(near).round() % 1440) + 1440) % 1440;
}

/// The waking window suggested from recorded sleeps ([nights]: each night's first sleep and final wake-up, the
/// last 14 days): from your usual wake-up + 30 min (up to the next half hour) to your usual sleep - 60 min (down
/// to the half hour). 10:00 to 22:00 with fewer than 3 nights or when that leaves no usable window.
(int, int) suggestWindow(List<({DateTime start, DateTime end})> nights) {
  const fallback = (SharpRule.defaultFromMin, SharpRule.defaultUntilMin);
  if (nights.length < 3) return fallback;
  int clock(DateTime t) => t.hour * 60 + t.minute;
  final wake = clockMedian([for (final n in nights) clock(n.end)]);
  final sleep = clockMedian([for (final n in nights) clock(n.start)]);
  final from = (((wake + SharpRule.afterWakeMin + 29) ~/ 30) * 30) % 1440;
  final until = ((((sleep - SharpRule.beforeSleepMin) % 1440 + 1440) % 1440) ~/ 30) * 30;
  return windowOk(from, until) ? (from, until) : fallback;
}
