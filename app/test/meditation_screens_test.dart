// Renders the meditation screen in its states at a phone's size with real fonts, writes PNGs to
// build/screens/meditation_*.png for a human look, and fails on any layout overflow (also at 130 % text).
// The numbers below are made up for the pictures; nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/learning.dart';
import 'package:eeg_tracker/meditation/silent_block.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/sound/audio_route.dart';
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
MeditationSummary _s(
  DateTime start, {
  double runS = 600,
  double settledS = 330,
  int bells = 14,
  bool complete = true,
  SilentBlock? silent,
  bool bluetooth = false,
}) {
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
    silent: silent,
    bluetoothSound: bluetooth,
  );
}

SilentBlock _block(double? alpha, {double seconds = 120}) =>
    SilentBlock(plannedS: 120, seconds: seconds, countedS: 96, alpha: alpha, muscleShare: 0.04, drowsyShare: 0.02);

/// Nine made-up meditations whose silent minutes rise about 2 % a session (some noise), for the learning section.
final List<MeditationSummary> _nine = [
  for (var d = 0; d < 9; d++)
    MeditationSummary(
      start: DateTime(2026, 11, 2 + d, 21, 10),
      lengthMin: 10,
      runS: 600,
      complete: true,
      settledS: 300,
      longestSettledS: 40,
      bells: 12,
      restless: const {Restless.jaw: 1, Restless.blinks: 3, Restless.movement: 0},
      drifting: 0,
      drowsyS: 0,
      calm: const [0.5],
      iafHz: 9.75,
      note: '',
      logFile: '',
      outcome: 0.06 + 0.003 * d,
      bluetoothSound: d == 2,
      silent: _block(0.01 * d + (d.isEven ? 0.006 : -0.006)),
    ),
];

final _earlier = [
  for (var d = 0; d < 6; d++) _s(DateTime(2026, 11, 17 - d, 21, 10), settledS: 240.0 + 15 * d, bells: 9 + d),
];

final Map<String, MeditationViewModel> states = {
  'setup': meditationModel(stage: Stage.setup, minutes: 10),
  'setup_night_running': meditationModel(stage: Stage.setup, minutes: 10, recordingRuns: true),
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
  'setup_bluetooth': meditationModel(
    stage: Stage.setup,
    minutes: 10,
    silentSeconds: 120,
    route: const AudioRoute(RouteKind.bluetooth, type: 'a2dp', device: 'WH-1000XM4'),
  ),
  'setup_silent': meditationModel(stage: Stage.setup, minutes: 5, silentSeconds: 120),
  'silent_minutes': meditationModel(
    stage: Stage.running,
    minutes: 10,
    chip: Moment.settled,
    runSeconds: 600,
    bells: 14,
    contact: _contact,
    silentSeconds: 120,
    silentRun: 47,
    inSilent: true,
    route: const AudioRoute(RouteKind.bluetooth, device: 'WH-1000XM4'),
  ),
  'report_learning': meditationModel(
    stage: Stage.report,
    minutes: 10,
    silentSeconds: 120,
    report: _s(DateTime(2026, 11, 18, 21, 4), silent: _block(0.072), bluetooth: true),
    comparison: compareWithEarlier(_s(DateTime(2026, 11, 18, 21, 4)), _earlier).line,
    earlier: _earlier,
    learning: learningVerdict(_nine),
  ),
  'report_not_yet': meditationModel(
    stage: Stage.report,
    minutes: 20,
    silentSeconds: 120,
    report: _s(DateTime(2026, 11, 18, 21, 4), silent: _block(null, seconds: 41)),
    comparison: compareWithEarlier(_s(DateTime(2026, 11, 18, 21, 4)), _earlier).line,
    earlier: _earlier,
    learning: learningVerdict(_nine.take(3).toList()),
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
    message: 'Headband not found. Is it switched on and charged?',
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

  test('a session a clock limit ended says so in its report; one ended by its length or Stop does not', () {
    MeditationSummary ended(String? end) => MeditationSummary.fromJson({..._s(DateTime(2026, 11, 19, 21)).toJson(), 'end': end})!;
    final silent = meditationModel(stage: Stage.report, minutes: 20, report: ended(MeditationSummary.endNoSignal));
    expect(silent.notes.join(' '), contains('no signal for 5 minutes'));
    final limit = meditationModel(stage: Stage.report, minutes: 20, report: ended(MeditationSummary.endClock));
    expect(limit.notes.join(' '), contains('time limit'));
    expect(meditationModel(stage: Stage.report, minutes: 20, report: ended(null)).notes, isEmpty);
  });

  test('the track keeps eyes closed twice eyes open at every length, and fills the width', () {
    for (final minutes in [5, 10, 20]) {
      final w = trackWidths(392, minutes * 60.0);
      expect(w[1], closeTo(2 * w[0], 1e-9), reason: '$minutes min');
      expect(w[0], greaterThanOrEqualTo(22));
      expect(w.reduce((a, b) => a + b) + 12, closeTo(392, 1e-9));
      expect(w[2], greaterThan(w[1]));
      // with the 2 silent minutes: a fourth cell, in its real ratio to the time with sound
      final q = trackWidths(392, minutes * 60.0, silentSeconds: 120);
      expect(q, hasLength(4));
      expect(q[3] / q[2], closeTo(120 / (minutes * 60), 1e-9));
      expect(q[1], closeTo(2 * q[0], 1e-9));
      expect(q[3], greaterThanOrEqualTo(22));
      expect(q.reduce((a, b) => a + b) + 18, closeTo(392, 1e-9));
      expect(q[2], greaterThan(q[3]), reason: '$minutes min with sound outweigh 2 without');
    }
  });

  testWidgets('the report shows the silent minutes\' number and the learning lines; the setup the Bluetooth warning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1210, 8000); // tall: the whole report is built
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    Future<void> show(String key) => tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: MeditationView(
          model: states[key]!,
          onMinutes: (_) {},
          onStart: () {},
          onStop: () {},
          onDone: () {},
          onInfo: () {},
        ),
      ),
    );
    await show('report_learning');
    expect(find.text('Learning'), findsOneWidget);
    expect(find.text('Alpha without sound'), findsOneWidget);
    expect(find.text('+18.0 %'), findsOneWidget);
    expect(find.textContaining('Going up: alpha in the silent minutes rose about'), findsOneWidget);
    expect(find.textContaining('Seen together, not tested'), findsOneWidget);
    expect(find.textContaining('went to Bluetooth headphones'), findsOneWidget);
    await show('report_not_yet');
    expect(find.textContaining('Not enough sessions yet: 3 of 8'), findsOneWidget);
    expect(find.text('not enough'), findsOneWidget);
    expect(find.text('stopped after 41 s'), findsOneWidget);
    await show('setup_bluetooth');
    expect(find.textContaining('Sound goes to Bluetooth headphones (WH-1000XM4)'), findsOneWidget);
    expect(find.textContaining('Wired headphones or the phone\'s speaker. Bluetooth'), findsNothing);
    expect(find.textContaining('At the end, 2 min without sound: go on the same way.'), findsOneWidget);
    expect(find.text('30 s eyes open · 60 s eyes closed · 10 min with sound · 2\u00a0min\u00a0without'), findsOneWidget);
    await show('silent_minutes');
    expect(find.text('Without sound'), findsOneWidget);
    expect(find.text('without sound, left'), findsOneWidget);
    expect(find.textContaining('it comes about 0.25-0.5 s late'), findsOneWidget);
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
