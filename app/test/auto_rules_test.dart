// Automatic recording, phase 1 (DECISIONS 600-609): the bedtime window from recorded nights, the kind guessed from the
// phone's context, and the headband battery guard. Plain rules on a fake clock.
import 'package:eeg_tracker/auto/battery_guard.dart';
import 'package:eeg_tracker/auto/bedtime.dart';
import 'package:eeg_tracker/auto/rules.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:flutter_test/flutter_test.dart';

({DateTime start, DateTime end}) night(int day, int bedH, int bedM, int wakeH, int wakeM) {
  final start = DateTime(2026, 11, day, bedH, bedM);
  var end = DateTime(2026, 11, day, wakeH, wakeM);
  if (!end.isAfter(start)) end = end.add(const Duration(days: 1));
  return (start: start, end: end);
}

void main() {
  group('the bedtime window', () {
    test('until 3 nights: 23:00 to 07:00, opening 2 hours early', () {
      final w = usualNight([night(10, 23, 50, 7, 30), night(11, 0, 10, 8, 0)], const AutoSettings());
      expect((w.bedMin, w.wakeMin, w.fromNights), (23 * 60, 7 * 60, 0));
      expect(w.opensMin, 21 * 60);
      expect(w.contains(DateTime(2026, 11, 20, 20, 59)), isFalse);
      expect(w.contains(DateTime(2026, 11, 20, 21, 0)), isTrue);
      expect(w.contains(DateTime(2026, 11, 21, 3, 0)), isTrue, reason: 'across midnight');
      expect(w.contains(DateTime(2026, 11, 21, 7, 0)), isTrue);
      expect(w.contains(DateTime(2026, 11, 21, 7, 1)), isFalse);
      expect(w.contains(DateTime(2026, 11, 21, 14, 0)), isFalse);
    });

    test('from 3 nights: the median start and end around midnight', () {
      final w = usualNight([
        night(10, 23, 40, 7, 0),
        night(11, 0, 20, 7, 40),
        night(12, 0, 0, 7, 20),
      ], const AutoSettings());
      expect((w.bedMin, w.wakeMin, w.fromNights), (0, 7 * 60 + 20, 3));
      expect(w.opensMin, 22 * 60);
    });

    test('set by hand wins over the nights', () {
      final w = usualNight([
        night(10, 23, 40, 7, 0),
        night(11, 0, 20, 7, 40),
        night(12, 0, 0, 7, 20),
      ], const AutoSettings(bedMin: 22 * 60 + 30, wakeMin: 6 * 60 + 15));
      expect((w.bedMin, w.wakeMin, w.byHand), (22 * 60 + 30, 6 * 60 + 15, true));
    });

    test('the checks inside the window: every 10 minutes from its opening, the next 24 hours only', () {
      final w = usualNight(const [], const AutoSettings());
      final at = bedtimeChecks(w, DateTime(2026, 11, 20, 14, 3));
      expect(at.first, DateTime(2026, 11, 20, 21, 0));
      expect(at[1], DateTime(2026, 11, 20, 21, 10));
      expect(at.last, DateTime(2026, 11, 21, 7, 0));
      expect(at, hasLength(61));
      final inside = bedtimeChecks(w, DateTime(2026, 11, 20, 23, 4));
      expect(inside.first, DateTime(2026, 11, 20, 23, 10), reason: 'already inside: the next 10-minute mark');
    });
  });

  group('what you are doing (the kind)', () {
    final w = usualNight(const [], const AutoSettings()); // 21:00 to 07:00
    PhoneContext ctx(int h, int m, {bool charging = false, bool screenOn = true, int? offMin, bool dnd = false, LaptopWork? laptop}) =>
        PhoneContext(
          now: DateTime(2026, 11, 20, h, m),
          charging: charging,
          screenOn: screenOn,
          screenOffSince: offMin == null ? null : DateTime(2026, 11, 20, h, m).subtract(Duration(minutes: offMin)),
          dnd: dnd,
          laptop: laptop,
        );
    LaptopWork working(int h, int m) => LaptopWork(working: true, at: DateTime(2026, 11, 20, h, m));

    test('inside the bedtime window: night', () {
      final g = guessKind(ctx(22, 30), w);
      expect(g.kind, WearKind.night);
      expect(g.reasons, contains('bedtime window (21:00-07:00)'));
    });

    test('evening, charging with the screen off 2 minutes or more: night; under 2 minutes not yet', () {
      final w2 = usualNight(const [], const AutoSettings(bedMin: 1 * 60, wakeMin: 9 * 60)); // opens 23:00
      expect(guessKind(ctx(20, 30, charging: true, screenOn: false, offMin: 3), w2).kind, WearKind.night);
      expect(guessKind(ctx(20, 30, charging: true, screenOn: false, offMin: 1), w2).kind, WearKind.other);
      expect(guessKind(ctx(19, 30, charging: true, screenOn: false, offMin: 30), w2).kind, WearKind.other, reason: 'before 20:00');
      expect(guessKind(ctx(20, 30, charging: false, screenOn: false, offMin: 30), w2).kind, WearKind.other);
    });

    test('screen off with no time known counts as off now', () {
      final w2 = usualNight(const [], const AutoSettings(bedMin: 1 * 60, wakeMin: 9 * 60));
      expect(guessKind(ctx(21, 0, charging: true, screenOn: false), w2).kind, WearKind.night);
    });

    test('Do Not Disturb in the evening: night', () {
      final w2 = usualNight(const [], const AutoSettings(bedMin: 1 * 60, wakeMin: 9 * 60));
      final g = guessKind(ctx(21, 15, dnd: true), w2);
      expect(g.kind, WearKind.night);
      expect(g.reasons, contains('Do Not Disturb on'));
    });

    test('the laptop says you are working: work, even in the bedtime window', () {
      final g = guessKind(ctx(22, 30, laptop: working(22, 20)), w);
      expect(g.kind, WearKind.work);
      expect(g.reasons, contains('laptop: work session'));
    });

    test('an old laptop signal (over 15 minutes) or a stopped one does not count', () {
      expect(guessKind(ctx(14, 0, laptop: working(13, 40)), w).kind, WearKind.other);
      expect(guessKind(ctx(14, 0, laptop: LaptopWork(working: false, at: DateTime(2026, 11, 20, 13, 59))), w).kind, WearKind.other);
      expect(guessKind(ctx(14, 0, laptop: working(13, 50)), w).kind, WearKind.work);
    });

    test('daytime, nothing else: other', () {
      final g = guessKind(ctx(14, 0), w);
      expect(g.kind, WearKind.other);
      expect(g.reasons, isNotEmpty);
    });
  });

  group('the headband battery guard', () {
    final w = usualNight(const [], const AutoSettings()); // bed 23:00, wake 07:00: 8 h

    test('tonight needs 8 h x 10 % + 15 % = 95 %', () {
      expect(nightNeedPct(w), 95);
    });

    test('a night is never refused, only warned about', () {
      final low = guardBattery(WearKind.night, 30, DateTime(2026, 11, 20, 23, 0), w);
      expect(low.allowed, isTrue);
      expect(low.note, 'headband at 30 %: about 3 h, the night needs about 8 h');
      expect(guardBattery(WearKind.night, 100, DateTime(2026, 11, 20, 23, 0), w).note, isNull);
      expect(guardBattery(WearKind.night, 90, DateTime(2026, 11, 20, 23, 0), w).note, isNull, reason: '9 h for an 8-hour night');
      expect(guardBattery(WearKind.night, 70, DateTime(2026, 11, 20, 23, 0), w).note, isNotNull);
    });

    test('the chosen default only warns: a daytime session is never refused and never given an end', () {
      expect(BatteryRule.onlyWarns, isTrue);
      final plenty = guardBattery(WearKind.work, 80, DateTime(2026, 11, 20, 10, 0), w);
      expect(plenty.allowed, isTrue);
      expect(plenty.limit, isNull, reason: 'no session is stopped because of the estimate');
      expect(plenty.charge, isFalse);
      expect(plenty.note, isNull);
      for (final low in [
        guardBattery(WearKind.work, 90, DateTime(2026, 11, 20, 20, 0), w), // bedtime 3 h away, tonight needs 95 %
        guardBattery(WearKind.other, 100, DateTime(2026, 11, 20, 20, 0), w),
        guardBattery(WearKind.work, 20, DateTime(2026, 11, 20, 10, 0), w),
      ]) {
        expect(low.allowed, isTrue);
        expect(low.limit, isNull);
        expect(low.charge, isTrue);
        expect(low.note, 'Charge the headband for tonight.');
      }
    });

    test('the stopping rule (onlyWarns off): daytime, bedtime 4 hours away or more: down to 15 %, ending 4 hours before bed', () {
      final g = guardBattery(WearKind.work, 80, DateTime(2026, 11, 20, 10, 0), w, onlyWarns: false);
      expect(g.allowed, isTrue);
      expect(g.limit, const Duration(hours: 6, minutes: 30), reason: '(80 - 15) / 10 = 6.5 h; bed - 4 h is 9 h away');
      final late = guardBattery(WearKind.work, 80, DateTime(2026, 11, 20, 17, 0), w, onlyWarns: false);
      expect(late.limit, const Duration(hours: 2), reason: 'ends at 19:00, 4 hours before 23:00');
    });

    test('the stopping rule (onlyWarns off): daytime, bedtime under 4 hours away: only above what tonight needs', () {
      final refused = guardBattery(WearKind.work, 90, DateTime(2026, 11, 20, 20, 0), w, onlyWarns: false);
      expect(refused.allowed, isFalse);
      expect(refused.note, 'Charge the headband for tonight.');
      final full = guardBattery(WearKind.other, 100, DateTime(2026, 11, 20, 20, 0), w, onlyWarns: false);
      expect(full.allowed, isFalse, reason: '100 - 95 = 5 % = 30 min, under the 40-minute minimum');
    });

    test('the stopping rule (onlyWarns off): too little to bother: under 40 minutes is refused', () {
      expect(guardBattery(WearKind.work, 20, DateTime(2026, 11, 20, 10, 0), w, onlyWarns: false).allowed, isFalse);
      expect(guardBattery(WearKind.work, 22, DateTime(2026, 11, 20, 10, 0), w, onlyWarns: false).allowed, isTrue);
    });

    test('battery not known: allowed, said so', () {
      final g = guardBattery(WearKind.work, null, DateTime(2026, 11, 20, 10, 0), w);
      expect(g.allowed, isTrue);
      expect(g.limit, isNull);
      expect(g.note, 'headband battery not known');
    });
  });
}
