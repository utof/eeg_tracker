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
    expect(state.estimates, hasLength(7));
    expect(labelsTsv(state), File('test/fixtures/confirm/labels.tsv').readAsStringSync());
    expect(estimatesTsv(state), File('test/fixtures/confirm/estimates.tsv').readAsStringSync());
    expect((tsvNumber(0.9), tsvNumber(0.555), tsvNumber(1), tsvNumber(0.12345)), ('0.9', '0.555', '1', '0.123'));
    final head = File('test/fixtures/confirm/labels.tsv').readAsLinesSync().first.split('\t');
    expect(head, labelColumns);
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
