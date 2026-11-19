// Work sessions on the phone (DECISIONS 446): one JSON file per session in files/work-sessions/, written whole.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/work/store.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> session(DateTime start, {int hints = 1, double minutes = 90}) => {
  'version': workFormatVersion,
  'kind': 'work_session',
  'start': start.toIso8601String(),
  'end': start.add(Duration(seconds: (minutes * 60).round())).toIso8601String(),
  'worn_min': minutes - 5,
  'minutes': {'alert': 60.0, 'getting_drowsy': 10.0, 'drowsy': 5.0, 'unknown': 10.0, 'eyes_closed': 1.0},
  'hints': [
    for (var i = 0; i < hints; i++)
      {'at': start.add(Duration(minutes: 60 + 45 * i)).toIso8601String(), 'reason': 'stretch', 'active_min': 60.0, 'threshold_min': 60.0, 'level': 'alert', 'taken': i == 0},
  ],
  'breaks': [
    {'start': start.add(const Duration(minutes: 61)).toIso8601String(), 'end': start.add(const Duration(minutes: 70)).toIso8601String(), 'source': 'tapped', 'before': 0.8, 'after': 0.2},
  ],
  'ratings': [],
  'epochs': [],
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('work-store'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the folder sits beside recordings/', () {
    expect(workDirFor('/data/files/recordings').path, '/data/files/work-sessions');
  });

  test('save writes <stem>.work.json whole (no .tmp left); list reads them newest first and skips damaged files', () {
    final store = WorkStore(Directory('${tmp.path}/work-sessions'));
    final a = DateTime(2026, 11, 19, 9, 5, 7), b = DateTime(2026, 11, 19, 14);
    store.save(session(a));
    store.save(session(b, hints: 2));
    File('${store.dir.path}/broken.work.json').writeAsStringSync('{');
    expect(store.dir.listSync().map((f) => f.uri.pathSegments.last), isNot(contains(endsWith('.tmp'))));
    expect(File('${store.dir.path}/2026-11-19-090507.work.json').existsSync(), isTrue);
    final list = store.list();
    expect(list.map((s) => s.start), [b, a]);
    expect(list.first.hints, 2);
    expect(list.last.breaks, 1);
    expect(list.last.minutes, closeTo(90, 1e-9));
    expect(list.last.drowsyMin, 15, reason: 'getting drowsy and drowsy');
    // saving again under the same start replaces the file
    store.save(session(a, hints: 0));
    expect(store.list().last.hints, 0);
  });

  test("today's hints of earlier sessions, for the 4-a-day cap", () {
    final store = WorkStore(Directory('${tmp.path}/work-sessions'));
    store.save(session(DateTime(2026, 11, 18, 10), hints: 2));
    store.save(session(DateTime(2026, 11, 19, 9), hints: 2));
    final hints = store.hintsOfDay(DateTime(2026, 11, 19, 15));
    expect(hints, hasLength(2));
    expect(hints.first.at, DateTime(2026, 11, 19, 10));
  });

  test('the file is plain JSON a laptop script can read', () {
    final store = WorkStore(Directory('${tmp.path}/work-sessions'));
    store.save(session(DateTime(2026, 11, 19, 9)));
    final j = jsonDecode(File('${store.dir.path}/2026-11-19-090000.work.json').readAsStringSync()) as Map;
    expect(j['kind'], 'work_session');
    expect(j['version'], workFormatVersion);
  });
}
