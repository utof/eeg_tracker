// The app's own records (DECISIONS 710-711): file names, the writer (day files, parts, a restarted engine, a deleted
// file), pruning by days and bytes without touching a file another engine may hold open, and the one logging API
// (levels, facts, errors, the lines before the folder is known, debugPrint, Flutter's errors, the switches).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/export/store.dart' show isExported;
import 'package:eeg_tracker/logs/activity.dart';
import 'package:eeg_tracker/logs/files.dart';
import 'package:eeg_tracker/logs/log.dart';
import 'package:eeg_tracker/logs/settings.dart';
import 'package:eeg_tracker/logs/usage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, Object?>> _lines(File f) => [
  for (final l in f.readAsLinesSync()) jsonDecode(l) as Map<String, Object?>,
];

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('logs_files');
    Activity.reset();
    Usage.reset();
  });
  tearDown(() async {
    await Logs.reset();
    Activity.reset();
    Usage.reset();
    tmp.deleteSync(recursive: true);
  });

  group('names', () {
    test('a kind, a day, an engine and a part; anything else is not a log file', () {
      expect(logFileName(LogKind.app, '2026-11-20', 'screen'), 'app-2026-11-20-screen.jsonl');
      expect(logFileName(LogKind.metrics, '2026-11-20', 'recorder', 3), 'metrics-2026-11-20-recorder-3.jsonl');
      final n = parseLogFileName('usage-2026-11-20-auto-2.jsonl')!;
      expect((n.kind, n.day, n.engine, n.part), (LogKind.usage, '2026-11-20', 'auto', 2));
      expect(parseLogFileName('settings.json'), isNull);
      expect(parseLogFileName('app-2026-11-20-screen.jsonl.tmp'), isNull);
      expect(parseLogFileName('night-2026-11-20-screen.jsonl'), isNull);
    });

    test('times are local with milliseconds and the offset', () {
      final t = DateTime(2026, 11, 20, 14, 31, 2, 123);
      expect(logTime(t), startsWith('2026-11-20T14:31:02.123'));
      expect(DateTime.parse(logTime(t)).isAtSameMomentAs(t), isTrue);
    });

    test('the folder leaves the phone with Export data and Share on Wi-Fi', () {
      expect(isExported('logs/app-2026-11-20-screen.jsonl'), isTrue);
      expect(isExported('logs/settings.json'), isTrue);
    });
  });

  group('the writer', () {
    test('one JSON line per entry; a new file each day; a NaN or infinity becomes null', () {
      var now = DateTime(2026, 11, 20, 23, 59, 50);
      final w = JsonlWriter(tmp, LogKind.app, 'screen', clock: () => now);
      w.write({'msg': 'a', 'x': double.infinity, 'ohms': {'O1': double.nan, 'O2': 1200.0}});
      now = DateTime(2026, 11, 21, 0, 0, 5);
      w.write({'msg': 'b', 'at': DateTime(2026, 11, 21), 'took': const Duration(seconds: 2)});
      w.close();
      final day1 = _lines(File('${tmp.path}/app-2026-11-20-screen.jsonl'));
      expect(day1.single, {'msg': 'a', 'x': null, 'ohms': {'O1': null, 'O2': 1200.0}});
      final day2 = _lines(File('${tmp.path}/app-2026-11-21-screen.jsonl')).single;
      expect(day2['msg'], 'b');
      expect(day2['at'], startsWith('2026-11-21T00:00:00.000'));
      expect(day2['took'], 2000);
      expect(w.lost, 0);
    });

    test('over the part size the next part starts; a restarted engine continues the last part', () {
      final now = DateTime(2026, 11, 20, 10);
      final w = JsonlWriter(tmp, LogKind.usage, 'screen', clock: () => now, partBytes: 200);
      for (var i = 0; i < 10; i++) {
        w.write({'ev': 'tap', 'i': i, 'pad': 'x' * 40});
      }
      w.close();
      final names = [for (final f in logFiles(tmp)) f.uri.pathSegments.last];
      expect(names.first, 'usage-2026-11-20-screen.jsonl');
      expect(names.length, greaterThan(2));
      for (final f in logFiles(tmp)) {
        expect(f.lengthSync(), lessThanOrEqualTo(200));
      }
      final again = JsonlWriter(tmp, LogKind.usage, 'screen', clock: () => now, partBytes: 200);
      again.write({'ev': 'tap', 'i': 10});
      expect(again.path, endsWith(names.last));
      again.close();
      final all = [for (final f in logFiles(tmp)) ..._lines(f)];
      expect([for (final l in all) l['i']], List.generate(11, (i) => i));
    });

    test('a file deleted under it (the Delete button in another engine): a new one within 10 seconds', () {
      var now = DateTime(2026, 11, 20, 10);
      final w = JsonlWriter(tmp, LogKind.app, 'recorder', clock: () => now);
      w.write({'msg': 'before'});
      File(w.path!).deleteSync();
      now = now.add(const Duration(seconds: 11));
      w.write({'msg': 'after'});
      w.close();
      expect(_lines(File('${tmp.path}/app-2026-11-20-recorder.jsonl')).single['msg'], 'after');
    });

    test('a folder it cannot write is counted, never thrown', () {
      final file = File('${tmp.path}/not-a-folder')..writeAsStringSync('x');
      final w = JsonlWriter(Directory(file.path), LogKind.app, 'screen');
      w.write({'msg': 'lost'});
      expect(w.lost, 1);
    });
  });

  group('pruning', () {
    File put(String name, int bytes, DateTime modified) =>
        File('${tmp.path}/$name')
          ..writeAsBytesSync(List.filled(bytes, 120))
          ..setLastModifiedSync(modified);

    test('past its days a kind\'s file goes; the usage log stays longer; an open file never goes', () {
      final now = DateTime(2026, 11, 20, 12);
      final old = now.subtract(const Duration(days: 20));
      put('app-2026-11-10-screen.jsonl', 10, old);
      put('app-2026-11-19-screen.jsonl', 10, old);
      put('usage-2026-11-10-screen.jsonl', 10, old);
      // a file from 9 days ago still written in the last minutes (a clock moved back): kept
      put('app-2026-11-11-recorder.jsonl', 10, now.subtract(const Duration(minutes: 2)));
      put('settings.json', 10, old);
      expect(pruneLogs(tmp, now), 1);
      final left = tmp.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(left, {'app-2026-11-19-screen.jsonl', 'usage-2026-11-10-screen.jsonl', 'app-2026-11-11-recorder.jsonl', 'settings.json'});
    });

    test('over its bytes the oldest of the kind go first', () {
      final now = DateTime(2026, 11, 20, 12);
      final mb = 1 << 20;
      for (var d = 14; d <= 19; d++) {
        put('app-2026-11-$d-screen.jsonl', 5 * mb, now.subtract(const Duration(hours: 1)));
      }
      put('metrics-2026-11-14-screen.jsonl', 5 * mb, now.subtract(const Duration(hours: 1)));
      pruneLogs(tmp, now);
      final app = logFiles(tmp, kind: LogKind.app).map((f) => f.uri.pathSegments.last).toList();
      expect(app, [for (final d in [16, 17, 18, 19]) 'app-2026-11-$d-screen.jsonl']);
      expect(logFiles(tmp, kind: LogKind.metrics), hasLength(1));
      expect(logSizes(tmp)[LogKind.app], (files: 4, bytes: 20 * mb));
    });

    test('Delete takes one kind and leaves the rest', () {
      final now = DateTime(2026, 11, 20);
      put('app-2026-11-20-screen.jsonl', 10, now);
      put('usage-2026-11-20-screen.jsonl', 10, now);
      expect(deleteLogs(tmp, {LogKind.usage}), 1);
      expect(logFiles(tmp).map((f) => f.uri.pathSegments.last), ['app-2026-11-20-screen.jsonl']);
    });
  });

  group('the logging API', () {
    test('lines before the folder is known are kept and written first; fine lines only when detailed', () async {
      final now = DateTime(2026, 11, 20, 9);
      final logs = Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false, clock: () => now);
      final log = AppLog('recorder');
      log.info('early', {'n': 1});
      log.fine('detail');
      logs.attach(tmp);
      log.warn('drop', data: {'why': 'out of range'});
      final lines = _lines(File('${tmp.path}/app-2026-11-20-screen.jsonl'));
      expect([for (final l in lines) l['msg']], ['early', 'drop']);
      expect(lines.first, containsPair('sub', 'recorder'));
      expect(lines.first, containsPair('level', 'info'));
      expect(lines.first['data'], {'n': 1});
      expect(lines.last, containsPair('level', 'warn'));
      logs.saveSettings(const LogSettings(detailed: true));
      log.fine('now kept');
      expect(_lines(File('${tmp.path}/app-2026-11-20-screen.jsonl')).last['msg'], 'now kept');
      expect(LogSettings.load(tmp).detailed, isTrue);
    });

    test('an error carries its error, a short stack, the screen and what is on', () async {
      final logs = Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false)..attach(tmp);
      Usage.view('MeditationScreen');
      Activity.begin('session:Meditation');
      try {
        throw StateError('boom');
      } catch (e, st) {
        AppLog('sessions').error('could not save', error: e, stack: st, data: {'file': 'x'});
      }
      final l = _lines(logFiles(tmp, kind: LogKind.app).single).last;
      expect(l['level'], 'error');
      expect(l['error'], contains('boom'));
      expect(l['stack'], isA<String>());
      expect(l['screen'], 'MeditationScreen');
      expect(l['on'], ['session:Meditation']);
      expect(logs.screen, 'MeditationScreen');
    });

    test('timed: how long it took, or the failure with its time; rethrown', () async {
      Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false).attach(tmp);
      final log = AppLog('scoring');
      expect(await log.timed('score', () async => 42), 42);
      await expectLater(log.timed('score', () async => throw const FormatException('bad')), throwsFormatException);
      final lines = _lines(logFiles(tmp, kind: LogKind.app).single);
      expect(lines[0]['msg'], startsWith('score took '));
      expect((lines[0]['data'] as Map)['ms'], isA<int>());
      expect(lines[1], containsPair('level', 'error'));
      expect(lines[1]['msg'], startsWith('score failed after'));
    });

    test('debugPrint lands in the log as "print", at most 120 lines a minute; stop puts debugPrint back', () async {
      final before = debugPrint;
      final logs = Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false)..attach(tmp);
      for (var i = 0; i < 130; i++) {
        debugPrint('line $i');
      }
      final lines = _lines(logFiles(tmp, kind: LogKind.app).single);
      expect(lines, hasLength(printsPerMinute));
      expect(lines.first, containsPair('sub', 'print'));
      await logs.stop();
      expect(debugPrint, same(before));
    });

    test('Flutter errors and uncaught errors are logged and still reach the handlers before', () async {
      final seen = <FlutterErrorDetails>[];
      final flutterBefore = FlutterError.onError;
      final FlutterExceptionHandler handler = seen.add;
      FlutterError.onError = handler;
      try {
        final logs = Logs.start(engine: 'screen', recordingsDir: () async => null, capturePrint: false)..attach(tmp);
        FlutterError.reportError(FlutterErrorDetails(exception: Exception('layout'), library: 'rendering library'));
        expect(seen, hasLength(1));
        final l = _lines(logFiles(tmp, kind: LogKind.app).single).single;
        expect(l['msg'], 'Flutter error in rendering library');
        expect(l['error'], contains('layout'));
        await logs.stop();
        expect(FlutterError.onError, same(handler)); // put back as it was
      } finally {
        FlutterError.onError = flutterBefore;
      }
    });

    test('a library\'s own logger (package:logging, as flutter_soloud uses) lands under its name', () async {
      Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false).attach(tmp);
      AppLog('🎶 flutter_soloud').warn('device lost');
      expect(_lines(logFiles(tmp, kind: LogKind.app).single).single['sub'], '🎶 flutter_soloud');
    });

    test('usage lines stop while "Record how I use the app" is off', () async {
      final logs = Logs.start(engine: 'screen', recordingsDir: () async => null, catchErrors: false)..attach(tmp);
      Usage.tap(control: 'FilledButton', label: 'Start night');
      logs.saveSettings(const LogSettings(usage: false));
      Usage.tap(control: 'FilledButton', label: 'Stop');
      final lines = _lines(logFiles(tmp, kind: LogKind.usage).single);
      expect([for (final l in lines) l['label']], ['Start night']);
    });

    test('a broken settings file means the defaults: usage and battery on, not detailed', () {
      File('${tmp.path}/settings.json').writeAsStringSync('{not json');
      final s = LogSettings.load(tmp);
      expect((s.usage, s.battery, s.detailed), (true, true, false));
    });
  });

  group('activity', () {
    test('counted holders; one start and one stop with its length go to the listeners', () {
      var now = DateTime(2026, 11, 20, 10);
      Activity.clock = () => now;
      final told = <(String, bool, Duration?)>[];
      Activity.listen((f, on, d) => told.add((f, on, d)));
      Activity.begin('share');
      Activity.begin('share');
      now = now.add(const Duration(minutes: 5));
      Activity.end('share');
      expect(Activity.isOn('share'), isTrue);
      Activity.end('share');
      Activity.end('share'); // one too many: nothing
      Activity.set('signal', on: true);
      Activity.set('signal', on: true);
      expect(Activity.active, ['signal']);
      expect(told, [('share', true, null), ('share', false, const Duration(minutes: 5)), ('signal', true, null)]);
      expect(featureLabel('session:Meditation'), 'Meditation session');
      expect(featureLabel('signal'), 'Signal tab');
    });
  });
}
