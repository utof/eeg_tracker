// What the phone reads on the screen's thread at every app start and return (DECISIONS 620-629), counted on a made-up
// folder with 60 days of history (test/support/app_folder.dart). Before the sweep one night screen refresh opened
// 731 files there on the screen's thread: every check-in, nap, dream session and lucid night for five lines, every
// report for the study reminders, every recording's index for the nights' list. Now: a handful at the first refresh,
// none at the next while nothing changed, and the reports and recordings only in background isolates. The lines and
// the moments armed are the same as before.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/cache/file_summaries.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/lucid/morning.dart' show searchLastNight;
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/nap/rules.dart' show NapEnd;
import 'package:eeg_tracker/nap/store.dart';
import 'package:eeg_tracker/recorder/nights.dart' show dateName, nightLabel, nightOf;
import 'package:eeg_tracker/sharp/page.dart' show recentNights;
import 'package:eeg_tracker/sharp/store.dart';
import 'package:eeg_tracker/sleep/live_stager.dart' show LiveMode;
import 'package:eeg_tracker/study/arm.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/study/store.dart';
import 'package:eeg_tracker/ui/dream_view.dart' show clock;
import 'package:eeg_tracker/ui/lucid_screen.dart';
import 'package:eeg_tracker/ui/lucid_view.dart' show LucidDue;
import 'package:eeg_tracker/ui/memory_cues_screen.dart' show memoryNightLine;
import 'package:eeg_tracker/ui/nap_screen.dart' show napSessionRunning;
import 'package:eeg_tracker/ui/morning_screen.dart' show checkedInTodayAt;
import 'package:eeg_tracker/ui/nap_view.dart' show endWords;
import 'package:eeg_tracker/ui/night_lines.dart';
import 'package:eeg_tracker/wearer/check.dart';
import 'package:eeg_tracker/wearer/wearer.dart';
import 'package:eeg_tracker/try_these/cards.dart' show tryCards;
import 'package:eeg_tracker/try_these/seen.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/try_these_screen.dart' show TryTheseEntry;
import 'package:eeg_tracker/ui/trends_screen.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:eeg_tracker/work/days.dart';
import 'package:eeg_tracker/work/store.dart' show workDirFor;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sharp_prompts_test.dart' show FakeSharpPhone;
import 'support/app_folder.dart';
import 'support/read_count.dart';
import 'wearer_test.dart' show night;

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

  group('"Was this you?" on the sleep report, a check-in\'s result and Settings', () {
    test('the same verdicts as judging every file; each file read once, also in a new process', () {
      final counts = countReads(addTearDown);
      final first = refreshWearer(rec, now);
      final every = judgeWearer(
        wearerRecordings(NightReportStore(nightsDirFor(rec)).all(), MorningStore(morningsDirFor(rec)).list()),
      );
      expect(first.verdicts.length, every.length);
      for (final v in every) {
        expect(first.of(v.kind, v.id)?.state, v.state, reason: '${v.kind}:${v.id}');
      }
      expect(first.ready(kindNight), isTrue);
      counts.clear();
      final again = refreshWearer(rec, now);
      expect(counts.of('/files/nights/') + counts.of('/files/mornings/'), 0, reason: '$counts');
      expect(again.verdicts.keys, first.verdicts.keys);
      SummaryIndex.forgetAll(); // a new process, or the background isolate
      counts.clear();
      refreshWearer(rec, now);
      expect(counts.of('/files/nights/') + counts.of('/files/mornings/'), 0, reason: '$counts');
      expect(counts.of('/cache/wearer-'), 2, reason: 'the two kept indexes');
    });

    test('worked out in a background isolate: nothing read on the screen\'s thread', () async {
      final counts = countReads(addTearDown);
      final r = await wearerInBackground(rec, now);
      expect(counts.total, 0, reason: '$counts');
      expect(r.on, isTrue);
      expect(r.verdicts, isNotEmpty);
    });

    test('an answer changes its file, and only that file is read again', () {
      refreshWearer(rec, now);
      final counts = countReads(addTearDown);
      answerWearer(rec, kindNight, '2026-11-12', answerSomeoneElse, now);
      addTearDown(() => answerWearer(rec, kindNight, '2026-11-12', null, now));
      counts.clear();
      final r = refreshWearer(rec, now);
      expect(r.answers['$kindNight:2026-11-12'], answerSomeoneElse);
      expect(counts.of('/files/nights/'), 1, reason: '$counts');
    });
  });

  group('Trends', () {
    testWidgets('opens without reading the history on the screen\'s thread', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      final counts = countReads(addTearDown);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: TrendsScreen(recordingsDir: rec)));
      expect(find.text('Reading your days…'), findsOneWidget, reason: 'the page is up while the isolate reads');
      for (var i = 0; i < 300 && find.byType(TrendsView).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.byType(TrendsView), findsOneWidget);
      for (final folder in ['/files/nights/', '/files/mornings/', '/work-sessions/', '/meditations/']) {
        expect(counts.of(folder), 0, reason: '$folder: $counts');
      }
    });

    test('the same page as on the screen\'s thread; the work sessions are read again only when one changed', () {
      final kept = File('${root.path}/files/cache/work-days.json');
      if (kept.existsSync()) kept.deleteSync(); // as on the first open after the update
      final counts = countReads(addTearDown);
      final first = loadTrendsPage(rec, now);
      expect(counts.of('/work-sessions/'), 60);
      counts.clear();
      final again = loadTrendsPage(rec, now); // a new isolate at every open: nothing in memory
      expect(counts.of('/work-sessions/'), 0, reason: 'the kept day numbers: $counts');
      expect(counts.of('/cache/work-days.json'), 1);
      expect(again.model.rows.length, first.model.rows.length);
      expect(readWorkDayNumbers(rec)['worktime'], hasLength(60));
      expect(readWorkDayNumbers(rec), workDayNumbers([
        for (final f in Directory(workDirFor(rec).path).listSync().whereType<File>())
          jsonDecode(File(f.path).readAsStringSync()),
      ]));
    });
  });

  group('Try these on the night screen', () {
    testWidgets('looks once while the screen rebuilds for minutes; again when the newest report changes', (tester) async {
      var lookups = 0;
      Future<Map<String, String>> lookup(String files, Set<String> ids) async {
        lookups++;
        return const {};
      }

      // the night screen rebuilds every second
      Widget page(Object? changed) => MaterialApp(
        home: Scaffold(body: TryTheseEntry(recordingsDir: rec, seen: lookup, changed: changed)),
      );
      await tester.pumpWidget(page(('2026-11-19', true, true)));
      for (var s = 0; s < 180; s++) {
        await tester.pumpWidget(page(('2026-11-19', true, true)));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(lookups, 1);
      await tester.pumpWidget(page(('2026-11-20', false, false))); // last night's scoring began
      await tester.pump();
      expect(lookups, 2);
    });

    test('what the app saw: each report read once, also in a new isolate; the same sentences', () {
      final files = Directory(rec).parent.path;
      final ids = {for (final c in tryCards) if (c.auto) c.id};
      final counts = countReads(addTearDown);
      final first = seenByApp(Directory(files), ids);
      expect(first['sleep-time'], 'Scored on this phone in 30 s: the night of Thu 19 Nov.');
      expect(first.containsKey('night'), isFalse, reason: 'Lights off was never tapped');
      expect(counts.of('/files/nights/'), 60);
      counts.clear();
      expect(seenByApp(Directory(files), ids), first);
      expect(counts.of('/files/nights/'), 0, reason: '$counts');
      SummaryIndex.forgetAll(); // the next look runs in a new isolate
      counts.clear();
      expect(seenByApp(Directory(files), ids), first);
      expect(counts.of('/files/nights/'), 0, reason: '$counts');
      expect(counts.of('/cache/try-reports.json'), 1);
    });
  });

  group('the Lucid page', () {
    late Directory tmp;
    late String small;
    late LucidNightRecord record;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('lucid_page');
      small = '${tmp.path}/files/recordings';
      Directory(small).createSync(recursive: true);
      final start = DateTime.now().subtract(const Duration(hours: 9));
      for (var k = 0; k < 3; k++) {
        writeRun(Directory(small), start.add(Duration(minutes: 10 * k)));
      }
      record = LucidNightRecord(startMs: start.millisecondsSinceEpoch, index: 0, cuesFromMs: start.millisecondsSinceEpoch);
      LucidStore(lucidDirFor(small))
        ..setOn(true, start)
        ..saveNight(record);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<List<bool>> open(WidgetTester tester, {int times = 1}) async {
      final asked = <bool>[];
      Future<NightSignals?> search(String rec, LucidStore store, LucidNightRecord r, {bool onlyIfScored = false}) async {
        asked.add(onlyIfScored);
        return null;
      }

      for (var i = 0; i < times; i++) {
        await tester.pumpWidget(MaterialApp(home: LucidScreen(key: UniqueKey(), recordingsDir: small, search: search)));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      return asked;
    }

    testWidgets('no search yet: the night is searched once the page opens', (tester) async {
      expect(await open(tester), [false]);
    });

    testWidgets('searched before the night was scored: asked again only if scored, not at every open', (tester) async {
      LucidStore(lucidDirFor(small)).saveSignals(
        record.stamp,
        NightSignals(made: DateTime.now(), signals: const [], sweepUv: 120, staged: false),
      );
      expect(await open(tester, times: 2), [true, true], reason: 'the search reads nothing until the report is scored');
    });

    testWidgets('not while a session runs', (tester) async {
      napSessionRunning = true;
      addTearDown(() => napSessionRunning = false);
      expect(await open(tester), isEmpty);
    });

    test('the search reads the night only once its report is scored', () {
      final counts = countReads(addTearDown);
      expect(searchLastNight(small, record, onlyIfScored: true), isNull);
      expect(counts.of('.f32') + counts.of('.idx'), 0, reason: 'not scored: the night is not read ($counts)');
      final start = DateTime.fromMillisecondsSinceEpoch(record.startMs);
      final r = night(dateName(nightOf(start)));
      r['data_start'] = start.toIso8601String();
      NightReportStore(nightsDirFor(small)).write(r);
      final out = searchLastNight(small, record, onlyIfScored: true);
      expect(out, isNotNull);
      expect(out!.staged, isTrue);
      expect(counts.of('.f32'), greaterThanOrEqualTo(3), reason: 'scored: the night is read once ($counts)');
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
