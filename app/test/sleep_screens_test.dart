// Renders the sleep report and the night screen's Sleep section in their states at a phone's size with real
// fonts, writes build/screens/sleep_*.png for a human look, and fails on any layout overflow (also at 130 % text).
// The nights are made up (stages built from a fixed pattern), not recordings.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/sleep/drift.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/rem_check.dart';
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

/// Made-up detector output for [stages]: missing where the data is, a loose electrode for a few minutes while
/// awake, noisy stretches here and there; jaw bursts more often awake, movements on turning.
NightSeen _seen(List<String> stages, {int jawEveryS = 200, DriftSeen? drift}) {
  final q = [
    for (var e = 0; e < stages.length; e++)
      stages[e] == 'gap' || (stages[e] == 'W' && e % 140 < 6)
          ? EpochQuality.missing
          : (e % 97 < 9 || (stages[e] == 'W' && e % 11 < 4))
          ? EpochQuality.degraded
          : EpochQuality.good,
  ];
  final n = stages.length * 30;
  return NightSeen(
    quality: q,
    bursts: [
      for (var k = 40; k < n; k += stages[k ~/ 30] == 'W' ? 90 : jawEveryS) Burst(k, k + 2, BurstKind.jaw, 6),
      for (var k = 75; k < n; k += 410) Burst(k, k + 1, BurstKind.oneSided, 5),
    ]..sort((a, b) => a.start.compareTo(b.start)),
    moves: [for (var k = 130; k < n; k += stages[k ~/ 30] == 'W' ? 150 : 520) (k, k + 1)],
    drift: drift,
    // side-to-side eye movements: many in dream sleep, some awake, a few elsewhere; none where the data is missing
    eye: EyeSeen.measured('T3-T4', [
      for (var e = 0; e < stages.length; e++)
        stages[e] == 'gap' ? null : stages[e] == 'R' ? 6 + e % 5 : stages[e] == 'W' ? 4 : e % 9 == 0 ? 5 : e % 3,
    ]),
  );
}

/// Made-up model probabilities: most on the scored stage, a little dream sleep everywhere.
List<double> _probs(List<String> stages) => [
  for (final s in stages)
    for (final k in ['W', 'N1', 'N2', 'N3', 'R']) k == s ? 0.7 : k == 'R' ? 0.1 : (s == 'R' ? 0.3 : 0.2) / 3,
];

SleepReport _report(String nightOf, DateTime start, List<String> stages, {int jawEveryS = 200, DriftSeen? drift}) =>
    SleepReport(
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
            probabilities: _probs(stages),
            seen: _seen(stages, jawEveryS: jawEveryS, drift: drift),
          ),
        ),
      )
      as Map<String, dynamic>,
);

final _start = DateTime(2026, 11, 17, 23, 40);
// Lights off tapped at 23:45; the detector says asleep at 23:57:30, the sleep model at 23:58 (18 min of wake).
final _main = _report(
  '2026-11-17',
  _start,
  _stages(),
  drift: const DriftSeen(lightsOffS: 300, from: LightsOffFrom.button, tapped: 1795466700.4, onsetS: 1050),
);
final _others = [
  _report('2026-11-16', DateTime(2026, 11, 16, 23, 55), [..._run('W', 20), ..._run('N2', 200), ..._run('R', 60), ..._run('W', 10)],
      jawEveryS: 260, drift: const DriftSeen(lightsOffS: 0, from: LightsOffFrom.button, onsetS: 1260)),
  _report('2026-11-15', DateTime(2026, 11, 16, 0, 30), [..._run('W', 30), ..._run('N2', 150), ..._run('N3', 40), ..._run('W', 15)],
      jawEveryS: 150, drift: const DriftSeen(lightsOffS: 0, from: LightsOffFrom.nightStart)),
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
  'report': SleepReportView(
    nightOf: '2026-11-17',
    report: _main,
    others: _others,
    onInfo: () {},
    onLicences: () {},
    onDriftInfo: () {},
  ),
  'report_scoring': const SleepReportView(nightOf: '2026-11-17', scoringStep: 'Sleep model, run 2 of 3, part 4 of 9'),
  'report_blocked': const SleepReportView(nightOf: '2026-11-17', blocked: ''),
  'report_short': SleepReportView(nightOf: '2026-11-14', report: _others.last),
  'report_night_start': SleepReportView(nightOf: '2026-11-15', report: _others[1], others: [_main, _others[0]], onDriftInfo: () {}),
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
    final x = _main.extras!;
    expect(x.hours.length, greaterThan(8));
    expect(x.asleep.jawPerHour, greaterThan(10));
    expect(x.asleep.degradedMin, greaterThan(0));
    expect(x.night.missingMin, greaterThan(25));
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

  for (final scale in [1.0, 1.3]) {
    testWidgets('the whole report on one tall page at ${(scale * 100).round()} % text, for a look', (tester) async {
      tester.view.physicalSize = Size(1210, scale == 1.0 ? 7600 : 10200); // 440 dp wide
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(theme: nightTheme(), home: RepaintBoundary(key: key, child: _reportStates['report'])),
        ),
      );
      expect(tester.takeException(), isNull);
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/screens/sleep_report_full${scale == 1.0 ? '' : '_text130'}.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
    });
  }

  testWidgets('the whole report scrolls into view without overflow', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _reportStates['report']));
    expect(find.textContaining('through noise (movement, muscle or a loose electrode)'), findsOneWidget);
    // top to bottom, in order (the list builds only what is near the screen)
    for (final heading in [
      'Sleep periods', 'Dream sleep check', 'Jaw and movement', 'Hour by hour', 'Past nights', 'Licences',
    ]) {
      await tester.scrollUntilVisible(find.text(heading), 300);
      expect(find.text(heading), findsOneWidget);
      if (heading == 'Dream sleep check') expect(find.textContaining('Side-to-side eye movements (T3-T4): '), findsOneWidget);
      if (heading == 'Jaw and movement') expect(find.text('Jaw muscle bursts'), findsOneWidget);
      if (heading == 'Hour by hour') {
        await tester.scrollUntilVisible(find.textContaining('Jaw on earlier nights: '), -300);
        await tester.scrollUntilVisible(find.text('Hour by hour'), 300);
      }
    }
    expect(find.text('Tue 17 Nov'), findsNothing); // the open night is not in its own list
    expect(find.textContaining('too short to score'), findsOneWidget);
    expect(find.textContaining(' · jaw '), findsNWidgets(2)); // the past nights with extras
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older report without extras shows no extras', (tester) async {
    final json = Map<String, dynamic>.of(_main.json)..remove('extras');
    await tester.pumpWidget(MaterialApp(
      theme: nightTheme(),
      home: SleepReportView(nightOf: '2026-11-17', report: SleepReport(json)),
    ));
    await tester.scrollUntilVisible(find.text('Sleep periods'), 400);
    expect(find.text('Jaw and movement'), findsNothing);
    expect(find.textContaining('through noise'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a report from an earlier scorer offers Score again, at the bottom; while scoring it does not', (tester) async {
    var asked = 0;
    Widget page({String? step}) => MaterialApp(
      theme: nightTheme(),
      home: SleepReportView(
        nightOf: '2026-11-17',
        report: SleepReport(Map<String, dynamic>.of(_main.json)..['model'] = 'anysleep older pieces'),
        scoringStep: step,
        onRescore: () => asked++,
      ),
    );
    await tester.pumpWidget(page());
    await tester.scrollUntilVisible(find.text('Score again'), 400);
    expect(find.textContaining('An earlier version of the app scored this night'), findsOneWidget);
    await tester.tap(find.text('Score again'));
    expect(asked, 1);
    await tester.pumpWidget(const SizedBox()); // a fresh page, scrolled to the top
    await tester.pumpWidget(page(step: 'Sleep model 40 % (run 2 of 3)'));
    expect(find.textContaining('Scoring this night on the phone: Sleep model 40 % (run 2 of 3).'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Scored on this phone'), 400);
    expect(find.text('Score again'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
