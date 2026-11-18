// Renders the meditation screen in its states at a phone's size with real fonts, writes PNGs to
// build/screens/meditation_*.png for a human look, and fails on any layout overflow (also at 130 % text).
// The numbers below are made up for the pictures; nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/ui/meditation_view.dart';
import 'package:eeg_tracker/ui/phase_track.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const _contact = {'O1': 4.2e5, 'O2': 1.6e6, 'T3': 8.1e5, 'T4': null};

const List<(double, String)> _allMarks = [
  (42, 'jaw'),
  (95, 'blinks'),
  (130, 'blinks'),
  (188, 'movement'),
  (260, 'blinks'),
  (333, 'drifting'),
  (410, 'jaw'),
  (512, 'blinks'),
];
const List<double> _calm = [
  0.35, 0.42, 0.51, 0.58, 0.49, 0.62, 0.66, 0.6, 0.71, 0.55, 0.68, 0.73, 0.64, 0.7, 0.59, 0.66, 0.72, 0.69, 0.75, 0.71, //
];

/// A made-up summary whose counts agree with its marks, as the tracker's do.
MeditationSummary _s(DateTime start, {double runS = 600, double settledS = 330, int bells = 14, bool complete = true}) {
  final marks = _allMarks.where((m) => m.$1 < runS).toList();
  int count(String k) => marks.where((m) => m.$2 == k).length;
  return MeditationSummary(
    start: start,
    lengthMin: 10,
    runS: runS,
    complete: complete,
    settledS: settledS,
    longestSettledS: 52,
    bells: bells,
    restless: {for (final r in Restless.values) r: count(r.name)},
    drifting: count('drifting'),
    drowsyS: count('drifting') * 34,
    calm: _calm.sublist(0, (runS / 30).ceil().clamp(1, 20)),
    marks: marks,
    iafHz: 9.75,
    note: '',
    logFile: '',
  );
}

final _earlier = [
  for (var d = 0; d < 6; d++) _s(DateTime(2026, 11, 17 - d, 21, 10), settledS: 240.0 + 15 * d, bells: 9 + d),
];

final Map<String, MeditationViewModel> states = {
  'setup': meditationModel(stage: Stage.setup, minutes: 10),
  'setup_night_running': meditationModel(stage: Stage.setup, minutes: 10, nightRunning: true),
  'connecting': meditationModel(stage: Stage.connecting, minutes: 10, message: 'Found BrainBit Black. Connecting.'),
  'eyes_open': meditationModel(stage: Stage.calibrating, minutes: 10, calPhase: 'open', calSecondsLeft: 21, contact: _contact),
  'eyes_closed': meditationModel(
    stage: Stage.calibrating,
    minutes: 10,
    calPhase: 'closed',
    calSecondsLeft: 38,
    contact: _contact,
  ),
  'settled': meditationModel(
    stage: Stage.running,
    minutes: 10,
    chip: Moment.settled,
    runSeconds: 268,
    bells: 9,
    contact: _contact,
  ),
  'restless': meditationModel(
    stage: Stage.running,
    minutes: 10,
    chip: Moment.restless,
    runSeconds: 301,
    bells: 9,
    contact: _contact,
  ),
  'no_signal': meditationModel(
    stage: Stage.running,
    minutes: 20,
    chip: Moment.noSignal,
    runSeconds: 412,
    bells: 11,
    contact: _contact,
    soundNote: 'The sound did not start (no audio device). This session runs without sound.',
  ),
  'report': meditationModel(
    stage: Stage.report,
    minutes: 10,
    report: _s(DateTime(2026, 11, 18, 21, 4)),
    comparison: compareWithEarlier(_s(DateTime(2026, 11, 18, 21, 4)), _earlier).line,
    earlier: _earlier,
  ),
  'report_first_stopped': meditationModel(
    stage: Stage.report,
    minutes: 20,
    report: _s(DateTime(2026, 11, 18, 21, 4), runS: 251, settledS: 96, bells: 4, complete: false),
    comparison: compareWithEarlier(_s(DateTime(2026, 11, 18, 21, 4), runS: 251, settledS: 96), const []).line,
  ),
  'failed': meditationModel(
    stage: Stage.failed,
    minutes: 10,
    message: 'Headband not found. Is it switched on, charged, and free (no night recording)?',
  ),
};

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('meditation ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // about a Xiaomi 12T: 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(
              tester.view,
            ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(
                key: key,
                child: MeditationView(
                  model: e.value,
                  onMinutes: (_) {},
                  onStart: () {},
                  onStop: () {},
                  onDone: () {},
                  onInfo: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/screens/meditation_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true);
          out.writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  test('the track keeps eyes closed twice eyes open at every length, and fills the width', () {
    for (final minutes in [5, 10, 20]) {
      final w = trackWidths(392, minutes * 60.0);
      expect(w[1], closeTo(2 * w[0], 1e-9), reason: '$minutes min');
      expect(w[0], greaterThanOrEqualTo(22));
      expect(w.reduce((a, b) => a + b) + 12, closeTo(392, 1e-9));
      expect(w[2], greaterThan(w[1]));
    }
  });

  testWidgets('the length choice and the actions reach their callbacks', (tester) async {
    int? picked;
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: MeditationView(
          model: states['setup']!,
          onMinutes: (v) => picked = v,
          onStart: () => started = true,
          onStop: () {},
          onDone: () {},
          onInfo: () {},
        ),
      ),
    );
    await tester.tap(find.text('20 min'));
    await tester.tap(find.text('Start meditation'));
    expect(picked, 20);
    expect(started, isTrue);
  });
}
