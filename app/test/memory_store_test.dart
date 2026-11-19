// The memory cues' files (DECISIONS 506): off by default, the evening sessions, the test frozen once, the nights the
// recorder writes, the mornings, and which session a night may use.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/cues/night_cues.dart' show CueMoment;
import 'package:eeg_tracker/memory_cues/store.dart';
import 'package:eeg_tracker/memory_cues/task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late MemoryStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('memory_store_test');
    store = MemoryStore(Directory('${dir.path}/memory_cues'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  MemorySession complete(DateTime at, {int seed = 1}) {
    final s = drawSession(math.Random(seed), at.subtract(const Duration(minutes: 12)));
    return s.copyWith(
      evening: {for (final i in s.items) i.object: (x: i.x, y: i.y)},
      eveningEnd: at.subtract(const Duration(minutes: 2)),
      levels: [0.01, 0.012],
      completed: at,
    );
  }

  test('off by default, and nothing written by reading', () {
    expect(store.settings().on, isFalse);
    expect(store.sessions(), isEmpty);
    expect(store.nights(), isEmpty);
    expect(store.dir.existsSync(), isFalse);
  });

  test('switching on and off is logged; the folder is the one beside the recordings', () {
    store.setOn(true, DateTime(2026, 11, 24, 21));
    expect(store.settings().on, isTrue);
    store.setOn(false, DateTime(2026, 11, 24, 21, 5));
    expect(store.settings().on, isFalse);
    final events = File('${store.dir.path}/events.jsonl').readAsLinesSync().map(jsonDecode).toList();
    expect([for (final e in events) (e as Map)['event']], ['switched on', 'switched off']);
    expect(memoryDirFor('/data/files/recordings').path, '/data/files/memory_cues');
  });

  test('sessions are kept, newest last', () {
    final a = complete(DateTime(2026, 11, 23, 23)), b = complete(DateTime(2026, 11, 24, 23), seed: 2);
    store.saveSession(b);
    store.saveSession(a);
    expect([for (final s in store.sessions()) s.id], [a.id, b.id]);
    expect(store.session(a.id)!.toJson(), a.toJson());
  });

  test('a night uses the newest session finished in the 3 hours before it starts, and only one night uses it', () {
    final night = DateTime(2026, 11, 24, 23, 30).millisecondsSinceEpoch;
    store.saveSession(complete(DateTime(2026, 11, 24, 20, 20))); // 3 h 10 min before: too old
    expect(store.freshSession(night), isNull);
    final s = complete(DateTime(2026, 11, 24, 23), seed: 3);
    store.saveSession(s);
    final unfinished = drawSession(math.Random(4), DateTime(2026, 11, 24, 23, 10));
    store.saveSession(unfinished);
    expect(store.freshSession(night)!.id, s.id);
    store.saveNight(MemoryNightRecord(startMs: night, index: 0, session: s.id, cuesFromMs: night + 1800000));
    expect(store.freshSession(night + 60000), isNull, reason: 'a second start that night gets no session');
    expect(store.freshSession(night), isNotNull, reason: 'the same night started again keeps it');
  });

  test('the test is drawn and frozen once', () {
    final a = store.ensureTest(DateTime(2026, 11, 24, 22), salt: '00' * 32);
    final b = store.ensureTest(DateTime(2026, 11, 25, 22));
    expect(b.sealed.toJson(), a.sealed.toJson());
    expect(b.plan.sha, a.plan.sha);
    expect(b.planSha, a.plan.sha);
  });

  test('a night\'s record survives JSON and never says which kind of night or which half', () {
    final r = MemoryNightRecord(
      startMs: 1000,
      index: 3,
      session: '2026-11-24-224800',
      cuesFromMs: 1800000,
      phase: 'listening',
      cues: const [CueMoment(atMs: 2000000, step: -3, period: 1, confidence: 0.91, aroused: true)],
      arousals: const [2010000],
      stops: const [(3000000, 'per night')],
      running: true,
      mediaVolume: 6,
    );
    store.saveNight(r);
    final back = store.night(1000)!;
    expect(back.toJson(), r.toJson());
    expect(store.nextIndex(), 4);
    final text = File('${store.nightsDir.path}/${r.stamp}.json').readAsStringSync();
    expect(text, isNot(contains('silent')));
    expect(text, isNot(contains('sound_')));
  });

  test('plays are kept apart, one line each', () {
    store.addPlay(2000000, 3, 1, true, null);
    store.addPlay(2010000, 3, 1, false, 'no');
    final lines = File('${store.dir.path}/plays.jsonl').readAsLinesSync();
    expect(lines, hasLength(2));
    expect(jsonDecode(lines[1]), containsPair('sound', 1));
  });

  test('a morning survives JSON', () {
    final m = MemoryMorning(
      session: 's',
      made: DateTime(2026, 11, 25, 8),
      taps: const {'dog': (x: 0.25, y: 0.5)},
      heard: 'no',
    );
    store.saveMorning('2026-11-24-233000', m);
    expect(store.morning('2026-11-24-233000')!.toJson(), m.toJson());
    expect(store.morning('nothing'), isNull);
  });

  test('both sound files are written into the folder', () {
    final files = store.ensureSounds();
    expect(files.map((f) => f.path.split('/').last), ['sound_a.wav', 'sound_b.wav']);
    expect(files.every((f) => f.existsSync()), isTrue);
  });
}
