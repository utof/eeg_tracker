// "Someone else wore it" for a work session (DECISIONS rows 490-494): marked by hand on the end page or in the list of
// earlier sessions, kept in the session's own file (`wearer`: `answer`, `at`) the way a night's report keeps it, so
// the Trends numbers, the unusual card and the experiments leave the session out. Nothing is deleted.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/work_view.dart';
import 'package:eeg_tracker/wearer/check.dart' show answerMe, answerSomeoneElse;
import 'package:eeg_tracker/wearer/wearer.dart';
import 'package:eeg_tracker/work/controller.dart' show WorkStage;
import 'package:eeg_tracker/work/days.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _session(DateTime start) => {
  'version': workFormatVersion,
  'kind': 'work_session',
  'start': start.toIso8601String(),
  'end': start.add(const Duration(minutes: 90)).toIso8601String(),
  'ended': 'stopped',
  'worn_min': 85.0,
  'hints': [],
  'breaks': [],
  'ratings': [],
  'epochs': [
    for (var i = 0; i < 180; i++)
      {
        'at': start.add(Duration(seconds: 30 * i)).toIso8601String(),
        't': -0.4,
        's': 30 * i,
        'eyes_closed': false,
        'level': 'alert',
      },
  ],
};

WorkSummary _summary({String? answer}) => WorkSummary(
  start: DateTime(2026, 11, 19, 9, 5, 7),
  end: DateTime(2026, 11, 19, 10, 35, 7),
  wornMin: 85,
  hints: 0,
  breaks: 0,
  drowsyMin: 4,
  alertMin: 80,
  hintList: const [],
  wearerAnswer: answer,
);

void main() {
  group('the file', () {
    late Directory tmp;
    late String recordings;
    late WorkStore store;
    final start = DateTime(2026, 11, 19, 9, 5, 7);
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('work-wearer');
      recordings = '${tmp.path}/recordings';
      store = WorkStore(workDirFor(recordings))..save(_session(start));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, Object?> onDisk() => jsonDecode(
      File('${store.dir.path}/2026-11-19-090507.work.json').readAsStringSync(),
    ) as Map<String, Object?>;

    test('the list says who wore it, and the session has an id', () {
      expect(store.list().single.wearerAnswer, isNull);
      expect(store.list().single.id, '2026-11-19-090507');
      answerWearer(
        recordings,
        kindWork,
        '2026-11-19-090507',
        answerSomeoneElse,
        DateTime(2026, 11, 19, 11),
      );
      expect(store.list().single.wearerAnswer, answerSomeoneElse);
    });

    test('"someone else" is written like a night\'s answer and nothing else in the file changes', () {
      final before = onDisk();
      answerWearer(
        recordings,
        kindWork,
        '2026-11-19-090507',
        answerSomeoneElse,
        DateTime(2026, 11, 19, 11),
      );
      final after = onDisk();
      expect(after['wearer'], {
        'answer': answerSomeoneElse,
        'at': startsWith('2026-11-19T11:00:00'),
      });
      expect((after..remove('wearer')), before);
      expect(
        store.dir.listSync().map((f) => f.path),
        isNot(contains(endsWith('.tmp'))),
      );
      final events = File('${tmp.path}/wearer/events.jsonl')
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, Object?>);
      expect(events.last, containsPair('kind', kindWork));
      expect(events.last, containsPair('answer', answerSomeoneElse));
    });

    test('the Trends numbers leave a session marked "someone else" out, and take it back with Undo', () {
      expect(
        workDayNumbers([onDisk()])['worktime'],
        isNotNull,
        reason: '90 min of alert readings make a day',
      );
      answerWearer(
        recordings,
        kindWork,
        '2026-11-19-090507',
        answerSomeoneElse,
        DateTime(2026, 11, 19, 11),
      );
      expect(workDayNumbers([onDisk()])['worktime'], isEmpty);
      answerWearer(
        recordings,
        kindWork,
        '2026-11-19-090507',
        null,
        DateTime(2026, 11, 19, 11, 5),
      );
      expect(onDisk().containsKey('wearer'), isFalse);
      expect(workDayNumbers([onDisk()])['worktime'], isNotEmpty);
    });

    test('a session that is not there cannot be marked', () {
      expect(
        () => answerWearer(
          recordings,
          kindWork,
          '2026-01-01-000000',
          answerSomeoneElse,
          DateTime.now(),
        ),
        throwsStateError,
      );
    });
  });

  group('the words', () {
    test('open: the by-hand choice; answered: what it did, with Undo; the check switched off: nothing', () {
      final open = workWearerLine(null, on: true)!;
      expect(open.canSaySomeoneElse, isTrue);
      expect(open.canUndo, isFalse);
      final said = workWearerLine(answerSomeoneElse, on: true)!;
      expect(said.canUndo, isTrue);
      expect(said.text, contains('left out of your trends'));
      expect(workWearerLine(null, on: false), isNull);
      expect(
        workWearerLine(answerMe, on: true)!.canSaySomeoneElse,
        isTrue,
        reason: 'an old "me" answer does not hide the choice',
      );
    });
  });

  group('the page', () {
    Future<void> show(
      WidgetTester tester,
      WorkViewModel m,
      List<String> calls,
    ) async {
      tester.view.physicalSize = const Size(1210, 8000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: WorkView(model: m, onWearer: (s, a) => calls.add('${s.id} $a')),
        ),
      );
    }

    testWidgets(
      'the end page offers "Someone else wore it" and Undo reaches its callback',
      (tester) async {
        final calls = <String>[];
        await show(
          tester,
          WorkViewModel(
            stage: WorkStage.done,
            summary: _summary(),
            wearerOn: true,
          ),
          calls,
        );
        await tester.ensureVisible(find.text('Someone else wore it'));
        await tester.tap(find.text('Someone else wore it'));
        expect(calls, ['2026-11-19-090507 someone else']);
        calls.clear();
        await show(
          tester,
          WorkViewModel(
            stage: WorkStage.done,
            summary: _summary(answer: answerSomeoneElse),
            wearerOn: true,
          ),
          calls,
        );
        expect(
          find.textContaining('Someone else wore the headband'),
          findsOneWidget,
        );
        expect(find.text('Someone else wore it'), findsNothing);
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        expect(calls, ['2026-11-19-090507 null']);
      },
    );

    testWidgets(
      'earlier sessions: a quiet button on each, and a marked one says so',
      (tester) async {
        final calls = <String>[];
        final marked = WorkSummary(
          start: DateTime(2026, 11, 18, 14),
          end: DateTime(2026, 11, 18, 16),
          wornMin: 100,
          hints: 0,
          breaks: 0,
          drowsyMin: 0,
          alertMin: 90,
          hintList: const [],
          wearerAnswer: answerSomeoneElse,
        );
        await show(
          tester,
          WorkViewModel(
            stage: WorkStage.setup,
            sessions: [_summary(), marked],
            wearerOn: true,
          ),
          calls,
        );
        expect(find.text('Someone else wore it'), findsOneWidget);
        expect(
          find.textContaining('Someone else wore the headband'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Someone else wore it'));
        await tester.tap(find.text('Someone else wore it'));
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        expect(calls, [
          '2026-11-19-090507 someone else',
          '2026-11-18-140000 null',
        ]);
      },
    );

    testWidgets('with the check switched off the page has no such choice', (
      tester,
    ) async {
      await show(
        tester,
        WorkViewModel(stage: WorkStage.done, summary: _summary()),
        [],
      );
      expect(find.text('Someone else wore it'), findsNothing);
    });
  });
}
