// One live sleep model for the night (lib/sleep/night_scorer.dart, DECISIONS 330): the smart alarm and the lucid dream
// cues listen to one scorer instead of each opening AnySleep for itself. It runs while either needs it and is freed when
// neither does; with both on, one model is opened and each makes the same decisions as it does alone; the recorder's
// one guard switches all of it off with one log line (the phone's alarm still rings at the window's end, the cues
// stop). ONNX cannot run in `flutter test`, so a scripted model says which stage each 30 s of the clock is.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/alarm/bell.dart';
import 'package:eeg_tracker/alarm/live_alarm.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/lucid/bell.dart';
import 'package:eeg_tracker/lucid/live_cues.dart';
import 'package:eeg_tracker/lucid/plan.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/recorder/watch_guard.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show LiveWindow;
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:eeg_tracker/sleep/night_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart';

/// Every 30 s of the clock is the stage [script] says for its start (unix ms), top probability 0.9: the epochs of any
/// scorer whose start is on the same 30 s grid read the same. [origin] is the scorer's first sample (unix s).
class ClockModel implements LiveModel {
  ClockModel(this.origin, this.script);
  final int? Function() origin;
  final String Function(int epochStartMs) script;
  Object? fail;
  int calls = 0;
  bool closed = false;

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    calls++;
    if (fail != null) throw fail!;
    final o = origin()!;
    const names = ['W', 'N1', 'N2', 'N3', 'R'];
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var j = 0; j < 5; j++) {
        p[e * 5 + j] = 0.025;
      }
      p[e * 5 + names.indexOf(script((o + (first + e) * 30) * 1000))] = 0.9;
    }
    return p;
  }

  @override
  Future<void> close() async => closed = true;
}

class AlarmBellFake implements AlarmBell {
  final List<String> reasons = [];

  @override
  Future<bool> ringNow(String reason) async {
    reasons.add(reason);
    return true;
  }
}

class CueBellFake implements CueBell {
  final List<double> gains = [];

  @override
  Future<bool> play(File cue, double gain) async {
    gains.add(gain);
    return true;
  }

  @override
  Future<({int volume, int max})?> mediaVolume() async => (volume: 7, max: 15);
}

/// A listener that needs the model from [from] until [until] (unix ms) and keeps every stage it is given.
class Listener implements StageListener {
  Listener(this.who, {required this.from, required this.until, this.failAt});
  @override
  final String who;
  final int from, until;
  final int? failAt;
  final List<(int, int, String)> got = [];
  int changes = 0;

  @override
  bool needs(double t0Ms) => t0Ms >= from && t0Ms < until;

  @override
  void scored(LiveStage st, int epochStartMs) {
    if (got.length == failAt) throw StateError('$who broke');
    got.add((st.epoch, epochStartMs, st.stage));
  }

  @override
  void modelChanged() => changes++;
}

Future<Float32List> zeros(LiveWindow w) async => Float32List(w.epochs * 3840 * 4);

/// 2026-11-25 01:00:00 local: the night's first sample.
final int startMs = DateTime(2026, 11, 25, 1).millisecondsSinceEpoch;
const int minute = 60000;

/// Sample [i] in volts (lucid_live_test.dart's signal): a quiet back of the head, the temples held apart by a sideways
/// eye movement each 20 s and back 1 s later (an eye burst).
Sample sampleAt(int i) {
  final t = i / 250;
  final eye = t % 20 >= 10 && t % 20 < 11 ? 60.0 : 0.0;
  return Sample.four(
    pack: i % 2048,
    o1: (12000 + 10 * math.sin(i * 0.25)) * 1e-6,
    o2: (-8000 + 8 * math.cos(i * 0.1)) * 1e-6,
    t3: (20000 + eye + 2 * math.sin(i * 0.7)) * 1e-6,
    t4: (-15000 - eye + 2 * math.cos(i * 0.9)) * 1e-6,
  );
}

/// A secret whose first night of the test has sound.
String cueFirst() {
  for (var k = 0; ; k++) {
    final salt = k.toRadixString(16).padLeft(64, '0');
    if (LucidSealed.draw(salt).arms[0] == NightArm.cue) return salt;
  }
}

/// A FastBand with [sampleAt]'s eye movements.
class EyeBand extends FastBand {
  EyeBand({required super.start});
  int _j = 0;

  @override
  List<Sample> batch() => [for (var k = 0; k < perBatch; k++) sampleAt(_j++)];
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('night_scorer_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<Sample> second(int s) => [for (var j = 0; j < 250; j++) sampleAt(s * 250 + j)];
  DateTime arrival(int s) => DateTime.fromMillisecondsSinceEpoch(startMs + (s + 1) * 1000);

  group('NightScorer', () {
    late NightScorer scorer;
    late List<ClockModel> made;
    setUp(() {
      made = [];
      scorer = NightScorer(
        model: () => made.isEmpty || made.last.closed
            ? (made..add(ClockModel(() => scorer.startUnix, (_) => 'N2'))).last
            : throw StateError('a second model while one is open'),
        scale: zeros,
      );
    });

    Future<void> feed(int seconds) async {
      for (var s = 0; s < seconds; s++) {
        scorer.add(arrival(s), second(s), firstOfFile: s == 0);
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('overlapping hours share one model; each gets every epoch from its start, on one clock', () async {
      final a = Listener('smart alarm', from: startMs + 2 * minute, until: startMs + 20 * minute);
      final b = Listener('lucid cues', from: startMs + 10 * minute, until: startMs + 30 * minute);
      scorer
        ..join(a)
        ..join(b);
      await feed(32 * 60);
      expect(scorer.loads, 1);
      expect(made, hasLength(1));
      expect(made.single.closed, isTrue, reason: 'freed once neither needs it');
      expect(scorer.stager, isNull);
      expect(scorer.takeEvents(), [
        'live sleep model on for the smart alarm (load 1 tonight)',
        'live sleep model: shared with the lucid cues (no second copy)',
        startsWith('live sleep model off, no one needs it ('),
      ]);
      final shared = {for (final (e, ms, _) in a.got) e: ms};
      for (final (e, ms, _) in b.got) {
        if (shared.containsKey(e)) expect(ms, shared[e], reason: 'epoch $e starts at the same time for both');
        expect(ms, startMs + 2 * minute + e * 30000);
      }
      expect(b.got.first.$2, lessThanOrEqualTo(startMs + 10 * minute), reason: 'b is given the epochs from its start');
      expect(a.got.last.$2, lessThan(startMs + 20 * minute));
    });

    test('hours apart: the model is freed between them and opened again, never two at once', () async {
      final a = Listener('smart alarm', from: startMs + 2 * minute, until: startMs + 9 * minute);
      final b = Listener('lucid cues', from: startMs + 15 * minute, until: startMs + 24 * minute);
      scorer
        ..join(a)
        ..join(b);
      await feed(26 * 60);
      expect(scorer.loads, 2);
      expect(made.every((m) => m.closed), isTrue);
      expect(b.got.first.$2, startMs + 15 * minute, reason: 'the new model starts its clock at its first sample');
    });

    test('a listener that throws is dropped; the other keeps its stages', () async {
      final a = Listener('smart alarm', from: startMs, until: startMs + 20 * minute, failAt: 3);
      final b = Listener('lucid cues', from: startMs, until: startMs + 20 * minute);
      scorer
        ..join(a)
        ..join(b);
      await feed(12 * 60);
      expect(a.got, hasLength(3));
      expect(b.got.length, greaterThan(10));
      expect(scorer.stager, isNotNull, reason: 'still needed by the cues');
    });

    test('leaving frees the model at once when no one else uses it', () async {
      final a = Listener('smart alarm', from: startMs, until: startMs + 60 * minute);
      scorer.join(a);
      await feed(6 * 60);
      expect(made.single.closed, isFalse);
      await scorer.leave(a);
      expect(made.single.closed, isTrue);
    });
  });

  group('the smart alarm and the lucid cues on one night', () {
    // deep sleep, then dream sleep with one awake epoch at 01:34 (a stir after the cues around it), deep sleep again,
    // then light sleep (on the 30 s grid of the night's start)
    String script(int ms) {
      final m = (ms - startMs) / minute;
      if (m >= 34 && m < 34.5) return 'W';
      if (m < 20 || (m >= 50 && m < 58)) return 'N3';
      return m < 50 ? 'R' : 'N2';
    }

    // the alarm's model from 01:02 (window 02:02-02:12), the cues' from 01:04 (cues from 01:10)
    final plan = AlarmPlan(endMs: startMs + 72 * minute, windowMin: 10);

    LucidStore lucidStore(String name) {
      final s = LucidStore(Directory('${dir.path}/$name'));
      s.setLevel(0.1, DateTime(2026, 11, 24, 22));
      s.setOn(true, DateTime(2026, 11, 24, 22));
      s.ensureTest(DateTime(2026, 11, 24, 22), salt: cueFirst());
      return s;
    }

    LiveCues openCues(LucidStore store, CueBell bell, {LiveModel Function()? model, NightScorer? scorer}) =>
        LiveCues.open(
          store: store,
          nightStartMs: startMs,
          model: model,
          scorer: scorer,
          bell: bell,
          now: DateTime.fromMillisecondsSinceEpoch(startMs),
          scale: zeros,
          cuesAfter: const Duration(minutes: 10),
          modelBefore: const Duration(minutes: 6),
        )!;

    /// 75 minutes in 1 s batches as the recorder gives them: the shared scorer first, then each listener; the alarm
    /// checked every batch, the cues every 10 s.
    Future<(List<String>, List<String>)> night({NightScorer? scorer, LiveAlarm? alarm, LiveCues? cues}) async {
      final alarmEvents = <String>[], cueEvents = <String>[];
      cueEvents.addAll(cues?.takeEvents() ?? const []);
      for (var s = 0; s < 75 * 60; s++) {
        final rows = second(s), at = arrival(s);
        now = at;
        scorer?.add(at, rows, firstOfFile: s == 0);
        alarm?.add(at, rows, firstOfFile: s == 0);
        cues?.add(at, rows, firstOfFile: s == 0);
        alarm?.check(at);
        if (s % 10 == 0) cues?.check(at, drift: 'asleep');
        alarmEvents.addAll(alarm?.takeEvents() ?? const []);
        cueEvents.addAll(cues?.takeEvents() ?? const []);
        await Future<void>.delayed(Duration.zero);
      }
      await alarm?.close();
      await cues?.close();
      return (alarmEvents, cueEvents);
    }

    test('one model for both, and each decides as it does alone', () async {
      // the alarm alone, with a model of its own
      final bellA = AlarmBellFake();
      late final LiveAlarm alone;
      alone = LiveAlarm(
        plan: plan,
        model: () => ClockModel(() => alone.scorer.startUnix, script),
        bell: bellA,
        scale: zeros,
        clock: () => now,
      );
      final (aloneAlarmEvents, _) = await night(alarm: alone);

      // the cues alone, with a model of their own
      final storeC = lucidStore('alone'), bellC = CueBellFake();
      late final LiveCues aloneCues;
      aloneCues = openCues(storeC, bellC, model: () => ClockModel(() => aloneCues.scorer.startUnix, script));
      final (_, aloneCueEvents) = await night(cues: aloneCues);

      // both on one shared scorer
      var loads = 0;
      late final NightScorer scorer;
      final models = <ClockModel>[];
      scorer = NightScorer(
        model: () {
          loads++;
          return (models..add(ClockModel(() => scorer.startUnix, script))).last;
        },
        scale: zeros,
      );
      final bellB = AlarmBellFake();
      final alarm = LiveAlarm(plan: plan, scorer: scorer, bell: bellB, clock: () => now);
      final storeS = lucidStore('shared'), bellS = CueBellFake();
      final cues = openCues(storeS, bellS, scorer: scorer);
      final (alarmEvents, cueEvents) = await night(scorer: scorer, alarm: alarm, cues: cues);

      expect(loads, 1, reason: 'one model load for both');
      expect(scorer.loads, 1);
      expect(scorer.takeEvents().take(2), [
        'live sleep model on for the smart alarm (load 1 tonight)',
        'live sleep model: shared with the lucid cues (no second copy)',
      ]);
      expect(models.single.closed, isTrue, reason: 'freed once both let it go');

      // the alarm: the same wake, for the same reason, from the same epoch
      final w = alarm.live.wake!, w0 = alone.live.wake!;
      expect(w0.why, AlarmWhy.light);
      expect((w.atMs, w.why, w.epochStartMs, w.stage), (w0.atMs, w0.why, w0.epochStartMs, w0.stage));
      expect(w.epochStartMs, greaterThanOrEqualTo(startMs + (57 * 60 + 30 + 630) * 1000), reason: '10 min after deep');
      expect(bellB.reasons, bellA.reasons);
      expect(alarmEvents, aloneAlarmEvents);

      // the cues: the same moments, steps and periods, the same sounds and markers
      final r = storeS.night(startMs)!, r0 = storeC.night(startMs)!;
      expect(r0.cues, isNotEmpty);
      expect(r0.cues.first.atMs, greaterThanOrEqualTo(startMs + 30 * minute), reason: '10 min after deep');
      expect(
        [for (final c in r.cues) (c.atMs, c.step, c.period, c.aroused)],
        [for (final c in r0.cues) (c.atMs, c.step, c.period, c.aroused)],
      );
      expect(r0.arousals, hasLength(1), reason: 'the awake epoch at 01:34 is a stir after a cue');
      expect(
        [for (final c in r0.cues.where((c) => c.aroused)) c.atMs],
        everyElement(inInclusiveRange(startMs + 33 * minute + 30000, startMs + 34 * minute + 29000)),
        reason: 'the cues just before and inside the awake epoch',
      );
      expect(r.arousals, r0.arousals);
      expect(bellS.gains, bellC.gains);
      expect(cueEvents, aloneCueEvents);
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

    late MemoryNightStore nights;
    late List<RecorderStatus> statuses;
    late LucidStore lucid;
    late CueBellFake cueBell;
    late AlarmBellFake alarmBell;
    late List<ClockModel> models;
    late NightScorer scorer;
    setUp(() {
      nights = MemoryNightStore();
      statuses = [];
      lucid = LucidStore(Directory('${dir.path}/lucid'));
      lucid.setLevel(0.1, DateTime(2026, 11, 24, 22));
      lucid.setOn(true, DateTime(2026, 11, 24, 22));
      lucid.ensureTest(DateTime(2026, 11, 24, 22), salt: cueFirst());
      cueBell = CueBellFake();
      alarmBell = AlarmBellFake();
      models = [];
      scorer = NightScorer(
        model: () => (models..add(ClockModel(() => scorer.startUnix, (_) => 'R'))).last,
        scale: zeros,
      );
    });

    NightRecorder recorder(
      FastBand band, {
      required AlarmPlan plan,
      CueFactory? cues,
      GuardLimits limits = const GuardLimits(),
      AlarmWatch Function(AlarmPlan plan)? alarm,
    }) => NightRecorder(
      finder: OneFinder(band),
      dir: dir,
      store: nights,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      clock: band.now,
      watch: null,
      scorer: scorer,
      alarmPlan: plan,
      alarm: alarm ?? (p) => LiveAlarm(plan: p, scorer: scorer, bell: alarmBell, clock: band.now),
      cues:
          cues ??
          (nightStartMs) => LiveCues.open(
            store: lucid,
            nightStartMs: nightStartMs,
            scorer: scorer,
            bell: cueBell,
            now: DateTime.fromMillisecondsSinceEpoch(nightStartMs),
            cuesAfter: const Duration(minutes: 10),
            modelBefore: const Duration(minutes: 6),
          ),
      liveLimits: limits,
    );

    String logOf() =>
        [for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log'))) f.readAsStringSync()]
            .join();
    List<String> markers() => [
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')))
        ...f.readAsLinesSync(),
    ];
    int saved() => dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.f32'))
        .fold(0, (n, f) => n + f.lengthSync() ~/ recordBytes);

    test('both on: one model for the night, the alarm wakes, the cues play, the log says so', () async {
      final band = EyeBand(start: t0);
      // the alarm's model from 01:02 (window 02:02-02:12), the cues' from 01:04 (cues from 01:10)
      final plan = AlarmPlan(endMs: startMs + 72 * minute, windowMin: 10);
      final r = recorder(band, plan: plan);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'woke'), limit: const Duration(minutes: 4));
      await until(() => band.clockS >= 66 * 60, limit: const Duration(minutes: 2));
      expect(models.single.closed, isFalse, reason: 'the cues still use it after the wake');
      await r.stop();
      await running;

      expect(saved(), band.sent, reason: 'every sample saved');
      expect(scorer.loads, 1);
      expect(models.single.closed, isTrue);
      final log = logOf();
      expect(RegExp('live sleep model on for').allMatches(log), hasLength(1));
      expect(log, contains('live sleep model on for the smart alarm (load 1 tonight)'));
      expect(log, contains('live sleep model: shared with the lucid cues (no second copy)'));
      expect(
        log,
        matches(RegExp(r"smart alarm and lucid cues, one sleep model: [0-9.]+ s of the recorder's time over")),
      );
      expect(log, isNot(contains('stopped:')));
      final texts = markers().join('\n');
      expect(texts, contains('smart alarm: wake, dream sleep'));
      expect(texts, contains('lucid cue 1 (dream sleep 0.90, +0 dB)'));
      expect(alarmBell.reasons, hasLength(1));
      expect(cueBell.gains, isNotEmpty);
      expect(lucid.night(startMs)!.running, isFalse);
    });

    test('the guard switches both off with one line: the phone\'s alarm stays, the cues stop', () async {
      final band = EyeBand(start: t0);
      final plan = AlarmPlan(endMs: startMs + 72 * minute, windowMin: 10);
      var rss = 300 << 20;
      final r = recorder(
        band,
        plan: plan,
        limits: GuardLimits(rss: () => rss),
      );
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'scoring') && lucid.night(startMs)?.phase == 'listening');
      rss += 701 << 20;
      await until(() => statuses.any((s) => s.alarm?.phase == 'off'));
      final calls = models.single.calls;
      final at = band.clockS;
      await until(() => band.clockS >= at + 120);
      await r.stop();
      await running;

      final lines = logOf().split('\n').where((l) => l.contains('stopped:')).toList();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        endsWith(
          'smart alarm and lucid cues stopped: the app grew by 701 MB (over 700 MB); the phone\'s alarm still rings at '
          '02:12; the recording goes on',
        ),
      );
      expect(models.single.closed, isTrue);
      expect(models.single.calls, calls, reason: 'no model call after the guard');
      expect(statuses.last.alarm!.note, contains('switched off'));
      expect((nights.state.alarmOff, nights.state.alarmScoring), (true, false));
      final night = lucid.night(startMs)!;
      expect(night.phase, 'off');
      expect(night.off, contains('The recorder stopped them'));
      expect(night.running, isFalse);
      expect(saved(), band.sent, reason: 'every sample saved');
    });

    test('a model that cannot open switches both off with one line', () async {
      final band = EyeBand(start: t0);
      // started 10 min before the window: the alarm needs the model from the first batch
      final plan = AlarmPlan(endMs: startMs + 12 * minute, windowMin: 10);
      scorer = NightScorer(model: () => throw StateError('no ONNX here'), scale: zeros);
      final r = recorder(band, plan: plan);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'off'));
      await until(() => band.clockS >= 6 * 60);
      await r.stop();
      await running;
      final lines = logOf().split('\n').where((l) => l.contains('stopped:')).toList();
      expect(
        lines.single,
        endsWith(
          'smart alarm and lucid cues stopped: Bad state: no ONNX here; the phone\'s alarm still rings at 01:12; '
          'the recording goes on',
        ),
      );
      expect(lucid.night(startMs)!.phase, 'off');
      expect(saved(), band.sent);
    });

    test('after the guard, the alarm\'s hour does not start the model again', () async {
      final band = EyeBand(start: t0);
      // the cues' model from 01:04; the alarm's from 01:08
      final plan = AlarmPlan(endMs: startMs + 78 * minute, windowMin: 10);
      var rss = 300 << 20;
      var made = 0;
      final r = recorder(
        band,
        plan: plan,
        limits: GuardLimits(rss: () => rss),
        alarm: (p) {
          made++;
          return LiveAlarm(plan: p, scorer: scorer, bell: alarmBell, clock: band.now);
        },
      );
      final running = r.run(restartedBySystem: false);
      await until(() => lucid.night(startMs)?.phase == 'listening');
      rss += 701 << 20;
      await until(() => lucid.night(startMs)?.phase == 'off');
      await until(() => band.clockS >= 9 * 60);
      await r.stop();
      await running;
      final log = logOf();
      expect(log, contains('lucid cues stopped: the app grew by 701 MB (over 700 MB); the recording goes on'));
      expect(
        log,
        contains(
          'smart alarm: the live sleep model was switched off earlier tonight, so it stays off; '
          'the phone\'s alarm rings at 02:18',
        ),
      );
      expect(made, 0);
      expect(scorer.loads, 1);
      expect(statuses.last.alarm!.phase, 'off');
      expect(saved(), band.sent);
    });

    test('the cues failing alone leave the alarm and the model running', () async {
      final band = EyeBand(start: t0);
      final plan = AlarmPlan(endMs: startMs + 12 * minute, windowMin: 10);
      final broken = ThrowingCues(failAt: 30);
      final r = recorder(band, plan: plan, cues: (_) => broken);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'woke'));
      await r.stop();
      await running;
      final log = logOf();
      final lines = log.split('\n').where((l) => l.contains('stopped:')).toList();
      expect(lines.single, endsWith('lucid cues stopped: Bad state: cues broke; the recording goes on'));
      expect(broken.closed, isTrue);
      expect(alarmBell.reasons, hasLength(1));
      expect(scorer.loads, 1);
      expect(saved(), band.sent);
    });
  });
}

/// The clock the alarm reads in the one-night test (the batch's arrival).
DateTime now = DateTime.fromMillisecondsSinceEpoch(0);

/// Cues that fail on their [failAt]-th batch.
class ThrowingCues implements CueWatch {
  ThrowingCues({required this.failAt});
  final int failAt;
  int batches = 0;
  bool closed = false;

  @override
  String get who => 'lucid cues';

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (++batches == failAt) throw StateError('cues broke');
  }

  @override
  void check(DateTime now, {int? lightsOffMs, String? drift}) {}
  @override
  List<String> takeEvents() => const [];
  @override
  bool get finished => false;
  @override
  Future<void> close() async => closed = true;
}
