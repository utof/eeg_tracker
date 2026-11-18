// The trends' maths (DECISIONS rows 120-129): what counts as a day, "your usual" and when an arrow shows, the
// sleep-pressure estimate from the sleep log, and the gate that keeps forecasts hidden.
import 'dart:math' as math;

import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/forecast.dart';
import 'package:eeg_tracker/trends/pressure.dart';
import 'package:eeg_tracker/trends/usual.dart';
import 'package:flutter_test/flutter_test.dart';

/// A series of [n] days ending the day before [today], from [value] (k = 0 is the oldest).
Map<String, double> days(String today, int n, double Function(int k) value) => {
  for (var k = 0; k < n; k++) addDays(today, k - n): value(k),
};

void main() {
  group('days', () {
    test('a day starts at 04:00: a meditation at 2 a.m. belongs to the day before', () {
      expect(dayKey(DateTime(2026, 11, 18, 3, 59)), '2026-11-17');
      expect(dayKey(DateTime(2026, 11, 18, 4)), '2026-11-18');
      expect(dayKey(DateTime(2026, 11, 18, 23, 30)), '2026-11-18');
    });

    test('day keys step across months and years', () {
      expect(addDays('2026-11-30', 1), '2026-12-01');
      expect(addDays('2027-01-01', -1), '2026-12-31');
      expect(daysBetween('2026-11-18', '2026-12-02'), 14);
      expect(weekdayShort('2026-11-18'), 'Wed');
    });

    test('a night counts for the day you woke from it', () {
      // the owner's sleep of 06:51-14:36 and an ordinary night that ends at 07:10
      expect(wakeDay(DateTime(2026, 11, 18, 14, 36)), '2026-11-18');
      expect(wakeDay(DateTime(2026, 11, 18, 7, 10)), '2026-11-18');
      // a night cut short at 02:00 still belongs to the evening before
      expect(wakeDay(DateTime(2026, 11, 18, 2)), '2026-11-17');
    });
  });

  group('your usual', () {
    const today = '2026-11-18';

    test('nothing to compare with before 7 days; the count is told', () {
      final u = usualOf(days(today, 6, (_) => 420), today, Scale.minutes);
      expect(u.days, 6);
      expect(u.ready, isFalse);
      expect(u.daysToUsual, 1);
      expect(u.arrow(300), Arrow.none);
    });

    test('from 7 days the middle value; arrows only from 14 days', () {
      final s = days(today, 10, (k) => 400.0 + 5 * k);
      final u = usualOf(s, today, Scale.minutes);
      expect(u.ready, isTrue);
      expect(u.median, 422.5);
      expect(u.arrowsReady, isFalse);
      expect(u.daysToArrows, 4);
      expect(u.arrow(100), Arrow.none);
    });

    test('a short night beyond the normal spread and over an hour off gets an arrow', () {
      final s = days(today, 20, (k) => 420.0 + (k.isEven ? 10 : -10));
      final u = usualOf(s, today, Scale.minutes);
      expect(u.arrowsReady, isTrue);
      expect(u.spread, closeTo(1.4826 * 10, 1e-9));
      expect(u.arrow(300), Arrow.down);
      expect(u.arrow(470), Arrow.none); // 50 min more: beyond 2 spreads, but under the hour that counts
      expect(u.arrow(490), Arrow.up);
      expect(u.low, 360);
      expect(u.high, 480);
    });

    test('ratings need 2 points even when every day was the same', () {
      final s = days(today, 20, (_) => 4);
      final u = usualOf(s, today, Scale.rating);
      expect(u.spread, 0);
      expect(u.arrow(5), Arrow.none);
      expect(u.arrow(6), Arrow.up);
      expect(u.arrow(2), Arrow.down);
    });

    test('alpha strength is judged on a log scale', () {
      final s = days(today, 20, (k) => 30 * math.pow(1.1, k.isEven ? 1 : -1).toDouble());
      final u = usualOf(s, today, Scale.log);
      expect(u.median, closeTo(30, 1e-9));
      expect(u.arrow(45), Arrow.up);
      expect(u.arrow(33.5), Arrow.none);
      expect(u.arrow(20), Arrow.down);
      expect(u.low! * u.high!, closeTo(900, 1e-6)); // symmetric around 30 on the log scale
    });

    test('reaction time: an arrow needs a 10 % change as well', () {
      final s = days(today, 20, (k) => 300.0 + (k.isEven ? 2 : -2));
      final u = usualOf(s, today, Scale.reaction);
      expect(u.arrow(320), Arrow.none);
      expect(u.arrow(335), Arrow.up);
    });

    test('only the last 28 days before the day count, never the day itself', () {
      final s = {
        ...days(today, 40, (k) => k < 12 ? 100.0 : 7.0),
        today: 500.0,
      };
      final u = usualOf(s, today, Scale.plain);
      expect(u.days, 28);
      expect(u.median, 7);
    });

    test('inputs such as practice minutes never get arrows', () {
      final s = days(today, 20, (k) => k.toDouble());
      final u = usualOf(s, today, Scale.noArrows);
      expect(u.arrow(1000), Arrow.none);
    });
  });

  group('sleep pressure from the sleep log', () {
    final base = DateTime(2026, 11, 1, 23);

    test('a regular 16-hour day reaches 100 at bedtime; a regular night brings it back to 0', () {
      final sleeps = [
        for (var d = 0; d < 6; d++) (start: base.add(Duration(days: d)), end: base.add(Duration(days: d, hours: 8))),
      ];
      final m = PressureModel(sleeps);
      final bed = base.add(const Duration(days: 6));
      expect(m.levelAt(bed)!, closeTo(100, 0.5));
      expect(m.levelAt(base.add(const Duration(days: 5, hours: 8)))!, closeTo(0, 0.5));
      expect(m.hoursAwakeLike(bed)!, closeTo(16, 0.1));
      expect(m.hoursAwakeLike(base.add(const Duration(days: 5, hours: 17)))!, closeTo(9, 0.1));
    });

    test('a long sleep goes below the rested level; a short one leaves pressure', () {
      final m = PressureModel([(start: base, end: base.add(const Duration(hours: 4)))]);
      final short = m.levelAt(base.add(const Duration(hours: 4)))!;
      expect(short, greaterThan(15));
      final long = PressureModel([(start: base, end: base.add(const Duration(hours: 11)))]);
      expect(long.levelAt(base.add(const Duration(hours: 11)))!, lessThan(0));
      expect(long.hoursAwakeLike(base.add(const Duration(hours: 11))), 0);
    });

    test('before the first recorded sleep and 30 hours after the last there is no estimate', () {
      final m = PressureModel([(start: base, end: base.add(const Duration(hours: 8)))]);
      expect(m.levelAt(base.subtract(const Duration(minutes: 1))), isNull);
      expect(m.levelAt(base.add(const Duration(hours: 37))), isNotNull);
      expect(m.levelAt(base.add(const Duration(hours: 38, minutes: 1))), isNull);
    });

    test('a night missing from the log starts the estimate again at the next sleep', () {
      final later = base.add(const Duration(days: 3));
      final m = PressureModel([
        (start: base, end: base.add(const Duration(hours: 8))),
        (start: later, end: later.add(const Duration(hours: 8))),
      ]);
      expect(m.levelAt(base.add(const Duration(days: 2))), isNull);
      expect(m.levelAt(later)!, closeTo(100, 1e-9)); // starts as at a regular bedtime (an assumption)
      final pts = m.curve(base, later.add(const Duration(hours: 10)), step: const Duration(hours: 1));
      expect(pts.where((p) => p.level == null), isNotEmpty);
    });
  });

  group('forecasts stay hidden', () {
    test('under 60 rated days: hidden, with the count', () {
      final s = days('2026-11-18', 12, (k) => 5);
      final f = sleepinessForecast(s, '2026-11-18');
      expect(f.shown, isFalse);
      expect(f.ratedDays, 12);
      expect(f.why, contains('60'));
    });

    test('noisy days around a steady level: the blend beats "same as yesterday" and shows, with a range', () {
      final r = math.Random(3);
      final s = {...days('2027-02-01', 90, (k) => (5 + r.nextInt(5) - 2).toDouble()), '2027-02-01': 5.0};
      final f = sleepinessForecast(s, '2027-02-01');
      expect(f.shown, isTrue, reason: f.why);
      expect(f.skill, greaterThan(0.05));
      expect(f.low, lessThanOrEqualTo(f.value!));
      expect(f.high, greaterThanOrEqualTo(f.value!));
      expect(f.low, greaterThanOrEqualTo(1));
      expect(f.high, lessThanOrEqualTo(9));
      expect(f.scoredDays, 60);
      // before today's rating it waits, so the forecast cannot colour the answer
      final before = sleepinessForecast({...s}..remove('2027-02-01'), '2027-02-01');
      expect(before.shown, isFalse);
      expect(before.why, contains('check-in'));
    });

    test('a slow drift: "same as yesterday" wins, so it stays hidden', () {
      final s = days('2027-02-01', 90, (k) => 1 + (k ~/ 11) % 9.0);
      final f = sleepinessForecast(s, '2027-02-01');
      expect(f.shown, isFalse);
      expect(f.why, contains('same as yesterday'));
    });
  });
}
