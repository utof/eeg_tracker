// Raw recordings packed after a day (lib/recorder/packed.dart, DECISIONS 540-549): lossless, checked before the
// original goes, skipped while a file may still grow, read the same as the plain file by the nights, the sleep
// scorer's layout and the other readers, and sent by Export data and Share on Wi-Fi as they are, naming the `.f32`
// they hold.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/export/exporter.dart';
import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/recorder/packed.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:flutter_test/flutter_test.dart';

String sha(List<int> b) => sha256.convert(b).toString();

/// [n] records of `<I4f`: a packet counter and four noisy channels, like a recording.
Uint8List signal(int n, {int seed = 0}) {
  final r = Random(seed);
  final b = ByteData(n * recordBytes);
  for (var i = 0; i < n; i++) {
    b.setUint32(i * recordBytes, i % 2048, Endian.little);
    for (var c = 0; c < 4; c++) {
      b.setFloat32(i * recordBytes + 4 + 4 * c, (r.nextDouble() - 0.5) * 4e-5 + sin(i / 25) * 3e-5, Endian.little);
    }
  }
  return b.buffer.asUint8List();
}

void main() {
  late Directory tmp, files, rec;
  final now = DateTime(2026, 11, 20, 12);
  final old = now.subtract(const Duration(days: 2));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('packed_test');
    files = Directory('${tmp.path}/files')..createSync();
    rec = Directory('${files.path}/recordings')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A recorder run from [start]: `.f32` ([seconds] of signal), `.idx` (a batch a second), `.log`, all last written at
  /// [at].
  File run(Directory dir, DateTime start, int seconds, {DateTime? at, int seed = 0}) {
    dir.createSync(recursive: true);
    final stem = fileStem(start);
    final f32 = File('${dir.path}/$stem.f32')..writeAsBytesSync(signal(seconds * 250, seed: seed));
    final idx = ByteData(seconds * indexBytes);
    for (var k = 0; k < seconds; k++) {
      idx.setFloat64(k * indexBytes, start.millisecondsSinceEpoch / 1000 + k + 1, Endian.little);
      idx.setUint64(k * indexBytes + 8, k * 250, Endian.little);
    }
    File('${dir.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
    File('${dir.path}/$stem.log').writeAsStringSync('connected\n');
    for (final ext in ['f32', 'idx', 'log']) {
      File('${dir.path}/$stem.$ext').setLastModifiedSync(at ?? old);
    }
    return f32;
  }

  List<String> names(Directory d) => [for (final f in d.listSync()) f.uri.pathSegments.last]..sort();

  group('one file', () {
    test('a packed recording gives back the same bytes, says what it holds and keeps its time', () {
      final f32 = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = f32.readAsBytesSync();
      final p = packRaw(f32);
      expect(f32.existsSync(), isFalse);
      expect(p.packed.path, '${f32.path}.gz');
      expect(p.packedBytes, lessThan(body.length)); // synthetic noise packs little; a real night 40 %
      expect(gzip.decode(p.packed.readAsBytesSync()), body); // a standard gzip file
      final want = PackedInfo(name: '2026-11-18-230000.f32', bytes: body.length, sha256: sha(body), modifiedMs: old.millisecondsSinceEpoch);
      expect(p.info, want);
      expect(packedInfo(p.packed), want);
      expect(p.packed.lastModifiedSync(), old);
      expect(rawExists(f32), isTrue);
      expect(rawOnDisk(f32)!.path, p.packed.path);
      expect(rawLength(f32), body.length);
      expect(readRaw(f32), body);
      final r = openRaw(f32);
      try {
        r.setPositionSync(200000);
        expect(r.readSync(40), body.sublist(200000, 200040));
        r.setPositionSync(20); // back: unpacks again from the start
        expect(r.readSync(20), body.sublist(20, 40));
        r.setPositionSync(body.length - 10);
        expect(r.readSync(100), body.sublist(body.length - 10)); // fewer at the end
        expect(r.readSync(10), isEmpty);
      } finally {
        r.closeSync();
      }
      expect(unpackedDigest(p.packed), (bytes: body.length, sha256: sha(body)));
    });

    test('the header names the file and its time, as gzip -N reads them', () {
      final info = PackedInfo(name: '2026-11-18-230000.f32', bytes: 5, sha256: 'a' * 64, modifiedMs: 1763496000123);
      final h = packedHeader(info);
      expect(h.sublist(0, 4), [0x1f, 0x8b, 8, 8 | 16]);
      expect(ByteData.sublistView(h, 4, 8).getUint32(0, Endian.little), 1763496000);
      expect(latin1.decode(h.sublist(10, 10 + info.name.length)), info.name);
      expect(parsePackedHeader(h), info);
      expect(parsePackedHeader(Uint8List.fromList(gzip.encode([1, 2, 3]))), isNull); // a gzip file without it
      expect(parsePackedHeader(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('a crash before the check leaves the original and nothing else', () {
      final f32 = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = f32.readAsBytesSync();
      final before = names(rec);
      expect(() => packRaw(f32, beforeCheck: (_) => throw StateError('the app was killed')), throwsStateError);
      expect(f32.readAsBytesSync(), body);
      expect(names(rec), before);
    });

    test('a copy that does not give back the same bytes is never used', () {
      final f32 = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = f32.readAsBytesSync();
      void flip(File copy) {
        final b = copy.readAsBytesSync();
        b[b.length ~/ 2] ^= 0xff;
        copy.writeAsBytesSync(b);
      }

      expect(() => packRaw(f32, beforeCheck: flip), throwsA(isA<PackFailure>()));
      expect(f32.readAsBytesSync(), body);
      expect(packedFileOf(f32).existsSync(), isFalse);
      expect(packingTempOf(f32).existsSync(), isFalse);
    });

    test('a file written while it is packed stays plain', () {
      final f32 = run(rec, DateTime(2026, 11, 18, 23), 60);
      void grow(File _) => f32.writeAsBytesSync(List.filled(recordBytes, 0), mode: FileMode.append);
      expect(
        () => packRaw(f32, beforeCheck: grow),
        throwsA(isA<PackFailure>().having((e) => e.message, 'message', contains('changed while it was packed'))),
      );
      expect(f32.lengthSync(), 60 * 250 * recordBytes + recordBytes);
      expect(packedFileOf(f32).existsSync(), isFalse);
    });

    test('a run stopped between the copy and the removal is finished; a wrong copy goes', () {
      final a = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = a.readAsBytesSync();
      final p = packRaw(a);
      a.writeAsBytesSync(body); // as if the original had not been removed yet
      expect(packOne(a.path).packed.path, p.packed.path);
      expect(a.existsSync(), isFalse);
      expect(readRaw(a), body);
      final b = run(rec, DateTime(2026, 11, 19, 1), 60, seed: 1);
      packedFileOf(b).writeAsBytesSync(gzip.encode([1, 2, 3]));
      expect(finishPacking(b), isNull);
      expect(packedFileOf(b).existsSync(), isFalse);
      expect(b.existsSync(), isTrue);
    });
  });

  group('the run between nights', () {
    test('only closed recordings, a day old and big enough, in the recording folders', () {
      final night = run(rec, DateTime(2026, 11, 18, 23), 60);
      final morning = run(Directory('${files.path}/mornings'), DateTime(2026, 11, 19, 7), 60, seed: 1);
      final diy = run(Directory('${files.path}/recordings-diy'), DateTime(2026, 11, 18, 22), 60, seed: 2);
      run(rec, DateTime(2026, 11, 20, 11), 60, at: now.subtract(const Duration(minutes: 5)), seed: 3); // recording
      run(rec, DateTime(2026, 11, 19, 3), 10, seed: 4); // 50 KB
      run(Directory('${files.path}/meditations'), DateTime(2026, 11, 18, 21), 60, seed: 5); // not a recording folder
      expect(packCandidates(files, now).map((f) => f.path), [diy.path, night.path, morning.path]..sort());
    });

    test('it packs one file at a time, stops when something records, and notes what it did', () async {
      final a = run(rec, DateTime(2026, 11, 17, 23), 60);
      final b = run(rec, DateTime(2026, 11, 18, 23), 60, seed: 1);
      final body = a.readAsBytesSync();
      packingTempOf(a).writeAsBytesSync([1, 2]); // left by a run that was killed
      var asked = 0;
      final r = await packOldRecordings(
        files,
        busy: () async => ++asked > 2, // the first check and the first file are free; then a night starts
        pack: (path) async => packOne(path),
        clock: () => now,
      );
      expect(r.packed.map((p) => p.packed.path), ['${a.path}.gz']);
      expect(r.left, 1);
      expect(readRaw(a), body);
      expect(b.existsSync(), isTrue);
      expect(packingTempOf(a).existsSync(), isFalse);
      final log = File('${files.path}/$packingLogName').readAsLinesSync().map(jsonDecode).toList();
      expect(log, hasLength(1));
      expect((log.single as Map)['files'], 1);
      expect(((log.single as Map)['list'] as List).single, containsPair('sha256', sha(body)));
      final idle = await packOldRecordings(files, busy: () async => true, pack: (p) async => packOne(p), clock: () => now);
      expect(idle.packed, isEmpty);
      expect(b.existsSync(), isTrue);
    });

    test('a file that cannot be packed is noted and stays', () async {
      final a = run(rec, DateTime(2026, 11, 18, 23), 60);
      final r = await packOldRecordings(
        files,
        busy: () async => false,
        pack: (path) async => throw const PackFailure('the packed copy does not give back the same bytes'),
        clock: () => now,
      );
      expect(r.failed.single.$1.path, a.path);
      expect(a.existsSync(), isTrue);
      expect(File('${files.path}/$packingLogName').readAsStringSync(), contains('does not give back'));
    });
  });

  group('the readers', () {
    test('the nights, their layout and the scorer\'s inputs read a packed night the same', () {
      final a = run(rec, DateTime(2026, 11, 18, 23), 120);
      run(rec, DateTime(2026, 11, 18, 23, 2, 30), 120, seed: 1);
      List<Object> look() {
        final n = nightsIn(rec).single;
        final layout = joinLayout(n.recordings);
        var sum = 0.0, missing = 0;
        layout.forEachRow((row, gap) {
          sum += row[0] + row[3];
          if (gap) missing++;
        });
        return [
          n.name,
          n.runs,
          n.end,
          [for (final f in n.recordings) f.path],
          SleepScorer.inputsOf(n),
          layout.startUnix,
          layout.samples,
          layout.bad,
          [for (var c = 0; c < 4; c++) layout.channel(c)],
          sum,
          missing,
        ];
      }

      final plain = look();
      packRaw(a);
      expect(names(rec), contains('${a.uri.pathSegments.last}.gz'));
      expect(look(), plain);
    });
  });

  group('leaving the phone', () {
    late Directory out;
    setUp(() => out = Directory('${tmp.path}/Download/EEG')..createSync(recursive: true));

    Future<ExportOutcome> export() =>
        runExport(filesDir: files, target: DirectoryTarget(out), everything: false, clock: () => now);

    Map<String, Map<String, Object?>> manifest() {
      final m = jsonDecode(File('${out.path}/$exportFolderName/manifest.json').readAsStringSync()) as Map;
      return {for (final e in (m['files'] as List).cast<Map<String, Object?>>()) e['path']! as String: e};
    }

    test('a night exported before it was packed is not exported again', () async {
      final a = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = a.readAsBytesSync();
      expect((await export()).files, 3);
      packRaw(a);
      expect(pendingExport(files).files, 0);
      final o = await export();
      expect((o.files, o.complete), (0, true));
      final m = manifest();
      expect(m.keys, contains('recordings/2026-11-18-230000.f32'));
      expect(m['recordings/2026-11-18-230000.f32']!['sha256'], sha(body));
      expect(m['recordings/2026-11-18-230000.f32']!.containsKey('on_phone'), isFalse); // its packed form is here
    });

    test('a night packed before its export leaves as it is, naming the .f32 it holds', () async {
      final a = run(rec, DateTime(2026, 11, 18, 23), 60);
      final body = a.readAsBytesSync();
      final p = packRaw(a);
      expect((await export()).files, 3);
      final row = manifest()['recordings/2026-11-18-230000.f32.gz']!;
      expect(row['sha256'], sha(p.packed.readAsBytesSync()));
      expect(row['original'], {'path': 'recordings/2026-11-18-230000.f32', 'bytes': body.length, 'sha256': sha(body)});
      final copy = File('${out.path}/$exportFolderName/recordings/2026-11-18-230000.f32.gz');
      expect(gzip.decode(copy.readAsBytesSync()), body);
      expect(ExportStore(files).load().files['recordings/2026-11-18-230000.f32.gz']!.original, row['original']);
      expect((await export()).files, 0); // and once only
      final listed = storedFiles(files).firstWhere((f) => f.path.endsWith('.gz'));
      expect(listed.originalJson, row['original']);
      expect(listed.originalPath, 'recordings/2026-11-18-230000.f32');
    });
  });
}
