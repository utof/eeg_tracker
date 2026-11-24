// The shared labels package by itself: the vocabulary, the golden exports (labels and estimates) and the batch
// widget.
// The app's tests (app/test/confirm_test.dart) cover the queue, the timing and the files through eeg_tracker's door.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

void main() {
  test('the vocabulary: labels by id and by a typed word; sleep and a nap are one question', () {
    expect(Labels.all.length, greaterThanOrEqualTo(36));
    expect(Label.of('walking'), same(Labels.walking));
    expect(Label.of('juggling'), isNull);
    expect(Label.named(' Walk '), same(Labels.walking));
    expect(Label.named('eyes closed'), same(Labels.eyesClosed));
    expect(Labels.nap.says('sleep'), isTrue);
    expect(Labels.asleep.sameAs(Labels.nap), isTrue);
    expect(Labels.walking.says('work'), isFalse);
    expect((Labels.kss.unit, Labels.kss.kind), ('1-9', 'rating'));
    expect(labelSources.keys, containsAll(['owner_app_prompt', 'owner_stop_sheet', 'owner_app_tag']));
    expect(labelConfidences.keys, containsAll(['certain', 'likely']));
    expect(labelKinds.keys, contains('activity'));
    for (final l in Labels.all) {
      expect(labelKinds.containsKey(l.kind), isTrue, reason: l.id);
    }
  });

  test('every label can be asked about, in plain words', () {
    final at = DateTime(2026, 11, 20, 22);
    Estimate e(Label l) => Estimate(detector: 'd', version: 'v', label: l, start: DateTime(2026, 11, 20, 19, 8), end: DateTime(2026, 11, 20, 21, 14));
    expect(questionOf(e(Labels.walking), at), 'Did you walk 19:08-21:14?');
    expect(questionOf(e(Labels.headbandOff), at), 'Was the headband off 19:08-21:14?');
    expect(questionOf(e(Labels.soundSession), at), 'Was this "sound session" 19:08-21:14?');
  });

  test('the labels file made from the fixture is the golden file', () {
    final files = Directory.systemTemp.createTempSync('shared-labels');
    addTearDown(() => files.deleteSync(recursive: true));
    Directory('${files.path}/confirm').createSync();
    for (final n in ['estimates.jsonl', 'answers.jsonl']) {
      File('test/fixtures/confirm/$n').copySync('${files.path}/confirm/$n');
    }
    final state = ConfirmStore(files).read();
    expect(state.estimates, hasLength(15));
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      File('test/fixtures/confirm/labels.tsv').writeAsStringSync(labelsTsv(state));
      File('test/fixtures/confirm/estimates.tsv').writeAsStringSync(estimatesTsv(state));
    }
    expect(labelsTsv(state), File('test/fixtures/confirm/labels.tsv').readAsStringSync());
    expect(estimatesTsv(state), File('test/fixtures/confirm/estimates.tsv').readAsStringSync());
    expect((tsvNumber(0.9), tsvNumber(0.555), tsvNumber(1), tsvNumber(0.12345)), ('0.9', '0.555', '1', '0.123'));
    final head = File('test/fixtures/confirm/labels.tsv').readAsLinesSync().first.split('\t');
    expect(head, labelColumns);
  });

  group('what an answer means (asking.md)', () {
    late Directory files;
    late ConfirmStore store;
    final walk = Estimate(detector: 'walking', version: 'w1', label: Labels.walking, start: DateTime(2026, 11, 20, 19, 8), end: DateTime(2026, 11, 20, 21, 14), confidence: 0.7, recording: 'rec');
    final nap = Estimate(detector: 'sleep-periods', version: 's1', label: Labels.nap, start: DateTime(2026, 11, 20, 15, 59), end: DateTime(2026, 11, 20, 17, 49), confidence: 0.9);
    final shown = DateTime(2026, 11, 20, 21, 30), at = DateTime(2026, 11, 20, 21, 30, 4, 260);
    setUp(() {
      files = Directory.systemTemp.createTempSync('shared-labels-answers');
      store = ConfirmStore(files)..register([walk, nap]);
    });
    tearDown(() => files.deleteSync(recursive: true));
    Map<String, String> table(String tsv, List<String> columns, String id) =>
        Map.fromIterables(columns, tsv.split('\n').firstWhere((l) => l.contains(id)).split('\t'));

    test('a plain Yes says it happened, not that the times are right', () {
      store.answer(walk.id, Answer.yes, at: at, card: CardKind.normal, shown: shown, estimate: walk);
      final a = store.read().answers[walk.id]!;
      expect((a.timesConfirmed, a.start, a.end), (false, null, null));
      final label = table(labelsTsv(store.read()), labelColumns, 'confirm:');
      expect((label['times_confirmed'], label['confidence'], label['present']), ('0', 'likely', '1'));
      expect(label['start'], '2026-11-20T19:08:00+03:00', reason: 'still the detector\'s times');
      expect(table(estimatesTsv(store.read()), estimateColumns, walk.id)['times_confirmed'], '0');
    });

    test('"Yes, but the times are off" stores your times as confirmed', () {
      store.answer(walk.id, Answer.yes, at: at, card: CardKind.normal, shown: shown, estimate: walk, start: DateTime(2026, 11, 20, 19, 20), end: DateTime(2026, 11, 20, 21));
      final a = store.read().answers[walk.id]!;
      expect((a.timesConfirmed, a.start, a.end), (true, DateTime(2026, 11, 20, 19, 20), DateTime(2026, 11, 20, 21)));
      final label = table(labelsTsv(store.read()), labelColumns, 'confirm:');
      expect((label['times_confirmed'], label['confidence'], label['start'], label['end']), ('1', 'certain', '2026-11-20T19:20:00+03:00', '2026-11-20T21:00:00+03:00'));
      final row = table(estimatesTsv(store.read()), estimateColumns, walk.id);
      expect((row['start'], row['confirmed_start'], row['confirmed_end']), ('2026-11-20T19:08:00+03:00', '2026-11-20T19:20:00+03:00', '2026-11-20T21:00:00+03:00'));
      // an end before the start is not a correction: a plain Yes
      store.answer(nap.id, Answer.yes, at: at, start: DateTime(2026, 11, 20, 17), end: DateTime(2026, 11, 20, 16));
      expect(store.read().answers[nap.id]!.timesConfirmed, isFalse);
    });

    test('Not sure is its own answer: stored, no label, not asked again', () {
      store.answer(walk.id, Answer.skip, at: at, card: CardKind.normal, shown: shown, estimate: walk);
      expect(store.answersFile.readAsStringSync(), contains('"answer":"not_sure"'));
      final state = store.read();
      expect(state.answers[walk.id]!.answer, Answer.skip);
      expect(labelsTsv(state).trim().split('\n'), hasLength(1), reason: 'no label row: nothing that scores a detector sees it');
      expect(state.labelsOf(Labels.walking), 0);
      final row = table(estimatesTsv(state), estimateColumns, walk.id);
      expect((row['answer'], row['label_id'], row['times_confirmed']), ('not_sure', '', ''));
      expect([for (final e in openEstimates(state, DateTime(2026, 11, 20, 22))) e.id], [nap.id]);
    });

    test('no answer is stored apart from every answer and is never a Yes or a No', () {
      final now = DateTime(2026, 11, 20, 22);
      store.notAnswered(walk.id, WhyNot.dismissed, via: AnswerVia.notification, at: at);
      var state = store.read();
      expect((state.answered(walk.id), state.closed(walk.id), state.unanswered[walk.id]!.why), (false, false, WhyNot.dismissed));
      expect(labelsTsv(state).trim().split('\n'), hasLength(1));
      var row = table(estimatesTsv(state), estimateColumns, walk.id);
      expect((row['answer'], row['why_not'], row['via'], row['label_id']), ('not_answered', 'dismissed', 'notification', ''));
      expect(openEstimates(state, now).map((e) => e.id), contains(walk.id), reason: 'a swiped notification leaves it on the card');
      store.notAnswered(walk.id, WhyNot.tooMany, at: at);
      state = store.read();
      expect(state.closed(walk.id), isTrue);
      expect(openEstimates(state, now).map((e) => e.id), isNot(contains(walk.id)));
      expect(openEstimates(state, now, recording: 'rec').map((e) => e.id), [walk.id], reason: 'its own recording\'s stop sheet may still ask');
      // a real answer given later stands
      store.answer(walk.id, Answer.no, at: now, via: AnswerVia.stopSheet);
      state = store.read();
      row = table(estimatesTsv(state), estimateColumns, walk.id);
      expect((state.closed(walk.id), row['answer'], row['why_not']), (false, 'no', ''));
    });

    test('a card stores what it was: the guess, how sure, blind or not, the seconds, the age, where', () {
      store.answer(walk.id, Answer.no, via: AnswerVia.notification, at: at, card: CardKind.normal, shown: shown, estimate: walk);
      final line = store.answersFile.readAsLinesSync().single;
      expect(line, '{"estimate_id":"${walk.id}","answer":"no","at":"2026-11-20T21:30:04+03:00","via":"notification","card":"normal","guess":"walking","confidence":0.7,"shown":"2026-11-20T21:30:00+03:00","seconds":4.3,"age_min":16}');
      final a = store.read().answers[walk.id]!;
      expect((a.card, a.guess, a.guessConfidence, a.seconds, a.ageMin, a.via), (CardKind.normal, 'walking', 0.7, 4.3, 16, 'notification'));
      final row = table(estimatesTsv(store.read()), estimateColumns, walk.id);
      expect((row['card'], row['seconds_to_answer'], row['age_min'], row['shown'], row['via']), ('normal', '4.3', '16', '2026-11-20T21:30:00+03:00', 'notification'));
    });

    test('a blind card stores what you said; whether it agrees with the guess is worked out from it', () {
      store.answer(walk.id, Answer.said, at: at, card: CardKind.blind, shown: shown, estimate: walk, said: Labels.walking);
      store.answer(nap.id, Answer.said, at: at, card: CardKind.blind, shown: shown, estimate: nap, said: Labels.working, words: 'at my desk');
      final state = store.read();
      expect((state.answers[walk.id]!.agrees(walk.label), state.answers[nap.id]!.agrees(nap.label)), (true, false));
      final w = table(estimatesTsv(state), estimateColumns, walk.id), n = table(estimatesTsv(state), estimateColumns, nap.id);
      expect((w['answer'], w['card'], w['label'], w['said'], w['agrees']), ('said', 'blind', 'walking', 'walking', '1'));
      expect((n['label'], n['said'], n['agrees'], n['owner_words']), ('nap', 'working', '0', 'at my desk'));
      final label = table(labelsTsv(state), labelColumns, 'confirm:${nap.id.substring(4)}');
      expect((label['label'], label['kind'], label['present'], label['times_confirmed'], label['owner_words']), ('working', 'activity', '1', '0', 'at my desk'));
      expect(label['context'], 'the app asked without showing its guess; sleep-periods (s1) said nap, confidence 0.90');
    });
  });

  testWidgets('the batch works in any theme: three buttons a question, a tap answers', (t) async {
    final nap = Estimate(detector: 'd', version: 'v', label: Labels.nap, start: DateTime(2026, 11, 20, 15, 59), end: DateTime(2026, 11, 20, 17, 49));
    final got = <Answer>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConfirmCard(questions: [ConfirmQuestion(nap, questionOf(nap, DateTime(2026, 11, 20, 18)), 'long')], onAnswer: (_, a) => got.add(a)),
        ),
      ),
    );
    expect(find.text('Quick check'), findsOneWidget);
    expect(find.text('Did you nap 15:59-17:49?'), findsOneWidget);
    await t.tap(find.text('Not sure'));
    await t.tap(find.text('Yes'));
    expect(got, [Answer.skip, Answer.yes]);
    expect(t.takeException(), isNull);
  });
}
