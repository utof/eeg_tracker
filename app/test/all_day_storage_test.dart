// The phone must not fill up when it records all day (review finding 10, DECISIONS 1035-1042):
// - the awake hours of a recording (file sets in no night and no nap) leave the phone like any raw recording, set by
//   set, once the laptop has checked them;
// - a file set shared by two nights or naps goes only when every one of them may go;
// - the file set being written is never packed or cleared, whatever its acks say;
// - packing and clearing run beside a live recording and never touch its files.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/export/exporter.dart';
import 'package:eeg_tracker/export/store.dart';
import 'package:eeg_tracker/recorder/acks.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/recorder/packed.dart';
import 'package:eeg_tracker/recorder/recheck.dart';
import 'package:eeg_tracker/recorder/remove.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:eeg_tracker/storage/clear.dart';
import 'package:eeg_tracker/storage/open_sets.dart';
import 'package:eeg_tracker/storage/storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder;
import 'roll_over_test.dart' show packs, rolling;

void main() {
  late Directory files, rec;
  late SpanLog log;

  setUp(() {
    files = Directory.systemTemp.createTempSync('all_day_storage');
    rec = Directory('${files.path}/recordings')..createSync();
    log = SpanLog(spansDirFor(rec.path));
    forgetNightSets();
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// Two hours from now: every file made here was written more than an hour before it.
  DateTime later() => DateTime.now().add(const Duration(hours: 2));
  final dayMs = const Duration(days: 1).inMilliseconds;

  /// A file set of [minutes] at 250 Hz from [start] (one batch a second), part of [recording] (null: the first set,
  /// which names it).
  String writeSet(DateTime start, int minutes, {String? recording, Directory? dir}) {
    final w = ChunkWriter.open(dir ?? rec, start, inRecording: true, recording: recording);
    final batch = [for (var i = 0; i < 250; i++) Sample(i, Float32List.fromList([i * 1e-7, 2e-5, 3e-5, start.minute * 1e-6]))];
    for (var s = 0; s < minutes * 60; s++) {
      w.addBatch(start.add(Duration(seconds: s)), batch);
      if (s % 600 == 599) w.append();
    }
    w.close();
    return w.stem;
  }

  String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();

  /// The laptop's checked copy of each raw file of [stems] as it is now, acked at [at] (unix ms).
  void ack(Iterable<String> stems, {int at = 0}) {
    final kept = <String, LaptopCopy>{};
    for (final stem in stems) {
      for (final f in rawFilesOf(File('${rec.path}/$stem.f32'))) {
        final st = f.statSync();
        kept[ackPathOf('recordings/${f.uri.pathSegments.last}')] = LaptopCopy(
          sha256: isPackedPath(f.path) ? packedInfo(f)!.sha256 : sha(f),
          bytes: isPackedPath(f.path) ? packedInfo(f)!.bytes : st.size,
          modifiedMs: isPackedPath(f.path) ? packedInfo(f)!.modifiedMs : st.modified.millisecondsSinceEpoch,
          ackedMs: at,
        );
      }
    }
    AckStore(files).add(kept);
  }

  void report(NightFiles n) => NightReportStore(nightsDirFor(rec.path)).write(
    buildReport(
      nightOf: n.name,
      built: DateTime(2026, 11, 20, 8),
      scoringSeconds: 1,
      start: n.start,
      lengthSeconds: 3600,
      inputs: SleepScorer.inputsOf(n),
      model: 'test',
    ),
  );

  bool raw(String stem) => rawOnDisk(File('${rec.path}/$stem.f32')) != null;

  /// The laptop proves every file the phone asked about.
  void proveAll(DateTime now) {
    final store = RecheckStore(files);
    for (final a in store.asks().values) {
      store.prove(a.path, a.nonce, ok: true, why: null, at: now);
    }
  }

  /// One recording of a day in four file sets of 5 minutes (stand-ins for the roll-over's four hours): two awake, at
  /// 09:00 and 13:00, then two at 23:00 and 01:00 with Sleep from 23:02 to 01:04.
  ({String id, List<String> day, List<String> night}) allDay() {
    final id = writeSet(DateTime(2026, 11, 18, 9), 5);
    final d2 = writeSet(DateTime(2026, 11, 18, 13), 5, recording: id);
    final e = writeSet(DateTime(2026, 11, 18, 23), 5, recording: id);
    final n = writeSet(DateTime(2026, 11, 19, 1), 5, recording: id);
    log.add(id, kind: 'sleep', start: DateTime(2026, 11, 18, 23, 2), end: DateTime(2026, 11, 19, 1, 4), source: 'owner_button');
    return (id: id, day: [id, d2], night: [e, n]);
  }

  test('the awake hours of a recording leave the phone set by set once the laptop checked them; the night goes whole', () async {
    final now = later();
    final t = now.millisecondsSinceEpoch;
    final r = allDay();
    final night = nightsIn(rec).single;
    expect(night.recordings.map((f) => f.uri.pathSegments.last), [for (final s in r.night) '$s.f32']);
    report(night);

    // nothing acked: nothing may go, and all of it is the Danger zone's
    var plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now);
    expect(plan.groups, isEmpty);
    expect(plan.why['nights.raw'], 'not checked on the laptop yet');
    final danger = planClear(files, {'nights.raw'}, mode: ClearMode.phoneOnly, now: now);
    expect({for (final g in danger.groups) ...g.sets.map((s) => s.split('/').last)}, {for (final s in [...r.day, ...r.night]) '$s.f32'});

    // the first day set checked 5 days ago, the second yesterday, the night 5 days ago
    ack([r.day[0], ...r.night], at: t - 5 * dayMs);
    ack([r.day[1]], at: t - 1 * dayMs);
    plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now);
    expect([for (final g in plan.groups) (g.night, g.sets.length)], unorderedEquals([('2026-11-18', 2), (null, 1), (null, 1)]));

    expect((await autoClear(files, busy: () async => false, paired: true, laptop: 'desk', clock: () => now))!.removed, isEmpty, reason: 'asked first');
    proveAll(now);
    final run = (await autoClear(files, busy: () async => false, paired: true, laptop: 'desk', clock: () => now))!;
    expect(run.removed, unorderedEquals(['2026-11-18', '${r.day[0]}.f32']));
    expect(raw(r.day[0]), isFalse);
    expect(raw(r.day[1]), isTrue, reason: 'checked only a day ago');
    expect(r.night.map(raw), [false, false]);
    expect(removedRecordOf(File('${rec.path}/${r.day[0]}.f32'))!.onLaptop, isTrue);
    // what stays of a set: its header, log and the record of where its samples went
    expect(File('${rec.path}/${r.day[0]}.header.json').existsSync(), isTrue);
    expect(File('${rec.path}/${r.day[0]}.log').existsSync(), isTrue);
    // the night keeps its shape and its report
    forgetNightSets();
    expect(nightsIn(rec).single.removed, hasLength(2));
    expect(NightReportStore(nightsDirFor(rec.path)).read('2026-11-18'), isNotNull);
  });

  test('a file set two sleeps share goes only when both may go: a nap with its report never takes a night\'s set', () {
    final now = later();
    // one set 20:00-20:12 holds a nap (20:02-20:05) and the start of the night (20:08 on); the night goes on in a second set
    final id = writeSet(DateTime(2026, 11, 18, 20), 12);
    final second = writeSet(DateTime(2026, 11, 18, 20, 12), 8, recording: id);
    log.add(id, kind: 'nap', start: DateTime(2026, 11, 18, 20, 2), end: DateTime(2026, 11, 18, 20, 5), source: 'owner_button');
    log.add(id, kind: 'sleep', start: DateTime(2026, 11, 18, 20, 8), end: DateTime(2026, 11, 18, 20, 19), source: 'owner_button');
    final nap = napsIn(rec).single, night = nightsIn(rec).single;
    expect(nap.recordings.single.path, endsWith('$id.f32'));
    expect(night.recordings, hasLength(2));
    ack([id, second]);
    report(nap); // the nap has its report, the night has none yet
    var plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now);
    expect(plan.groups, isEmpty, reason: 'the shared set is the night\'s too');
    expect(plan.why['nights.raw'], 'no sleep report yet');
    report(night);
    plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now);
    expect({for (final g in plan.groups) ...g.sets.map((s) => s.split('/').last)}, {'$id.f32', '$second.f32'});
  });

  test('the file set being written is never planned and never packed, whatever its age and acks say', () async {
    final now = later();
    final r = allDay();
    report(nightsIn(rec).single);
    ack([...r.day, ...r.night], at: now.millisecondsSinceEpoch - 9 * dayMs);
    // the recording still runs: its newest set is the open one
    final open = openSets(files, r.id);
    expect(open.map((p) => p.split('/').last), ['${r.night[1]}.f32']);
    expect(openSets(files, null), isEmpty);
    expect(openSets(files, 'no-such-recording'), isEmpty);
    // by the files' own times, not their names: the phone's clock set back names a new set before the old ones
    final early = writeSet(DateTime(2026, 11, 18, 3), 1, recording: r.id);
    expect(openSets(files, r.id).map((p) => p.split('/').last), ['$early.f32']);
    for (final f in rec.listSync().whereType<File>().where((f) => f.path.contains(early))) {
      f.deleteSync();
    }
    forgetNightSets();
    expect(openSets(files, r.id).map((p) => p.split('/').last), ['${r.night[1]}.f32']);
    final plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now, open: open);
    final planned = {for (final g in plan.groups) ...g.sets.map((s) => s.split('/').last)};
    expect(planned, {'${r.day[0]}.f32', '${r.day[1]}.f32'}, reason: 'the night holds the open set: it stays whole');
    expect(plan.why['nights.raw'], 'still being recorded');
    // packing: everything is days old by the clock given, yet the open set stays plain
    final packed = await packOldRecordings(
      files,
      busy: () async => false,
      pack: (p) async => packOne(p),
      clock: () => now.add(const Duration(days: 3)),
      open: open,
    );
    expect(packed.packed.map((p) => p.packed.uri.pathSegments.last), unorderedEquals([for (final s in [...r.day, r.night[0]]) '$s.f32.gz']));
    expect(File('${rec.path}/${r.night[1]}.f32').existsSync(), isTrue);
  });

  test('beside a live recording: old recordings are packed and cleared, and no byte of the live one is touched', tags: 'realtime', () async {
    final now = DateTime.now();
    // an older recording, days ago: a day set and a night, checked by the laptop 5 days ago, old enough to pack
    final old = allDay();
    report(nightsIn(rec).single);
    for (final f in rec.listSync().whereType<File>()) {
      f.setLastModifiedSync(now.subtract(const Duration(days: 6)));
    }
    forgetNightSets();
    report(nightsIn(rec).single);
    ack([...old.day, ...old.night], at: now.millisecondsSinceEpoch - 5 * dayMs);

    // the live recording: rolls over every 2 kB, so it has closed sets of its own and an open one
    final band = FakeBand('a', packOf: (i) => i);
    final store = MemoryNightStore();
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: rec,
      store: store,
      onStatus: (_) {},
      onStuck: (_) async {},
      timing: rolling(bytes: 2 * 1024),
      watch: null,
      sleep: false,
      spanLog: log,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final id = store.state.recording;
    expect(id, isNotNull);

    // housekeeping, as the Record tab runs it, while the recorder writes
    final open = openSets(files, id);
    expect(open, hasLength(1));
    final packed = await packOldRecordings(files, busy: () async => false, pack: packInBackground, open: open);
    expect(packed.failed, isEmpty);
    expect(packed.packed.map((p) => p.packed.uri.pathSegments.last), unorderedEquals([for (final s in [...old.day, ...old.night]) '$s.f32.gz']));
    await autoClear(files, busy: () async => false, paired: true, laptop: 'desk', open: () async => openSets(files, store.state.recording));
    proveAll(DateTime.now());
    final cleared = (await autoClear(files, busy: () async => false, paired: true, laptop: 'desk', open: () async => openSets(files, store.state.recording)))!;
    expect(cleared.removed, unorderedEquals(['2026-11-18', '${old.day[0]}.f32', '${old.day[1]}.f32']));
    expect(cleared.kept, isEmpty);
    // the archive's list and Export work beside it too: the nights are listed, and the export leaves out what is
    // being written
    forgetNightSets();
    expect(nightsIn(rec).map((n) => n.name), ['2026-11-18']);
    final out = Directory('${files.path}-export')..createSync();
    addTearDown(() => out.deleteSync(recursive: true));
    final exported = await runExport(
      filesDir: files,
      target: DirectoryTarget(out),
      everything: true,
      open: openSets(files, store.state.recording),
    );
    expect(exported.complete, isTrue);
    expect(exported.stillWritten, isNotEmpty);
    expect(exported.stillWritten, everyElement(startsWith('recordings/')));
    expect(exported.files, greaterThan(4));

    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;

    // the live recording: every sample once, in order, in plain files no one else wrote
    final mine = rec.listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(mine.length, greaterThan(2));
    expect([for (final f in mine) ...packs(f)], [for (var i = 0; i < band.emitted; i++) i]);
    expect(rec.listSync().where((f) => f.path.endsWith('.gz')), isEmpty, reason: 'the old packed ones left, none of the live ones was packed');
    expect(rec.listSync().where((f) => f.path.endsWith('.removed.json')), hasLength(4));
  });

  test('Export leaves out the file set being written and takes it the next time', () async {
    final a = writeSet(DateTime(2026, 11, 18, 9), 5);
    final b = writeSet(DateTime(2026, 11, 18, 13), 5, recording: a);
    final out = Directory('${files.path}-export')..createSync();
    addTearDown(() => out.deleteSync(recursive: true));
    final first = await runExport(filesDir: files, target: DirectoryTarget(out), everything: false, open: openSets(files, a));
    expect(first.complete, isTrue);
    expect(first.stillWritten, unorderedEquals(['recordings/$b.f32', 'recordings/$b.idx', 'recordings/$b.log', 'recordings/$b.header.json']));
    expect(File('${out.path}/$exportFolderName/recordings/$a.f32').existsSync(), isTrue);
    expect(File('${out.path}/$exportFolderName/recordings/$b.f32').existsSync(), isFalse);
    expect(pendingExport(files).files, 4);
    final second = await runExport(filesDir: files, target: DirectoryTarget(out), everything: false);
    expect(second.stillWritten, isEmpty);
    expect(second.files, 4);
    expect(File('${out.path}/$exportFolderName/recordings/$b.f32').existsSync(), isTrue);
  });

  test('the Record tab\'s line: what the recordings take and what waits for the laptop', () {
    final r = allDay();
    var s = rawOnPhone(files);
    final all = [for (final x in [...r.day, ...r.night]) ...rawFilesOf(File('${rec.path}/$x.f32'))].fold(0, (n, f) => n + f.lengthSync());
    expect((s.bytes, s.waiting), (all, all));
    expect(storageLine(s, paired: true), 'Recordings on this phone: ${sizeText(all)}. All of it waits for the laptop to check it.');
    expect(storageLine(s, paired: false), 'Recordings on this phone: ${sizeText(all)}. No laptop is paired: nothing is cleared by itself.');
    ack(r.day);
    s = rawOnPhone(files);
    final day = [for (final x in r.day) ...rawFilesOf(File('${rec.path}/$x.f32'))].fold(0, (n, f) => n + f.lengthSync());
    expect((s.bytes, s.waiting), (all, all - day));
    expect(storageLine(s, paired: true), 'Recordings on this phone: ${sizeText(all)}. ${sizeText(all - day)} waits for the laptop to check it.');
    ack(r.night);
    expect(storageLine(rawOnPhone(files), paired: true), 'Recordings on this phone: ${sizeText(all)}. The laptop has checked all of it.');
    expect(storageLine((bytes: 0, waiting: 0), paired: true), isNull);
  });
}
