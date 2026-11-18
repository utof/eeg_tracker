// Renders the sleep report and the night screen's Sleep section in their states at a phone's size with real
// fonts, writes build/screens/sleep_*.png for a human look, and fails on any layout overflow (also at 130 % text).
// The nights are made up (stages built from a fixed pattern), not recordings.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/sleep_report_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

List<String> _run(String s, int minutes) => List.filled(minutes * 2, s);

/// A made-up night from 23:40: four sleep cycles, a 25-minute hole in the data, an hour awake at dawn, then a
/// short morning sleep.
List<String> _stages() => [
  ..._run('W', 18), ..._run('N1', 6), ..._run('N2', 22), ..._run('N3', 34), ..._run('N2', 14), ..._run('R', 9),
  ..._run('N2', 18), ..._run('gap', 25), ..._run('N3', 18), ..._run('N2', 20), ..._run('R', 16), ..._run('W', 7),
  ..._run('N2', 34), ..._run('N3', 8), ..._run('N2', 16), ..._run('R', 22), ..._run('N1', 4), ..._run('N2', 30),
  ..._run('R', 26), ..._run('W', 70), ..._run('N1', 5), ..._run('N2', 25), ..._run('R', 14), ..._run('W', 9),
];

SleepReport _report(String nightOf, DateTime start, List<String> stages) => SleepReport(
  jsonDecode(
        jsonEncode(
          buildReport(
            nightOf: nightOf,
            built: start.add(Duration(seconds: 30 * stages.length + 140)),
            scoringSeconds: 131,
            start: start,
            lengthSeconds: 30.0 * stages.length,
            inputs: {for (var i = 0; i < 4; i++) '2026-11-17-23400$i.f32': 1000},
            model: phoneModelId,
            stages: stages,
            confidence: List.filled(stages.length, 0.74),
          ),
        ),
      )
      as Map<String, dynamic>,
);

final _start = DateTime(2026, 11, 17, 23, 40);
final _main = _report('2026-11-17', _start, _stages());
final _others = [
  _report('2026-11-16', DateTime(2026, 11, 16, 23, 55), [..._run('W', 20), ..._run('N2', 200), ..._run('R', 60), ..._run('W', 10)]),
  _report('2026-11-15', DateTime(2026, 11, 16, 0, 30), [..._run('W', 30), ..._run('N2', 150), ..._run('N3', 40), ..._run('W', 15)]),
  SleepReport(
    jsonDecode(
          jsonEncode(
            buildReport(
              nightOf: '2026-11-14',
              built: DateTime(2026, 11, 14, 23),
              scoringSeconds: 0.4,
              start: DateTime(2026, 11, 14, 22, 58),
              lengthSeconds: 170,
              inputs: const {},
              model: phoneModelId,
            ),
          ),
        )
        as Map<String, dynamic>,
  ),
];

final Map<String, Widget> _reportStates = {
  'report': SleepReportView(nightOf: '2026-11-17', report: _main, others: _others, onInfo: () {}, onLicences: () {}),
  'report_scoring': const SleepReportView(nightOf: '2026-11-17', scoringStep: 'Sleep model, run 2 of 3, part 4 of 9'),
  'report_blocked': const SleepReportView(nightOf: '2026-11-17', blocked: ''),
  'report_short': SleepReportView(nightOf: '2026-11-14', report: _others.last),
  'report_no_period': SleepReportView(
    nightOf: '2026-11-17',
    report: _report('2026-11-17', _start, [..._run('W', 40), ..._run('N1', 6), ..._run('W', 30)]),
  ),
};

NightViewModel _morning(SleepSummary sleep) => NightViewModel(
  title: 'Ready',
  sentence: 'Last night is saved. Put the headband on to start a new one.',
  tone: Tone.calm,
  running: false,
  minutes: 490,
  nightsOnPhone: 4,
  sleep: sleep,
);

final Map<String, Widget> _nightStates = {
  'night_sleep': NightView(
    model: _morning(SleepSummary(nightOf: '2026-11-17', scored: true, asleepMin: _main.asleepMin, periods: 2)),
    onStart: () {},
    onStop: () {},
    onFix: (_) {},
    onSleepReport: () {},
  ),
  'night_scoring': NightView(
    model: _morning(const SleepSummary(nightOf: '2026-11-17', scoringStep: 'Sleep model, run 1 of 3, part 2 of 9')),
    onStart: () {},
    onStop: () {},
    onFix: (_) {},
  ),
  'night_blocked': NightView(
    model: _morning(const SleepSummary(nightOf: '2026-11-17', blocked: 'Bad state: no memory')),
    onStart: () {},
    onStop: () {},
    onFix: (_) {},
    onRetrySleep: () {},
  ),
};

void main() {
  setUpAll(loadFonts);

  test('the made-up night has the periods the screens show', () {
    expect(_main.periods.length, 2);
    expect(_main.missingMin, 25);
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in {..._reportStates, ..._nightStates}.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // about a Xiaomi 12T: 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(key: key, child: e.value),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/screens/sleep_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true);
          out.writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  testWidgets('the whole report on one tall page, for a look', (tester) async {
    tester.view.physicalSize = const Size(1210, 6600); // 440 x 2400 dp
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: RepaintBoundary(key: key, child: _reportStates['report'])),
    );
    expect(tester.takeException(), isNull);
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/screens/sleep_report_full.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  });

  testWidgets('the whole report scrolls into view without overflow', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _reportStates['report']));
    await tester.scrollUntilVisible(find.text('Licences'), 400);
    expect(find.text('Sleep periods'), findsOneWidget);
    expect(find.text('Past nights'), findsOneWidget);
    expect(find.text('Tue 17 Nov'), findsNothing); // the open night is not in its own list
    expect(find.textContaining('too short to score'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
