// The sheet after Stop (Record first, DECISIONS 890-891, 908-910; spec tests 8 and 11): each chip's tag, the times,
// the verbatim words, Skip, the skip-by-itself rule, the confirm questions it settles, and the same tag fields as the
// golden file the laptop's truth.py reads (tests/contract/labels/stop-sheet.tags.json).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart' show forgetNightSets;
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:eeg_tracker/spans/stop_sheet.dart';
import 'package:eeg_tracker/ui/stop_sheet.dart';
import 'package:eeg_tracker/ui/theme.dart';
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

  test(
    "a work span the headband watcher started is the app's guess: it covers nothing and the Worked chip is still asked (DECISIONS 1131)",
    () {
      Span work(String source) => Span(id: '$id-1', kind: 'work', start: start.add(const Duration(minutes: 3)), end: end, source: source);
      final guess = StopSheetPlan(recording: id, start: start, end: end, spans: [work('auto_start')]);
      expect(guess.covered, 0);
      expect(guess.done, isEmpty);
      expect(guess.skips(questions: 0), isFalse);
      final pressed = StopSheetPlan(recording: id, start: start, end: end, spans: [work('owner_button')]);
      expect(pressed.done, {'working'});
    },
  );

  // The real phone, 2026-11-25: "the sheet did not show" after two Stops. Both are the rule, pinned here.
  test('Sleep started the recording and Stop ended it: Sleep covers it all, so no sheet and nothing left to answer', () {
    final rec = Directory('${files.path}/recordings')..createSync();
    final pressed = DateTime(2026, 11, 25, 14, 17, 52), stopped = DateTime(2026, 11, 25, 14, 21, 29);
    final batch = List.filled(250, Sample(0, Float32List.fromList([1e-5, 2e-5, 3e-5, 4e-5])));
    String writeSet(DateTime at, int seconds, {String? recording}) {
      final w = ChunkWriter.open(rec, at, inRecording: true, recording: recording);
      for (var s = 0; s < seconds; s++) {
        w.addBatch(at.add(Duration(seconds: s)), batch);
      }
      w.close();
      return w.stem;
    }

    final rid = writeSet(pressed, 39); // the screen was swiped away: 59 s without data, then a second file set
    writeSet(DateTime(2026, 11, 25, 14, 19, 30), 119, recording: rid);
    SpanLog(Directory('${files.path}/spans')).add(rid, kind: 'sleep', start: pressed, end: stopped, source: 'owner_button', endedBy: 'recording_stopped', startedRecording: true);
    final p = stopSheetPlan(files, rid, pressed.millisecondsSinceEpoch)!;
    expect((p.start, p.end), (pressed, stopped));
    expect(p.covered, 1.0);
    expect(p.skips(questions: 0), isTrue); // no sheet after Stop, and no "Answer" line on the Record tab
    expect(p.skips(questions: 1), isFalse); // a waiting "Did you sleep?" would still bring it
  });

  test('a recording that never got a sample and has nothing marked: there is nothing to ask about', () {
    final at = DateTime(2026, 11, 25, 14, 25);
    expect(stopSheetPlan(files, '2026-11-25-142500', at.millisecondsSinceEpoch), isNull); // no file set at all
    final rec = Directory('${files.path}/recordings')..createSync();
    final w = ChunkWriter.open(rec, at, inRecording: true)..close(); // a file set with a header and no sample
    expect(stopSheetPlan(files, w.stem, at.millisecondsSinceEpoch), isNull);
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

  // ---- a Yes to "Did you sleep?" (review finding 4, DECISIONS 1016) ----

  Estimate sleepEstimate({String? recording}) => Estimate(
    label: Labels.asleep,
    start: start.add(const Duration(hours: 2)),
    end: start.add(const Duration(hours: 4)),
    recording: recording ?? id,
    detector: 'test',
    version: '1',
    confidence: 0.7,
    made: end,
  );
  List<Span> spansOf(String recording) => readSpans(spansFileOf(Directory('${files.path}/spans'), recording)).spans;

  test('"Yes, but the times are off": the sleep span is built from the times you set, not the detector\'s', () {
    final confirm = ConfirmQuestions(files, clock: () => end.add(const Duration(minutes: 5)));
    final e = sleepEstimate();
    confirm.register([e]);
    final from = e.start.add(const Duration(minutes: 25)), to = e.end.subtract(const Duration(minutes: 10));
    final said = <(Estimate, Answered)>[];
    ConfirmQuestions.onYes = (e, a) {
      said.add((e, a));
      confirmedSleep(files, e, answer: a);
    };
    addTearDown(() => ConfirmQuestions.onYes = null);
    confirm.answer(e.id, Answer.yes, start: from, end: to);
    expect(said.single.$2.timesConfirmed, isTrue);
    expect([for (final s in spansOf(id)) (s.source, s.estimate, s.start, s.end)], [('owner_confirmed', e.id, from, to)]);
  });

  test('a plain Yes keeps the detector\'s times; times set later (after taking the answer back) correct the same span', () {
    final confirm = ConfirmQuestions(files, clock: () => end.add(const Duration(minutes: 5)));
    final e = sleepEstimate();
    confirm.register([e]);
    ConfirmQuestions.onYes = (e, a) => confirmedSleep(files, e, answer: a);
    addTearDown(() => ConfirmQuestions.onYes = null);
    confirm.answer(e.id, Answer.yes);
    expect([for (final s in spansOf(id)) (s.estimate, s.start, s.end)], [(e.id, e.start, e.end)]);
    confirm.undo(e.id);
    final from = e.start.add(const Duration(minutes: 30));
    confirm.answer(e.id, Answer.yes, start: from, end: e.end);
    final after = spansOf(id);
    expect([for (final s in after) (s.estimate, s.start, s.end)], [(e.id, from, e.end)], reason: 'one span, with your times');
  });

  test('a Yes given where no span could be written (the notification, or while that recording still runs) becomes '
      'the span at the next sweep once the recording has stopped', () {
    final confirm = ConfirmQuestions(files, clock: () => end.add(const Duration(minutes: 5)));
    final e = sleepEstimate(), walk = Estimate(label: Label.of('walking')!, start: e.start, end: e.end, recording: id, detector: 'test', version: '1', confidence: 0.6, made: end);
    final no = sleepEstimate(recording: 'other');
    confirm.register([e, walk, no]);
    ConfirmQuestions.onYes = null; // the notification's Yes is written by Android: no hook runs
    final from = e.start.add(const Duration(minutes: 5));
    confirm.answer(e.id, Answer.yes, via: AnswerVia.notification, start: from, end: e.end);
    confirm.answer(walk.id, Answer.yes);
    confirm.answer(no.id, Answer.no);
    expect(spansOf(id), isEmpty);
    // the recording still runs: nothing may be written into the recorder's file, and nothing is lost
    expect(sweepConfirmedSleep(files, active: () => id), (written: 0, waiting: 1));
    expect(spansOf(id), isEmpty);
    // it has stopped
    expect(sweepConfirmedSleep(files, active: () => null), (written: 1, waiting: 0));
    expect([for (final s in spansOf(id)) (s.kind, s.source, s.estimate, s.start, s.end)], [('sleep', 'owner_confirmed', e.id, from, e.end)]);
    expect(sweepConfirmedSleep(files, active: () => null), (written: 0, waiting: 0), reason: 'safe to repeat');
    expect(spansOf(id), hasLength(1));
    expect(spansOf('other'), isEmpty, reason: 'a No makes no span');
  });

  // ---- which recording a Yes is filed under (the real phone, 2026-11-25 14:10; DECISIONS 1028) ----

  group('a Yes becomes a stretch of the recording that holds its start', () {
    late Directory rec;
    final batch = List.filled(250, Sample(0, Float32List.fromList([1e-5, 2e-5, 3e-5, 4e-5])));
    setUp(() {
      rec = Directory('${files.path}/recordings')..createSync();
      forgetNightSets();
    });

    /// A file set with data from [from] to [to]; [recording]: its header's id (null: a set from before Record first;
    /// '': the first set of a new recording, named by its own stem).
    String writeSet(DateTime from, DateTime to, {String? recording}) {
      final w = ChunkWriter.open(rec, from, inRecording: recording != null, recording: recording == '' ? null : recording);
      w.addBatch(from, batch);
      w.addBatch(to, batch);
      w.close();
      return w.stem;
    }

    // the owner's night: an awake evening recording, then the night in two file sets (one drop at 05:21), all from
    // before Record first, chained into one old-style night under the first one's name
    final from = DateTime(2026, 11, 25, 1, 30, 52), to = DateTime(2026, 11, 25, 8, 31, 22);
    late String evening, night, afterDrop;
    void theNight() {
      evening = writeSet(DateTime(2026, 11, 24, 18, 23, 44), DateTime(2026, 11, 25, 0, 5, 10));
      night = writeSet(DateTime(2026, 11, 25, 0, 36), DateTime(2026, 11, 25, 5, 21, 32));
      afterDrop = writeSet(DateTime(2026, 11, 25, 5, 23, 4), DateTime(2026, 11, 25, 11, 41));
    }

    Estimate slept(String recording) =>
        Estimate(label: Labels.asleep, start: from, end: to, recording: recording, detector: 'test', version: '1', confidence: 0.9, made: to);
    SpansFile fileOf(String recording) => readSpans(spansFileOf(Directory('${files.path}/spans'), recording));
    int lines(String recording) => spansFileOf(Directory('${files.path}/spans'), recording).readAsLinesSync().length;

    test('the estimate names the night\'s first recording, the awake evening: the stretch goes where its hours are', () {
      theNight();
      expect((evening, night, afterDrop), ('2026-11-24-182344', '2026-11-25-003600', '2026-11-25-052304'));
      final e = slept(evening);
      expect(confirmedSleep(files, e), isTrue);
      expect(fileOf(evening).spans, isEmpty);
      expect(fileOf(afterDrop).spans, isEmpty);
      final s = fileOf(night).spans.single; // it holds 01:30; the stretch is one, whole, though it ends in the next set
      expect((s.id, s.start, s.end, s.source, s.estimate), ('$night-1', from, to, 'owner_confirmed', e.id));
      expect(confirmedSleep(files, e), isTrue);
      expect(lines(night), 1, reason: 'once');
    });

    test('the one already written under the wrong recording is filed again at the next sweep, once', () {
      theNight();
      final e = slept(evening);
      final confirm = ConfirmQuestions(files, clock: () => DateTime(2026, 11, 25, 13, 52));
      confirm.register([e]);
      ConfirmQuestions.onYes = null;
      confirm.answer(e.id, Answer.yes);
      // what the phone has since 14:10:26
      final wrong = SpanLog(Directory('${files.path}/spans')).add(evening, kind: 'sleep', start: from, end: to, source: 'owner_confirmed', estimate: e.id);
      expect(wrong.id, '2026-11-24-182344-1');

      expect(sweepConfirmedSleep(files, active: () => null), (written: 1, waiting: 0));
      expect(fileOf(evening).spans, isEmpty);
      final old = fileOf(evening).removed.single;
      expect((old.id, old.movedTo, old.start, old.end), (wrong.id, '$night-1', from, to));
      final s = fileOf(night).spans.single;
      expect((s.id, s.start, s.end, s.source, s.estimate, s.endedBy), ('$night-1', from, to, 'owner_confirmed', e.id, 'owner'));

      expect(sweepConfirmedSleep(files, active: () => null), (written: 0, waiting: 0), reason: 'safe to run twice');
      expect((lines(evening), lines(night)), (2, 1));
    });

    test('a recording made since Record first is named by its id, whichever of its file sets holds the start', () {
      final id = writeSet(DateTime(2026, 11, 25, 0, 36), DateTime(2026, 11, 25, 1), recording: '');
      final second = writeSet(DateTime(2026, 11, 25, 1, 1), DateTime(2026, 11, 25, 9), recording: id);
      final e = slept('2026-11-24-182344');
      expect(confirmedSleep(files, e), isTrue);
      expect(fileOf(id).spans.single.id, '$id-1');
      expect(fileOf(second).spans, isEmpty);
    });

    test('a start between two file sets: the first one that holds part of it; no file set at all: the estimate\'s own', () {
      final e = slept('named');
      expect(confirmedSleep(files, e), isTrue);
      expect(fileOf('named').spans.single.estimate, e.id);
      final later = writeSet(DateTime(2026, 11, 25, 2), DateTime(2026, 11, 25, 9));
      writeSet(DateTime(2026, 11, 24, 22), DateTime(2026, 11, 25, 1)); // ends before the start
      forgetNightSets();
      final confirm = ConfirmQuestions(files, clock: () => DateTime(2026, 11, 25, 13, 52));
      confirm.register([e]);
      ConfirmQuestions.onYes = null;
      confirm.answer(e.id, Answer.yes);
      expect(sweepConfirmedSleep(files, active: () => null), (written: 1, waiting: 0));
      expect(fileOf(later).spans.single.estimate, e.id);
      expect(fileOf('named').removed.single.movedTo, '$later-1');
    });

    test('the recording that holds it still runs: the stretch waits; one you took away is not made again', () {
      theNight();
      final e = slept(evening);
      final confirm = ConfirmQuestions(files, clock: () => DateTime(2026, 11, 25, 13, 52));
      confirm.register([e]);
      ConfirmQuestions.onYes = null;
      confirm.answer(e.id, Answer.yes);
      expect(sweepConfirmedSleep(files, active: () => night), (written: 0, waiting: 1));
      expect(fileOf(night).spans, isEmpty);
      expect(sweepConfirmedSleep(files, active: () => null), (written: 1, waiting: 0));
      final s = fileOf(night).spans.single;
      SpanLog(Directory('${files.path}/spans')).write(s.asRemoved(true)); // "Not sleep" in the Archive
      expect(sweepConfirmedSleep(files, active: () => null), (written: 0, waiting: 0));
      expect(confirmedSleep(files, e), isTrue);
      expect(fileOf(night).spans, isEmpty);
      expect(lines(night), 2);
    });
  });

  testWidgets('the sheet: chips, words, Save writes the tags; Skip writes nothing; either way it is not asked again', (tester) async {
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(), // the app's own: its filled buttons are as wide as they are allowed to be
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
    // on a phone-sized screen Save is on the screen and can be tapped
    expect(tester.getRect(find.text('Save')).right, lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final tags = TagStore(files).tags(id);
    expect([for (final t in tags) (t.label, t.confidence)], unorderedEquals([('awake', 'certain'), ('walking', 'within')]));
    expect(tags.every((t) => t.words == words && t.source == 'owner_stop_sheet' && t.truth), isTrue);
  });
}
