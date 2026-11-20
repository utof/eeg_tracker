// The bedtime window of automatic recording (DECISIONS 602): from 2 hours before your usual bedtime to your usual
// wake-up, taken from your recorded nights (the median start and end of the last 14 days' nights, 3 hours or longer,
// around midnight as the sharp-hours page does), 23:00 to 07:00 until 3 nights are recorded, or set by hand. Inside it
// the app checks every 10 minutes whether the headband is on, and a find there is taken for the night.
import 'dart:io';

import '../recorder/nights.dart';
import '../sharp/schedule.dart' show clockMedian;
import 'store.dart';

/// The usual night and the window around it.
class UsualNight {
  const UsualNight({required this.bedMin, required this.wakeMin, this.fromNights = 0, this.byHand = false});

  /// Minutes after midnight.
  final int bedMin, wakeMin;

  /// Recorded nights behind the times (0: the defaults or set by hand).
  final int fromNights;
  final bool byHand;

  /// The window opens this many minutes after midnight (2 hours before bedtime).
  int get opensMin => ((bedMin - AutoRule.beforeBed.inMinutes) % 1440 + 1440) % 1440;

  /// The usual night's length in hours.
  double get nightHours => (((wakeMin - bedMin) % 1440 + 1440) % 1440) / 60;

  static int _clock(DateTime t) => t.hour * 60 + t.minute;

  /// [t] is inside the window (both ends included, across midnight).
  bool contains(DateTime t) {
    final span = ((wakeMin - opensMin) % 1440 + 1440) % 1440;
    return ((_clock(t) - opensMin) % 1440 + 1440) % 1440 <= span;
  }

  /// Hours from [t] to the next usual bedtime and the next usual wake-up.
  double hoursToBed(DateTime t) => _ahead(t, bedMin);
  double hoursToWake(DateTime t) => _ahead(t, wakeMin);

  double _ahead(DateTime t, int clock) {
    final m = ((clock - _clock(t)) % 1440 + 1440) % 1440;
    return (m - t.second / 60) / 60;
  }

  /// `21:00-07:00`.
  String get windowText => '${clockText(opensMin)}-${clockText(wakeMin)}';
}

String clockText(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// The usual night: set by hand, else from [nights] (each one's start and end), else 23:00 to 07:00.
UsualNight usualNight(List<({DateTime start, DateTime end})> nights, AutoSettings s) {
  if (s.bedtimeByHand) return UsualNight(bedMin: s.bedMin!, wakeMin: s.wakeMin!, byHand: true);
  if (nights.length < 3) return const UsualNight(bedMin: AutoRule.defaultBedMin, wakeMin: AutoRule.defaultWakeMin);
  int clock(DateTime t) => t.hour * 60 + t.minute;
  return UsualNight(
    bedMin: clockMedian([for (final n in nights) clock(n.start)]),
    wakeMin: clockMedian([for (final n in nights) clock(n.end)]),
    fromNights: nights.length,
  );
}

/// The recorded nights of the 14 days before [now] that lasted 3 hours or more: when each recording started and its
/// last data came. Unreadable folders give none.
List<({DateTime start, DateTime end})> recordedNights(Directory recordings, DateTime now) {
  try {
    return [
      for (final n in nightsIn(recordings))
        if (n.recordings.isNotEmpty &&
            n.end.difference(n.start) >= const Duration(hours: 3) &&
            now.difference(n.end) < const Duration(days: 14))
          (start: n.start, end: n.end),
    ];
  } catch (_) {
    return const [];
  }
}

/// The bedtime checks of the next 24 hours: every 10 minutes from the window's opening to its end.
List<DateTime> bedtimeChecks(UsualNight w, DateTime now) {
  final every = AutoRule.bedtimeEvery.inMinutes;
  final out = <DateTime>[];
  final until = now.add(const Duration(hours: 24));
  // the window's opening on the day before, today and tomorrow covers every check of the next 24 hours
  for (var d = -1; d <= 1; d++) {
    final day = DateTime(now.year, now.month, now.day + d);
    final open = DateTime(day.year, day.month, day.day, w.opensMin ~/ 60, w.opensMin % 60);
    final span = ((w.wakeMin - w.opensMin) % 1440 + 1440) % 1440;
    for (var m = 0; m <= span; m += every) {
      final t = open.add(Duration(minutes: m));
      if (t.isAfter(now) && !t.isAfter(until)) out.add(t);
    }
  }
  return out..sort();
}
