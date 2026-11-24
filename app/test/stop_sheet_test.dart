// The sheet after Stop (Record first, DECISIONS 890-891, 908-910; spec tests 8 and 11): each chip's tag, the times,
// the verbatim words, Skip, the skip-by-itself rule, the confirm questions it settles, and the same tag fields as the
// golden file the laptop's truth.py reads (tests/contract/labels/stop-sheet.tags.json).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/stop_sheet.dart';
import 'package:eeg_tracker/ui/stop_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

void main() {
  late Directory files;
  const id = '2026-11-21-110200';
  final start = DateTime.parse('2026-11-21T11:02:00+03:00').toLocal(), end = DateTime.parse('2026-11-21T19:40:00+03:00').toLocal();
  final plan = StopSheetPlan(recording: id, start: start, end: end);
  const words = 'Felt "good"\tthen tired';

  setUp(() => files = Directory.systemTemp.createTempSync('stop_sheet_test'));
  tearDown(() => files.deleteSync(recursive: true));

  test('the sheet makes the golden file\'s tags: label, times, source, confidence and the words as typed', () {
    final golden = jsonDecode(File('../tests/contract/labels/stop-sheet.tags.json').readAsStringSync()) as Map;
    final walkFrom = DateTime.parse('2026-11-21T17:00:00+03:00'), walkTo = DateTime.parse('2026-11-21T17:40:00+03:00');
    final made = stopSheetTags(
      start: start,
      end: end,
      picks: [const StopPick('awake'), StopPick('walking', start: walkFrom, end: walkTo), const StopPick('eating'), const StopPick('other')],
      words: words,
      made: end,
    );
    Map<String, Object?> fields(Map<Object?, Object?> t) => {
      for (final k in const ['label', 'truth', 'source', 'confidence', 'words']) k: t[k],
      'start': DateTime.parse(t['start'] as String).toUtc(),
      'end': DateTime.parse(t['end'] as String).toUtc(),
    };
    expect([for (final t in made) fields(t)], [for (final t in golden['tags'] as List) fields(t as Map)]);
    // and they survive the Archive's tags file, which rewrites it whole
    expect(saveStopSheet(files, plan, picks: [const StopPick('eating')], words: words, made: end), isTrue);
    final store = TagStore(files);
    final tag = store.tags(id).single;
    expect((tag.label, tag.source, tag.confidence, tag.words, tag.truth), ('eating', 'owner_stop_sheet', 'within', words, true));
    expect(store.add(id, ManualTag(start: start, end: end, label: 'walk')), isTrue);
    expect(store.tags(id).where((t) => t.source == 'owner_stop_sheet').single.words, words);
  });

  test('every chip and every span kind\'s label is a word of the shared vocabulary', () {
    for (final c in stopChips) {
      expect(Label.of(c.label), isNotNull, reason: c.word);
    }
    for (final l in spanLabels.values) {
      expect(Label.of(l), isNotNull, reason: l);
    }
    for (final l in chipOfSpanKind.values) {
      expect(stopChipOf(l), isNotNull, reason: l);
    }
    expect(labelSources.keys, containsAll([stopSheetSource, 'owner_activity_button']));
    expect(labelConfidences.keys, contains('within'));
  });

  test('chips: one tap each; Awake the whole time and Slept or Napped switch each other off; words alone are Other', () {
    var on = tapStopChip({}, 'night_sleep');
    on = tapStopChip(on, 'walking');
    expect(on, {'night_sleep', 'walking'});
    on = tapStopChip(on, 'awake');
    expect(on, {'walking', 'awake'});
    on = tapStopChip(on, 'nap');
    expect(on, {'walking', 'nap'});
    expect(tapStopChip(on, 'walking'), {'nap'});
    final t = stopSheetTags(start: start, end: end, picks: const [], words: 'gardening', made: end).single;
    expect((t['label'], t['confidence'], t['words']), ('other', 'within', 'gardening'));
    expect(stopSheetTags(start: start, end: end, picks: const [], words: '  ', made: end), isEmpty); // Skip
  });

  test('skipped by itself when pressed spans cover 90 % and no question waits; done chips come from pressed spans', () {
    Span span(String kind, int fromMin, int toMin, {String source = 'owner_button'}) => Span(
      id: '$id-$fromMin',
      kind: kind,
      start: start.add(Duration(minutes: fromMin)),
      end: start.add(Duration(minutes: toMin)),
      source: source,
    );
    final total = end.difference(start).inMinutes; // 518
    final morning = StopSheetPlan(recording: id, start: start, end: end, spans: [span('sleep', 0, total - 20)]);
    expect(morning.covered, greaterThan(0.9));
    expect(morning.skips(questions: 0), isTrue);
    expect(morning.skips(questions: 1), isFalse);
    expect(morning.done, {'night_sleep'});
    final day = StopSheetPlan(recording: id, start: start, end: end, spans: [span('work', 3, 98), span('work', 50, 120), span('sleep', 200, 300, source: 'auto_start')]);
    expect(day.covered, closeTo(117 / total, 0.001)); // overlaps once; the app's own guess does not count
    expect(day.skips(questions: 0), isFalse);
    expect(day.done, {'working'});
    expect(day.marked, startsWith('Work 11:05-12:40 · Work 11:52-13:02'));
  });

  test('Awake the whole time settles the recording\'s sleep estimates as No; a timed walk says Yes to the walk inside it', () {
    final confirm = ConfirmQuestions(files, clock: () => end.add(const Duration(minutes: 5)));
    Estimate est(String label, int fromMin, int toMin) => Estimate(
      label: Label.of(label)!,
      start: start.add(Duration(minutes: fromMin)),
      end: start.add(Duration(minutes: toMin)),
      recording: id,
      detector: 'test',
      version: '1',
      confidence: 0.6,
      made: end,
    );
    final sleep = est('asleep', 100, 200), walk = est('walking', 360, 395);
    confirm.register([sleep, walk]);
    expect(confirm.pendingFor(id, start, end), hasLength(2));
    saveStopSheet(
      files,
      plan,
      picks: [const StopPick('awake'), StopPick('walking', start: start.add(const Duration(minutes: 358)), end: start.add(const Duration(minutes: 398)))],
      confirm: confirm,
      made: end,
    );
    final state = confirm.store.read();
    expect(state.answers[sleep.id]!.answer, Answer.no);
    expect(state.answers[walk.id]!.answer, Answer.yes);
    expect(state.answers[walk.id]!.via, AnswerVia.stopSheet.wire);
    expect(confirm.pendingFor(id, start, end), isEmpty);
  });

  test('Slept with times and a yes: a sleep span, owner_confirmed; a Yes on a sleep estimate does the same, once', () {
    final from = start.add(const Duration(hours: 2)), to = start.add(const Duration(hours: 4));
    saveStopSheet(files, plan, picks: [StopPick('night_sleep', start: from, end: to)], sleepReports: {'night_sleep'}, made: end);
    var spans = readSpans(spansFileOf(Directory('${files.path}/spans'), id)).spans;
    expect([for (final s in spans) (s.kind, s.source, s.start, s.end)], [('sleep', 'owner_confirmed', from, to)]);
    final e = Estimate(label: Labels.asleep, start: from, end: to, recording: id, detector: 'test', version: '1', confidence: 0.7, made: end);
    expect(confirmedSleep(files, e), isTrue);
    expect(confirmedSleep(files, e), isTrue);
    expect(confirmedSleep(files, e, active: () => id), isTrue); // confirmed before: nothing to write
    spans = readSpans(spansFileOf(Directory('${files.path}/spans'), id)).spans;
    expect(spans, hasLength(2));
    expect(spans.last.estimate, e.id);
    final other = Estimate(label: Labels.asleep, start: from, end: to, recording: 'running', detector: 'test', version: '1', confidence: 0.7, made: end);
    expect(confirmedSleep(files, other, active: () => 'running'), isFalse); // the recorder's file while it runs
  });

  testWidgets('the sheet: chips, words, Save writes the tags; Skip writes nothing; either way it is not asked again', (tester) async {
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => showStopSheet(context, plan, filesDir: files), child: const Text('open')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('What was this recording?'), findsOneWidget);
    expect(find.textContaining('11:02 - 19:40'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(TagStore(files).tags(id), isEmpty);
    expect(StopSheetSeen(files).last, id);

    await open();
    await tester.tap(find.text('Awake the whole time'));
    await tester.tap(find.text('Walked'));
    await tester.pump();
    expect(find.text('Walked: only part of it?'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('stop-words')), words);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final tags = TagStore(files).tags(id);
    expect([for (final t in tags) (t.label, t.confidence)], unorderedEquals([('awake', 'certain'), ('walking', 'within')]));
    expect(tags.every((t) => t.words == words && t.source == 'owner_stop_sheet' && t.truth), isTrue);
  });
}
