// "Sleep so far" on a recording started with Record (Record first, DECISIONS 880-889): it counts only the open sleep
// stretch, from the moment Sleep was pressed, and not the hours of the recording before it. Real file sets and a real
// spans file; the plan (lib/sleep/so_far.dart planSoFar) is what the scoring windows are cut from.
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/sleep/so_far.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory files, rec;
  late SpanLog log;

  setUp(() {
    files = Directory.systemTemp.createTempSync('so_far_spans_test');
    rec = Directory('${files.path}/recordings')..createSync();
    log = SpanLog(spansDirFor(rec.path));
    forgetNightSets();
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// A recording's file set of [minutes] at 250 Hz from [start], one batch a second, with its recording id in the header.
  String writeSet(DateTime start, int minutes) {
    final w = ChunkWriter.open(rec, start, inRecording: true);
    final row = Sample(0, Float32List.fromList([1e-5, 2e-5, 3e-5, 4e-5]));
    final batch = List.filled(250, row);
    for (var s = 0; s < minutes * 60; s++) {
      w.addBatch(start.add(Duration(seconds: s)), batch);
      if (s % 600 == 599) w.append();
    }
    w.close();
    return w.stem;
  }

  final evening = DateTime(2026, 11, 21, 22);

  test('Sleep pressed 25 minutes into a recording: so far counts from the sleep, not from the recording', () {
    final id = writeSet(evening, 40); // 22:00 - 22:40
    final from = evening.add(const Duration(minutes: 25));
    log.add(id, kind: 'sleep', start: from, source: 'owner_button'); // still open
    final plan = planSoFar(rec.path, from.millisecondsSinceEpoch)!;
    expect(plan.startUnix, from.millisecondsSinceEpoch ~/ 1000, reason: 'the chart starts when Sleep was pressed');
    expect(plan.epochs, inInclusiveRange(29, 30), reason: '15 minutes of sleep, not the 40 of the recording');
    expect(plan.walkLayout!.samples, plan.layout.samples, reason: 'the walking rule reads the same stretch');
  });

  test('an earlier, closed sleep of the evening is not counted: only the open stretch', () {
    final id = writeSet(evening, 60); // 22:00 - 23:00
    log.add(id, kind: 'sleep', start: evening.add(const Duration(minutes: 5)), end: evening.add(const Duration(minutes: 15)), source: 'owner_button');
    final open = evening.add(const Duration(minutes: 35));
    log.add(id, kind: 'sleep', start: open, source: 'owner_button');
    final plan = planSoFar(rec.path, open.millisecondsSinceEpoch)!;
    expect(plan.startUnix, open.millisecondsSinceEpoch ~/ 1000);
    expect(plan.epochs, inInclusiveRange(49, 50), reason: '25 minutes: the open stretch only');
  });

  test('a recording of Sleep from its first minute: the whole recording is the sleep, as before', () {
    final id = writeSet(evening, 30);
    log.add(id, kind: 'sleep', start: evening, source: 'owner_button');
    final plan = planSoFar(rec.path, evening.millisecondsSinceEpoch)!;
    expect(plan.startUnix, inInclusiveRange(evening.millisecondsSinceEpoch ~/ 1000 - 1, evening.millisecondsSinceEpoch ~/ 1000));
    expect(plan.epochs, inInclusiveRange(59, 60));
  });

  test('a recording with no sleep marked is no night: nothing to count', () {
    writeSet(evening, 30);
    expect(planSoFar(rec.path, evening.millisecondsSinceEpoch), isNull);
  });
}
