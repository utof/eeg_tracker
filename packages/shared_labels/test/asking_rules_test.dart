// The asking rules (docs/evidence/asking.md, DECISIONS 960-979) with a made-up clock: the words, blind cards, what is
// dropped unasked, the quiet hours from real sleep, the day's pushes, backing off, and the one "may I push now?".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

final day = DateTime(2026, 11, 20);
DateTime at(int h, [int m = 0, int s = 0]) => day.add(Duration(hours: h, minutes: m, seconds: s));

Estimate est(Label label, DateTime start, int minutes, {double? confidence, String? recording = 'rec'}) =>
    Estimate(detector: 'd', version: 'v', label: label, start: start, end: start.add(Duration(minutes: minutes)), confidence: confidence, recording: recording, made: start);

void main() {
  late Directory files;
  late ConfirmStore store;
  setUp(() {
    files = Directory.systemTemp.createTempSync('asking-rules');
    store = ConfirmStore(files);
  });
  tearDown(() => files.deleteSync(recursive: true));

  void line(Map<String, Object?> j) {
    store.dir.createSync(recursive: true);
    store.asksFile.writeAsStringSync('${jsonEncode(j)}\n', mode: FileMode.append);
  }

  /// A batch that went out at [when] with [ids].
  void push(DateTime when, List<String> ids) => line({'at': isoLocal(when), 'via': 'notification', 'estimates': ids});
  void dismiss(DateTime batch) => line({'at': isoLocal(batch.add(const Duration(minutes: 1))), 'event': 'dismissed', 'batch': isoLocal(batch)});

  group('the words', () {
    final nap = est(Labels.nap, at(15, 59), 110), walk = est(Labels.walking, at(19, 8), 126);
    test('the stretch first, the guess second as the headband\'s opinion, then the question', () {
      expect(questionOf(nap, at(18)), '15:59-17:49. The headband thinks you napped. Did you?');
      expect(questionOf(est(Labels.asleep, at(15, 59), 110), at(18)), '15:59-17:49. The headband thinks you slept. Did you?');
      expect(questionOf(walk, at(32)), 'Yesterday 19:08-21:14. The headband thinks you walked. Did you?');
      expect(questionOf(walk, at(24 * 3 + 8)), 'Fri 20 Nov 19:08-21:14. The headband thinks you walked. Did you?');
      expect(questionOf(est(Labels.headbandOff, at(10), 20), at(11)), '10:00-10:20. The headband thinks the headband was off. Was it?');
      expect(questionOf(est(Labels.soundSession, at(10), 20), at(11), who: 'The app'), '10:00-10:20. The app thinks this was "sound session". Was it?');
    });

    test('after the stretch\'s own day only "did it happen": the times to the half hour', () {
      expect(questionOf(walk, at(32), exact: false), 'Yesterday, about 19:00 to 21:00. The headband thinks you walked. Did you?');
      expect(blindQuestionOf(walk, at(32), exact: false), 'What were you doing yesterday, about 19:00 to 21:00?');
      expect(spanWords(est(Labels.walking, at(10, 50), 20), at(12), exact: false), 'about 11:00');
    });

    test('the buttons name the thing, for any label', () {
      ConfirmQuestion q(Label l) => ConfirmQuestion(est(l, at(10), 20), '', 'few');
      expect((q(Labels.asleep).yes, q(Labels.asleep).no), ('I slept', 'I was awake'));
      expect((q(Labels.walking).yes, q(Labels.walking).no), ('I walked', 'I did not walk'));
      expect((q(Labels.soundSession).yes, q(Labels.soundSession).no), ('Yes, it was', 'No, it was not'));
      for (final l in Labels.all) {
        expect([l.thinks, l.yesWord, l.noWord, l.asks, l.chip].every((w) => w.isNotEmpty), isTrue, reason: l.id);
        expect(l.yesWord, isNot(l.noWord), reason: l.id);
      }
    });
  });

  group('blind cards', () {
    test('1 card in 5, drawn from the estimate\'s id: the same every time, nothing rolled', () {
      final ids = [for (var i = 0; i < 2000; i++) est(Labels.walking, at(0, i), 20).id];
      final blind = ids.where(blindByDraw).toList();
      expect(blind.length / ids.length, closeTo(0.2, 0.03));
      expect(ids.where(blindByDraw).toList(), blind);
      expect(ids.where((i) => blindByDraw(i, seed: 'other')).toList(), isNot(blind));
      expect(ids.where((i) => blindByDraw(i, oneIn: 1)), hasLength(2000));
      expect(blindByDraw('est:512b2a6f9414dfb1'), blindByDraw('est:512b2a6f9414dfb1'));
    });

    test('the question and the chips never show the guess, and the chips are from the shared vocabulary', () {
      final walk = est(Labels.walking, at(19, 8), 126);
      expect(blindQuestionOf(walk, at(22)), 'What were you doing 19:08-21:14?');
      final chips = blindChips(walk);
      expect([for (final c in chips) c.id], ['asleep', 'walking', 'vehicle', 'eating', 'talking', 'working', 'exercise', 'resting']);
      expect(blindChips(est(Labels.asleep, at(1), 300)), chips, reason: 'the same chips whatever the guess');
      expect(blindChips(est(Labels.nap, at(15), 30)), chips, reason: 'a nap is the Sleeping chip');
      final cycle = blindChips(est(Labels.cycling, at(15), 30));
      expect(cycle, contains(Labels.cycling), reason: 'a guess that is not on the short list joins it');
      expect([for (final c in cycle) Labels.all.indexOf(c)], isSorted<num>(), reason: 'in the vocabulary\'s order: its place gives nothing away');
    });
  });

  group('dropped unasked', () {
    test('a stretch\'s times are asked about on its own day only (04:00 to 04:00)', () {
      final night = est(Labels.asleep, at(-1), 8 * 60 + 5); // 23:00 to 07:05
      expect(timesAsked(night, at(8)), isTrue);
      expect(timesAsked(night, at(27, 59)), isTrue);
      expect(timesAsked(night, at(28, 1)), isFalse);
      expect(timesAsked(est(Labels.walking, at(1), 30), at(8)), isFalse, reason: 'a walk at 01:00 belongs to yesterday');
    });

    test('older than 48 hours, and a short stretch older than 3 hours', () {
      final walk = est(Labels.walking, at(10), 30), doze = est(Labels.nap, at(10), 14), quarter = est(Labels.nap, at(11), 15);
      store.register([walk, doze, quarter]);
      var s = store.read();
      expect(closedWhy(doze, s, at(13, 13)), isNull);
      expect(closedWhy(doze, s, at(13, 15)), WhyNot.shortAndOld);
      expect(closedWhy(quarter, s, at(20)), isNull, reason: '15 minutes is not short');
      expect(closedWhy(walk, s, at(58, 30)), isNull);
      expect(closedWhy(walk, s, at(58, 31)), WhyNot.neverSeen);
      push(at(11), [walk.id]);
      s = store.read();
      expect(closedWhy(walk, s, at(58, 31)), WhyNot.expired);
      expect([for (final e in openEstimates(s, at(13, 15))) e.id], [walk.id, quarter.id], reason: 'the doze is not asked about');
      expect([for (final e in openEstimates(s, at(13, 15), recording: 'rec')) e.id], hasLength(3), reason: 'its own stop sheet still may');
    });

    test('more than 4 waiting: a notification takes the newest and the ones the detector is least sure of; every one stays on the card', () {
      final e = [
        est(Labels.walking, at(8), 30, confidence: 0.9),
        est(Labels.walking, at(9), 30, confidence: 0.4),
        est(Labels.walking, at(10), 30, confidence: 0.95),
        est(Labels.walking, at(11), 30, confidence: 0.6),
        est(Labels.walking, at(12), 30, confidence: 0.99),
        est(Labels.walking, at(13), 30, confidence: 0.97),
      ];
      store.register(e);
      final s = store.read();
      const settings = ConfirmSettings();
      final pushed = notificationBatch(s, settings, at(14));
      expect([for (final p in pushed) p.estimate.id], [e[1].id, e[3].id, e[4].id, e[5].id]);
      expect({for (final p in pushed) p.estimate.start.hour: p.why}, {9: 'unsure', 11: 'unsure', 12: 'newest', 13: 'newest'});
      final card = cardBatch(s, settings, at(14));
      expect([for (final p in card) p.estimate.id], [for (final x in e) x.id], reason: 'all six, in time order');
      expect({for (final p in card) p.estimate.start.hour: p.why}, containsPair(9, 'unsure'));
      // the two the notification had no room for are not closed: they are open, and they are not pushed later either
      expect([for (final x in e) closedWhy(x, s, at(14))], everyElement(isNull));
      push(at(14), [for (final p in pushed) p.estimate.id]);
      final after = store.read();
      expect(notificationBatch(after, settings, at(16)), isEmpty, reason: 'the extras are not pushed in a batch of their own');
      expect(cardBatch(after, settings, at(16)), hasLength(6));
      // they age out by the usual rules: 48 hours after the stretch ended (the 08:00 one ended 08:30)
      expect([for (final p in cardBatch(after, settings, at(24 * 2 + 8, 31))) p.estimate.id], [for (final x in e.skip(1)) x.id]);
      // answering one takes it off the card and a waiting one is still there
      store.answer(e[0].id, Answer.yes, at: at(14));
      expect(cardBatch(store.read(), settings, at(14)), hasLength(5));
    });

    test('switched off: nothing on the card, nothing pushed', () {
      store.register([est(Labels.walking, at(8), 30), est(Labels.walking, at(9), 30)]);
      const off = ConfirmSettings(on: false);
      expect(cardBatch(store.read(), off, at(14)), isEmpty);
      expect(notificationBatch(store.read(), off, at(14)), isEmpty);
    });
  });

  group('quiet hours', () {
    void nights(int n, {int bedH = 25, int bedM = 30, int wakeH = 33}) {
      store.register([
        for (var d = 1; d <= n; d++) est(Labels.asleep, at(bedH - 24 * d, bedM + d), (wakeH - bedH) * 60 - bedM, confidence: 0.9, recording: 'n$d'),
      ]);
    }

    test('follow your real sleep: usual bedtime until 30 minutes after you woke', () {
      nights(3); // to bed about 01:32, up 09:01-09:03, the last one this morning
      final s = store.read();
      const settings = ConfirmSettings();
      expect(sleepHabit(s, at(20)), (bedMin: 92, wakeMin: 9 * 60 + 2, nights: 3));
      expect(quietHours(s, settings, at(20)), (startMin: 92, endMin: 9 * 60 + 31, fromSleep: true), reason: 'this morning he woke at 09:01');
      expect(mayPush(at(24, 30), s, settings).ok, isTrue, reason: 'awake at 00:30: the fixed 22:00 would have kept quiet');
      final asleep = mayPush(at(26), s, settings);
      expect((asleep.ok, asleep.why), (false, 'quiet hours'));
      expect(asleep.retry, at(33, 32), reason: 'no waking seen yet: the usual 09:02 and half an hour');
    });

    test('too few nights, or your own override: the fixed hours', () {
      nights(2);
      const settings = ConfirmSettings();
      expect(sleepHabit(store.read(), at(20)), isNull);
      expect(quietHours(store.read(), settings, at(20)), (startMin: 22 * 60, endMin: 8 * 60, fromSleep: false));
      expect(mayPush(at(24, 30), store.read(), settings).retry, at(32));
      nights(5);
      const fixed = ConfirmSettings(quietFromSleep: false, quietStartMin: 23 * 60, quietEndMin: 7 * 60);
      expect(quietHours(store.read(), fixed, at(20)), (startMin: 23 * 60, endMin: 7 * 60, fromSleep: false));
    });

    test('a night you said was not sleep does not count, and neither does a nap', () {
      nights(3);
      store.register([est(Labels.nap, at(-10), 200)]);
      final first = store.read().estimates.values.first;
      store.answer(first.id, Answer.no, at: at(10));
      expect(sleepHabit(store.read(), at(20)), isNull);
    });
  });

  group('the day\'s pushes', () {
    const settings = ConfirmSettings(quietFromSleep: false);
    test('at most 2 batches a day: a third waits for tomorrow, and is on the card today', () {
      final e = [for (var h = 9; h < 12; h++) est(Labels.walking, at(h), 30)];
      store.register(e);
      push(at(10), [e[0].id]);
      push(at(12), [e[1].id]);
      final s = store.read();
      expect((settings.perDay, ConfirmRule.pushesPerDay, ConfirmRule.cardsPerBatch, settings.perBatch), (2, 2, 4, 4));
      final third = notificationBatch(s, settings, at(14));
      expect([for (final p in third) p.estimate.id], [e[2].id]);
      final answer = mayPush(at(14), s, settings);
      expect((answer.ok, answer.why, answer.retry), (false, 'today\'s pushes are used up', at(24)));
      expect(planTime(third, s, settings, at(14)), at(32), reason: 'tomorrow, after the quiet hours');
      expect(cardBatch(s, settings, at(14)), hasLength(3), reason: 'inside the app nothing is held back');
      expect(planTime(third, s, const ConfirmSettings(perDay: 1, quietFromSleep: false), at(11)), at(32));
    });

    test('an answer on the stop sheet never counts as a push', () {
      final walk = est(Labels.walking, at(9), 30);
      store.register([walk]);
      expect(recordingBatch(store.read(), 'rec', at(10)), hasLength(1));
      store.answer(walk.id, Answer.yes, via: AnswerVia.stopSheet, at: at(10));
      expect(store.read().batches, isEmpty);
      expect(mayPush(at(10, 5), store.read(), settings).ok, isTrue);
    });

    test('settings: 2 pushes and 4 cards by default; more than that falls back', () {
      expect(ConfirmSettings.fromJson({'per_day': 3, 'per_batch': 5}).perDay, 2);
      expect(ConfirmSettings.fromJson({'per_day': 3, 'per_batch': 5}).perBatch, 4);
      expect(ConfirmSettings.fromJson({'per_day': 1, 'per_batch': 2, 'quiet_from_sleep': false}).toJson(), containsPair('quiet_from_sleep', false));
    });
  });

  group('backing off', () {
    const settings = ConfirmSettings(quietFromSleep: false);
    final now = at(24 * 7 + 20); // a week later, 20:00

    /// One batch a day at 12:00 for the last [n] days; [answered] of them (the newest) got an answer.
    List<Estimate> week(int n, int answered, {int hour = 12}) {
      final e = [for (var d = n; d >= 1; d--) est(Labels.walking, at(24 * (7 - d) + hour - 1), 30, recording: 'w$d')];
      store.register(e);
      for (final (i, x) in e.indexed) {
        final when = x.end.add(const Duration(minutes: 30));
        push(when, [x.id]);
        if (i >= n - answered) store.answer(x.id, Answer.yes, at: when.add(const Duration(minutes: 2)), via: AnswerVia.notification);
      }
      return e;
    }

    test('half or more of the week\'s batches answered: 2 a day', () {
      week(4, 2);
      final b = backoffOf(store.read(), now);
      expect((b.perDay, b.rate, b.judged, b.step), (2, 0.5, 4, 'normal'));
    });

    test('under 50 %: 1 a day', () {
      week(4, 1);
      final b = backoffOf(store.read(), now);
      expect((b.perDay, b.rate, b.step, b.reason), (1, 0.25, 'one_a_day', '25 % of 4 batches answered in 7 days'));
      // one went out today: the second waits for tomorrow
      push(at(24 * 7 + 18), ['x']);
      expect(mayPush(now, store.read(), settings).why, 'today\'s pushes are used up');
    });

    test('under 25 %: no pushes for 7 days, then 1 a day again', () {
      week(5, 1);
      var b = backoffOf(store.read(), now);
      expect((b.perDay, b.startsPause, b.pausedUntil, b.step), (0, true, now.add(const Duration(days: 7)), 'pause'));
      store.logBackoff('pause', b.reason, at: now, until: b.pausedUntil);
      final later = now.add(const Duration(days: 3));
      b = backoffOf(store.read(), later);
      expect((b.perDay, b.startsPause, b.pausedUntil), (0, false, now.add(const Duration(days: 7))));
      final answer = mayPush(later, store.read(), settings);
      expect((answer.ok, answer.why, answer.retry), (false, 'paused', now.add(const Duration(days: 7))));
      store.register([est(Labels.walking, now.subtract(const Duration(hours: 2)), 30, recording: 'new')]);
      expect(cardBatch(store.read(), settings, now), hasLength(1), reason: 'the questions wait in the app');
      final after = now.add(const Duration(days: 7, minutes: 1));
      b = backoffOf(store.read(), after);
      expect((b.perDay, b.step, b.reason), (1, 'one_a_day', 'trying again after a pause'));
    });

    test('too few batches say nothing, and a fresh unanswered batch is not judged yet', () {
      week(3, 0);
      expect(backoffOf(store.read(), now).perDay, 2);
      push(now.subtract(const Duration(hours: 5)), ['x']);
      expect(backoffOf(store.read(), now).judged, 3);
      expect(backoffOf(store.read(), now.add(const Duration(hours: 2))).judged, 4);
    });

    test('2 batches in a row swiped away in the same hour: that hour is skipped for 7 days', () {
      final e = week(3, 0, hour: 14);
      dismiss(e[1].end.add(const Duration(minutes: 30)));
      dismiss(e[2].end.add(const Duration(minutes: 30)));
      final last = e[2].end.add(const Duration(minutes: 30)); // yesterday 14:00
      var b = backoffOf(store.read(), now);
      expect(b.skipHours, {14: last.add(const Duration(days: 7))});
      final tomorrow = at(24 * 8 + 14, 20);
      final answer = mayPush(tomorrow, store.read(), settings, backoff: backoffOf(store.read(), tomorrow));
      expect((answer.ok, answer.why, answer.retry), (false, 'this hour is skipped', at(24 * 8 + 15)));
      expect(backoffOf(store.read(), last.add(const Duration(days: 7, minutes: 1))).skipHours, isEmpty);
      // swiped away but then answered in the app is not a dismissal
      store.answer(e[2].id, Answer.no, at: now);
      b = backoffOf(store.read(), now);
      expect(b.skipHours, isEmpty);
    });

    test('10 batches in a row all Yes at under about a second a card: the next batch is blind', () {
      void batches(int n, {double seconds = 0.8, Answer second = Answer.yes, int from = 0}) {
        for (var i = from; i < from + n; i++) {
          final a = est(Labels.walking, at(i * 3), 30, recording: 'a$i'), b = est(Labels.nap, at(i * 3 + 1), 30, recording: 'b$i');
          store.register([a, b]);
          final when = at(i * 3 + 2);
          push(when, [a.id, b.id]);
          store.answer(a.id, Answer.yes, at: when.add(const Duration(minutes: 9)), shown: when, via: AnswerVia.notification);
          final t = when.add(const Duration(minutes: 9, milliseconds: 800));
          store.answer(b.id, second, at: t, shown: t.subtract(Duration(milliseconds: (seconds * 1000).round())), via: AnswerVia.notification);
        }
      }

      batches(9);
      expect(backoffOf(store.read(), now).blindNext, isFalse);
      batches(1, from: 9);
      expect(backoffOf(store.read(), now).blindNext, isTrue);
      // a batch with one answer cannot be timed: it neither counts nor breaks the run
      final lone = est(Labels.walking, at(40), 30, recording: 'lone');
      store.register([lone]);
      push(at(41), [lone.id]);
      store.answer(lone.id, Answer.no, at: at(41, 5));
      expect(backoffOf(store.read(), now).blindNext, isTrue);
      // one careful batch (three seconds on the second card) ends the run; so does a No
      batches(1, from: 20, seconds: 3);
      expect(backoffOf(store.read(), now).blindNext, isFalse);
      batches(9, from: 21);
      expect(backoffOf(store.read(), now).blindNext, isFalse);
      batches(1, from: 30);
      expect(backoffOf(store.read(), now).blindNext, isTrue);
      batches(1, from: 31, second: Answer.no);
      expect(backoffOf(store.read(), now).blindNext, isFalse);
    });

    test('a batch made blind by rule is remembered: its cards are blind wherever they show', () {
      final a = est(Labels.walking, at(9), 30);
      store.register([a]);
      store.saveArmed(Armed(at(10), [a.id], const {}, [a.id]));
      expect(store.read().forcedBlind, {a.id});
      store.settleArmed(at(10, 1));
      expect(store.read().forcedBlind, {a.id});
      expect(store.read().pushes.single.blind, [a.id]);
    });
  });

  group('may I push now?', () {
    const settings = ConfirmSettings(quietFromSleep: false);
    test('the one gate: yes at a free moment, and the other app can only make it wait', () {
      final walk = est(Labels.walking, at(9), 30);
      store.register([walk]);
      final s = store.read();
      expect(mayPush(at(10), s, settings).ok, isTrue);
      expect(mayPush(at(10), s, const ConfirmSettings(on: false)).retry, isNull);
      // the hook the link to utof_tracker will fill: "my check-in is at 10:20, come right after"
      DateTime? other(DateTime t) => t.isBefore(at(10, 22)) ? at(10, 22) : null;
      final held = mayPush(at(10), s, settings, other: other);
      expect((held.ok, held.why, held.retry), (false, 'the other app is asking', at(10, 22)));
      final batch = notificationBatch(s, settings, at(10));
      expect(planTime(batch, s, settings, at(10), other: other), at(10, 22));
      expect(planTime(batch, s, settings, at(10)), at(10));
      push(at(9, 50), ['x']);
      expect(mayPush(at(10), store.read(), settings).retry, at(10, 50), reason: 'an hour between batches');
    });
  });
}
