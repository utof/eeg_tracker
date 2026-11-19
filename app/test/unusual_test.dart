// The "Unusual for you" card (DECISIONS rows 290-299): its words from the detector's verdicts, the silent start,
// "back in your usual range", the track record, the switch, "feeling ill", the back-test log and its export.
// The detector's numbers themselves are checked against the Python reference in unusual_cross_check_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/unusual/card.dart';
import 'package:eeg_tracker/unusual/detector.dart';
import 'package:eeg_tracker/unusual/store.dart';
import 'package:flutter_test/flutter_test.dart';

const start = '2026-01-01';
String day(int k) => addDays(start, k);

/// Noon of day [k] (a day runs 04:00 to 04:00).
DateTime at(int k) => dayNoon(day(k));

/// Day k -> value for k in 0..n-1; null leaves a day out.
Map<String, double> series(int n, double? Function(int k) f) => {
  for (var k = 0; k < n; k++)
    if (f(k) != null) day(k): f(k)!,
};

double wobble(int k) => 420.0 + 10 * ((k % 3) - 1);

String plain(String s) => s.replaceAll(' ', ' ');

UnusualCard cardOn(Map<String, Map<String, double>> s, int today, {Map<String, Set<String>> causes = const {}}) {
  final v = judgeDays(s, start, day(today));
  return unusualCard(v, s, day(today), causes: causes);
}

void main() {
  group('the card\'s words', () {
    test('two short nights: one plain sentence, what it is based on, and a line for the main screen', () {
      final s = {'asleep': series(60, (k) => k >= 58 ? 300 : wobble(k))};
      final c = cardOn(s, 59);
      expect(c.kind, CardKind.alert);
      expect(plain(c.headline), 'Your sleep has been 2 h shorter than usual for 2 nights.');
      expect(c.lines, isEmpty);
      expect(c.episode, day(59));
      expect(plain(c.status!), contains('your sleep length'));
      expect(plain(c.status!), contains('the 28 days that end a week before'));
      expect(plain(c.mainLine!), 'Unusual for you: your sleep has been 2 h shorter than usual for 2 nights.');
    });

    test('one short night is not a card', () {
      final c = cardOn({'asleep': series(60, (k) => k == 59 ? 300 : wobble(k))}, 59);
      expect(c.kind, CardKind.quiet);
      expect(c.mainLine, isNull);
    });

    test('a run that bridged a missing night says so; minutes round to 10', () {
      final s = {'asleep': series(60, (k) => k == 58 ? null : (k == 57 || k == 59 ? 345 : wobble(k)))};
      final c = cardOn(s, 59);
      expect(plain(c.headline), 'Your sleep has been 1 h 20 min shorter than usual on 2 of the last 3 nights.');
    });

    test('ratings and the reaction test, in the order of the trends page, with values and the usual', () {
      final s = {
        'asleep': series(60, (k) => k >= 58 ? 560 : wobble(k)),
        'mood': series(60, (k) => k >= 58 ? 2 : (k % 4 == 0 ? 3 : 4)),
        'kss': series(60, (k) => k >= 58 ? 7 : 4),
        'reaction': series(60, (k) => k >= 58 ? 340 : 280.0 + k % 3),
      };
      final c = cardOn(s, 59);
      expect(plain(c.headline), 'Your sleep has been 2 h 20 min longer than usual for 2 nights.');
      expect([for (final l in c.lines) plain(l)], [
        'You have felt sleepier than usual for 2 mornings (7 of 9; usual 4 of 9).',
        'Your mood has been lower than usual for 2 mornings (2 of 5; usual 4 of 5).',
        'Your reaction test has been slower than usual for 2 mornings (340 ms; usual 281 ms).',
      ]);
      expect(plain(c.status!), contains('your sleep length, sleepiness, mood and reaction test'));
    });

    test('better mood or more alert is not a card (one direction counts)', () {
      final s = {
        'mood': series(60, (k) => k >= 58 ? 5 : 3),
        'kss': series(60, (k) => k >= 58 ? 1 : 4),
      };
      expect(cardOn(s, 59).kind, CardKind.quiet);
    });

    test("the headband's own numbers never make a card", () {
      final s = {
        'asleep': series(60, wobble),
        'iaf': series(60, (k) => k >= 58 ? 10.8 : 9.8 + 0.05 * ((k % 3) - 1)),
      };
      final v = judgeDays(s, start, day(59));
      expect(v.last.ruleAll, isTrue);
      expect(unusualCard(v, s, day(59)).kind, CardKind.quiet);
    });

    test('the card stays through one day without numbers', () {
      final s = {'asleep': series(59, (k) => k >= 57 ? 300 : wobble(k))};
      final c = cardOn(s, 59);
      expect(c.kind, CardKind.alert);
      expect(plain(c.headline), 'Your sleep has been 2 h shorter than usual for 2 nights.');
    });
  });

  group('silent first, then the track record', () {
    test('under 28 days with a number: learning, silent even when the rule holds', () {
      final s = {'asleep': series(24, (k) => k >= 22 ? 300 : wobble(k))};
      final v = judgeDays(s, start, day(23));
      expect(v.last.ruleCore, isTrue);
      final c = unusualCard(v, s, day(23));
      expect(c.kind, CardKind.learning);
      expect(plain(c.headline), 'Learning your usual: 23 of 28 days.');
      expect(c.mainLine, isNull);
      expect(c.status, contains('only notes what it would have said'));
    });

    test('nothing yet: learning from 0', () {
      final c = unusualCard(const [], const {}, day(0));
      expect(c.kind, CardKind.learning);
      expect(plain(c.headline), 'Learning your usual: 0 of 28 days.');
    });

    test('quiet: what it would have said while silent and what it said since', () {
      final s = {'asleep': series(80, (k) => (k == 22 || k == 23 || k == 50 || k == 51) ? 300 : wobble(k))};
      final c = cardOn(s, 79);
      expect(c.kind, CardKind.quiet);
      expect(c.headline, 'Nothing unusual for you lately.');
      expect(
        plain(c.status!),
        startsWith('Since ${dayLabel(day(28))}, when it switched on: 1 card. In its silent first 28 days it would '
            'have shown 1.'),
      );
    });

    test('back in your usual range for 3 days after a card, once a number is back', () {
      final s = {'asleep': series(80, (k) => (k == 70 || k == 71) ? 300 : wobble(k))};
      final c = cardOn(s, 72);
      expect(c.kind, CardKind.back);
      expect(c.headline, 'Back in your usual range.');
      expect(plain(c.lines.single), 'It showed on ${dayLabel(day(71))}: sleep shorter than usual.');
      expect(c.mainLine, isNull);
      expect(cardOn(s, 74).kind, CardKind.back);
      expect(cardOn(s, 75).kind, CardKind.quiet);
    });

    test('a card that only faded for lack of numbers is not called "back"', () {
      final s = {'asleep': series(72, (k) => (k == 70 || k == 71) ? 300 : wobble(k))};
      expect(cardOn(s, 73).kind, CardKind.quiet);
    });
  });

  group('the files: switch, "feeling ill", back-test log', () {
    late Directory tmp;
    late UnusualStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('unusual_test');
      store = UnusualStore(Directory('${tmp.path}/unusual'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    List<Map<String, Object?>> logLines() => [
      for (final l in File('${tmp.path}/unusual/log.jsonl').readAsLinesSync()) jsonDecode(l) as Map<String, Object?>,
    ];

    test('on unless switched off; off writes nothing and says so', () {
      expect(store.on, isTrue);
      store.setOn(false, at(10));
      expect(UnusualStore(store.dir).on, isFalse);
      final c = refreshUnusual(store, {'asleep': series(60, wobble)}, at(59));
      expect(c.kind, CardKind.off);
      expect(File('${tmp.path}/unusual/log.jsonl').existsSync(), isFalse);
      store.setOn(true, at(11));
      expect(store.on, isTrue);
      final events = File('${tmp.path}/unusual/events.jsonl').readAsLinesSync();
      expect([for (final e in events) (jsonDecode(e) as Map)['event']], ['switched off', 'switched on']);
    });

    test('the log: one line per finished day, written once, with both ways', () {
      final s = {
        'asleep': series(60, (k) => (k == 40 || k == 41) ? 300 : wobble(k)),
        'iaf': series(60, (k) => (k == 50 || k == 51) ? 10.8 : 9.8 + 0.05 * ((k % 3) - 1)),
      };
      refreshUnusual(store, s, at(59));
      var lines = logLines();
      expect(lines.length, 59); // days 0-58; today is not over
      expect(lines.first['day'], day(0));
      expect(lines.first['phase'], 'silent');
      final d41 = lines.firstWhere((l) => l['day'] == day(41));
      expect(d41['card'], isTrue);
      expect(d41['shown'], isTrue);
      expect(d41['numbers'], ['asleep']);
      expect(plain(d41['words']! as String), 'Your sleep has been 2 h shorter than usual for 2 nights.');
      final asleep = (d41['values']! as Map)['asleep'] as Map;
      expect(asleep['value'], 300);
      expect(asleep['state'], 'down');
      expect(asleep['run'], 2);
      final d51 = lines.firstWhere((l) => l['day'] == day(51));
      expect(d51['card'], isFalse);
      expect(d51['withHeadband'], isTrue);
      expect(d51['numbersWithHeadband'], ['iaf']);
      refreshUnusual(store, s, at(59).add(const Duration(hours: 3)));
      expect(logLines().length, 59);
      refreshUnusual(store, s, at(60));
      lines = logLines();
      expect(lines.length, 60);
      expect(lines.last['day'], day(59));
    });

    test('a damaged log line is skipped, and its day is not written again', () {
      Directory('${tmp.path}/unusual').createSync();
      File('${tmp.path}/unusual/log.jsonl').writeAsStringSync('{"day":"${day(0)}"}\nnot json\n');
      refreshUnusual(store, {'asleep': series(3, wobble)}, at(2));
      expect(logLines, throwsFormatException);
      final days = [
        for (final l in File('${tmp.path}/unusual/log.jsonl').readAsLinesSync())
          if (l.startsWith('{')) (jsonDecode(l) as Map)['day'],
      ];
      expect(days, [day(0), day(1)]);
    });

    test('"feeling ill" pauses the card for two weeks; resuming ends it', () {
      final s = {'asleep': series(80, (k) => (k == 58 || k == 59) ? 300 : wobble(k))};
      final c = refreshUnusual(store, s, at(59));
      expect(c.kind, CardKind.alert);
      store.setCauses(c.episode!, {'feeling ill', 'stress'}, at(59));
      expect(store.causes(), {
        day(59): {'feeling ill', 'stress'},
      });
      final p = refreshUnusual(store, s, at(60));
      expect(p.kind, CardKind.paused);
      expect(p.headline, 'Paused until ${dayLabel(day(73))}.');
      expect(p.pausedUntil, day(73));
      store.resume(at(62));
      expect(refreshUnusual(store, s, at(62)).kind, isNot(CardKind.paused));
    });

    test('causes: the latest choice for a card wins; taking "feeling ill" back undoes the pause', () {
      final s = {'asleep': series(80, (k) => (k == 58 || k == 59) ? 300 : wobble(k))};
      store.setCauses(day(59), {'feeling ill'}, at(59));
      expect(store.ill().single.tapped, day(59));
      store.setCauses(day(59), {'late night'}, at(59).add(const Duration(minutes: 1)));
      expect(store.ill(), isEmpty);
      expect(refreshUnusual(store, s, at(60)).kind, isNot(CardKind.paused));
      final c = cardOn(s, 59, causes: store.causes());
      expect(c.causes, {'late night'});
    });

    test('Export data takes the folder with everything else', () {
      store.setOn(false, at(1));
      store.setOn(true, at(2));
      refreshUnusual(store, {'asleep': series(3, wobble)}, at(2));
      final paths = [for (final f in storedFiles(tmp)) f.path];
      expect(paths, ['unusual/events.jsonl', 'unusual/log.jsonl', 'unusual/settings.json']);
    });
  });
}
