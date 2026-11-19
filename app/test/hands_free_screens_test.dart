// Renders the hands-free Settings and calibration pages in their states at the owner's phone width (393 dp) with real
// fonts, writes PNGs to build/screens/handsfree_*.png for a human look, and fails on any layout overflow (also at
// 130 % text). The calibrations and lanes below are made up for the pictures; nothing here was measured.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:eeg_tracker/handsfree/calibration_controller.dart';
import 'package:eeg_tracker/handsfree/store.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

List<double> _jaw({bool clench = true}) => [
  for (var i = 0; i < 100; i++)
    clench && (i >= 70 && i < 75 || i >= 81 && i < 85) ? 30 + 25 * math.sin(i.toDouble()).abs() : 1.2 + 0.8 * math.sin(i * 1.7).abs(),
];

const List<LaneStep> _eyes = [(ago: 3.1, step: 135), (ago: 2.4, step: -262), (ago: 1.7, step: 120)];

const _both = GestureCalibration(
  GestureSettings(clenchX: 21.4, glanceUv: 78, leftSign: 1),
  [
    TryResult(GestureKind.clench, 32, 48.2, 0, 'ok'),
    TryResult(GestureKind.clench, 40, 42.8, 0, 'ok'),
    TryResult(GestureKind.clench, 48, null, 0, 'one'),
    TryResult(GestureKind.glance, 56, 131.0, 1, 'ok'),
    TryResult(GestureKind.glance, 64, 140.5, 1, 'ok'),
    TryResult(GestureKind.glance, 72, 118.9, 1, 'ok'),
  ],
  2,
  3,
  true,
  0,
);

const _none = GestureCalibration(
  GestureSettings(glanceOn: false, clenchOn: false),
  [
    TryResult(GestureKind.clench, 32, 9.1, 0, 'weak'),
    TryResult(GestureKind.clench, 40, null, 0, 'none'),
    TryResult(GestureKind.clench, 48, 12.0, 0, 'apart'),
    TryResult(GestureKind.glance, 56, null, 0, 'none'),
    TryResult(GestureKind.glance, 64, 62.0, -1, 'many'),
    TryResult(GestureKind.glance, 72, null, 1, 'noisy'),
  ],
  0,
  0,
  false,
  1,
);

CalibrationRecord _record(GestureCalibration c) => CalibrationRecord.of(c, DateTime(2026, 11, 19, 21, 5));

final Map<String, Widget> states = {
  'settings_first': _settings(const SettingsViewModel()),
  'settings_on': _settings(SettingsViewModel(on: true, calibration: _record(_both))),
  'settings_clench_only': _settings(
    SettingsViewModel(
      on: true,
      calibration: _record(
        const GestureCalibration(GestureSettings(clenchX: 34, glanceUv: 70, glanceOn: false), [], 3, 1, false, 0),
      ),
    ),
  ),
  'settings_night': _settings(SettingsViewModel(calibration: _record(_none), nightRunning: true)),
  'settings_on_uncalibrated': _settings(const SettingsViewModel(on: true)),
  'cal_setup': _cal(const CalViewModel(stage: CalStage.setup)),
  'cal_connecting': _cal(const CalViewModel(stage: CalStage.connecting, message: 'Found BrainBit Black. Connecting.')),
  'cal_still': _cal(
    CalViewModel(stage: CalStage.still, stillLeft: 9, jaw: [for (var i = 0; i < 100; i++) i < 30 ? double.nan : 1.3]),
  ),
  'cal_still_learning': _cal(const CalViewModel(stage: CalStage.still, stillLeft: 27)),
  'cal_clench': _cal(CalViewModel(stage: CalStage.trying, tryNow: 1, inWindow: true, jaw: _jaw(), shaped: const [true])),
  'cal_relax': _cal(CalViewModel(stage: CalStage.trying, tryNow: 2, jaw: _jaw(clench: false), shaped: const [true, false])),
  'cal_glance': _cal(
    CalViewModel(
      stage: CalStage.trying,
      tryNow: 4,
      inWindow: true,
      jaw: _jaw(clench: false),
      eyes: _eyes,
      shaped: const [true, false, true, true],
      linesAreYours: true,
      clenchLine: 21,
      glanceSize: 78,
    ),
  ),
  'cal_result': _cal(const CalViewModel(stage: CalStage.result, result: _both, clenchLine: 21.4)),
  'cal_result_none': _cal(const CalViewModel(stage: CalStage.result, result: _none)),
  'cal_failed': _cal(const CalViewModel(stage: CalStage.failed, message: 'The headband dropped out. Nothing was kept; please try again.')),
};

Widget _settings(SettingsViewModel m) => SettingsView(model: m, onToggle: (_) {}, onCalibrate: () {}, onInfo: () {});
Widget _cal(CalViewModel m) => CalibrationView(model: m, onStart: () {}, onStop: () {}, onDone: () {}, onInfo: () {});

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('hands-free ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1080, 2400); // the owner's Xiaomi 11T: 393 x 873 dp
        tester.view.devicePixelRatio = 1080 / 393;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: e.value)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1080 / 393);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/handsfree_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  test('the switch line says what is on, in words', () {
    expect(handsFreeStatus(const SettingsViewModel()), startsWith('Off. Calibrate first'));
    expect(handsFreeStatus(SettingsViewModel(on: true, calibration: _record(_both))), 'On: both gestures.');
    expect(handsFreeStatus(SettingsViewModel(on: true, calibration: _record(_none))), startsWith('On, but no gesture'));
    expect(handsFreeStatus(SettingsViewModel(calibration: _record(_none))), 'Off. No gesture was caught clearly; calibrate again.');
    expect(handsFreeStatus(const SettingsViewModel(on: true)), startsWith('On, but not calibrated'));
  });

  test('every rule a try can break has words', () {
    for (final why in ['ok', 'none', 'noisy', 'one', 'many', 'long', 'short', 'close', 'apart', 'weak', 'slow', 'same', 'way', 'small']) {
      for (final k in GestureKind.values) {
        expect(whyWords(k, why), isNot(why), reason: '$k $why');
      }
    }
  });

  test('the instruction follows the stage and the try', () {
    expect(calInstruction(const CalViewModel(stage: CalStage.still, stillLeft: 12)).$2, contains('12 s'));
    expect(calInstruction(const CalViewModel(stage: CalStage.trying, tryNow: 0, inWindow: true)).$1, 'Clench twice now');
    expect(calInstruction(const CalViewModel(stage: CalStage.trying, tryNow: 3, inWindow: true)).$1, 'Look left, then right');
    expect(calInstruction(const CalViewModel(stage: CalStage.trying, tryNow: 3)).$1, 'Relax');
  });

  testWidgets('the gear on the night screen opens Settings; the switch and Calibrate reach their callbacks', (tester) async {
    var opened = 0, calibrate = 0;
    final toggles = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: NightView(
          model: const NightViewModel(title: 'Ready', sentence: 'Tap Start night.', tone: Tone.calm, running: false),
          onStart: () {},
          onStop: () {},
          onFix: (_) {},
          onSettings: () => opened++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    expect(opened, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: SettingsView(model: const SettingsViewModel(), onToggle: toggles.add, onCalibrate: () => calibrate++, onInfo: () {}),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.scrollUntilVisible(find.text('Calibrate'), 200);
    await tester.tap(find.text('Calibrate'));
    expect([toggles, calibrate], [
      [true],
      1,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: SettingsView(model: const SettingsViewModel(nightRunning: true), onToggle: (_) {}, onCalibrate: () => calibrate++, onInfo: () {}),
      ),
    );
    await tester.scrollUntilVisible(find.text('Calibrate'), 200);
    await tester.tap(find.text('Calibrate'));
    expect(calibrate, 1, reason: 'the headband is busy with the night');
  });
}
