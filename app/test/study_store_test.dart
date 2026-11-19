// The study reminders on disk (DECISIONS rows 400-401): settings, the one-tap answers, the day numbers.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/study/schedule.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late StudyStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('study');
    store = StudyStore(studyDirFor('${tmp.path}/recordings'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the folder sits beside the recordings, like the sharp-hours one', () {
    expect(studyDirFor('/data/files/recordings').path, '/data/files/study-review');
  });

  test('settings: nothing before the first save, then what was saved; a half-written file is ignored', () {
    expect(store.settings(), isNull);
    store.saveSettings(StudySettings(on: true, eveningMin: 1230, changed: DateTime(2026, 11, 20, 9)));
    final s = store.settings()!;
    expect((s.on, s.eveningMin, s.morningMin), (true, 1230, null));
    expect(Directory(store.dir.path).listSync().map((f) => f.path.split('/').last), [
      'settings.json',
    ], reason: 'no .tmp left');
    File('${store.dir.path}/settings.json').writeAsStringSync('{"version": 1, "on"');
    expect(store.settings(), isNull);
  });

  test('answers: both kinds, in the order given; their local time keeps its offset', () {
    final at = DateTime(2026, 11, 20, 21, 40);
    store
      ..addAnswer(
        StudyAnswer.evening(
          at: at,
          studied: true,
          prompt: DateTime(2026, 11, 20, 21, 30),
          shown: DateTime(2026, 11, 20, 21, 31),
        ),
      )
      ..addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 8, 5), recall: Recall.some));
    final a = store.answers();
    expect(a.length, 2);
    expect(a[0].isEvening, isTrue);
    expect(a[0].studied, isTrue);
    expect(a[0].at, at);
    expect(a[0].prompt, DateTime(2026, 11, 20, 21, 30));
    expect(a[0].shown, DateTime(2026, 11, 20, 21, 31));
    expect(a[1].recall, Recall.some);
    expect(a[1].prompt, isNull, reason: 'logged from the page');
    final raw = File('${store.dir.path}/log.jsonl').readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
    expect(raw[0]['kind'], 'evening');
    expect(raw[0]['studied'], true);
    expect(raw[0]['at'], matches(RegExp(r'^2026-11-20T21:40:00[+-]\d\d:\d\d$')));
    expect(raw[1]['kind'], 'morning');
    expect(raw[1]['recall'], 'some');
    expect(raw[1].containsKey('studied'), isFalse);
  });

  test('a line that is cut off, foreign or wrong is skipped, the others are kept', () {
    store.addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 8), recall: Recall.well));
    File('${store.dir.path}/log.jsonl').writeAsStringSync(
      [
        '{"version":1,"at":"2026-11-21T08:00:00+03:00","kind":"morning","recall":"great"}',
        '{"version":1,"at":"2026-11-21T08:00:00+03:00","kind":"evening","studied":"yes"}',
        '{"version":1,"at":"2026-11-21T08:00:00+03:00","kind":"evening","studied":false}',
        '{"version":1,"at":"2026-11-21T08:0',
        '',
      ].join('\n'),
      mode: FileMode.append,
    );
    final a = store.answers();
    expect(a.length, 2);
    expect(a.map((x) => x.kind.name), ['studyMorning', 'studyEvening']);
  });

  test('day numbers: recall 1 little, 2 some, 3 well, the mean of the day (04:00 to 04:00); evenings give none', () {
    store
      ..addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 8), recall: Recall.well))
      ..addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 12), recall: Recall.some))
      ..addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 22, 8), recall: Recall.little))
      ..addAnswer(StudyAnswer.evening(at: DateTime(2026, 11, 21, 21), studied: true));
    expect(studyDayNumbers(store.answers()), {
      'recall': {'2026-11-21': 2.5, '2026-11-22': 1.0},
    });
    expect(studyDayNumbers(const []), {'recall': <String, double>{}});
  });

  test('delete removes the folder', () {
    store.addAnswer(StudyAnswer.morning(at: DateTime(2026, 11, 21, 8), recall: Recall.well));
    store.deleteAll();
    expect(store.dir.existsSync(), isFalse);
    expect(store.answers(), isEmpty);
  });
}
