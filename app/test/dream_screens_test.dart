// Renders the dream catcher in its states at a phone's size with real fonts, writes PNGs to build/screens/dream_*.png
// for a human look, and fails on any layout overflow (also at 130 % text). The sessions below are made up for the
// pictures; nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/dream/controller.dart';
import 'package:eeg_tracker/dream/rounds.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/dream/voice.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/ui/dream_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

DreamSession _session(DateTime start, List<(double, DreamCause, bool?, AnswerEnd, String)> rounds, {String end = DreamEnd.rounds, String? night}) =>
    DreamSession(
      start: start,
      plannedRounds: 4,
      ending: night == null ? DreamEnding.wake : DreamEnding.sleep,
      prompts: const {'theme': 'own', 'question': 'own'},
      recording: fileStem(start),
      firstTimerS: 760,
      baselineS: 62,
      rounds: [
        for (final (i, (atS, cause, drifting, how, note)) in rounds.indexed)
          DreamRound(
            n: i + 1,
            atS: atS,
            at: start.add(Duration(seconds: atS.round())),
            cause: cause,
            state: 'drowsy',
            answerFile: how == AnswerEnd.failed ? null : '${fileStem(start)}-r${i + 1}.wav',
            answerS: how == AnswerEnd.failed ? 0 : 9.0 + 4 * i,
            voiceS: 6,
            end: how,
            drifting: drifting,
            endS: atS + 45,
            note: note,
          ),
      ],
      endS: 1980,
      endWhy: end,
      night: night,
    );

final _last = _session(DateTime(2026, 11, 18, 23, 12), [
  (431, DreamCause.drowsy, true, AnswerEnd.silence, 'A staircase made of bookshelves; the books were the steps'),
  (902, DreamCause.drowsy, false, AnswerEnd.silence, ''),
  (1388, DreamCause.timer, null, AnswerEnd.noVoice, ''),
]);
final _earlier = [
  _session(DateTime(2026, 11, 17, 23, 40), [(512, DreamCause.drowsy, true, AnswerEnd.silence, 'ladders')], end: DreamEnd.cap),
  _session(DateTime(2026, 11, 16, 14, 5), [], end: DreamEnd.stopped),
];
const _contact = {'O1': 4.2e5, 'O2': 1.6e6, 'T3': 8.1e5, 'T4': null};
const _mine = PromptInfo(seconds: 3.4);

final Map<String, DreamViewModel> states = {
  'first': const DreamViewModel(stage: DreamStage.setup),
  'morning': DreamViewModel(stage: DreamStage.setup, theme: _mine, question: const PromptInfo(seconds: 2.1), latest: _last, earlier: _earlier, playing: _last.rounds.first.answerFile),
  'recording_prompt': const DreamViewModel(stage: DreamStage.setup, theme: _mine, recording: PromptKind.question, recordingS: 2),
  'ended': DreamViewModel(stage: DreamStage.done, theme: _mine, question: _mine, latest: _last, justEnded: true, earlier: _earlier, ending: DreamEnding.wake),
  'night_running': const DreamViewModel(stage: DreamStage.setup, nightRunning: true, ending: DreamEnding.sleep),
  'failed': const DreamViewModel(stage: DreamStage.failed, message: 'Headband not found. Is it switched on, charged, and free (no night recording)?'),
  'face_connecting': const DreamViewModel(stage: DreamStage.connecting, message: 'Found BrainBit Black. Connecting.'),
  'face_baseline': const DreamViewModel(stage: DreamStage.baseline, contact: _contact),
  'face_drifting': const DreamViewModel(stage: DreamStage.drifting, roundsDone: 1, minutes: 14),
  'face_asking': const DreamViewModel(stage: DreamStage.asking, roundsDone: 1, roundNow: 2, minutes: 19),
  'face_answering': const DreamViewModel(stage: DreamStage.answering, roundsDone: 1, roundNow: 2, minutes: 19),
  'face_checking': const DreamViewModel(stage: DreamStage.checking, roundsDone: 1, roundNow: 2, minutes: 20),
  'face_no_signal': const DreamViewModel(stage: DreamStage.drifting, roundsDone: 2, rounds: 3, minutes: 31, noData: true),
};

DreamView _view(DreamViewModel m, {ValueChanged<bool>? onDrifting, VoidCallback? onLightsOff, ValueChanged<int>? onRounds}) => DreamView(
  model: m,
  onRounds: onRounds ?? (_) {},
  onEnding: (_) {},
  onLightsOff: onLightsOff ?? () {},
  onStop: () {},
  onDrifting: onDrifting ?? (_) {},
  onRecord: (_) {},
  onPlayPrompt: (_) {},
  onPlayAnswer: (_, _) {},
  onNote: (_, _, _) {},
  onOpen: (_) {},
  onInfo: () {},
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('dream catcher ${e.key} at ${(scale * 100).round()} % text', (tester) async {
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
          File('build/screens/dream_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  testWidgets('the halves answer drifting or awake; the choices and Lights off reach their callbacks', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final answers = <bool>[];
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['face_checking']!, onDrifting: answers.add)));
    await tester.tap(find.text('Drifting'));
    await tester.tap(find.text('Awake'));
    expect(answers, [true, false]);

    int? rounds;
    var lightsOff = false;
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: _view(states['first']!, onLightsOff: () => lightsOff = true, onRounds: (v) => rounds = v)),
    );
    await tester.tap(find.text('Lights off'));
    await tester.scrollUntilVisible(find.text('3 rounds'), 200);
    await tester.tap(find.text('3 rounds'));
    expect((lightsOff, rounds), (true, 3));
  });

  testWidgets('a night recording disables Lights off; the face shows nothing brighter than its words', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['night_running']!)));
    final button = tester.widget<FilledButton>(find.ancestor(of: find.text('Lights off'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(button.onPressed, isNull);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(states['face_drifting']!)));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, faceGround);
    expect(find.text('Drift off'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
}
