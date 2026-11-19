// Everything the study reminders page shows, from the files (DECISIONS rows 400-401). Pure: the screen reads the
// files and the phone's state, this puts them together, the view lays them out.
import '../sharp/page.dart' show recentNights;
import '../sharp/schedule.dart';
import '../sharp/store.dart' show PromptEvent, PromptEventKind;
import '../sleep/report.dart' show SleepReport;
import '../trends/days.dart';
import 'schedule.dart';

/// The waking hours the reminders keep to: the sharp-hours window when one was saved there (the owner's own quiet
/// hours), else the one suggested from 3 or more recorded nights; with neither, the whole day (nothing is known
/// to keep to, so the plain 21:00 and 08:30 stand).
(int, int) studyWindow(SharpSettings? sharp, List<SleepReport> reports, DateTime now) {
  if (sharp != null) return (sharp.fromMin, sharp.untilMin);
  final nights = recentNights(reports, now);
  return nights.length < 3 ? (0, 1439) : suggestWindow(nights);
}

/// The times in use now, from the settings, the sleep and the waking hours.
StudyTimes timesFor(StudySettings s, SharpSettings? sharp, List<SleepReport> reports, DateTime now) =>
    studyTimes(s, suggestTimes(recentNights(reports, now)), studyWindow(sharp, reports, now));

/// What happened to the reminders in the last 7 days, from the Android side's log: each planned reminder's first
/// event. A reminder with none never rang (the phone held it back).
class StudyReach {
  const StudyReach({this.shown = 0, this.skipped = 0, this.late = 0});
  final int shown, skipped, late;
  int get arrived => shown + skipped + late;
}

StudyReach reachOfStudy(List<PromptEvent> events, DateTime now, {int days = 7}) {
  final since = now.subtract(Duration(days: days));
  final first = <int, PromptEventKind>{};
  for (final e in events) {
    if (e.planned.isBefore(since) || e.planned.isAfter(now)) continue;
    if (e.event == PromptEventKind.shown || e.event == PromptEventKind.skipped || e.event == PromptEventKind.late) {
      first.putIfAbsent(e.planned.millisecondsSinceEpoch, () => e.event);
    }
  }
  int n(PromptEventKind k) => first.values.where((x) => x == k).length;
  return StudyReach(
    shown: n(PromptEventKind.shown),
    skipped: n(PromptEventKind.skipped),
    late: n(PromptEventKind.late),
  );
}

class StudyPageModel {
  const StudyPageModel({
    required this.now,
    required this.settings,
    required this.saved,
    required this.times,
    required this.suggested,
    required this.nights,
    required this.window,
    required this.windowFromSharp,
    required this.today,
    required this.evenings,
    required this.studied,
    required this.recalls,
    required this.reach,
    this.notificationsOn = true,
    this.xiaomi = false,
  });

  final DateTime now;
  final StudySettings settings;

  /// A settings file exists (the reminders were switched on or off at least once).
  final bool saved;
  final StudyTimes times;

  /// What your sleep alone gives (before the waking hours move it), and how many recorded nights of the last 14
  /// days it came from (under 3: the plain 21:00 and 08:30).
  final Suggested suggested;
  final int nights;

  /// The waking hours the reminders keep to, and whether they are the sharp-hours window.
  final (int, int) window;
  final bool windowFromSharp;

  /// Today's answers (the 04:00 day), oldest first.
  final List<StudyAnswer> today;

  /// The last 14 days: evenings answered, those answered "yes", and the morning answers by word.
  final int evenings, studied;
  final Map<Recall, int> recalls;
  final StudyReach reach;
  final bool notificationsOn, xiaomi;

  bool get on => settings.on;

  /// The times come from your recorded sleep.
  bool get fromSleep => nights >= 3;

  /// An automatic time was moved to keep inside the waking hours.
  bool get eveningMoved => times.eveningAuto && times.evening != suggested.evening;
  bool get morningMoved => times.morningAuto && times.morning != suggested.morning;
  int get recallCount => recalls.values.fold(0, (a, b) => a + b);
  StudyAnswer? get eveningToday => today.where((a) => a.isEvening).lastOrNull;
  StudyAnswer? get morningToday => today.where((a) => !a.isEvening).lastOrNull;
}

StudyPageModel buildStudyPage({
  required StudySettings? saved,
  required SharpSettings? sharp,
  required List<StudyAnswer> answers,
  required List<PromptEvent> events,
  required List<SleepReport> reports,
  required DateTime now,
  bool notificationsOn = true,
  bool xiaomi = false,
}) {
  final settings = saved ?? const StudySettings(on: false);
  final today = dayKey(now);
  final recent = [
    for (final a in answers)
      if (daysBetween(a.day, today) < 14 && daysBetween(a.day, today) >= 0) a,
  ];
  return StudyPageModel(
    now: now,
    settings: settings,
    saved: saved != null,
    times: timesFor(settings, sharp, reports, now),
    suggested: suggestTimes(recentNights(reports, now)),
    nights: recentNights(reports, now).length,
    window: studyWindow(sharp, reports, now),
    windowFromSharp: sharp != null,
    today: [
      for (final a in answers)
        if (a.day == today) a,
    ]..sort((a, b) => a.at.compareTo(b.at)),
    evenings: recent.where((a) => a.isEvening).length,
    studied: recent.where((a) => a.isEvening && a.studied == true).length,
    recalls: {for (final r in Recall.values) r: recent.where((a) => !a.isEvening && a.recall == r).length},
    reach: reachOfStudy(events, now),
    notificationsOn: notificationsOn,
    xiaomi: xiaomi,
  );
}

/// The switch's line on the page and in Settings.
String studyStatus(StudyPageModel m) {
  if (m.on) return 'On: evening ${clockText(m.times.evening)}, morning ${clockText(m.times.morning)}.';
  return m.saved
      ? 'Off. Nothing is asked; your answers so far are kept.'
      : 'Off. Nothing is asked until you switch it on.';
}
