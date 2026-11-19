// The work session's break hints (DECISIONS 443-445): the laptop's break-hint rules (docs/break-hints.md) on the
// headband's worn time, plus a hint when drowsiness stays up.
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ticks every second from [from] for [seconds] with no epochs at all (the headband out of range).
void away(BreakPlanner p, DateTime from, int seconds) {
  for (var s = 0; s <= seconds; s++) {
    p.tick(from.add(Duration(seconds: s)), worn: false);
  }
}

/// Ticks every 30 s from [from] for [minutes], worn or not, feeding [level] epochs; returns the hints shown.
List<WorkHint> run(BreakPlanner p, DateTime from, double minutes, {bool worn = true, DrowsyLevel level = DrowsyLevel.alert, bool closed = false}) {
  final out = <WorkHint>[];
  for (var s = 0; s <= minutes * 60; s += 30) {
    final now = from.add(Duration(seconds: s));
    if (s > 0) p.epoch(level, eyesClosed: closed, window: switch (level) { DrowsyLevel.alert => 0.1, DrowsyLevel.unknown => null, _ => 0.8 });
    final h = p.tick(now, worn: worn);
    if (h != null) out.add(h);
  }
  return out;
}

void main() {
  final day = DateTime(2026, 11, 19, 9); // 09:00

  test('the first hint after 60 minutes worn, then not again within 45 minutes', () {
    final p = BreakPlanner();
    var hints = run(p, day, 59.5);
    expect(hints, isEmpty);
    hints = run(p, day.add(const Duration(minutes: 59, seconds: 30)), 1);
    expect(hints, hasLength(1));
    expect(hints.single.reason, HintReason.stretch);
    expect(hints.single.activeMin, closeTo(60, 0.6));
    expect(run(p, day.add(const Duration(minutes: 61)), 43), isEmpty);
  });

  test('an ignored hint adds 15 minutes to the threshold (back-off), counted once its 30-minute window closed', () {
    final p = BreakPlanner();
    final hints = run(p, day, 200);
    // 60, then +15 after the first ignored: 75 + 45 spacing does not bind (stretch keeps growing): 60, 105, 150, 195
    expect(hints.map((h) => h.activeMin.round()), [60, 105, 150, 195]);
    expect(p.thresholdMin(day.add(const Duration(minutes: 200))), 60 + 15 * 3, reason: "the 4th hint's 30 minutes are not over");
  });

  test('at most 4 a day; the day runs 04:00 to 04:00; nothing in quiet hours 23:00-08:00', () {
    final p = BreakPlanner();
    expect(run(p, DateTime(2026, 11, 19, 8), 6 * 60), hasLength(4));
    final night = BreakPlanner();
    expect(run(night, DateTime(2026, 11, 19, 22, 30), 120), isEmpty, reason: 'from 23:00 quiet');
    final early = BreakPlanner();
    final h = run(early, DateTime(2026, 11, 20, 6, 30), 120);
    expect(h.single.at, DateTime(2026, 11, 20, 8), reason: 'held until the quiet hours end');
  });

  test("earlier sessions' hints of the same day count toward the cap and the spacing", () {
    final earlier = [for (var i = 0; i < 3; i++) WorkHint(at: day.add(Duration(minutes: 10 * i)), reason: HintReason.stretch, activeMin: 60, thresholdMin: 60, level: DrowsyLevel.alert)];
    final p = BreakPlanner(earlier: earlier);
    final hints = run(p, day.add(const Duration(minutes: 30)), 8 * 60);
    expect(hints, hasLength(1));
    expect(p.hintsToday(day.add(const Duration(hours: 9))), 4);
  });

  test('drowsiness up in 8 of the last 12 epochs brings a hint before the hour', () {
    final p = BreakPlanner();
    run(p, day, 20);
    final hints = run(p, day.add(const Duration(minutes: 20)), 10, level: DrowsyLevel.gettingDrowsy);
    expect(hints, hasLength(1));
    expect(hints.single.reason, HintReason.drowsy);
    expect(hints.single.at, day.add(const Duration(minutes: 24)), reason: 'the 8th drowsy epoch');
  });

  test('eyes closed in 6 of the last 12 epochs brings a hint that names it', () {
    final p = BreakPlanner();
    run(p, day, 20);
    final hints = run(p, day.add(const Duration(minutes: 20)), 5, closed: true, level: DrowsyLevel.unknown);
    expect(hints.single.reason, HintReason.eyesClosed);
  });

  test('a tapped break of 5 minutes or more resets the stretch, marks the hint taken and keeps drowsiness before and after', () {
    final p = BreakPlanner();
    final h = run(p, day, 61);
    expect(h, hasLength(1));
    p.answer(HintAnswer.onBreak, day.add(const Duration(minutes: 62)));
    expect(p.onBreak, isTrue);
    expect(p.breaks.single.before, closeTo(0.1, 1e-9));
    expect(run(p, day.add(const Duration(minutes: 62)), 10), isEmpty, reason: 'no hints on a break');
    p.endBreak(day.add(const Duration(minutes: 72)));
    expect(p.breaks.single.minutes, closeTo(10, 1e-9));
    expect(h.single.taken, isTrue);
    expect(p.stretchMin, 0);
    expect(p.thresholdMin(day.add(const Duration(minutes: 72))), 60, reason: 'a hint followed by a break is no back-off');
    // the 10 epochs after the break: the "after" number
    run(p, day.add(const Duration(minutes: 72)), 5.5);
    expect(p.breaks.single.after, closeTo(0.1, 1e-9));
    expect(p.breaks.single.afterLevel, DrowsyLevel.alert);
  });

  test('a short tapped break only pauses the count', () {
    final p = BreakPlanner();
    run(p, day, 30);
    p.startBreak(day.add(const Duration(minutes: 30)));
    p.endBreak(day.add(const Duration(minutes: 33)));
    run(p, day.add(const Duration(minutes: 33)), 10);
    expect(p.stretchMin, closeTo(40, 0.6));
    expect(p.breaks.single.counts, isFalse);
  });

  test('the headband off for 5 minutes is a break from when it went off; under 5 minutes pauses', () {
    final p = BreakPlanner();
    run(p, day, 30);
    run(p, day.add(const Duration(minutes: 30)), 4, worn: false);
    expect(p.breaks, isEmpty);
    run(p, day.add(const Duration(minutes: 34, seconds: 30)), 10);
    expect(p.stretchMin, closeTo(40, 1.1));
    run(p, day.add(const Duration(minutes: 45)), 8, worn: false);
    expect(p.breaks.single.source, BreakSource.headbandOff);
    expect(p.breaks.single.start, day.add(const Duration(minutes: 45)));
    expect(p.onBreak, isTrue);
    run(p, day.add(const Duration(minutes: 53, seconds: 30)), 1);
    expect(p.onBreak, isFalse);
    expect(p.stretchMin, lessThan(1.1));
  });

  test('Snooze brings the hint back 20 minutes later, unless a break came first', () {
    final p = BreakPlanner();
    run(p, day, 60);
    p.answer(HintAnswer.snoozed, day.add(const Duration(minutes: 60)));
    final h = run(p, day.add(const Duration(minutes: 60, seconds: 30)), 25);
    expect(h.single.reason, HintReason.snooze);
    expect(h.single.at, day.add(const Duration(minutes: 80)));
    final q = BreakPlanner();
    run(q, day, 60);
    q.answer(HintAnswer.snoozed, day.add(const Duration(minutes: 60)));
    q.startBreak(day.add(const Duration(minutes: 65)));
    q.endBreak(day.add(const Duration(minutes: 71)));
    expect(run(q, day.add(const Duration(minutes: 71)), 25), isEmpty);
  });

  test('a rating goes with the newest hint within 30 minutes, else on its own; all of it round-trips as JSON', () {
    final p = BreakPlanner();
    run(p, day, 60);
    p.rate(2, day.add(const Duration(minutes: 61)));
    p.rate(4, day.add(const Duration(minutes: 100)));
    expect(p.ratings.map((r) => r.hint), [0, null]);
    p.startBreak(day.add(const Duration(minutes: 101)));
    p.endBreak(day.add(const Duration(minutes: 110)));
    final j = p.toJson();
    final hints = [for (final h in j['hints'] as List) WorkHint.fromJson(h as Map<String, Object?>)];
    expect(hints.single.reason, HintReason.stretch);
    expect(hints.single.at, p.hints.single.at);
    expect((j['breaks'] as List).single, containsPair('source', 'tapped'));
    expect((j['ratings'] as List).first, containsPair('value', 2));
  });

  group('work review 2026-11-20', () {
    DateTime at(int minutes, [int seconds = 0]) => day.add(Duration(minutes: minutes, seconds: seconds));

    test('a forgotten Back: the break ends by itself 2 minutes after the headband is back on, at that moment (finding 2)', () {
      final p = BreakPlanner();
      run(p, day, 30);
      p.startBreak(at(30));
      run(p, at(30), 10, worn: false, level: DrowsyLevel.unknown); // taken off, left connected
      expect(p.onBreak, isTrue);
      run(p, at(41), 1.5);
      expect(p.onBreak, isTrue, reason: 'not yet: worn under 2 minutes');
      run(p, at(42, 30), 0.5);
      expect(p.onBreak, isFalse);
      expect(p.breaks.single.end, at(41), reason: 'the moment it came back');
      expect(p.breaks.single.endSource, BreakEnd.auto);
      expect(p.breaks.single.toJson()['end_source'], 'auto');
      expect(p.stretchMin, closeTo(2, 0.1), reason: 'an 11-minute break reset the hour; the 2 minutes since are worn');
    });

    test('a forgotten Back with the headband on all along: 20 minutes of readable signal end it (finding 2)', () {
      final p = BreakPlanner();
      run(p, day, 30);
      p.startBreak(at(30));
      run(p, at(30), 19.5);
      expect(p.onBreak, isTrue);
      run(p, at(49, 30), 0.5);
      expect(p.onBreak, isFalse);
      expect(p.breaks.single.end, at(50));
      expect(p.breaks.single.endSource, BreakEnd.auto);
      expect(p.breaks.single.counts, isTrue);
    });

    test("the review's case: a tapped break never ended no longer silences the rest of the day (finding 2)", () {
      final p = BreakPlanner();
      run(p, day, 30);
      p.startBreak(at(30));
      final hints = run(p, at(31), 6 * 60, level: DrowsyLevel.drowsy);
      expect(hints, isNotEmpty);
      expect(p.activeS / 60, greaterThan(5 * 60));
    });

    test('noisy or closed-eyes half minutes on a break with the headband on do not end it (finding 2)', () {
      final p = BreakPlanner();
      run(p, day, 30);
      p.startBreak(at(30));
      run(p, at(30), 15, level: DrowsyLevel.unknown); // walking, talking: worn, never read
      run(p, at(45), 15, closed: true, level: DrowsyLevel.unknown); // resting with eyes closed
      expect(p.onBreak, isTrue);
      p.endBreak(at(61));
      expect(p.breaks.single.endSource, BreakEnd.back);
    });

    test('eyes closed while resting on a tapped break bring no hint at Back (finding 5)', () {
      final p = BreakPlanner();
      run(p, day, 30);
      p.startBreak(at(30));
      run(p, at(30), 4, closed: true, level: DrowsyLevel.unknown);
      run(p, at(34), 1.5);
      p.endBreak(at(36));
      expect(p.tick(at(36, 1), worn: true), isNull);
      expect(run(p, at(36, 1), 2.5), isEmpty);
    });

    test('drowsy before a walk out of range: no drowsy hint the second you return (finding 5)', () {
      final earlier = [WorkHint(at: at(0), reason: HintReason.stretch, activeMin: 60, thresholdMin: 60, level: DrowsyLevel.alert)];
      final p = BreakPlanner(earlier: earlier);
      run(p, at(0), 30);
      expect(run(p, at(30), 6, level: DrowsyLevel.drowsy), isEmpty, reason: 'held back by the 45-minute spacing');
      away(p, at(36), 15 * 60);
      expect(p.onBreak, isTrue);
      expect(p.tick(at(51, 1), worn: true), isNull);
      expect(p.onBreak, isFalse);
      expect(p.tick(at(51, 2), worn: true), isNull);
      // 8 fresh drowsy half minutes after it bring one
      final h = run(p, at(51, 2), 4, level: DrowsyLevel.drowsy);
      expect(h.single.reason, HintReason.drowsy);
    });

    test('a headband-off break with the headband left connected keeps the level before it (finding 6)', () {
      final p = BreakPlanner();
      run(p, day, 30);
      run(p, at(30), 6, worn: false, level: DrowsyLevel.unknown); // put down on the desk: unreadable half minutes
      final b = p.breaks.single;
      expect(b.source, BreakSource.headbandOff);
      expect(b.before, closeTo(0.1, 1e-9));
      expect(b.beforeLevel, DrowsyLevel.alert);
    });

    test('On a break right after a drowsy hint keeps the level before it (the hint cleared its epochs)', () {
      final p = BreakPlanner();
      run(p, day, 20);
      final h = run(p, at(20), 4, level: DrowsyLevel.gettingDrowsy);
      expect(h.single.reason, HintReason.drowsy);
      p.answer(HintAnswer.onBreak, at(24, 10));
      expect(p.breaks.single.beforeLevel, DrowsyLevel.gettingDrowsy);
      expect(p.breaks.single.before, closeTo(0.8, 1e-9));
    });

    test('a 1-minute break keeps a snooze; one of 5 minutes or more ends it (finding 19)', () {
      final p = BreakPlanner();
      run(p, day, 60);
      p.answer(HintAnswer.snoozed, at(60));
      p.startBreak(at(65));
      p.endBreak(at(66));
      final h = run(p, at(66), 20);
      expect(h.single.reason, HintReason.snooze);
      expect(h.single.at, at(80));
    });

    test('a hint answers On a break only within its 30 minutes (finding 9)', () {
      final p = BreakPlanner();
      run(p, day, 60);
      p.answer(HintAnswer.onBreak, at(95));
      expect(p.onBreak, isTrue, reason: 'the break starts all the same');
      expect(p.hints.single.answer, isNull);
      expect(p.hints.single.answeredAt, isNull);
    });

    test("a forward jump of the phone's clock is not worn time: the monotonic clock counts (finding 8)", () {
      final p = BreakPlanner();
      for (var s = 0; s <= 7 * 60; s++) {
        expect(p.tick(day.add(Duration(seconds: s)), worn: true, mono: Duration(seconds: s)), isNull);
      }
      final h = p.tick(day.add(const Duration(hours: 2, minutes: 7, seconds: 1)), worn: true, mono: const Duration(minutes: 7, seconds: 1));
      expect(h, isNull);
      expect(p.stretchMin, closeTo(7, 0.1));
      expect(p.activeS / 60, closeTo(7, 0.1));
    });

    test('a stretch carried over from a session that ended under 5 minutes ago; it is in the file (finding 7)', () {
      final p = BreakPlanner(carriedStretchMin: 40);
      final h = run(p, at(0), 21);
      expect(h.single.reason, HintReason.stretch);
      expect(h.single.at, at(20));
      expect(p.toJson()['stretch_min'], closeTo(61, 0.1), reason: 'a hint does not reset the stretch; only a break does');
      expect(BreakPlanner(carriedStretchMin: 12.5).toJson()['stretch_min'], 12.5);
    });

    test('back-off positive control: an ignored hint, a later break, the next hint at 75 minutes (finding 18)', () {
      final p = BreakPlanner();
      final first = run(p, day, 95);
      expect(first.single.at, at(60));
      p.startBreak(at(95)); // 35 minutes after the hint: not "taken"
      p.endBreak(at(101));
      expect(first.single.taken, isFalse);
      final next = run(p, at(101), 80);
      expect(next.first.at, at(176), reason: '60 + 15 for the ignored hint; without the back-off it would come at 161');
      expect(next.first.thresholdMin, 75);
    });
  });
}
