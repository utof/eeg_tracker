import 'dart:io';

import 'package:eeg_tracker/recorder/nights.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('nights_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  void make(String name, [int bytes = 20]) => File('${dir.path}/$name').writeAsBytesSync(List.filled(bytes, 0));

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
    expect(first.bytes, 2 * (200 + 16 + 16));
    expect(first.start, DateTime(2026, 11, 18, 23, 12));
    expect(first.folderName, 'eeg-night-2026-11-18');
    expect(nightLabel(first.nightOf), 'Wed 18 Nov');
  });

  test('a missing folder means no nights', () {
    expect(nightsIn(Directory('${dir.path}/absent')), isEmpty);
  });
}
