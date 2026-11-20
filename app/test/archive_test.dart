// The Archive (DECISIONS 700-709): the list from a made-up app folder (kinds, how each started, grouping, packed and old
// files, any layout, the report's night as one recording), your tags round trip, the delete rules (the laptop's checked
// copy, the danger zone's raw-only and everything, in use), the detectors' pass and its cache, and the timeline's bands
// from a made-up pass.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:eeg_tracker/archive/bands.dart';
import 'package:eeg_tracker/archive/delete.dart';
import 'package:eeg_tracker/archive/detail.dart';
import 'package:eeg_tracker/archive/items.dart';
import 'package:eeg_tracker/archive/raw_remover.dart';
import 'package:eeg_tracker/archive/seen.dart';
import 'package:eeg_tracker/archive/tags.dart';
import 'package:eeg_tracker/cache/file_summaries.dart' show JsonMemo;
import 'package:eeg_tracker/export/store.dart' show isExported;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/packed.dart' show packRaw, packedFileOf;
import 'package:eeg_tracker/sleep/report.dart' show isoLocal;
import 'package:flutter_test/flutter_test.dart';

import 'support/read_count.dart';

/// A file set of [seconds] from [start] in [dir]: batches of 25 samples, each arriving as the recorder writes them,
/// [log] as its log's first lines, [header] (the BrainBit's by default; null: none, an old set). Samples in µV from
/// [uv] (default: 10 µV noise).
String writeSet(
  Directory dir,
  DateTime start, {
  int seconds = 60,
  List<String> log = const [],
  RecordingHeader? header,
  bool oldSet = false,
  double Function(int i, int c)? uv,
}) {
  final h = header ?? brainBitHeader;
  final w = ChunkWriter.open(dir, start, header: h);
  for (final l in log) {
    w.log(l, at: start);
  }
  final rnd = math.Random(start.millisecondsSinceEpoch);
  final f = uv ?? (i, c) => (rnd.nextDouble() - 0.5) * 20;
  for (var b = 0; b < seconds * 10; b++) {
    final rows = [
      for (var k = 0; k < 25; k++)
        Sample(b * 25 + k, [for (var c = 0; c < h.count; c++) f(b * 25 + k, c) * 1e-6]),
    ];
    w.addBatch(start.add(Duration(milliseconds: (b + 1) * 100)), rows);
  }
  w.close();
  if (oldSet) File('${dir.path}/${w.stem}.header.json').deleteSync();
  return w.stem;
}

void writeJson(File f, Object j) {
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(jsonEncode(j));
}

final DateTime day = DateTime(2026, 11, 18);
DateTime at(int h, int m, [int d = 0]) => DateTime(day.year, day.month, day.day + d, h, m);

void main() {
  late Directory root, files, rec;
  setUp(() {
    root = Directory.systemTemp.createTempSync('archive_test');
    files = Directory('${root.path}/files')..createSync();
    rec = Directory('${files.path}/recordings')..createSync();
    forgetArchive();
    JsonMemo.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  ArchiveItem only(ArchiveList l, String id) => l.items.singleWhere((i) => i.id == id);

  group('the list', () {
    test('a night by hand, its drop and reconnect: one recording, started with Start night', () {
      final a = writeSet(rec, at(23, 0), log: ['drift-off detector on; lights off counts from the first sample until Lights off']);
      // 40 minutes away, then the recorder's own reconnect line: still the same night
      final b = writeSet(
        rec,
        at(23, 41),
        log: ['reconnected (direct, try 4) after a drop (out of range); previous run $a, last data 2026-11-18T23:01:00.000, 2400.0 s ago'],
      );
      final l = listArchive(files);
      expect(l.items, hasLength(1));
      final n = l.items.single;
      expect(n.id, a);
      expect(n.stems, [a, b]);
      expect(n.kind, ArchiveKind.night);
      expect(n.kind.tag, 'sleep');
      expect(n.started.how, StartedHow.hand);
      expect(n.started.words, 'You: Start night');
      expect(n.started.byYou, isTrue);
      expect(n.start, at(23, 0));
      expect(n.end.isAfter(at(23, 41)), isTrue);
      expect(n.bytes, greaterThan(2 * 60 * 250 * 20));
      expect(n.laptop, OnLaptop.unknown);
    });

    test('a second Start night after 15 minutes is a recording of its own', () {
      writeSet(rec, at(23, 0));
      writeSet(rec, at(23, 20));
      expect(listArchive(files).items, hasLength(2));
    });

    test('started by the headband watcher, by itself or after Yes (its kept minutes join the night)', () {
      final auto = writeSet(rec, at(22, 0, -1), log: ['started automatically: the headband was found on at 22:00 (bedtime); recording and silent analysis only']);
      final pre = writeSet(rec, at(23, 0), log: ['auto-start: the headband was found on (check at 23:00); these minutes were kept in memory while the app asked']);
      writeSet(rec, at(23, 2), log: ['started after "Yes" to "Start the night?" (asked 23:00, answered 23:02); recording and silent analysis only']);
      final l = listArchive(files);
      expect(l.items, hasLength(2));
      expect(only(l, auto).started.how, StartedHow.watcher);
      expect(only(l, auto).started.byYou, isFalse);
      expect(only(l, pre).started.how, StartedHow.watcherYes);
      expect(only(l, pre).sets, hasLength(2));
      expect(only(l, pre).kind, ArchiveKind.night);
    });

    test('a nap names its recording; a work session without raw signal; who started it from the watcher\'s log', () {
      final nap = writeSet(rec, at(14, 0), seconds: 30, log: ['nap coach session; headband BB Black']);
      writeJson(File('${files.path}/naps/$nap.nap.json'), {'start': at(14, 0).toIso8601String(), 'lengthMin': 20, 'recording': nap, 'endS': 1200});
      writeJson(File('${files.path}/work-sessions/2026-11-18-090000.work.json'), {
        'start': at(9, 0).toIso8601String(),
        'end': at(11, 30).toIso8601String(),
        'epochs': const [],
      });
      writeJson(File('${files.path}/work-sessions/2026-11-18-160000.work.json'), {
        'start': at(16, 0).toIso8601String(),
        'end': at(17, 0).toIso8601String(),
      });
      File('${files.path}/auto-start/log.jsonl')
        ..parent.createSync()
        ..writeAsStringSync('${jsonEncode({'version': 1, 'at': isoLocal(at(16, 0).add(const Duration(seconds: 9))), 'event': 'start', 'kind': 'work', 'how': 'automatic'})}\n');
      final l = listArchive(files);
      final n = only(l, nap);
      expect(n.kind, ArchiveKind.nap);
      expect(n.sessions.single.path, 'naps/$nap.nap.json');
      expect(n.started.words, 'You: Nap coach');
      final w1 = only(l, '2026-11-18-090000'), w2 = only(l, '2026-11-18-160000');
      expect(w1.kind, ArchiveKind.work);
      expect(w1.hasRaw, isFalse);
      expect(w1.length, const Duration(hours: 2, minutes: 30));
      expect(w1.started.how, StartedHow.hand);
      expect(w2.started.how, StartedHow.watcher);
      // newest first, one day
      expect([for (final i in l.items) i.id], ['2026-11-18-160000', nap, '2026-11-18-090000']);
      expect(l.days.single.$1, '2026-11-18');
    });

    test('a meditation\'s whole log is its raw signal', () {
      final m = Directory('${files.path}/meditations')..createSync();
      writeJson(File('${m.path}/2026-11-18-200000.meditation.json'), {
        'start': at(20, 0).toIso8601String(),
        'runS': 600,
        'log': '2026-11-18-200000.session.json',
      });
      File('${m.path}/2026-11-18-200000.session.json').writeAsStringSync('x' * 5000);
      final i = listArchive(files).items.single;
      expect(i.kind, ArchiveKind.meditation);
      expect(i.length, const Duration(minutes: 10));
      expect(i.hasRaw, isTrue);
      expect(i.rawPaths, ['meditations/2026-11-18-200000.session.json']);
      expect(i.rawBytes, 5000);
    });

    test('the sleep report\'s night is one recording: the dream catcher before it and the night', () {
      final dream = writeSet(rec, at(22, 30), log: ['dream catcher session; headband BB Black']);
      final night = writeSet(rec, at(23, 10), seconds: 120, log: ['connected BB Black serial 1 battery 90% signal -60 dBm']);
      writeJson(File('${files.path}/dream-catcher/$dream.dream.json'), {'start': at(22, 30).toIso8601String(), 'recording': dream, 'endS': 900});
      writeJson(File('${files.path}/nights/2026-11-18.report.json'), {
        'night_of': '2026-11-18',
        'scored': true,
        'data_start': isoLocal(at(22, 30)),
        'data_end': isoLocal(at(23, 12)),
        'inputs': [
          {'file': '$dream.f32', 'bytes': 1},
          {'file': '$night.f32', 'bytes': 1},
        ],
        'total': {'asleep_min': 0},
        'periods': const [],
      });
      final l = listArchive(files);
      expect(l.items, hasLength(1));
      final i = l.items.single;
      expect(i.kind, ArchiveKind.night); // the night holds most of the signal
      expect(i.id, dream);
      expect(i.stems, [dream, night]);
      expect(i.report!.nightOf, '2026-11-18');
      expect(i.sessions.single.kind, ArchiveKind.dream);
    });

    test('any layout, packed and old files: the DIY board\'s 8 channels, a packed set, a set without a header', () {
      final diy = Directory('${files.path}/recordings-diy')..createSync();
      final h8 = RecordingHeader(
        channels: [for (var c = 1; c <= 8; c++) HeaderChannel('Ch$c')],
        sampleRate: 250,
        device: 'DIY board',
        counter: counterSequence,
      );
      final board = writeSet(diy, at(21, 0), header: h8);
      final old = writeSet(rec, at(2, 0), oldSet: true);
      final packed = writeSet(rec, at(5, 0), seconds: 30);
      packRaw(File('${rec.path}/$packed.f32'));
      final l = listArchive(files);
      final b = only(l, board);
      expect(b.kind, ArchiveKind.board);
      expect(b.sets.single.names, hasLength(8));
      expect(b.started.words, 'You: Start night (DIY board)');
      expect(only(l, old).sets.single.names, ['O1', 'O2', 'T3', 'T4']);
      final p = only(l, packed).sets.single;
      expect(p.files, contains('$packed.f32.gz'));
      expect(p.rawBytes, 30 * 250 * 20);
      expect(p.end, isNotNull);
    });

    test('a list after the first opens no file set again until one changes', () {
      for (var k = 0; k < 6; k++) {
        writeSet(rec, at(k * 3, 0), seconds: 10);
      }
      listArchive(files);
      forgetArchive(); // a new process: the kept index on disk
      final counts = ReadCounts();
      countingReads(counts, () => listArchive(files));
      expect(counts.of('/recordings/'), 0);
      final s = writeSet(rec, at(20, 0), seconds: 10);
      counts.clear();
      final l = countingReads(counts, () => listArchive(files));
      expect(counts.of('/recordings/$s'), greaterThan(0));
      expect(counts.of('/recordings/') - counts.of('/recordings/$s'), 0);
      expect(l.items, hasLength(7));
    });
  });

  group('your tags', () {
    test('add, change and remove a tag; a file with none goes; they leave with Export data', () {
      final store = TagStore(files);
      final walk = ManualTag(start: at(9, 0), end: at(9, 40), label: ' Walk ', made: at(10, 0));
      expect(walk.label, 'walk');
      expect(store.add('2026-11-18-090000', walk), isTrue);
      final read = store.tags('2026-11-18-090000');
      expect(read, [walk]);
      final meeting = read.single.copyWith(label: 'meeting with Anna', end: at(9, 50));
      expect(store.replace('2026-11-18-090000', read.single, meeting), isTrue);
      expect(store.tags('2026-11-18-090000').single.label, 'meeting with Anna');
      expect(isExported('archive/2026-11-18-090000.tags.json'), isTrue);
      expect(store.remove('2026-11-18-090000', store.tags('2026-11-18-090000').single), isTrue);
      expect(store.fileFor('2026-11-18-090000').existsSync(), isFalse);
    });

    test('a damaged tags file is never overwritten; a damaged tag is left out', () {
      final store = TagStore(files);
      store.dir.createSync(recursive: true);
      store.fileFor('x').writeAsStringSync('{not json');
      expect(store.tags('x'), isEmpty);
      expect(store.add('x', ManualTag(start: at(1, 0), end: at(2, 0), label: 'sleep')), isFalse);
      expect(store.fileFor('x').readAsStringSync(), '{not json');
      store.fileFor('y').writeAsStringSync(jsonEncode({
        'version': 1,
        'id': 'y',
        'tags': [
          {'start': isoLocal(at(3, 0)), 'end': isoLocal(at(2, 0)), 'label': 'backwards'},
          {'start': isoLocal(at(3, 0)), 'end': isoLocal(at(4, 0)), 'label': 'rest'},
        ],
      }));
      expect([for (final t in store.tags('y')) t.label], ['rest']);
    });

    test('the list shows a recording\'s tags', () {
      final s = writeSet(rec, at(8, 0), seconds: 10);
      TagStore(files).add(s, ManualTag(start: at(8, 0), end: at(8, 1), label: 'walk'));
      expect(listArchive(files).items.single.manualTags.single.label, 'walk');
    });
  });

  group('deleting', () {
    final later = DateTime.now().add(const Duration(hours: 2));

    test('without the laptop\'s checked copy: no normal removal; the danger zone\'s raw only keeps every statistic', () {
      final nap = writeSet(rec, at(14, 0), log: ['nap coach session; headband BB Black']);
      File('${rec.path}/$nap.markers.jsonl').writeAsStringSync('{"t": 1, "i": 0, "text": "lights off"}\n');
      writeJson(File('${files.path}/naps/$nap.nap.json'), {'start': at(14, 0).toIso8601String(), 'recording': nap, 'endS': 60});
      TagStore(files).add(nap, ManualTag(start: at(14, 0), end: at(14, 1), label: 'rest'));
      var l = listArchive(files);
      final item = l.items.single;
      expect(item.laptop, OnLaptop.unknown);
      final rm = PhoneRawRemover(files);
      final normal = deleteItem(files, item, DeleteMode.rawOnLaptop, all: l.items, remover: rm, now: later);
      expect(normal.complete, isFalse);
      expect(File('${rec.path}/$nap.f32').existsSync(), isTrue);
      final plan = planDelete(item, DeleteMode.rawOnly);
      expect(plan.onlyCopy, isTrue);
      expect(plan.removes, ['the raw signal (1 file set)']);
      expect(plan.keeps, containsAll(["the nap's results", 'your 1 tag', "each file set's log"]));
      final out = deleteItem(files, item, DeleteMode.rawOnly, all: l.items, remover: rm, now: later);
      expect(out.complete, isTrue);
      expect(out.freedBytes, item.rawBytes);
      expect(File('${rec.path}/$nap.f32').existsSync(), isFalse);
      expect(File('${rec.path}/$nap.idx').existsSync(), isFalse);
      for (final kept in ['.log', '.header.json', '.markers.jsonl', removedSuffix]) {
        expect(File('${rec.path}/$nap$kept').existsSync(), isTrue, reason: kept);
      }
      final record = jsonDecode(File('${rec.path}/$nap$removedSuffix').readAsStringSync()) as Map;
      expect(record['format'], 'eeg-tracker-removed');
      expect(record['why'], 'deleted by hand');
      expect(record['on_laptop'], isFalse);
      expect(record['end_ms'], isA<int>());
      // still listed: what is left, and its tags
      l = listArchive(files);
      final left = l.items.single;
      expect(left.rawRemoved, isTrue);
      expect(left.hasRaw, isFalse);
      expect(left.sessions, hasLength(1));
      expect(left.manualTags, hasLength(1));
      expect(left.end, item.end);
    });

    test('with the laptop\'s checked copy of every raw file: removed by the normal action', () {
      final s = writeSet(rec, at(1, 0), seconds: 20);
      final acks = <String, Object?>{};
      for (final name in ['$s.f32', '$s.idx']) {
        final f = File('${rec.path}/$name');
        acks['recordings/$name'] = {
          'sha256': '0' * 64,
          'bytes': f.lengthSync(),
          'modified_ms': f.statSync().modified.millisecondsSinceEpoch,
          'acked_ms': 1,
        };
      }
      writeJson(File('${files.path}/transfer/acks.json'), {'format': 'eeg-tracker-acks', 'version': 1, 'files': acks});
      final l = listArchive(files);
      final i = l.items.single;
      expect(i.laptop, OnLaptop.yes);
      expect(planDelete(i, DeleteMode.rawOnLaptop).onlyCopy, isFalse);
      final out = deleteItem(files, i, DeleteMode.rawOnLaptop, all: l.items, remover: PhoneRawRemover(files), now: later);
      expect(out.complete, isTrue);
      expect(jsonDecode(File('${rec.path}/$s$removedSuffix').readAsStringSync())['on_laptop'], isTrue);
      expect(listArchive(files).items.single.removedToLaptop, isTrue);
    });

    test('the laptop\'s copy of other bytes is no copy', () {
      final s = writeSet(rec, at(1, 0), seconds: 20);
      writeJson(File('${files.path}/transfer/acks.json'), {
        'format': 'eeg-tracker-acks',
        'files': {
          'recordings/$s.f32': {'sha256': '0' * 64, 'bytes': 7, 'modified_ms': 1, 'acked_ms': 1},
        },
      });
      expect(listArchive(files).items.single.laptop, OnLaptop.no);
    });

    test('everything: every file of it, its session, report and tags', () {
      final dream = writeSet(rec, at(22, 30), log: ['dream catcher session; headband BB Black']);
      writeJson(File('${files.path}/dream-catcher/$dream.dream.json'), {'start': at(22, 30).toIso8601String(), 'recording': dream, 'endS': 60});
      File('${files.path}/dream-catcher/$dream-r1.wav').writeAsBytesSync([1, 2, 3]);
      writeJson(File('${files.path}/nights/2026-11-18.report.json'), {
        'night_of': '2026-11-18',
        'scored': false,
        'data_start': isoLocal(at(22, 30)),
        'data_end': isoLocal(at(22, 31)),
        'inputs': [
          {'file': '$dream.f32', 'bytes': 1},
        ],
        'total': {'asleep_min': 0},
        'periods': const [],
      });
      TagStore(files).add(dream, ManualTag(start: at(22, 30), end: at(22, 31), label: 'sleep'));
      final keep = writeSet(rec, at(5, 0, 1), seconds: 10);
      final l = listArchive(files);
      final i = only(l, dream);
      expect(i.sessions.single.companions, ['dream-catcher/$dream-r1.wav']);
      final plan = planDelete(i, DeleteMode.everything);
      expect(plan.removes, containsAll(['the raw signal (1 file set)', 'the sleep report', "the dream catcher's results", 'your 1 tag']));
      expect(plan.keeps, isEmpty);
      final out = deleteItem(files, i, DeleteMode.everything, all: l.items, remover: PhoneRawRemover(files), now: later);
      expect(out.complete, isTrue);
      expect(rec.listSync().map((f) => f.uri.pathSegments.last).where((n) => n.startsWith(dream)), isEmpty);
      expect(Directory('${files.path}/dream-catcher').listSync(), isEmpty);
      expect(File('${files.path}/nights/2026-11-18.report.json').existsSync(), isFalse);
      expect(TagStore(files).fileFor(dream).existsSync(), isFalse);
      expect([for (final i in listArchive(files).items) i.id], [keep]);
    });

    test('never while in use: written in the last hour, a night recording, a session, the scoring', () {
      final old = writeSet(rec, at(1, 0), seconds: 10);
      final newest = writeSet(rec, at(3, 0), seconds: 10);
      final l = listArchive(files);
      final rm = PhoneRawRemover(files);
      // just written
      final now = DateTime.now();
      expect(whyInUse(files, only(l, old), l.items, const ArchiveBusy(), now), startsWith('Written at '));
      final r = deleteItem(files, only(l, old), DeleteMode.rawOnly, all: l.items, remover: rm, now: now);
      expect(r.complete, isFalse);
      expect(File('${rec.path}/$old.f32').existsSync(), isTrue);
      // an hour on: a night recording holds the newest only
      const night = ArchiveBusy(nightRecording: true);
      expect(whyInUse(files, only(l, newest), l.items, night, later), contains('A night is recording'));
      expect(whyInUse(files, only(l, old), l.items, night, later), isNull);
      expect(whyInUse(files, only(l, newest), l.items, const ArchiveBusy(sessionRunning: true), later), contains('session'));
      expect(
        whyInUse(files, only(l, old), l.items, const ArchiveBusy(scoring: true), only(l, old).end.add(const Duration(hours: 3))),
        contains('sleep report'),
      );
      expect(deleteItem(files, only(l, newest), DeleteMode.rawOnly, all: l.items, remover: rm, busy: night, now: later).complete, isFalse);
      expect(File('${rec.path}/$newest.f32').existsSync(), isTrue);
    });

    test('a packed set: its .f32.gz and index go, the record keeps the plain name and bytes', () {
      final s = writeSet(rec, at(4, 0), seconds: 30);
      packRaw(File('${rec.path}/$s.f32'));
      final l = listArchive(files);
      final out = deleteItem(files, l.items.single, DeleteMode.rawOnly, all: l.items, remover: PhoneRawRemover(files), now: later);
      expect(out.complete, isTrue);
      expect(packedFileOf(File('${rec.path}/$s.f32')).existsSync(), isFalse);
      final f = (jsonDecode(File('${rec.path}/$s$removedSuffix').readAsStringSync())['files'] as List).first as Map;
      expect(f['name'], '$s.f32');
      expect(f['bytes'], 30 * 250 * 20);
      expect(f['phone_name'], '$s.f32.gz');
    });
  });

  group('the detectors\' pass', () {
    test('per 30 s epoch from the first sample; a gap between two sets reads as no signal', () {
      final a = writeSet(rec, at(10, 0), seconds: 90);
      final b = writeSet(rec, at(10, 3), seconds: 60);
      final s = seeRecording([File('${rec.path}/$a.f32'), File('${rec.path}/$b.f32')])!;
      expect(s.start, at(10, 0));
      expect(s.epochs, 8); // 10:00 to 10:04
      expect(s.quality.substring(0, 3), isNot(contains('m')));
      expect(s.quality.substring(3, 6), 'mmm'); // 10:01:30 to 10:03
      expect(s.eyes.length, 8);
      expect(s.jaw, everyElement(0));
    });

    test('flat zeros: no usable electrode', () {
      final a = writeSet(rec, at(10, 0), seconds: 60, uv: (i, c) => 0);
      expect(seeRecording([File('${rec.path}/$a.f32')])!.quality, 'mm');
    });

    test('kept until a raw file changes; never run for a layout without O1 O2 T3 T4', () {
      final a = writeSet(rec, at(10, 0), seconds: 60);
      final f32 = [File('${rec.path}/$a.f32')];
      final first = seeAndKeep(files, a, f32);
      expect(first.seen!.epochs, 2);
      // a kept pass is used as it is: plant a marker in it
      final kept = seenFileFor(files, a);
      final j = jsonDecode(kept.readAsStringSync()) as Map;
      (j['seen'] as Map)['eyes'] = 'cc';
      kept.writeAsStringSync(jsonEncode(j));
      expect(seeAndKeep(files, a, f32).seen!.eyes, 'cc');
      expect(keptMinutes(files)[a], isNotNull);
      // the recording grew: read again
      File('${rec.path}/$a.idx').writeAsBytesSync([...File('${rec.path}/$a.idx').readAsBytesSync()]);
      File('${rec.path}/$a.f32').setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      expect(seeAndKeep(files, a, f32).seen!.eyes, isNot('cc'));
      final diy = Directory('${files.path}/recordings-diy')..createSync();
      final h8 = RecordingHeader(
        channels: [for (var c = 1; c <= 8; c++) HeaderChannel('Ch$c')],
        sampleRate: 250,
        device: 'DIY board',
        counter: counterSequence,
      );
      final board = writeSet(diy, at(11, 0), seconds: 30, header: h8);
      final why = seeAndKeep(files, board, [File('${diy.path}/$board.f32')]);
      expect(why.seen, isNull);
      expect(why.why, contains('O1, O2, T3, T4'));
    });
  });

  group('the timeline', () {
    ArchiveItem item(DateTime start, DateTime end) =>
        ArchiveItem(id: 'x', kind: ArchiveKind.night, start: start, end: end, started: byHand(ArchiveKind.night));

    test('bands from a made-up pass: eyes closed, drowsy, talking, moving, no signal; asleep wins', () {
      // 20 epochs from 22:00: 0-1 no signal, 2-4 eyes closed, 5-7 drowsy, 8-9 talking, 10 moving, 12-17 asleep (with eyes
      // "closed" and talking that asleep must not show), 18-19 awake
      final q = 'mm${'g' * 18}';
      final eyes = '--ccc' '${'o' * 7}' '${'c' * 6}' 'oo';
      final level = '-----ddd' '${'a' * 4}' '${'d' * 6}' 'aa';
      final jaw = [0, 0, 0, 0, 0, 0, 0, 0, 3, 4, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0];
      final move = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      final seen = RecordingSeen(
        startMs: at(22, 0).millisecondsSinceEpoch,
        quality: q,
        eyes: eyes,
        level: level,
        jaw: jaw,
        move: move,
      );
      final stages = (start: at(22, 6), stages: '123R22WWWW'); // epochs 12-17 asleep
      final tl = timelineOf(item(at(22, 0), at(22, 10)), TimelineInput(seen: seen, stages: stages));
      String spans(Lane l) => [for (final b in tl.of(l)) '${b.label} ${b.start.minute}:${b.start.second}-${b.end.minute}:${b.end.second}'].join(', ');
      expect(spans(Lane.signal), 'No signal 0:0-1:0');
      expect(spans(Lane.sleep), 'Asleep 6:0-9:0');
      expect(spans(Lane.eyes), 'Eyes closed 1:0-2:30');
      expect(spans(Lane.drowsy), 'Drowsy 2:30-4:0');
      expect(spans(Lane.talking), 'Talking or chewing 4:0-5:0, Jaw 6:0-7:0');
      expect(spans(Lane.moving), 'Moving 5:0-5:30');
      expect(tl.total(Lane.sleep), const Duration(minutes: 3));
      expect(tl.of(Lane.sleep).single.source, contains('light 2 min, deep 1 min, dream 1 min'));
    });

    test('a work session\'s breaks and meetings; its own epochs without a pass; sessions and your tags', () {
      final w = WorkDetail(
        start: at(9, 0),
        end: at(10, 0),
        breaks: [(at(9, 20), at(9, 30))],
        meetings: [(at(9, 40), at(9, 55))],
        epochs: [
          for (var i = 0; i < 120; i++)
            (at: at(9, 0).add(Duration(seconds: 30 * i)), level: i >= 10 && i < 16 ? 'drowsy' : 'alert', closed: i >= 100 && i < 104),
        ],
      );
      final tag = ManualTag(start: at(9, 0), end: at(9, 15), label: 'meeting');
      final tl = timelineOf(item(at(9, 0), at(10, 0)), TimelineInput(work: [w], tags: [tag]));
      expect([for (final b in tl.of(Lane.work)) b.label], ['Work session', 'Break', 'Work session']);
      expect(tl.of(Lane.meeting).single.start, at(9, 40));
      expect(tl.of(Lane.drowsy).single.start, at(9, 5));
      expect(tl.of(Lane.eyes).single.start, at(9, 50));
      expect(tl.of(Lane.tags).single.tag, tag);
      expect(bandAt(tl, Lane.work, at(9, 25))!.label, 'Break');
    });

    test('without a pass, the time between file sets is no data', () {
      final i = ArchiveItem(
        id: 'x',
        kind: ArchiveKind.night,
        start: at(1, 0),
        end: at(3, 0),
        started: byHand(ArchiveKind.night),
        sets: [
          RawSet(folder: 'recordings', stem: '2026-11-18-010000', start: at(1, 0), end: at(1, 30), bytes: 1, rawBytes: 1, writer: 'night', files: const []),
          RawSet(folder: 'recordings', stem: '2026-11-18-020000', start: at(2, 0), end: at(3, 0), bytes: 1, rawBytes: 1, writer: 'night', files: const []),
        ],
      );
      final b = timelineOf(i, const TimelineInput()).of(Lane.signal).single;
      expect((b.label, b.start, b.end), ('No data', at(1, 30), at(2, 0)));
    });

    test('the list\'s words for what was found', () {
      expect(foundWords(asleepMin: 372, minutes: {'eyes': 14, 'talking': 9.4, 'drowsy': 0.5, 'moving': 3}), [
        'asleep 6 h 12',
        'eyes closed 14 min',
        'talking 9 min',
        'moving 3 min',
      ]);
      expect(noSignalWords({'nosignal': 42}), 'no signal 42 min');
    });
  });

  group('the raw view', () {
    test('a window of every channel at a moment; in a gap, where the signal is', () {
      final a = writeSet(rec, at(10, 0), seconds: 60, uv: (i, c) => c * 10.0 + i % 7);
      final b = writeSet(rec, at(10, 5), seconds: 60);
      final paths = ['${rec.path}/$a.f32', '${rec.path}/$b.f32'];
      final w = readWindow(paths, at(10, 0).add(const Duration(seconds: 20)), 10);
      expect(w.names, ['O1', 'O2', 'T3', 'T4']);
      expect(w.rate, 250);
      expect(w.lead, 500);
      expect(w.samples, 500 + 2500);
      expect(w.note, isNull);
      expect(w.values[w.lead * 4 + 1], closeTo(10.0 + (20 * 250) % 7, 1e-3));
      final gap = readWindow(paths, at(10, 3), 10);
      expect(gap.samples, 0);
      expect(gap.next, at(10, 5));
      final edge = readWindow(paths, at(10, 0).add(const Duration(seconds: 55)), 10);
      expect(edge.note, contains('stops after'));
    });

    test('the page\'s data: stages, work, sessions in its time, tags, the kept pass', () {
      final s = writeSet(rec, at(23, 0), seconds: 60);
      final l = listArchive(files);
      var d = loadDetail(files, l.items.single, const []);
      expect(d.passKept, isFalse);
      expect(d.rawPaths, ['${rec.path}/$s.f32']);
      seeAndKeep(files, s, [File('${rec.path}/$s.f32')]);
      d = loadDetail(files, l.items.single, const []);
      expect(d.passKept, isTrue);
      expect(d.input.seen!.epochs, 2);
    });
  });
}
