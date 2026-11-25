// A marked stretch taken away in the Archive (DECISIONS 1025), and a short stray one before the night (1026), built
// from the owner's 2026-11-25: Sleep pressed for a 4-minute test at 14:17, the real night that evening.
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/archive/items.dart' show sessionFilesIn;
import 'package:eeg_tracker/confirm/questions.dart';
import 'package:eeg_tracker/feedback/session_log.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/spans/not_sleep.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_labels/shared_labels.dart';

void main() {
  late Directory files, rec, nights;
  late SpanLog log;

  setUp(() {
    files = Directory.systemTemp.createTempSync('removed_span_test');
    rec = Directory('${files.path}/recordings')..createSync();
    nights = Directory('${files.path}/nights')..createSync();
    log = SpanLog(spansDirFor(rec.path));
    forgetNightSets();
  });
  tearDown(() => files.deleteSync(recursive: true));

  String writeSet(DateTime start, int seconds, {String? recording}) {
    final w = ChunkWriter.open(rec, start, inRecording: true, recording: recording);
    final batch = List.filled(250, Sample(0, Float32List.fromList([1e-5, 2e-5, 3e-5, 4e-5])));
    for (var s = 0; s < seconds; s++) {
      w.addBatch(start.add(Duration(seconds: s)), batch);
    }
    w.close();
    return w.stem;
  }

  final pressed = DateTime(2026, 11, 25, 14, 17, 52), stopped = DateTime(2026, 11, 25, 14, 21, 29);

  /// The 4-minute test: two file sets (the screen was swiped away in between), Sleep from its start to Stop.
  Span theTest() {
    final id = writeSet(pressed, 39);
    writeSet(DateTime(2026, 11, 25, 14, 19, 30), 119, recording: id);
    return log.add(id, kind: 'sleep', start: pressed, end: stopped, source: 'owner_button', endedBy: 'recording_stopped', startedRecording: true);
  }

  /// That evening's night: Sleep 23:30, Stop 30 minutes later (long enough to be no stray).
  Span tonight() {
    final from = DateTime(2026, 11, 25, 23, 30);
    final id = writeSet(from, 30 * 60);
    return log.add(id, kind: 'sleep', start: from, end: from.add(const Duration(minutes: 30)), source: 'owner_button', endedBy: 'recording_stopped', startedRecording: true);
  }

  File report(String name) => File('${nights.path}/$name.report.json');

  test('the test stretch alone is the night of its evening date, as before', () {
    final t = theTest();
    final n = nightsIn(rec).single;
    expect(n.name, '2026-11-25');
    expect(n.spanIds, [t.id]);
  });

  test('a stretch under 20 minutes, hours before the night of the same evening date, is left out of that night', () {
    final t = theTest(), real = tonight();
    final n = nightsIn(rec).single;
    expect(n.name, '2026-11-25');
    expect(n.spanIds, [real.id]);
    expect(n.windows, [(real.start, real.end!)]);
    expect(n.start, real.start); // not 14:17: the night's report starts where the night did
    expect(n.recordingIds, [real.recording]);
    expect(n.recordings.single.path, endsWith('${real.recording}.f32'));
    expect(t.recording, isNot(real.recording));
  });

  test('the same while tonight\'s sleep is still open', () {
    theTest();
    final from = DateTime(2026, 11, 25, 23, 30);
    final id = writeSet(from, 5 * 60);
    final open = log.add(id, kind: 'sleep', start: from, source: 'owner_button', startedRecording: true);
    final n = nightsIn(rec).single;
    expect(n.spanIds, [open.id]);
    expect(n.start, from);
  });

  test('a short stretch hours after a real sleep of the same evening date is left out too; two long ones still join', () {
    final a = DateTime(2026, 11, 25, 13), id = writeSet(a, 40 * 60);
    final long = log.add(id, kind: 'sleep', start: a, end: a.add(const Duration(minutes: 40)), source: 'owner_button');
    final b = DateTime(2026, 11, 25, 20), id2 = writeSet(b, 5 * 60);
    log.add(id2, kind: 'sleep', start: b, end: b.add(const Duration(minutes: 5)), source: 'owner_button');
    expect(nightsIn(rec).single.spanIds, [long.id]);
    final real = tonight();
    forgetNightSets();
    expect(nightsIn(rec).single.spanIds, [long.id, real.id]);
  });

  test('Not sleep on the test stretch: no night, its report put away; taking it back brings both home', () {
    final t = theTest();
    report('2026-11-25').writeAsStringSync('{"scored":false}');
    expect(setSpanRemoved(files, t, removed: true), ['2026-11-25']);
    expect(nightsIn(rec), isEmpty);
    expect(report('2026-11-25').existsSync(), isFalse);
    final away = File('${nights.path}/not-sleep/${t.id}.report.json');
    expect(away.readAsStringSync(), '{"scored":false}'); // put away, never deleted
    final f = log.read(t.recording);
    expect(f.spans, isEmpty);
    expect(f.removed.single.id, t.id);
    expect((f.removed.single.start, f.removed.single.end, f.removed.single.endedBy), (pressed, stopped, 'recording_stopped'));
    // add-only: the two lines before are still there
    expect(log.fileOf(t.recording).readAsLinesSync(), hasLength(2));

    expect(setSpanRemoved(files, f.removed.single, removed: false), ['2026-11-25']);
    expect(nightsIn(rec).single.spanIds, [t.id]);
    expect(report('2026-11-25').readAsStringSync(), '{"scored":false}');
    expect(away.existsSync(), isFalse);
    expect(log.read(t.recording).removed, isEmpty);
  });

  test('removed, then the real night: tonight is the night; taking the test back later does not touch its report', () {
    final t = theTest();
    report('2026-11-25').writeAsStringSync('"the test"');
    setSpanRemoved(files, t, removed: true);
    final real = tonight();
    forgetNightSets();
    expect(nightsIn(rec).single.spanIds, [real.id]);
    report('2026-11-25').writeAsStringSync('"tonight"');
    // "It was sleep after all": the stray rule still keeps it out of tonight's night, and tonight's report stays
    expect(setSpanRemoved(files, log.read(t.recording).removed.single, removed: false), isEmpty);
    expect(nightsIn(rec).single.spanIds, [real.id]);
    expect(report('2026-11-25').readAsStringSync(), '"tonight"');
    expect(File('${nights.path}/not-sleep/${t.id}.report.json').readAsStringSync(), '"the test"');
  });

  test('one of two stretches of a night removed: the night stays, with the other one, and keeps its report file', () {
    final a = DateTime(2026, 11, 25, 23), id = writeSet(a, 90 * 60);
    final first = log.add(id, kind: 'sleep', start: a, end: a.add(const Duration(minutes: 30)), source: 'owner_button');
    final second = log.add(id, kind: 'sleep', start: a.add(const Duration(minutes: 40)), end: a.add(const Duration(minutes: 90)), source: 'auto_resume');
    report('2026-11-25').writeAsStringSync('{}');
    expect(setSpanRemoved(files, second, removed: true), isEmpty);
    expect(nightsIn(rec).single.spanIds, [first.id]);
    expect(report('2026-11-25').existsSync(), isTrue); // out of date by its spans: scored again, not put away
  });

  test('a nap removed: no nap, its report put away and brought back; a work mark removed: gone from the spans', () {
    final a = DateTime(2026, 11, 25, 11), id = writeSet(a, 60 * 60);
    final nap = log.add(id, kind: 'nap', start: a, end: a.add(const Duration(minutes: 30)), source: 'owner_button');
    final work = log.add(id, kind: 'work', start: a.add(const Duration(minutes: 31)), end: a.add(const Duration(minutes: 55)), source: 'owner_button');
    Directory('${nights.path}/naps').createSync();
    report('naps/2026-11-25-110000').writeAsStringSync('{}');
    expect(setSpanRemoved(files, nap, removed: true), ['naps/2026-11-25-110000']);
    expect(napsIn(rec), isEmpty);
    expect(report('naps/2026-11-25-110000').existsSync(), isFalse);
    expect(File('${nights.path}/not-sleep/${nap.id}.report.json').existsSync(), isTrue);
    expect(setSpanRemoved(files, work, removed: true), isEmpty);
    expect(log.read(id).spans, isEmpty);
    expect([for (final s in log.read(id).removed) s.id], [nap.id, work.id]);
    // a new mark never takes a removed one's number
    expect(log.add(id, kind: 'work', start: a, end: a, source: 'owner_button').id, '$id-3');
    expect(setSpanRemoved(files, log.read(id).removed.first, removed: false), ['naps/2026-11-25-110000']);
    expect(napsIn(rec).single.spanIds, [nap.id]);
    expect(report('naps/2026-11-25-110000').existsSync(), isTrue);
  });

  test('a removed Work or Meditate mark takes the activity\'s own file out of the lists; put back, it is there again', () async {
    final a = DateTime(2026, 11, 25, 11), id = writeSet(a, 60 * 60);
    final w0 = a.add(const Duration(minutes: 5)), m0 = a.add(const Duration(minutes: 31));
    final work = log.add(id, kind: 'work', start: w0, end: w0.add(const Duration(minutes: 20)), source: 'owner_button');
    final med = log.add(id, kind: 'meditate', start: m0, end: m0.add(const Duration(minutes: 10)), source: 'owner_button');
    // each activity's own file names its recording and its span (spans/activities.dart [ActivityRef])
    final works = WorkStore(Directory('${files.path}/work-sessions'));
    works.save({
      'kind': 'work_session',
      'start': w0.toIso8601String(),
      'end': w0.add(const Duration(minutes: 20)).toIso8601String(),
      'worn_min': 20,
      'recording': id,
      'span': work.id,
    });
    // a second work session of its own, from before Record first: never touched
    works.save({'kind': 'work_session', 'start': DateTime(2026, 11, 20, 10).toIso8601String(), 'end': DateTime(2026, 11, 20, 11).toIso8601String(), 'worn_min': 55});
    final meds = MeditationStore(Directory('${files.path}/meditations'));
    final summary = MeditationSummary(
      start: m0,
      lengthMin: 10,
      runS: 600,
      complete: true,
      settledS: 300,
      longestSettledS: 52,
      bells: 2,
      restless: {for (final r in Restless.values) r: 0},
      drifting: 0,
      drowsyS: 0,
      calm: const [0.5],
      iafHz: 9.75,
      note: '',
      logFile: '${fileStem(m0)}.log.json',
    );
    await meds.save(summary, SessionLog({'start': m0.toIso8601String()}), extra: {'recording': id, 'span': med.id});

    List<String> archive() => [for (final f in sessionFilesIn(files)) f.path]..sort();
    expect(works.list().map((s) => s.start), [w0, DateTime(2026, 11, 20, 10)]);
    expect(meds.list().map((s) => s.start), [m0]);
    expect(archive(), hasLength(3));

    setSpanRemoved(files, work, removed: true);
    expect(works.list().map((s) => s.start), [DateTime(2026, 11, 20, 10)]);
    expect((await works.listAsync()).map((s) => s.start), [DateTime(2026, 11, 20, 10)]);
    expect(meds.list(), hasLength(1));
    expect(archive(), ['meditations/${fileStem(m0)}.meditation.json', 'work-sessions/2026-11-20-100000.work.json']);
    setSpanRemoved(files, med, removed: true);
    expect(meds.list(), isEmpty);
    expect(archive(), ['work-sessions/2026-11-20-100000.work.json']);
    // nothing was deleted
    expect(File('${files.path}/work-sessions/${fileStem(w0)}.work.json').existsSync(), isTrue);
    expect(File('${files.path}/meditations/${fileStem(m0)}.meditation.json').existsSync(), isTrue);

    setSpanRemoved(files, log.read(id).removed.firstWhere((s) => s.id == work.id), removed: false);
    setSpanRemoved(files, log.read(id).removed.firstWhere((s) => s.id == med.id), removed: false);
    expect(works.list().map((s) => s.start), [w0, DateTime(2026, 11, 20, 10)]);
    expect(meds.list().map((s) => s.start), [m0]);
    expect(archive(), hasLength(3));
  });

  test('an open "Did you sleep?" about a stretch that was taken away is not asked; put back, it is asked again', () {
    final t = theTest(); // Sleep 14:17:52 to 14:21:29, pressed by mistake
    final now = DateTime(2026, 11, 25, 15);
    final confirm = ConfirmQuestions(files, clock: () => now);
    final guess = Estimate(
      detector: 'sleep-periods',
      version: 'test',
      label: Labels.nap,
      start: pressed.add(const Duration(seconds: 20)),
      end: stopped.subtract(const Duration(seconds: 10)),
      recording: t.recording,
      confidence: 0.9,
      made: stopped,
    );
    // another guess, hours away from the stretch: it is none of the removal's business
    final other = Estimate(
      detector: 'sleep-periods',
      version: 'test',
      label: Labels.nap,
      start: DateTime(2026, 11, 25, 10),
      end: DateTime(2026, 11, 25, 10, 40),
      recording: 'another',
      confidence: 0.9,
      made: DateTime(2026, 11, 25, 10, 40),
    );
    confirm.register([guess, other]);
    expect(confirm.pending().map((q) => q.estimate.id), containsAll([guess.id, other.id]));
    expect(confirm.pendingFor(t.recording, pressed, stopped).map((q) => q.estimate.id), [guess.id]);

    setSpanRemoved(files, t, removed: true);
    expect(confirm.pending().map((q) => q.estimate.id), [other.id]);
    expect(confirm.pendingFor(t.recording, pressed, stopped), isEmpty);
    // nothing was answered for you: no Yes, no No, no label
    expect(confirm.store.read().answered(guess.id), isFalse);

    setSpanRemoved(files, log.read(t.recording).removed.single, removed: false);
    expect(confirm.pending().map((q) => q.estimate.id), containsAll([guess.id, other.id]));

    // a stretch filed again under another recording (`moved_to`) was not taken away by you: its question stays
    log.write(log.read(t.recording).spans.single.asRemoved(true, movedTo: 'elsewhere-1'));
    expect(confirm.pending().map((q) => q.estimate.id), containsAll([guess.id, other.id]));
  });

  test('the recording that runs now is the recorder\'s: its marks cannot be removed from the Archive', () {
    final t = theTest();
    expect(() => setSpanRemoved(files, t, removed: true, active: () => t.recording), throwsA(isA<SpansBusy>()));
    expect(nightsIn(rec).single.spanIds, [t.id]);
  });
}
