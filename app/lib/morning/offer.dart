// The morning check-in offer (DECISIONS 1110): when the Record tab asks "Morning check-in now?" on the running
// recording. A pure rule over what the app already knows (the recording's spans, the clock, the last data, the last
// check-in); nothing is read or written here, and nothing starts by itself: the offer is one line the owner may
// tap, never a notification or a sound.
import '../spans/span.dart';

abstract final class MorningOfferRule {
  /// The shortest sleep stretch that is offered a check-in (a doze is not a night).
  static const Duration minSleep = Duration(hours: 3);

  /// The sleep must have ended from 04:00 to 13:00 local, both minutes included (04:00 is where the app's day begins).
  static const int fromMinute = 4 * 60;
  static const int toMinute = 13 * 60;

  /// The offer goes away this long after the end of the sleep.
  static const Duration maxAge = Duration(hours: 2);

  /// "The recording still runs": data in the last 2 minutes.
  static const Duration dataFresh = Duration(minutes: 2);

  /// The words' promise ("About 6 minutes"), as the Morning section says.
  static const int minutes = 6;
}

/// The offer: which sleep stretch it is for (to remember "Not now") and the line.
class MorningOffer {
  const MorningOffer({required this.spanId, required this.sleptUntil});

  /// The sleep span's id.
  final String spanId;
  final DateTime sleptUntil;

  String get line {
    final t = '${sleptUntil.hour.toString().padLeft(2, '0')}:${sleptUntil.minute.toString().padLeft(2, '0')}';
    return 'Slept until $t. Morning check-in now? About ${MorningOfferRule.minutes} minutes.';
  }
}

/// The offer for the running recording, or null.
///
/// The stretch that counts is the newest sleep span (kind `sleep`, not `nap`; a removed one is no sleep). Its length
/// is end minus start (pauses are not taken off). [lastCheckIn] is the newest check-in saved (null: none known);
/// [dismissedSpanId] is the stretch the owner tapped "Not now" for: it is kept in memory by the screen, so a restart
/// of the app may show the line again within the 2 hours.
MorningOffer? morningOffer({
  required List<Span> spans,
  required DateTime now,
  required DateTime? lastDataAt,
  required DateTime? lastCheckIn,
  required String? dismissedSpanId,
}) {
  if (lastDataAt == null || now.difference(lastDataAt) > MorningOfferRule.dataFresh) return null;
  if (spans.any((s) => !s.closed && !s.removed)) return null; // something is marked now
  final sleeps = [
    for (final s in spans)
      if (s.kind == 'sleep' && s.closed && !s.removed) s,
  ]..sort((a, b) => a.end!.compareTo(b.end!));
  if (sleeps.isEmpty) return null;
  final sleep = sleeps.last;
  final end = sleep.end!;
  if (sleep.endedBy != 'owner' || sleep.id == dismissedSpanId) return null;
  if (end.difference(sleep.start) < MorningOfferRule.minSleep) return null;
  final day = DateTime(end.year, end.month, end.day);
  if (end.isBefore(day.add(const Duration(minutes: MorningOfferRule.fromMinute))) ||
      end.isAfter(day.add(const Duration(minutes: MorningOfferRule.toMinute)))) {
    return null;
  }
  if (now.difference(end) > MorningOfferRule.maxAge || now.isBefore(end)) return null;
  if (lastCheckIn != null && !lastCheckIn.isBefore(end)) return null;
  for (final s in spans) {
    if (s.kind == 'check_in' && !s.removed && !s.start.isBefore(end)) return null;
  }
  return MorningOffer(spanId: sleep.id, sleptUntil: end);
}
