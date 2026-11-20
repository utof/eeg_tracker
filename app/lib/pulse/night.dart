// The pulse of a sleep report's night (DECISIONS 815-816): the night's raw files through the pulse pass (pass.dart,
// kept in files/pulse/ like the Archive's), the readings on the report's own clock (one per 30 s epoch from its data
// start), "Pulse while asleep" in words, and one number a night for Trends ("your usual", trends/usual.dart). Plain
// Dart; the report runs it in a background isolate.
import 'dart:io';
import 'dart:isolate';

import '../feedback/features.dart' show median;
import '../recorder/nights.dart' show nightsIn;
import '../sleep/report.dart' show SleepReport;
import '../trends/days.dart' show wakeDay;
import '../trends/trends.dart' show finalWake;
import 'detector.dart';
import 'pass.dart';

/// A night's pulse on its report's clock: the readings (null: no pulse file covers the night) and why there are none.
typedef NightPulse = ({List<double?>? bpm, String? why});

/// The pulse of night [nightOf] on the clock of its report ([startMs], [n] epochs). With [run], the night's raw files
/// get the pass first when none is kept for them as they are (never while [run] is false: something records or scores).
NightPulse nightPulse(Directory recordingsDir, String nightOf, int startMs, int n, {bool run = true}) {
  final filesDir = recordingsDir.parent;
  String? why;
  if (run) {
    final night = nightsIn(recordingsDir).where((x) => x.name == nightOf).firstOrNull;
    final raw = night?.recordings ?? const <File>[];
    if (raw.isNotEmpty) {
      final stem = raw.first.uri.pathSegments.last;
      why = pulseAndKeep(filesDir, stem.substring(0, stem.length - 4), raw).why;
    }
  }
  final bpm = pulseOnClock(filesDir, startMs, n);
  return (bpm: bpm, why: bpm == null ? why : null);
}

/// [nightPulse] in a background isolate (only plain values cross).
Future<NightPulse> nightPulseInBackground(String recordingsPath, String nightOf, int startMs, int n, {bool run = true}) =>
    Isolate.run(() => nightPulse(Directory(recordingsPath), nightOf, startMs, n, run: run), debugName: 'night-pulse');

/// The sleep report's line: "Pulse while asleep: about 55/min (read in 22 % of the night)".
String pulseAsleepWords(PulseAsleep a) {
  final share = '${(a.share * 100).round()} %';
  if (a.median != null) return 'Pulse while asleep: about ${a.median!.round()}/min (read in $share of the night)';
  if (a.read > 0) return 'Pulse while asleep: too few readings for a number (read in $share of the night)';
  return 'Pulse while asleep: not found in the signal this night';
}

/// The lowest 5 minutes in words, or null.
String? pulseLowestWords(PulseAsleep a) =>
    a.median == null || a.lowest == null ? null : 'Lowest 5 minutes asleep: ${a.lowest!.round()}/min';

/// Pulse while asleep per day (the day of the night's last wake, as every sleep number in Trends), from the kept
/// pulse files: the median of every reading asleep of the day's nights, with at least [PulseRule.minNightReadings].
Map<String, double> pulseDayNumbers(Directory filesDir, List<SleepReport> nights) {
  final kept = keptPulses(filesDir);
  if (kept.isEmpty) return const {};
  final byDay = <String, List<double>>{};
  for (final r in nights) {
    if (!r.scored) continue;
    final stages = r.stages;
    final bpm = pulseOnClock(filesDir, r.dataStart.millisecondsSinceEpoch, stages.length, kept: kept);
    if (bpm == null) continue;
    final list = byDay.putIfAbsent(wakeDay(finalWake(r)), () => []);
    for (var i = 0; i < stages.length && i < bpm.length; i++) {
      final b = bpm[i];
      if (b != null && asleepStages.contains(stages[i])) list.add(b);
    }
  }
  return {
    for (final MapEntry(key: d, value: v) in byDay.entries)
      if (v.length >= PulseRule.minNightReadings) d: (median(v) * 10).round() / 10,
  };
}
