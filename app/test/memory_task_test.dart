// The memory cues' learning task (DECISIONS 501): objects drawn on a board, half with each sound, places far enough
// apart, learning rounds that keep only the objects not yet placed close, and the distances the test is scored by.
import 'dart:math' as math;

import 'package:eeg_tracker/memory_cues/objects.dart';
import 'package:eeg_tracker/memory_cues/task.dart';
import 'package:flutter_test/flutter_test.dart';

/// A corner far from [it]'s place (at least half a board width away).
BoardPoint far(MemoryItem it) => (x: it.x > 0.5 ? 0.0 : 1.0, y: it.y > TaskRule.aspect / 2 ? 0.0 : TaskRule.aspect);

void main() {
  final made = DateTime(2026, 11, 24, 22, 30);

  test('the object pool is large enough for three nights without a repeat, and every name is unique', () {
    expect(memoryObjects.length, greaterThanOrEqualTo(3 * TaskRule.objects));
    expect(memoryObjects.map((o) => o.name).toSet().length, memoryObjects.length);
    expect(memoryObjects.map((o) => o.icon.codePoint).toSet().length, memoryObjects.length);
  });

  test('a session: 32 different objects, 16 with each sound, places on the board and far enough apart', () {
    final s = drawSession(math.Random(7), made);
    expect(s.items, hasLength(TaskRule.objects));
    expect(s.items.map((i) => i.object).toSet(), hasLength(TaskRule.objects));
    expect(s.items.where((i) => i.sound == 0), hasLength(TaskRule.objects ~/ 2));
    expect(s.items.where((i) => i.sound == 1), hasLength(TaskRule.objects ~/ 2));
    for (final i in s.items) {
      expect(i.x, inInclusiveRange(TaskRule.edge, 1 - TaskRule.edge));
      expect(i.y, inInclusiveRange(TaskRule.edge, TaskRule.aspect - TaskRule.edge));
    }
    for (var a = 0; a < s.items.length; a++) {
      for (var b = a + 1; b < s.items.length; b++) {
        final d = math.sqrt(math.pow(s.items[a].x - s.items[b].x, 2) + math.pow(s.items[a].y - s.items[b].y, 2));
        expect(d, greaterThanOrEqualTo(TaskRule.minApart));
      }
    }
    expect(s.studyOrder.toSet(), s.items.map((i) => i.object).toSet());
  });

  test('the same random source gives the same session; the last session\'s objects are left out', () {
    final a = drawSession(math.Random(3), made), b = drawSession(math.Random(3), made);
    expect(a.toJson(), b.toJson());
    final c = drawSession(math.Random(4), made, avoid: a.items.map((i) => i.object).toSet());
    expect(c.items.map((i) => i.object).toSet().intersection(a.items.map((i) => i.object).toSet()), isEmpty);
  });

  test('the sounds are not told by where the objects sit or when they are shown', () {
    // over many draws, sound A's places and study positions are spread like sound B's
    var ax = 0.0, bx = 0.0, aFirst = 0;
    for (var seed = 0; seed < 200; seed++) {
      final s = drawSession(math.Random(seed), made);
      for (final i in s.items) {
        if (i.sound == 0) {
          ax += i.x;
        } else {
          bx += i.x;
        }
      }
      if (s.itemOf(s.studyOrder.first).sound == 0) aFirst++;
    }
    expect((ax - bx).abs() / (200 * 16), lessThan(0.02));
    expect(aFirst, inInclusiveRange(70, 130));
  });

  test('distance in board widths, close within the hit radius', () {
    const item = MemoryItem(object: 'cat', x: 0.5, y: 0.5, sound: 0);
    expect(placementError(item, (x: 0.8, y: 0.9)), closeTo(0.5, 1e-12));
    expect(isClose(item, (x: 0.5 + TaskRule.hitRadius - 0.001, y: 0.5)), isTrue);
    expect(isClose(item, (x: 0.5 + TaskRule.hitRadius + 0.001, y: 0.5)), isFalse);
  });

  test('a half\'s mean distance; an object not placed counts as the board\'s half diagonal', () {
    final s = MemorySession(
      id: 'x',
      made: made,
      boardDp: 360,
      items: const [
        MemoryItem(object: 'a', x: 0.2, y: 0.2, sound: 0),
        MemoryItem(object: 'b', x: 0.8, y: 0.2, sound: 0),
        MemoryItem(object: 'c', x: 0.5, y: 1.0, sound: 1),
      ],
      studyOrder: const ['a', 'b', 'c'],
    );
    final taps = {'a': (x: 0.2, y: 0.3), 'c': (x: 0.5, y: 1.0)};
    expect(halfError(s, taps, 0), closeTo((0.1 + missedError) / 2, 1e-12));
    expect(halfError(s, taps, 1), closeTo(0, 1e-12));
    expect(missedError, closeTo(math.sqrt(1 + TaskRule.aspect * TaskRule.aspect) / 2, 1e-12));
    expect(closeCount(s, taps), 2);
  });

  test('learning rounds: every object once, then only the ones not yet placed close, at most 3 rounds', () {
    final s = drawSession(math.Random(1), made);
    final l = LearnRounds(s, math.Random(2));
    final firstRound = <String>[];
    while (l.round == 1) {
      final o = l.current!;
      firstRound.add(o);
      final it = s.itemOf(o);
      // the first 10 placed close, the rest far
      l.place(firstRound.length <= 10 ? (x: it.x, y: it.y) : far(it));
    }
    expect(firstRound.toSet(), hasLength(TaskRule.objects));
    expect(l.round, 2);
    expect(l.left, TaskRule.objects - 10);
    while (!l.done) {
      final it = s.itemOf(l.current!);
      l.place(far(it)); // never close again
    }
    expect(l.round, TaskRule.learnRounds);
    expect(l.placements, hasLength(TaskRule.objects + 2 * (TaskRule.objects - 10)));
  });

  test('learning ends early when every object was placed close', () {
    final s = drawSession(math.Random(5), made);
    final l = LearnRounds(s, math.Random(6));
    while (!l.done) {
      final it = s.itemOf(l.current!);
      l.place((x: it.x, y: it.y));
    }
    expect(l.placements, hasLength(TaskRule.objects));
  });

  test('a session survives JSON, with its learning, its evening test and the loudness of each sound', () {
    final s = drawSession(math.Random(9), made);
    final done = s.copyWith(
      learn: [(object: s.items.first.object, round: 1, x: 0.1, y: 0.2, ms: 100)],
      evening: {for (final i in s.items) i.object: (x: i.x, y: i.y)},
      eveningEnd: made.add(const Duration(minutes: 9)),
      levels: [0.01, 0.02],
      mediaVolume: 7,
      mediaVolumeMax: 15,
      completed: made.add(const Duration(minutes: 11)),
    );
    final back = MemorySession.fromJson(done.toJson())!;
    expect(back.toJson(), done.toJson());
    expect(back.isComplete, isTrue);
    expect(s.isComplete, isFalse);
    expect(MemorySession.fromJson({'id': 'x'}), isNull);
  });
}
