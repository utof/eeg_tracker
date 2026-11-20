// The recording header (lib/recorder/header.dart; docs/data-format.md "The recording header"; DECISIONS 630-639): a
// record carries any number of channels, every recording says what it holds, files from before the header read as they
// did, and a feature that needs particular sites picks them by name or refuses in words.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/morning/result.dart' show readCheckInRecording;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/nights.dart' show nightsIn;
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/prep.dart' show prepareNight;
import 'package:flutter_test/flutter_test.dart';

double f32(double v) => (Float32List(1)..[0] = v)[0];

/// Channel c of sample i, in volts: distinct for every channel and sample, so a channel read from the wrong place shows.
double volt(int i, int c) => (c + 1) * 1e-4 + i * 1e-7;

/// Reads a `.f32` with `<I` + n `<f` records, independently of the app's readers.
List<(int, List<double>)> readRecords(File f, int n) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  final size = 4 + 4 * n;
  return [
    for (var o = 0; o + size <= b.lengthInBytes; o += size)
      (b.getUint32(o, Endian.little), [for (var c = 0; c < n; c++) b.getFloat32(o + 4 + 4 * c, Endian.little)]),
  ];
}

List<String> chNames(int n) => [for (var c = 1; c <= n; c++) 'Ch$c'];

/// A recording of [samples] samples with [header]'s channels, 250 a second from [start], one `.idx` row a second.
File record(Directory dir, DateTime start, RecordingHeader header, {int samples = 500}) {
  final w = ChunkWriter.open(dir, start, header: header);
  final t0 = start.microsecondsSinceEpoch;
  for (var k = 0; k * 250 < samples; k++) {
    final n = (samples - k * 250).clamp(0, 250);
    w.addBatch(DateTime.fromMicrosecondsSinceEpoch(t0 + (k + 1) * 1000000), [
      for (var i = k * 250; i < k * 250 + n; i++) Sample(i, [for (var c = 0; c < header.count; c++) volt(i, c)]),
    ]);
  }
  w.close();
  return File('${dir.path}/${w.stem}.f32');
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('recording_header_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('the header itself', () {
    for (final m in [brainBitMontage(), helmetPlan8(), helmetPlan16()]) {
      test('${m.count} channels: written and read back the same', () {
        final h = headerForMontage(m, device: 'test');
        expect(h.count, m.count);
        expect(h.record, '<I${m.count}f');
        expect(h.recordBytes, 4 + 4 * m.count);
        final back = RecordingHeader.decode(h.encode());
        expect(back, h);
        expect(back.names, m.names);
        expect(back.source, HeaderSource.file);
        final j = jsonDecode(h.encode()) as Map<String, Object?>;
        expect(j['format'], 'eeg-tracker-recording');
        expect(j['version'], 1);
        expect(j['unit'], 'V');
        expect((j['channels']! as List).length, m.count);
      });
    }

    test('the BrainBit: O1 O2 T3 T4 (sites O1 O2 T7 T8) at 250 Hz, its forehead reference, its packet number', () {
      final j = jsonDecode(brainBitHeader.encode()) as Map<String, Object?>;
      expect([for (final c in j['channels']! as List) (c as Map)['name']], ['O1', 'O2', 'T3', 'T4']);
      expect([for (final c in j['channels']! as List) (c as Map)['site']], ['O1', 'O2', 'T7', 'T8']);
      for (final c in j['channels']! as List) {
        final xyz = ((c as Map)['xyz']! as List).cast<num>();
        expect(xyz[0] * xyz[0] + xyz[1] * xyz[1] + xyz[2] * xyz[2], closeTo(1, 1e-3)); // a direction on the head
      }
      expect(j['reference'], {'name': 'Ref', 'where': 'forehead', 'site': 'Fpz'});
      expect(j['ground'], isNull);
      expect(j['sample_rate'], 250);
      expect(j['record'], '<I4f');
      expect(j['counter'], 'packet number');
      expect(j['device'], 'BrainBit');
    });

    test('the DIY board: its names, the earlobes, a custom place from the positions file', () {
      final m = withPositions(diyBoardMontage(const ['O1', 'O2', 'X1', 'Fp1']), parsePositions('X1 60 30\n'));
      final h = headerForMontage(m, device: 'DIY board', sampleRate: 500, counter: counterSequence);
      final j = jsonDecode(h.encode()) as Map<String, Object?>;
      final x1 = (j['channels']! as List)[2] as Map;
      expect(x1['name'], 'X1');
      expect(x1['site'], isNull);
      final want = fromAngles(60, 30);
      expect((x1['xyz']! as List).cast<num>(), [closeTo(want.x, 1e-4), closeTo(want.y, 1e-4), closeTo(want.z, 1e-4)]);
      expect(j['reference'], {'name': 'Ref', 'where': 'an earlobe', 'site': 'A1'});
      expect(j['ground'], {'name': 'Bias', 'where': 'the other earlobe', 'site': 'A2'});
      expect(j['sample_rate'], 500);
      expect(j['counter'], 'board sequence number');
    });

    test('a header that breaks a rule is refused in words naming the file; unknown fields are ignored', () {
      Map<String, Object?> good() =>
          jsonDecode(headerForMontage(helmetPlan8(), device: 'x').encode()) as Map<String, Object?>;
      Matcher says(String s) =>
          throwsA(isA<HeaderError>().having((e) => '$e', 'text', allOf(contains('the.header.json'), contains(s))));
      RecordingHeader read(Object? j) => RecordingHeader.fromJson(j, where: 'the.header.json');
      expect(() => read(good()..['version'] = 2), says('newer version of the app'));
      expect(() => read(good()..['format'] = 'other'), says('not an eeg-tracker-recording header'));
      expect(() => read(good()..['record'] = '<I4f'), says('does not match 8 channels (<I8f)'));
      expect(() => read(good()..['unit'] = 'uV'), says('volts'));
      expect(() => read(good()..['sample_rate'] = 0), says('sample_rate'));
      expect(() => read(good()..['channels'] = []), says('1 to 64 channels'));
      final twice = good();
      (twice['channels']! as List)[1] = {'name': 'M1'};
      expect(() => read(twice), says('M1 appears twice'));
      final badXyz = good();
      (badXyz['channels']! as List)[0] = {
        'name': 'M1',
        'xyz': [1, 2],
      };
      expect(() => read(badXyz), says('xyz'));
      expect(
        () => RecordingHeader.decode('{"format": ', where: 'the.header.json'),
        throwsA(isA<HeaderError>().having((e) => '$e', 'text', contains('not valid JSON'))),
      );
      expect(read(good()..['later'] = {'anything': 1}).count, 8);
    });

    test('channels by name: exact first, else the 10-10 site (T7 for T3, any case); a missing one is named', () {
      final h = RecordingHeader(
        channels: [
          for (final n in ['Fz', 'o2', 'T8', 'O1', 'T7', 'Pz']) HeaderChannel(n, site: standardName(n)),
        ],
      );
      expect(h.pick(sleepSites, who: 'The sleep model'), [3, 1, 4, 2]);
      expect(mapping(h, sleepSites, who: 'x'), [3, 1, 4, 2]);
      expect(mapping(brainBitHeader, sleepSites, who: 'x'), isNull); // in order already: rows read as they are
      final plan = headerForMontage(helmetPlan8(), device: 'helmet');
      expect(
        () => plan.pick(sleepSites, who: 'The sleep model'),
        throwsA(
          isA<MissingSites>()
              .having((e) => e.missing, 'missing', ['O1', 'O2', 'T3', 'T4'])
              .having(
                (e) => '$e',
                'text',
                'The sleep model needs O1 O2 T3 T4; this recording (helmet: M1 M2 F7 F8 Fz C3 C4 Pz) has no O1, O2, T3, T4.',
              ),
        ),
      );
    });
  });

  group('the files', () {
    for (final n in [4, 8, 16]) {
      test('$n channels: the writer writes its header first and $n floats a record; read back by the header', () {
        final h = RecordingHeader(channels: [for (final s in chNames(n)) HeaderChannel(s)], device: 'test');
        final f = record(dir, DateTime(2026, 11, 20, 23), h, samples: 300);
        final hf = File('${dir.path}/2026-11-20-230000.header.json');
        expect(hf.existsSync(), isTrue);
        expect(readHeader(f), h);
        expect(f.lengthSync(), 300 * (4 + 4 * n));
        expect(recordsIn(f), 300);
        final recs = readRecords(f, n);
        expect(recs.map((r) => r.$1), [for (var i = 0; i < 300; i++) i]);
        for (final i in [0, 17, 299]) {
          expect(recs[i].$2, [for (var c = 0; c < n; c++) f32(volt(i, c))]);
        }
        // every channel by name, through the night reader
        final layout = joinLayout([f], names: chNames(n), who: 'a test');
        expect(layout.names, chNames(n));
        for (final c in [0, n - 1]) {
          expect(layout.channel(c)[5], closeTo(f32(volt(5, c)) * 1e6, 1e-9));
        }
      });
    }

    test('a new BrainBit recording is byte for byte the old <I4f record, plus its header', () {
      final f = record(dir, DateTime(2026, 11, 20, 23), brainBitHeader, samples: 50);
      final want = ByteData(50 * 20);
      for (var i = 0; i < 50; i++) {
        want.setUint32(i * 20, i, Endian.little);
        for (var c = 0; c < 4; c++) {
          want.setFloat32(i * 20 + 4 + 4 * c, volt(i, c), Endian.little);
        }
      }
      expect(f.readAsBytesSync(), want.buffer.asUint8List());
      expect(readHeader(f).names, ['O1', 'O2', 'T3', 'T4']);
    });

    test('a sample of another width than the header\'s is refused: the file never holds a record its header does not describe', () {
      final w = ChunkWriter.open(dir, DateTime(2026, 11, 20, 23), header: headerForMontage(helmetPlan8(), device: 'x'));
      expect(() => w.addBatch(DateTime.now(), [Sample.four(pack: 1, o1: 0, o2: 0, t3: 0, t4: 0)]), throwsArgumentError);
      w.close();
      expect(File('${dir.path}/${w.stem}.f32').lengthSync(), 0);
    });

    test('an 8-channel sample has no O1..T4 fields: asking is an error, never another channel', () {
      final s = Sample(1, List.filled(8, 0.0));
      expect(() => s.o1, throwsStateError);
      expect(s.inOrder([3, 2, 1, 0]).channels, 4);
    });

    test('files from before the header read as they did: the sleep fixture, as the BrainBit', () {
      final f = File('test/fixtures/sleep_night/2026-11-24-001200.f32');
      final h = readHeader(f);
      expect(h.source, HeaderSource.legacy);
      expect(h.names, ['O1', 'O2', 'T3', 'T4']);
      expect(h.recordBytes, 20);
      expect(h.sampleRate, 250);
      expect(recordsIn(f), f.lengthSync() ~/ 20);
      final layout = joinLayout([f]);
      final raw = readRecords(f, 4);
      final at = layout.parts.firstWhere((p) => p.run != null).at; // the night starts at a whole second
      expect(layout.channel(2)[at + 10], closeTo(raw[10].$2[2] * 1e6, 1e-6));
    });

    test('a DIY file set from before the header: its .log\'s format line gives the width, the names and the rate', () {
      final stem = '${dir.path}/2026-11-19-230000';
      File('$stem.log').writeAsStringSync(
        '2026-11-19T23:00:00.000 driver DIY board ...\n'
        '2026-11-19T23:00:00.001 format .f32 records <I8f: board sequence number, then A B C D E F G H in volts; 500 Hz\n',
      );
      File('$stem.f32').writeAsBytesSync(Uint8List(36 * 10));
      final h = readHeader(File('$stem.f32'));
      expect(h.source, HeaderSource.log);
      expect(h.names, ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
      expect(h.sampleRate, 500);
      expect(h.counter, counterSequence);
      expect(recordsIn(File('$stem.f32')), 10);
      File('$stem.log')
          .writeAsStringSync('format .f32 records <I6f: board sequence number, then O1 O2 in volts; 250 Hz\n');
      expect(readHeader(File('$stem.f32')).names, chNames(6)); // names that do not fit: Ch1..ChN, as the laptop
    });

    test('a damaged header is an error naming its file, never a guess', () {
      final f = record(dir, DateTime(2026, 11, 20, 23), brainBitHeader, samples: 10);
      headerFileOf(f).writeAsStringSync('{"format": "eeg-tracker-recording", "version": 1');
      expect(
        () => readHeader(f),
        throwsA(isA<HeaderError>().having((e) => '$e', 'text', contains('2026-11-20-230000.header.json'))),
      );
      expect(tryHeader(f), isNull);
      expect(() => joinLayout([f]), throwsA(isA<HeaderError>()));
    });

    test('the sleep tools read O1 O2 T3 T4 by name wherever a recording holds them', () {
      final names = ['Fz', 'O2', 'Cz', 'T8', 'O1', 'Pz', 'T7', 'Oz'];
      final h = RecordingHeader(channels: [for (final n in names) HeaderChannel(n, site: standardName(n))]);
      final f = record(dir, DateTime(2026, 11, 20, 23), h, samples: 600);
      final layout = joinLayout([f]);
      expect(layout.names, ['O1', 'O2', 'T3', 'T4']);
      final cols = [4, 1, 6, 3]; // O1 O2 T7 T8 in this recording
      for (var c = 0; c < 4; c++) {
        expect(layout.channel(c)[123], closeTo(f32(volt(123, cols[c])) * 1e6, 1e-9), reason: layout.names[c]);
      }
      final rows = <List<double>>[];
      layout.forEachRow((row, missing) {
        if (rows.length < 3) rows.add(List.of(row));
      });
      expect(rows[2], [for (final c in cols) closeTo(f32(volt(2, c)) * 1e6, 1e-9)]);
    });

    test(
      'a night whose recording lacks O1 O2 T3 T4 is refused in words: the sleep model never reads other channels',
      () {
        final f = record(
          dir,
          DateTime(2026, 11, 20, 23),
          headerForMontage(helmetPlan8(), device: 'helmet'),
          samples: 300,
        );
        expect(
          () => prepareNight([f], atLeast: 0),
          throwsA(
            isA<MissingSites>().having(
              (e) => '$e',
              'text',
              contains('needs O1 O2 T3 T4; this recording (helmet: M1 M2 F7 F8 Fz C3 C4 Pz) has no O1, O2, T3, T4'),
            ),
          ),
        );
      },
    );

    test('the morning check-in reads its channels by name, and refuses a recording without them', () {
      final names = ['T8', 'T7', 'O2', 'O1', 'Cz', 'Pz', 'Fz', 'Oz'];
      final h = RecordingHeader(channels: [for (final n in names) HeaderChannel(n, site: standardName(n))]);
      final f = record(dir, DateTime(2026, 11, 21, 7), h, samples: 10);
      expect(readCheckInRecording(f), isNull); // no check-in markers: nothing to read, and no error either
      final g = record(dir, DateTime(2026, 11, 21, 8), headerForMontage(helmetPlan8(), device: 'helmet'), samples: 10);
      expect(
        () => readCheckInRecording(g),
        throwsA(isA<MissingSites>().having((e) => '$e', 'text', contains('The morning check-in needs'))),
      );
    });

    test('the nights list counts a wide recording by its own record and rate', () {
      final h = RecordingHeader(channels: [for (final s in chNames(16)) HeaderChannel(s)], sampleRate: 500);
      final w = ChunkWriter.open(dir, DateTime(2026, 11, 20, 23), header: h);
      w.addBatch(DateTime(2026, 11, 20, 23, 0, 1), [for (var i = 0; i < 1000; i++) Sample(i, List.filled(16, 0.0))]);
      w.close();
      File('${dir.path}/${w.stem}.idx').deleteSync(); // no index: the end is start + samples / rate
      final nights = nightsIn(dir);
      expect(nights, hasLength(1));
      expect(nights.single.recordings, hasLength(1));
      expect(nights.single.end, DateTime(2026, 11, 20, 23, 0, 2)); // 1000 samples at 500 Hz
      expect(nights.single.files.map((f) => f.uri.pathSegments.last), contains('2026-11-20-230000.header.json'));
    });
  });
}
