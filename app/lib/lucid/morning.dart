// The lucid cues' morning (DECISIONS 304, 306): the night's recordings are searched for dream signals (signals.dart:
// left-right-left-right with the eyes, and a double clench when the hands-free calibration has one), each placed on
// the clock, given the full-night scoring's stage there and the cue moment it may answer (within 2 minutes after).
// The search runs in a background isolate over the joined night, as the night extras do (sleep/extras.dart), and is
// kept in files/lucid/signals/. Also what one night gives the results (plan.dart).
import 'dart:io';
import 'dart:isolate';

import '../detectors/gestures.dart';
import '../handsfree/store.dart';
import '../recorder/nights.dart';
import '../sleep/night_signal.dart' show joinLayout;
import '../sleep/report.dart';
import 'plan.dart';
import 'signals.dart';
import 'store.dart';

const int _fs = 250;

/// Found signals placed on the clock ([startUnix]: the joined night's first sample), with the stage of
/// [stages] (30 s epochs from [stagesFromUnix]; null: unknown) and the cue moment each follows within 2 minutes.
List<FoundSignal> placeSignals(
  FoundSignals found, {
  required int startUnix,
  required List<String> stages,
  required int? stagesFromUnix,
  required List<CueMoment> cues,
}) {
  FoundSignal at(double s, String kind, int? pairs) {
    final ms = ((startUnix + s) * 1000).round();
    String? stage;
    final from = stagesFromUnix;
    if (from != null) {
      final e = ((startUnix + s - from) / 30).floor();
      if (e >= 0 && e < stages.length) stage = stages[e];
    }
    int? after;
    for (final c in cues) {
      final d = (ms - c.atMs) ~/ 1000;
      if (d >= 0 && d <= SignalRule.answerS && (after == null || d < after)) after = d;
    }
    return FoundSignal(atMs: ms, kind: kind, pairs: pairs, stage: stage, afterCueS: after);
  }

  final out = [
    for (final s in found.lrlr) at(s.end / _fs, 'lrlr', s.pairs),
    for (final g in found.clenches) at(g.start / 10, 'clench', null),
  ]..sort((a, b) => a.atMs.compareTo(b.atMs));
  return out;
}

/// The search over a night's `.f32` files (oldest first); runs in the caller's isolate.
NightSignals searchNight(
  List<File> f32Files, {
  required double sweepUv,
  required GestureSettings? clench,
  required List<String> stages,
  required int? stagesFromUnix,
  required List<CueMoment> cues,
}) {
  final layout = joinLayout(f32Files);
  final finder = SignalFinder(sweepUv: sweepUv, clench: clench);
  if (layout.samples > 0) layout.forEachRow((row, missing) => finder.push(row, missing: missing));
  return NightSignals(
    made: DateTime.now(),
    signals: layout.samples == 0
        ? const []
        : placeSignals(
            finder.finish(),
            startUnix: layout.startUnix,
            stages: stages,
            stagesFromUnix: stagesFromUnix,
            cues: cues,
          ),
    sweepUv: sweepUv,
    clenchX: clench?.clenchX,
    staged: stagesFromUnix != null,
  );
}

/// The look size and the clench line from the owner's hands-free calibration: its look size when the look was
/// usable, its clench line when the double clench was (whether or not the switch is on).
({double sweepUv, GestureSettings? clench}) calibratedSignals(Directory filesDir) {
  try {
    final cal = HandsFreeStore(filesDir).load().calibration;
    final s = cal?.settings;
    return (
      sweepUv: s != null && s.glanceOn ? s.glanceUv : SignalRule.sweepUv,
      clench: s != null && s.clenchOn ? GestureSettings(clenchX: s.clenchX, glanceOn: false) : null,
    );
  } catch (_) {
    return (sweepUv: SignalRule.sweepUv, clench: null);
  }
}

/// Searches the night of [record] in a background isolate and keeps the result; null when its recordings are gone.
Future<NightSignals?> searchAndKeep(String recordingsDir, LucidStore store, LucidNightRecord record) async {
  final start = DateTime.fromMillisecondsSinceEpoch(record.startMs);
  final night = nightsIn(Directory(recordingsDir)).where((n) => dateName(n.nightOf) == dateName(nightOf(start)));
  if (night.isEmpty || night.first.recordings.isEmpty) return null;
  final files = [for (final f in night.first.recordings) f.path];
  final report = NightReportStore(nightsDirFor(recordingsDir)).read(night.first.name);
  final scored = report != null && report.scored;
  final stages = scored ? report.stages : const <String>[];
  final from = scored ? report.dataStart.millisecondsSinceEpoch ~/ 1000 : null;
  final cal = calibratedSignals(Directory(recordingsDir).parent);
  final cues = record.cues;
  final out = await Isolate.run(
    () => searchNight(
      [for (final p in files) File(p)],
      sweepUv: cal.sweepUv,
      clench: cal.clench,
      stages: stages,
      stagesFromUnix: from,
      cues: cues,
    ),
    debugName: 'lucid-signals',
  );
  store.saveSignals(record.stamp, out);
  return out;
}

/// A practice counts for a night when it ended from 3 hours before the night's start to 2 hours after (in bed, after
/// Start), and went through its guided part.
bool practisedBefore(int nightStartMs, List<PracticeRecord> practices) => practices.any((p) {
  if (!p.completed) return false;
  final end = p.end.millisecondsSinceEpoch;
  return end >= nightStartMs - 3 * 3600 * 1000 && end <= nightStartMs + 2 * 3600 * 1000;
});

/// What one night gives the results.
LucidNight nightForResults(
  LucidNightRecord r, {
  required LucidAnswers? answers,
  required NightSignals? signals,
  required List<PracticeRecord> practices,
  bool Function(int nightStartMs)? practisedFor,
}) => LucidNight(
  index: r.index,
  cueMoments: r.cues.length,
  arousedMoments: r.cues.where((c) => c.aroused).length,
  signalsInDreamSleep: signals?.inDreamSleep ?? 0,
  practised: (practisedFor ?? (ms) => practisedBefore(ms, practices))(r.startMs),
  answers: answers,
);
