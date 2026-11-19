// The smart alarm during the night (lib/alarm/live_alarm.dart and the night recorder, DECISIONS 230-236): the live
// model starts an hour before the window, the first light moment inside it brings the phone's alarm forward, and it
// can never stop the recording: a model that throws, takes too long or grows the app too much is switched off with
// one log line, and the phone's own alarm at the window's end is left alone. ONNX cannot run in `flutter test`, so a
// scripted model says which stage each epoch is.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/alarm/bell.dart';
import 'package:eeg_tracker/alarm/live_alarm.dart';
import 'package:eeg_tracker/alarm/record.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show LiveWindow;
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart';

/// Every epoch is the stage [script] says; [fail] makes every call throw.
class ScriptedModel implements LiveModel {
  ScriptedModel(this.script);
  final String Function(int epoch) script;
  Object? fail;
  bool closed = false;
  final List<int> firsts = [];

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    firsts.add(first);
    if (fail != null) throw fail!;
    const names = ['W', 'N1', 'N2', 'N3', 'R'];
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      p[e * 5 + names.indexOf(script(first + e))] = 0.9;
      for (var j = 0; j < 5; j++) {
        if (p[e * 5 + j] == 0) p[e * 5 + j] = 0.025;
      }
    }
    return p;
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeBell implements AlarmBell {
  final List<String> reasons = [];
  Object? fail;

  @override
  Future<bool> ringNow(String reason) async {
    if (fail != null) throw fail!;
    reasons.add(reason);
    return true;
  }
}

/// The scaling is AnySleep's own and checked elsewhere (live_prep_test.dart); here only its size matters.
Future<Float32List> zeros(LiveWindow w) async => Float32List(w.epochs * 3840 * 4);

/// An alarm that fails on its [failAt]-th batch, or spends [slowMs] on every batch.
class BrokenAlarm implements AlarmWatch {
  BrokenAlarm({this.failAt, this.slowMs = 0});
  final int? failAt;
  final int slowMs;
  int batches = 0;
  bool closed = false;

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (++batches == failAt) throw StateError('alarm broke');
    if (slowMs > 0) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < slowMs) {}
    }
  }

  @override
  void check(DateTime now) {}
  @override
  List<String> takeEvents() => const [];
  @override
  AlarmLive get live => const AlarmLive(phase: AlarmPhase.scoring, stage: 'N2');
  @override
  bool get finished => false;
  @override
  Future<void> close() async => closed = true;
}

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

/// 2026-11-24 06:50:00 local: the night's (and the band's) first sample.
final double t0 = DateTime(2026, 11, 24, 6, 50).millisecondsSinceEpoch / 1000;

List<Map<String, dynamic>> markersIn(Directory dir) => [
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')))
    for (final l in f.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>,
];

String logOf(Directory dir) => [
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log'))) f.readAsStringSync(),
].join();

int savedSamples(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.f32'))
    .fold(0, (n, f) => n + f.lengthSync() ~/ recordBytes);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('smart_alarm_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('LiveAlarm on its own', () {
    /// Feeds [seconds] of a FastBand into [a] in 1 s batches, the clock following the band.
    Future<void> feed(LiveAlarm a, FastBand band, double seconds, {double holeAtS = -1, double holeS = 0}) async {
      var first = true;
      while (band.clockS < seconds) {
        if (holeAtS >= 0 && band.clockS >= holeAtS && band.clockS < holeAtS + 1) band.clockS += holeS;
        final b = band.batch();
        band.clockS += b.length / 250;
        a.add(band.now(), b, firstOfFile: first);
        first = false;
        a.check(band.now());
        await a.stager?.idle(); // the scaling and the model are async: let each call finish, as a phone keeps up
      }
    }

    test('waits until an hour before the window, then wakes at the first light epoch inside it', () async {
      final band = FastBand(start: t0);
      // window 07:52-08:02: the model from 06:52 (2 min after the first sample)
      final plan = AlarmPlan(endMs: ((t0 + 72 * 60) * 1000).round(), windowMin: 10);
      final model = ScriptedModel((_) => 'N2');
      final bell = FakeBell();
      final a = LiveAlarm(plan: plan, model: () => model, bell: bell, store: AlarmStore(dir), scale: zeros, clock: band.now);
      await feed(a, band, 119);
      expect(a.stager, isNull, reason: 'nothing before the model\'s hour');
      expect(a.live.phase, AlarmPhase.waiting);
      await feed(a, band, 63 * 60);
      expect(a.startUnix, greaterThanOrEqualTo(t0 + 120));
      expect(a.live.phase, AlarmPhase.woke);
      final w = a.live.wake!;
      expect(w.why, AlarmWhy.light);
      expect(w.atMs, greaterThanOrEqualTo(plan.startMs));
      expect(w.atMs - plan.startMs, lessThan(31000), reason: 'the first epoch handed out inside the window');
      expect(bell.reasons, ['Light sleep, 10 min before 08:02.']);
      expect(a.takeEvents(), [
        'smart alarm: sleep model on (window 07:52-08:02)',
        matches(RegExp(r'^smart alarm: wake, light sleep \(N2 at 07:4\d:\d\d, read 2 min behind; 10 min before 08:02\)$')),
      ]);
      await a.close();
      expect(model.closed, isTrue, reason: 'the model is freed at the wake');
      final rec = AlarmStore(dir).read(plan.endMs)!;
      expect((rec['wake'] as Map)['why'], 'light');
      expect(rec['phase'], 'woke');
      expect((rec['stages'] as String).replaceAll('2', ''), isEmpty);
      final calls = model.firsts.length;
      await feed(a, band, 64 * 60);
      expect(model.firsts.length, calls, reason: 'nothing more is scored after the wake');
    });

    test('deep sleep all through the window: no early ring; the window\'s end is the phone\'s', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 70 * 60) * 1000).round(), windowMin: 5);
      final bell = FakeBell();
      final a = LiveAlarm(plan: plan, model: () => ScriptedModel((_) => 'N3'), bell: bell, scale: zeros, clock: band.now);
      await feed(a, band, 71 * 60);
      expect(a.live.phase, AlarmPhase.ended);
      expect(a.live.wake!.why, AlarmWhy.windowEnd);
      expect(bell.reasons, isEmpty);
      expect(a.takeEvents().last, 'smart alarm: the window\'s end (08:00) came without light sleep; the phone\'s alarm rings');
      expect(a.live.stage, 'N3');
    });

    test('a model that fails leaves the phone\'s alarm, said in a sentence', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 70 * 60) * 1000).round(), windowMin: 5);
      final model = ScriptedModel((_) => 'N2')..fail = StateError('no ONNX here');
      final a = LiveAlarm(plan: plan, model: () => model, bell: FakeBell(), scale: zeros, clock: band.now);
      await feed(a, band, 20 * 60);
      expect(a.live.phase, AlarmPhase.off);
      expect(a.live.note, contains('so the phone\'s alarm wakes you at 08:00'));
      expect(a.finished, isTrue);
    });

    test('a hole in the stream is held, so the epochs stay on the clock', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 90 * 60) * 1000).round(), windowMin: 30); // the model from the first sample
      final a = LiveAlarm(plan: plan, model: () => ScriptedModel((_) => 'N2'), bell: FakeBell(), scale: zeros, clock: band.now);
      await feed(a, band, 600, holeAtS: 300, holeS: 12);
      expect(a.startUnix, t0.round());
      final s = a.stager!;
      expect(s.prep.samples, closeTo((band.clockS - (a.startUnix! - t0)) * 250, 250));
      expect(s.prep.gapAt(10), isTrue, reason: 'the 12 s hole is lost signal (over 5 s held)');
      expect(s.prep.gapAt(11), isFalse);
    });

    test('a bell that fails is logged; the phone\'s alarm still rings at the end', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 62 * 60) * 1000).round(), windowMin: 30);
      final bell = FakeBell()..fail = StateError('no channel');
      final a = LiveAlarm(plan: plan, model: () => ScriptedModel((_) => 'R'), bell: bell, scale: zeros, clock: band.now);
      await feed(a, band, 40 * 60);
      await Future<void>.delayed(Duration.zero);
      expect(a.live.wake!.why, AlarmWhy.dream);
      expect(a.takeEvents().last, startsWith('smart alarm: could not ring early (Bad state: no channel); the phone\'s alarm rings at'));
    });
  });

  group('in the night recorder', () {
    late MemoryNightStore store;
    late List<RecorderStatus> statuses;
    setUp(() {
      store = MemoryNightStore();
      statuses = [];
    });

    NightRecorder recorder(
      FastBand band, {
      AlarmPlan? plan,
      AlarmWatch Function(AlarmPlan plan)? alarm,
      RecorderTiming timing = fast,
      int Function()? rss,
    }) => NightRecorder(
      finder: OneFinder(band),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: timing,
      clock: band.now,
      watch: null,
      alarmPlan: plan,
      alarm: alarm,
      rss: rss,
    );

    test('a short night: the model from the start, the wake a marker, every sample saved, the screen sees it', () async {
      final band = FastBand(start: t0);
      // started 10 min before the window (07:00-07:30): the model's hour has already begun
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      final model = ScriptedModel((_) => 'N2');
      final bell = FakeBell();
      LiveAlarm? made;
      final r = recorder(
        band,
        plan: plan,
        alarm: (p) => made = LiveAlarm(plan: p, model: () => model, bell: bell, store: AlarmStore(dir), scale: zeros, clock: band.now),
      );
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'woke'));
      await until(() => band.clockS >= 12 * 60);
      await r.stop();
      await running;

      expect(savedSamples(dir), band.sent, reason: 'every sample saved');
      expect(bell.reasons, hasLength(1));
      final texts = [for (final m in markersIn(dir)) m['text'] as String];
      expect(texts, [
        'smart alarm: sleep model on (window 07:00-07:30)',
        startsWith('smart alarm: wake, light sleep (N2 at 06:5'),
      ]);
      final log = logOf(dir);
      expect(log, contains('smart alarm set: wake by 07:30, window from 07:00; the sleep model starts at 06:00'));
      expect(log, matches(RegExp(r"smart alarm: sleep model [0-9.]+ s of the recorder's time over [0-9.]+ min")));
      final s = statuses.lastWhere((s) => s.alarm?.phase == 'woke').alarm!;
      expect((s.endMs, s.windowMin, s.why, s.stage), (plan.endMs, 30, 'light', 'N2'));
      expect(s.wakeMs, made!.live.wake!.atMs);
      expect(store.state.alarmEndMs, plan.endMs);
      expect(store.state.alarmScoring, isFalse);
      expect(store.state.alarmOff, isTrue, reason: 'done for tonight');
      expect(model.closed, isTrue);
      // the status survives the isolate port
      expect(AlarmStatus.fromMap(s.toMap())!.why, 'light');
    });

    test('the model waits for its hour: nothing is made before it', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 92 * 60) * 1000).round(), windowMin: 30); // model from 06:52
      DateTime? madeAt;
      final r = recorder(band, plan: plan, alarm: (p) {
        madeAt = band.now();
        return BrokenAlarm();
      });
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 60);
      expect(madeAt, isNull);
      expect(statuses.last.alarm?.phase, 'waiting');
      await until(() => madeAt != null);
      await r.stop();
      await running;
      expect(madeAt!.millisecondsSinceEpoch, greaterThanOrEqualTo(plan.scoreFromMs));
      expect(madeAt!.millisecondsSinceEpoch - plan.scoreFromMs, lessThan(3000));
      expect(savedSamples(dir), band.sent);
    });

    test('an alarm that throws is switched off with one log line; the recording goes on', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      final broken = BrokenAlarm(failAt: 20);
      final r = recorder(band, plan: plan, alarm: (_) => broken);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'off'));
      await until(() => band.clockS >= 120);
      await r.stop();
      await running;
      expect(savedSamples(dir), band.sent, reason: 'every sample saved');
      final lines = logOf(dir).split('\n').where((l) => l.contains('smart alarm stopped')).toList();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        endsWith('smart alarm stopped: Bad state: alarm broke; the phone\'s alarm still rings at 07:30; the recording goes on'),
      );
      expect(broken.closed, isTrue);
      expect(broken.batches, 20, reason: 'never called again');
      expect((store.state.alarmOff, store.state.alarmScoring), (true, false));
      expect(statuses.last.alarm!.note, contains('switched off'));
    });

    test('a slow alarm is switched off by its share of the time', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      final slow = BrokenAlarm(slowMs: 3);
      const timing = RecorderTiming(
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
        alarmBudgetAfter: Duration(milliseconds: 100),
      );
      final r = recorder(band, plan: plan, alarm: (_) => slow, timing: timing);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'off'));
      await until(() => band.clockS >= 60);
      await r.stop();
      await running;
      expect(savedSamples(dir), band.sent);
      expect(logOf(dir), matches(RegExp(r"smart alarm stopped: it took [0-9.]+ % of the recorder's time \(over 2\.0 %\)")));
      expect(slow.closed, isTrue);
    });

    test('the memory limit switches it off', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      var rss = 300 << 20;
      final r = recorder(band, plan: plan, alarm: (_) => BrokenAlarm(), rss: () => rss);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'scoring'));
      rss += 701 << 20;
      await until(() => statuses.any((s) => s.alarm?.phase == 'off'));
      await r.stop();
      await running;
      expect(logOf(dir), contains('smart alarm stopped: the app grew by 701 MB (over 700 MB)'));
      expect(savedSamples(dir), band.sent);
    });

    test('a process that ended while the model ran keeps it off tonight, with one note', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      store.state = NightState(
        active: true,
        startMs: ((t0 - 3600) * 1000).round(),
        alarmEndMs: plan.endMs,
        alarmWindowMin: 30,
        alarmScoring: true,
      );
      var made = 0;
      final r = recorder(band, alarm: (_) {
        made++;
        return BrokenAlarm();
      });
      final running = r.run(restartedBySystem: true);
      await until(() => band.clockS >= 60);
      await r.stop();
      await running;
      expect(made, 0);
      expect(
        logOf(dir),
        contains(
          'smart alarm: the app process ended while the sleep model ran, so the model stays off tonight; '
          'the phone\'s alarm still rings at 07:30',
        ),
      );
      expect(statuses.last.alarm!.phase, 'off');
      expect(savedSamples(dir), band.sent);
    });

    test('a process restarted before the model\'s hour starts it as planned', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      store.state = NightState(active: true, startMs: ((t0 - 3600) * 1000).round(), alarmEndMs: plan.endMs, alarmWindowMin: 30);
      var made = 0;
      final r = recorder(band, alarm: (_) {
        made++;
        return BrokenAlarm();
      });
      final running = r.run(restartedBySystem: true);
      await until(() => made > 0);
      await r.stop();
      await running;
      expect(made, 1);
    });

    test('Alarm off stops the model, marks the night and tells the screen', () async {
      final band = FastBand(start: t0);
      final plan = AlarmPlan(endMs: ((t0 + 40 * 60) * 1000).round(), windowMin: 30);
      final a = BrokenAlarm();
      final r = recorder(band, plan: plan, alarm: (_) => a);
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.any((s) => s.alarm?.phase == 'scoring'));
      r.alarmOff();
      r.alarmOff(); // a second tap changes nothing
      await until(() => band.clockS >= 60);
      await r.stop();
      await running;
      expect(a.closed, isTrue);
      expect([for (final m in markersIn(dir)) m['text']], ['smart alarm: turned off']);
      expect(statuses.last.alarm!.note, 'Turned off.');
      expect(store.state.alarmOff, isTrue);
    });

    test('no plan: no alarm, no status', () async {
      final band = FastBand(start: t0);
      var made = 0;
      final r = recorder(band, alarm: (_) {
        made++;
        return BrokenAlarm();
      });
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 30);
      await r.stop();
      await running;
      expect(made, 0);
      expect(statuses.every((s) => s.alarm == null), isTrue);
      expect(logOf(dir), isNot(contains('smart alarm')));
      expect(math.max(0, savedSamples(dir) - band.sent), 0);
    });
  });
}
