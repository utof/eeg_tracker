// The optional evening reminder of a sleep experiment (DECISIONS 1085). Pure: when it rings and for which evenings,
// worked out again the same way whenever it is needed.
//
// - Off until switched on from the experiment's page (a `reminder` line of its log).
// - One a day at most: 45 to 59 minutes before your usual bedtime (the middle of the last 14 days' recorded sleeps,
//   as the study reminders work theirs out); 22:15 with fewer than 3 recorded nights. Never outside the waking hours
//   the other reminders keep to.
// - Only for an evening that is still unanswered: an answer on any page takes tonight's away. When the app picks the
//   nights, only an evening whose pick was drawn has a question.
// - It goes in the phone's one list of reminders (SharpPrompts.kt), so that list's rules hold: none while a recording
//   runs (so never during a sleep stretch) or a session runs, none when it would come over an hour late, and it goes
//   away by itself after an hour.
import '../sharp/schedule.dart';
import '../trends/days.dart';
import 'store.dart';

/// Planning values.
abstract final class ReminderRule {
  /// This long before your usual bedtime, rounded down to [roundMin].
  static const int beforeBedMin = 45, roundMin = 15;

  /// With fewer than 3 recorded nights in the last 14 days.
  static const int defaultMin = 22 * 60 + 15;

  static const int armDays = SharpRule.armDays;
}

bool _inWindow(int t, int from, int until) => ((t - from) % 1440 + 1440) % 1440 <= windowLength(from, until);

/// The minute of the day the reminder rings at. [nights]: each night's first sleep and final wake-up of the last 14
/// days; [window]: the waking hours (from, until) it must stay inside.
int reminderMinute(List<({DateTime start, DateTime end})> nights, (int, int) window) {
  var t = ReminderRule.defaultMin;
  if (nights.length >= 3) {
    final bed = clockMedian([for (final n in nights) n.start.hour * 60 + n.start.minute]);
    t = ((((bed - ReminderRule.beforeBedMin) % 1440 + 1440) % 1440) ~/ ReminderRule.roundMin) * ReminderRule.roundMin;
  }
  final (from, until) = window;
  if (_inWindow(t, from, until)) return t;
  final toFrom = ((from - t) % 1440 + 1440) % 1440, toUntil = ((t - until) % 1440 + 1440) % 1440;
  return toFrom <= toUntil ? from : until;
}

/// The reminders still ahead of [now] for the running experiment [e] (null: none runs), at [minute] of each day,
/// oldest first.
List<PlannedPrompt> upcomingExperimentReminders(DateTime now, ExperimentLog? e, int minute, {int days = ReminderRule.armDays}) {
  if (e == null || !e.running || !e.remind) return const [];
  final today = dayKey(now);
  final out = <PlannedPrompt>[];
  for (var d = -1; d <= days; d++) {
    final day = addDays(today, d);
    if (day.compareTo(e.plan.start) < 0) continue;
    final at = windowStart(day, minute);
    final log = e.day(day);
    if (!at.isAfter(now) || log.answer != null) continue;
    if (e.plan.picked && log.pick == null) continue;
    out.add(PlannedPrompt(at, kind: PromptKind.sleepExperiment));
  }
  return out;
}
