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
import '../recorder/remove.dart' show RawUse, rawGoneText, removedOfNight;
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

/// Searches the night of [record] (run it in a background isolate: it reads the whole night, about 190 MB for 10
/// hours, packed recordings unpacked as they are read); null when its recordings are gone (or left the phone,
/// remove.dart: [lucidRawGone] says where), or with [onlyIfScored]
/// when the night has no scored report yet: a search made before the night was scored is done again only once its
/// stages exist (DECISIONS 620-629; the page searched again at every open until then).
NightSignals? searchLastNight(String recordingsDir, LucidNightRecord record, {bool onlyIfScored = false}) {
  final start = DateTime.fromMillisecondsSinceEpoch(record.startMs);
  final name = dateName(nightOf(start));
  final report = NightReportStore(nightsDirFor(recordingsDir)).read(name);
  final scored = report != null && report.scored;
  if (onlyIfScored && !scored) return null;
  final night = nightsIn(Directory(recordingsDir)).where((n) => n.name == name);
  if (night.isEmpty || night.first.recordings.isEmpty || night.first.removed.isNotEmpty) return null;
  final cal = calibratedSignals(Directory(recordingsDir).parent);
  return searchNight(
    night.first.recordings,
    sweepUv: cal.sweepUv,
    clench: cal.clench,
    stages: scored ? report.stages : const <String>[],
    stagesFromUnix: scored ? report.dataStart.millisecondsSinceEpoch ~/ 1000 : null,
    cues: record.cues,
  );
}

/// What the page says when the night of [record] has no samples on the phone any more (moved to the laptop or deleted
/// by hand, remove.dart); null while they are here.
String? lucidRawGone(String recordingsDir, LucidNightRecord record) =>
    rawGoneText(removedOfNight(Directory(recordingsDir), dateName(nightOf(DateTime.fromMillisecondsSinceEpoch(record.startMs)))));

/// [searchLastNight] in a background isolate (nothing of it on the screen's thread), keeping the result.
Future<NightSignals?> searchAndKeep(
  String recordingsDir,
  LucidStore store,
  LucidNightRecord record, {
  bool onlyIfScored = false,
}) async {
  // the night's raw files are read meanwhile: nothing in the folder is removed until it ends (remove.dart)
  final out = await RawUse.hold(
    [recordingsDir],
    () => Isolate.run(
      () => searchLastNight(recordingsDir, record, onlyIfScored: onlyIfScored),
      debugName: 'lucid-signals',
    ),
  );
  if (out != null) store.saveSignals(record.stamp, out);
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
