// Self-experiments (DECISIONS rows 200-209): the draw, the weekday rule, the plan's hash, what a day may show,
// when results open, the randomisation test, its range, adherence and the words. Expected values come from an
// independent brute-force Python version (itertools over every order; hashlib for the draw), not from this code.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/experiments/analysis.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/experiments/store.dart';
import 'package:eeg_tracker/export/store.dart' show storedFiles;
import 'package:eeg_tracker/training/check.dart' show sha256Hex;
import 'package:eeg_tracker/training/reveal.dart' show permutationTest;
import 'package:eeg_tracker/trends/days.dart';
import 'package:flutter_test/flutter_test.dart';

List<double?> nums(List<num?> v) => [for (final x in v) x?.toDouble()];

// 14 days, salt "test-salt-1" (no weekday rule at 2 weeks): order 10101010110010
const a14 = [457, 426, 457, 416, 449, 417, 473, 425, 472, 463, 425, 422, 440, 430];
// 28 days, salt "test-salt-1": order 0110001110010110001101011010 (the first draw broke the weekday rule)
const a28 = [425, 442, 461, 436, 396, 416, 459, 450, 466, 419, 402, 470, 428, 471, 477, 424, 421, 404, 467, 453, 415, 445, 408, 454, 475, 396, 443, 423];
const b28 = [471, 440, 354, 332, 433, 394, 381, 454, 459, 426, 429, 435, 476, 442, 438, 439, 365, 465, 453, 439, 351, 398, 449, 357, 414, 456, 374, 476];
const c28 = [423, 419, 422, 424, 421, 427, 416, 418, 426, 420, 415, 426, 429, 417, 412, 419, 419, 418, 428, 414, 428, 412, 415, 424, 427, 425, 422, 421];

void main() {
  group('the draw', () {
    test('the same secret always gives the same order (checked against hashlib)', () {
      expect(orderText(drawDays('test-salt-1', 14)), '10101010110010');
      expect(orderText(drawDays('test-salt-1', 28)), '0110001110010110001101011010');
      expect(orderText(drawDays('test-salt-1', 42)), '101010101100110001101100100110010110100110');
      expect(orderText(drawDays('another secret', 28)), '1010101011000011001111001010');
      expect(orderText(drawDays('another secret', 42)), '011010011010010110101001010111000011101010');
      expect(orderText(drawDays('s3', 14)), '01100101011001');
    });

    test('every block of 4 has 2 of each, a last pair 1 of each, and every weekday both kinds', () {
      final r = math.Random(5);
      for (var k = 0; k < 60; k++) {
        final salt = 'salt-${r.nextInt(1 << 30)}';
        for (final days in [28, 42, 56]) {
          final o = drawDays(salt, days);
          expect(o.length, days);
          for (var b = 0; b + 4 <= days; b += 4) {
            expect(o.sublist(b, b + 4).where((d) => d).length, 2, reason: '$salt $days block $b');
          }
          if (days % 4 == 2) expect(o[days - 1] != o[days - 2], isTrue);
          for (var col = 0; col < 7; col++) {
            final n = [for (var i = col; i < days; i += 7) o[i]];
            expect(n.contains(true) && n.contains(false), isTrue, reason: '$salt $days weekday $col');
          }
          expect(spreadOk(o), isTrue);
        }
      }
    });

    test('an odd number of days is refused; the weekday rule sees a one-kind weekday', () {
      expect(() => drawDays('x', 7), throwsArgumentError);
      expect(spreadOk(orderFrom('1010101' '1010101' '1010101')!), isFalse);
      expect(spreadOk(orderFrom('1010101' '1010101')!), isTrue, reason: 'two days of a weekday are not ruled');
      expect(spreadOk(orderFrom('1010101' '0101010' '1010101')!), isTrue);
    });

    test('the sealed order hashes as canonical JSON and notices an edit', () {
      final s = SealedOrder.draw('test-salt-1', 28);
      expect(s.sha, 'bcb21d98f5db36ad706d36b332559dcd08304f7a966dae8ac82f8b7d59994485');
      expect(s.consistent, isTrue);
      final back = SealedOrder.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
      expect(back.sha, s.sha);
      final edited = SealedOrder('test-salt-1', [...s.order]..[0] = !s.order[0]);
      expect(edited.consistent, isFalse);
      expect(SealedOrder.fromJson({'salt': 'x', 'allocation': '10a'}), isNull);
    });
  });

  group('the randomisation test', () {
    test('14 days: the difference, p over all 432 orders, and p for a guessed effect', () {
      final o = Orders.of(drawDays('test-salt-1', 14), nums(a14));
      expect(o.exact, isTrue);
      expect(o.count, 432);
      expect(o.diff(), closeTo(35.71428571428572, 1e-9));
      expect(o.p(), closeTo(0.004629629629629629, 1e-12));
      expect(o.p(30), closeTo(0.3055555555555556, 1e-12));
    });

    test('without the weekday rule and with every number it equals the replay check\'s block test', () {
      final order = drawDays('test-salt-1', 14);
      final mine = Orders.of(order, nums(a14));
      final theirs = permutationTest([for (final v in a14) v.toDouble()], order, [for (var i = 0; i < 14; i++) blockOf(i)])!;
      expect(mine.p(), closeTo(theirs.p, 1e-12));
      expect(mine.diff(), closeTo(theirs.diff, 1e-12));
      expect(mine.count, theirs.orders);
    });

    test('28 days: only the 118 852 orders the weekday rule allows are counted', () {
      final order = drawDays('test-salt-1', 28);
      final a = Orders.of(order, nums(a28));
      expect(a.count, 118852);
      expect(a.diff(), closeTo(44.28571428571428, 1e-9));
      expect(a.p(), closeTo(1.6827651196446e-05, 1e-12));
      final b = Orders.of(order, nums(b28));
      expect(b.diff(), closeTo(-8.857142857142833, 1e-9));
      expect(b.p(), closeTo(0.5693804058829468, 1e-12));
    });

    test('days without a number are left out, in every order', () {
      final v14 = nums(a14)..[2] = null..[9] = null..[13] = null;
      final o = Orders.of(drawDays('test-salt-1', 14), v14);
      expect(o.have, 11);
      expect(o.diff(), closeTo(36.366666666666674, 1e-9));
      expect(o.p(), closeTo(0.009259259259259259, 1e-12));
      final v28 = nums(a28)..[2] = null..[9] = null..[27] = null;
      final o28 = Orders.of(drawDays('test-salt-1', 28), v28);
      expect(o28.diff(), closeTo(45.13461538461536, 1e-9));
      expect(o28.p(), closeTo(3.3655302392892e-05, 1e-12));
    });

    test('too many orders: 50 000 seeded draws, the same every time, close to the exact p', () {
      final order = drawDays('test-salt-1', 28);
      final exact = Orders.of(order, nums(b28));
      final s1 = Orders.of(order, nums(b28), maxExact: 1000), s2 = Orders.of(order, nums(b28), maxExact: 1000);
      expect(s1.exact, isFalse);
      expect(s1.count, 50000);
      expect(s1.p(), s2.p());
      expect(s1.p(), closeTo(exact.p(), 0.01));
    });
  });

  group('the range', () {
    ({double low, double high})? range(List<bool> order, List<double?> v) {
      final have = [for (final x in v) ?x];
      return shiftRange(Orders.of(order, v), have.reduce(math.max) - have.reduce(math.min));
    }

    test('is every effect the test does not reject at 5 % (brute-force values)', () {
      final o14 = drawDays('test-salt-1', 14), o28 = drawDays('test-salt-1', 28);
      var r = range(o14, nums(a14))!;
      expect(r.low, closeTo(24.0, 1e-4));
      expect(r.high, closeTo(48.5, 1e-4));
      r = range(o28, nums(a28))!;
      expect(r.low, closeTo(34.75, 1e-4));
      expect(r.high, closeTo(54.0, 1e-4));
      r = range(o28, nums(b28))!;
      expect(r.low, closeTo(-39.666666666667, 1e-4));
      expect(r.high, closeTo(24.4, 1e-4));
      r = range(o28, nums(c28))!;
      expect(r.low, closeTo(-6.0, 1e-4));
      expect(r.high, closeTo(2.833333333333, 1e-4));
      r = range(o28, nums(a28)..[2] = null..[9] = null..[27] = null)!;
      expect(r.low, closeTo(34.39507918551905, 1e-4));
      expect(r.high, closeTo(55.71428571428665, 1e-4));
    });

    test('leaves out zero exactly when p is under 0.05', () {
      final o28 = drawDays('test-salt-1', 28);
      for (final v in [a28, b28, c28]) {
        final o = Orders.of(o28, nums(v)), r = range(o28, nums(v))!;
        expect(r.low > 0 || r.high < 0, o.p() < 0.05);
        expect(r.low <= o.diff() && o.diff() <= r.high, isTrue);
      }
    });

    test('no range when the test cannot reject anything (4 days: 6 orders, smallest p 1/3)', () {
      expect(range([true, false, false, true], nums([5, 1, 2, 6])), isNull);
      expect(range([true, true, false, false], nums([5, null, null, null])), isNull);
    });
  });

  group('results and words', () {
    final order = drawDays('test-salt-1', 28);
    List<ExpDay> days(List<int> v, {String id = 'asleep', Map<int, bool> kept = const {}, int? only}) => [
      for (var i = 0; i < (only ?? v.length); i++)
        ExpDay(index: i, day: addDays('2026-11-20', i), doIt: order[i], kept: kept[i], values: {id: v[i].toDouble()}),
    ];
    final asleep = outcomeById('asleep')!;

    test('a clear effect: likely real, as assigned', () {
      final r = analyse(asleep, days(a28), order);
      expect(r.verdict, Verdict.likelyReal);
      expect(r.tested!.nDo, 14);
      expect(r.tested!.nDont, 14);
      expect(
        sentence(r, 'No screens in the last hour before bed', 'Screens as usual'),
        'On “No screens in the last hour before bed” days your time asleep was 44 min longer than on '
        '“Screens as usual” days (range +35 to +54 min): likely real for you.',
      );
    });

    test('a wide range around zero: not clear yet', () {
      final r = analyse(asleep, days(b28), order);
      expect(r.verdict, Verdict.notClear);
      expect(sentence(r, 'A', 'B'), 'On “A” days your time asleep was 9 min shorter than on “B” days (range −40 to +24 min): not clear yet.');
    });

    test('a range inside what matters (30 min of sleep): little or no effect', () {
      final r = analyse(asleep, days(c28), order);
      expect(r.verdict, Verdict.littleOrNone);
      expect(r.tested!.matters, 30);
      expect(sentence(r, 'A', 'B'), endsWith('(range −6 to +3 min): little or no effect for you.'));
    });

    test('under 5 days of a kind: too few, no range, the counts said', () {
      final r = analyse(asleep, days(a28, only: 8), order);
      expect(r.verdict, Verdict.tooFew);
      expect(r.tested!.low, isNull);
      expect(sentence(r, 'A', 'B'), 'Too few days to say: 4 days of “A” and 4 days of “B” have a number, and it takes 5 of each.');
      final none = analyse(asleep, const [], order);
      expect(none.tested, isNull);
      expect(sentence(none, 'A', 'B'), startsWith('Too few days to say: no day of each kind has a number yet'));
    });

    test('adherence: counted as assigned for the test, and by what was done beside it', () {
      // days 1 and 2 are "do" days (order 0110...): day 1 not kept, so by what was done it was a "don't" day
      final kept = {for (var i = 0; i < 28; i++) i: i != 1 && i != 3};
      kept.remove(27); // not answered
      final r = analyse(asleep, days(a28, kept: kept), order);
      expect(r.tested!.diff, closeTo(44.28571428571428, 1e-9), reason: 'the test ignores adherence');
      expect(r.adherence.days, 28);
      expect(r.adherence.answered, 27);
      expect(r.adherence.kept, 25);
      expect(r.adherence.answeredDo, 14);
      expect(r.adherence.keptDo, 13);
      // by hand: day 1 (442, do, not kept) counts as don't; day 3 (436, don't, not kept) counts as do; day 27 out
      final doV = <double>[], dontV = <double>[];
      for (var i = 0; i < 27; i++) {
        final did = (i == 1 || i == 3) ? !order[i] : order[i];
        (did ? doV : dontV).add(a28[i].toDouble());
      }
      double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
      expect(r.asDone!.diff, closeTo(mean(doV) - mean(dontV), 1e-9));
      expect(r.asDone!.nDo + r.asDone!.nDont, 27);
    });

    test('other numbers are plain differences, never tested', () {
      final d = [
        for (var i = 0; i < 28; i++)
          ExpDay(index: i, day: addDays('2026-11-20', i), doIt: order[i], values: {'asleep': a28[i].toDouble(), 'mood': order[i] ? 4 : 3}),
      ];
      final r = analyse(asleep, d, order);
      expect(r.others.map((s) => s.outcome.id), ['mood']);
      expect(r.others.single.diff, 1);
      expect(signed(r.others.single.outcome, r.others.single.diff), '+1.0 points');
    });

    test('ratios are judged on a log scale and worded in per cent; reaction time against the don\'t days', () {
      final alpha = outcomeById('alpha')!;
      final d = [
        for (var i = 0; i < 28; i++)
          ExpDay(index: i, day: addDays('2026-11-20', i), doIt: order[i], values: {'alpha': order[i] ? 30.0 : 20.0}),
      ];
      final r = analyse(alpha, d, order);
      expect(r.tested!.diff, closeTo(math.log(1.5), 1e-12));
      expect(sizeWords(alpha, r.tested!.diff), '50 % higher');
      expect(signed(alpha, -math.log(2)), '−50 %');
      final reaction = outcomeById('reaction')!;
      final rr = analyse(reaction, days(a28, id: 'reaction'), order);
      final dontMean = [for (var i = 0; i < 28; i++) if (!order[i]) a28[i]].reduce((a, b) => a + b) / 14;
      expect(rr.tested!.matters, closeTo(0.05 * dontMean, 1e-9));
      expect(sizeWords(reaction, 12.4), '12 ms slower');
      expect(sizeWords(outcomeById('kss')!, -0.64), '0.6 points lower');
      expect(sizeWords(outcomeById('iaf')!, 0.004), 'the same');
      expect(rangeWords(outcomeById('iaf')!, -0.123, 0.2), '−0.12 to +0.20 Hz');
    });

    test('every outcome is one of the trends\' numbers', () {
      for (final o in outcomes) {
        expect(o.spec.id, o.id);
        expect(o.matters, greaterThan(0));
      }
      for (final p in presets) {
        expect(outcomeById(p.outcome), isNotNull);
      }
    });
  });

  group('the plan, the days and when results open', () {
    late Directory tmp;
    late ExperimentStore store;
    final made = DateTime(2026, 11, 19, 14, 30);
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('exp');
      store = ExperimentStore(Directory('${tmp.path}/experiments'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ExperimentState create({int weeks = 4}) => store.create(
      preset: 'screens',
      doText: 'No screens in the last hour before bed',
      dontText: 'Screens as usual',
      outcome: outcomeById('asleep')!,
      weeks: weeks,
      now: made,
      random: math.Random(3),
    );

    test('the plan and its hash are saved before day 1; day 1 is tomorrow', () {
      final s = create();
      expect(s.plan.id, '2026-11-19-143000');
      expect(s.plan.start, '2026-11-20');
      expect(s.plan.days, 28);
      expect(s.plan.lastDay, '2026-12-17');
      expect(s.plan.unlocks, '2026-12-19');
      expect(s.phase, ExpPhase.waiting);
      expect(s.todayView, isNull);
      expect(s.planOk, isTrue);
      final dir = '${store.dir.path}/2026-11-19-143000';
      final plan = jsonDecode(File('$dir/plan.json').readAsStringSync()) as Map;
      final sealed = jsonDecode(File('$dir/sealed.json').readAsStringSync()) as Map;
      // the hashes, worked out here from the files alone
      String canon(Object? v) => jsonEncode(_sorted(v));
      expect(plan['sha256'], sha256Hex(canon(plan['plan'])));
      expect((plan['plan'] as Map)['allocationSha256'], sha256Hex(canon(sealed)));
      expect(((plan['plan'] as Map)['primary'] as Map)['id'], 'asleep');
      expect((sealed['allocation'] as String).length, 28);
      expect(File('$dir/events.jsonl').readAsStringSync(), contains('plan frozen'));
      expect(jsonEncode(plan), isNot(contains(sealed['salt'])), reason: 'the plan never holds the secret');
    });

    test('a plan or an order edited afterwards is noticed', () {
      create();
      final dir = '${store.dir.path}/2026-11-19-143000';
      final sealedFile = File('$dir/sealed.json');
      final sealed = jsonDecode(sealedFile.readAsStringSync()) as Map;
      final a = sealed['allocation'] as String;
      sealed['allocation'] = (a[0] == '1' ? '0' : '1') + a.substring(1);
      sealedFile.writeAsStringSync(jsonEncode(sealed));
      expect(store.load('2026-11-19-143000', made)!.planOk, isFalse);
      sealed['allocation'] = a;
      sealedFile.writeAsStringSync(jsonEncode(sealed));
      expect(store.load('2026-11-19-143000', made)!.planOk, isTrue);
      final planFile = File('$dir/plan.json');
      planFile.writeAsStringSync(planFile.readAsStringSync().replaceFirst('Screens as usual', 'Screens all night'));
      expect(store.load('2026-11-19-143000', made)!.planOk, isFalse);
    });

    test('a day shows its own task and the days before it, never the days ahead', () {
      create();
      final sealed = SealedOrder.fromJson(jsonDecode(File('${store.dir.path}/2026-11-19-143000/sealed.json').readAsStringSync()))!;
      // a day runs 04:00 to 04:00: 03:00 on the 21st is still day 1
      final d1 = store.load('2026-11-19-143000', DateTime(2026, 11, 21, 3))!;
      expect(d1.phase, ExpPhase.running);
      expect(d1.todayView!.index, 0);
      expect(d1.todayView!.doIt, sealed.order[0]);
      expect(d1.pastDays, isEmpty);
      expect(d1.orderForResults(), isNull, reason: 'the order stays sealed while it runs');
      final d9 = store.load('2026-11-19-143000', DateTime(2026, 11, 28, 12))!;
      expect(d9.todayView!.index, 8);
      expect([for (final d in d9.pastDays) d.doIt], sealed.order.sublist(0, 8));
      expect(d9.textFor(true), 'No screens in the last hour before bed');
    });

    test('results open only on the planned day: the day after the last number', () {
      create();
      ExperimentState at(int m, int d, [int h = 12]) => store.load('2026-11-19-143000', DateTime(2026, m, d, h))!;
      expect(at(12, 17).phase, ExpPhase.running);
      expect(at(12, 17).todayView!.index, 27);
      expect(at(12, 18).phase, ExpPhase.lastNumber);
      expect(at(12, 18).open, isFalse);
      expect(at(12, 18).todayView, isNull);
      expect(at(12, 19, 3).phase, ExpPhase.lastNumber, reason: 'before 04:00 it is still the 18th');
      expect(at(12, 19, 5).phase, ExpPhase.finished);
      expect(at(12, 19, 5).open, isTrue);
      expect(at(12, 19, 5).orderForResults()!.length, 28);
      expect(resultsFor(at(12, 10), const {}), isNull);
      expect(resultsFor(at(12, 19), const {})!.verdict, Verdict.tooFew);
    });

    test('the number of a day is the next day\'s', () {
      create();
      final s = store.load('2026-11-19-143000', DateTime(2026, 11, 23, 12))!;
      final d = s.analysisDays({
        'asleep': {'2026-11-20': 1, '2026-11-21': 2, '2026-11-22': 3, '2026-11-23': 4, '2026-11-24': 5},
        'mood': {'2026-11-22': 4},
      });
      expect([for (final x in d) x.day], ['2026-11-20', '2026-11-21', '2026-11-22']);
      expect([for (final x in d) x.values['asleep']], [2, 3, 4]);
      expect([for (final x in d) x.values['mood']], [null, 4, null]);
    });

    test('"did you keep to it?" is kept for past days only, can be corrected, and closes with the results', () {
      create();
      final day3 = DateTime(2026, 11, 22, 12);
      expect(store.load('2026-11-19-143000', day3)!.unanswered().map((d) => d.day), ['2026-11-21', '2026-11-20']);
      expect(store.answer('2026-11-19-143000', '2026-11-22', true, day3), isFalse, reason: 'today is not over');
      expect(store.answer('2026-11-19-143000', '2026-11-30', true, day3), isFalse);
      expect(store.answer('2026-11-19-143000', '2026-11-21', false, day3), isTrue);
      expect(store.answer('2026-11-19-143000', '2026-11-20', true, day3), isTrue);
      var s = store.load('2026-11-19-143000', day3)!;
      expect(s.unanswered(), isEmpty);
      expect(s.pastDays.map((d) => d.kept), [true, false]);
      expect(store.answer('2026-11-19-143000', '2026-11-21', true, day3), isTrue);
      s = store.load('2026-11-19-143000', day3)!;
      expect(s.pastDays.map((d) => d.kept), [true, true]);
      expect(store.answer('2026-11-19-143000', '2026-11-21', false, DateTime(2026, 12, 20)), isFalse);
      final log = File('${store.dir.path}/2026-11-19-143000/events.jsonl').readAsLinesSync();
      expect(log.where((l) => l.contains('"answer"')).length, 3);
    });

    test('an early look is marked for good and opens only what is over', () {
      create();
      final day9 = DateTime(2026, 11, 28, 12);
      var s = store.load('2026-11-19-143000', day9)!;
      expect(resultsFor(s, const {}), isNull);
      store.earlyLook('2026-11-19-143000', day9);
      s = store.load('2026-11-19-143000', day9)!;
      expect(s.progress.earlyLooks.single.daysDone, 8);
      expect(s.progress.earlyLooks.single.day, '2026-11-28');
      expect(s.open, isFalse);
      expect(resultsFor(s, const {}, early: true)!.days, 8);
      final end = store.load('2026-11-19-143000', DateTime(2026, 12, 20))!;
      expect(end.progress.earlyLooks.length, 1, reason: 'still shown at the planned end');
    });

    test('a stop keeps the days that are over and frees the slot; one experiment at a time', () {
      create();
      expect(create, throwsStateError);
      final day9 = DateTime(2026, 11, 28, 12);
      store.stop('2026-11-19-143000', day9);
      final s = store.load('2026-11-19-143000', DateTime(2026, 12, 5))!;
      expect(s.phase, ExpPhase.stopped);
      expect(s.open, isTrue);
      expect(s.assignedDays, 8);
      expect(s.pastDays.length, 8);
      expect(s.todayView, isNull);
      expect(store.active(day9), isNull);
      final next = store.create(preset: 'custom', doText: '  Cold  shower\n', dontText: 'As usual', outcome: outcomeById('kss')!, weeks: 6, now: day9, random: math.Random(4));
      expect(next.plan.doText, 'Cold shower');
      expect(next.plan.days, 42);
      expect(store.all(day9).map((e) => e.plan.id), ['2026-11-28-120000', '2026-11-19-143000']);
      expect(store.active(day9)!.plan.id, '2026-11-28-120000');
    });

    test('Export data takes the whole experiment folder, hidden order included (its rule is "everything except")', () {
      final files = Directory('${tmp.path}/files')..createSync();
      final st = ExperimentStore(experimentsDirFor('${files.path}/recordings'));
      st.create(preset: 'screens', doText: 'a', dontText: 'b', outcome: outcomeById('asleep')!, weeks: 4, now: made, random: math.Random(3));
      expect(st.dir.path, '${files.path}/experiments');
      expect([for (final f in storedFiles(files)) f.path], [
        'experiments/2026-11-19-143000/events.jsonl',
        'experiments/2026-11-19-143000/plan.json',
        'experiments/2026-11-19-143000/progress.json',
        'experiments/2026-11-19-143000/sealed.json',
      ]);
    });

    test('empty lines and odd lengths are refused; damaged files read as nothing', () {
      expect(() => store.create(preset: 'custom', doText: ' ', dontText: 'x', outcome: outcomeById('kss')!, weeks: 4, now: made), throwsArgumentError);
      expect(() => store.create(preset: 'custom', doText: 'x', dontText: 'y', outcome: outcomeById('kss')!, weeks: 3, now: made), throwsArgumentError);
      Directory('${store.dir.path}/2026-01-01-000000').createSync(recursive: true);
      File('${store.dir.path}/2026-01-01-000000/plan.json').writeAsStringSync('{');
      expect(store.all(made), isEmpty);
    });
  });
}

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}
