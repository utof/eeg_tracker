// What the Record tab says about tonight's evening question of the running sleep experiment (DECISIONS 1084). Pure.
import '../trends/days.dart';
import 'store.dart';

/// The question is on the Record tab from this hour until the day ends (04:00): earlier nobody can say "none after
/// noon" or "a late workout" yet. A planning value.
const int eveningFromHour = 17;

enum Tonight {
  /// No line: no experiment runs, it is not evening yet, or tonight is answered.
  nothing,

  /// The one-tap question.
  ask,

  /// The app picks the nights and has not drawn tonight's: the way to the page, where the pick is made.
  pick,
}

/// It is evening by the app's day: from [eveningFromHour] to 04:00.
bool isEvening(DateTime now) => now.hour >= eveningFromHour || now.hour < dayStartHour;

/// What the Record tab shows at [now] for the running experiment [e] (null: none runs).
Tonight tonightAsk(ExperimentLog? e, DateTime now) {
  if (e == null || !e.running || !isEvening(now)) return Tonight.nothing;
  final day = dayKey(now);
  if (day.compareTo(e.plan.start) < 0) return Tonight.nothing;
  final today = e.day(day);
  if (today.answer != null) return Tonight.nothing;
  return e.plan.picked && today.pick == null ? Tonight.pick : Tonight.ask;
}
