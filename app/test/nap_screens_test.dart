// Renders the nap coach in its states at a phone's size with real fonts, writes PNGs to build/screens/nap_*.png for a
// human look, and fails on any layout overflow (also at 130 % text). The naps below are made up for the pictures;
// nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/detectors/drift_off.dart' show DriftState;
import 'package:eeg_tracker/nap/controller.dart';
import 'package:eeg_tracker/nap/rules.dart';
import 'package:eeg_tracker/nap/store.dart';
import 'package:eeg_tracker/sleep/live_stager.dart' show LiveMode;
import 'package:eeg_tracker/sound/audio_route.dart';
import 'package:eeg_tracker/ui/cue_sound_check.dart';
import 'package:eeg_tracker/ui/nap_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

NapSession _nap(DateTime start, {required String stages, NapEnd end = NapEnd.deepSleep, int length = 30, int? onsetS = 420,
    NapLiveInfo live = const NapLiveInfo(mode: LiveMode.full, calls: 40, medianMs: 2100, maxMs: 3400)}) {
  final endS = stages.length * 30.0 + 45;
  return NapSession(
    start: start,
    lengthMin: length,
    recording: null,
    live: live,
    endS: endS,
    end: end,
    wakeS: end == NapEnd.stopped ? null : stages.length * 30.0,
    upS: end == NapEnd.stopped ? null : stages.length * 30.0 + 38,
    baselineS: 61,
    drowsyS: 300,
    onsetS: onsetS,
    deepEpoch: end == NapEnd.deepSleep ? stages.length - 5 : null,
    stages: stages,
  );
}

// awake 7 min, light sleep, deep sleep starting at 24.5 min, woken at 27 min (the last 2 min not scored)
final _deep = _nap(DateTime(2026, 11, 19, 14, 32), stages: '${'.' * 4}${'W' * 10}1122${'2' * 30}33${'.' * 4}');
final _length = _nap(
  DateTime(2026, 11, 18, 15, 5),
  stages: '${'.' * 4}${'W' * 16}11${'2' * 6}gggg${'2' * 4}W22${'.' * 4}',
  end: NapEnd.length,
  length: 20,
  onsetS: 540,
  live: const NapLiveInfo(mode: LiveMode.light, why: 'Two checks in a row took over 15 s (the last 16.2 s) with the full model, so it now uses 1 of its 3 runs.', calls: 31, medianMs: 7400, maxMs: 16200, poorEpochs: 4),
);
final _stopped = _nap(DateTime(2026, 11, 17, 13, 50), stages: '${'.' * 4}${'W' * 12}', end: NapEnd.stopped, onsetS: null,
    live: const NapLiveInfo(mode: LiveMode.timer, why: 'The sleep model stopped (no ONNX Runtime), so the timer alone ends the nap.'));

final Map<String, NapViewModel> states = {
  'first': const NapViewModel(stage: NapStage.setup),
  'ready_last': NapViewModel(stage: NapStage.setup, lengthMin: 20, latest: _deep, earlier: [_length, _stopped]),
  'long': const NapViewModel(stage: NapStage.setup, lengthMin: 90),
  'ended': NapViewModel(stage: NapStage.done, latest: _deep, justEnded: true, earlier: [_length, _stopped]),
  'ended_length': NapViewModel(stage: NapStage.done, lengthMin: 20, latest: _length, justEnded: true),
  'night_running': const NapViewModel(stage: NapStage.setup, recordingRuns: true),
  'failed': const NapViewModel(stage: NapStage.failed, message: 'Headband not found. Is it switched on and charged?'),
  'face_connecting': const NapViewModel(stage: NapStage.connecting, message: 'Found BrainBit Black. Connecting.'),
  'face_baseline': const NapViewModel(stage: NapStage.resting, seconds: 35),
  'face_resting': const NapViewModel(stage: NapStage.resting, seconds: 190, drift: DriftState.awake),
  'face_asleep': const NapViewModel(stage: NapStage.resting, seconds: 760, drift: DriftState.asleep, live: NapLive.on, lightSleep: true),
  'face_waiting': const NapViewModel(stage: NapStage.resting, seconds: 400, drift: DriftState.drowsy,
      liveNote: 'The sleep model waits for last night\'s scoring to finish; the timer covers until then.'),
  'face_timer': const NapViewModel(stage: NapStage.resting, lengthMin: 45, seconds: 1400, drift: DriftState.asleep, live: NapLive.timer,
      liveNote: 'The sleep model is too slow on this phone (two checks over 15 s, the last 17.9 s), so the timer alone ends the nap.'),
  'face_poor': const NapViewModel(stage: NapStage.resting, seconds: 900, drift: DriftState.awake, live: NapLive.poor,
      liveNote: 'The headband\'s signal is lost; the timer ends the nap until it is back.'),
  'wake_deep': const NapViewModel(stage: NapStage.waking, seconds: 1620, end: NapEnd.deepSleep),
  'wake_length': const NapViewModel(stage: NapStage.waking, lengthMin: 20, seconds: 1200, end: NapEnd.length),
};

NapView _view(NapViewModel m, {ValueChanged<int>? onLength, VoidCallback? onAwake, VoidCallback? onLightsOff}) => NapView(
  model: m,
  onLength: onLength ?? (_) {},
  onLightsOff: onLightsOff ?? () {},
  onStop: () {},
  onAwake: onAwake ?? () {},
  onOpen: (_) {},
  onInfo: () {},
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('nap coach ${e.key} at ${(scale * 100).round()} % text', (tester) async {
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
              home: RepaintBoundary(key: key, child: _view(e.value)),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/nap_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  testWidgets('the length, Lights off and "I\'m awake" reach their callbacks', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    int? length;
    var lightsOff = false, awake = false;
    await tester.pumpWidget(MaterialApp(
      theme: nightTheme(),
      home: _view(states['first']!, onLength: (v) => length = v, onLightsOff: () => lightsOff = true),
    ));
    await tester.tap(find.text('45 min'));
    await tester.tap(find.text('Lights off'));
    expect(length, 45);
    expect(lightsOff, isTrue);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['wake_deep']!, onAwake: () => awake = true)));
    expect(find.textContaining('Deep sleep was starting'), findsOneWidget);
    await tester.tap(find.text("I'm awake"));
    expect(awake, isTrue);
  });

  testWidgets('the setup says where the wake sound plays and that the phone may be locked', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['first']!)));
    expect(find.textContaining('or from Bluetooth headphones when they are connected'), findsOneWidget);
    expect(find.textContaining('locking the phone can stop the nap'), findsNothing);
    expect(find.textContaining('If you lock the phone, the nap goes on'), findsOneWidget);
  });

  testWidgets('Lights off with the media volume off: a dialog says so; Not now stops, the other button goes on', (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      theme: nightTheme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answer = await confirmCueSound(
            context,
            cue: 'the wake cue',
            go: 'Lights off anyway',
            routes: FixedAudioRoute(const AudioRoute(RouteKind.speaker)),
            volume: () async => (volume: 0, max: 15),
          ),
          child: const Text('Lights off'),
        ),
      ),
    ));
    await tester.tap(find.text('Lights off'));
    await tester.pumpAndSettle();
    expect(find.textContaining('media volume is off'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    await tester.tap(find.text('Lights off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lights off anyway'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('the report says why it woke you and how the model ran', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['ended_length']!)));
    expect(find.text('at 20 min, your length'), findsOneWidget);
    expect(find.text('light 7, deep 0, dream 0 min'), findsOneWidget);
    expect(find.text('1 run, 7.4 s a check'), findsOneWidget);
    expect(find.textContaining('1 of its 3 runs'), findsOneWidget);
    expect(find.text('after 9 min'), findsOneWidget);
    expect(napLine(_stopped), '30 min · no sleep seen · stopped');
  });

  testWidgets('a nap the timer alone ended: no stage minutes, "not scored", beside the alpha rule\'s onset', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final timerOnly = _nap(
      DateTime(2026, 11, 19, 15),
      stages: '.' * 40,
      end: NapEnd.length,
      length: 20,
      onsetS: 540,
      live: const NapLiveInfo(mode: LiveMode.timer, why: 'The sleep model stopped (no ONNX Runtime), so the timer alone ends the nap.'),
    );
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(NapViewModel(stage: NapStage.done, latest: timerOnly, justEnded: true))));
    expect(find.text('after 9 min'), findsOneWidget);
    expect(find.text('0 min'), findsNothing, reason: 'nothing was scored: no "Asleep 0 min" beside "Fell asleep after 9 min"');
    expect(find.text('light 0, deep 0, dream 0 min'), findsNothing);
    expect(find.text('not scored (timer only)'), findsNWidgets(2));
    expect(find.textContaining('last 2 minutes'), findsNothing);
    // with the model on, the last 2 minutes and the wake are never scored, and the report says so
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['ended_length']!)));
    expect(find.textContaining('leave out the last 2 minutes'), findsOneWidget);
  });
}
