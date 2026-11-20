// A finished night is never scored again by itself, and a night's scoring goes on where it stopped (DECISIONS rows
// 580-584): a restart is a new SleepScorer on the same folders, an app killed mid-call is a model call that never
// returns. Fake model runs count their calls and compute their outputs from their inputs, so a night scored in
// several goes must give exactly the numbers of one go. Real files, real isolates for the share server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:eeg_tracker/sleep/progress.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/ui/sleep_scoring.dart';
import 'package:flutter_test/flutter_test.dart';

/// The night the fake preparation hands the model: 200 epochs (two pieces: 4 calls a run, 12 in all).
const int epochs = 200;
const int callsPerNight = 12;

ModelInput fakeInput(int startUnix) => ModelInput(
  startUnix: startUnix,
  epochs: epochs,
  gap: [for (var e = 0; e < epochs; e++) e % 50 == 7],
  channels: [
    for (var c = 0; c < 4; c++)
      Float32List.fromList([for (var t = 0; t < epochs * epochSamples; t++) ((t * 31 + c * 977) % 1009 - 504) / 97]),
  ],
  percentiles: const [],
  recordedSamples: epochs * 7500,
  missingSamples: 0,
);

/// A model run whose outputs follow from its inputs; counts its calls in [calls]; the call numbered [hangAt] (1-based,
/// over every run) never returns, as in an app that Android ended.
class CountingRun implements StageRun {
  CountingRun(this.run, this.calls, {this.hangAt});
  final int run;
  final List<String> calls;
  final int? hangAt;

  Future<void> _maybeHang() {
    if (hangAt != null && calls.length == hangAt) return Completer<void>().future; // never completes
    return Future<void>.value();
  }

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) async {
    calls.add('r$run sums $from-$to/$epochs');
    await _maybeHang();
    final s = Float32List(4 * meansWidth), n = Float32List(meansWidth);
    for (var i = 0; i < s.length; i++) {
      s[i] = x[(i * 7 + run) % x.length] * (to - from);
    }
    n.fillRange(0, n.length, (to - from).toDouble());
    return (sums: s, counts: n);
  }

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    calls.add('r$run logits $epochs');
    await _maybeHang();
    final out = Float32List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var k = 0; k < 5; k++) {
        out[e * 5 + k] =
            x[e * epochSamples * 4 + k * 13] + (means == null ? 0 : means[(e + k) % means.length]) + run * k * 0.01;
      }
    }
    return out;
  }
}

void main() {
  late Directory root, recordings;
  late NightReportStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sleep_resume_test');
    recordings = Directory('${root.path}/recordings')..createSync();
    store = NightReportStore(nightsDirFor(recordings.path));
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A recorder run of [minutes] at [start]: small noise, one batch a second in the .idx.
  void writeRun(Directory dir, DateTime start, double minutes) {
    final n = (minutes * 60 * 250).round();
    final rng = math.Random(1);
    final rec = ByteData(n * recordBytes);
    for (var i = 0; i < n; i++) {
      rec.setUint32(i * recordBytes, i % 2048, Endian.little);
      for (var c = 0; c < 4; c++) {
        rec.setFloat32(i * recordBytes + 4 + 4 * c, 20e-6 * (rng.nextDouble() - 0.5), Endian.little);
      }
    }
    final stem = fileStem(start);
    File('${dir.path}/$stem.f32').writeAsBytesSync(rec.buffer.asUint8List());
    final rows = n ~/ 250;
    final idx = ByteData(rows * indexBytes);
    for (var k = 0; k < rows; k++) {
      idx
        ..setFloat64(k * indexBytes, start.millisecondsSinceEpoch / 1000 + k + 1, Endian.little)
        ..setUint64(k * indexBytes + 8, k * 250, Endian.little);
    }
    File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
  }

  final start = DateTime(2026, 11, 18, 23, 0);
  const night = '2026-11-18';

  /// A scorer on [dir] ("the app after a start"): the fake preparation, the counting runs, no detectors' pass.
  SleepScorer scorer(
    Directory dir,
    List<String> calls, {
    int? hangAt,
    PrepareFn? prepare,
    String model = phoneModelId,
  }) => SleepScorer(
    recordingsDir: dir,
    store: NightReportStore(nightsDirFor(dir.path)),
    openRun: (run) async => CountingRun(run, calls, hangAt: hangAt),
    prepare: prepare ?? (files) async => fakeInput(start.millisecondsSinceEpoch ~/ 1000),
    see: (files) async => null,
    model: model,
  );

  Future<void> until(bool Function() ok, {int ms = 5000}) async {
    for (var i = 0; i < ms ~/ 5 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ok(), isTrue);
  }

  /// The parts of a report that come from the model.
  Map<String, Object?> scoredPart(Map<String, dynamic> j) => {
    for (final k in ['stages', 'periods', 'total', 'data_start', 'data_end']) k: j[k],
  };

  /// The same night scored in one go, in its own folder.
  Future<Map<String, Object?>> inOneGo() async {
    final dir = Directory('${root.path}/one-go/recordings')..createSync(recursive: true);
    writeRun(dir, start, 6);
    final calls = <String>[];
    final s = scorer(dir, calls);
    final r = await s.score(s.due().single);
    expect(calls, hasLength(callsPerNight));
    return scoredPart(r.json);
  }

  test('a finished night is not scored again after a restart, nor after an update of the scorer', () async {
    writeRun(recordings, start, 6);
    final calls = <String>[];
    final first = scorer(recordings, calls);
    expect(first.due().map((n) => n.name), [night]);
    await first.score(first.due().single);
    expect(calls, hasLength(callsPerNight));

    // the app starts again: nothing is due, nothing waits for "Try again"
    final again = scorer(recordings, calls);
    expect(again.due(), isEmpty);
    expect(again.blocked(), isEmpty);

    // an update with another scorer (and an older report without drift_off): the report stays as it is
    final j = store.read(night)!.json
      ..['model'] = 'anysleep older pieces'
      ..remove('drift_off');
    store.write(j);
    final updated = scorer(recordings, calls);
    expect(updated.due(), isEmpty);
    expect(updated.blocked(), isEmpty);
    expect(updated.olderScorer(store.read(night)!), isTrue);
    expect(calls, hasLength(callsPerNight), reason: 'no model call after the update');

    // "Score again" on its page: scored once more, from the start, with the current scorer
    updated.request(night);
    expect(updated.due().map((n) => n.name), [night]);
    final steps = <String>[];
    await updated.score(updated.due().single, progress: steps.add);
    expect(steps.first, 'Preparing the recording to score it again');
    expect(calls, hasLength(2 * callsPerNight));
    expect(updated.olderScorer(store.read(night)!), isFalse);
    expect(scorer(recordings, calls).due(), isEmpty);

    // new data the same night (10+ minutes) is the one thing that scores it again by itself
    writeRun(recordings, start.add(const Duration(minutes: 7)), 12);
    final grown = scorer(recordings, calls);
    expect(grown.due().single.recordings, hasLength(2));
    steps.clear();
    await grown.score(grown.due().single, progress: steps.add);
    expect(steps.first, 'Preparing the recording: new data since its report', reason: 'the screen says why');
  });

  test('an app killed during a model call goes on from its last saved call, with the numbers of one go', () async {
    final want = await inOneGo();
    writeRun(recordings, start, 6);
    final calls = <String>[];
    final killed = scorer(recordings, calls, hangAt: 7); // the 7th call never returns
    unawaited(killed.score(killed.due().single));
    await until(() => calls.length == 7);
    expect(store.markerFor(night).existsSync(), isTrue);

    // the app starts again: the night is due by itself (not "stopped, try again"), and only what was left is done
    final calls2 = <String>[];
    final restarted = scorer(recordings, calls2);
    expect(restarted.blocked(), isEmpty);
    expect(restarted.due().map((n) => n.name), [night]);
    final steps = <String>[];
    final r = await restarted.score(restarted.due().single, progress: steps.add);
    expect(calls2.first, calls[6], reason: 'the unfinished 7th call is made again');
    expect(calls2, hasLength(callsPerNight - 6));
    expect(steps.first, 'Preparing the recording to go on from 50 %');
    expect(steps.contains('Sleep model 50 % (run 2 of 3)'), isTrue);
    expect(scoredPart(r.json), want);
    expect(jsonEncode(scoredPart(store.read(night)!.json)), jsonEncode(want));
    expect(store.markerFor(night).existsSync(), isFalse);
    expect(restarted.progressStore.read(night), isNull, reason: 'the progress file goes with the report');
  });

  test('every saved step resumes to the same probabilities, bit for bit', () async {
    final input = fakeInput(0);
    final saved = <Uint8List>[];
    final calls = <String>[];
    final whole = await stageProbabilities(
      input,
      3,
      (run) async => CountingRun(run, calls),
      saved: (p) async => saved.add(p.toBytes()),
    );
    expect(saved, hasLength(callsPerNight));
    for (final bytes in saved) {
      final from = ModelProgress.fromBytes(bytes)!;
      final done = from.calls; // the resumed go goes on in this object
      final rest = <String>[];
      final again = await stageProbabilities(input, 3, (run) async => CountingRun(run, rest), from: from);
      expect(rest, hasLength(callsPerNight - done));
      expect(again, whole);
    }
  });

  test('a go that keeps dying while preparing waits for "Try again" after 3 tries; then goes on', () async {
    writeRun(recordings, start, 6);
    final calls = <String>[];
    Future<ModelInput?> neverReady(List<File> files) => Completer<ModelInput?>().future;
    for (var go = 1; go <= maxTries; go++) {
      final s = scorer(recordings, calls, prepare: neverReady);
      expect(s.due().map((n) => n.name), [night], reason: 'go $go starts by itself');
      unawaited(s.score(s.due().single));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = scorer(recordings, calls);
    expect(s.due(), isEmpty);
    expect(s.blocked(), {night: ''});
    s.unblock(night);
    expect(s.due().map((n) => n.name), [night]);
    await s.score(s.due().single);
    expect(calls, hasLength(callsPerNight));
  });

  test('a night that starts stops the go at its next model call: not a failure, nothing lost', () async {
    final want = await inOneGo();
    writeRun(recordings, start, 6);
    final calls = <String>[];
    final s = scorer(recordings, calls);
    var stop = false;
    final go = s.score(
      s.due().single,
      between: () async {
        if (calls.length == 5) stop = true;
        if (stop) throw const ScoringPaused('a night records');
      },
    );
    await expectLater(go, throwsA(isA<ScoringPaused>()));
    expect(calls, hasLength(5));
    expect(store.markerFor(night).existsSync(), isFalse);
    expect(s.blocked(), isEmpty);
    expect(s.progressStore.read(night)!.tries, 0, reason: 'a pause is not a failed try');
    final calls2 = <String>[];
    final later = scorer(recordings, calls2);
    final r = await later.score(later.due().single);
    expect(calls2, hasLength(callsPerNight - 5));
    expect(scoredPart(r.json), want);
  });

  test('an older app left a "scoring" marker on a night that has its report: cleared, not shown as stopped', () async {
    // the owner's phone (2026-11-19): an update ended the old app while it scored the night a second time
    writeRun(recordings, start, 6);
    final calls = <String>[];
    final s = scorer(recordings, calls);
    await s.score(s.due().single);
    store.write(store.read(night)!.json..['model'] = 'anysleep older pieces');
    store.markerFor(night).writeAsStringSync('');
    final after = scorer(recordings, calls);
    expect(after.blocked(), isEmpty);
    expect(after.due(), isEmpty);
    expect(store.markerFor(night).existsSync(), isFalse);
    expect(calls, hasLength(callsPerNight));
  });

  test('progress files: an exact round trip; damaged ones and ones of other recordings are not used', () async {
    final p = NightProgress(
      inputs: {'a.f32': 100, 'b.f32': 2000},
      model: phoneModelId,
      tries: 2,
      seconds: 12.5,
      prepared: (
        startUnix: 5,
        recordedSamples: 7500 * epochs,
        missingSamples: 3,
        gap: [for (var e = 0; e < epochs; e++) e.isOdd],
      ),
      progress: ModelProgress(epochs, runCount: 3)
        ..run = 2
        ..pass = 2
        ..piece = 1
        ..calls = 6
        ..means = Float32List.fromList(List.generate(4 * meansWidth, (i) => i / 3)),
    );
    p.progress!.sum[17] = 0.1 + 0.2;
    final bytes = encodeProgress(p);
    final back = decodeProgress(bytes)!;
    expect(encodeProgress(back), bytes);
    expect((back.tries, back.seconds, back.progress!.means![5]), (2, 12.5, Float32List.fromList([5 / 3])[0]));
    expect(back.prepared!.gap, p.prepared!.gap);
    expect(back.matches({'a.f32': 100, 'b.f32': 2000}, phoneModelId), isTrue);
    expect(back.matches({'a.f32': 100, 'b.f32': 2001}, phoneModelId), isFalse);
    expect(back.matches({'a.f32': 100, 'b.f32': 2000}, 'another model'), isFalse);
    expect(decodeProgress(Uint8List.sublistView(bytes, 0, bytes.length - 1)), isNull);
    final nan = ModelProgress(epochs, runCount: 3)..sum[0] = double.nan;
    expect(ModelProgress.fromBytes(nan.toBytes()), isNull);

    // in the scorer: a progress file of other recordings is dropped and the night is scored from the start
    writeRun(recordings, start, 6);
    final s = scorer(recordings, <String>[]);
    s.progressStore.write(night, p);
    expect(s.due().map((n) => n.name), [night]);
    expect(s.progressStore.read(night), isNull);
    s.progressStore.fileFor(night).writeAsStringSync('not a progress file');
    expect(s.due().map((n) => n.name), [night]);
  });

  group('SleepScoring', () {
    test('runSoon waits before it starts; halt stops a running go at its next call and keeps its progress', () async {
      writeRun(recordings, start, 6);
      final calls = <String>[];
      final gate = Completer<void>();
      final s = SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => CountingRun(run, calls),
        prepare: (files) async {
          await gate.future;
          return fakeInput(start.millisecondsSinceEpoch ~/ 1000);
        },
        see: (files) async => null,
      );
      final scoring = SleepScoring(s, settle: const Duration(milliseconds: 150));
      scoring.runSoon();
      scoring.runSoon(); // a second call changes nothing
      expect((scoring.busy, scoring.starting), (false, true));
      await until(() => scoring.step == 'Preparing the recording');
      expect((scoring.busy, scoring.night), (true, night));
      scoring.halt(); // Start night
      gate.complete();
      await until(() => !scoring.busy);
      expect(calls, isEmpty, reason: 'stopped before its first model call');
      expect(scoring.blocked, isEmpty);
      expect(s.due().map((n) => n.name), [night]);
      await scoring.run(); // after Stop: on from where it was
      expect(calls, hasLength(callsPerNight));
      expect(scoring.reports.single.nightOf, night);
    });

    test("runSoon's then (packing old nights, rows 540-549) runs once the go has ended; halt drops it", () async {
      writeRun(recordings, start, 6);
      final calls = <String>[];
      final scoring = SleepScoring(
        SleepScorer(
          recordingsDir: recordings,
          store: store,
          openRun: (run) async => CountingRun(run, calls),
          prepare: (files) async => fakeInput(start.millisecondsSinceEpoch ~/ 1000),
          see: (files) async => null,
        ),
        settle: const Duration(milliseconds: 50),
      );
      final after = <String>[];
      scoring.runSoon(then: () => after.add('first'));
      scoring.runSoon(then: () => after.add('packed')); // the latest one asked replaces it
      expect(after, isEmpty);
      await until(() => after.isNotEmpty);
      expect(after, ['packed']);
      expect(calls, hasLength(callsPerNight), reason: 'after the scoring, never before it');
      expect(scoring.busy, isFalse);

      scoring.runSoon(then: () => after.add('again'));
      scoring.halt(); // Start night before the go began
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(after, ['packed']);
      await scoring.run();
      expect(after, ['packed'], reason: 'a halt dropped it');
    });

    test('a night recording or a session stops it; while the laptop copies it waits and says so', () async {
      writeRun(recordings, start, 6);
      final calls = <String>[];
      final steps = <String?>[];
      var copying = true;
      String? stop;
      final scoring = SleepScoring(
        SleepScorer(
          recordingsDir: recordings,
          store: store,
          openRun: (run) async => _SlowRun(CountingRun(run, calls)), // a call takes a while, as on the phone
          prepare: (files) async => fakeInput(start.millisecondsSinceEpoch ~/ 1000),
          see: (files) async => null,
        ),
        stopFor: () => stop,
        waitFor: () => copying ? 'the laptop copies files' : null,
        poll: const Duration(milliseconds: 20),
      );
      scoring.addListener(() => steps.add(scoring.step));
      final go = scoring.run();
      await until(() => scoring.step == 'Waiting while the laptop copies files');
      expect(calls, isEmpty);
      copying = false;
      await until(() => calls.length >= 3);
      stop = 'a session runs';
      await go;
      expect(calls.length, lessThan(callsPerNight));
      expect(scoring.blocked, isEmpty);
      stop = null;
      await scoring.run();
      expect(calls, hasLength(callsPerNight));
      expect(steps, contains('Sleep model 0 % (run 1 of 3)'));
    });
  });

  test('a night started where the screen does not see it (the headband watcher) stops it: the rule may ask Android', () async {
    // The watcher starts the night recorder from its own engine (DECISIONS 604): the screen's flags say nothing, so
    // the screen's rule asks whether the recorder's service runs, before every model call.
    writeRun(recordings, start, 6);
    final calls = <String>[];
    var serviceRuns = false;
    var asked = 0;
    final scoring = SleepScoring(
      SleepScorer(
        recordingsDir: recordings,
        store: store,
        openRun: (run) async => _SlowRun(CountingRun(run, calls)),
        prepare: (files) async => fakeInput(start.millisecondsSinceEpoch ~/ 1000),
        see: (files) async => null,
      ),
      stopFor: () async {
        asked++;
        await Future<void>.delayed(const Duration(milliseconds: 1)); // a platform call
        return serviceRuns ? 'a night records' : null;
      },
    );
    final go = scoring.run();
    await until(() => calls.length >= 3);
    serviceRuns = true; // the watcher's "Start the night"
    final at = calls.length;
    await go;
    expect(calls.length, lessThanOrEqualTo(at + 1), reason: 'went on scoring beside the night');
    expect(calls.length, lessThan(callsPerNight));
    expect(asked, greaterThanOrEqualTo(at));
    expect(scoring.blocked, isEmpty, reason: 'a pause, not a failure');
    serviceRuns = false;
    await scoring.run();
    expect(calls, hasLength(callsPerNight));
  });

  test('Share on Wi-Fi answers while a night is scored with a heavy preparation', () async {
    writeRun(recordings, start, 6);
    final s = SleepScorer(
      recordingsDir: recordings,
      store: store,
      openRun: (run) async => _SlowRun(CountingRun(run, <String>[])),
      prepare: (files) => Isolate.run(heavyPreparation),
      see: (files) async => null,
    );
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    final host = ShareHost(filesDir: root.path, onLog: (_) {});
    await host.start(
      ShareConfig(
        on: true,
        token: 'abcdefghjkmn',
        port: port,
        offAtMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ),
    );
    try {
      await until(() => host.status.up);
      var done = false;
      final go = s.score(s.due().single).whenComplete(() => done = true);
      final waits = <int>[];
      final client = HttpClient();
      try {
        while (!done) {
          for (final path in ['/state', '/files']) {
            final watch = Stopwatch()..start();
            final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
            req.headers.set('Authorization', 'Bearer abcdefghjkmn');
            final res = await req.close();
            await res.drain<void>();
            expect(res.statusCode, 200, reason: path);
            waits.add(watch.elapsedMilliseconds);
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } finally {
        client.close(force: true);
      }
      await go;
      expect(waits.length, greaterThan(10), reason: 'answered many times while the night was scored');
      expect(waits.reduce(math.max), lessThan(1500), reason: 'the slowest answer while scoring: $waits');
      expect(host.copying, isTrue, reason: 'the list was just asked for');
    } finally {
      await host.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

final int nightStartUnix = DateTime(2026, 11, 18, 23, 0).millisecondsSinceEpoch ~/ 1000;

/// A stand-in for the preparation of a long night: seconds of work and big arrays, in a background isolate.
ModelInput? heavyPreparation() {
  final watch = Stopwatch()..start();
  var acc = 0.0;
  while (watch.elapsedMilliseconds < 2500) {
    final big = Float64List(2000000);
    for (var i = 0; i < big.length; i += 7) {
      big[i] = i * 1.5;
      acc += big[i];
    }
  }
  return acc > 0 ? fakeInput(nightStartUnix) : null;
}

/// A model call that takes a while, as on the phone.
class _SlowRun implements StageRun {
  _SlowRun(this.inner);
  final StageRun inner;

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return inner.logits(x, epochs, means: means);
  }

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return inner.sums(x, epochs, from: from, to: to);
  }
}
