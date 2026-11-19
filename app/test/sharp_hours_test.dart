// What the sharp-hours page may say and when (DECISIONS rows 286-287): no pattern before 3 weeks and about 60
// ratings; then 2-hour blocks by clock time, by hours since waking and by sleep pressure, each with an 80 % range
// from resampling whole days; a best time named only when it stands out clearly; the day's numbers for Trends;
// and whether the questions reach the owner at all.
import 'dart:math' as math;

import 'package:eeg_tracker/sharp/hours.dart';
import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/pressure.dart';
import 'package:flutter_test/flutter_test.dart';

SharpRating _r(DateTime at, int v, {DateTime? prompt}) => SharpRating(at: at, sharp: v, prompt: prompt);

/// [n] ratings a day for [days] days from 20 Nov, at the given hours, the value from [value].
List<SharpRating> _days(int days, List<double> hours, int Function(int day, double hour) value) => [
  for (var d = 0; d < days; d++)
    for (final h in hours)
      _r(DateTime(2026, 11, 20 + d, h.floor(), ((h - h.floor()) * 60).round()), value(d, h)),
];

void main() {
  group('the no-verdict gate', () {
    test('nothing yet', () {
      final g = sharpGate(const [], const [], '2026-11-20');
      expect(g.open, isFalse);
      expect(g.day, 0);
      expect(g.words, 'Nothing rated yet.');
    });

    test('collecting: N of about 60 ratings, day D of 21', () {
      final r = _days(9, [10, 13, 16], (d, h) => 3).take(23).toList();
      final g = sharpGate(r, const [], '2026-11-28');
      expect(g.ratings, 23);
      expect(g.day, 9);
      expect(g.open, isFalse);
      expect(g.words, 'Collecting: 23 of about 60 ratings, day 9 of 21.');
    });

    test('opens only after 21 days AND 60 ratings', () {
      final many = _days(21, [10, 13, 16], (d, h) => 3); // 63 ratings, days 1-21
      expect(sharpGate(many, const [], '2026-12-10').open, isFalse, reason: 'day 21: still collecting');
      expect(sharpGate(many, const [], '2026-12-11').open, isTrue, reason: 'day 22 with 63');
      expect(sharpGate(many.take(59).toList(), const [], '2026-12-30').open, isFalse, reason: '59 ratings');
      final open = sharpGate(many, const [], '2026-12-11');
      expect(open.words, '63 ratings and no reaction tests over 22 days.');
    });

    test('reaction times need 30 tests as well', () {
      final many = _days(21, [10, 13, 16], (d, h) => 3);
      final tests = [
        for (var i = 0; i < 29; i++)
          SharpReaction(at: DateTime(2026, 11, 20 + i % 21, 10, 5), ratingAt: DateTime(2026, 11, 20 + i % 21, 10), timesMs: const [300, 300, 300, 300, 300]),
      ];
      expect(sharpGate(many, tests, '2026-12-11').testsOpen, isFalse);
      expect(sharpGate(many, [...tests, tests.first], '2026-12-11').testsOpen, isTrue);
    });
  });

  group('blocks', () {
    test('clock time: 2-hour blocks by the time of the answer', () {
      expect(blockOf(SharpAxis.clock, 9.99), 4);
      expect(blockOf(SharpAxis.clock, 10.0), 5);
      expect(blockOf(SharpAxis.clock, 23.5), 11);
      expect(blockWords(SharpAxis.clock, 5), '10:00 to 12:00');
      expect(blockShort(SharpAxis.clock, 5), '10');
    });

    test('hours since waking: 2-hour blocks, 16 or more together', () {
      expect(blockOf(SharpAxis.sinceWake, 0.5), 0);
      expect(blockOf(SharpAxis.sinceWake, 3.5), 1);
      expect(blockOf(SharpAxis.sinceWake, 15.9), 7);
      expect(blockOf(SharpAxis.sinceWake, 21), 8);
      expect(blockWords(SharpAxis.sinceWake, 1), '2 to 4 hours after waking');
      expect(blockWords(SharpAxis.sinceWake, 8), '16 hours or more after waking');
    });

    test('sleep pressure: quarters of the 0-100 scale, under 25 and 100 or more at the ends', () {
      expect(blockOf(SharpAxis.pressure, -10), 0);
      expect(blockOf(SharpAxis.pressure, 24.9), 0);
      expect(blockOf(SharpAxis.pressure, 25), 1);
      expect(blockOf(SharpAxis.pressure, 99), 3);
      expect(blockOf(SharpAxis.pressure, 130), 4);
      expect(blockWords(SharpAxis.pressure, 0), 'sleep pressure under 25 of 100');
      expect(blockWords(SharpAxis.pressure, 2), 'sleep pressure 50 to 75 of 100');
      expect(blockWords(SharpAxis.pressure, 4), 'sleep pressure past a regular bedtime (100 or more)');
    });

    test('hours since waking come from the latest recorded wake-up within 24 hours before the answer', () {
      final wakes = [DateTime(2026, 11, 20, 7), DateTime(2026, 11, 21, 8)];
      expect(hoursSinceWake(DateTime(2026, 11, 20, 10, 30), wakes), 3.5);
      expect(hoursSinceWake(DateTime(2026, 11, 21, 7, 30), wakes), isNull, reason: 'the last wake-up was 24.5 hours before');
      expect(hoursSinceWake(DateTime(2026, 11, 21, 9), wakes), 1);
      expect(hoursSinceWake(DateTime(2026, 11, 20, 6), wakes), isNull, reason: 'before any recorded wake-up');
    });

    test('points on an axis; answers the axis cannot place are counted, not guessed', () {
      final ratings = [_r(DateTime(2026, 11, 20, 10, 30), 4), _r(DateTime(2026, 11, 20, 6), 2)];
      final pts = axisPoints(
        SharpAxis.sinceWake,
        [for (final r in ratings) (at: r.at, value: r.sharp.toDouble())],
        wakes: [DateTime(2026, 11, 20, 7)],
        pressure: PressureModel(const []),
      );
      expect(pts.placed, hasLength(1));
      expect(pts.placed.single.block, 1);
      expect(pts.left, 1);
      final clock = axisPoints(SharpAxis.clock, [for (final r in ratings) (at: r.at, value: r.sharp.toDouble())]);
      expect([for (final p in clock.placed) p.block], [5, 3]);
      expect(clock.left, 0);
    });
  });

  group('ranges and the best time', () {
    List<SharpPoint> pts(List<SharpRating> r) =>
        axisPoints(SharpAxis.clock, [for (final x in r) (at: x.at, value: x.sharp.toDouble())]).placed;

    test('each block: mean, n, days, and an 80 % range that holds the mean; the same every time', () {
      final r = _days(25, [10.5, 14.5, 18.5], (d, h) => 2 + (d * 7 + h.floor()) % 3);
      final a = sharpProfile(SharpAxis.clock, pts(r), higherBetter: true);
      final b = sharpProfile(SharpAxis.clock, pts(r), higherBetter: true);
      final ten = a.blocks.firstWhere((x) => x.index == 5);
      expect(ten.n, 25);
      expect(ten.days, 25);
      expect(ten.shown, isTrue);
      expect(ten.low!, lessThanOrEqualTo(ten.mean!));
      expect(ten.high!, greaterThanOrEqualTo(ten.mean!));
      expect(ten.high! - ten.low!, lessThan(1.5));
      expect([for (final x in a.blocks) x.low], [for (final x in b.blocks) x.low]);
    });

    test('a block with under 5 answers or from under 3 days has no mean shown', () {
      final r = [
        ..._days(25, [10.5], (d, h) => 3),
        _r(DateTime(2026, 11, 20, 20), 5),
        _r(DateTime(2026, 11, 20, 20, 30), 5),
        _r(DateTime(2026, 11, 21, 20), 5),
        _r(DateTime(2026, 11, 21, 20, 30), 5),
        _r(DateTime(2026, 11, 21, 20, 50), 5), // 5 answers, 2 days
      ];
      final p = sharpProfile(SharpAxis.clock, pts(r), higherBetter: true);
      final eight = p.blocks.firstWhere((x) => x.index == 10);
      expect(eight.n, 5);
      expect(eight.shown, isFalse);
      expect(eight.mean, isNull);
    });

    test('pure noise is rarely called a best time (at most 5 of 100 made-up months)', () {
      var named = 0;
      for (var seed = 0; seed < 100; seed++) {
        final g = math.Random(seed);
        int noise() => (3 + (g.nextDouble() + g.nextDouble() + g.nextDouble() - 1.5) * 1.6).round().clamp(1, 5);
        final r = _days(30, [10.5, 12.5, 14.5, 16.5, 18.5, 20.5], (d, h) => noise())
            .where((_) => g.nextDouble() < 0.7)
            .toList();
        if (sharpProfile(SharpAxis.clock, pts(r), higherBetter: true, seed: seed).best != null) named++;
      }
      expect(named, lessThanOrEqualTo(5));
    });

    test('a clear peak (a point higher from 10 to 12, 150 answers) is named, with its size and range', () {
      var named = 0;
      BestTime? last;
      for (var seed = 0; seed < 20; seed++) {
        final g = math.Random(seed);
        int v(int d, double h) =>
            (3 + (h < 12 ? 1 : 0) + (g.nextDouble() + g.nextDouble() + g.nextDouble() - 1.5) * 1.2).round().clamp(1, 5);
        final r = _days(30, [10.5, 12.5, 14.5, 16.5, 18.5], v);
        final b = sharpProfile(SharpAxis.clock, pts(r), higherBetter: true, seed: seed).best;
        if (b != null && b.blocks.length == 1 && b.blocks.single.index == 5) {
          named++;
          last = b;
        }
      }
      expect(named, greaterThanOrEqualTo(18));
      expect(last!.gap, greaterThan(0.5));
      expect(last.low, lessThan(last.gap));
      expect(last.high, greaterThan(last.gap));
      expect(last.sure, greaterThanOrEqualTo(0.9));
    });

    test('a peak over two neighbouring blocks is named as one 4-hour span', () {
      var named = 0;
      BestTime? last;
      for (var seed = 0; seed < 20; seed++) {
        final g = math.Random(seed);
        int v(int d, double h) =>
            (3 + (h < 12 ? 1 : 0) + (g.nextDouble() + g.nextDouble() + g.nextDouble() - 1.5) * 1.2).round().clamp(1, 5);
        // 9, 11: two morning blocks alike; 13-19 the rest
        final r = _days(30, [9.0, 11.0, 13.0, 15.0, 17.0, 19.0], v);
        final b = sharpProfile(SharpAxis.clock, pts(r), higherBetter: true, seed: seed).best;
        if (b != null && b.blocks.map((x) => x.index).toSet().containsAll([4, 5])) {
          named++;
          last = b;
        }
      }
      expect(named, greaterThanOrEqualTo(16));
      expect(last!.blocks, hasLength(2));
      expect(bestWords(SharpAxis.clock, last), startsWith('Sharpest 08:00 to 12:00: '));
    });

    test('reaction time: quicker is better, and a best time needs 5 % quicker', () {
      final g = math.Random(7);
      final pts = <SharpPoint>[
        for (var d = 0; d < 30; d++)
          for (final h in [10.5, 14.5, 18.5])
            SharpPoint(
              at: DateTime(2026, 11, 20 + d, h.floor(), 30),
              day: dayKey(DateTime(2026, 11, 20 + d, h.floor(), 30)),
              value: (h < 12 ? 270 : 320) + g.nextDouble() * 20,
              block: blockOf(SharpAxis.clock, h),
            ),
      ];
      final p = sharpProfile(SharpAxis.clock, pts, higherBetter: false, minPerBlock: 4);
      expect(p.best, isNotNull);
      expect(p.best!.blocks.single.index, 5);
      expect(p.best!.gap, lessThan(0), reason: 'faster: a negative difference in ms');
      expect(bestWords(SharpAxis.clock, p.best!, reaction: true), startsWith('Quickest 10:00 to 12:00: '));
      expect(bestWords(SharpAxis.clock, p.best!, reaction: true), contains('% quicker than at your other times'));
    });

    test('the words', () {
      final block = SharpBlock(index: 5, n: 20, days: 18, mean: 3.9, low: 3.6, high: 4.2);
      final b = BestTime(blocks: [block], mean: 3.9, gap: 0.8, low: 0.4, high: 1.2, sure: 0.95);
      expect(bestWords(SharpAxis.clock, b), 'Sharpest 10:00 to 12:00: 0.8 points above your other times (probably 0.4 to 1.2).');
      expect(
        bestWords(SharpAxis.sinceWake, BestTime(blocks: const [SharpBlock(index: 1, n: 20, days: 18, mean: 3.9, low: 3.6, high: 4.2)], mean: 3.9, gap: 0.6, low: 0.1, high: 1.0, sure: 0.92)),
        'Sharpest 2 to 4 hours after waking: 0.6 points above your other times (probably 0.1 to 1.0).',
      );
      const two = [SharpBlock(index: 1, n: 9, days: 8), SharpBlock(index: 2, n: 9, days: 8)];
      expect(spanWords(SharpAxis.sinceWake, two), '2 to 6 hours after waking');
      expect(spanWords(SharpAxis.pressure, two), 'sleep pressure 25 to 75 of 100');
      expect(spanWords(SharpAxis.clock, const [SharpBlock(index: 11, n: 9, days: 8)]), '22:00 to 24:00');
      // the clock's ends are kept inside the waking window: no question is asked before 09:30 or after 22:30
      const morning = [SharpBlock(index: 4, n: 9, days: 8), SharpBlock(index: 5, n: 9, days: 8)];
      expect(spanWords(SharpAxis.clock, morning, fromMin: 570, untilMin: 1350), '09:30 to 12:00');
      expect(spanWords(SharpAxis.clock, const [SharpBlock(index: 11, n: 9, days: 8)], fromMin: 570, untilMin: 1350), '22:00 to 22:30');
      expect(spanWords(SharpAxis.clock, const [SharpBlock(index: 5, n: 9, days: 8)], fromMin: 570, untilMin: 1350), '10:00 to 12:00');
      expect(spanWords(SharpAxis.sinceWake, two, fromMin: 570, untilMin: 1350), '2 to 6 hours after waking');
    });
  });

  group('the day\'s numbers for Trends', () {
    test('sharpness = the mean of the day\'s ratings (a day runs 04:00 to 04:00); reaction = the median of its tests', () {
      final ratings = [
        _r(DateTime(2026, 11, 20, 10), 4),
        _r(DateTime(2026, 11, 20, 15), 3),
        _r(DateTime(2026, 11, 21, 2), 2), // still 20 Nov
        _r(DateTime(2026, 11, 21, 11), 5),
      ];
      final tests = [
        SharpReaction(at: DateTime(2026, 11, 20, 10, 2), ratingAt: DateTime(2026, 11, 20, 10), timesMs: const [300, 300, 300, 300, 300]),
        SharpReaction(at: DateTime(2026, 11, 20, 15, 2), ratingAt: DateTime(2026, 11, 20, 15), timesMs: const [340, 340, 340, 340, 340]),
        SharpReaction(at: DateTime(2026, 11, 20, 18, 2), ratingAt: DateTime(2026, 11, 20, 18), timesMs: const [500, 500]),
      ];
      final s = sharpDayNumbers(ratings, tests);
      expect(s['sharp'], {'2026-11-20': 3.0, '2026-11-21': 5.0});
      expect(s['dayrt'], {'2026-11-20': 320.0}, reason: 'the 2-tap test has no median');
    });
  });

  group('do the questions arrive?', () {
    final s = SharpSettings(
      on: true,
      perDay: 4,
      fromMin: 600,
      untilMin: 1320,
      seed: 'seed-a',
      firstOn: DateTime(2026, 11, 1, 9),
      changed: DateTime(2026, 11, 1, 9),
    );
    final now = DateTime(2026, 11, 20, 9);
    final planned = [
      for (var d = 1; d <= 7; d++) ...promptsForDay(addDays('2026-11-20', -d), s),
    ];

    test('the last 7 full days: planned, arrived, shown, skipped, answered', () {
      final events = [
        for (final (i, p) in planned.indexed)
          if (i % 4 != 3) // a quarter never arrived
            PromptEvent(planned: p.at, at: p.at.add(const Duration(minutes: 2)), event: i % 7 == 0 ? PromptEventKind.skipped : PromptEventKind.shown, reason: i % 7 == 0 ? 'night recording' : null),
      ];
      final ratings = [
        for (final (i, p) in planned.indexed)
          if (i % 4 != 3 && i % 7 != 0 && i.isEven) _r(p.at.add(const Duration(minutes: 5)), 3, prompt: p.at),
      ];
      final r = reachOf(s, events, ratings, now);
      expect(r.planned, 28);
      expect(r.arrived, 21);
      expect(r.skipped, events.where((e) => e.event == PromptEventKind.skipped).length);
      expect(r.shown, 21 - r.skipped);
      expect(r.answered, ratings.length);
      expect(r.heldBack, isFalse, reason: '21 of 28 is three in four');
      final fewer = reachOf(s, events.take(20).toList(), ratings, now);
      expect(fewer.heldBack, isTrue);
    });

    test('days before the last change are not counted; off counts nothing', () {
      final changed = s.copyWith(changed: DateTime(2026, 11, 17, 12));
      expect(reachOf(changed, const [], const [], now).planned, 8, reason: '18 and 19 Nov only');
      expect(reachOf(s.copyWith(on: false), const [], const [], now).planned, 0);
      expect(reachOf(changed, const [], const [], now).heldBack, isTrue);
      expect(reachOf(s.copyWith(changed: DateTime(2026, 11, 19, 12)), const [], const [], now).heldBack, isFalse, reason: 'under 6 planned: too few to judge');
    });
  });
}
