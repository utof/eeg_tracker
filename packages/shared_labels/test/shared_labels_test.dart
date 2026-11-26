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
    expect(questionOf(e(Labels.walking), at), '19:08-21:14. The headband thinks you walked. Did you?');
    expect(questionOf(e(Labels.headbandOff), at), '19:08-21:14. The headband thinks the headband was off. Was it?');
    expect(questionOf(e(Labels.soundSession), at), '19:08-21:14. The headband thinks this was "sound session". Was it?');
  });

  test('the labels file made from the fixture is the golden file', () {
    final files = Directory.systemTemp.createTempSync('shared-labels');
    addTearDown(() => files.deleteSync(recursive: true));
    Directory('${files.path}/confirm').createSync();
    for (final n in ['estimates.jsonl', 'answers.jsonl']) {
      File('test/fixtures/confirm/$n').copySync('${files.path}/confirm/$n');
    }
    final state = ConfirmStore(files).read();
    expect(state.estimates, hasLength(16));
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
      store.notAnswered(walk.id, WhyNot.shortAndOld, at: at);
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

  group('a choice card: "Meditating or resting?" (eyes closed and still; DECISIONS 1105-1106)', () {
    late Directory files;
    late ConfirmStore store;
    final rest = Estimate(detector: restDetector, version: 'rest-v1', label: Labels.eyesClosed, start: DateTime(2026, 11, 20, 13, 5), end: DateTime(2026, 11, 20, 13, 12), confidence: 0.8, recording: 'rec');
    final walk = Estimate(detector: 'walking', version: 'w1', label: Labels.walking, start: DateTime(2026, 11, 20, 19, 8), end: DateTime(2026, 11, 20, 21, 14));
    final now = DateTime(2026, 11, 20, 14, 0);
    setUp(() {
      files = Directory.systemTemp.createTempSync('shared-labels-choice');
      store = ConfirmStore(files);
    });
    tearDown(() => files.deleteSync(recursive: true));
    Map<String, String> table(String tsv, List<String> columns, String id) =>
        Map.fromIterables(columns, tsv.split('\n').firstWhere((l) => l.contains(id)).split('\t'));

    test('which estimates get one, its words and its two chips', () {
      expect((isChoice(rest), isChoice(walk)), (true, false));
      expect(choiceQuestionOf(rest, now), '13:05-13:12. Your eyes were closed and you were still. Meditating or resting?');
      expect(
        choiceQuestionOf(rest, now.add(const Duration(days: 1)), exact: false),
        'Yesterday, about 13:00. Your eyes were closed and you were still. Meditating or resting?',
      );
      final q = ConfirmQuestion(rest, choiceQuestionOf(rest, now), 'newest', kind: CardKind.choice, guessText: questionOf(rest, now));
      expect(q.chips, [Labels.meditating, Labels.resting]);
      expect(CardKind.of('choice'), CardKind.choice);
    });

    test('the picked word becomes the label; the tables say it was a choice, and "agrees" is not counted', () {
      store.register([rest]);
      final at = DateTime(2026, 11, 20, 14, 0, 6);
      store.answer(rest.id, Answer.said, at: at, card: CardKind.choice, shown: now, estimate: rest, said: Labels.meditating);
      final state = store.read();
      expect(state.answers[rest.id]!.agrees(rest.label), isNull, reason: 'the detector guessed neither word');
      final row = table(estimatesTsv(state), estimateColumns, rest.id);
      expect((row['answer'], row['card'], row['label'], row['said'], row['agrees'], row['detector']), ('said', 'choice', 'eyes_closed', 'meditating', '', restDetector));
      final label = table(labelsTsv(state), labelColumns, 'confirm:${rest.id.substring(4)}');
      expect((label['label'], label['kind'], label['present'], label['times_confirmed'], label['owner_words']), ('meditating', 'activity', '1', '0', 'meditating'));
      expect(label['context'], 'the app asked to pick meditating or resting; eyes-closed-rest (rest-v1) said eyes_closed, confidence 0.80');
    });

    testWidgets('the card shows the two words, "Something else" and "Not sure"; never Yes and No', (t) async {
      t.view.physicalSize = const Size(393, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final said = <Label>[];
      final answers = <Answer>[];
      var words = 0;
      final q = ConfirmQuestion(rest, choiceQuestionOf(rest, now), 'newest', kind: CardKind.choice, guessText: questionOf(rest, now));
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfirmBatch(questions: [q], onAnswer: (_, a) => answers.add(a), onSaid: (_, l) => said.add(l), onWords: (_) => words++, onTimes: (_, _, _) {}),
          ),
        ),
      );
      expect(find.text('13:05-13:12. Your eyes were closed and you were still. Meditating or resting?'), findsOneWidget);
      for (final chip in ['Meditating', 'Resting', 'Something else', 'Not sure']) {
        expect(find.text(chip), findsOneWidget, reason: chip);
      }
      expect(find.text('Sleeping'), findsNothing, reason: 'not a blind card\'s long list');
      expect(find.text('Eyes closed'), findsNothing);
      expect(find.text('Yes, but the times are off'), findsNothing);
      await t.tap(find.text('Resting'));
      await t.tap(find.text('Something else'));
      await t.tap(find.text('Not sure'));
      expect(said, [Labels.resting]);
      expect((words, answers.single), (1, Answer.skip));
      expect(t.takeException(), isNull);
    });
  });

  group('the card', () {
    final nap = Estimate(detector: 'd', version: 'v', label: Labels.nap, start: DateTime(2026, 11, 20, 15, 59), end: DateTime(2026, 11, 20, 17, 49));
    final walk = Estimate(detector: 'd', version: 'v', label: Labels.walking, start: DateTime(2026, 11, 20, 19, 8), end: DateTime(2026, 11, 20, 21, 14));
    final now = DateTime(2026, 11, 20, 21, 40);
    ConfirmQuestion guess(Estimate e, {bool exact = true}) => ConfirmQuestion(e, questionOf(e, now, exact: exact), 'long', exactTimes: exact);
    ConfirmQuestion blind(Estimate e) => ConfirmQuestion(e, blindQuestionOf(e, now), 'long', kind: CardKind.blind, guessText: questionOf(e, now));
    Future<void> show(WidgetTester t, Widget child, {double width = 393}) async {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(24), child: child))));
    }

    testWidgets('names the stretch, then the guess; the buttons name the thing, in the same order every time', (t) async {
      final got = <Answer>[];
      await show(t, ConfirmCard(questions: [guess(nap), guess(walk)], onAnswer: (_, a) => got.add(a)));
      expect(find.text('Quick check'), findsOneWidget);
      expect(find.text('15:59-17:49. The headband thinks you napped. Did you?'), findsOneWidget);
      for (final words in [['I napped', 'I was awake'], ['I walked', 'I did not walk']]) {
        final x = [for (final w in words) t.getCenter(find.text(w)).dx];
        final unsure = t.getCenter(find.text('Not sure').at(words.first == 'I napped' ? 0 : 1)).dx;
        expect(x[0] < x[1] && x[1] < unsure, isTrue, reason: 'yes, no, not sure, left to right');
      }
      expect(find.text('Yes'), findsNothing);
      expect(find.byType(Slider), findsNothing, reason: 'no confidence slider');
      await t.tap(find.text('Not sure').first);
      await t.tap(find.text('I napped'));
      await t.tap(find.text('I did not walk'));
      expect(got, [Answer.skip, Answer.yes, Answer.no]);
      expect(t.getSize(find.widgetWithText(OutlinedButton, 'I walked')).height, greaterThanOrEqualTo(48));
      expect(find.text('Yes, but the times are off'), findsNothing, reason: 'only a screen that can save times offers it');
      expect(t.takeException(), isNull);
    });

    testWidgets('fits a narrow phone', (t) async {
      final ride = Estimate(detector: 'd', version: 'v', label: Labels.vehicle, start: nap.start, end: nap.end);
      await show(t, ConfirmCard(questions: [guess(walk), guess(ride), blind(nap)], onAnswer: (_, _) {}, onSaid: (_, _) {}, onWords: (_) {}, onTimes: (_, _, _) {}), width: 320);
      expect(t.takeException(), isNull);
      expect(find.text('I did not ride'), findsOneWidget);
    });

    testWidgets('"Yes, but the times are off" opens the stretch on a strip; both ends move; saving gives your times', (t) async {
      final got = <(DateTime, DateTime)>[];
      final other = Estimate(detector: 'd', version: 'v', label: Labels.nap, start: DateTime(2026, 11, 20, 18, 45), end: DateTime(2026, 11, 20, 19, 0));
      await show(t, ConfirmBatch(questions: [guess(walk)], onAnswer: (_, _) {}, onTimes: (_, s, e) => got.add((s, e)), around: [other, walk], now: now));
      await t.tap(find.text('Yes, but the times are off'));
      await t.pumpAndSettle();
      expect(find.text('Walking: set the times'), findsOneWidget);
      expect(find.text('Start 19:08'), findsOneWidget);
      expect(find.text('End 21:14'), findsOneWidget);
      expect(find.text('Also found: napping 18:45-19:00'), findsOneWidget, reason: 'what came before is on the strip');
      expect(find.text('18:36'), findsOneWidget, reason: 'the strip starts a quarter of the stretch earlier');
      expect(find.text('21:40'), findsOneWidget, reason: 'and cannot go past now');
      await t.tap(find.byKey(const ValueKey('times-start-later')));
      await t.tap(find.byKey(const ValueKey('times-start-later')));
      await t.tap(find.byKey(const ValueKey('times-end-earlier')));
      await t.pump();
      expect(find.text('Start 19:18'), findsOneWidget);
      expect(find.text('End 21:09'), findsOneWidget);
      // dragging the end's handle to the right moves it later, and it stops at now
      await t.drag(find.byKey(const ValueKey('times-handle-end')), const Offset(400, 0));
      await t.pump();
      expect(find.text('End 21:40'), findsOneWidget);
      await t.drag(find.byKey(const ValueKey('times-handle-start')), const Offset(-30, 0));
      await t.pump();
      final start = t.widget<Text>(find.byKey(const ValueKey('times-start'))).data!;
      expect(start.compareTo('Start 19:18') < 0, isTrue, reason: 'dragged left: earlier ($start)');
      // the start cannot pass the end
      for (var i = 0; i < 40; i++) {
        await t.tap(find.byKey(const ValueKey('times-start-later')));
      }
      await t.pump();
      expect(find.text('Start 21:39'), findsOneWidget);
      await t.tap(find.text('Save these times'));
      await t.pumpAndSettle();
      expect(got, [(DateTime(2026, 11, 20, 21, 39), DateTime(2026, 11, 20, 21, 40))]);
      expect(find.text('Walking: set the times'), findsNothing);
    });

    testWidgets('times left as they are and saved count as seen; Cancel saves nothing; no link once the day is over', (t) async {
      final got = <(DateTime, DateTime)>[];
      await show(t, ConfirmBatch(questions: [guess(walk)], onAnswer: (_, _) {}, onTimes: (_, s, e) => got.add((s, e)), now: now));
      await t.tap(find.text('Yes, but the times are off'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(got, isEmpty);
      await t.tap(find.text('Yes, but the times are off'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save these times'));
      await t.pumpAndSettle();
      expect(got, [(walk.start, walk.end)]);
      await show(t, ConfirmBatch(questions: [guess(walk, exact: false)], onAnswer: (_, _) {}, onTimes: (_, _, _) {}));
      expect(find.text('About 19:00 to 21:00. The headband thinks you walked. Did you?'), findsOneWidget);
      expect(find.text('Yes, but the times are off'), findsNothing);
    });

    testWidgets('a blind card asks what you were doing and never shows the guess', (t) async {
      final said = <Label>[];
      final answers = <Answer>[];
      var words = 0;
      await show(t, ConfirmBatch(questions: [blind(walk)], onAnswer: (_, a) => answers.add(a), onSaid: (_, l) => said.add(l), onWords: (_) => words++, onTimes: (_, _, _) {}));
      expect(find.text('What were you doing 19:08-21:14?'), findsOneWidget);
      expect(find.textContaining('thinks'), findsNothing);
      expect(find.text('I walked'), findsNothing);
      expect(find.text('Yes, but the times are off'), findsNothing);
      for (final chip in ['Sleeping', 'Walking', 'Working', 'Eating', 'Resting', 'Something else', 'Not sure']) {
        expect(find.text(chip), findsOneWidget, reason: chip);
      }
      await t.tap(find.text('Working'));
      await t.tap(find.text('Something else'));
      await t.tap(find.text('Not sure'));
      expect(said, [Labels.working]);
      expect((words, answers.single), (1, Answer.skip));
      // answered: what you said is shown, still not the guess
      await show(t, ConfirmBatch(questions: [blind(walk)], onAnswer: (_, _) {}, onSaid: (_, _) {}, answers: {walk.id: Answer.said}, saved: {walk.id: 'Working'}));
      expect(find.text('Saved: Working'), findsOneWidget);
      // a screen that cannot take a blind answer shows the guess instead
      await show(t, ConfirmBatch(questions: [blind(walk)], onAnswer: (_, _) {}));
      expect(find.text('19:08-21:14. The headband thinks you walked. Did you?'), findsOneWidget);
    });
  });

  test('the stop sheet: every chip is a vocabulary label; a tap, the confidences and the tags', () {
    for (final c in stopChips) {
      expect(Label.of(c.label), isNotNull, reason: c.word);
    }
    expect(tapStopChip({'night_sleep', 'walking'}, 'awake'), {'walking', 'awake'});
    expect(tapStopChip({'awake'}, 'nap'), {'nap'});
    final start = DateTime(2026, 11, 21, 11, 2), end = DateTime(2026, 11, 21, 19, 40);
    final tags = stopSheetTags(
      start: start,
      end: end,
      picks: [const StopPick('awake'), StopPick('walking', start: DateTime(2026, 11, 21, 17), end: DateTime(2026, 11, 21, 17, 40)), const StopPick('eating')],
      words: 'a "b"\tc',
      made: end,
    );
    expect([for (final t in tags) t['confidence']], ['certain', 'likely', 'within']);
    expect(tags.every((t) => t['source'] == 'owner_stop_sheet' && t['truth'] == true && t['words'] == 'a "b"\tc'), isTrue);
    expect(tags[1]['start'], isoLocal(DateTime(2026, 11, 21, 17)));
    expect(tags[2]['end'], isoLocal(end));
    expect(stopSheetTags(start: start, end: end, picks: const [], made: end), isEmpty);
  });
}
