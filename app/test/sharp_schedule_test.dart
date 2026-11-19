// The sharp-hours log's sampling schedule (DECISIONS rows 281-283): a few random moments a day inside the waking
// window, one in each equal part of it, at least an hour apart, the same moments whenever they are worked out
// again; the window itself, suggested from recorded sleeps.
import 'dart:math' as math;

import 'package:eeg_tracker/sharp/schedule.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:flutter_test/flutter_test.dart';

SharpSettings _s({int perDay = 4, int from = 10 * 60, int until = 22 * 60, String seed = 'seed-a', bool on = true}) =>
    SharpSettings(on: on, perDay: perDay, fromMin: from, untilMin: until, seed: seed);

int _min(DateTime t) => t.hour * 60 + t.minute;

void main() {
  group('clock times', () {
    test('read and written as HH:MM; nothing else is accepted', () {
      expect(clockText(9 * 60 + 5), '09:05');
      expect(clockText(0), '00:00');
      expect(parseClock('23:30'), 23 * 60 + 30);
      expect(parseClock('7:00'), isNull);
      expect(parseClock('24:00'), isNull);
      expect(parseClock('12:60'), isNull);
      expect(parseClock(930), isNull);
    });

    test('the window is from..until, past midnight when until is earlier', () {
      expect(_s().windowMin, 12 * 60);
      expect(_s(from: 15 * 60, until: 3 * 60).windowMin, 12 * 60);
      expect(windowOk(10 * 60, 22 * 60), isTrue);
      expect(windowOk(10 * 60, 12 * 60), isFalse, reason: 'under 4 hours awake');
      expect(windowOk(6 * 60, 4 * 60), isFalse, reason: 'quiet hours under 4 hours');
      expect(windowOk(10 * 60, 10 * 60), isFalse);
    });
  });

  group('one day', () {
    test('perDay moments, sorted, inside the window, at least an hour apart', () {
      for (var d = 0; d < 200; d++) {
        final day = addDays('2026-11-20', d);
        final p = promptsForDay(day, _s());
        expect(p, hasLength(4), reason: day);
        final noon = dayNoon(day);
        final start = DateTime(noon.year, noon.month, noon.day, 10), end = DateTime(noon.year, noon.month, noon.day, 22);
        for (var i = 0; i < p.length; i++) {
          expect(p[i].at.isBefore(start), isFalse, reason: '$day ${p[i].at}');
          expect(p[i].at.isBefore(end), isTrue, reason: '$day ${p[i].at}');
          expect(p[i].at.second, 0);
          if (i > 0) expect(p[i].at.difference(p[i - 1].at).inMinutes, greaterThanOrEqualTo(60), reason: day);
        }
      }
    });

    test('stratified: one moment in each equal part of the window', () {
      for (var d = 0; d < 100; d++) {
        final p = promptsForDay(addDays('2026-11-20', d), _s());
        for (var k = 0; k < 4; k++) {
          final m = _min(p[k].at);
          expect(m, inInclusiveRange(10 * 60 + k * 180, 10 * 60 + (k + 1) * 180 - 1));
        }
      }
    });

    test('the same day and secret give the same moments; another secret or day gives others', () {
      final a = promptsForDay('2026-11-20', _s()), b = promptsForDay('2026-11-20', _s());
      expect([for (final x in a) x.at], [for (final x in b) x.at]);
      expect([for (final x in a) x.test], [for (final x in b) x.test]);
      final c = promptsForDay('2026-11-20', _s(seed: 'seed-b'));
      final e = promptsForDay('2026-11-21', _s());
      expect([for (final x in c) _min(x.at)], isNot([for (final x in a) _min(x.at)]));
      expect([for (final x in e) _min(x.at)], isNot([for (final x in a) _min(x.at)]));
    });

    test('two of the day ask for the reaction test; with fewer prompts, at most all of them', () {
      expect(promptsForDay('2026-11-20', _s()).where((p) => p.test), hasLength(2));
      expect(promptsForDay('2026-11-20', _s(perDay: 6)).where((p) => p.test), hasLength(2));
      final tests = <int>{};
      for (var d = 0; d < 60; d++) {
        final p = promptsForDay(addDays('2026-11-20', d), _s());
        for (var k = 0; k < p.length; k++) {
          if (p[k].test) tests.add(k);
        }
      }
      expect(tests, {0, 1, 2, 3}, reason: 'the test falls on every part of the day over time');
    });

    test('every waking hour gets moments over the weeks, none outside the window', () {
      final byHour = List.filled(24, 0);
      for (var d = 0; d < 365; d++) {
        for (final p in promptsForDay(addDays('2026-11-20', d), _s())) {
          byHour[p.at.hour]++;
        }
      }
      for (var h = 0; h < 24; h++) {
        if (h >= 10 && h < 22) {
          // 4 a day over 12 hours: about 122 a year in each hour; even near the parts' edges well over half that
          expect(byHour[h], greaterThan(60), reason: 'hour $h');
        } else {
          expect(byHour[h], 0, reason: 'hour $h is quiet');
        }
      }
    });

    test('a window past midnight runs into the next calendar date', () {
      final p = promptsForDay('2026-11-20', _s(from: 15 * 60, until: 3 * 60));
      expect(p, hasLength(4));
      expect(p.first.at.isAfter(DateTime(2026, 11, 20, 14, 59)), isTrue);
      expect(p.last.at.isBefore(DateTime(2026, 11, 21, 3)), isTrue);
    });

    test('a short window holds fewer prompts, never closer than an hour', () {
      final p = promptsForDay('2026-11-20', _s(perDay: 6, from: 10 * 60, until: 14 * 60 + 30));
      expect(p.length, 4, reason: '4.5 hours: four parts of 67 min each');
      for (var i = 1; i < p.length; i++) {
        expect(p[i].at.difference(p[i - 1].at).inMinutes, greaterThanOrEqualTo(60));
      }
    });

    test('off: nothing planned', () {
      expect(promptsForDay('2026-11-20', _s(on: false)), isEmpty);
    });
  });

  group('arming', () {
    test('the moments still ahead over the next days, oldest first', () {
      final now = DateTime(2026, 11, 20, 15, 0);
      final p = upcomingPrompts(now, _s(), days: 3);
      expect(p, isNotEmpty);
      expect(p.every((x) => x.at.isAfter(now)), isTrue);
      for (var i = 1; i < p.length; i++) {
        expect(p[i].at.isAfter(p[i - 1].at), isTrue);
      }
      final today = promptsForDay('2026-11-20', _s()).where((x) => x.at.isAfter(now)).length;
      expect(p.length, today + 4 * 3);
    });

    test('a window past midnight: last evening\'s moments after midnight are still armed', () {
      final s = _s(from: 15 * 60, until: 3 * 60);
      final now = DateTime(2026, 11, 21, 0, 30); // still "20 Nov" by the 04:00 rule and by the window
      final late = promptsForDay('2026-11-20', s).where((x) => x.at.isAfter(now)).toList();
      final p = upcomingPrompts(now, s, days: 1);
      for (final x in late) {
        expect(p.map((y) => y.at), contains(x.at));
      }
    });

    test('off: nothing to arm', () {
      expect(upcomingPrompts(DateTime(2026, 11, 20, 9), _s(on: false)), isEmpty);
    });
  });

  group('settings file', () {
    test('round trip, and anything malformed is refused', () {
      final s = SharpSettings(
        on: true,
        perDay: 6,
        fromMin: 9 * 60 + 30,
        untilMin: 23 * 60,
        seed: 'ab12',
        firstOn: DateTime(2026, 11, 20, 9, 1),
        changed: DateTime(2026, 11, 20, 9, 2),
      );
      final j = s.toJson();
      expect(j['awake_from'], '09:30');
      expect(j['awake_until'], '23:00');
      expect(j['per_day'], 6);
      final back = SharpSettings.fromJson(j)!;
      expect(back.toJson(), j);
      for (final bad in <Map<String, Object?>>[
        {...j, 'per_day': 5},
        {...j, 'per_day': '4'},
        {...j, 'awake_from': '9:30'},
        {...j, 'awake_until': '10:00'},
        {...j, 'seed': ''},
        {...j, 'on': 'yes'},
        {...j, 'version': 2},
        {...j, 'first_on': 'yesterday'},
      ]) {
        expect(SharpSettings.fromJson(bad), isNull, reason: '$bad');
      }
      expect(SharpSettings.fromJson('x'), isNull);
    });
  });

  group('the suggested window', () {
    ({DateTime start, DateTime end}) night(int d, int startMin, int endMin) {
      final base = DateTime(2026, 11, 1 + d);
      return (start: base.add(Duration(minutes: startMin)), end: base.add(Duration(minutes: endMin)));
    }

    test('without 3 recorded nights: 10:00 to 22:00', () {
      expect(suggestWindow(const []), (10 * 60, 22 * 60));
      expect(suggestWindow([night(0, 23 * 60, 31 * 60), night(1, 23 * 60, 31 * 60)]), (10 * 60, 22 * 60));
    });

    test('from your usual wake-up plus 30 min to your usual sleep minus 60 min, on the half hour', () {
      // asleep around 23:40 (one after midnight), up around 07:20
      final nights = [
        night(0, 23 * 60 + 30, 31 * 60 + 10),
        night(1, 23 * 60 + 50, 31 * 60 + 25),
        night(2, 24 * 60 + 20, 31 * 60 + 20),
        night(3, 23 * 60 + 40, 31 * 60 + 40),
      ];
      // wake median 07:22.5 + 30 = 07:52 -> 08:00; sleep median 23:45 - 60 = 22:45 -> 22:30
      expect(suggestWindow(nights), (8 * 60, 22 * 60 + 30));
    });

    test('a late sleeper: asleep after 6, up in the afternoon', () {
      final nights = [for (var d = 0; d < 5; d++) night(d, 30 * 60 + 50 + d * 5, 38 * 60 + 30)];
      final (from, until) = suggestWindow(nights);
      expect(from, 15 * 60, reason: 'up 14:30 + 30 min');
      expect(until, 6 * 60, reason: 'asleep about 07:00 - 60 min');
      expect(windowOk(from, until), isTrue);
    });

    test('a schedule that leaves too short a window falls back to 10:00 to 22:00', () {
      // naps only: "asleep" 13:00-14:00 every day
      final nights = [for (var d = 0; d < 5; d++) night(d, 13 * 60, 14 * 60)];
      expect(suggestWindow(nights), (10 * 60, 22 * 60));
    });
  });

  test('the per-day seed does not depend on Dart\'s own hash codes', () {
    expect(daySeed('seed-a', '2026-11-20'), daySeed('seed-a', '2026-11-20'));
    expect(daySeed('seed-a', '2026-11-20'), isNot(daySeed('seed-a', '2026-11-21')));
    expect(daySeed('seed-a', '2026-11-20'), lessThan(math.pow(2, 48)));
  });
}
