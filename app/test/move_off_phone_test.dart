// Moving raw recordings to the laptop (DECISIONS 690-699): the laptop's acks (recorder/acks.dart) through Share on
// Wi-Fi's `POST /ack` (share/server.dart), the one helper that removes a set's raw files (recorder/remove.dart), the
// Storage page's rules (storage/: by hand, by time, the Danger zone) and view, and what the nights, the sleep scoring
// and the screens make of a set whose raw files left the phone. Plain folders and real sockets on 127.0.0.1; the
// recordings are made up.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:eeg_tracker/dream/answer_text.dart' show AnswerText, writeAnswerText;
import 'package:eeg_tracker/export/exporter.dart';
import 'package:eeg_tracker/recorder/acks.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/recorder/packed.dart' show packRaw, packedFileOf;
import 'package:eeg_tracker/recorder/remove.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/storage/clear.dart';
import 'package:eeg_tracker/storage/storage.dart';
import 'package:eeg_tracker/ui/storage_bar.dart';
import 'package:eeg_tracker/ui/storage_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const token = 'abcdefghjkmn';
const key = 'a2V5LWZvci10aGUtYWNrLWZpeHR1cmUtb25seS0zMi1ieXRlcw';

void main() {
  late Directory files, rec;
  final random = Random(690);

  setUp(() {
    files = Directory.systemTemp.createTempSync('move_off_phone');
    rec = Directory('${files.path}/recordings')..createSync();
    forgetNightSets();
  });
  tearDown(() => files.deleteSync(recursive: true));

  /// Two hours from now: every file made here was written more than an hour before it.
  DateTime later() => DateTime.now().add(const Duration(hours: 2));

  String sha(File f) => sha256.convert(f.readAsBytesSync()).toString();

  /// A recording from [start] whose last batch arrives an hour later: random samples (packing gains little, and every
  /// set's bytes differ), an index row, a log and markers.
  String run(DateTime start, {Directory? dir, int records = 5000}) {
    final d = dir ?? rec;
    final stem = fileStem(start);
    File('${d.path}/$stem.f32').writeAsBytesSync([for (var i = 0; i < records * 20; i++) random.nextInt(256)]);
    final idx = ByteData(16)
      ..setFloat64(0, start.add(const Duration(hours: 1)).microsecondsSinceEpoch / 1e6, Endian.little)
      ..setUint64(8, records, Endian.little);
    File('${d.path}/$stem.idx').writeAsBytesSync(idx.buffer.asUint8List());
    File('${d.path}/$stem.log').writeAsStringSync('started\n');
    File('${d.path}/$stem.markers.jsonl').writeAsStringSync('{"t":1,"i":0,"text":"lights off"}\n');
    return stem;
  }

  /// The night's sleep report, made from its recordings as they are now.
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

  /// The laptop's checked copy of each raw file of [stems] (in [dir]) as it is now, acked at [at] (unix ms).
  void ack(Iterable<String> stems, {Directory? dir, int at = 0}) {
    final d = dir ?? rec;
    final folder = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final kept = <String, LaptopCopy>{};
    for (final stem in stems) {
      for (final f in rawFilesOf(File('${d.path}/$stem.f32'))) {
        final path = '$folder/${f.uri.pathSegments.last}';
        final st = f.statSync();
        kept[ackPathOf(path)] = LaptopCopy(
          sha256: sha(f),
          bytes: st.size,
          modifiedMs: st.modified.millisecondsSinceEpoch,
          ackedMs: at,
        );
      }
    }
    AckStore(files).add(kept);
  }

  /// The laptop's checked copy of one file at [path] (relative to files/).
  void ackFile(String path, {int at = 0}) {
    final f = File('${files.path}/$path');
    final st = f.statSync();
    AckStore(files).add({path: LaptopCopy(sha256: sha(f), bytes: st.size, modifiedMs: st.modified.millisecondsSinceEpoch, ackedMs: at)});
  }

  List<String> names(Directory d) => (d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList())..sort();

  group('the proof and the acks', () {
    test('an ack is kept only for the bytes the phone holds: a wrong hash, a file still written or one not shared are refused', () async {
      final stem = run(DateTime(2026, 11, 17, 23));
      final f32 = File('${rec.path}/$stem.f32');
      Future<String?> plain(File f, FileStat _) async => sha(f);
      Future<({LaptopCopy? copy, String? why})> check(String path, String digest, {DateTime? now}) =>
          checkAck(files, path, digest, now: now ?? later(), plainSha: plain);
      expect((await check('recordings/$stem.f32', '0' * 64)).why, 'different bytes');
      expect((await check('recordings/$stem.f32', sha(f32), now: DateTime.now())).why, 'still being written');
      expect((await check('cache/share-hashes.json', sha(f32))).why, 'not a file the phone shares');
      expect((await check('transfer/acks.json', sha(f32))).why, 'not a file the phone shares');
      expect((await check('recordings/$stem.log', sha(f32))).why, 'different bytes', reason: 'any shared file may be acked');
      expect((await check('recordings/2026-11-10-230000.f32', sha(f32))).why, 'not on the phone');
      final ok = await check('recordings/$stem.f32', sha(f32));
      expect(ok.why, isNull);
      expect((ok.copy!.sha256, ok.copy!.bytes), (sha(f32), f32.lengthSync()));
    });

    test('an ack outlives the packing (by the packed file\'s original), not a change of the bytes', () async {
      final stem = run(DateTime(2026, 11, 17, 23));
      final f32 = File('${rec.path}/$stem.f32');
      final digest = sha(f32);
      ack([stem]);
      expect(ackedNow(AckStore(files).load(), 'recordings/$stem.f32', f32), isTrue);
      packRaw(f32);
      final gz = packedFileOf(f32);
      expect(ackedNow(AckStore(files).load(), 'recordings/$stem.f32.gz', gz), isTrue, reason: 'the same bytes, packed');
      // the laptop acks the packed file by its original's hash, never the gzip file's own
      final r = await checkAck(files, 'recordings/$stem.f32.gz', digest, now: later(), plainSha: (_, _) async => null);
      expect(r.copy?.sha256, digest);
      final idx = File('${rec.path}/$stem.idx')..writeAsBytesSync([1, 2, 3], mode: FileMode.append);
      expect(ackedNow(AckStore(files).load(), 'recordings/$stem.idx', idx), isFalse, reason: 'the index grew');
    });

    test('acking the same bytes again keeps the first time (the keep time counts from it); new bytes start again', () {
      final stem = run(DateTime(2026, 11, 17, 23));
      ack([stem], at: 1000);
      ack([stem], at: 5000);
      expect(AckStore(files).load()['recordings/$stem.f32']!.ackedMs, 1000);
      File('${rec.path}/$stem.idx').writeAsBytesSync([9], mode: FileMode.append);
      ack([stem], at: 7000);
      expect(AckStore(files).load()['recordings/$stem.idx']!.ackedMs, 7000);
    });
  });

  group('removing a set\'s raw files', () {
    test('never while read, written in the last hour or not checked on the laptop; then only the samples and index go', () async {
      final stem = run(DateTime(2026, 11, 17, 23));
      final f32 = File('${rec.path}/$stem.f32');
      final size = f32.lengthSync();
      expect(whyNotRemove(f32, onlyIfOnLaptop: true, acks: AckStore(files).load(), now: later()), 'not checked on the laptop yet');
      ack([stem]);
      final acks = AckStore(files).load();
      expect(whyNotRemove(f32, onlyIfOnLaptop: true, acks: acks, now: DateTime.now()), 'written in the last hour');
      await RawUse.hold([f32.path], () async {
        expect(removeRaw(f32, onlyIfOnLaptop: true, acks: acks, why: whyMoved, now: later()).refused, 'being read on the phone');
      });
      await RawUse.hold([rec.path], () async {
        expect(whyNotRemove(f32, onlyIfOnLaptop: true, acks: acks, now: later()), 'being read on the phone', reason: 'its folder');
      });
      expect(f32.existsSync(), isTrue);
      final r = removeRaw(f32, onlyIfOnLaptop: true, acks: acks, why: whyMoved, laptop: 'desk', now: later());
      expect((r.removed, r.refused), (true, null));
      expect(names(rec), ['$stem.log', '$stem.markers.jsonl', '$stem.removed.json']);
      final record = removedRecordOf(f32)!;
      expect((record.onLaptop, record.laptop, record.why, record.night), (true, 'desk', whyMoved, '2026-11-17'));
      expect(record.endMs, DateTime(2026, 11, 18).millisecondsSinceEpoch);
      expect(record.samplesBytes, size);
      expect(rawRemoved(f32), isTrue);
      // again: nothing left to remove, nothing changed
      expect(removeRaw(f32, onlyIfOnLaptop: true, acks: acks, why: whyMoved, now: later()).refused, 'no raw files on the phone');
      expect(removedRecordOf(f32)!.files.length, 2);
    });

    test('by hand (the Archive): without an ack when the owner asks, and the record says it is not on the laptop', () {
      final stem = run(DateTime(2026, 11, 17, 23));
      final f32 = File('${rec.path}/$stem.f32');
      final r = removeRaw(f32, onlyIfOnLaptop: false, acks: const {}, why: whyByHand, now: later());
      expect(r.removed, isTrue);
      expect(removedRecordOf(f32)!.onLaptop, isFalse);
      expect(rawGoneText([removedRecordOf(f32)!]), "This night's raw recording was deleted from this phone.");
    });
  });

  group('the Storage page\'s rules', () {
    final now = later();
    final dayMs = const Duration(days: 1).inMilliseconds;

    /// Five nights, each reported: the 15th to the 19th.
    List<String> fiveNights() {
      final stems = [for (var d = 15; d <= 19; d++) run(DateTime(2026, 11, d, 23))];
      for (final n in nightsIn(rec)) {
        report(n);
      }
      return stems;
    }

    test('every file has its kind; the statistics are always kept', () {
      final stem = run(DateTime(2026, 11, 17, 23));
      File('${rec.path}/$stem.header.json').writeAsStringSync('{"session":"work"}');
      String? session(String p) => sessionOf(File('${files.path}/$p.f32'));
      expect(classify('recordings/$stem.f32', session: session), 'work.raw');
      expect(classify('recordings/2026-11-18-230000.f32.gz'), 'nights.raw');
      expect(classify('recordings/2026-11-18-230000.idx'), 'nights.raw');
      expect(classify('recordings/2026-11-18-230000.log'), 'logs.recorder');
      expect(classify('recordings/2026-11-18-230000.header.json'), 'other.all');
      expect(classify('recordings/2026-11-18-230000.removed.json'), 'other.all');
      expect(classify('recordings-diy/2026-11-18-230000.f32'), 'diy.raw');
      expect(classify('mornings/2026-11-18-073000.f32'), 'checkins.raw');
      expect(classify('mornings/2026-11-18-073000.morning.json'), 'checkins.results');
      expect(classify('nights/2026-11-18.report.json'), 'nights.reports');
      expect(classify('dream-catcher/2026-11-18-230000-r1.wav'), 'dream.audio');
      expect(classify('dream-catcher/2026-11-18-230000-r1.text.json'), 'dream.text');
      expect(classify('dream-catcher/prompts/theme.wav'), 'dream.sessions', reason: 'the owner\'s own prompts stay');
      expect(classify('work-sessions/2026-11-18-100000.work.json'), 'work.summaries');
      expect(classify('cache/share-hashes.json'), 'cache.all');
      expect(classify('settings.json'), 'other.all');
      expect(classify('logs/app-2026-11-18-main.jsonl'), 'logs.app'); // the app's own records (lib/logs)
      for (final id in ['nights.reports', 'work.summaries', 'checkins.results', 'dream.text', 'other.all', 'logs.app']) {
        expect(storageItems[id]!.kept, isTrue, reason: id);
      }
      expect({for (final i in storageItems.values) if (i.auto) i.id}, {'nights.raw', 'work.raw', 'dream.audio', 'checkins.raw', 'diy.raw'});
    });

    test('Clear selected: only what the laptop checked, a night whole, never before its report; the statistics stay', () async {
      final stems = fiveNights();
      final a = run(DateTime(2026, 11, 20, 2)); // joins the 19th's night, not acked
      ack(stems); // every night's first set
      final plan = planClear(files, {'nights.raw', 'nights.reports'}, mode: ClearMode.checked, now: now);
      expect([for (final g in plan.groups) g.night], ['2026-11-15', '2026-11-16', '2026-11-17', '2026-11-18']);
      expect(plan.why['nights.raw'], 'not checked on the laptop yet', reason: 'the 19th: one set is only on the phone');
      expect(plan.files, isEmpty, reason: 'reports are never planned');
      final r = await runClear(files, plan, busy: () async => false, clock: later);
      expect(r.removed.length, 4);
      expect(File('${rec.path}/$a.f32').existsSync() && File('${rec.path}/${stems.last}.f32').existsSync(), isTrue);
      expect(NightReportStore(nightsDirFor(rec.path)).all().length, 5);
      expect(removedRecordOf(File('${rec.path}/${stems.first}.f32'))!.why, whyCleared);
      // a night without its report stays whatever the laptop has
      final b = run(DateTime(2026, 11, 10, 23));
      ack([b]);
      final again = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: now);
      expect(again.groups, isEmpty);
      expect(again.why['nights.raw'], isNotNull);
      expect(File('${rec.path}/$b.f32').existsSync(), isTrue);
    });

    test('automatic: only while paired, 3 days after the laptop checked by default, never what is only on the phone', () async {
      final stems = fiveNights();
      final t = now.millisecondsSinceEpoch;
      ack([stems[0]], at: t - 5 * dayMs); // checked 5 days ago
      ack([stems[1]], at: t - 1 * dayMs); // yesterday
      // stems[2..4]: only on the phone
      expect(await autoClear(files, busy: () async => false, paired: false, clock: () => now), isNull);
      expect(File('${rec.path}/${stems[0]}.f32').existsSync(), isTrue);
      expect(StorageStore(files).load().keepDays('nights'), 3);
      expect(await autoClear(files, busy: () async => true, paired: true, clock: () => now), isNull, reason: 'busy');
      final r = (await autoClear(files, busy: () async => false, paired: true, laptop: 'desk', clock: () => now))!;
      expect(r.removed, ['2026-11-15']);
      expect(removedRecordOf(File('${rec.path}/${stems[0]}.f32'))!.why, whyKeepTime);
      expect(File('${rec.path}/${stems[1]}.f32').existsSync(), isTrue, reason: 'checked only a day ago');
      // a week: nothing more; Never: nothing at all
      StorageStore(files).save(const StorageSettings().withKeep('nights', 7));
      expect((await autoClear(files, busy: () async => false, paired: true, clock: () => now.add(const Duration(days: 3))))!.removed, isEmpty);
      StorageStore(files).save(const StorageSettings().withKeep('nights', 0));
      final never = await autoClear(files, busy: () async => false, paired: true, clock: () => now.add(const Duration(days: 60)));
      expect(never?.removed ?? const <String>[], isEmpty);
      for (final s in stems.skip(1)) {
        expect(File('${rec.path}/$s.f32').existsSync(), isTrue);
      }
    });

    test('the Danger zone: only what is NOT on the laptop, by hand; the record says it is gone for good', () async {
      final stems = fiveNights();
      ack([stems[0]]);
      final plan = planClear(files, {'nights.raw'}, mode: ClearMode.phoneOnly, now: now);
      expect([for (final g in plan.groups) g.night], ['2026-11-16', '2026-11-17', '2026-11-18', '2026-11-19']);
      expect(plan.count['nights.raw'], 4);
      final r = await runClear(files, plan, busy: () async => false, clock: later);
      expect(r.removed.length, 4);
      final rec16 = removedRecordOf(File('${rec.path}/${stems[1]}.f32'))!;
      expect((rec16.onLaptop, rec16.why), (false, whyPhoneOnly));
      expect(rawGoneText([rec16]), "This night's raw recording was deleted from this phone.");
      expect(File('${rec.path}/${stems[0]}.f32').existsSync(), isTrue, reason: 'on the laptop: not the Danger zone\'s');
    });

    test('a spoken answer stays until it has its words; an old set\'s log stays while its samples need it', () async {
      final dream = Directory('${files.path}/dream-catcher')..createSync();
      File('${dream.path}/2026-11-15-230000-r1.wav').writeAsBytesSync(List.filled(5000, 1));
      File('${dream.path}/2026-11-15-230000-r2.wav').writeAsBytesSync(List.filled(5000, 2));
      writeAnswerText(dream, const AnswerText(answer: '2026-11-15-230000-r1.wav', edited: 'a red door'));
      ackFile('dream-catcher/2026-11-15-230000-r1.wav');
      ackFile('dream-catcher/2026-11-15-230000-r2.wav');
      final stem = run(DateTime(2026, 11, 15, 23)); // no header: its log says what its samples hold
      ackFile('recordings/$stem.log');
      final plan = planClear(files, {'dream.audio', 'logs.recorder'}, mode: ClearMode.checked, now: now);
      expect([for (final f in plan.files) f.path], ['dream-catcher/2026-11-15-230000-r1.wav']);
      expect(plan.why['dream.audio'], 'not turned into words yet');
      expect(plan.why['logs.recorder'], 'its recording still needs it');
      await runClear(files, plan, busy: () async => false, clock: later);
      expect(File('${dream.path}/2026-11-15-230000-r1.wav').existsSync(), isFalse);
      expect(File('${dream.path}/2026-11-15-230000-r1.text.json').existsSync(), isTrue);
      expect(fileGoneText(files, 'dream-catcher/2026-11-15-230000-r1.wav'), 'This recording is on the laptop now, not on this phone.');
    });

    test('a work session\'s raw EEG goes set by set, and a set of no night by its own ack', () async {
      final work = run(DateTime(2026, 11, 12, 10));
      File('${rec.path}/$work.header.json').writeAsStringSync('{"session":"work"}');
      final night = run(DateTime(2026, 11, 19, 23));
      for (final n in nightsIn(rec)) {
        report(n);
      }
      ack([work, night]);
      List<NightFiles> withoutWork(Directory d) => [
        for (final n in nightsIn(d))
          if (!n.files.any((f) => f.path.contains(work))) n, // as nights.dart does once work sets are no night
      ];
      final plan = planClear(files, {'work.raw', 'nights.raw'}, mode: ClearMode.checked, now: now, nights: withoutWork);
      expect([for (final g in plan.groups) (g.item, g.night, g.sets.length)], [('nights.raw', '2026-11-19', 1), ('work.raw', null, 1)]);
    });

    test('the usage: by kind and by category, what may go now, what only the Danger zone could, what the laptop has', () {
      final stems = fiveNights();
      ack(stems.take(2));
      final u = scanStorage(files, now: now);
      expect(u.bytes['nights.raw'], greaterThan(5 * 100000));
      expect(u.clearable['nights.raw'], greaterThan(2 * 100000));
      expect(u.phoneOnly['nights.raw'], greaterThan(3 * 100000));
      expect(u.phoneOnlyCount['nights.raw'], 3);
      expect(u.bytes['nights.reports'], greaterThan(0));
      expect(u.clearable.containsKey('nights.reports'), isFalse);
      expect(u.onLaptop, u.clearable['nights.raw']);
      final cats = {for (final c in usageByCategory(u)) c.id: c.bytes};
      expect(cats['nights'], u.bytes['nights.raw']! + u.bytes['nights.reports']!);
      expect(cats.values.fold(0, (a, b) => a + b), u.total);
      expect(storageSegments(u).first.id, 'nights');
    });
  });

  group('without the raw files', () {
    test('the nights keep their shape, the scoring never scores a moved night again, the report stays', () async {
      for (var d = 15; d <= 19; d++) {
        run(DateTime(2026, 11, d, 23));
        run(DateTime(2026, 11, d + 1, 3)); // the same night, after a gap
      }
      for (final n in nightsIn(rec)) {
        report(n);
      }
      ack({
        for (final f in rec.listSync())
          if (!f.uri.pathSegments.last.startsWith('2026-11-19') && !f.uri.pathSegments.last.startsWith('2026-11-20'))
            f.uri.pathSegments.last.substring(0, 17), // the 19th's night stays only on the phone
      });
      final before = [for (final n in nightsIn(rec)) (n.name, n.start, n.end, n.runs)];
      final plan = planClear(files, {'nights.raw'}, mode: ClearMode.checked, now: later());
      await runClear(files, plan, busy: () async => false, laptop: 'desk', clock: later);
      forgetNightSets();
      final after = nightsIn(rec);
      expect([for (final n in after) (n.name, n.start, n.end, n.runs)], before);
      final moved = after.where((n) => n.name == '2026-11-15').single;
      expect(moved.recordings, isEmpty);
      expect(moved.removed.length, 2);
      final scorer = SleepScorer(
        recordingsDir: rec,
        store: NightReportStore(nightsDirFor(rec.path)),
        openRun: (_) => throw StateError('no model in this test'),
      );
      expect(scorer.due(), isEmpty);
      scorer.request('2026-11-15'); // "Score again" on a moved night does nothing
      expect(scorer.due(), isEmpty);
      expect(NightReportStore(nightsDirFor(rec.path)).read('2026-11-15'), isNotNull);
      expect(rawGoneText(removedOfNight(rec, '2026-11-15')), "This night's raw recording is on the laptop now (desk).");
      expect(removedOfNight(rec, '2026-11-19'), isEmpty);
    });

    test('Export data names the files that left the phone; the share list and the pending export do not miss them', () async {
      final stem = run(DateTime(2026, 11, 15, 23));
      final out = Directory('${files.path}/../move_export_${files.uri.pathSegments.where((s) => s.isNotEmpty).last}')
        ..createSync();
      addTearDown(() => out.deleteSync(recursive: true));
      await runExport(filesDir: files, target: DirectoryTarget(out), everything: false);
      ack([stem]);
      removeRaw(File('${rec.path}/$stem.f32'), onlyIfOnLaptop: true, acks: AckStore(files).load(), why: whyMoved, now: later());
      final r = await runExport(filesDir: files, target: DirectoryTarget(out), everything: false);
      expect(r.complete, isTrue);
      final m = jsonDecode(File('${out.path}/eeg-export/manifest.json').readAsStringSync()) as Map<String, Object?>;
      final byPath = {for (final f in (m['files']! as List).cast<Map<String, Object?>>()) f['path']: f};
      expect(byPath['recordings/$stem.f32']!['on_phone'], isFalse);
      expect(byPath['recordings/$stem.f32']!['removed'], whyMoved);
      expect(byPath['recordings/$stem.removed.json'], isNotNull, reason: 'the record travels like any file');
      expect(byPath['recordings/$stem.log']!.containsKey('removed'), isFalse);
      expect(byPath.keys.where((p) => '$p'.startsWith('transfer/')), isEmpty, reason: 'the acks stay on the phone');
    });

    testWidgets('the Storage page: the bar opens a category, the statistics have no box, the promise, the Danger zone', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400 * 3);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final u = StorageUsage(
        bytes: {'nights.raw': 2100000000, 'nights.reports': 4000000, 'dream.audio': 90000000, 'other.all': 3000000},
        files: const {},
        clearable: {'nights.raw': 1200000000, 'dream.audio': 90000000},
        phoneOnly: {'nights.raw': 900000000},
        phoneOnlyCount: {'nights.raw': 4},
        why: {'nights.raw': 'not checked on the laptop yet'},
        onLaptop: 14300000000,
      );
      final tapped = <String>[], selected = <String>[];
      var m = StorageViewModel(usage: u, paired: true, laptop: 'desk', space: (total: 128000000000, free: 41000000000));
      Widget page() => MaterialApp(
        theme: nightTheme(),
        home: StorageView(
          model: m,
          onSelect: (i, on) => selected.add('$i $on'),
          onExpand: tapped.add,
          onKeep: (_, _) {},
          onClear: () {},
          onDanger: (_, _) {},
          onDangerDelete: () {},
          onSegment: tapped.add,
        ),
      );
      await tester.pumpWidget(page());
      expect(find.textContaining('2.2', findRichText: true), findsOneWidget);
      String nb(String s) => s.replaceAll(RegExp(r'(?<=\d) (?=[MG]B)'), '\u00a0'); // sizeText keeps number and unit together
      expect(find.text(nb('41.0 GB free of 128.0 GB')), findsOneWidget);
      expect(find.text(nb('14.3 GB')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('storage-segment-nights')));
      expect(tapped, ['nights']);
      expect(find.text(automaticPromise), findsOneWidget);
      expect(find.text('3 days'), findsWidgets);
      expect(find.text('Clear selected'), findsOneWidget);
      m = StorageViewModel(usage: u, paired: true, expanded: const {'nights'}, selected: const {'nights.raw'}, danger: const {'nights.raw'});
      await tester.pumpWidget(page());
      expect(find.text(nb('Clear selected · 1.2 GB')), findsOneWidget);
      expect(find.text('Always kept'), findsOneWidget);
      expect(find.textContaining(nb('900 MB stays: not checked on the laptop yet')), findsOneWidget);
      expect(find.bySemanticsLabel('Select Sleep reports'), findsNothing, reason: 'the statistics have no box');
      expect(find.text('Danger zone'), findsOneWidget);
      expect(find.text(nb('Delete from this phone only · 900 MB')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('the bar keeps a small category visible and adds up to its width', () {
      final w = StorageBar.widths([1000000000, 1000, 500000000], 300);
      expect(w[1], 4);
      expect(w.fold(0.0, (a, b) => a + b) + 2 * 2, closeTo(300, 0.01));
    });
  });
}
