// Backing off by rule (asking.md): the app asks less when the answers say it asks too much. Worked out from what the
// files already hold (the batches that went out, what the phone did with them, the answers); the only thing written
// down is each step with its reason (`backoff` lines of asks.jsonl), which a pause needs to end. Pure rules: no files,
// no clock. Every number is a planning value from research, not measured on the owner (DECISIONS 972).
import 'store.dart';

abstract final class BackoffRule {
  /// The answer rate is taken over the batches pushed in this long.
  static const Duration window = Duration(days: 7);

  /// Under this share of pushed batches answered: one push a day. Under [pauseUnder]: none for [pauseFor], then one a
  /// day again.
  static const double oneADayUnder = 0.5, pauseUnder = 0.25;
  static const Duration pauseFor = Duration(days: 7);

  /// Fewer judged batches than this say nothing yet.
  static const int minBatches = 4;

  /// A batch nobody answered is judged once it is this old (the notification is gone by then).
  static const Duration settled = Duration(hours: 6);

  /// This many batches in a row swiped away in one hour of the day: that hour is skipped for [skipHourFor].
  static const int dismissalsInARow = 2;
  static const Duration skipHourFor = Duration(days: 7);

  /// This many batches in a row answered all Yes with every card after the first in under [autopilotSeconds]: the
  /// next batch is blind cards. A batch with fewer than [timedCards] answers cannot be timed and is passed over.
  static const int autopilotBatches = 10;
  static const double autopilotSeconds = 1.5;
  static const int timedCards = 2;
}

/// What the rules allow now.
class Backoff {
  const Backoff({required this.perDay, this.pausedUntil, this.startsPause = false, this.skipHours = const {}, this.blindNext = false, this.rate, this.judged = 0, this.reason = ''});

  /// Pushed batches a day: the most the settings allow, 1, or 0 while paused.
  final int perDay;

  /// No pushes until then (questions wait in the app, with its badge).
  final DateTime? pausedUntil;

  /// The pause begins now: write it down ([ConfirmStore.logBackoff]) so it can end.
  final bool startsPause;

  /// Hours of the day (0-23) with no pushes, and until when.
  final Map<int, DateTime> skipHours;

  /// The next batch is blind cards.
  final bool blindNext;

  /// The share of judged batches that were answered, and how many were judged; null with too few.
  final double? rate;
  final int judged;

  /// In plain words, for the log.
  final String reason;

  /// `pause`, `one_a_day` or `normal`.
  String get step => perDay == 0 ? 'pause' : (reason.isEmpty ? 'normal' : 'one_a_day');
}

bool _answered(Push p, ConfirmState s) => p.ids.any(s.answered);

/// Whether [p] was swiped away and then left alone.
bool dismissed(Push p, ConfirmState s) => !_answered(p, s) && s.events.any((e) => e.event == 'dismissed' && e.batch == p.at);

/// All Yes, and fast: null when the batch cannot be timed.
bool? autopilot(Push p, ConfirmState s) {
  final got = [for (final id in p.ids) ?s.answers[id]]..sort((a, b) => a.at.compareTo(b.at));
  if (got.length < BackoffRule.timedCards) return null;
  return got.every((a) => a.answer == Answer.yes && !a.timesConfirmed) &&
      got.skip(1).every((a) => a.seconds != null && a.seconds! < BackoffRule.autopilotSeconds);
}

/// The rules as of [now]; [maxPerDay] is the settings' pushes a day.
Backoff backoffOf(ConfirmState state, DateTime now, {int maxPerDay = 2}) {
  final skip = <int, DateTime>{};
  for (var h = 0; h < 24; h++) {
    final inHour = [for (final p in state.pushes) if (p.at.hour == h && !p.at.isAfter(now)) p];
    if (inHour.length < BackoffRule.dismissalsInARow) continue;
    final last = inHour.sublist(inHour.length - BackoffRule.dismissalsInARow);
    final until = last.last.at.add(BackoffRule.skipHourFor);
    if (last.every((p) => dismissed(p, state)) && until.isAfter(now)) skip[h] = until;
  }
  final timed = [for (final p in state.pushes) if (autopilot(p, state) != null) p];
  final blind =
      timed.length >= BackoffRule.autopilotBatches && timed.sublist(timed.length - BackoffRule.autopilotBatches).every((p) => autopilot(p, state)!);

  final pauses = [for (final e in state.events) if (e.event == 'backoff' && e.step == 'pause' && e.until != null) e.until!]..sort();
  final lastPause = pauses.isEmpty ? null : pauses.last;
  if (lastPause != null && lastPause.isAfter(now)) {
    return Backoff(perDay: 0, pausedUntil: lastPause, skipHours: skip, blindNext: blind, reason: 'paused: few batches were answered');
  }
  var from = now.subtract(BackoffRule.window);
  if (lastPause != null && lastPause.isAfter(from)) from = lastPause;
  final judged = [
    for (final p in state.pushes)
      if (!p.at.isBefore(from) && !p.at.isAfter(now) && (_answered(p, state) || now.difference(p.at) >= BackoffRule.settled)) p,
  ];
  if (judged.length < BackoffRule.minBatches) {
    // after a pause: one a day until enough batches say how it goes
    final retry = lastPause != null && now.difference(lastPause) < BackoffRule.window;
    return Backoff(perDay: retry ? 1 : maxPerDay, skipHours: skip, blindNext: blind, judged: judged.length, reason: retry ? 'trying again after a pause' : '');
  }
  final rate = judged.where((p) => _answered(p, state)).length / judged.length;
  final pct = '${(rate * 100).round()} % of ${judged.length} batches answered in 7 days';
  if (rate < BackoffRule.pauseUnder) {
    return Backoff(perDay: 0, pausedUntil: now.add(BackoffRule.pauseFor), startsPause: true, skipHours: skip, blindNext: blind, rate: rate, judged: judged.length, reason: pct);
  }
  if (rate < BackoffRule.oneADayUnder) return Backoff(perDay: 1, skipHours: skip, blindNext: blind, rate: rate, judged: judged.length, reason: pct);
  return Backoff(perDay: maxPerDay, skipHours: skip, blindNext: blind, rate: rate, judged: judged.length);
}
