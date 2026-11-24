// The spans file: its reader against the golden files it shares with scripts/spans.py, and its one writer (Record
// first, DECISIONS 880-899; spec test 1 and 12).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final golden = Directory('../tests/contract/spans');

  test('every golden spans file reads as its expected JSON says', () {
    final files = [
      for (final f in golden.listSync().whereType<File>())
        if (f.path.endsWith(spansSuffix)) f,
    ];
    expect(files.length, greaterThanOrEqualTo(6));
    for (final f in files) {
      final want = jsonDecode(File(f.path.replaceFirst(spansSuffix, '.expected.json')).readAsStringSync());
      expect(jsonDecode(jsonEncode(readSpans(f).toExpected())), want, reason: f.path);
    }
  });

  test('a missing file reads as an empty one', () {
    final s = readSpans(File('${golden.path}/none$spansSuffix'));
    expect(s.spans, isEmpty);
    expect(s.skipped, 0);
  });

  group('SpanLog', () {
    late Directory dir;
    final t0 = DateTime(2026, 11, 21, 11, 5);
    setUp(() => dir = Directory.systemTemp.createTempSync('span_log_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('open, close: the last line of a span is the span, and each line is in the file at once', () {
      final log = SpanLog(dir, clock: () => t0);
      final open = log.add('2026-11-21-110200', kind: 'work', start: t0, source: 'owner_button');
      expect(open.id, '2026-11-21-110200-1');
      expect(open.label, 'working');
      expect(log.read('2026-11-21-110200').spans.single.closed, isFalse);
      log.write(open.closedAt(t0.add(const Duration(hours: 1)), 'owner'));
      final nap = log.add('2026-11-21-110200', kind: 'nap', start: t0.add(const Duration(hours: 2)), source: 'owner_button');
      expect(nap.id, '2026-11-21-110200-2');
      final back = log.read('2026-11-21-110200');
      expect([for (final s in back.spans) s.id], ['2026-11-21-110200-1', '2026-11-21-110200-2']);
      expect(back.spans.first.end, t0.add(const Duration(hours: 1)));
      expect(back.spans.first.endedBy, 'owner');
      expect(back.spans.last.closed, isFalse);
      expect(log.fileOf('2026-11-21-110200').readAsLinesSync(), hasLength(3));
    });

    test('a kill in the middle of a line: the half line is skipped, the rest is read, the next line stands alone', () {
      final log = SpanLog(dir, clock: () => t0);
      final a = log.add('r', kind: 'work', start: t0, source: 'owner_button');
      log.fileOf('r').writeAsStringSync('{"v":1,"span":"r-2","kind":"na', mode: FileMode.append);
      var back = log.read('r');
      expect(back.spans.single.id, a.id);
      expect(back.skipped, 1);
      final b = log.add('r', kind: 'nap', start: t0, source: 'owner_button');
      back = log.read('r');
      expect([for (final s in back.spans) s.id], ['r-1', b.id]);
      expect(back.skipped, 1);
    });

    test('the screen may not write the spans of the recording that runs', () {
      String? active = 'r';
      final screen = SpanLog.screen(dir, active: () => active, clock: () => t0);
      expect(() => screen.add('r', kind: 'sleep', start: t0, source: 'owner_confirmed'), throwsA(isA<SpansBusy>()));
      expect(() => screen.reviewed('r', sleep: false), throwsA(isA<SpansBusy>()));
      expect(screen.fileOf('r').existsSync(), isFalse);
      screen.add('other', kind: 'sleep', start: t0, source: 'owner_confirmed'); // another recording: allowed
      active = null; // stopped
      final s = screen.add('r', kind: 'sleep', start: t0, end: t0.add(const Duration(hours: 7)), source: 'owner_confirmed', estimate: 'est:1');
      expect(s.endedBy, 'owner');
      expect(screen.read('r').spans.single.estimate, 'est:1');
    });

    test('Not sleep and taking it back: the last reviewed line counts', () {
      final log = SpanLog(dir, clock: () => t0);
      log.reviewed('2026-11-20-221706', sleep: false, sets: ['2026-11-20-221706'], hides: ['2026-11-20']);
      var back = log.read('2026-11-20-221706');
      expect(back.reviewed, 'no_sleep');
      expect(back.sets, ['2026-11-20-221706']);
      expect(back.hides, ['2026-11-20']);
      log.reviewed('2026-11-20-221706', sleep: true);
      back = log.read('2026-11-20-221706');
      expect(back.reviewed, 'sleep');
      expect(back.sets, isEmpty);
    });
  });

  test('the running recording in words', () {
    final t = DateTime(2026, 11, 21, 11, 5);
    final work = Span(id: 'r-1', kind: 'work', start: t, source: 'owner_button').closedAt(DateTime(2026, 11, 21, 12, 40), 'owner');
    final sleep = Span(id: 'r-2', kind: 'sleep', start: DateTime(2026, 11, 21, 23, 10), source: 'owner_button');
    expect(
      spansLine([work, sleep], sinceMs: DateTime(2026, 11, 21, 11, 2).millisecondsSinceEpoch),
      'Recording since 11:02 · Work 11:05-12:40 · Sleep since 23:10',
    );
    expect(spansLine(const []), 'nothing marked, so it is not counted as sleep');
    expect(spanWord('dream_catcher'), 'Dream catcher');
    expect(spanWord('some_new_kind'), 'Some new kind');
  });
}
