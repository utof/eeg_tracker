// The shared labels package by itself: the vocabulary, the golden label export, the who-asks seam and the batch widget.
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
    expect(state.estimates, hasLength(7));
    expect(labelsTsv(state), File('test/fixtures/confirm/labels.tsv').readAsStringSync());
    final head = File('test/fixtures/confirm/labels.tsv').readAsLinesSync().first.split('\t');
    expect(head, labelColumns);
  });

  test('who asks: the app itself; the utof route is a stub that is never linked', () async {
    final e = [Estimate(detector: 'd', version: 'v', label: Labels.nap, start: DateTime(2026, 11, 20, 15), end: DateTime(2026, 11, 20, 16))];
    const AskRouter self = SelfAskRouter(), utof = UtofAskRouter();
    expect(await self.offer(e, DateTime(2026, 11, 20, 17)), AskDecision.askHere);
    expect((utof.name, await utof.linked(), const UtofAskRouter().why), ('utof', false, 'not linked'));
    expect(await utof.offer(e, DateTime(2026, 11, 20, 17)), AskDecision.askHere);
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
