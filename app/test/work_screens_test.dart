// Renders the work session page in its states at a phone's size with real fonts, writes PNGs to
// build/screens/work_*.png for a look, and checks that the buttons reach their callbacks.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/work_view.dart';
import 'package:eeg_tracker/work/breaks.dart';
import 'package:eeg_tracker/work/controller.dart';
import 'package:eeg_tracker/work/drowsiness.dart';
import 'package:eeg_tracker/work/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final _t = DateTime(2026, 11, 19, 11, 40);
final _hint = WorkHint(at: _t, reason: HintReason.drowsy, activeMin: 48, thresholdMin: 60, level: DrowsyLevel.gettingDrowsy);
const _cells = [
  WorkCell.alert, WorkCell.alert, WorkCell.alert, WorkCell.unknown, WorkCell.alert, WorkCell.alert,
  WorkCell.alert, WorkCell.gettingDrowsy, WorkCell.gettingDrowsy, WorkCell.drowsy, WorkCell.drowsy, WorkCell.gettingDrowsy,
];
final _past = WorkSummary(start: DateTime(2026, 11, 18, 14, 5), end: DateTime(2026, 11, 18, 16, 50), wornMin: 152, hints: 2, breaks: 1, drowsyMin: 18, alertMin: 120, hintList: [_hint]);
final _other = WorkSummary(start: DateTime(2026, 11, 17, 9, 30), end: DateTime(2026, 11, 17, 11, 0), wornMin: 85, hints: 0, breaks: 0, drowsyMin: 4, alertMin: 80, hintList: const [], wearerAnswer: 'someone else');

const _quiet = 'The media volume is low (2 of 15), so the break chime may not be heard. The hints also show on the lock screen.';

final Map<String, WorkViewModel> states = {
  'setup': WorkViewModel(stage: WorkStage.setup, sessions: [_past, _other], wearerOn: true),
  'night': const WorkViewModel(stage: WorkStage.setup, nightRunning: true),
  'connecting': const WorkViewModel(stage: WorkStage.connecting, message: 'Found BrainBit. Connecting.'),
  'eyes_closed': const WorkViewModel(stage: WorkStage.eyesClosed, closedLeft: 42),
  'calibrating': const WorkViewModel(stage: WorkStage.calibrating, calibrationLeftMin: 2.5, cells: [WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none, WorkCell.none], wornMin: 1.5, stretchMin: 1.5),
  'quiet': const WorkViewModel(stage: WorkStage.calibrating, calibrationLeftMin: 3.5, wornMin: 0.5, stretchMin: 0.5, volumeNote: _quiet),
  'alert': const WorkViewModel(stage: WorkStage.running, level: DrowsyLevel.alert, cells: _cells, wornMin: 64, stretchMin: 23, hintsToday: 1, afterBreak: 'After your break: drowsiness went down (getting drowsy before, alert after).'),
  'hint': WorkViewModel(stage: WorkStage.running, level: DrowsyLevel.gettingDrowsy, cells: _cells, wornMin: 64, stretchMin: 48, hintsToday: 2, hint: _hint),
  'rated': WorkViewModel(stage: WorkStage.running, level: DrowsyLevel.drowsy, cells: _cells, wornMin: 64, stretchMin: 48, hintsToday: 2, hint: _hint, rated: 2),
  'break': const WorkViewModel(stage: WorkStage.running, level: DrowsyLevel.drowsy, onBreak: true, breakMin: 6, cells: _cells, wornMin: 64, hintsToday: 2),
  'noisy': const WorkViewModel(stage: WorkStage.running, noisy: true, signal: WorkSignal.noisy, cells: _cells, wornMin: 90, stretchMin: 30, hintsToday: 2, kept: false),
  'calibrating_talking': const WorkViewModel(stage: WorkStage.calibrating, calibrationWaits: true, signal: WorkSignal.noisy, calibrationLeftMin: 3, wornMin: 9, stretchMin: 9),
  'meeting': const WorkViewModel(stage: WorkStage.running, meeting: true, signal: WorkSignal.noisy, cells: _cells, wornMin: 95, stretchMin: 35, hintsToday: 1),
  'off': const WorkViewModel(stage: WorkStage.running, level: DrowsyLevel.alert, signal: WorkSignal.off, cells: _cells, wornMin: 64, stretchMin: 23),
  'done_raw': WorkViewModel(stage: WorkStage.done, summary: _past, rawNote: 'The raw EEG (54 MB) is kept with your recordings, apart from your nights, and goes out with Export data.'),
  'done_marked': WorkViewModel(stage: WorkStage.done, summary: _other, wearerOn: true),
  'done': WorkViewModel(stage: WorkStage.done, summary: _past, wearerOn: true, afterBreak: 'After your break: drowsiness went down (drowsy before, alert after).'),
  'failed': const WorkViewModel(stage: WorkStage.failed, message: 'Headband not found. Is it switched on, charged, and free (no night recording)?'),
};

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('work session ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // about a Xiaomi 11T / 12T: 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(key: key, child: WorkView(model: e.value, onStart: () {}, onStop: () {}, onBreak: () {}, onBack: () {}, onSnooze: () {}, onNotNow: () {}, onRate: (_) {}, onEyesClosedFirst: (_) {}, onAgain: () {}, onInfo: () {})),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/work_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  testWidgets('Start, On a break, Snooze, Not now, a rating and Stop reach their callbacks', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    Widget view(WorkViewModel m) => MaterialApp(
      theme: nightTheme(),
      home: WorkView(
        model: m,
        onStart: () => calls.add('start'),
        onStop: () => calls.add('stop'),
        onBreak: () => calls.add('break'),
        onBack: () => calls.add('back'),
        onSnooze: () => calls.add('snooze'),
        onNotNow: () => calls.add('not now'),
        onRate: (v) => calls.add('rate $v'),
        onEyesClosedFirst: (v) => calls.add('eyes $v'),
      ),
    );
    await tester.pumpWidget(view(states['setup']!));
    await tester.tap(find.text('Start work session'));
    await tester.tap(find.text('Start with 1 minute eyes closed'));
    await tester.pumpWidget(view(states['hint']!));
    await tester.tap(find.text('On a break'));
    await tester.tap(find.text('Snooze 20 min'));
    await tester.tap(find.text('Not now'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('Stop'));
    await tester.pumpWidget(view(states['break']!));
    expect(find.text('On a break'), findsOneWidget, reason: 'the status word');
    await tester.tap(find.text('Back'));
    expect(calls, ['start', 'eyes true', 'break', 'snooze', 'not now', 'rate 2', 'stop', 'back']);
  });

  testWidgets('a low media volume is a quiet line on the running page, not a dialog (DECISIONS 496)', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: WorkView(model: states['quiet']!)));
    expect(find.text(_quiet), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: WorkView(model: states['calibrating']!)));
    expect(find.textContaining('media volume'), findsNothing);
  });

  testWidgets('a working day in words: talking is not a break, calibration waits, a meeting, the raw EEG kept (DECISIONS 680-685)', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    Future<void> show(String k) => tester.pumpWidget(MaterialApp(theme: nightTheme(), home: WorkView(model: states[k]!)));
    await show('calibrating_talking');
    expect(find.text('Calibrating'), findsOneWidget);
    expect(find.textContaining('Waiting for a quiet minute to calibrate (talking?)'), findsOneWidget);
    expect(find.text('Talking / moving — reading paused'), findsOneWidget);
    expect(find.text('On a break'), findsOneWidget, reason: 'only the button: no break status');
    await show('meeting');
    expect(find.text('In a meeting'), findsOneWidget);
    expect(find.textContaining('break hints wait until it ends'), findsOneWidget);
    await show('off');
    expect(find.text('The headband seems off: no skin contact in the signal'), findsOneWidget);
    await show('done_raw');
    expect(find.textContaining('The raw EEG (54 MB) is kept with your recordings'), findsOneWidget);
  });

  testWidgets('during a night the page says so and Start is off', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: WorkView(model: states['night']!, onStart: () => fail('no start'))));
    expect(find.textContaining('recording the night'), findsOneWidget);
    await tester.tap(find.text('Start work session'));
  });
}
