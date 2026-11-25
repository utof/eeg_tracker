// The sleep model's day numbers on Trends (DECISIONS rows 650-659): minutes of light, deep and dream sleep,
// wake-ups, the time to fall asleep, sleep efficiency and sleep regularity, each worked out from the phone's sleep
// reports (report.dart) and counted for the day you woke from the night (days.dart, row 121). Plain Dart: Trends
// loads in a background isolate and this runs inside its `dailySeries`, over the reports it has already read.
//
// A night is left out of all of them when it is marked "someone else" (row 377), has no sleep period, or when more
// than half of its time asleep was read through noise or with no usable channel (the same limit as the export to
// utof_tracker, row 553; a report from before the detectors' extras has no such figure and counts). The length of
// sleep ("Asleep") keeps counting every scored night, as before.
import 'dart:math' as math;

import '../sleep/drift.dart' show LightsOffFrom;
import '../sleep/report.dart' show SleepReport;
import '../wearer/check.dart' show answerSomeoneElse;
import 'days.dart';

/// More of the time asleep than this read through noise or with no channel: the night is left out (row 653).
const double noisyNightShare = 0.5;

/// A night is judged for efficiency only when it spans at least this long (minutes): a nap-sized stay says nothing.
const double efficiencyMinInBedMin = 30;

/// Regularity looks at the nights whose day is one of the last [regularityDays] days, and needs [regularityMinNights]
/// of them (row 655).
const int regularityDays = 7, regularityMinNights = 5;

/// Longest spread regularity reports (the times are spread all round the clock): 12 hours.
const double regularitySpreadCapMin = 720;

/// Whether the sleep model's numbers may use [r] at all (see the top of the file).
bool countsForSleepNumbers(SleepReport r) {
  if (!r.scored || r.noSleepFound || r.wearerAnswer == answerSomeoneElse || r.periods.isEmpty) return false;
  final asleep = r.extras?.asleep;
  return asleep == null || asleep.min <= 0 || asleep.noisyShare <= noisyNightShare;
}

class _Night {
  _Night(this.report) {
    final p = report.periods;
    onset = p.map((x) => x.start).reduce((a, b) => a.isBefore(b) ? a : b);
    wake = p.map((x) => x.end).reduce((a, b) => a.isAfter(b) ? a : b);
    day = wakeDay(wake);
  }

  final SleepReport report;
  late final DateTime onset, wake;
  late final String day;

  /// When the time in bed starts: the Lights off tap or marker, else when the recording started; never later than
  /// the first sleep (a late tap must not cut into the sleep, row 654).
  DateTime get bedStart {
    final lo = report.driftOff;
    final tapped = lo != null && lo.from != LightsOffFrom.nightStart ? lo.lightsOff : null;
    final from = tapped ?? report.dataStart;
    return from.isBefore(onset) ? from : onset;
  }

  double get inBedMin => wake.difference(bedStart).inSeconds / 60;

  /// Minutes from Lights off to the sleep model's first sleep; null without a Lights off or when it found none.
  double? get fellAsleepMin {
    final lo = report.driftOff;
    if (lo == null || lo.from == LightsOffFrom.nightStart) return null;
    final v = lo.modelOnsetMin;
    return v != null && v.isFinite && v >= 0 ? v : null;
  }
}

/// The standard deviation of times of day (minutes after midnight), as a circle: 23:50 and 00:10 are 20 minutes
/// apart, not 23 hours and 40. `sqrt(-2 ln R)` with R the length of the mean of the times as unit arrows, in minutes;
/// at most [regularitySpreadCapMin].
double circularSpreadMin(List<double> minutesOfDay) {
  if (minutesOfDay.length < 2) return 0;
  var c = 0.0, s = 0.0;
  for (final m in minutesOfDay) {
    final a = m * math.pi / 720;
    c += math.cos(a);
    s += math.sin(a);
  }
  final r = math.sqrt(c * c + s * s) / minutesOfDay.length;
  if (r < 1e-9) return regularitySpreadCapMin;
  final sd = math.sqrt(-2 * math.log(math.min(1.0, r))) * 720 / math.pi;
  return math.min(sd, regularitySpreadCapMin);
}

double _minuteOfDay(DateTime t) => t.hour * 60.0 + t.minute + t.second / 60;

/// Day -> value for `light`, `deep`, `dream`, `wakeups`, `fall_asleep`, `efficiency` and `regularity`.
Map<String, Map<String, double>> sleepModelDays(Iterable<SleepReport> reports) {
  final nights = [
    for (final r in reports)
      if (countsForSleepNumbers(r)) _Night(r),
  ]..sort((a, b) => a.report.dataStart.compareTo(b.report.dataStart));
  final out = {for (final id in sleepModelIds) id: <String, double>{}};
  final asleep = <String, double>{}, inBed = <String, double>{};
  final onsets = <String, List<double>>{}, wakes = <String, List<double>>{};
  for (final n in nights) {
    final d = n.day;
    void add(String id, double v) => out[id]![d] = (out[id]![d] ?? 0) + v;
    for (final p in n.report.periods) {
      add('light', p.lightMin);
      add('deep', p.deepMin);
      add('dream', p.dreamMin);
      add('wakeups', p.wakeUps.toDouble());
    }
    final fell = n.fellAsleepMin;
    if (fell != null) out['fall_asleep']!.putIfAbsent(d, () => fell);
    if (n.inBedMin >= efficiencyMinInBedMin) {
      asleep[d] = (asleep[d] ?? 0) + n.report.periods.fold(0.0, (s, p) => s + p.asleepMin);
      inBed[d] = (inBed[d] ?? 0) + n.inBedMin;
    }
    (onsets[d] ??= []).add(_minuteOfDay(n.onset));
    (wakes[d] ??= []).add(_minuteOfDay(n.wake));
  }
  for (final d in inBed.keys) {
    out['efficiency']![d] = math.min(100.0, asleep[d]! / inBed[d]! * 100);
  }
  // regularity: the nights of the last 7 days up to this one (a day with two sleeps counts once, by its first onset
  // and last wake-up)
  final byDay = onsets.keys.toList()..sort();
  for (final d in byDay) {
    final window = [
      for (final k in byDay)
        if (k.compareTo(d) <= 0 && daysBetween(k, d) < regularityDays) k,
    ];
    if (window.length < regularityMinNights) continue;
    final on = [for (final k in window) onsets[k]!.first];
    final off = [for (final k in window) wakes[k]!.last];
    out['regularity']![d] = (circularSpreadMin(on) + circularSpreadMin(off)) / 2;
  }
  return out;
}

/// The ids this file makes numbers for.
const List<String> sleepModelIds = ['light', 'deep', 'dream', 'wakeups', 'fall_asleep', 'efficiency', 'regularity'];
