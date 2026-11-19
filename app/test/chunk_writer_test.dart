import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads `.f32` with the documented `<I4f` layout (docs/data-format.md), independently of the writer.
List<(int, List<double>)> readF32(File f) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  return [
    for (var o = 0; o + 20 <= b.lengthInBytes; o += 20)
      (b.getUint32(o, Endian.little), [for (var c = 0; c < 4; c++) b.getFloat32(o + 4 + 4 * c, Endian.little)]),
  ];
}

/// Reads `.idx` with the documented `<dQ` layout.
List<(double, int)> readIdx(File f) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  return [
    for (var o = 0; o + 16 <= b.lengthInBytes; o += 16)
      (b.getFloat64(o, Endian.little), b.getUint64(o + 8, Endian.little)),
  ];
}

double f32(double v) => (Float32List(1)..[0] = v)[0];

List<Sample> batch(int firstPack, int n) => [
  for (var i = 0; i < n; i++) (pack: (firstPack + i) % 2048, o1: 1e-5 * i, o2: -2e-5 * i, t3: 0.4, t4: -0.123456789),
];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('chunk_writer_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('file stem and log time use the laptop formats', () {
    final t = DateTime(2026, 11, 8, 2, 4, 3, 7);
    expect(fileStem(t), '2026-11-08-020403');
    expect(logTime(t), '2026-11-08T02:04:03.007');
  });

  test('records and index rows read back with the documented struct layout', () {
    final start = DateTime(2026, 11, 18, 23, 59, 58);
    final w = ChunkWriter.open(dir, start);
    expect(w.stem, '2026-11-18-235958');
    final t1 = DateTime.fromMicrosecondsSinceEpoch(1789000000123456);
    final t2 = t1.add(const Duration(milliseconds: 40));
    w.addBatch(t1, batch(2046, 3)); // packet numbers wrap at 2048, as the headband's do
    w.addBatch(t2, batch(1, 2));
    w.log('connected test', at: start);
    expect(w.append(), 5);
    w.sync();
    w.close();

    final recs = readF32(File('${dir.path}/${w.stem}.f32'));
    expect(recs.map((r) => r.$1), [2046, 2047, 0, 1, 2]);
    expect(recs[1].$2, [f32(1e-5), f32(-2e-5), f32(0.4), f32(-0.123456789)]);
    expect(recs[4].$2[0], f32(1e-5));
    final idx = readIdx(File('${dir.path}/${w.stem}.idx'));
    expect(idx.map((r) => r.$2), [0, 3]);
    expect(idx[0].$1, closeTo(1789000000.123456, 1e-6));
    expect(idx[1].$1 - idx[0].$1, closeTo(0.040, 1e-6));
    expect(File('${dir.path}/${w.stem}.log').readAsStringSync(), '2026-11-18T23:59:58.000 connected test\n');
  });

  test('append adds to the files before sync; nothing is written twice', () {
    final w = ChunkWriter.open(dir, DateTime(2026, 1, 1));
    final f = File('${dir.path}/${w.stem}.f32');
    w.addBatch(DateTime.now(), batch(0, 4));
    expect(f.lengthSync(), 0); // buffered in memory
    w.append();
    expect(f.lengthSync(), 4 * recordBytes);
    w.append();
    w.sync();
    expect(f.lengthSync(), 4 * recordBytes);
    w.close();
    w.close(); // second close is harmless
    w.addBatch(DateTime.now(), batch(4, 1)); // ignored after close
    expect(w.samplesWritten, 4);
  });

  test('two runs in the same second get separate file sets', () {
    final t = DateTime(2026, 11, 18, 1, 2, 3);
    final a = ChunkWriter.open(dir, t)..close();
    final b = ChunkWriter.open(dir, t)..close();
    expect(a.stem, '2026-11-18-010203');
    expect(b.stem, '2026-11-18-010204');
  });

  test('python with numpy reads the files the way scripts/to_bdf.py does', () async {
    final probe = await Process.run('python3', ['-c', 'import numpy']).catchError((_) => ProcessResult(0, 1, '', ''));
    if (probe.exitCode != 0) {
      markTestSkipped('python3 with numpy not available');
      return;
    }
    final w = ChunkWriter.open(dir, DateTime(2026, 11, 18, 3));
    final t0 = DateTime.fromMillisecondsSinceEpoch(1789000000000);
    for (var k = 0; k < 10; k++) {
      w.addBatch(t0.add(Duration(milliseconds: 20 * k)), batch(5 * k, 5));
    }
    w.close();
    // Same dtypes as to_bdf.py's load().
    const code = '''
import json, sys, numpy as np
p = sys.argv[1]
rec = np.fromfile(p + ".f32", dtype=np.dtype([("pack", "<u4"), ("v", "<f4", 4)]))
idx = np.fromfile(p + ".idx", dtype=np.dtype([("t", "<f8"), ("i", "<u8")]))
print(json.dumps({"n": len(rec), "pack": rec["pack"].tolist(), "v1": rec["v"][1].astype(float).tolist(),
                  "t": idx["t"].tolist(), "i": idx["i"].tolist()}))
''';
    final r = await Process.run('python3', ['-I', '-c', code, '${dir.path}/${w.stem}']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    expect(j['n'], 50);
    expect(j['pack'], List.generate(50, (i) => i));
    expect(j['v1'], [f32(1e-5), f32(-2e-5), f32(0.4), f32(-0.123456789)]);
    expect(j['i'], List.generate(10, (k) => 5 * k));
    expect((j['t'] as List).first, closeTo(1789000000.0, 1e-6));
  });

  test('a failed write (storage full) leaves whole records, and close never throws', () {
    final start = DateTime(2026, 11, 19, 23);
    Link('${dir.path}/${fileStem(start)}.idx').createSync('/dev/full');
    final w = ChunkWriter.open(dir, start);
    final t = DateTime.fromMillisecondsSinceEpoch(1789000000000);
    w.addBatch(t, batch(0, 5));
    expect(w.append, throwsA(isA<FileSystemException>()));
    // all or nothing: no sample in the .f32 that the .idx does not cover, and the count says so
    expect(File('${dir.path}/${w.stem}.f32').lengthSync(), 0);
    expect(w.samplesWritten, 0);
    w.log('a line is not worth an exception');
    w.addBatch(t.add(const Duration(milliseconds: 20)), batch(5, 5));
    w.close(); // sync fails inside; the files are closed anyway
    expect(w.isClosed, isTrue);
    expect(File('${dir.path}/${w.stem}.f32').lengthSync() % recordBytes, 0);
  });
}
