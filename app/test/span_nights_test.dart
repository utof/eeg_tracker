// Nights and naps from sleep spans (Record first, DECISIONS 886-889; spec tests 3, 4, 7, 10, 13's phone twin): an
// awake recording is no night, a sleep span is scored by its own samples only, naps stand alone, old folders read as
// before, "Not sleep" takes an old recording out, a recording ended by a phone restart gets its spans closed.
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/spans/after_restart.dart';
import 'package:eeg_tracker/spans/not_sleep.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sleep_resume_test.dart' show CountingRun, fakeInput;

void main() {
  late Directory files, rec;
  late SpanLog log;

  setUp(() {
    files = Directory.systemTemp.createTempSync('span_nights_test');
    rec = Directory('${files.path}/recordings')..createSync();
    log = SpanLog(spansDirFor(rec.path));
    forgetNightSets();
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// A file set of [minutes] at 250 Hz from [start], one batch a second; [recording]: its header's id (null: an old set).
  String writeSet(DateTime start, int minutes, {String? recording, bool first = false}) {
    final w = ChunkWriter.open(rec, start, inRecording: recording != null || first, recording: recording);
    final row = Sample(0, Float32List.fromList([1e-5, 2e-5, 3e-5, 4e-5]));
    final batch = List.filled(250, row);
    for (var s = 0; s < minutes * 60; s++) {
      w.addBatch(start.add(Duration(seconds: s)), batch);
      if (s % 600 == 599) w.append();
    }
    w.close();
    return w.stem;
  }

  final day = DateTime(2026, 11, 21, 11, 2);

  test('an awake recording (Record, 2 hours, Stop, no sleep span) is no night and no nap', () {
    writeSet(day, 120, first: true);
    expect(nightsIn(rec), isEmpty);
    expect(napsIn(rec), isEmpty);
  });

  test('a sleep span 3 hours into a recording: one night named by its evening, only its samples', () {
    final id = writeSet(day, 240, first: true); // 11:02 - 15:02
    final from = day.add(const Duration(hours: 3)), to = from.add(const Duration(minutes: 40));
    log.add(id, kind: 'sleep', start: from, end: to, source: 'owner_button');
    final n = nightsIn(rec).single;
    expect(n.name, '2026-11-21'); // 14:02 minus 12 hours is still the 21st
    expect(n.windows, [(from, to)]);
    expect((n.start, n.end), (from, to));
    expect(n.spanIds, ['$id-1']);
    expect(n.spanField, {'recording': [id], 'spans': ['$id-1'], 'kind': 'night', 'from': 'pressed'});
    expect(n.recordings.single.path, endsWith('$id.f32'));
    // the joined signal is the span's 40 minutes, not the recording's 4 hours
    final w = [(from.microsecondsSinceEpoch / 1e6, to.microsecondsSinceEpoch / 1e6)];
    final layout = joinLayout(n.recordings, windows: w);
    expect(layout.samples, 40 * 60 * 250);
    expect(layout.startUnix, from.millisecondsSinceEpoch ~/ 1000);
    expect(joinLayout(n.recordings).samples, 240 * 60 * 250);
    // its report's inputs are the span's bytes: the recording going on after the sleep does not make it stale
    expect(SleepScorer.inputsOf(n), {'$id.f32': 40 * 60 * 250 * 20});
  });

  test('two sleep spans of one evening are one night; a nap is its own and joins none; an open span ends at the data', () {
    final id = writeSet(DateTime(2026, 11, 21, 22), 600, first: true); // 22:00 - 08:00
    final a = DateTime(2026, 11, 21, 23), b = DateTime(2026, 11, 22, 2), c = DateTime(2026, 11, 22, 3);
    log.add(id, kind: 'sleep', start: a, end: b, source: 'owner_button');
    log.add(id, kind: 'nap', start: DateTime(2026, 11, 22, 2, 10), end: DateTime(2026, 11, 22, 2, 40), source: 'owner_button');
    log.add(id, kind: 'sleep', start: c, source: 'auto_start'); // still open
    log.add(id, kind: 'work', start: a, end: b, source: 'owner_button'); // not sleep: no window
    final n = nightsIn(rec).single;
    expect(n.name, '2026-11-21');
    expect(n.windows!.map((w) => w.$1), [a, c]);
    expect(n.windows!.last.$2, DateTime(2026, 11, 22, 7, 59, 59)); // the last batch's arrival
    expect(n.spanFrom, 'pressed');
    final nap = napsIn(rec).single;
    expect(nap.name, 'naps/2026-11-22-021000');
    expect(nap.isNap, isTrue);
    expect(nap.spanField!['kind'], 'nap');
    expect(nap.windows!.single.$2.difference(nap.windows!.single.$1), const Duration(minutes: 30));
  });

  test('an old folder (no recording ids, no spans) reads as before; Not sleep takes a recording out and back', () {
    final evening = writeSet(DateTime(2026, 11, 20, 22, 17), 100); // the awake evening
    final night = writeSet(DateTime(2026, 11, 21, 23, 30), 60);
    final before = nightsIn(rec);
    expect([for (final n in before) n.name], ['2026-11-21', '2026-11-20']);
    expect(before.every((n) => n.windows == null && n.spanField == null), isTrue);
    expect(SleepScorer.inputsOf(before.last), {'$evening.f32': 100 * 60 * 250 * 20});
    final nights = Directory('${files.path}/nights')..createSync();
    File('${nights.path}/2026-11-20.report.json').writeAsStringSync('{}');
    File('${nights.path}/2026-11-21.report.json').writeAsStringSync('{}');

    expect(setNotSleep(files, evening, [evening], notSleep: true), ['2026-11-20']);
    expect(isNotSleep(files, evening), isTrue);
    expect([for (final n in nightsIn(rec)) n.name], ['2026-11-21']);
    expect(File('${nights.path}/2026-11-20.report.json').existsSync(), isFalse);
    expect(File('${nights.path}/not-sleep/2026-11-20.report.json').existsSync(), isTrue); // hidden, never deleted
    expect(File('${nights.path}/2026-11-21.report.json').existsSync(), isTrue);
    final line = readSpans(spansFileOf(spansDirFor(rec.path), evening));
    expect(line.reviewed, 'no_sleep');
    expect(line.sets, [evening]);
    expect(line.hides, ['2026-11-20']);

    expect(setNotSleep(files, evening, [evening], notSleep: false), ['2026-11-20']);
    expect(isNotSleep(files, evening), isFalse);
    expect([for (final n in nightsIn(rec)) n.name], ['2026-11-21', '2026-11-20']);
    expect(File('${nights.path}/2026-11-20.report.json').existsSync(), isTrue);
    expect(night, isNotEmpty);
  });

  test('an old night and a sleep span of the same evening are one night, the old chain a window too', () {
    final old = writeSet(DateTime(2026, 11, 21, 22), 60);
    final id = writeSet(DateTime(2026, 11, 22, 1), 300, first: true);
    log.add(id, kind: 'sleep', start: DateTime(2026, 11, 22, 1, 30), end: DateTime(2026, 11, 22, 5), source: 'owner_confirmed', estimate: 'est:1');
    final n = nightsIn(rec).single;
    expect(n.name, '2026-11-21');
    expect([for (final f in n.recordings) f.uri.pathSegments.last], ['$old.f32', '$id.f32']);
    expect(n.windows, [(DateTime(2026, 11, 21, 22), DateTime(2026, 11, 21, 22, 59, 59)), (DateTime(2026, 11, 22, 1, 30), DateTime(2026, 11, 22, 5))]);
    expect(n.spanFrom, 'confirmed');
  });

  test('a recording ended by a phone restart: its open spans end at its last sample, once the data is old', () {
    final id = writeSet(day, 30, first: true);
    final open = log.add(id, kind: 'sleep', start: day.add(const Duration(minutes: 5)), source: 'owner_button', startedRecording: true);
    final state = NightState(active: true, startMs: day.millisecondsSinceEpoch, recording: id, spans: [open.toLine(day)]);
    final lastSample = day.add(const Duration(minutes: 30));
    // Android restarting the process: the data is fresh, nothing is closed
    expect(endedWithoutStop(state, rec, clock: () => lastSample.add(const Duration(minutes: 2))), isNull);
    final fixed = endedWithoutStop(state, rec, clock: () => lastSample.add(const Duration(hours: 2)))!;
    expect(fixed.active, isFalse);
    expect(fixed.sleepKit, isFalse);
    final s = readSpans(spansFileOf(spansDirFor(rec.path), id)).spans.single;
    expect(s.endedBy, 'phone_restart');
    expect(s.end!.difference(lastSample).inSeconds.abs(), lessThan(2));
    expect(nightsIn(rec).single.windows!.single.$2, s.end);
    expect(endedWithoutStop(fixed, rec), isNull); // done once
    expect(tryHeader(File('${rec.path}/$id.f32'))!.recording, id);
  });

  test('the scorer: a sleep span and a nap get their reports from their own samples; nothing else is scored', () async {
    final id = writeSet(day, 240, first: true);
    final from = day.add(const Duration(hours: 1)), to = from.add(const Duration(minutes: 40));
    final napAt = day.add(const Duration(hours: 3));
    log.add(id, kind: 'sleep', start: from, end: to, source: 'owner_button');
    log.add(id, kind: 'nap', start: napAt, end: napAt.add(const Duration(minutes: 20)), source: 'owner_button');
    writeSet(DateTime(2026, 11, 22, 9), 120, first: true); // an awake recording: never scored
    final asked = <List<(double, double)>>[];
    final store = NightReportStore(nightsDirFor(rec.path));
    final s = SleepScorer(
      recordingsDir: rec,
      store: store,
      openRun: (run) async => CountingRun(run, []),
      prepare: (files) async => fail('a span night is prepared through its windows'),
      see: (files) async => null,
      prepareSpan: (files, windows) async {
        asked.add(windows);
        return fakeInput(windows.first.$1.floor());
      },
      seeSpan: (files, windows) async => null,
    );
    final due = s.due();
    expect([for (final n in due) n.name], ['naps/${fileStem(napAt)}', '2026-11-21']);
    for (final n in due) {
      await s.score(n);
    }
    expect(asked.map((w) => w.single.$2 - w.single.$1), [20 * 60, 40 * 60]);
    final night = store.read('2026-11-21')!;
    expect(night.json['span'], {'recording': [id], 'spans': ['$id-1'], 'kind': 'night', 'from': 'pressed'});
    expect(night.json['night_of'], '2026-11-21');
    final nap = File('${store.dir.path}/naps/${fileStem(napAt)}.report.json');
    expect(nap.existsSync(), isTrue);
    expect(store.read('naps/${fileStem(napAt)}')!.json['span'], containsPair('kind', 'nap'));
    expect(store.read('naps/${fileStem(napAt)}')!.json['night_of'], fileStem(napAt));
    expect([for (final r in store.all()) r.nightOf], ['2026-11-21']); // a nap is never listed as a night
    expect(s.due(), isEmpty);
  });
}
