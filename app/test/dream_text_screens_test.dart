// Renders the dream catcher's answers as text (DECISIONS rows 254-255) at the owner's width (393 dp, a Xiaomi 11T)
// with real fonts, at 100 % and 130 % text, writes PNGs to build/screens/dream_text_*.png for a human look, and fails
// on any layout overflow; then checks that the words, Undo edit, Try again and the model's buttons reach their
// callbacks. The sessions and words below are made up for the pictures; nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/dream/answer_text.dart';
import 'package:eeg_tracker/dream/controller.dart';
import 'package:eeg_tracker/dream/rounds.dart';
import 'package:eeg_tracker/dream/store.dart';
import 'package:eeg_tracker/dream/voice.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/ui/dream_text_view.dart';
import 'package:eeg_tracker/ui/dream_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final _start = DateTime(2026, 11, 19, 0, 40);
final _stem = fileStem(_start);

DreamSession _session() => DreamSession(
  start: _start,
  plannedRounds: 4,
  ending: DreamEnding.wake,
  prompts: const {'theme': 'own', 'question': 'own'},
  recording: _stem,
  firstTimerS: 760,
  baselineS: 62,
  rounds: [
    for (final (i, (atS, how, note)) in [
      (431.0, AnswerEnd.silence, 'The stairs again'),
      (902.0, AnswerEnd.silence, ''),
      (1388.0, AnswerEnd.noVoice, ''),
      (1702.0, AnswerEnd.silence, ''),
    ].indexed)
      DreamRound(
        n: i + 1,
        atS: atS,
        at: _start.add(Duration(seconds: atS.round())),
        cause: i == 2 ? DreamCause.timer : DreamCause.drowsy,
        state: 'drowsy',
        answerFile: '$_stem-r${i + 1}.wav',
        answerS: 9.0 + 4 * i,
        voiceS: 6,
        end: how,
        drifting: i.isEven,
        endS: atS + 45,
        note: note,
      ),
  ],
  endS: 1980,
  endWhy: DreamEnd.rounds,
);

final DreamSession _s = _session();
String _f(int n) => '$_stem-r$n.wav';
const _mb = 670576784;

final Map<String, DreamViewModel> states = {
  'morning': DreamViewModel(
    stage: DreamStage.setup,
    latest: _s,
    words: {
      _f(1): const AnswerWords(WordsState.done, text: 'Я видел лестницу из книжных полок, и книги были ступеньками'),
      _f(2): const AnswerWords(WordsState.done, text: 'a staircase going up into the clouds, my grandmother at the top', edited: true),
      _f(3): const AnswerWords(WordsState.done),
      _f(4): const AnswerWords(WordsState.failed, why: 'the recording is not a 16 kHz WAV (no sound in the WAV file)', giveUp: true),
    },
    speech: const SpeechInfo(SpeechState.ready, total: _mb),
  ),
  'writing': DreamViewModel(
    stage: DreamStage.done,
    justEnded: true,
    latest: _s,
    words: {
      _f(1): const AnswerWords(WordsState.done, text: 'Какие-то цифры падали с неба, как снег'),
      _f(2): const AnswerWords(WordsState.working),
      _f(3): const AnswerWords(WordsState.waiting),
      _f(4): const AnswerWords(WordsState.failed, why: 'out of memory'),
    },
    speech: const SpeechInfo(SpeechState.ready, total: _mb),
  ),
  'no_model': DreamViewModel(stage: DreamStage.setup, latest: _s, speech: const SpeechInfo(SpeechState.absent, total: _mb)),
  'downloading': const DreamViewModel(stage: DreamStage.setup, speech: SpeechInfo(SpeechState.downloading, bytes: 312400000, total: _mb)),
  'download_failed': const DreamViewModel(
    stage: DreamStage.setup,
    speech: SpeechInfo(SpeechState.failed, bytes: 312400000, total: _mb, message: 'The download stalled. Try again.'),
  ),
};

DreamView _view(
  DreamViewModel m, {
  void Function(DreamSession, DreamRound, String)? onWords,
  void Function(DreamSession, DreamRound)? onUndo,
  void Function(DreamSession, DreamRound)? onRetry,
  VoidCallback? onDownload,
}) => DreamView(
  model: m,
  onRounds: (_) {},
  onEnding: (_) {},
  onLightsOff: () {},
  onStop: () {},
  onDrifting: (_) {},
  onRecord: (_) {},
  onPlayPrompt: (_) {},
  onPlayAnswer: (_, _) {},
  onNote: (_, _, _) {},
  onOpen: (_) {},
  onInfo: () {},
  onWords: onWords,
  onUndoWords: onUndo,
  onRetryWords: onRetry,
  onSpeechDownload: onDownload,
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('dream catcher words ${e.key} at ${(scale * 100).round()} % text, 393 dp', (tester) async {
        tester.view.physicalSize = const Size(1080, 2400); // the owner's Xiaomi 11T: 393 x 873 dp
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
        // the whole column, not just the first screen: scroll to the end and render that too
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        Future<void> shot(String suffix) => tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/dream_text_${e.key}${scale == 1.0 ? '' : '_text130'}$suffix.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
        await shot('');
        for (final suffix in ['_mid', '_down']) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          await shot(suffix);
        }
      });
    }
  }

  testWidgets('the words reach their callbacks: typing, Undo edit, Try again, Download', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final typed = <String>[], undone = <int>[], retried = <int>[];
    var downloads = 0;
    Widget app(DreamViewModel m) => MaterialApp(
      theme: nightTheme(),
      home: _view(
        m,
        onWords: (_, r, v) => typed.add('${r.n}:$v'),
        onUndo: (_, r) => undone.add(r.n),
        onRetry: (_, r) => retried.add(r.n),
        onDownload: () => downloads++,
      ),
    );
    await tester.pumpWidget(app(states['morning']!));
    expect(find.text('Words heard by the phone'), findsOneWidget);
    expect(find.text('Your words'), findsOneWidget);
    expect(find.text('No words heard.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Я видел лестницу из книжных полок, и книги были ступеньками'), 'Я видел лестницу');
    expect(typed, ['1:Я видел лестницу']);
    await tester.tap(find.text('Undo edit'));
    expect(undone, [2]);
    await tester.dragUntilVisible(find.text('Try again').hitTestable(), find.byType(ListView).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    expect(retried, [4]);

    await tester.pumpWidget(app(states['no_model']!));
    expect(find.text('Words heard by the phone'), findsNothing, reason: 'no model: no words block in the rows');
    await tester.dragUntilVisible(find.textContaining('Download (').hitTestable(), find.byType(ListView).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Download ('));
    expect(downloads, 1);
  });

  test('the row\'s state from the text file: working, words, yours, failed, waiting, none', () {
    final at = DateTime(2026, 11, 19);
    const empty = AnswerText(answer: 'a-r1.wav');
    final heard = empty.started().withMachine(MachineText(text: 'tree', model: 'm', at: at, audioS: 3, voiceS: 2, tookS: 1));
    expect(wordsFor(empty, modelReady: true, working: true).state, WordsState.working);
    expect(wordsFor(heard, modelReady: true, working: false).text, 'tree');
    final mine = wordsFor(heard.edit('three'), modelReady: false, working: false);
    expect((mine.state, mine.text, mine.edited), (WordsState.done, 'three', true));
    final failed = wordsFor(empty.started().withFailure('x'), modelReady: true, working: false);
    expect((failed.state, failed.giveUp), (WordsState.failed, false));
    expect(wordsFor(empty.started().withFailure('x').started().withFailure('x'), modelReady: true, working: false).giveUp, true);
    expect(wordsFor(null, modelReady: true, working: false).state, WordsState.waiting);
    expect(wordsFor(empty.started(), modelReady: true, working: false).state, WordsState.waiting, reason: 'stalled: it tries again');
    expect(wordsFor(null, modelReady: false, working: false).state, WordsState.none);
  });
}
