// Renders the Lucid dreams page and the evening practice in their states at the owner's phone width (393 dp), with
// real fonts, writes PNGs to build/screens/lucid_*.png for a human look (the first viewport and the whole column),
// fails on any layout overflow (also at 130 % text), and checks what is due from the files. The nights below are made
// up for the pictures; nothing here was measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/lucid/plan.dart';
import 'package:eeg_tracker/lucid/store.dart';
import 'package:eeg_tracker/ui/lucid_screen.dart';
import 'package:eeg_tracker/ui/lucid_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

final int _start = DateTime(2026, 11, 26, 0, 40).millisecondsSinceEpoch;
int _at(int h, int m) => DateTime(2026, 11, 26, h, m).millisecondsSinceEpoch;

final LucidNightRecord _record = LucidNightRecord(
  startMs: _start,
  index: 4,
  cuesFromMs: _start + 270 * 60000,
  phase: 'ended',
  cues: [
    for (final (h, m, p) in [(5, 41, 1), (5, 42, 1), (5, 42, 1), (5, 43, 1), (7, 2, 2), (7, 3, 2), (7, 5, 2), (7, 6, 2)])
      CueMoment(atMs: _at(h, m), step: 0, period: p, confidence: 0.82, aroused: h == 7 && m == 3),
  ],
);

final NightSignals _signals = NightSignals(
  made: DateTime(2026, 11, 26, 8, 30),
  sweepUv: 80,
  signals: [FoundSignal(atMs: _at(7, 4), kind: 'lrlr', pairs: 2, stage: 'R', afterCueS: 70)],
);

final _nights = [
  (answered: true, lucid: false),
  (answered: true, lucid: false),
  (answered: false, lucid: false),
  (answered: true, lucid: true),
  (answered: true, lucid: false),
];

LucidResults _results() {
  final s = LucidSealed.draw('5' * 64);
  final p = LucidPlan(frozen: DateTime(2026, 11, 10), scheduleSha256: s.sha);
  return lucidResults(
    plan: p,
    planSha: p.sha,
    sealed: s,
    nights: [
      for (var i = 0; i < 13; i++)
        LucidNight(
          index: i,
          cueMoments: 12,
          arousedMoments: s.arms[i] == NightArm.cue ? 2 : 1,
          signalsInDreamSleep: i == 7 ? 1 : 0,
          practised: i.isEven,
          answers: i == 5 ? null : LucidAnswers(lucid: i == 3 || i == 7 ? 'yes' : 'no', heard: i < 6 ? 'dream' : 'no', recall: 2),
        ),
    ],
  )!;
}

final Map<String, LucidViewModel> states = {
  'off': const LucidViewModel(on: false, due: LucidDue.turnOn),
  'practise_first': const LucidViewModel(on: true, due: LucidDue.practise),
  'evening': LucidViewModel(
    on: true,
    due: LucidDue.practise,
    level: 0.031,
    nights: _nights,
    nextIndex: 5,
    last: LucidLastNight(
      record: _record,
      signals: _signals,
      answers: const LucidAnswers(lucid: 'no', heard: 'dream', recall: 2),
      endMs: _at(8, 5),
    ),
  ),
  'ready': LucidViewModel(
    on: true,
    due: LucidDue.ready,
    level: 0.031,
    practisedAt: DateTime(2026, 11, 26, 23, 14),
    nights: _nights,
    nextIndex: 5,
  ),
  'morning': LucidViewModel(
    on: true,
    due: LucidDue.answer,
    level: 0.031,
    nights: _nights.sublist(0, 4),
    nextIndex: 5,
    last: LucidLastNight(record: _record, searching: true, endMs: _at(8, 5)),
    draft: const LucidDraft(lucid: 'yes'),
  ),
  'results': LucidViewModel(
    on: true,
    due: LucidDue.practise,
    level: 0.031,
    nights: [for (var i = 0; i < 13; i++) (answered: i != 5, lucid: i == 3 || i == 7)],
    nextIndex: 13,
    results: _results(),
    last: LucidLastNight(
      record: LucidNightRecord(
        startMs: _start,
        index: 12,
        cuesFromMs: _start + 270 * 60000,
        phase: 'ended',
        off: 'The sleep model stopped (it failed or was too slow), so no more cues tonight.',
      ),
      endMs: _at(7, 50),
    ),
  ),
};

final Map<String, PracticeViewModel> faces = {
  'practice_loudness': const PracticeViewModel(stage: PracticeStage.loudness, step: 9),
  'practice_words': const PracticeViewModel(stage: PracticeStage.guided, cue: 2, showWords: true),
  'practice_eyes_closed': const PracticeViewModel(stage: PracticeStage.unguided, cue: 7),
  'practice_done': const PracticeViewModel(stage: PracticeStage.done, heardLevel: 0.0317),
};

Future<void> _shot(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _app(Widget child, double scale, GlobalKey key) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: nightTheme(),
      home: RepaintBoundary(key: key, child: child),
    ),
  ),
);

LucidView _view(LucidViewModel m, {ValueChanged<LucidDraft>? onDraft, VoidCallback? onSave}) => LucidView(
  model: m,
  onTurnOn: () {},
  onTurnOff: () {},
  onPractise: () {},
  onDraft: onDraft ?? (_) {},
  onSave: onSave ?? () {},
  onInfo: () {},
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    final suffix = scale == 1.0 ? '' : '_text130';
    for (final e in states.entries) {
      for (final full in [false, true]) {
        testWidgets('lucid ${e.key}${full ? ' (whole column)' : ''} at ${(scale * 100).round()} % text', (tester) async {
          // the Xiaomi 11T: 393 dp wide; the whole column on a tall canvas
          tester.view.physicalSize = Size(1080, full ? 2.75 * 3400 : 2400);
          tester.view.devicePixelRatio = 2.75;
          addTearDown(tester.view.reset);
          final key = GlobalKey();
          await tester.pumpWidget(_app(_view(e.value), scale, key));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          await _shot(tester, key, 'lucid_${e.key}${full ? '_full' : ''}$suffix');
        });
      }
    }
    for (final e in faces.entries) {
      testWidgets('lucid ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          _app(PracticeView(model: e.value, onHeard: () {}, onStop: () {}, onDone: () {}), scale, key),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        await _shot(tester, key, 'lucid_${e.key}$suffix');
      });
    }
  }

  testWidgets('the answers: nothing preselected, Save only once each question has one', (tester) async {
    tester.view.physicalSize = const Size(1080, 2.75 * 3400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    var draft = const LucidDraft();
    var saved = false;
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: _view(
          LucidViewModel(on: true, due: LucidDue.answer, last: LucidLastNight(record: _record), draft: draft),
          onDraft: (d) => draft = d,
          onSave: () => saved = true,
        ),
      ),
    );
    await show();
    expect(find.text('Answer each question'), findsOneWidget);
    await tester.tap(find.text('Yes').first);
    await show();
    expect(find.textContaining('eye signal'), findsOneWidget, reason: 'asked only after a lucid yes');
    await tester.tap(find.text('No').at(1)); // the eye signal: no
    await show();
    await tester.tap(find.text('In a dream'));
    await show();
    await tester.tap(find.text('A dream'));
    await show();
    expect(draft.complete, isTrue);
    await tester.tap(find.text('Save answers'));
    expect(saved, isTrue);
    expect(draft.answers!.toJson(), {'lucid': 'yes', 'heard': 'dream', 'recall': 2, 'signal': 'no'});
  });

  group('what is due, from the files', () {
    late Directory dir;
    late LucidStore store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('lucid_due');
      store = LucidStore(Directory('${dir.path}/lucid'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('never used: turn on; on without a loudness: practise first', () {
      expect(lucidModel(store: store, now: DateTime(2026, 11, 26, 21), nightRunning: false).due, LucidDue.turnOn);
      expect(lucidNightLine('${dir.path}/recordings'), isNull);
      store.setOn(true, DateTime(2026, 11, 26, 21));
      final m = lucidModel(store: store, now: DateTime(2026, 11, 26, 21), nightRunning: false);
      expect((m.due, m.level), (LucidDue.practise, null));
      expect(lucidNightLine('${dir.path}/recordings'), 'On: practise first, it sets the loudness.');
    });

    test('a practice in the last 3 hours makes the night ready', () {
      store.setOn(true, DateTime(2026, 11, 26, 21));
      store.setLevel(0.03, DateTime(2026, 11, 26, 22));
      store.addPractice(
        PracticeRecord(start: DateTime(2026, 11, 26, 22), end: DateTime(2026, 11, 26, 22, 16), cues: 16, completed: true),
      );
      final m = lucidModel(store: store, now: DateTime(2026, 11, 26, 23), nightRunning: false);
      expect(m.due, LucidDue.ready);
      expect(m.practisedAt, DateTime(2026, 11, 26, 22, 16));
      expect(lucidModel(store: store, now: DateTime(2026, 11, 27, 3), nightRunning: false).due, LucidDue.practise);
    });

    test('the morning after a night with cues on: answer; once answered, the evening again', () {
      store.setOn(true, DateTime(2026, 11, 25, 21));
      store.setLevel(0.03, DateTime(2026, 11, 25, 22));
      store.saveNight(LucidNightRecord(startMs: _start, index: 0, cuesFromMs: _start + 270 * 60000));
      final morning = DateTime(2026, 11, 26, 8, 30);
      expect(lucidModel(store: store, now: morning, nightRunning: false).due, LucidDue.answer);
      expect(lucidModel(store: store, now: morning, nightRunning: true, runningStartMs: _start).due, isNot(LucidDue.answer));
      expect(lucidNightLine('${dir.path}/recordings', now: morning), 'Three questions about last night are waiting.');
      store.saveAnswers(_record.stamp, const LucidAnswers(lucid: 'no', heard: 'no', recall: 1), morning);
      final m = lucidModel(store: store, now: morning, nightRunning: false);
      expect(m.due, LucidDue.practise);
      expect(m.nights, [(answered: true, lucid: false)]);
      expect(m.nextIndex, 1);
      expect(lucidModel(store: store, now: DateTime(2026, 11, 28), nightRunning: false).due, LucidDue.practise);
    });
  });
}
