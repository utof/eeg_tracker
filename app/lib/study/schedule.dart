// The study reminders' schedule (ROADMAP "Evening study, morning review"; DECISIONS rows 400-401). Pure: when to
// ring, worked out again the same way whenever it is needed.
//
// - One reminder in the evening, 1 to 2 hours before your usual bedtime ("Good time to learn something you want
//   to keep"), and one in the morning, 30 to 60 minutes after your usual wake-up ("Try to recall what you studied
//   last night, before looking"). Usual = the middle of the last 14 days' recorded sleeps, as the sharp-hours
//   window is worked out; with fewer than 3 recorded nights, 21:00 and 08:30.
// - Both can be set by hand instead. Neither rings in the quiet hours: automatic times are moved inside the waking
//   hours, a time set by hand is refused outside them. The waking hours are the sharp-hours window when one was
//   saved there, else the one suggested from the sleep.
// - A reminder that is already answered is not rung again, and a morning reminder is dropped when you said "no" to
//   studying the evening before: nothing to recall.
// - The Android side (SharpPrompts.kt) only rings the moments it is given, and skips one during a night recording
//   or a session, like the sharp-hours questions.
import '../sharp/schedule.dart';
import '../trends/days.dart';

/// Planning values (DECISIONS row 400).
abstract final class StudyRule {
  /// The evening reminder this long before your usual bedtime, rounded down to [roundMin] (so 90 to 104 minutes).
  static const int beforeBedMin = 90;

  /// The morning reminder this long after your usual wake-up, rounded up to [roundMin] (so 45 to 59 minutes).
  static const int afterWakeMin = 45;
  static const int roundMin = 15;

  /// With fewer than 3 recorded nights in the last 14 days.
  static const int defaultEveningMin = 21 * 60, defaultMorningMin = 8 * 60 + 30;

  /// How many days ahead the phone is given reminders (re-armed at every app start and every answer).
  static const int armDays = SharpRule.armDays;
}

/// How much of what was studied came back: the morning's one tap. Values 1 to 3 for the day numbers.
enum Recall {
  little('little', 1, 'A little'),
  some('some', 2, 'Some'),
  well('well', 3, 'Well');

  const Recall(this.wire, this.value, this.label);
  final String wire, label;
  final int value;

  static Recall? fromWire(Object? s) => values.where((r) => r.wire == s).firstOrNull;
}

/// The reminders' own settings. [eveningMin] and [morningMin] are minutes after midnight when set by hand, null
/// while the time follows your sleep.
class StudySettings {
  const StudySettings({required this.on, this.eveningMin, this.morningMin, this.firstOn, this.changed});

  /// The owner's switch; off until switched on.
  final bool on;
  final int? eveningMin, morningMin;

  /// When the reminders were first switched on, and when the switch or a time last changed.
  final DateTime? firstOn, changed;

  StudySettings copyWith({
    bool? on,
    int? eveningMin,
    int? morningMin,
    bool autoEvening = false,
    bool autoMorning = false,
    DateTime? firstOn,
    DateTime? changed,
  }) => StudySettings(
    on: on ?? this.on,
    eveningMin: autoEvening ? null : (eveningMin ?? this.eveningMin),
    morningMin: autoMorning ? null : (morningMin ?? this.morningMin),
    firstOn: firstOn ?? this.firstOn,
    changed: changed ?? this.changed,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'on': on,
    'evening': eveningMin == null ? null : clockText(eveningMin!),
    'morning': morningMin == null ? null : clockText(morningMin!),
    'first_on': firstOn?.toIso8601String(),
    'changed': changed?.toIso8601String(),
  };

  static DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

  /// Null for anything that is not a settings file this version wrote.
  static StudySettings? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1 || j['on'] is! bool) return null;
    final evening = j['evening'], morning = j['morning'];
    final e = evening == null ? null : parseClock(evening), m = morning == null ? null : parseClock(morning);
    if ((evening != null && e == null) || (morning != null && m == null)) return null;
    final first = _time(j['first_on']), changed = _time(j['changed']);
    if ((j['first_on'] != null && first == null) || (j['changed'] != null && changed == null)) return null;
    return StudySettings(on: j['on'] as bool, eveningMin: e, morningMin: m, firstOn: first, changed: changed);
  }
}

/// What the owner said at one reminder: tonight's "studied: yes or no", or the morning's recall.
class StudyAnswer {
  const StudyAnswer._(this.at, this.kind, this.studied, this.recall, this.prompt, this.shown);

  factory StudyAnswer.evening({required DateTime at, required bool studied, DateTime? prompt, DateTime? shown}) =>
      StudyAnswer._(at, PromptKind.studyEvening, studied, null, prompt, shown);

  factory StudyAnswer.morning({required DateTime at, required Recall recall, DateTime? prompt, DateTime? shown}) =>
      StudyAnswer._(at, PromptKind.studyMorning, null, recall, prompt, shown);

  /// When it was answered.
  final DateTime at;

  /// [PromptKind.studyEvening] (with [studied]) or [PromptKind.studyMorning] (with [recall]).
  final PromptKind kind;
  final bool? studied;
  final Recall? recall;

  /// The planned reminder it answers and when its notification appeared; both null when logged from the page.
  final DateTime? prompt, shown;

  bool get isEvening => kind == PromptKind.studyEvening;

  /// The 04:00-04:00 day it belongs to.
  String get day => dayKey(at);
}

/// The times that follow your sleep (evening and morning, minutes after midnight).
typedef Suggested = ({int evening, int morning});

/// The times that follow your sleep: [nights] are each night's first sleep and final wake-up of the last 14 days.
Suggested suggestTimes(List<({DateTime start, DateTime end})> nights) {
  if (nights.length < 3) return (evening: StudyRule.defaultEveningMin, morning: StudyRule.defaultMorningMin);
  int clock(DateTime t) => t.hour * 60 + t.minute;
  final bed = clockMedian([for (final n in nights) clock(n.start)]);
  final wake = clockMedian([for (final n in nights) clock(n.end)]);
  const q = StudyRule.roundMin;
  final evening = ((((bed - StudyRule.beforeBedMin) % 1440 + 1440) % 1440) ~/ q) * q;
  final morning = ((((wake + StudyRule.afterWakeMin + q - 1) ~/ q) * q) % 1440 + 1440) % 1440;
  return (evening: evening, morning: morning);
}

/// [t] is inside the waking hours [from] to [until] (past midnight when [until] is earlier).
bool timeInWindow(int t, int from, int until) => ((t - from) % 1440 + 1440) % 1440 <= windowLength(from, until);

/// The nearest end of the waking hours to a [t] outside them.
int _clamp(int t, int from, int until) {
  if (timeInWindow(t, from, until)) return t;
  final toFrom = ((from - t) % 1440 + 1440) % 1440, toUntil = ((t - until) % 1440 + 1440) % 1440;
  return toFrom <= toUntil ? from : until;
}

/// The times the reminders ring at, and whether each follows your sleep.
typedef StudyTimes = ({int evening, int morning, bool eveningAuto, bool morningAuto});

/// The times in use: those set by hand, else [suggested] moved inside the waking hours [window].
StudyTimes studyTimes(StudySettings s, Suggested suggested, (int, int) window) {
  final (from, until) = window;
  return (
    evening: s.eveningMin ?? _clamp(suggested.evening, from, until),
    morning: s.morningMin ?? _clamp(suggested.morning, from, until),
    eveningAuto: s.eveningMin == null,
    morningAuto: s.morningMin == null,
  );
}

/// The reminders still ahead of [now]: the rest of today (and of yesterday's day when a time is after midnight)
/// and the next [days] days, oldest first. Dropped: what [answers] already answered, and the morning after a "no".
List<PlannedPrompt> upcomingStudy(
  DateTime now,
  StudySettings s,
  StudyTimes times,
  List<StudyAnswer> answers, {
  int days = StudyRule.armDays,
}) {
  if (!s.on) return const [];
  final today = dayKey(now);
  final evenings = <String, StudyAnswer>{}, mornings = <String, StudyAnswer>{};
  for (final a in [...answers]..sort((x, y) => x.at.compareTo(y.at))) {
    (a.isEvening ? evenings : mornings)[a.day] = a; // the latest of a day
  }
  final out = <PlannedPrompt>[];
  for (var d = -1; d <= days; d++) {
    final day = addDays(today, d);
    final evening = windowStart(day, times.evening), morning = windowStart(day, times.morning);
    if (evening.isAfter(now) && !evenings.containsKey(day)) {
      out.add(PlannedPrompt(evening, kind: PromptKind.studyEvening));
    }
    final said = evenings[addDays(day, -1)];
    if (morning.isAfter(now) && !mornings.containsKey(day) && said?.studied != false) {
      out.add(PlannedPrompt(morning, kind: PromptKind.studyMorning));
    }
  }
  return out..sort((a, b) => a.at.compareTo(b.at));
}
