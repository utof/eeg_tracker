// Sleep experiments (DECISIONS rows 838, 1050-1069): the log on disk, the app's picks, which nights count, the
// stages of an honest result and its words, and the night numbers read from made-up sleep reports. Expected p values
// and ranges come from an independent brute-force Python version (itertools; hashlib for the picks).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/sleep_experiments/result.dart';
import 'package:eeg_tracker/sleep_experiments/store.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sleep_trends_test.dart' show night;

final caffeine = kindById('caffeine_late')!, workout = kindById('workout_late')!, alcohol = kindById('alcohol')!;
const wB = [52, 61, 47, 70, 58, 66, 49, 73, 55, 63], oB = [75, 68, 59, 80, 71, 64, 77, 83, 69, 72];

NightNumbers nn({double? eff, double? pulse, double deep = 80, double awake = 20, double dream = 90, double asleep = 420, double start = 690}) =>
    NightNumbers({'efficiency': ?eff, 'pulse': ?pulse, 'deep': deep, 'awake': awake, 'dream': dream, 'sleep_start': start}, asleepMin: asleep, startMin: start);

ExperimentLog logOf(ExperimentKind kind, Map<String, DayLog> days, {String start = '2026-11-02', String? salt, String? ended}) =>
    ExperimentLog(SleepExperiment(id: '2026-11-02-090000', kind: kind, created: DateTime(2026, 11, 2, 9), start: start, salt: salt), days, ended);

/// 20 evenings from 2 Nov, with and without in turn, the efficiency of the night after from [wB] and [oB].
(ExperimentLog, Map<String, NightNumbers>) twenty() {
  final days = <String, DayLog>{}, nights = <String, NightNumbers>{};
  for (var i = 0; i < 20; i++) {
    final day = addDays('2026-11-02', i), w = i.isEven;
    days[day] = DayLog(answer: w ? Answer.withIt : Answer.without);
    nights[addDays(day, 1)] = nn(eff: (w ? wB : oB)[i ~/ 2].toDouble());
  }
  return (logOf(caffeine, days, ended: '2026-11-22'), nights);
}

void main() {
  group('what is offered', () {
    test('three experiments; only caffeine and the workout may be picked by the app; none is a custom one', () {
      expect([for (final k in experimentKinds) k.id], ['caffeine_late', 'workout_late', 'alcohol']);
      expect(caffeine.canPick && workout.canPick, isTrue);
      expect(alcohol.canPick, isFalse);
      expect(alcohol.nightAfterOut, isTrue);
      expect(caffeine.main, efficiency);
      expect(alcohol.main, pulseAsleep);
    });
  });

  group('the log on disk', () {
    late Directory tmp;
    late SleepExperimentStore store;
    final t0 = DateTime(2026, 11, 2, 21);
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sleepexp');
      store = SleepExperimentStore(Directory('${tmp.path}/sleep-experiments'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('start, tap, tap again, odd night, end: the last line about a day wins', () {
      final e = store.create(kind: alcohol, picked: false, now: t0);
      final id = e.plan.id;
      expect(id, '2026-11-02-210000');
      expect(e.plan.start, '2026-11-02');
      expect(e.running, isTrue);
      expect(store.answer(id, '2026-11-02', Answer.withIt, t0), isTrue);
      expect(store.answer(id, '2026-11-02', Answer.neither, t0.add(const Duration(minutes: 1))), isTrue);
      expect(store.odd(id, '2026-11-02', 'ill', true, t0), isTrue);
      expect(store.odd(id, '2026-11-02', 'nonsense', true, t0), isFalse);
      // a day before the start, and a day that has not come
      expect(store.answer(id, '2026-11-01', Answer.withIt, t0), isFalse);
      expect(store.answer(id, '2026-11-03', Answer.withIt, t0), isFalse);
      var got = store.read(id)!;
      expect(got.day('2026-11-02').answer, Answer.neither);
      expect(got.day('2026-11-02').odd, {'ill'});
      store.odd(id, '2026-11-02', 'ill', false, t0);
      store.answer(id, '2026-11-02', null, t0);
      got = store.read(id)!;
      expect(got.day('2026-11-02').answer, isNull);
      expect(got.day('2026-11-02').odd, isEmpty);
      // 1 a.m. still belongs to the evening before (a day runs 04:00 to 04:00)
      expect(store.answer(id, '2026-11-02', Answer.without, DateTime(2026, 11, 3, 1)), isTrue);
      store.end(id, DateTime(2026, 11, 20, 10));
      got = store.read(id)!;
      expect(got.ended, '2026-11-20');
      expect(store.answer(id, '2026-11-19', Answer.withIt, DateTime(2026, 11, 20, 11)), isFalse);
      expect(store.active(), isNull);
    });

    test('one at a time; the app never picks the nights for alcohol', () {
      store.create(kind: caffeine, picked: false, now: t0);
      expect(() => store.create(kind: workout, picked: false, now: t0.add(const Duration(hours: 1))), throwsStateError);
      store.end(store.active()!.plan.id, t0);
      expect(() => store.create(kind: alcohol, picked: true, now: t0.add(const Duration(hours: 1))), throwsArgumentError);
    });

    test('a damaged line is skipped, a foreign folder too', () {
      final id = store.create(kind: caffeine, picked: false, now: t0).plan.id;
      store.answer(id, '2026-11-02', Answer.withIt, t0);
      File('${store.dir.path}/$id/log.jsonl').writeAsStringSync('{half\n', mode: FileMode.append);
      Directory('${store.dir.path}/other').createSync();
      expect(store.all().single.day('2026-11-02').answer, Answer.withIt);
    });

    test('picks: drawn from the secret in blocks of 4 with 2 of each (checked against hashlib), once a day', () {
      const expected = '10101010110011000110'; // allocate('test-salt-1'), an independent Python version
      expect([for (var i = 0; i < 20; i++) pickAt('test-salt-1', i) ? '1' : '0'].join(), expected);
      expect([for (var i = 0; i < 20; i++) pickAt('another secret', i) ? '1' : '0'].join(), '00110110110011001001');

      final id = store.create(kind: caffeine, picked: true, now: t0, random: math.Random(4)).plan.id;
      final salt = store.read(id)!.plan.salt!;
      final first = store.pick(id, t0)!;
      expect(store.pick(id, t0.add(const Duration(hours: 1))), first, reason: 'asking again the same day');
      expect(first, pickAt(salt, 0));
      // a day without a draw is not a test night; the next draw is number 2 of the order
      final later = DateTime(2026, 11, 5, 20);
      expect(store.pick(id, later), pickAt(salt, 1));
      final got = store.read(id)!;
      expect(got.picksMade, 2);
      expect(got.day('2026-11-05').pickIndex, 1);
      expect(got.day('2026-11-03').pick, isNull);
      // an experiment where you choose never draws
      store.end(id, later);
      final own = store.create(kind: workout, picked: false, now: later.add(const Duration(minutes: 1))).plan.id;
      expect(store.pick(own, later.add(const Duration(minutes: 2))), isNull);
    });

    test('the files leave the phone with Export data and Share on Wi-Fi (their one list of files)', () {
      final id = store.create(kind: caffeine, picked: true, now: t0, random: math.Random(4)).plan.id;
      store.answer(id, '2026-11-02', Answer.withIt, t0);
      final paths = [for (final f in storedFiles(tmp)) f.path];
      expect(paths, ['sleep-experiments/$id/log.jsonl', 'sleep-experiments/$id/plan.json']);
      final plan = jsonDecode(File('${tmp.path}/sleep-experiments/$id/plan.json').readAsStringSync()) as Map;
      expect(plan['kind'], 'caffeine_late');
      expect(plan['picked'], isTrue);
      expect(plan['watched'], ['efficiency', 'deep', 'awake']);
      final line = jsonDecode(File('${tmp.path}/sleep-experiments/$id/log.jsonl').readAsLinesSync().last) as Map;
      expect(line, {'at': t0.toIso8601String(), 'day': '2026-11-02', 'event': 'answer', 'answer': 'with'});
    });
  });

  group('which nights count', () {
    test('in between, no night, odd, after a short night; tonight is not judged yet', () {
      final e = logOf(caffeine, {
        '2026-11-02': const DayLog(answer: Answer.withIt),
        '2026-11-03': const DayLog(answer: Answer.neither),
        '2026-11-04': const DayLog(answer: Answer.without), // no report for the night after
        '2026-11-05': const DayLog(answer: Answer.without, odd: {'ill'}),
        '2026-11-06': const DayLog(answer: Answer.without),
        '2026-11-07': const DayLog(answer: Answer.withIt), // the night before it was 4 hours
        '2026-11-08': const DayLog(answer: Answer.without),
        '2026-11-09': const DayLog(answer: Answer.withIt), // today: not slept yet
        '2026-11-01': const DayLog(answer: Answer.withIt), // before the start
      });
      final nights = {
        '2026-11-02': nn(eff: 90),
        '2026-11-03': nn(eff: 80),
        '2026-11-04': nn(eff: 85),
        '2026-11-06': nn(eff: 70),
        '2026-11-07': nn(eff: 88, asleep: 240),
        '2026-11-08': nn(eff: 95),
        '2026-11-09': nn(eff: 87),
      };
      final p = sortNights(e, nights);
      expect([for (final n in p.counted) '${n.day} ${n.withIt}'], ['2026-11-02 true', '2026-11-06 false', '2026-11-08 false']);
      expect(p.leftOut, {LeftOut.inBetween: 1, LeftOut.noNight: 1, LeftOut.odd: 1, LeftOut.afterShortNight: 1});
      expect(leftOutLine(p), 'Left out: 4 nights (1 in between, 1 no night that counts, 1 ill or not your own bed, 1 after a night under 5 hours).');
      // once ended, the last evening without a night is a missing night like any other
      final ended = sortNights(ExperimentLog(e.plan, e.days, '2026-11-12'), nights);
      expect(ended.leftOut[LeftOut.noNight], 2);
    });

    test('alcohol: the night after drinks is in neither pile, a second night of drinks still counts', () {
      final e = logOf(alcohol, {
        '2026-11-06': const DayLog(answer: Answer.withIt),
        '2026-11-07': const DayLog(answer: Answer.withIt),
        '2026-11-08': const DayLog(answer: Answer.without),
        '2026-11-09': const DayLog(answer: Answer.without),
      }, ended: '2026-11-12');
      final nights = {for (var d = 7; d <= 10; d++) '2026-11-${d.toString().padLeft(2, '0')}': nn(pulse: 60)};
      final p = sortNights(e, nights);
      expect([for (final n in p.counted) '${n.day} ${n.withIt}'], ['2026-11-06 true', '2026-11-07 true', '2026-11-09 false']);
      expect(p.leftOut, {LeftOut.nightAfter: 1});
      // the same log for caffeine has no such rule
      expect(sortNights(logOf(caffeine, e.days, ended: '2026-11-12'), nights).counted.length, 4);
    });

    test('Friday and Saturday evenings lead into days off', () {
      CountedNight on(String day) => CountedNight(day: day, withIt: true, night: nn());
      expect(on('2026-11-06').dayOff, isTrue); // Friday
      expect(on('2026-11-07').dayOff, isTrue);
      expect(on('2026-11-08').dayOff, isFalse); // Sunday evening: work tomorrow
      expect(on('2026-11-05').dayOff, isFalse);
    });
  });

  group('the result, stage by stage', () {
    test('under 5 of a kind: only the counts', () {
      final e = logOf(caffeine, {
        for (var i = 0; i < 9; i++) addDays('2026-11-02', i): DayLog(answer: i < 3 ? Answer.withIt : Answer.without),
      }, ended: '2026-11-20');
      final nights = {for (var i = 0; i < 9; i++) addDays('2026-11-03', i): nn(eff: i < 3 ? 60 : 90)};
      final res = resultFor(e, nights);
      final r = res.measures.first;
      expect(r.stage, Stage.notEnough);
      expect(r.meanWith, isNull);
      expect(r.p, isNull);
      expect(sentence(res, r), 'Not enough yet: 3 nights with, 6 without. The averages show from 5 of each.');
      expect(matchedLine(res, r), isNull);
    });

    test('from 5 of each: the two averages and "too early to say", no test', () {
      final e = logOf(caffeine, {
        for (var i = 0; i < 12; i++) addDays('2026-11-02', i): DayLog(answer: i.isEven ? Answer.withIt : Answer.without),
      }, ended: '2026-11-20');
      final nights = {for (var i = 0; i < 12; i++) addDays('2026-11-03', i): nn(eff: i.isEven ? 80 : 90)};
      final res = resultFor(e, nights);
      final r = res.measures.first;
      expect(r.stage, Stage.soFar);
      expect(r.p, isNull);
      expect(r.range, isNull);
      expect(r.needed, 10, reason: 'other people\'s spread (6.5) until 14 ordinary nights: 9.5 points needs 10');
      expect(r.ownSpread, isFalse);
      expect(sentence(res, r), 'So far 80 % with (6 nights) and 90 % without (6 nights). Too early to say: this needs about 10 of each.');
      expect(neededLine(r), contains('about 10 nights with and 10 without'));
      expect(neededLine(r), contains('other people'));
    });

    test('10 of each, a clear gap: seen together, with the range (all 184 756 labellings)', () {
      final (e, nights) = twenty();
      final res = resultFor(e, nights);
      final r = res.measures.first;
      expect(r.stage, Stage.verdict);
      expect(r.diff, closeTo(-12.4, 1e-9));
      expect(r.p, closeTo(0.003929507025482257, 1e-12));
      expect(r.range!.low, closeTo(-20.0, 0.01));
      expect(r.range!.high, closeTo(-4.75, 0.01));
      expect(r.clear, isTrue);
      expect(res.tested, isFalse);
      expect(
        sentence(res, r),
        'On your 10 nights with late caffeine, your sleep efficiency was 12 points lower than on 10 nights without '
        '(likely between 5 and 20). Seen together, not proven: other things about those days may differ too.',
      );
      // never the word "caused", and never a number without its range
      for (final m in res.measures) {
        expect(sentence(res, m), isNot(contains('caus')));
      }
    });

    test('10 of each the app picked: tested, by the orders the draw could have given (7776)', () {
      const order = '10101010110011000110'; // pickAt('test-salt-1', i)
      final days = <String, DayLog>{}, nights = <String, NightNumbers>{};
      var w = 0, o = 0;
      for (var i = 0; i < 20; i++) {
        final day = addDays('2026-11-02', i * 2), pick = order[i] == '1'; // a test night every other day
        // the owner did otherwise on test night 4: it still counts as picked
        days[day] = DayLog(pick: pick, pickIndex: i, answer: i == 3 ? Answer.neither : (pick ? Answer.withIt : Answer.without));
        nights[addDays(day, 1)] = nn(eff: (pick ? wB[w++] : oB[o++]).toDouble());
        // an evening in between with an answer but no pick is not a test night
        days[addDays(day, 1)] = const DayLog(answer: Answer.withIt);
        if (i < 3) nights[addDays(day, 2)] = nn(eff: 10); // (13 ordinary nights: other people's spread still)
      }
      final res = resultFor(logOf(caffeine, days, salt: 'test-salt-1', ended: '2026-12-20'), nights);
      final r = res.measures.first;
      expect(res.piles.counted.length, 20);
      expect(res.tested, isTrue);
      expect(res.keptTo, (kept: 19, answered: 20));
      expect(r.diff, closeTo(-12.4, 1e-9));
      expect(r.p, closeTo(0.006687242798353909, 1e-12));
      expect(r.range!.low, closeTo(-20.8, 0.01));
      expect(r.range!.high, closeTo(-4.0, 0.01));
      expect(
        sentence(res, r),
        'Tested: on the 10 nights the app picked for late caffeine, your sleep efficiency was 12 points lower than on '
        'the 10 nights it picked without (likely between 4 and 21).',
      );
    });

    test('10 of each and nothing there: "no difference seen", with what this many nights cannot show', () {
      final days = <String, DayLog>{}, nights = <String, NightNumbers>{};
      const a = [60, 72, 65, 58, 70, 63, 69, 64, 67, 61], b = [66, 61, 71, 64, 68, 59, 73, 62, 65, 70];
      for (var i = 0; i < 20; i++) {
        final day = addDays('2026-11-02', i);
        days[day] = DayLog(answer: i.isEven ? Answer.withIt : Answer.without);
        nights[addDays(day, 1)] = nn(pulse: (i.isEven ? a : b)[i ~/ 2].toDouble());
      }
      final res = resultFor(logOf(alcohol, days, ended: '2026-11-25'), nights);
      // alcohol: the 10 nights after drinks are in neither pile, so only the drinking nights are left
      expect(res.piles.nWithout, 0);
      final res2 = resultFor(logOf(workout, days, ended: '2026-11-25'), nights);
      final r = res2.measures.first;
      expect(r.measure, pulseAsleep);
      // the workout's pulse needs 20 x (3.3 / 3.9)^2 = 15 of each by other people's spread: 10 is still "so far"
      expect(r.needed, 15);
      expect(r.stage, Stage.soFar);
      expect(sentence(res2, r), startsWith('So far 64.9 a minute with (10 nights) and 65.9 a minute without (10 nights). Too early to say'));
    });

    test('your own spread is used from 14 ordinary nights', () {
      // 16 ordinary nights of efficiency with a sample spread of exactly 4.0 (8 at 84 - d and 8 at 84 + d)
      final d = 4.0 * math.sqrt(15 / 16);
      final nights = {for (var i = 0; i < 16; i++) addDays('2026-10-01', i): nn(eff: 84 + (i.isEven ? d : -d))};
      final n = neededFor(caffeine.watched.first, ordinaryValues('efficiency', nights, const {}));
      expect(n.own, isTrue);
      expect(n.needed, 5, reason: '20 x (4 / 9.5)^2 = 3.5, never under 5');
      expect(neededWords(efficiency, n.needed, n.own), contains('how much your own nights vary, this needs about 10 nights with and 10 without'));
      final few = neededFor(caffeine.watched.first, [80, 90, 85]);
      expect(few.own, isFalse);
      // a tiny expected change against a wide spread: said before the start
      expect(neededWords(dreamSleep, 80, false), contains('more than 60 nights'));
    });

    test('similar nights: a gap that shrinks by half says so', () {
      // work-day evenings only (Mon-Thu), with-nights all two hours late except two; the gap among usual-bedtime
      // nights is far smaller than the raw one
      final days = <String, DayLog>{}, nights = <String, NightNumbers>{};
      final evenings = [
        for (var i = 0; i < 40; i++)
          if (dayNoon(addDays('2026-11-02', i)).weekday <= DateTime.thursday) addDays('2026-11-02', i),
      ].take(20).toList();
      for (final (i, day) in evenings.indexed) {
        final w = i.isEven, late = w && i >= 4;
        days[day] = DayLog(answer: w ? Answer.withIt : Answer.without);
        nights[addDays(day, 1)] = nn(eff: w ? (late ? 70.0 + i % 3 : 88.0) : 90.0 + i % 3, start: late ? 810 : 690);
      }
      final res = resultFor(logOf(caffeine, days, ended: '2026-12-20'), nights);
      final r = res.measures.first;
      expect(r.clear, isTrue);
      expect(r.matched!.nWith, 2);
      expect(r.matched!.nWithout, 10);
      expect(r.matched!.diff, closeTo(88 - 91.0, 1e-9));
      expect(matchedLine(res, r), endsWith('3 points lower. Part of the gap may be late nights, not late caffeine.'));
    });
  });

  group('words', () {
    test('sizes, levels and changes in plain units', () {
      expect(amount(deepSleep, -27.6), '28 minutes');
      expect(amount(efficiency, 1.2), '1 point');
      expect(amount(pulseAsleep, 2.44), '2.4 beats a minute');
      expect(amount(pulseAsleep, 1.0), '1 beat a minute');
      expect(level(efficiency, 82.4), '82 %');
      expect(level(deepSleep, 72), '1 h 12 min');
      expect(level(awakeInNight, 25), '25 min');
      expect(level(pulseAsleep, 58.0), '58 a minute');
      expect(level(sleepStart, 700), '23:40');
      expect(level(sleepStart, 750), '00:30');
      expect(change(sleepStart, 36), '36 minutes later');
      expect(change(deepSleep, -34), '34 minutes less');
      expect(change(efficiency, 0.2), 'no different');
    });
  });

  group('night numbers from sleep reports', () {
    SleepReport rep(Map<String, Object?> j) => SleepReport(j);

    test('one night: deep, dream, awake, efficiency, when sleep began; the pulse beside it', () {
      // asleep 23:30 to 07:00 (450 min in bed from the first sleep; the recording began 20 min earlier: 470)
      final r = rep(night(DateTime(2026, 11, 10, 23, 30), DateTime(2026, 11, 11, 7), light: 250, deep: 70, dream: 90));
      final got = nightNumbersFrom([r], pulse: {'2026-11-11': 57.5});
      final n = got['2026-11-11']!;
      expect(got.keys, ['2026-11-11']);
      expect(n.values['deep'], 70);
      expect(n.values['dream'], 90);
      expect(n.values['awake'], 20);
      expect(n.values['efficiency'], closeTo(410 / 470 * 100, 1e-9));
      expect(n.values['sleep_start'], 690);
      expect(n.values['pulse'], 57.5);
      expect(n.asleepMin, 410);
    });

    test('a night that began after midnight sorts after an evening one; no pulse, no pulse number', () {
      final r = rep(night(DateTime(2026, 11, 11, 0, 40), DateTime(2026, 11, 11, 8)));
      final n = nightNumbersFrom([r])['2026-11-11']!;
      expect(n.startMin, 760);
      expect(n.values.containsKey('pulse'), isFalse);
    });

    test('someone else\'s night, a too noisy night and an unscored night do not count', () {
      final a = night(DateTime(2026, 11, 10, 23), DateTime(2026, 11, 11, 7), answer: 'someone else');
      final b = night(DateTime(2026, 11, 11, 23), DateTime(2026, 11, 12, 7), noisy: 0.7);
      final c = {...night(DateTime(2026, 11, 12, 23), DateTime(2026, 11, 13, 7)), 'scored': false};
      final d = {...night(DateTime(2026, 11, 13, 23), DateTime(2026, 11, 14, 7)), 'no_sleep_found': true};
      expect(nightNumbersFrom([rep(a), rep(b), rep(c), rep(d)]), isEmpty);
    });
  });
}
