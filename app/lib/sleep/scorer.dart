// Scores finished nights on the phone after Stop (DECISIONS rows 97 and 580-589). A night is scored when its report
// is missing or its recordings changed (a file gone or shrunk, 10+ minutes of new samples), never again just because
// the app or its scorer was updated: a report from an older scorer stays, and its page offers "Score again".
//
// Each go joins and prepares the recordings in a background isolate, then the three AnySleep runs score the night
// piece by piece (ONNX Runtime on the plugin's own threads), then the shared detectors read the same samples in
// another background isolate for the report's extras (jaw, movement, signal quality; extras.dart; if that fails the
// report is still written, without extras), and `files/nights/<date>.report.json` is written. One step at a time, so
// at most one heavy thing runs. After every model call the progress is saved (`files/cache/scoring/`, progress.dart):
// a go that ends early (an app update, Android ending the app, a night that starts) goes on from there next time.
//
// A `<date>.scoring` marker stays while a go works. Still there at the next start: the app stopped while scoring,
// and the night goes on by itself, unless [maxTries] goes in a row ended before a model call was saved (the app may
// run out of memory preparing it): then it waits for "Try again" instead of stopping the app at every start. A
// failure writes its reason into the marker and waits for "Try again" too.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../recorder/header.dart' show legacyHeader, tryHeader;
import '../recorder/nights.dart';
import '../recorder/packed.dart' show rawExists, rawLength;
import '../recorder/remove.dart' show RawUse;
import 'extras.dart';
import 'model.dart';
import 'prep.dart';
import 'progress.dart';
import 'report.dart';

typedef PrepareFn = Future<ModelInput?> Function(List<File> recordings);

Future<ModelInput?> prepareInBackground(List<File> recordings) =>
    Isolate.run(() => prepareNight(recordings), debugName: 'sleep-prep');

/// The same for a night or nap of sleep spans (Record first, DECISIONS 886): only the samples inside [windows]
/// (unix seconds) are read.
typedef PrepareSpanFn = Future<ModelInput?> Function(List<File> recordings, List<(double, double)> windows);

Future<ModelInput?> prepareSpanInBackground(List<File> recordings, List<(double, double)> windows) =>
    Isolate.run(() => prepareNight(recordings, windows: windows), debugName: 'sleep-prep');

/// Ends a go early on purpose ([SleepScorer.score]'s `between` throws it: a night or a session starts). Not a
/// failure: the progress of the last model call stays, and the night goes on from there later.
class ScoringPaused implements Exception {
  const ScoringPaused(this.why);
  final String why;

  @override
  String toString() => 'scoring paused: $why';
}

/// What the scorer is doing, for the screen.
class ScoringState {
  const ScoringState({this.night, this.step, this.blocked = const {}});

  /// The night being scored and the current step, or null when idle.
  final String? night;
  final String? step;

  /// Nights whose last attempt did not finish, with why (empty text: the app stopped while scoring).
  final Map<String, String> blocked;
}

/// One night as the scorer sees it.
typedef _Night = ({NightFiles night, bool wanted, String? blocked});

class SleepScorer {
  SleepScorer({
    required this.recordingsDir,
    required this.store,
    required this.openRun,
    this.closeRun,
    this.runCount = 3,
    this.prepare = prepareInBackground,
    this.see = seeInBackground,
    this.prepareSpan = prepareSpanInBackground,
    this.seeSpan = seeSpanInBackground,
    this.spansDir,
    this.model = phoneModelId,
    this.log,
    ScoringProgressStore? progress,
    DateTime Function()? clock,
  }) : progressStore = progress ?? ScoringProgressStore(scoringProgressDirFor(recordingsDir.path)),
       _clock = clock ?? DateTime.now;

  final Directory recordingsDir;
  final NightReportStore store;
  final Future<StageRun> Function(int run) openRun;
  final Future<void> Function(StageRun run)? closeRun;
  final int runCount;
  final PrepareFn prepare;

  /// The detectors' pass for the extras.
  final SeeFn see;
  final PrepareSpanFn prepareSpan;
  final SeeSpanFn seeSpan;

  /// The spans files (the sibling `spans/` of the recordings unless said).
  final Directory? spansDir;

  /// The nights and the naps, newest first: everything that gets a report.
  List<NightFiles> _sleeps() => [...nightsIn(recordingsDir, spansDir: spansDir), ...napsIn(recordingsDir, spansDir: spansDir)];
  final String model;

  /// One line when a go starts, pauses or ends (logcat on the phone: tag `flutter`).
  final void Function(String line)? log;

  /// The nights under way (progress.dart).
  final ScoringProgressStore progressStore;
  final DateTime Function() _clock;

  /// The night's `.f32` names and lengths, packed or not (a night packed after a day keeps its report).
  /// For a night of sleep spans: each file's bytes inside the spans (worked out from its start and length, whole
  /// seconds), so a recording that goes on after the sleep does not make its report stale.
  static Map<String, int> inputsOf(NightFiles night) => {
    for (final f in night.recordings)
      if (rawExists(f)) f.uri.pathSegments.last: night.windows == null ? rawLength(f) : _bytesInside(f, night.windows!),
  };

  static int _bytesInside(File f32, List<(DateTime, DateTime)> windows) {
    final h = tryHeader(f32) ?? legacyHeader;
    final start = stemTime(f32.uri.pathSegments.last);
    final length = rawLength(f32);
    if (start == null) return length;
    final end = start.add(Duration(microseconds: (length ~/ h.recordBytes * 1e6 / h.sampleRate).round()));
    var seconds = 0;
    for (final (a, b) in windows) {
      final from = a.isAfter(start) ? a : start, to = b.isBefore(end) ? b : end;
      if (to.isAfter(from)) seconds += to.difference(from).inSeconds;
    }
    final bytes = (seconds * h.sampleRate).floor() * h.recordBytes;
    return bytes < length ? bytes : length;
  }

  /// The `.scoring` markers: night -> what it says.
  Map<String, String> _markers() {
    final out = <String, String>{};
    if (!store.dir.existsSync()) return out;
    final naps = Directory('${store.dir.path}/naps');
    for (final f in [...store.dir.listSync(), if (naps.existsSync()) ...naps.listSync()].whereType<File>()) {
      final name = f.path.substring(store.dir.path.length + 1); // `naps/<stamp>.scoring` for a nap
      if (!name.endsWith('.scoring')) continue;
      final night = name.substring(0, name.length - 8);
      try {
        out[night] = f.readAsStringSync().trim();
      } on FileSystemException {
        out[night] = '';
      }
    }
    return out;
  }

  /// Every night with recordings, oldest first: whether it needs scoring (no report, its recordings changed, a go
  /// under way, or "Score again"), and why it waits for "Try again" if it does. With [tidy], a marker or progress
  /// file left from something no longer needed (an older app's "score again after the update") is removed.
  List<_Night> _nights({bool tidy = false}) {
    final markers = _markers();
    final out = <_Night>[];
    for (final n in _sleeps().reversed) {
      // a night whose raw files left the phone (remove.dart) keeps its report: never scored again from what is left
      if (n.recordings.isEmpty || n.removed.isNotEmpty) continue;
      final inputs = inputsOf(n);
      final p = progressStore.read(n.name);
      final going = p != null && p.matches(inputs, model);
      final wanted = going || isStale(inputs, store.read(n.name));
      final marker = markers[n.name];
      String? stuck;
      if (wanted && marker != null) {
        if (marker.isNotEmpty) {
          stuck = marker; // a failure: it would most likely fail again the same way
        } else if (going && p.tries >= maxTries) {
          stuck = ''; // stopped while scoring, again and again, before a model call was saved
        }
      }
      if (tidy) {
        if (p != null && !going) progressStore.delete(n.name);
        if (marker != null && !wanted) store.markerFor(n.name).deleteSync();
      }
      out.add((night: n, wanted: wanted, blocked: stuck));
    }
    return out;
  }

  /// Nights that need scoring but wait for "Try again", with the reason (empty: the app stopped while scoring).
  Map<String, String> blocked() {
    if (!store.dir.existsSync()) return {};
    return {
      for (final n in _nights())
        if (n.blocked != null) n.night.name: n.blocked!,
    };
  }

  /// Nights that need scoring, oldest first, except blocked ones. Removes markers and progress files nothing needs.
  List<NightFiles> due() => [
    for (final n in _nights(tidy: true))
      if (n.wanted && n.blocked == null) n.night,
  ];

  /// "Try again": the night is scored once more, on from its last saved model call.
  void unblock(String night) {
    final m = store.markerFor(night);
    if (m.existsSync()) m.deleteSync();
    final p = progressStore.read(night);
    if (p != null && p.tries > 0) progressStore.write(night, p..tries = 0);
  }

  /// "Score again" for a night with a report (from an older scorer): scored once more from the start.
  void request(String night) {
    final n = _sleeps().where((n) => n.name == night).firstOrNull;
    if (n == null || n.recordings.isEmpty || n.removed.isNotEmpty) return;
    progressStore.write(night, NightProgress(inputs: inputsOf(n), model: model, requested: true));
    final m = store.markerFor(night);
    if (m.existsSync()) m.deleteSync();
  }

  /// Whether [r] came from an older scorer or report version (its page offers "Score again").
  bool olderScorer(SleepReport r) => scoredByOlder(r, model: model);

  /// Scores [night], on from its saved progress, and writes its report. [progress] gets each step's words;
  /// [between] runs before each step and model call and may wait, or throw [ScoringPaused] to end this go early.
  /// On a failure the marker keeps the reason and the error is rethrown.
  Future<SleepReport> score(
    NightFiles night, {
    void Function(String step)? progress,
    Future<void> Function()? between,
  }) =>
      // its raw files are read meanwhile: nothing removes them (remove.dart)
      RawUse.hold([for (final f in night.recordings) f.path], () => _score(night, progress, between));

  Future<SleepReport> _score(
    NightFiles night,
    void Function(String step)? progress,
    Future<void> Function()? between,
  ) async {
    final inputs = inputsOf(night);
    store.fileFor(night.name).parent.createSync(recursive: true);
    final saved = progressStore.read(night.name);
    final p = saved != null && saved.matches(inputs, model) ? saved : NightProgress(inputs: inputs, model: model);
    final triesBefore = p.tries;
    p.tries += 1; // counted until a model call is saved: a go that keeps dying while preparing stops by itself
    progressStore.write(night.name, p);
    final callsBefore = p.progress?.calls ?? 0;
    String calls() {
      final c = p.calls(runCount);
      return '${c.done} of ${c.of == 0 ? '?' : c.of} model calls';
    }

    log?.call(
      'sleep scoring of ${night.name}: ${callsBefore == 0 && p.prepared == null ? 'starting' : 'going on at ${calls()}'}'
      '${triesBefore > 0 ? ' (try ${triesBefore + 1})' : ''}',
    );
    final marker = store.markerFor(night.name)..writeAsStringSync('', flush: true);
    var since = _clock();
    void keep() {
      final now = _clock();
      p.seconds += now.difference(since).inMicroseconds / 1e6;
      since = now;
      progressStore.write(night.name, p);
    }

    try {
      await between?.call();
      final rep = await _report(night, inputs, p, keep, progress, between);
      // the owner's "Was this you?" answer belongs to the night, not to this scoring: read just before the write
      final answered = store.read(night.name)?.json['wearer'];
      if (answered != null) rep['wearer'] = answered;
      final span = night.spanField;
      if (span != null) rep['span'] = span; // which sleep spans it covers (docs/data-format.md)
      store.write(rep, name: night.name);
      marker.deleteSync();
      progressStore.delete(night.name);
      log?.call(
        'sleep scoring of ${night.name}: done, ${(p.progress?.calls ?? 0) - callsBefore} model calls in this go, '
        '${p.seconds.round()} s of work in all',
      );
      return SleepReport(rep);
    } on ScoringPaused catch (e) {
      if (p.tries > triesBefore) p.tries = triesBefore; // ended on purpose: not a try that failed
      keep();
      marker.deleteSync();
      log?.call('sleep scoring of ${night.name}: paused at ${calls()} (${e.why})');
      rethrow;
    } catch (e) {
      try {
        keep();
      } catch (_) {}
      marker.writeAsStringSync('$e', flush: true);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _report(
    NightFiles night,
    Map<String, int> inputs,
    NightProgress p,
    void Function() keep,
    void Function(String step)? progress,
    Future<void> Function()? between,
  ) async {
    var facts = p.prepared;
    final m = p.progress;
    if (facts != null && m != null && !m.fits(facts.gap.length, runCount, pieces(facts.gap.length).length)) {
      p.progress = null; // made with other pieces or runs: start the model over
    }
    Float64List? probs;
    if (facts != null && (p.progress?.done ?? false)) {
      probs = meanProbabilities(p.progress!); // the model is done: no second preparation
    } else {
      final before = p.calls(runCount);
      // why it is scored, in the first words (DECISIONS row 580: never just because the app was updated)
      progress?.call(
        before.done > 0
            ? 'Preparing the recording to go on from ${_pct(before.done, before.of)}'
            : p.requested
            ? 'Preparing the recording to score it again'
            : store.read(night.name) != null
            ? 'Preparing the recording: new data since its report'
            : 'Preparing the recording',
      );
      final w = _unixWindows(night);
      final input = await (w == null ? prepare(night.recordings) : prepareSpan(night.recordings, w));
      if (input != null) {
        facts = (
          startUnix: input.startUnix,
          recordedSamples: input.recordedSamples,
          missingSamples: input.missingSamples,
          gap: input.gap,
        );
        if (p.prepared?.gap.length != input.epochs) p.progress = null;
        p.prepared = facts;
        keep();
        final steps = modelCalls(input.epochs, runCount);
        probs = await stageProbabilities(
          input,
          runCount,
          openRun,
          close: closeRun,
          from: p.progress,
          progress: (r, k, n) => progress?.call('Sleep model ${_pct((r - 1) * n + k - 1, steps)} (run $r of $runCount)'),
          saved: (now) async {
            p
              ..progress = now
              ..tries = 0;
            keep();
          },
          between: between,
        );
      }
    }
    if (facts == null || probs == null) {
      // under 5 minutes: an unscored report, as the laptop's
      keep();
      return buildReport(
        nightOf: night.napStamp ?? night.name,
        built: _clock(),
        scoringSeconds: p.seconds,
        start: night.start,
        lengthSeconds: night.end.difference(night.start).inMilliseconds / 1000,
        inputs: inputs,
        model: model,
      );
    }
    final s = stagesOf(probs, facts.gap);
    await between?.call();
    progress?.call('Counting jaw, movement and signal');
    final w = _unixWindows(night);
    final (found, whyNot) = await Future.sync(() => w == null ? see(night.recordings) : seeSpan(night.recordings, w)).then<(NightSeen?, String?)>(
      (s) => (s, null),
      onError: (Object e) => (null, '$e'),
    );
    keep();
    return buildReport(
      nightOf: night.napStamp ?? night.name,
      built: _clock(),
      scoringSeconds: p.seconds,
      start: DateTime.fromMillisecondsSinceEpoch(facts.startUnix * 1000),
      lengthSeconds: facts.recordedSamples / 250,
      inputs: inputs,
      model: model,
      stages: s.stages,
      confidence: s.confidence,
      probabilities: probs,
      seen: found,
      extrasError: whyNot,
    );
  }

  static List<(double, double)>? _unixWindows(NightFiles night) => night.windows == null
      ? null
      : [for (final (a, b) in night.windows!) (a.microsecondsSinceEpoch / 1e6, b.microsecondsSinceEpoch / 1e6)];

  static String _pct(int done, int of) => '${of == 0 ? 0 : (100 * done / of).floor()} %';
}
