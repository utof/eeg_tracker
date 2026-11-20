// Automatic recording, phase 1 (DECISIONS 600-609): the settings and state files, the log of every guess and answer,
// and the minutes kept in memory while the app asks ("No" writes nothing; "Yes" writes them at the real start).
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/auto/log.dart';
import 'package:eeg_tracker/auto/preroll.dart';
import 'package:eeg_tracker/auto/store.dart';
import 'package:eeg_tracker/export/store.dart' show isExported;
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:flutter_test/flutter_test.dart';

List<Sample> batch(int first, [int n = 8]) => [
  for (var i = 0; i < n; i++) Sample.four(pack: first + i, o1: 1e-5, o2: 2e-5, t3: -1e-5, t4: 3e-6),
];

void main() {
  late Directory tmp;
  late AutoStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('auto');
    store = AutoStore(autoDirFor('${tmp.path}/recordings'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the folder sits beside the recordings and leaves the phone with Export data', () {
    expect(autoDirFor('/data/files/recordings').path, '/data/files/auto-start');
    for (final f in ['settings.json', 'state.json', 'log.jsonl', 'laptop.json']) {
      expect(isExported('auto-start/$f'), isTrue, reason: f);
    }
  });

  group('settings', () {
    test('every kind starts on "Ask me"; the chime is off; the bedtime follows the nights', () {
      final s = store.settings();
      for (final k in WearKind.values) {
        expect(s.choice(k), AutoChoice.ask, reason: k.wire);
      }
      expect(s.workChime, isFalse);
      expect(s.bedtimeByHand, isFalse);
      expect(s.allOff, isFalse);
    });

    test('saved whole and read back; no temporary file left', () {
      store.saveSettings(
        const AutoSettings()
            .withChoice(WearKind.night, AutoChoice.start)
            .withChoice(WearKind.work, AutoChoice.nothing)
            .withChime(true)
            .withBedtime(22 * 60, 6 * 60 + 30),
      );
      final s = store.settings();
      expect(s.choice(WearKind.night), AutoChoice.start);
      expect(s.choice(WearKind.work), AutoChoice.nothing);
      expect(s.choice(WearKind.other), AutoChoice.ask);
      expect((s.workChime, s.bedMin, s.wakeMin), (true, 22 * 60, 6 * 60 + 30));
      expect(store.dir.listSync().map((f) => f.uri.pathSegments.last), ['settings.json']);
    });

    test('other cannot start automatically yet: read as "Ask me"', () {
      final s = const AutoSettings().withChoice(WearKind.other, AutoChoice.start);
      expect(s.choice(WearKind.other), AutoChoice.ask);
    });

    test('all three "Do nothing": no checks at all', () {
      var s = const AutoSettings();
      for (final k in WearKind.values) {
        s = s.withChoice(k, AutoChoice.nothing);
      }
      expect(s.allOff, isTrue);
    });

    test('a half-written or foreign file gives the defaults', () {
      store.dir.createSync(recursive: true);
      File('${store.dir.path}/settings.json').writeAsStringSync('{"version": 1, "choi');
      expect(store.settings().choice(WearKind.night), AutoChoice.ask);
      File('${store.dir.path}/settings.json').writeAsStringSync('{"version": 2, "choices": {"night": "start"}}');
      expect(store.settings().choice(WearKind.night), AutoChoice.ask);
    });
  });

  test('state: quiet times, streaks, offers and the wearing survive a new engine', () {
    final t = DateTime(2026, 11, 20, 22, 40);
    store.saveState(
      AutoState(
        quietUntil: {WearKind.night: t.add(const Duration(minutes: 30))},
        yesStreak: {WearKind.work: 7},
        offered: {WearKind.night},
        wornSince: t,
        askedThisWearing: {WearKind.night},
        chargeNoticeDay: '2026-11-20',
      ),
    );
    final s = store.state();
    expect(s.quiet(WearKind.night, t.add(const Duration(minutes: 29))), isTrue);
    expect(s.quiet(WearKind.night, t.add(const Duration(minutes: 30))), isFalse);
    expect(s.quiet(WearKind.work, t), isFalse);
    expect(s.yesStreak[WearKind.work], 7);
    expect(s.offered, {WearKind.night});
    expect(s.wornSince, t);
    expect(s.askedThisWearing, {WearKind.night});
    expect(s.chargeNoticeDay, '2026-11-20');
    expect(s.copyWith(wornSince: () => null).wornSince, isNull);
  });

  group('the log', () {
    test('one line per event, read back in order; a cut line is skipped', () {
      final log = AutoLog(store.dir);
      final t = DateTime(2026, 11, 20, 23, 5);
      log.add(t, 'check', {'trigger': 'bedtime', 'worn': true, 'guess': 'night'});
      store.dir.createSync(recursive: true);
      File('${store.dir.path}/log.jsonl').writeAsStringSync('{"version": 1, "at"\n', mode: FileMode.append);
      log.add(t.add(const Duration(seconds: 20)), 'question', {'kind': 'night'});
      final e = log.events();
      expect([for (final x in e) x['event']], ['check', 'question']);
      expect(e.first['at'], startsWith('2026-11-20T23:05:00'));
      expect(e.first['trigger'], 'bedtime');
    });

    test('how often it was right, per kind: yes against not now; no answer and automatic starts apart', () {
      final log = AutoLog(store.dir);
      final t = DateTime(2026, 11, 20, 23);
      void answer(String kind, String a) => log.add(t, 'answer', {'kind': kind, 'answer': a});
      answer('night', 'yes');
      answer('night', 'yes');
      answer('night', 'no');
      answer('night', 'none');
      answer('work', 'yes');
      answer('other', 'night'); // "other" was a wrong guess: it was the night
      answer('other', 'no');
      log.add(t, 'start', {'kind': 'night', 'how': 'automatic'});
      final s = log.stats();
      expect((s[WearKind.night]!.asked, s[WearKind.night]!.yes, s[WearKind.night]!.no, s[WearKind.night]!.unanswered), (4, 2, 1, 1));
      expect(s[WearKind.night]!.automatic, 1);
      expect(s[WearKind.night]!.rightText, '2 of 3 answered: right');
      expect(s[WearKind.work]!.rightText, '1 of 1 answered: right');
      expect(s[WearKind.other]!.relabelled, 1);
      expect(s[WearKind.other]!.rightText, '1 of 2 answered: something else');
    });
  });

  group('the minutes kept while asking', () {
    test('"No" writes nothing: the recordings folder is not even made', () {
      final p = Preroll();
      final t = DateTime(2026, 11, 20, 23, 0, 4);
      for (var i = 0; i < 100; i++) {
        p.add(t.add(Duration(milliseconds: 32 * i)), batch(i * 8));
      }
      expect(p.samples, 800);
      p.clear();
      expect(p.samples, 0);
      expect(Directory('${tmp.path}/recordings').existsSync(), isFalse);
      expect(p.write(Directory('${tmp.path}/recordings'), const []), isNull, reason: 'nothing left to write');
      expect(Directory('${tmp.path}/recordings').existsSync(), isFalse);
    });

    test('"Yes" writes one run named after the first sample, with every arrival time, and joins that night', () {
      final p = Preroll();
      final t = DateTime(2026, 11, 20, 23, 0, 4);
      for (var i = 0; i < 10; i++) {
        p.add(t.add(Duration(milliseconds: 32 * i)), batch(i * 8));
      }
      final dir = Directory('${tmp.path}/recordings');
      final stem = p.write(dir, [(t, 'headband found on'), (t.add(const Duration(minutes: 2)), 'answered yes')]);
      expect(stem, '2026-11-20-230004');
      final f32 = File('${dir.path}/$stem.f32').readAsBytesSync();
      final idx = ByteData.sublistView(File('${dir.path}/$stem.idx').readAsBytesSync());
      expect(f32.length, 80 * recordBytes);
      expect(idx.lengthInBytes, 10 * indexBytes);
      expect(idx.getFloat64(0, Endian.little), unixSeconds(t));
      expect(idx.getUint64(indexBytes + 8, Endian.little), 8, reason: 'second batch starts at sample 8');
      expect(ByteData.sublistView(f32).getUint32(recordBytes * 79, Endian.little), 79);
      final log = File('${dir.path}/$stem.log').readAsStringSync();
      expect(log, contains('2026-11-20T23:00:04.000 headband found on'));
      expect(log, contains('answered yes'));
      // the recorder's first run, 40 s later, joins the same night
      ChunkWriter.open(dir, t.add(const Duration(seconds: 40)))
        ..addBatch(t.add(const Duration(seconds: 40)), batch(0))
        ..close();
      final nights = nightsIn(dir);
      expect(nights, hasLength(1));
      expect(nights.single.runs, 2);
      expect(nights.single.start, DateTime(2026, 11, 20, 23, 0, 4));
    });

    test('kept for at most 15 minutes from the first sample; later batches are dropped', () {
      final p = Preroll();
      final t = DateTime(2026, 11, 20, 23);
      p.add(t, batch(0));
      p.add(t.add(const Duration(minutes: 14, seconds: 59)), batch(8));
      expect(p.full, isFalse);
      p.add(t.add(const Duration(minutes: 15, seconds: 1)), batch(16));
      expect(p.samples, 16);
      expect(p.full, isTrue);
      expect(p.span, const Duration(minutes: 14, seconds: 59));
    });
  });
}
