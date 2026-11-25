// Renders the sleep-experiments pages in their states at a phone's size with real fonts, writes
// build/screens/sleep_experiment_*.png for a human look, and fails on any layout overflow (also at 130 % text). Then
// the flow on a fake app folder: start one, tap tonight's answer, tick an odd night, let the app pick, end it.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/sleep_experiments/result.dart';
import 'package:eeg_tracker/sleep_experiments/store.dart';
import 'package:eeg_tracker/trends/days.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/sleep_experiments_screen.dart';
import 'package:eeg_tracker/ui/sleep_experiments_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;
import 'sleep_experiments_test.dart' show logOf, nn, twenty, wB, oB;

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

final caffeine = kindById('caffeine_late')!, alcohol = kindById('alcohol')!, workout = kindById('workout_late')!;

SleepExperimentPage _pageOf(ExperimentLog e, Map<String, NightNumbers> nights, String today) =>
    SleepExperimentPage(result: resultFor(e, nights), today: today);

/// Alcohol since 2 Nov: [n] evenings answered, 3 or more drinks on every third.
SleepExperimentPage _alcohol(int n, String today) {
  final r = math.Random(5);
  final days = <String, DayLog>{}, nights = <String, NightNumbers>{};
  for (var i = 0; i < n; i++) {
    final day = addDays('2026-11-02', i), w = i % 3 == 0;
    days[day] = DayLog(answer: w ? Answer.withIt : (i % 7 == 5 ? Answer.neither : Answer.without), odd: i == 4 ? {'ill'} : const {});
    nights[addDays(day, 1)] = nn(pulse: 58.0 + (w ? 3 : 0) + r.nextInt(4), dream: 80.0 - (w ? 12 : 0) + r.nextInt(20));
  }
  return _pageOf(logOf(alcohol, days), nights, today);
}

void main() {
  setUpAll(loadFonts);

  final states = <String, SleepExperimentPage? Function()>{
    'none': () => null,
    'day1': () => _pageOf(logOf(caffeine, const {}), const {}, '2026-11-02'),
    'few_nights': () => _alcohol(8, '2026-11-10'),
    'so_far': () => _alcohol(40, '2026-12-12'),
    'picked_ask': () => _pageOf(logOf(workout, const {}, salt: 'test-salt-1'), const {}, '2026-11-02'),
    'picked_with': () => _pageOf(
      logOf(workout, {'2026-11-02': const DayLog(pick: true, pickIndex: 0)}, salt: 'test-salt-1'),
      const {},
      '2026-11-02',
    ),
    'verdict': () {
      final (e, nights) = twenty();
      return _pageOf(e, nights, '2026-11-23');
    },
  };

  for (final scale in [1.0, 1.3]) {
    for (final s in states.entries) {
      testWidgets('${s.key} at ${(scale * 100).round()} % text', (tester) async {
        final page = s.value();
        final view = SleepExperimentView(
          page: page,
          earlier: page == null ? [logOf(caffeine, const {}, ended: '2026-11-20')] : const [],
          onAnswer: (_, _) {},
          onOdd: (_, _, _) {},
          onPick: () {},
          onEnd: () {},
          onNew: () {},
          onInfo: () {},
          onOpen: (_) {},
        );
        final name = 'sleep_experiment_${s.key}${scale == 1.0 ? '' : '_text130'}';
        await _shoot(tester, view, name, scale: scale);
        await _shoot(tester, view, '${name}_whole', scale: scale, height: 3400);
      });
    }

    testWidgets('setup at ${(scale * 100).round()} % text', (tester) async {
      final tag = scale == 1.0 ? '' : '_text130';
      SleepExperimentChoice? got;
      final needs = neededBeforeStart(const {});
      await _shoot(tester, SleepExperimentSetup(onStart: (c) => got = c, needs: needs), 'sleep_experiment_setup$tag', scale: scale, height: 2600);
      expect(find.text('Choose one'), findsOneWidget);
      // alcohol: the app never picks the nights
      await tester.tap(find.text('Alcohol'));
      await tester.pump();
      expect(find.text('Let the app pick'), findsNothing);
      expect(find.textContaining('The app never tells you to drink'), findsOneWidget);
      await tester.tap(find.text('Late caffeine'));
      await tester.pump();
      expect(find.textContaining('this needs about 10 nights with and 10 without'), findsOneWidget);
      await _shoot(tester, SleepExperimentSetup(onStart: (c) => got = c, needs: needs), 'sleep_experiment_setup_tmp$tag', scale: scale, height: 2600);
      await tester.tap(find.text('Late hard workout'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Let the app pick'));
      await tester.pump();
      await tester.tap(find.text('Start today'));
      expect(got!.kind.id, 'workout_late');
      expect(got!.picked, isTrue);
    });

    testWidgets('the trends section at ${(scale * 100).round()} % text', (tester) async {
      final tag = scale == 1.0 ? '' : '_text130';
      final model = buildTrends((nights: const [], mornings: const [], sessions: const []), DateTime(2026, 11, 10, 18));
      final p = _alcohol(8, '2026-11-10');
      Answer? tapped;
      await _shoot(
        tester,
        TrendsView(
          model: model,
          sleepExperiments: SleepExperimentSection(
            log: p.log,
            today: '2026-11-10',
            line: pilesLine(p.result.piles),
            onAnswer: (a) => tapped = a,
            onOpen: () {},
          ),
        ),
        'sleep_experiment_in_trends$tag',
        scale: scale,
        height: 1700,
      );
      expect(find.text('Alcohol: 3 with, 1 without so far.'), findsOneWidget);
      await tester.tap(find.text('3 or more'));
      expect(tapped, Answer.withIt);
      await _shoot(
        tester,
        TrendsView(model: model, sleepExperiments: SleepExperimentSection(log: null, today: '2026-11-10', onOpen: () {})),
        'sleep_experiment_in_trends_none$tag',
        scale: scale,
        height: 1700,
      );
    });
  }

  group('what the page says', () {
    testWidgets('a handful of nights: counts and "not enough yet", no averages, no verdict', (tester) async {
      final p = _alcohol(8, '2026-11-10');
      await _shoot(tester, SleepExperimentView(page: p), 'sleep_experiment_tmp', height: 3400);
      expect(find.text('3 with · 1 without'), findsOneWidget);
      expect(find.textContaining('Not enough yet: 3 nights with, 1 without'), findsNWidgets(2));
      expect(find.textContaining('Left out: 4 nights (1 in between, 1 ill or not your own bed, 2 the night after drinks)'), findsOneWidget);
      expect(find.textContaining('Tested'), findsNothing);
      expect(find.textContaining('likely between'), findsNothing);
      expect(find.textContaining('can only say what was seen together'), findsOneWidget);
      expect(find.textContaining('under-counts dream sleep'), findsOneWidget);
    });

    testWidgets('a clear result you chose the nights for says "seen together", never "tested" or "caused"', (tester) async {
      final (e, nights) = twenty();
      await _shoot(tester, SleepExperimentView(page: _pageOf(e, nights, '2026-11-23')), 'sleep_experiment_tmp', height: 3400);
      expect(find.textContaining('Seen together, not proven'), findsOneWidget);
      expect(find.textContaining('Tested:'), findsNothing);
      expect(find.textContaining('caused it'), findsOneWidget, reason: 'only in "never what caused it"');
      expect(find.text('Today'), findsNothing, reason: 'ended: nothing more to tap');
    });
  });

  group('the flow on a fake app folder', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('sleepexpscreens'));
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('start, tap tonight, tick an odd night, yesterday, end', (tester) async {
      tester.view.physicalSize = const Size(1210, 9000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      var now = DateTime(2026, 11, 2, 21);
      final rec = '${tmp.path}/recordings';
      final store = SleepExperimentStore(sleepExperimentsDirFor(rec));
      final nights = {for (var i = 0; i < 6; i++) addDays('2026-11-03', i): nn(eff: (i.isEven ? wB : oB)[i].toDouble())};
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: SleepExperimentsScreen(recordingsDir: rec, now: () => now, readNights: (_) async => nights),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('None running'), findsOneWidget);
      await tester.tap(find.text('Start an experiment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Late caffeine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start today'));
      await tester.pumpAndSettle();
      final id = store.active()!.plan.id;
      expect(store.active()!.plan.picked, isFalse);
      expect(find.text('Caffeine today?'), findsOneWidget);
      expect(find.text('0 with · 0 without'), findsOneWidget);

      await tester.tap(find.text('A lot, late').first);
      await tester.pumpAndSettle();
      expect(store.read(id)!.day('2026-11-02').answer, Answer.withIt);
      await tester.tap(find.text('Not my own bed'));
      await tester.pumpAndSettle();
      expect(store.read(id)!.day('2026-11-02').odd, {'away'});
      await tester.tap(find.text('Not my own bed'));
      await tester.pumpAndSettle();

      // two days on: yesterday was not answered and is asked once more; the first night now counts
      now = DateTime(2026, 11, 4, 21);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: SleepExperimentsScreen(key: const ValueKey(2), recordingsDir: rec, now: () => now, readNights: (_) async => nights),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 with · 0 without'), findsOneWidget);
      expect(find.text('Yesterday: not answered'), findsOneWidget);
      await tester.tap(find.text('None after noon').at(1));
      await tester.pumpAndSettle();
      expect(store.read(id)!.day('2026-11-03').answer, Answer.without);
      expect(find.text('Yesterday: not answered'), findsNothing);
      expect(find.text('1 with · 1 without'), findsOneWidget);

      await tester.tap(find.text('End this experiment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End'));
      await tester.pumpAndSettle();
      expect(store.active(), isNull);
      expect(find.text('Result'), findsOneWidget);
      expect(find.text('Start an experiment'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the app picks: one draw a day, shown in words', (tester) async {
      tester.view.physicalSize = const Size(1210, 9000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final now = DateTime(2026, 11, 2, 18);
      final rec = '${tmp.path}/recordings';
      final store = SleepExperimentStore(sleepExperimentsDirFor(rec));
      final id = store.create(kind: workout, picked: true, now: now, random: math.Random(2)).plan.id;
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: SleepExperimentsScreen(recordingsDir: rec, now: () => now, readNights: (_) async => const {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('The app picked:'), findsNothing);
      await tester.tap(find.text('Pick for tonight'));
      await tester.pumpAndSettle();
      final pick = store.read(id)!.day('2026-11-02').pick!;
      expect(pick, pickAt(store.read(id)!.plan.salt!, 0));
      expect(find.text('The app picked: ${pick ? 'Late' : 'Early'}'), findsOneWidget);
      expect(find.text('Pick for tonight'), findsNothing);
    });
  });
}
