// Which estimates to ask about, and when (DECISIONS 862-864). Pure rules over what the store read: no files, no clock.
//
// The queue is every estimate that is over, not answered (a Not sure counts as answered: never asked again), not about
// a stretch already answered or already labelled by you (an Archive tag, a stop-sheet label), and at most
// [ConfirmRule.maxAge] old: after two days memory is no better than the detector. A batch takes the most valuable few:
// the ones the detector is unsure of, long ones, rare kinds and kinds with few answers so far. All planning values.
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
}

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

/// The open questions, oldest first: see the top of the file. [recording]: only that recording's, of any age.
List<Estimate> openEstimates(ConfirmState state, DateTime now, {List<Labelled> labelled = const [], String? recording}) {
  final settled = [
    for (final id in state.answers.keys)
      if (state.estimates[id] != null) state.estimates[id]!,
  ];
  final open = <Estimate>[];
  // newest registered first, so a re-scored stretch replaces its older estimate
  for (final e in state.estimates.values.toList().reversed) {
    if (state.answered(e.id) || e.end.isAfter(now)) continue;
    if (recording == null && state.closed(e.id)) continue;
    if (recording != null ? e.recording != recording : now.difference(e.end) > ConfirmRule.maxAge) continue;
    if (settled.any((s) => s.label.sameAs(e.label) && _same(e, s.start, s.end))) continue;
    if (labelled.any((l) => e.label.says(l.word) && _same(e, l.start, l.end))) continue;
    if (open.any((o) => o.label.sameAs(e.label) && _same(e, o.start, o.end))) continue;
    open.add(e);
  }
  return open..sort((a, b) => a.start.compareTo(b.start));
}

/// Why [e] is closed without an answer as of [now], or null: it is answered, already closed, or may still be asked.
/// Too old ([ConfirmRule.maxAge]): `expired` when it went out in a notification, else `never_seen`.
WhyNot? closedWhy(Estimate e, ConfirmState state, DateTime now) {
  if (state.answered(e.id) || state.closed(e.id) || e.end.isAfter(now)) return null;
  if (now.difference(e.end) > ConfirmRule.maxAge) return state.notified.contains(e.id) ? WhyNot.expired : WhyNot.neverSeen;
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

/// Up to [max] of [open] by value (ties: the later one, then the id), shown in time order.
List<Pick> pickBatch(List<Estimate> open, ConfirmState state, int max) {
  final picks = [for (final e in open) valueOf(e, state)]
    ..sort((a, b) {
      final v = b.value.compareTo(a.value);
      if (v != 0) return v;
      final t = b.estimate.end.compareTo(a.estimate.end);
      return t != 0 ? t : a.estimate.id.compareTo(b.estimate.id);
    });
  return picks.take(max).toList()..sort((a, b) => a.estimate.start.compareTo(b.estimate.start));
}

/// The in-app card's batch: the most valuable open questions.
List<Pick> cardBatch(ConfirmState state, ConfirmSettings settings, DateTime now, {List<Labelled> labelled = const []}) =>
    settings.on ? pickBatch(openEstimates(state, now, labelled: labelled), state, settings.perBatch) : const [];

/// The batch for one recording (the stop sheet's "What was this recording?"): every open question of it, whatever its
/// age, the switch or the quiet hours, since you are looking at that recording now.
List<Pick> recordingBatch(ConfirmState state, String recording, DateTime now, {List<Labelled> labelled = const [], int max = 5}) =>
    pickBatch(openEstimates(state, now, labelled: labelled, recording: recording), state, max);

/// The next notification batch: open questions that were in no notification yet.
List<Pick> notificationBatch(ConfirmState state, ConfirmSettings settings, DateTime now, {List<Labelled> labelled = const []}) {
  if (!settings.on) return const [];
  final open = [
    for (final e in openEstimates(state, now, labelled: labelled))
      if (!state.notified.contains(e.id)) e,
  ];
  return pickBatch(open, state, settings.perBatch);
}

bool _quiet(ConfirmSettings s, DateTime t) {
  final m = t.hour * 60 + t.minute, a = s.quietStartMin, b = s.quietEndMin;
  if (a == b) return false;
  return a < b ? m >= a && m < b : m >= a || m < b;
}

/// When [batch] should go out as a notification, or null (nothing to ask, switched off, today's batches used up).
/// Soon after the newest stretch ended, not in the quiet hours (then at their end), not right after the last batch.
DateTime? planTime(List<Pick> batch, ConfirmState state, ConfirmSettings settings, DateTime now) {
  if (!settings.on || batch.isEmpty) return null;
  var t = now;
  final newest = batch.map((p) => p.estimate.end).reduce((a, b) => a.isAfter(b) ? a : b).add(ConfirmRule.afterEvent);
  if (newest.isAfter(t)) t = newest;
  if (state.batches.isNotEmpty) {
    final next = state.batches.last.add(ConfirmRule.betweenBatches);
    if (next.isAfter(t)) t = next;
  }
  if (_quiet(settings, t)) {
    var end = DateTime(t.year, t.month, t.day, settings.quietEndMin ~/ 60, settings.quietEndMin % 60);
    if (!end.isAfter(t)) end = DateTime(t.year, t.month, t.day + 1, settings.quietEndMin ~/ 60, settings.quietEndMin % 60);
    t = end;
  }
  final day = DateTime(t.year, t.month, t.day);
  final thatDay = state.batches.where((b) => DateTime(b.year, b.month, b.day) == day).length;
  return thatDay >= settings.perDay ? null : t;
}
