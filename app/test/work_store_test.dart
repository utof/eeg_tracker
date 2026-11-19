// Work sessions on the phone (DECISIONS 446): one JSON file per session in files/work-sessions/, written whole.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/work/breaks.dart';
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

  group('work review 2026-11-20', () {
    Map<String, Object?> plain(DateTime start, DateTime end, {List<DateTime> hints = const [], double? stretch, String ended = 'stopped'}) => {
      'version': workFormatVersion,
      'kind': 'work_session',
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'ended': ended,
      'stretch_min': ?stretch,
      'hints': [
        for (final h in hints) {'at': h.toIso8601String(), 'reason': 'stretch', 'active_min': 60.0, 'threshold_min': 60.0, 'level': 'alert', 'taken': false},
      ],
      'breaks': [],
      'epochs': [],
    };
    DateTime t(int h, [int m = 0]) => DateTime(2026, 11, 20, h, m);

    test('a Stop for lunch is a break: a hint in the 30 minutes before it counts as followed (finding 7)', () {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(13), hints: [t(10), t(12, 50)]));
      final lunch = store.priorOfDay(t(14));
      expect(lunch.hints.map((h) => h.taken), [false, true], reason: 'the 10:00 hint was long before the Stop');
      expect(lunch.stretchMin, 0);
      expect(BreakPlanner(earlier: lunch.hints).thresholdMin(t(14)), 75, reason: 'only the 10:00 hint backs off');
      // a restart 2 minutes after the Stop is no break
      expect(store.priorOfDay(t(13, 2)).hints.map((h) => h.taken), [false, false]);
      // the file itself is not changed
      expect(WorkSummary.fromJson(jsonDecode(File('${store.dir.path}/2026-11-20-090000.work.json').readAsStringSync()))!.hintList.last.taken, isFalse);
    });

    test('a session that ended under 5 minutes ago hands over its stretch; one longer ago does not (finding 7)', () {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(10), stretch: 42.5, ended: 'running')); // a crash: its last save
      expect(store.priorOfDay(t(10, 4)).stretchMin, 42.5);
      expect(store.priorOfDay(t(10, 6)).stretchMin, 0);
      store.save(plain(t(8), t(8, 30))); // an older file without stretch_min
      expect(store.priorOfDay(t(8, 32)).stretchMin, 0);
    });

    test('Start reads only the files of the last 28 hours, by their names (finding 10)', () {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(10), hints: [t(9, 30)]));
      // a file named for a month ago (its contents claim today: it must not even be opened)
      File('${store.dir.path}/2026-10-20-090000.work.json').writeAsStringSync(jsonEncode(plain(t(9, 5), t(9, 50), hints: [t(9, 40)])));
      expect(store.priorOfDay(t(15)).hints.map((h) => h.at), [t(9, 30)]);
    });

    test('the list is cached by file: an unchanged file is not read again, a changed one is (finding 10)', () async {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(10), hints: [t(9, 30)]));
      final f = File('${store.dir.path}/2026-11-20-090000.work.json');
      expect(store.list().single.hints, 1);
      // the same length and time, other contents: the cached summary stays
      final when = f.lastModifiedSync();
      final text = f.readAsStringSync();
      f.writeAsStringSync(text.replaceAll('"stretch"', '"STRETCH"'));
      f.setLastModifiedSync(when);
      expect(WorkStore(store.dir).list().single.hintList.single.reason, HintReason.stretch, reason: 'not decoded again');
      store.save(plain(t(9), t(10, 30), hints: [t(9, 30), t(10, 20)]));
      expect(store.list().single.hints, 2);
      expect((await store.listAsync()).single.hints, 2);
    });

    test('listAsync decodes in the background and gives what list gives (finding 10)', () async {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(10), hints: [t(9, 30)]));
      store.save(plain(t(14), t(15)));
      File('${store.dir.path}/broken.work.json').writeAsStringSync('{');
      final a = await WorkStore(store.dir).listAsync();
      expect(a.map((s) => s.start), [t(14), t(9)]);
      expect(a.last.hintList.single.at, t(9, 30));
      expect(await WorkStore(Directory('${tmp.path}/none')).listAsync(), isEmpty);
    });

    test('the file is compact JSON (a 10-hour session is a third smaller) (finding 10)', () {
      final store = WorkStore(Directory('${tmp.path}/work-sessions'));
      store.save(plain(t(9), t(10)));
      final text = File('${store.dir.path}/2026-11-20-090000.work.json').readAsStringSync();
      expect(text, isNot(contains('\n')));
      expect(text, startsWith('{"version":'));
    });
  });
}
