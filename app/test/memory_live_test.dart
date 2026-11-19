// Memory cues during the night (lib/memory_cues/live_cues.dart on the shared engine, DECISIONS 502-506): only with a
// finished evening session, the model from the night's start, sounds only in the cue hours when the rule allows, the
// half the night's coin picked, a silent night of the test doing everything the same but playing nothing, and one
// kind of cue a night (the lucid cues win when both are on). The guard's switch-off is the engine's and the recorder's,
// tested with the lucid cues (lucid_live_test.dart, night_scorer_test.dart).
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/cues/night_cues.dart';
import 'package:eeg_tracker/lucid/live_cues.dart' show LiveCues, lucidCuesFor;
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/memory_cues/live_cues.dart';
import 'package:eeg_tracker/memory_cues/plan.dart';
import 'package:eeg_tracker/memory_cues/rule.dart';
import 'package:eeg_tracker/memory_cues/sounds.dart';
import 'package:eeg_tracker/memory_cues/store.dart';
import 'package:eeg_tracker/memory_cues/task.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fast_band.dart';
import 'support/night_fakes.dart';

/// A memory cue watch that fails on its [failAt]-th batch, or says [say] once (the recorder's side).
class _Watch implements CueWatch {
  _Watch({this.failAt, this.say});
  final int? failAt;
  String? say;
  int batches = 0;
  bool closed = false;

  @override
  String get who => 'memory cues';

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (++batches == failAt) throw StateError('cues broke');
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

/// A secret whose night 0 has sound with half [sound], and whose night [silentAt] is silent.
String saltWith({required int sound, required int silentAt}) {
  for (var k = 0; ; k++) {
    final salt = k.toRadixString(16).padLeft(64, '0');
    final s = MemorySealed.draw(salt);
    if (s.arms[0] == MemoryArm.sound && s.sounds[0] == sound && s.arms[silentAt] == MemoryArm.silent) return salt;
  }
}

void main() {
  late Directory dir;
  late MemoryStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('memory_live_test');
    store = MemoryStore(Directory('${dir.path}/memory_cues'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A finished evening session [minutesBefore] the night at [nightMs] after [startMs].
  MemorySession session({int nightMs = 0, int minutesBefore = 20, int seed = 1}) {
    final done = DateTime.fromMillisecondsSinceEpoch(startMs + nightMs - minutesBefore * 60000);
    final s = drawSession(math.Random(seed), done.subtract(const Duration(minutes: 12)));
    final finished = s.copyWith(
      evening: {for (final i in s.items) i.object: (x: i.x, y: i.y)},
      eveningEnd: done.subtract(const Duration(minutes: 2)),
      levels: [0.02, 0.04],
      completed: done,
    );
    store.saveSession(finished);
    return finished;
  }

  CueWatch? open({ScriptedModel? model, FakeBell? bell, int nightMs = 0}) => MemoryCues.open(
    store: store,
    nightStartMs: startMs + nightMs,
    model: () => model ?? ScriptedModel((_) => 'N2'),
    bell: bell ?? FakeBell(),
    now: DateTime.fromMillisecondsSinceEpoch(startMs + nightMs),
    scale: zeros,
    cuesAfter: const Duration(minutes: 2),
    cuesUntil: const Duration(minutes: 8),
  );

  /// Feeds [seconds] of [sampleAt] (still, no eye movements, as in N2/N3) in 1 s batches from the night's start,
  /// letting the model's calls finish.
  Future<List<String>> feed(CueWatch c, int seconds, {int nightMs = 0}) async {
    final events = <String>[];
    for (var s = 0; s < seconds; s++) {
      final rows = [for (var j = 0; j < 250; j++) sampleAt(s * 250 + j, eyes: false)];
      final arrival = DateTime.fromMillisecondsSinceEpoch(startMs + nightMs + (s + 1) * 1000);
      c.add(arrival, rows, firstOfFile: s == 0);
      if (s % 10 == 0) c.check(arrival, drift: 'asleep');
      events.addAll(c.takeEvents());
      await Future<void>.delayed(Duration.zero);
    }
    return events;
  }

  test('off by default: no cues, no files', () {
    session();
    expect(open(), isNull);
    expect(store.nights(), isEmpty);
  });

  test('on, but no evening session finished before the night: one line, no night in the test, no sound', () {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    session(minutesBefore: 4 * 60);
    final c = open()!;
    expect(c.finished, isTrue);
    expect(c.who, 'memory cues');
    expect(c.takeEvents().single, startsWith('memory cues: no evening task finished in the 3 hours before'));
    expect(store.nights(), isEmpty);
  });

  test('a sound night: the model from the start, sounds in N2/N3 from the cue hours on, 10 s apart, 3 dB under the '
      'evening loudness of the half the coin picked; done when the cue hours end', () async {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    store.ensureTest(DateTime(2026, 11, 24, 22), salt: saltWith(sound: 1, silentAt: 1));
    final s = session();
    final bell = FakeBell();
    final c = open(bell: bell)!;
    expect(c.takeEvents().single, 'memory cues on: night 1 of the test; sounds from 01:02 to 01:08');
    final events = await feed(c, 10 * 60);
    expect(events.first, 'memory cues: sleep model on');
    final cues = [
      for (final e in events)
        if (e.startsWith('memory cue ')) e,
    ];
    expect(cues, isNotEmpty);
    expect(cues.first, 'memory cue 1 (N2/N3 0.90, -3 dB)');
    expect(events.last, 'memory cues: done for tonight (the cue hours are over)');
    expect(c.finished, isTrue);
    final r = store.night(startMs)!;
    expect(r.index, 0);
    expect(r.session, s.id);
    expect(r.cues.length, cues.length);
    expect(r.cues.first.atMs, greaterThanOrEqualTo(startMs + 2 * 60000));
    expect(r.cues.last.atMs, lessThan(startMs + 8 * 60000));
    for (var j = 1; j < r.cues.length; j++) {
      expect(r.cues[j].atMs - r.cues[j - 1].atMs, greaterThanOrEqualTo(MemoryRule.spacingS * 1000));
    }
    expect(bell.gains, hasLength(cues.length));
    expect(bell.gains.first, closeTo(0.04 * math.pow(10, -3 / 20), 1e-9));
    expect(bell.files.toSet(), {memorySoundFiles[1]});
    expect(File('${store.dir.path}/plays.jsonl').readAsLinesSync(), hasLength(cues.length));
    expect(store.soundFiles.every((f) => f.existsSync()), isTrue);
    await c.close();
    expect(store.night(startMs)!.running, isFalse);
  });

  test('a silent night does everything the same but plays nothing', () async {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    store.ensureTest(DateTime(2026, 11, 24, 22), salt: saltWith(sound: 0, silentAt: 1));
    session();
    final soundBell = FakeBell();
    final a = open(bell: soundBell)!..takeEvents();
    final soundEvents = await feed(a, 9 * 60);
    await a.close();
    const day = 24 * 3600 * 1000;
    session(nightMs: day, seed: 2);
    final silentBell = FakeBell();
    final b = open(bell: silentBell, nightMs: day)!;
    expect(b.takeEvents().single, startsWith('memory cues on: night 2 of the test'));
    final silentEvents = await feed(b, 9 * 60, nightMs: day);
    await b.close();
    expect(silentEvents, soundEvents, reason: 'the same markers on both kinds of night');
    expect(soundBell.gains, isNotEmpty);
    expect(silentBell.gains, isEmpty);
    final ra = store.night(startMs)!, rb = store.night(startMs + day)!;
    expect([for (final c in rb.cues) c.atMs - day], [for (final c in ra.cues) c.atMs]);
    expect(rb.toJson().keys, ra.toJson().keys);
  });

  test('no sound in dream sleep or awake', () async {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    session();
    final bell = FakeBell();
    final c = open(bell: bell, model: ScriptedModel((e) => e.isEven ? 'R' : 'W'))!;
    await feed(c, 9 * 60);
    expect(store.night(startMs)!.cues, isEmpty);
    expect(bell.gains, isEmpty);
  });

  test('a process that ended while the model ran keeps the cues off; the night keeps its number and session', () async {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    final s = session();
    final c = open()!;
    await feed(c, 3 * 60);
    expect(store.night(startMs)!.running, isTrue); // the process "dies" here: no close
    final again = open()!;
    expect(again.finished, isTrue);
    expect(again.takeEvents().last, contains('ended while the sleep model ran'));
    expect(store.night(startMs)!.index, 0);
    expect(store.night(startMs)!.session, s.id);
    expect(store.nights(), hasLength(1));
  });

  test('Lights off moves the cue hours, both ends', () async {
    store.setOn(true, DateTime(2026, 11, 24, 22));
    session();
    final c = open()!..takeEvents();
    c.check(DateTime.fromMillisecondsSinceEpoch(startMs + 60000), lightsOffMs: startMs + 3 * 60000, drift: null);
    expect(c.takeEvents().single, 'memory cues from 01:05 (30 min after Lights off)');
    expect(store.night(startMs)!.cuesFromMs, startMs + 5 * 60000);
    final events = await feed(c, 12 * 60);
    final r = store.night(startMs)!;
    expect(r.cues.first.atMs, greaterThanOrEqualTo(startMs + 5 * 60000));
    expect(r.cues.last.atMs, lessThan(startMs + 11 * 60000));
    expect(events.last, 'memory cues: done for tonight (the cue hours are over)');
  });

  group('through the night recorder: its lines name the memory cues', () {
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

    Future<String> night(CueWatch w) async {
      final band = FastBand(start: startMs / 1000);
      final r = NightRecorder(
        finder: OneFinder(band),
        dir: dir,
        store: MemoryNightStore(),
        onStatus: (_) {},
        onStuck: (_) async {},
        timing: fast,
        clock: band.now,
        watch: null,
        cues: (_) => w,
      );
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 40);
      await r.stop();
      await running;
      return [
        for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log'))) f.readAsStringSync(),
      ].join();
    }

    test('the guard switches them off by their own name; the cost line too', () async {
      final broken = _Watch(failAt: 20);
      final log = await night(broken);
      expect(log, contains('memory cues stopped: Bad state: cues broke; the recording goes on'));
      expect(log, isNot(contains('lucid')));
      expect(broken.closed, isTrue);
    });

    test('their moments become markers, and the log ends with their cost', () async {
      final log = await night(_Watch(say: 'memory cue 1 (N2/N3 0.90, -3 dB)'));
      final markers = [
        for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')))
          ...f.readAsLinesSync(),
      ].join('\n');
      expect(markers, contains('memory cue 1 (N2/N3 0.90, -3 dB)'));
      expect(log, matches(RegExp(r"memory cues: [0-9.]+ s of the recorder's time over [0-9.]+ min")));
    });
  });

  group('one kind a night', () {
    test('the lucid cues win when both are on; the memory cues run when the lucid ones are off', () {
      final rec = '${dir.path}/recordings';
      final lucid = LucidStore(lucidDirFor(rec))
        ..setLevel(0.1, DateTime(2026, 11, 24, 22))
        ..setOn(true, DateTime(2026, 11, 24, 22));
      store.setOn(true, DateTime(2026, 11, 24, 22));
      session();
      final make = oneKindANight([
        lucidCuesFor(rec, model: () => ScriptedModel((_) => 'R'), bell: FakeBell()),
        memoryCuesFor(rec, model: () => ScriptedModel((_) => 'N2'), bell: FakeBell()),
      ]);
      expect(make(startMs), isA<LiveCues>());
      expect(store.nights(), isEmpty);
      lucid.setOn(false, DateTime(2026, 11, 24, 22, 1));
      const day = 24 * 3600 * 1000;
      session(nightMs: day, seed: 3);
      expect(make(startMs + day), isA<MemoryCues>());
      expect(store.nights(), hasLength(1));
    });

    test('a kind that throws ends the choice there (the recorder logs it): never a second kind by mistake', () {
      final make = oneKindANight([(_) => throw StateError('broken'), (_) => null]);
      expect(() => make(startMs), throwsStateError, reason: 'the recorder\'s guard catches and logs it');
    });
  });
}
