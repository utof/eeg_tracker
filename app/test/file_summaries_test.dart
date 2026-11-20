// The read-once tools (DECISIONS 620-629) on a plain folder, with every file read counted: the newest file is found
// without opening any, a file is decoded again only when its size or time changed, a folder's summaries survive a
// new process in files/cache/, and a value over a whole folder is worked out again only when a file changed.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/cache/file_summaries.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/read_count.dart';

void main() {
  // made anew at each use, so that the read counter (installed later) sees them
  late Directory root;
  Directory dir() => Directory('${root.path}/naps');
  File index() => File('${root.path}/cache/naps.json');
  setUp(() {
    root = Directory.systemTemp.createTempSync('file_summaries');
    dir().createSync();
    JsonMemo.clear();
    SummaryIndex.forgetAll();
  });
  tearDown(() => root.deleteSync(recursive: true));

  void put(String name, Object json, {DateTime? at}) {
    final f = File('${dir().path}/$name')..writeAsStringSync(jsonEncode(json));
    if (at != null) f.setLastModifiedSync(at);
  }

  test('the newest file by name, without opening any', () {
    put('2026-11-02-140000.nap.json', {'n': 2});
    put('2026-11-10-090000.nap.json', {'n': 10});
    put('2026-10-30-230000.nap.json', {'n': 0});
    put('2026-11-10-090000.nap.json.tmp', {'n': -1});
    final counts = countReads(addTearDown);
    final files = newestFirst(dir(), '.nap.json');
    expect(files.map((f) => f.uri.pathSegments.last), [
      '2026-11-10-090000.nap.json',
      '2026-11-02-140000.nap.json',
      '2026-10-30-230000.nap.json',
    ]);
    expect(counts.total, 0);
    expect(newestFirst(Directory('${root.path}/none'), '.nap.json'), isEmpty);
  });

  test('the first readable one; each file decoded once while it is unchanged', () {
    put('2026-11-02-140000.nap.json', {'n': 2});
    File('${dir().path}/2026-11-10-090000.nap.json').writeAsStringSync('{cut off');
    final counts = countReads(addTearDown);
    int? n(Object? j) => j is Map ? j['n'] as int? : null;
    expect(firstParsed(newestFirst(dir(), '.nap.json'), n), 2);
    expect(counts.total, 2, reason: 'the damaged newest one, then the next');
    counts.clear();
    expect(firstParsed(newestFirst(dir(), '.nap.json'), n), 2);
    expect(counts.total, 0, reason: 'nothing changed: nothing read');
    put('2026-11-10-090000.nap.json', {'n': 10}, at: DateTime(2026, 11, 10, 9, 30));
    expect(firstParsed(newestFirst(dir(), '.nap.json'), n), 10);
    expect(counts.total, 1, reason: 'only the changed file');
  });

  group('a folder\'s summaries', () {
    var summarized = <String>[];
    Object? summarize(File f) {
      summarized.add(f.uri.pathSegments.last);
      return {'n': (jsonDecode(f.readAsStringSync()) as Map)['n']};
    }

    setUp(() {
      summarized = [];
      for (var d = 1; d <= 5; d++) {
        put('2026-11-0$d-140000.nap.json', {'n': d, 'long': List.filled(200, d)});
      }
    });

    test('each file is summarized once; a new process reads the index and nothing else', () {
      final counts = countReads(addTearDown);
      final first = SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize);
      expect(first.keys.first, '2026-11-05-140000.nap.json', reason: 'newest first');
      expect(first['2026-11-03-140000.nap.json'], {'n': 3});
      expect(summarized, hasLength(5));
      expect(index().existsSync(), isTrue);

      summarized.clear();
      counts.clear();
      expect(SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize), first);
      expect(summarized, isEmpty);
      expect(counts.total, 0, reason: 'the same isolate keeps the index in memory');

      SummaryIndex.forgetAll(); // a new process, or a background isolate
      expect(SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize), first);
      expect(summarized, isEmpty);
      expect(counts.byPath.keys, [index().path], reason: 'only the index');
    });

    test('a changed, a new and a removed file; a damaged index; another version', () {
      final idx = SummaryIndex(index(), version: 1);
      idx.summaries(dir(), '.nap.json', summarize);
      summarized.clear();
      put('2026-11-02-140000.nap.json', {'n': 22}, at: DateTime(2026, 11, 20));
      put('2026-11-06-140000.nap.json', {'n': 6});
      File('${dir().path}/2026-11-01-140000.nap.json').deleteSync();
      final s = idx.summaries(dir(), '.nap.json', summarize);
      expect(summarized..sort(), ['2026-11-02-140000.nap.json', '2026-11-06-140000.nap.json']);
      expect(s['2026-11-02-140000.nap.json'], {'n': 22});
      expect(s.containsKey('2026-11-01-140000.nap.json'), isFalse);

      SummaryIndex.forgetAll();
      index().writeAsStringSync('{"version": 1, "files": {"2026-11-03-140000.nap.json": [1, 2');
      summarized.clear();
      expect(SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize).length, 5);
      expect(summarized, hasLength(5), reason: 'a damaged index is made again');

      SummaryIndex.forgetAll();
      summarized.clear();
      SummaryIndex(index(), version: 2).summaries(dir(), '.nap.json', summarize);
      expect(summarized, hasLength(5), reason: 'summaries of another version are not used');
    });

    test('a file that cannot be read gives nothing and is not read again until it changes', () {
      File('${dir().path}/2026-11-04-140000.nap.json').writeAsStringSync('not json');
      final s = SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize);
      expect(s['2026-11-04-140000.nap.json'], isNull);
      summarized.clear();
      SummaryIndex.forgetAll();
      SummaryIndex(index(), version: 1).summaries(dir(), '.nap.json', summarize);
      expect(summarized, isEmpty);
    });
  });

  test('a value over a whole folder is worked out again only when a file changed', () {
    for (var d = 1; d <= 3; d++) {
      put('2026-11-0$d-100000.work.json', {'n': d});
    }
    final cache = File('${root.path}/cache/work-days.json');
    var computed = 0;
    Object? sum() {
      computed++;
      return [for (final f in newestFirst(dir(), '.work.json')) (jsonDecode(f.readAsStringSync()) as Map)['n']];
    }

    expect(folderValue(File(cache.path), dir(), '.work.json', version: 1, compute: sum), [3, 2, 1]);
    final counts = countReads(addTearDown);
    expect(folderValue(File(cache.path), dir(), '.work.json', version: 1, compute: sum), [3, 2, 1]);
    expect(computed, 1);
    expect(counts.byPath.keys, [cache.path], reason: 'the kept value only');
    put('2026-11-04-100000.work.json', {'n': 4});
    expect(folderValue(File(cache.path), dir(), '.work.json', version: 1, compute: sum), [4, 3, 2, 1]);
    put('2026-11-02-100000.work.json', {'n': 20}, at: DateTime(2026, 11, 20));
    expect(folderValue(File(cache.path), dir(), '.work.json', version: 1, compute: sum), [4, 3, 20, 1]);
    File('${dir().path}/2026-11-01-100000.work.json').deleteSync();
    expect(folderValue(File(cache.path), dir(), '.work.json', version: 1, compute: sum), [4, 3, 20]);
    expect(folderValue(File(cache.path), dir(), '.work.json', version: 2, compute: sum), [4, 3, 20]);
    expect(computed, 5);
  });
}
