// Which estimates to ask about, and when (DECISIONS 862-864). Pure rules over what the store read: no files, no clock.
//
// The queue is every estimate that is over, not answered (a Not sure counts as answered: never asked again), not about
// a stretch already answered or already labelled by you (an Archive tag, a stop-sheet label), at most
// [ConfirmRule.maxAge] old (after two days memory is no better than the detector) and, when short, only hours old.
// A notification holds one batch; when more wait than that, it takes the newest and the ones the detector is least sure
// of, and the rest stay on the in-app card until they are answered or too old. [mayPush] is the one place that says
// when a batch may go out. All planning values (asking.md).
import 'backoff.dart';
import 'estimate.dart';
import 'store.dart';

abstract final class ConfirmRule {
  /// Older estimates are not asked about (the card and the notification); a recording's own batch has no limit.
  static const Duration maxAge = Duration(hours: 48);

  /// Two stretches of one label are the same question when one covers this share of the shorter.
  static const double sameShare = 0.5;

  /// Ask this long after the stretch ended (a walk, a recording), and leave this long between two batches.
  static const Duration afterEvent = Duration(minutes: 10);
  static const Duration betweenBatches = Duration(minutes: 60);

  /// A stretch this long counts as fully "long".
  static const double longMin = 120;

  /// With this many Yes or No answers a kind is no longer short of labels (about 8 per kind before asking mostly
  /// about unsure ones: _local/research labelling note, utof R79).
  static const int enoughLabels = 8;

  // Planning values from research (asking.md), not measured on the owner: reversible starting values.

  /// Notification batches a day, and cards in one.
  static const int pushesPerDay = 2, cardsPerBatch = 4;

  /// "The same day" runs from this hour to the same hour of the next day. A stretch's times are asked about
  /// ("Yes, but the times are off") only on its own day; after that only whether it happened.
  static const int dayStartsHour = 4;

  /// A stretch shorter than [shortStretch] is dropped unasked once it is older than [shortAskWithin].
  static const Duration shortStretch = Duration(minutes: 15), shortAskWithin = Duration(hours: 3);

  /// With more waiting than a batch holds: this many of the newest go in the notification, then the ones the
  /// detector is least sure of; the rest wait on the card.
  static const int keepNewest = 2;

  /// Quiet hours from your real sleep: nights (sleep of [nightAtLeast] or more) of the last [habitDays] days, at
  /// least [habitNights] of them; quiet from the usual bedtime until [quietAfterWaking] after you woke.
  static const Duration nightAtLeast = Duration(hours: 3), quietAfterWaking = Duration(minutes: 30);
  static const int habitDays = 14, habitNights = 3;

  /// A woken-up time counts for "after you woke" this long.
  static const Duration wokeCounts = Duration(hours: 12);
}

/// The day [t] belongs to, as [ConfirmRule.dayStartsHour] cuts them.
DateTime askingDay(DateTime t) {
  final s = t.subtract(const Duration(hours: ConfirmRule.dayStartsHour));
  return DateTime(s.year, s.month, s.day);
}

/// Whether [e]'s start and end are still asked about at [now]: only on the stretch's own day.
bool timesAsked(Estimate e, DateTime now) => askingDay(e.end) == askingDay(now);

/// One question of a batch: the estimate, and why it was picked (`unsure`, `long`, `rare`, `few`).
class Pick {
  const Pick(this.estimate, this.value, this.why);
  final Estimate estimate;
  final double value;
  final String why;
}

/// A stretch you labelled yourself (an Archive tag, a stop-sheet chip) and its word.
typedef Labelled = ({DateTime start, DateTime end, String word});

bool _same(Estimate a, DateTime s, DateTime e) => overlapShare(a.start, a.end, s, e) >= ConfirmRule.sameShare;

/// The open questions, oldest first: see the top of the file. [recording]: only that recording's, of any age, closed
/// or not (the stop sheet: you are looking at that recording now).
List<Estimate> openEstimates(ConfirmState state, DateTime now, {List<Labelled> labelled = const [], String? recording}) {
  final settled = [
    for (final id in state.answers.keys)
      if (state.estimates[id] != null) state.estimates[id]!,
  ];
  final open = <Estimate>[];
  // newest registered first, so a re-scored stretch replaces its older estimate
  for (final e in state.estimates.values.toList().reversed) {
    if (state.answered(e.id) || e.end.isAfter(now)) continue;
    if (recording != null ? e.recording != recording : (state.closed(e.id) || closedWhy(e, state, now) != null)) continue;
    if (settled.any((s) => s.label.sameAs(e.label) && _same(e, s.start, s.end))) continue;
    if (labelled.any((l) => e.label.says(l.word) && _same(e, l.start, l.end))) continue;
    if (open.any((o) => o.label.sameAs(e.label) && _same(e, o.start, o.end))) continue;
    open.add(e);
  }
  return open..sort((a, b) => a.start.compareTo(b.start));
}

/// Why [e] is closed without an answer as of [now], or null: it is answered, already closed, or may still be asked.
/// Too old ([ConfirmRule.maxAge]): `expired` when it went out in a notification, else `never_seen`. A short stretch
/// that is hours old: `short_and_old` (nobody remembers a ten-minute doze from this morning).
WhyNot? closedWhy(Estimate e, ConfirmState state, DateTime now) {
  if (state.answered(e.id) || state.closed(e.id) || e.end.isAfter(now)) return null;
  final age = now.difference(e.end);
  if (age > ConfirmRule.maxAge) return state.notified.contains(e.id) ? WhyNot.expired : WhyNot.neverSeen;
  if (e.length < ConfirmRule.shortStretch && age > ConfirmRule.shortAskWithin) return WhyNot.shortAndOld;
  return null;
}

/// How much an answer to [e] is worth, and the main reason: the first that holds of `unsure` (the detector is under
/// 60 % sure), `long` (an hour or more), `rare` (at most every second estimate is of this kind), else `few` (the kind
/// has few answers yet).
Pick valueOf(Estimate e, ConfirmState state) {
  final unsure = 1 - (e.confidence ?? 0.5);
  final long = (e.length.inSeconds / 60 / ConfirmRule.longMin).clamp(0.0, 1.0);
  final rare = 1 / state.estimates.values.where((x) => x.label == e.label).length.clamp(1, 1 << 30);
  final few = (1 - state.labelsOf(e.label) / ConfirmRule.enoughLabels).clamp(0.0, 1.0);
  final why = unsure > 0.4 ? 'unsure' : (long >= 0.5 ? 'long' : (rare >= 0.5 ? 'rare' : 'few'));
  return Pick(e, unsure + long + rare + few, why);
}

int _newerFirst(Estimate a, Estimate b) {
  final t = b.end.compareTo(a.end);
  return t != 0 ? t : a.id.compareTo(b.id);
}

/// Which of [open] are kept when more wait than [max]: the [ConfirmRule.keepNewest] newest, then the ones the detector
/// is least sure of (0.5 when it does not say; ties: the newer). With [max] or fewer, all of them, each with its
/// reason from [valueOf]. In time order.
List<Pick> pickBatch(List<Estimate> open, ConfirmState state, int max) {
  if (open.length <= max) return [for (final e in open) valueOf(e, state)]..sort((a, b) => a.estimate.start.compareTo(b.estimate.start));
  final byAge = [...open]..sort(_newerFirst);
  final newest = byAge.take(ConfirmRule.keepNewest.clamp(0, max)).toList();
  final rest = byAge.skip(newest.length).toList()
    ..sort((a, b) {
      final c = (a.confidence ?? 0.5).compareTo(b.confidence ?? 0.5);
      return c != 0 ? c : _newerFirst(a, b);
    });
  return [
    for (final e in newest) Pick(e, valueOf(e, state).value, 'newest'),
    for (final e in rest.take(max - newest.length)) Pick(e, valueOf(e, state).value, 'unsure'),
  ]..sort((a, b) => a.estimate.start.compareTo(b.estimate.start));
}

/// The in-app card: every open question, in time order. A batch's choice ([pickBatch]) is only what a notification
/// takes; the others wait here until they are answered or too old. It never counts against the day's pushes: a batch
/// the phone may not push is still here when you open the app.
List<Pick> cardBatch(ConfirmState state, ConfirmSettings settings, DateTime now, {List<Labelled> labelled = const []}) {
  if (!settings.on) return const [];
  final open = openEstimates(state, now, labelled: labelled);
  final chosen = {for (final p in pickBatch(open, state, settings.perBatch)) p.estimate.id: p};
  return [for (final e in open) chosen[e.id] ?? valueOf(e, state)]..sort((a, b) => a.estimate.start.compareTo(b.estimate.start));
}

/// The batch for one recording (the stop sheet's "What was this recording?"): every open question of it, whatever its
/// age, the switch or the quiet hours, since you are looking at that recording now. It never counts against the
/// day's pushes either.
List<Pick> recordingBatch(ConfirmState state, String recording, DateTime now, {List<Labelled> labelled = const [], int max = 5}) =>
    pickBatch(openEstimates(state, now, labelled: labelled, recording: recording), state, max);

/// The next notification batch: of the open questions, the ones [pickBatch] takes that were in no notification yet.
List<Pick> notificationBatch(ConfirmState state, ConfirmSettings settings, DateTime now, {List<Labelled> labelled = const []}) => settings.on
    ? [
        for (final p in pickBatch(openEstimates(state, now, labelled: labelled), state, settings.perBatch))
          if (!state.notified.contains(p.estimate.id)) p,
      ]
    : const [];

/// When you usually go to bed and get up, minutes of the day, from [nights] of your own nights.
typedef SleepHabit = ({int bedMin, int wakeMin, int nights});

int _minuteOfDay(DateTime t) => t.hour * 60 + t.minute;

int _median(List<int> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : ((s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2).round();
}

bool _night(Estimate e, ConfirmState state) =>
    (e.label.id == 'asleep' || e.label.id == 'night_sleep') && e.length >= ConfirmRule.nightAtLeast && state.answers[e.id]?.answer != Answer.no;

/// Your sleep habit as of [now], from the nights the app itself found (sleep estimates of three hours or more that
/// you did not answer No to); null with fewer than [ConfirmRule.habitNights] in the last [ConfirmRule.habitDays] days.
SleepHabit? sleepHabit(ConfirmState state, DateTime now) {
  final nights = [
    for (final e in state.estimates.values)
      if (_night(e, state) && !e.end.isAfter(now) && now.difference(e.end) <= const Duration(days: ConfirmRule.habitDays)) e,
  ];
  if (nights.length < ConfirmRule.habitNights) return null;
  // bedtimes straddle midnight: count them from noon
  final bed = (_median([for (final e in nights) (_minuteOfDay(e.start) + 720) % 1440]) + 720) % 1440;
  return (bedMin: bed, wakeMin: _median([for (final e in nights) _minuteOfDay(e.end)]), nights: nights.length);
}

/// The quiet hours in force at [t], minutes of the day, and whether they come from your sleep. From your sleep: the
/// usual bedtime until [ConfirmRule.quietAfterWaking] after you woke (today's waking when the app saw it, else the
/// usual one). Otherwise, and as your own override in Settings, the fixed hours.
({int startMin, int endMin, bool fromSleep}) quietHours(ConfirmState state, ConfirmSettings settings, DateTime t) {
  final habit = settings.quietFromSleep ? sleepHabit(state, t) : null;
  if (habit == null) return (startMin: settings.quietStartMin, endMin: settings.quietEndMin, fromSleep: false);
  DateTime? woke;
  for (final e in state.estimates.values) {
    if (_night(e, state) && !e.end.isAfter(t) && t.difference(e.end) <= ConfirmRule.wokeCounts && (woke == null || e.end.isAfter(woke))) woke = e.end;
  }
  final wake = woke == null ? habit.wakeMin : _minuteOfDay(woke);
  return (startMin: habit.bedMin, endMin: (wake + ConfirmRule.quietAfterWaking.inMinutes) % 1440, fromSleep: true);
}

/// The other app's say (utof_tracker's check-ins): given a moment, null when a push then is fine by it, else the
/// moment to try instead. Nothing provides one yet: the link between the two apps does not exist (HANDOFF, "the
/// cross-app hook").
typedef OtherAsker = DateTime? Function(DateTime at);

/// May a batch be pushed at [at]? Yes ([ok]), or not before [retry], or not at all ([retry] null).
class PushAnswer {
  const PushAnswer.yes() : ok = true, retry = null, why = '';
  const PushAnswer.wait(DateTime this.retry, this.why) : ok = false;
  const PushAnswer.never(this.why) : ok = false, retry = null;
  final bool ok;
  final DateTime? retry;
  final String why;
}

/// The one question every push asks: "may I push now?". All the rules are here and only here: the switch, a pause, an
/// hour between batches, the quiet hours, a skipped hour, the day's count, and last the other app's say ([other]).
PushAnswer mayPush(DateTime at, ConfirmState state, ConfirmSettings settings, {Backoff? backoff, OtherAsker? other}) {
  if (!settings.on) return const PushAnswer.never('switched off');
  final b = backoff ?? backoffOf(state, at, maxPerDay: settings.perDay);
  if (b.perDay <= 0) return b.pausedUntil == null ? const PushAnswer.never('paused') : PushAnswer.wait(b.pausedUntil!, 'paused');
  if (state.batches.isNotEmpty) {
    final next = state.batches.last.add(ConfirmRule.betweenBatches);
    if (next.isAfter(at)) return PushAnswer.wait(next, 'an hour between batches');
  }
  final q = quietHours(state, settings, at);
  final m = _minuteOfDay(at);
  if (q.startMin != q.endMin && (q.startMin < q.endMin ? m >= q.startMin && m < q.endMin : m >= q.startMin || m < q.endMin)) {
    var end = DateTime(at.year, at.month, at.day, q.endMin ~/ 60, q.endMin % 60);
    if (!end.isAfter(at)) end = DateTime(at.year, at.month, at.day + 1, q.endMin ~/ 60, q.endMin % 60);
    return PushAnswer.wait(end, 'quiet hours');
  }
  if (b.skipHours.containsKey(at.hour)) return PushAnswer.wait(DateTime(at.year, at.month, at.day, at.hour + 1), 'this hour is skipped');
  final day = DateTime(at.year, at.month, at.day);
  final thatDay = state.batches.where((x) => DateTime(x.year, x.month, x.day) == day).length;
  final allowed = b.perDay < settings.perDay ? b.perDay : settings.perDay;
  if (thatDay >= allowed) return PushAnswer.wait(DateTime(at.year, at.month, at.day + 1), 'today\'s pushes are used up');
  final wait = other?.call(at);
  if (wait != null && wait.isAfter(at)) return PushAnswer.wait(wait, 'the other app is asking');
  return const PushAnswer.yes();
}

/// When [batch] should go out as a notification, or null (nothing to ask, switched off). Soon after the newest stretch
/// ended, then the first moment [mayPush] allows: tomorrow when today's pushes are used up.
DateTime? planTime(List<Pick> batch, ConfirmState state, ConfirmSettings settings, DateTime now, {Backoff? backoff, OtherAsker? other}) {
  if (!settings.on || batch.isEmpty) return null;
  var t = now;
  final newest = batch.map((p) => p.estimate.end).reduce((a, b) => a.isAfter(b) ? a : b).add(ConfirmRule.afterEvent);
  if (newest.isAfter(t)) t = newest;
  // a batch that could only go out when its questions are too old to ask is not planned at all
  final tooLate = batch.map((p) => p.estimate.end).reduce((a, b) => a.isAfter(b) ? a : b).add(ConfirmRule.maxAge);
  for (var i = 0; i < 40; i++) {
    if (t.isAfter(tooLate)) return null;
    final a = mayPush(t, state, settings, backoff: backoff, other: other);
    if (a.ok) return t;
    if (a.retry == null || !a.retry!.isAfter(t)) return null;
    t = a.retry!;
  }
  return null;
}
