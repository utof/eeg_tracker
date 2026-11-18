// Renders the self-experiments pages in their states at a phone's size with real fonts, writes
// build/screens/experiment_*.png for a human look, and fails on any layout overflow (also at 130 % text). Then
// the flow on a fake app folder: set one up, answer a day, look early, stop.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/experiments/analysis.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/experiments/store.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/experiment_setup.dart';
import 'package:eeg_tracker/ui/experiments_screen.dart';
import 'package:eeg_tracker/ui/experiments_view.dart';
import 'package:eeg_tracker/ui/morning_section.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const _id = '2026-11-19-143000';
final _made = DateTime(2026, 11, 19, 14, 30);

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 980}) async {
  tester.view.physicalSize = Size(1210, height * 2.75); // about a Xiaomi 12T: 440 x 980 dp
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: height > 980 ? 2.0 : 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// A store in a temp folder with one experiment made on 19 Nov (day 1: 20 Nov, 28 days).
ExperimentStore _store(Directory tmp) {
  final store = ExperimentStore(Directory('${tmp.path}/experiments'));
  store.create(
    preset: 'screens',
    doText: 'No screens in the last hour before bed',
    dontText: 'Screens as usual',
    outcome: outcomeById('asleep')!,
    weeks: 4,
    now: _made,
    random: math.Random(3),
  );
  return store;
}

/// Per-day numbers with a 35-minute effect on sleep, a little noise, and two nights not recorded.
Map<String, Map<String, double>> _series(ExperimentState end) {
  final r = math.Random(11);
  final out = {for (final m in measureSpecs) m.id: <String, double>{}};
  for (final d in end.pastDays) {
    if (d.index == 6 || d.index == 17) continue;
    final next = addDays(d.day, 1);
    out['asleep']![next] = 415.0 + (d.doIt ? 35 : 0) + r.nextInt(30);
    out['kss']![next] = (d.doIt ? 3 : 4) + r.nextInt(3).toDouble();
    out['reaction']![next] = 310.0 + r.nextInt(40);
  }
  return out;
}

ExperimentPage _page(ExperimentStore store, DateTime now, {bool early = false, bool answers = true}) {
  if (answers) {
    final s = store.load(_id, now)!;
    if (!s.open) {
      for (final d in s.pastDays) {
        // yesterday stays open; day 4 was not kept
        if (d.day != addDays(s.today, -1)) store.answer(_id, d.day, d.index != 3, now);
      }
    }
  }
  if (early) store.earlyLook(_id, now);
  final s = store.load(_id, now)!;
  final end = store.load(_id, DateTime(2026, 12, 25))!;
  return ExperimentPage(state: s, now: now, results: resultsFor(s, _series(end), early: early), early: early);
}

void main() {
  setUpAll(loadFonts);
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('expscreens'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final states = <String, ExperimentPage? Function(ExperimentStore)>{
    'experiment_none': (_) => null,
    'experiment_waiting': (s) => _page(s, DateTime(2026, 11, 19, 15)),
    'experiment_day1': (s) => _page(s, DateTime(2026, 11, 20, 9)),
    'experiment_running': (s) => _page(s, DateTime(2026, 11, 28, 18)),
    'experiment_still_up': (s) => _page(s, DateTime(2026, 11, 28, 5), answers: false),
    'experiment_early_look': (s) => _page(s, DateTime(2026, 12, 4, 18), early: true),
    'experiment_last_number': (s) => _page(s, DateTime(2026, 12, 18, 12)),
    'experiment_finished': (s) => _page(s, DateTime(2026, 12, 19, 12)),
    'experiment_finished_after_look': (s) {
      _page(s, DateTime(2026, 12, 4, 18), early: true);
      return _page(s, DateTime(2026, 12, 19, 12));
    },
    'experiment_stopped': (s) {
      _page(s, DateTime(2026, 12, 2, 18));
      s.stop(_id, DateTime(2026, 12, 2, 18));
      return _page(s, DateTime(2026, 12, 3, 12));
    },
  };

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        final store = _store(tmp);
        final page = e.value(store);
        final view = ExperimentView(
          page: page,
          earlier: page == null ? [store.load(_id, DateTime(2026, 12, 25))!] : const [],
          onAnswer: (_, _) {},
          onLookEarly: () {},
          onStop: () {},
          onInfo: () {},
          onNew: () {},
          onOpen: (_) {},
        );
        final name = '${e.key}${scale == 1.0 ? '' : '_text130'}';
        await _shoot(tester, view, name, scale: scale);
        await _shoot(tester, view, '${name}_whole', scale: scale, height: 2900);
      });
    }

    testWidgets('setup, empty and with an own question, at ${(scale * 100).round()} % text', (tester) async {
      final tag = scale == 1.0 ? '' : '_text130';
      ExperimentChoice? got;
      await _shoot(tester, ExperimentSetup(now: _made, onStart: (c) => got = c), 'experiment_setup$tag', scale: scale, height: 1900);
      expect(find.text('Choose a question'), findsOneWidget);
      await tester.tap(find.text('Your own'));
      await tester.pump();
      expect(find.text('Write both lines'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'A cold shower in the evening');
      await tester.pump();
      expect(find.text('Choose the number'), findsOneWidget);
      await tester.tap(find.text('Reaction time'));
      await tester.pump();
      await tester.tap(find.text('6 weeks'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Start tomorrow'));
      expect(got!.preset, 'custom');
      expect(got!.doText, 'A cold shower in the evening');
      expect(got!.dontText, 'As usual');
      expect(got!.outcome.id, 'reaction');
      expect(got!.weeks, 6);
    });

    testWidgets('the trends section and the morning line at ${(scale * 100).round()} % text', (tester) async {
      final store = _store(tmp);
      final line = experimentLine(store.load(_id, DateTime(2026, 11, 28, 18)));
      final model = buildTrends((nights: const [], mornings: const [], sessions: const []), DateTime(2026, 11, 28, 18));
      await _shoot(
        tester,
        TrendsView(model: model, onInfo: () {}, onExperiments: () {}, experimentLine: line),
        'experiment_in_trends${scale == 1.0 ? '' : '_text130'}',
        scale: scale,
        height: 1500,
      );
      expect(find.text('Experiments'), findsOneWidget);
      await _shoot(
        tester,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: MorningSection(doneAt: '09:12', onCheckIn: () {}, onTrends: () {}, experiment: line),
          ),
        ),
        'experiment_in_morning${scale == 1.0 ? '' : '_text130'}',
        scale: scale,
      );
    });
  }

  group('the words', () {
    test('status and the one line for other screens', () {
      final store = _store(tmp);
      ExperimentState at(int m, int d, [int h = 12]) => store.load(_id, DateTime(2026, m, d, h))!;
      expect(statusWords(at(11, 19, 15)), 'Starts tomorrow');
      expect(statusWords(at(11, 28)), 'Day 9 of 28');
      expect(statusWords(at(12, 18)), 'Last number coming in');
      expect(statusWords(at(12, 19)), 'Finished');
      expect(experimentLine(null), isNull);
      expect(experimentLine(at(11, 19, 15)), 'Experiment starts tomorrow: “No screens in the last hour before bed” on random days.');
      final day2 = at(11, 21);
      expect(
        experimentLine(day2),
        'Experiment, day 2 of 28. Today: ${day2.textFor(day2.todayView!.doIt)}. 1 day to answer.',
      );
      expect(experimentLine(at(12, 18)), 'Experiment: every day is done. The answer opens Sat 19 Dec.');
      expect(experimentLine(at(12, 19)), 'Experiment finished: the answer is open.');
      expect(stillUpHours(DateTime(2026, 11, 28, 5)), isTrue);
      expect(stillUpHours(DateTime(2026, 11, 28, 11)), isFalse);
    });
  });

  group('the days ahead never reach the screen', () {
    testWidgets('a running page shows today\'s task and no later one; the answer is sealed', (tester) async {
      final store = _store(tmp);
      final page = _page(store, DateTime(2026, 11, 28, 18));
      await _shoot(tester, ExperimentView(page: page), 'experiment_tmp', height: 2900);
      expect(page.results, isNull);
      expect(find.text('Sealed until Sat 19 Dec'), findsOneWidget);
      expect(find.text('Day 9 of 28'), findsOneWidget);
      expect(find.text(page.state.textFor(page.state.todayView!.doIt)), findsOneWidget);
      expect(find.textContaining('p ='), findsNothing);
      // the bill's label speaks of 8 days over and 20 still sealed or to come
      expect(find.bySemanticsLabel(RegExp(r'^The days so far: 8 days over, \d of them “do” days, 1 not kept; 20 still sealed')), findsOneWidget);
    });
  });

  group('the flow on a fake app folder', () {
    testWidgets('set up, answer yesterday, look early (asks first), stop (asks first)', (tester) async {
      tester.view.physicalSize = const Size(1210, 2900 * 2.75);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final rec = '${tmp.path}/recordings';
      var now = DateTime(2026, 11, 19, 14, 30);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: ExperimentsScreen(recordingsDir: rec, now: () => now)));
      await tester.pumpAndSettle();
      expect(find.text('None running'), findsOneWidget);
      await tester.tap(find.text('New experiment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No screens in the last hour before bed'));
      await tester.pump();
      await tester.tap(find.text('Start tomorrow'));
      await tester.pumpAndSettle();
      expect(find.text('Starts tomorrow'), findsOneWidget);
      expect(find.text('New experiment'), findsNothing, reason: 'one at a time');
      final store = ExperimentStore(experimentsDirFor(rec));
      final id = store.all(now).single.plan.id;
      expect(store.all(now).single.plan.outcome.id, 'asleep');

      // day 3: two days to answer
      now = DateTime(2026, 11, 22, 18);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: ExperimentsScreen(key: UniqueKey(), recordingsDir: rec, now: () => now)));
      await tester.pumpAndSettle();
      expect(find.text('Day 3 of 28'), findsOneWidget);
      expect(find.text('Kept'), findsNWidgets(2));
      await tester.tap(find.text('Not kept').first);
      await tester.pumpAndSettle();
      expect(find.text('Kept'), findsOneWidget);
      expect(store.load(id, now)!.progress.kept, {'2026-11-21': false});

      await tester.tap(find.text('Look early anyway'));
      await tester.pumpAndSettle();
      expect(find.text('Look before the end?'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(store.load(id, now)!.progress.earlyLooks, isEmpty);
      await tester.tap(find.text('Look early anyway'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Look early'));
      await tester.pumpAndSettle();
      expect(store.load(id, now)!.progress.earlyLooks.single.daysDone, 2);
      expect(find.text('An early look'), findsOneWidget);
      expect(find.textContaining('Too few days to say'), findsOneWidget);

      await tester.tap(find.text('Stop this experiment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Stopped after 2 days'), findsOneWidget);
      expect(find.text('New experiment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
