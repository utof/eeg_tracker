// Every start writes why the process before it ended into files/app-starts.log (lib/start_log.dart, DECISIONS 734):
// all of Android's records the first time, then only the newer ones; a second engine of the same process adds only
// its start; the file rotates past 256 KB; nothing it meets stops a start.
import 'dart:io';

import 'package:eeg_tracker/start_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory files;
  setUp(() => files = Directory.systemTemp.createTempSync('starts'));
  tearDown(() => files.deleteSync(recursive: true));

  final asked = <int>[];
  Future<List<String>> Function(int) exits(List<String> lines) => (since) async {
    asked.add(since);
    return lines;
  };
  setUp(asked.clear);

  String log() => File('${files.path}/$startLogName').readAsStringSync();
  DateTime at(int h, int m) => DateTime(2026, 11, 20, h, m);

  test('the first start writes every exit Android still has; the next process only the newer ones', () async {
    await logStart(
      files.path,
      engine: 'screen',
      processId: 100,
      clock: () => at(9, 0),
      exitReasons: exits(['2026-11-19T23:47:00 freezer status 0 importance 400', '2026-11-20T08:59:00 user-requested status 0 importance 100']),
    );
    expect(asked, [0], reason: 'the first start asks for everything');
    expect(log(), contains('2026-11-20T09:00:00.000 start: screen engine, process 100\n'));
    expect(log(), contains('previous process ended: 2026-11-19T23:47:00 freezer status 0 importance 400\n'));
    expect(log(), contains('previous process ended: 2026-11-20T08:59:00 user-requested'));

    // the recorder's service starts in the same process: its start only
    final again = await logStart(files.path, engine: 'recorder', processId: 100, clock: () => at(9, 5), exitReasons: exits(['x']));
    expect(again, ['start: recorder engine, process 100 (already running)']);
    expect(asked, [0], reason: 'not asked again inside one process');

    // a new process after an update: only exits since the last start written
    await logStart(files.path, engine: 'screen', processId: 200, clock: () => at(10, 0), exitReasons: exits(['2026-11-20T09:59:00 other status 0 importance 400 (package updated)']));
    expect(asked.last, at(9, 0).millisecondsSinceEpoch);
    expect(log().split('\n').where((l) => l.contains('previous process ended')), hasLength(3));
    expect(log(), contains('09:59:00 other status 0 importance 400 (package updated)'));
  });

  test('a start with nothing from Android says so; an unreadable answer is a line, not a failure', () async {
    await logStart(files.path, engine: 'screen', processId: 1, clock: () => at(9, 0), exitReasons: exits(const []));
    expect(log(), contains('previous process ended: no record from Android since the last start'));
    await logStart(files.path, engine: 'screen', processId: 2, clock: () => at(9, 1), exitReasons: (_) async => throw StateError('no channel'));
    expect(log(), contains('previous process ended: not readable (Bad state: no channel)'));
  });

  test('past 256 KB the log moves to app-starts.1.log; the one before that goes', () async {
    final f = File('${files.path}/$startLogName')..writeAsStringSync('old\n' * (startLogMaxBytes ~/ 4 + 1));
    File('${files.path}/$startLogOlderName').writeAsStringSync('older\n');
    await logStart(files.path, engine: 'screen', processId: 1, clock: () => at(9, 0), exitReasons: exits(const []));
    expect(File('${files.path}/$startLogOlderName').readAsStringSync(), startsWith('old\n'));
    expect(f.lengthSync(), lessThan(1000));
    expect(f.readAsStringSync(), startsWith('2026-11-20T09:00:00.000 start: screen engine'));
  });

  test('a damaged memory of the last start is a first start again; a folder that cannot be written loses the lines', () async {
    Directory('${files.path}/cache').createSync();
    File('${files.path}/cache/app-starts.json').writeAsStringSync('{"last_ms": ');
    await logStart(files.path, engine: 'screen', processId: 7, clock: () => at(9, 0), exitReasons: exits(const []));
    expect(asked, [0]);
    final lines = await logStart('/proc/no-such-folder', engine: 'screen', processId: 8, exitReasons: exits(const []));
    expect(lines, isNotEmpty, reason: 'returned all the same; nothing thrown');
  });
}
