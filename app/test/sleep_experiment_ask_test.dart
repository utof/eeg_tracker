// Tonight's question of a running sleep experiment on the Record tab, beside the Sleep button (DECISIONS 1084): one
// line and three answers in the evening while tonight is unanswered; gone once answered; nothing when no experiment
// runs, before the evening, or while a sleep stretch is open.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/sleep_experiments/store.dart';
import 'package:eeg_tracker/sleep_experiments/tonight.dart';
import 'package:eeg_tracker/ui/home_tabs.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/sleep_experiment_ask.dart';
import 'package:eeg_tracker/ui/sleep_experiments_view.dart' show AnswerButtons;
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;
import 'sleep_experiments_test.dart' show logOf;

final caffeine = kindById('caffeine_late')!, workout = kindById('workout_late')!;

void main() {
  group('when the Record tab asks', () {
    final e = logOf(caffeine, const {});
    test('nothing without a running experiment', () {
      expect(tonightAsk(null, DateTime(2026, 11, 10, 21)), Tonight.nothing);
      expect(tonightAsk(logOf(caffeine, const {}, ended: '2026-11-09'), DateTime(2026, 11, 10, 21)), Tonight.nothing);
    });
    test('from 17:00 until the day ends at 04:00, not earlier in the day', () {
      expect(tonightAsk(e, DateTime(2026, 11, 10, 16, 59)), Tonight.nothing);
      expect(tonightAsk(e, DateTime(2026, 11, 10, 17)), Tonight.ask);
      expect(tonightAsk(e, DateTime(2026, 11, 11, 3, 59)), Tonight.ask);
      expect(tonightAsk(e, DateTime(2026, 11, 11, 4)), Tonight.nothing);
    });
    test('gone once tonight is answered; an answer after midnight is still about that evening', () {
      final said = logOf(caffeine, {'2026-11-10': const DayLog(answer: Answer.neither)});
      expect(tonightAsk(said, DateTime(2026, 11, 10, 22)), Tonight.nothing);
      expect(tonightAsk(said, DateTime(2026, 11, 11, 1)), Tonight.nothing);
      expect(tonightAsk(said, DateTime(2026, 11, 11, 18)), Tonight.ask);
    });
    test('the app picks the nights: first the way to the pick, the question once it is drawn', () {
      expect(tonightAsk(logOf(workout, const {}, salt: 's'), DateTime(2026, 11, 10, 18)), Tonight.pick);
      final drawn = logOf(workout, {'2026-11-10': const DayLog(pick: true, pickIndex: 0)}, salt: 's');
      expect(tonightAsk(drawn, DateTime(2026, 11, 10, 18)), Tonight.ask);
    });
  });

  group('on the Record tab', () {
    late Directory tmp;
    late String rec;
    late SleepExperimentStore store;
    setUpAll(loadFonts);
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sleepexpask');
      rec = '${tmp.path}/recordings';
      store = SleepExperimentStore(sleepExperimentsDirFor(rec));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    final shot = GlobalKey();

    /// build/screens/<name>.png for a human look.
    Future<void> shoot(WidgetTester tester, String name) async {
      final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2.75);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/screens/$name.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> show(WidgetTester tester, DateTime Function() now, {NightViewModel? model, List<String>? opened, double scale = 1}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nightTheme(),
            home: RepaintBoundary(
              key: shot,
              child: NightView(
              tab: HomeTab.night,
              model: model ?? const NightViewModel(title: 'Ready', sentence: '', tone: Tone.calm, running: false),
              onStart: () {},
              onRecord: () {},
              onSleepNow: () {},
              onStop: () {},
              onFix: (_) {},
              experimentAsk: SleepExperimentAsk(recordingsDir: rec, now: now, onOpen: () => opened?.add('page'), rearm: (_) async {}),
            ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('no experiment: nothing more on the tab', (tester) async {
      await show(tester, () => DateTime(2026, 11, 10, 21));
      expect(find.byType(AnswerButtons), findsNothing);
      expect(find.textContaining('today?'), findsNothing);
    });

    testWidgets('in the evening: the question sits right above Sleep; one tap keeps it and the line goes', (tester) async {
      store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12));
      final now = DateTime(2026, 11, 10, 21, 30);
      await show(tester, () => now);
      expect(find.text('Late caffeine. Caffeine today?'), findsOneWidget);
      for (final l in ['A lot, late', 'None after noon', 'In between']) {
        expect(find.text(l), findsOneWidget);
      }
      // right above the Sleep button, in the bar that stays on screen
      final ask = tester.getRect(find.text('None after noon')), sleep = tester.getRect(find.widgetWithText(FilledButton, 'Sleep'));
      expect(ask.bottom, lessThan(sleep.top));
      expect(sleep.top - ask.bottom, lessThan(40));
      await shoot(tester, 'record_tab_experiment_ask');

      await tester.tap(find.text('None after noon'));
      await tester.pump();
      expect(store.active()!.day('2026-11-10').answer, Answer.without);
      expect(find.text('Late caffeine. Caffeine today?'), findsNothing);
      expect(find.text('None after noon'), findsNothing);
      expect(find.textContaining('Kept: None after noon'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sleep'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('answered somewhere else (Trends, the page): the line goes without a restart', (tester) async {
      final id = store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12)).plan.id;
      final now = DateTime(2026, 11, 10, 21, 30);
      await show(tester, () => now);
      expect(find.text('In between'), findsOneWidget);
      store.answer(id, '2026-11-10', Answer.withIt, now);
      await tester.pump();
      expect(find.text('In between'), findsNothing);
    });

    testWidgets('before the evening, and while a sleep stretch is open: not shown', (tester) async {
      store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12));
      await show(tester, () => DateTime(2026, 11, 10, 11));
      expect(find.text('In between'), findsNothing);
      const sleeping = NightViewModel(title: 'Recording', sentence: '', tone: Tone.live, running: true, sleeping: true);
      await show(tester, () => DateTime(2026, 11, 10, 23), model: sleeping);
      expect(find.text('In between'), findsNothing);
      // a recording with no sleep marked yet: you are about to press Sleep, so it is there
      const recording = NightViewModel(title: 'Recording', sentence: '', tone: Tone.live, running: true, sleeping: false);
      await show(tester, () => DateTime(2026, 11, 10, 23), model: recording);
      expect(find.text('In between'), findsOneWidget);
      final ask = tester.getRect(find.text('In between')), sleep = tester.getRect(find.widgetWithText(FilledButton, 'Sleep'));
      expect(ask.bottom, lessThan(sleep.top));
    });

    testWidgets('the app picks the nights: one line that opens the page; after the pick, the question', (tester) async {
      final id = store.create(kind: workout, picked: true, now: DateTime(2026, 11, 9, 12), random: math.Random(2)).plan.id;
      final now = DateTime(2026, 11, 10, 18);
      final opened = <String>[];
      await show(tester, () => now, opened: opened);
      expect(find.text('Late hard workout: is tonight a test night?'), findsOneWidget);
      await shoot(tester, 'record_tab_experiment_pick');
      expect(find.text('Late'), findsNothing);
      await tester.tap(find.text('Let the app pick'));
      expect(opened, ['page']);
      store.pick(id, now);
      await tester.pump();
      expect(find.text('Late hard workout. Hard workout today?'), findsOneWidget);
      expect(find.text('Late'), findsOneWidget);
    });

    testWidgets('large text: nothing overflows', (tester) async {
      store.create(kind: caffeine, picked: false, now: DateTime(2026, 11, 9, 12));
      await show(tester, () => DateTime(2026, 11, 10, 21, 30), scale: 1.3);
      expect(find.text('None after noon'), findsOneWidget);
      await shoot(tester, 'record_tab_experiment_ask_text130');
    });
  });
}
