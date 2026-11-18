// Scores finished nights on the phone after Stop (DECISIONS row 97): for each night whose report is missing or
// out of date (night_files.py's rule), the recordings are joined and prepared in a background isolate, the three
// AnySleep runs score it piece by piece, the stages are split into sleep periods and `files/nights/<date>.report.json`
// is written. Beside them a second background isolate runs the shared detectors over the same samples for the
// report's extras (jaw, movement, signal quality; extras.dart): a few kilobytes of memory, and done before the model
// on the laptop; if it fails the report is still written, without extras. A `<date>.scoring` marker stays while it
// works: if the app dies while scoring (memory, a kill), the marker is still there next time and that night waits
// for "Try again" instead of crashing the app on every start.
import 'dart:io';
import 'dart:isolate';

import '../recorder/nights.dart';
import 'extras.dart';
import 'model.dart';
import 'prep.dart';
import 'report.dart';

typedef PrepareFn = Future<ModelInput?> Function(List<File> recordings);

Future<ModelInput?> prepareInBackground(List<File> recordings) =>
    Isolate.run(() => prepareNight(recordings), debugName: 'sleep-prep');

/// What the scorer is doing, for the screen.
class ScoringState {
  const ScoringState({this.night, this.step, this.blocked = const {}});

  /// The night being scored and the current step, or null when idle.
  final String? night;
  final String? step;

  /// Nights whose last attempt did not finish, with why (empty text: the app stopped while scoring).
  final Map<String, String> blocked;
}

class SleepScorer {
  SleepScorer({
    required this.recordingsDir,
    required this.store,
    required this.openRun,
    this.closeRun,
    this.runCount = 3,
    this.prepare = prepareInBackground,
    this.see = seeInBackground,
    this.model = phoneModelId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Directory recordingsDir;
  final NightReportStore store;
  final Future<StageRun> Function(int run) openRun;
  final Future<void> Function(StageRun run)? closeRun;
  final int runCount;
  final PrepareFn prepare;

  /// The detectors' pass for the extras.
  final SeeFn see;
  final String model;
  final DateTime Function() _clock;

  static Map<String, int> inputsOf(NightFiles night) => {
    for (final f in night.recordings)
      if (f.existsSync()) f.uri.pathSegments.last: f.lengthSync(),
  };

  /// Nights whose last scoring did not finish, with the reason written in the marker.
  Map<String, String> blocked() {
    final out = <String, String>{};
    if (!store.dir.existsSync()) return out;
    for (final f in store.dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.scoring')) continue;
      try {
        out[name.substring(0, name.length - 8)] = f.readAsStringSync().trim();
      } on FileSystemException {
        out[name.substring(0, name.length - 8)] = '';
      }
    }
    return out;
  }

  /// Nights with data whose report is missing or out of date, oldest first, except blocked ones.
  List<NightFiles> due() {
    final stuck = blocked();
    return [
      for (final n in nightsIn(recordingsDir).reversed)
        if (n.recordings.isNotEmpty && !stuck.containsKey(n.name) && isStale(inputsOf(n), store.read(n.name))) n,
    ];
  }

  /// Lets a blocked night be scored again.
  void unblock(String night) {
    final m = store.markerFor(night);
    if (m.existsSync()) m.deleteSync();
  }

  /// Scores [night] and writes its report. On a failure the marker keeps the reason and the error is rethrown.
  Future<SleepReport> score(NightFiles night, {void Function(String step)? progress}) async {
    final t0 = _clock();
    store.dir.createSync(recursive: true);
    final marker = store.markerFor(night.name)..writeAsStringSync('', flush: true);
    try {
      final inputs = inputsOf(night);
      progress?.call('Preparing the recording');
      // the detectors' pass runs beside the preparation and the model; it never fails the night
      var seeing = true;
      final seen = Future.sync(() => see(night.recordings)).then<(NightSeen?, String?)>(
        (s) => (s, null),
        onError: (Object e) => (null, '$e'),
      ).whenComplete(() => seeing = false);
      final input = await prepare(night.recordings);
      Map<String, dynamic> rep;
      if (input == null) {
        await seen;
        final start = night.start;
        rep = buildReport(
          nightOf: night.name,
          built: _clock(),
          scoringSeconds: _clock().difference(t0).inMilliseconds / 1000,
          start: start,
          lengthSeconds: night.end.difference(start).inMilliseconds / 1000,
          inputs: inputs,
          model: model,
        );
      } else {
        final probs = await stageProbabilities(
          input,
          runCount,
          openRun,
          close: closeRun,
          progress: (r, k, n) => progress?.call('Sleep model, run $r of $runCount${n > 1 ? ', part $k of $n' : ''}'),
        );
        final s = stagesOf(probs, input.gap);
        if (seeing) progress?.call('Counting jaw, movement and signal');
        final (found, whyNot) = await seen;
        rep = buildReport(
          nightOf: night.name,
          built: _clock(),
          scoringSeconds: _clock().difference(t0).inMilliseconds / 1000,
          start: DateTime.fromMillisecondsSinceEpoch(input.startUnix * 1000),
          lengthSeconds: input.recordedSamples / 250,
          inputs: inputs,
          model: model,
          stages: s.stages,
          confidence: s.confidence,
          seen: found,
          extrasError: whyNot,
        );
      }
      store.write(rep);
      marker.deleteSync();
      return SleepReport(rep);
    } catch (e) {
      marker.writeAsStringSync('$e', flush: true);
      rethrow;
    }
  }
}
