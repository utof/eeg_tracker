// What the phone reads on the screen's thread at every app start and return (DECISIONS 620-629), counted on a made-up
// folder with 60 days of history (test/support/app_folder.dart). Before the sweep one night screen refresh opened
// 731 files there on the screen's thread: every check-in, nap, dream session and lucid night for five lines, every
// report for the study reminders, every recording's index for the nights' list. Now: a handful at the first refresh,
// none at the next while nothing changed, and the reports and recordings only in background isolates. The lines and
// the moments armed are the same as before.
import 'dart:io';

import 'package:eeg_tracker/cache/file_summaries.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/nap/rules.dart' show NapEnd;
import 'package:eeg_tracker/nap/store.dart';
import 'package:eeg_tracker/recorder/nights.dart' show nightLabel;
import 'package:eeg_tracker/sharp/page.dart' show recentNights;
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/sleep/live_stager.dart' show LiveMode;
import 'package:eeg_tracker/study/arm.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:eeg_tracker/ui/dream_view.dart' show clock;
import 'package:eeg_tracker/ui/lucid_screen.dart';
import 'package:eeg_tracker/ui/lucid_view.dart' show LucidDue;
import 'package:eeg_tracker/ui/memory_cues_screen.dart' show memoryNightLine;
import 'package:eeg_tracker/ui/morning_screen.dart' show checkedInTodayAt;
import 'package:eeg_tracker/ui/nap_view.dart' show endWords;
import 'package:eeg_tracker/ui/night_lines.dart';
import 'package:eeg_tracker/wearer/wearer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sharp_prompts_test.dart' show FakeSharpPhone;
import 'support/app_folder.dart';
import 'support/read_count.dart';

void main() {
  late Directory root;
  late String rec;
  final now = DateTime(2026, 11, 20, 9);
  setUpAll(() {
    root = Directory.systemTemp.createTempSync('heavy_reads');
    rec = fakeAppFolder(root, days: 60, today: now, runs: 5);
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    JsonMemo.clear(); // a new process
    SummaryIndex.forgetAll();
  });

  group('the night screen\'s lines', () {
    test('the same lines as reading every file', () {
      final naps = NapStore(napDirFor(rec)).list(), dreams = DreamStore(dreamDirFor(rec)).list();
      final lines = nightLines(rec, now);
      expect(lines.nap, 'Last nap: ${nightLabel(naps.first.start)} ${clock(naps.first.start)}, 20 min, '
          '${endWords(naps.first)}.');
      expect(lines.dream, 'Last session: 0 answers, ${nightLabel(dreams.first.start)} ${clock(dreams.first.start)}.');
      expect(lines.checkedInAt, checkedInTodayAt(MorningStore(morningsDirFor(rec)).list(), now));
      expect(lines.checkedInAt, '07:40');
      final store = LucidStore(lucidDirFor(rec));
      expect(lines.lucid, 'On: practise first, it sets the loudness.');
      expect(lucidModel(store: store, now: now, nightRunning: false).due, LucidDue.practise);
      expect(lines.memory, memoryNightLine(rec, now: now));
    });

    test('a refresh opens a handful of files, the next none; a new nap only itself', () {
      final counts = countReads(addTearDown);
      nightLines(rec, now);
      // the newest nap, dream session and today's check-in; the lucid settings, newest night, its answers and the
      // practices; the memory cues' settings (never used)
      expect(counts.total, lessThanOrEqualTo(8), reason: '$counts');
      expect(counts.of('/naps/'), 1);
      expect(counts.of('/dream-catcher/'), 1);
      expect(counts.of('/files/mornings/'), 1);
      expect(counts.of('/lucid/nights/'), 1);
      counts.clear();
      nightLines(rec, now);
      expect(counts.total, 0, reason: 'nothing changed: $counts');

      final at = DateTime(2026, 11, 20, 8, 15);
      NapStore(napDirFor(rec)).save(
        NapSession(
          start: at,
          lengthMin: 30,
          recording: '2026-11-20-081500',
          live: const NapLiveInfo(mode: LiveMode.light, calls: 3),
          endS: 1800,
          end: NapEnd.length,
        ),
      );
      addTearDown(() => File('${napDirFor(rec).path}/2026-11-20-081500.nap.json').deleteSync());
      counts.clear();
      expect(nightLines(rec, now).nap, startsWith('Last nap: Fri 20 Nov 08:15, 30 min'));
      expect(counts.byPath.keys, [endsWith('/naps/2026-11-20-081500.nap.json')]);
    });

    test('a damaged newest file: the one before it, as when every file was read', () {
      final bad = File('${dreamDirFor(rec).path}/2026-11-20-010000.dream.json')..writeAsStringSync('{cut');
      addTearDown(bad.deleteSync);
      expect(nightLines(rec, now).dream, contains('Thu 19 Nov 23:10'));
    });
  });

  group('the study reminders at every start and return', () {
    test('armed from a background isolate: no file read on the screen\'s thread', () async {
      final phone = FakeSharpPhone();
      final counts = countReads(addTearDown);
      await rearmInBackground(rec, phone, now);
      expect(counts.total, 0, reason: '$counts');
      expect(phone.armed.single, isNotEmpty);
    });

    test('only the recent nights\' reports are opened, and the moments are those of every report', () {
      SharpStore(sharpDirFor(rec)).settings(); // nothing saved: the study reminders alone
      final counts = countReads(addTearDown);
      final planned = promptsFromFiles(rec, now);
      expect(counts.of('/files/nights/'), lessThanOrEqualTo(18), reason: 'of 60 reports');
      final store = StudyStore(studyDirFor(rec));
      final every = plannedPrompts(
        now: now,
        sharp: SharpStore(sharpDirFor(rec)).settings(),
        study: store.settings(),
        reports: ownNightReports(rec),
        answers: store.answers(),
      );
      expect(recentNights(ownNightReports(rec), now).length, greaterThanOrEqualTo(3), reason: 'the nights set the times');
      expect(planned.map((p) => '$p'), every.map((p) => '$p'));
      expect(planned.where((p) => p.kind.isStudy), isNotEmpty);
    });

    test('recentOwnNightReports: the nights a recent final wake-up can come from, newest first', () {
      final r = recentOwnNightReports(rec, now);
      expect(r.first.nightOf, '2026-11-19');
      expect(r.last.nightOf, '2026-11-02');
      expect(r, hasLength(18));
    });
  });
}
