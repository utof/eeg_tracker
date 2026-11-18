import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nights_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  void make(String name, [int bytes = 20]) => File('${dir.path}/$name').writeAsBytesSync(List.filled(bytes, 0));

  DateTime at(int day, double hour) =>
      DateTime(2026, 11, day).add(Duration(microseconds: (hour * 3600 * 1e6).round()));

  /// A run from [start] whose last batch arrives at [end] (one .idx row), with a few samples.
  void run(DateTime start, DateTime end, {bool log = true}) {
    final stem = fileStem(start);
    make('$stem.f32', 200);
    final idx = ByteData(16)
      ..setFloat64(0, end.microsecondsSinceEpoch / 1e6, Endian.little)
      ..setUint64(8, 0, Endian.little);
    File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
    if (log) make('$stem.log', 16);
  }

  test('a file name gives its run start; other names give null', () {
    expect(stemTime('2026-11-18-231200.f32'), DateTime(2026, 11, 18, 23, 12));
    expect(stemTime('2026-11-19-031455.log'), DateTime(2026, 11, 19, 3, 14, 55));
    expect(stemTime('2026-11-19-031455.markers.jsonl'), DateTime(2026, 11, 19, 3, 14, 55));
    expect(stemTime('2026-13-19-031455.f32'), isNull); // month 13 must not roll over into the next year
    expect(stemTime('notes.txt'), isNull);
    expect(stemTime('2026-11-19-0314.f32'), isNull);
  });

  test('runs from evening to morning are one night; the next evening starts another', () {
    for (final stem in ['2026-11-18-231200', '2026-11-19-031455', '2026-11-19-221000']) {
      for (final ext in ['f32', 'idx', 'log']) {
        make('$stem.$ext', ext == 'f32' ? 200 : 16);
      }
    }
    make('stray.txt');

    final nights = nightsIn(dir);
    expect(nights.map((n) => n.nightOf), [DateTime(2026, 11, 19), DateTime(2026, 11, 18)]); // newest first
    final first = nights.last;
    expect(first.runs, 2);
    expect(first.files.map((f) => f.uri.pathSegments.last), [
      '2026-11-18-231200.f32',
      '2026-11-18-231200.idx',
      '2026-11-18-231200.log',
      '2026-11-19-031455.f32',
      '2026-11-19-031455.idx',
      '2026-11-19-031455.log',
    ]);
    expect(first.recordings.map((f) => f.uri.pathSegments.last), ['2026-11-18-231200.f32', '2026-11-19-031455.f32']);
    expect(first.bytes, 2 * (200 + 16 + 16));
    expect(first.start, DateTime(2026, 11, 18, 23, 12));
    expect(first.folderName, 'eeg-night-2026-11-18');
    expect(first.name, '2026-11-18');
    expect(nightLabel(first.nightOf), 'Wed 18 Nov');
  });

  test('nights chain as in night_files.py: a late-morning sleep joins the night before it', () {
    // the cases of analysis/tests/test_sleep_report.py
    run(at(17, 23), at(18, 2));
    run(at(18, 2.1), at(18, 7.5));
    run(at(18, 9), at(18, 14.3)); // 1.5 h later: same night (noon-to-noon would split it off)
    run(at(18, 18), at(18, 19)); // 3.7 h later and after noon: the next night
    run(at(18, 23.5), at(19, 7)); // 4.5 h later but the same evening date: joins it
    final nights = nightsIn(dir);
    expect([for (final n in nights) (n.name, n.recordings.length)], [('2026-11-18', 2), ('2026-11-17', 3)]);
    expect(nights.last.end, at(18, 14.3));
  });

  test('a night never takes a recording 24 hours or more after its first one', () {
    for (var k = 0; k < 14; k++) {
      run(at(17, 9 + 2.0 * k), at(17, 11 + 2.0 * k));
    }
    expect([for (final n in nightsIn(dir)) (n.name, n.recordings.length)], [('2026-11-17', 2), ('2026-11-16', 12)]);
  });

  test('a run without samples joins the night it falls in, or one of its own', () {
    run(at(17, 23), at(18, 2));
    make('${fileStem(at(18, 3))}.log', 30); // a reconnect run that never got data
    make('${fileStem(at(18, 3))}.f32', 0);
    make('${fileStem(at(20, 22))}.log', 30); // a failed start two days later
    final nights = nightsIn(dir);
    expect([for (final n in nights) (n.name, n.files.length, n.recordings.length)], [
      ('2026-11-20', 1, 0),
      ('2026-11-17', 5, 1),
    ]);
  });

  test('a missing folder means no nights', () {
    expect(nightsIn(Directory('${dir.path}/absent')), isEmpty);
  });
}
