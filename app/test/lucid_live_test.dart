// Lucid dream cues during the night (lib/lucid/live_cues.dart and the night recorder, DECISIONS 300-303): the live
// model starts an hour before the cue hours, cues play only when the rule allows, a silent night of the test does
// everything the same but plays nothing, and the cues can never stop the recording: a watch that throws, takes too
// long or grows the app too much is switched off with one log line. ONNX cannot run in `flutter test`, so a scripted
// model says which stage each epoch is; a synthetic signal makes sideways eye movements with a quiet back of the head.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/lucid/bell.dart';
import 'package:eeg_tracker/lucid/live_cues.dart';
import 'package:eeg_tracker/lucid/plan.dart';
import 'package:eeg_tracker/lucid/rule.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/watch_guard.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show LiveWindow;
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart';

/// Every epoch is the stage [script] says (top probability 0.9); [fail] makes every call throw.
class ScriptedModel implements LiveModel {
  ScriptedModel(this.script);
  final String Function(int epoch) script;
  Object? fail;
  bool closed = false;

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    if (fail != null) throw fail!;
    const names = ['W', 'N1', 'N2', 'N3', 'R'];
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var j = 0; j < 5; j++) {
        p[e * 5 + j] = 0.025;
      }
      p[e * 5 + names.indexOf(script(first + e))] = 0.9;
    }
    return p;
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeBell implements CueBell {
  final List<double> gains = [];
  Object? fail;

  @override
  Future<bool> play(File cue, double gain) async {
    if (fail != null) throw fail!;
    gains.add(gain);
    return true;
  }

  @override
  Future<({int volume, int max})?> mediaVolume() async => (volume: 7, max: 15);
}

Future<Float32List> zeros(LiveWindow w) async => Float32List(w.epochs * 3840 * 4);

/// 2026-11-25 01:00:00 local: the night's first sample.
final int startMs = DateTime(2026, 11, 25, 1).millisecondsSinceEpoch;

/// Sample [i] in volts: a quiet back of the head, the temples held apart by a sideways eye movement each 20 s, back
/// 1 s later (a burst of two movements); from [jawFrom] seconds on a little jaw muscle each 7 s.
Sample sampleAt(int i, {double? jawFromS}) {
  final t = i / 250;
  final inLook = t % 20 >= 10 && t % 20 < 11;
  final eye = inLook ? 60.0 : 0.0;
  var t3 = 20000 + eye + 2 * math.sin(i * 0.7), t4 = -15000 - eye + 2 * math.cos(i * 0.9);
  if (jawFromS != null && t >= jawFromS && t % 7 < 1) {
    t3 += 40 * math.sin(i * 2.1);
    t4 += 40 * math.sin(i * 2.3);
  }
  return (
    pack: i % 2048,
    o1: (12000 + 10 * math.sin(i * 0.25)) * 1e-6,
    o2: (-8000 + 8 * math.cos(i * 0.1)) * 1e-6,
    t3: t3 * 1e-6,
    t4: t4 * 1e-6,
  );
}

/// A secret whose schedule starts with a cue night and has a silent night at [silentAt].
String saltWith({required int silentAt}) {
  for (var k = 0; ; k++) {
    final salt = k.toRadixString(16).padLeft(64, '0');
    final s = LucidSealed.draw(salt);
    if (s.arms[0] == NightArm.cue && s.arms[silentAt] == NightArm.silent) return salt;
  }
}

void main() {
  late Directory dir;
  late LucidStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('lucid_live_test');
    store = LucidStore(Directory('${dir.path}/lucid'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('LiveCues on its own', () {
    LiveCues? open({ScriptedModel? model, FakeBell? bell, int nightMs = 0}) => LiveCues.open(
      store: store,
      nightStartMs: startMs + nightMs,
      model: () => model ?? ScriptedModel((_) => 'R'),
      bell: bell ?? FakeBell(),
      now: DateTime.fromMillisecondsSinceEpoch(startMs + nightMs),
      scale: zeros,
      cuesAfter: const Duration(minutes: 10),
      modelBefore: const Duration(minutes: 6),
    );

    /// Feeds [seconds] of [sampleAt] in 1 s batches from the night's start, letting the model's calls finish.
    Future<List<String>> feed(LiveCues c, int seconds, {int fromS = 0, double? jawFromS, int nightMs = 0}) async {
      final events = <String>[];
      for (var s = fromS; s < seconds; s++) {
        final rows = [for (var j = 0; j < 250; j++) sampleAt(s * 250 + j, jawFromS: jawFromS)];
        final arrival = DateTime.fromMillisecondsSinceEpoch(startMs + nightMs + (s + 1) * 1000);
        c.add(arrival, rows, firstOfFile: s == fromS);
        if (s % 10 == 0) c.check(arrival, drift: 'asleep');
        events.addAll(c.takeEvents());
        await Future<void>.delayed(Duration.zero);
      }
      return events;
    }

    test('off by default: no cues, no files', () {
      expect(open(), isNull);
      expect(store.nights(), isEmpty);
    });

    test('the recorder\'s factory: nothing, not even the folder, while off; the cue file once on', () {
      final make = lucidCuesFor('${dir.path}/recordings', model: () => ScriptedModel((_) => 'R'), bell: FakeBell());
      expect(make(startMs), isNull);
      expect(store.dir.existsSync(), isFalse);
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      expect(make(startMs), isNotNull);
      expect(store.cueWav.lengthSync(), cueWavBytes().length);
    });

    test('a cue night: the model from an hour before, cues in dream sleep 30 s apart, louder each time', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22), mediaVolume: 7, mediaVolumeMax: 15);
      store.setOn(true, DateTime(2026, 11, 24, 22));
      store.ensureTest(DateTime(2026, 11, 24, 22), salt: saltWith(silentAt: 1));
      final bell = FakeBell();
      final c = open(bell: bell)!;
      final first = c.takeEvents();
      expect(first.single, 'lucid cues on: night 1 of the test; cues from 01:10, the sleep model from 01:04');
      final events = await feed(c, 14 * 60);
      expect(events.first, 'lucid cues: sleep model on');
      final cues = [
        for (final e in events)
          if (e.startsWith('lucid cue ')) e,
      ];
      expect(cues.first, 'lucid cue 1 (dream sleep 0.90, +0 dB)');
      final r = store.night(startMs)!;
      expect(r.index, 0);
      expect(r.cues.length, cues.length);
      expect(r.cues.first.atMs, greaterThanOrEqualTo(startMs + 10 * 60 * 1000));
      for (var j = 1; j < r.cues.length; j++) {
        expect(r.cues[j].atMs - r.cues[j - 1].atMs, greaterThanOrEqualTo(30000));
      }
      expect(bell.gains.length, cues.length);
      expect(bell.gains.first, closeTo(0.1, 1e-9));
      expect(bell.gains[1], closeTo(0.1 * cueGain(1), 1e-9));
      expect(r.running, isTrue);
      expect(r.mediaVolume, 7);
      expect(File('${store.dir.path}/plays.jsonl').readAsLinesSync(), hasLength(cues.length));
      await c.close();
      expect(store.night(startMs)!.running, isFalse);
      expect(store.night(startMs)!.phase, 'ended');
    });

    test('a silent night does everything the same but plays nothing', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      store.ensureTest(DateTime(2026, 11, 24, 22), salt: saltWith(silentAt: 1));
      final cueBell = FakeBell();
      final a = open(bell: cueBell)!;
      a.takeEvents();
      final cueEvents = await feed(a, 13 * 60);
      await a.close();
      const day = 24 * 3600 * 1000;
      final silentBell = FakeBell();
      final b = open(bell: silentBell, nightMs: day)!;
      expect(b.takeEvents().single, startsWith('lucid cues on: night 2 of the test'));
      final silentEvents = await feed(b, 13 * 60, nightMs: day);
      await b.close();
      expect(silentEvents, cueEvents, reason: 'the same markers on both kinds of night');
      expect(cueBell.gains, isNotEmpty);
      expect(silentBell.gains, isEmpty);
      final ra = store.night(startMs)!, rb = store.night(startMs + day)!;
      expect([for (final c in rb.cues) c.atMs - day], [for (final c in ra.cues) c.atMs]);
      expect(rb.toJson().keys, ra.toJson().keys);
      expect(rb.toJson().toString(), isNot(contains('silent')));
    });

    test('no loudness set yet: the night counts, but the cues are off with a sentence', () async {
      store.setOn(true, DateTime(2026, 11, 24, 22));
      final c = open()!;
      expect(c.finished, isTrue);
      expect(c.takeEvents().last, 'lucid cues off: No loudness is set yet: do the evening practice first.');
      expect(store.night(startMs)!.off, contains('evening practice'));
    });

    test('a model that fails switches the cues off for the night', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      final model = ScriptedModel((_) => 'R')..fail = StateError('no model');
      final c = open(model: model)!;
      final events = await feed(c, 12 * 60);
      expect(events.last, startsWith('lucid cues off: The sleep model stopped'));
      expect(c.finished, isTrue);
      expect(model.closed, isTrue);
    });

    test('jaw muscle again and again keeps the cues back', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      final bell = FakeBell();
      final c = open(bell: bell)!;
      await feed(c, 14 * 60, jawFromS: 9 * 60);
      await c.close();
      expect(store.night(startMs)!.cues, isEmpty);
      expect(c.rule!.whyNot(c.rule!.cuesFrom + 60, 'asleep'), isNotNull);
    });

    test('deep sleep before: no cues for 10 minutes after it', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      // the model's clock starts at 01:04; epochs up to 01:09 read deep sleep, then dream sleep
      final c = open(model: ScriptedModel((e) => e < 10 ? 'N3' : 'R'))!;
      await feed(c, 24 * 60);
      await c.close();
      final r = store.night(startMs)!;
      expect(r.cues, isNotEmpty);
      // the last deep epoch is epoch 9 (01:08:30-01:09); the newest epoch read must be 21 later, epoch 30, which is
      // handed out 2.5 minutes after it began: 01:04 + 35 epochs = 01:21:30
      expect(r.cues.first.atMs, greaterThanOrEqualTo(startMs + (4 * 60 + 35 * 30) * 1000));
    });

    test('a process that ended while the model ran keeps the cues off for the rest of that night', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      final c = open()!;
      await feed(c, 11 * 60);
      expect(store.night(startMs)!.running, isTrue); // the process "dies" here: no close
      final again = open()!;
      expect(again.finished, isTrue);
      expect(again.takeEvents().last, contains('the app ended while the sleep model ran'.substring(4)));
      expect(store.night(startMs)!.index, 0, reason: 'the same night keeps its number');
      expect(store.nights(), hasLength(1));
    });

    test('Lights off moves the cue hours', () async {
      store.setLevel(0.1, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      final c = open()!;
      c.takeEvents();
      c.check(DateTime.fromMillisecondsSinceEpoch(startMs + 60000), lightsOffMs: startMs + 2 * 60000, drift: null);
      expect(c.takeEvents().single, 'lucid cues from 01:12 (4.5 h after Lights off)');
      expect(store.night(startMs)!.cuesFromMs, startMs + 12 * 60000);
    });
  });

  group('through the night recorder', () {
    final double t0 = startMs / 1000;
    const fast = RecorderTiming(
      tick: Duration(milliseconds: 10),
      ticksPerCheck: 5,
      scanFor: Duration(milliseconds: 20),
      contactFor: Duration(milliseconds: 20),
      settle: Duration(milliseconds: 5),
      retryWait: Duration(milliseconds: 5),
      sdkTimeout: Duration(milliseconds: 300),
      connectTimeout: Duration(milliseconds: 300),
      notFoundWait: Duration(milliseconds: 10),
      notFoundWaitLong: Duration(milliseconds: 10),
      stopTimeout: Duration(seconds: 2),
      reconnectWaits: [Duration(milliseconds: 5)],
      rescanFor: Duration(milliseconds: 20),
    );

    NightRecorder recorder(FastBand band, {CueFactory? cues, GuardLimits limits = const GuardLimits()}) =>
        NightRecorder(
          finder: OneFinder(band),
          dir: dir,
          store: MemoryNightStore(),
          onStatus: (_) {},
          onStuck: (_) async {},
          timing: fast,
          clock: band.now,
          watch: null,
          cues: cues,
          cueLimits: limits,
        );

    String logOf() =>
        [for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log'))) f.readAsStringSync()]
            .join();
    int saved() => dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.f32'))
        .fold(0, (n, f) => n + f.lengthSync() ~/ recordBytes);

    test('a watch that throws is switched off with one log line; every sample is saved', () async {
      final band = FastBand(start: t0);
      final broken = BrokenCues(failAt: 20);
      final r = recorder(band, cues: (_) => broken);
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 60);
      await r.stop();
      await running;
      expect(saved(), band.sent);
      final log = logOf();
      expect(RegExp('lucid cues stopped').allMatches(log), hasLength(1));
      expect(log, contains('lucid cues stopped: Bad state: cues broke; the recording goes on'));
      expect(broken.closed, isTrue);
    });

    test('a watch that takes too long is switched off', () async {
      final band = FastBand(start: t0);
      final r = recorder(
        band,
        cues: (_) => BrokenCues(slowMs: 3),
        limits: const GuardLimits(budget: 0.05, after: Duration(milliseconds: 200)),
      );
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 30);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await r.stop();
      await running;
      expect(logOf(), contains('lucid cues stopped: it took'));
      expect(saved(), band.sent);
    });

    test('a watch while the app grows by too much is switched off', () async {
      final band = FastBand(start: t0);
      var rss = 100 << 20;
      final r = recorder(
        band,
        cues: (_) => BrokenCues(),
        limits: GuardLimits(memoryMb: 50, rss: () => rss += 20 << 20),
      );
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 30);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await r.stop();
      await running;
      expect(logOf(), matches(RegExp(r'lucid cues stopped: the app grew by \d+ MB \(over 50 MB\)')));
      expect(saved(), band.sent);
    });

    test('a factory that throws costs only the cues', () async {
      final band = FastBand(start: t0);
      final r = recorder(band, cues: (_) => throw StateError('no files'));
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 20);
      await r.stop();
      await running;
      expect(logOf(), contains('lucid cues could not start: Bad state: no files; the recording goes on'));
      expect(saved(), band.sent);
    });

    test('the cues\' moments become markers in the night\'s recording, and the log ends with their cost', () async {
      final band = FastBand(start: t0);
      final r = recorder(band, cues: (_) => BrokenCues(say: 'lucid cue 1 (dream sleep 0.90, +0 dB)'));
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 20);
      await r.stop();
      await running;
      final markers = [
        for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')))
          ...f.readAsLinesSync(),
      ].join('\n');
      expect(markers, contains('lucid cue 1 (dream sleep 0.90, +0 dB)'));
      expect(logOf(), matches(RegExp(r"lucid cues: [0-9.]+ s of the recorder's time over [0-9.]+ min")));
    });
  });
}

/// A cue watch that fails on its [failAt]-th batch, spends [slowMs] on every batch, or says [say] once.
class BrokenCues implements CueWatch {
  BrokenCues({this.failAt, this.slowMs = 0, this.say});
  final int? failAt;
  final int slowMs;
  String? say;
  int batches = 0;
  bool closed = false;

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (++batches == failAt) throw StateError('cues broke');
    if (slowMs > 0) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < slowMs) {}
    }
  }

  @override
  void check(DateTime now, {int? lightsOffMs, String? drift}) {}

  @override
  List<String> takeEvents() {
    final s = say;
    say = null;
    return s == null ? const [] : [s];
  }

  @override
  bool get finished => false;

  @override
  Future<void> close() async => closed = true;
}
