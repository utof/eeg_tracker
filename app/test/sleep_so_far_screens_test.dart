// "Sleep so far" on the screens (DECISIONS 640-649): the night screen's section while a night records (and not between
// nights), the DIY board's plain refusal, the page in its states at the owner's phone width (393 dp) with real fonts
// at 100 and 130 % text (build/screens/so_far_*.png for a human look; any overflow fails), and the page looking when
// it opens and stopping when it closes. The nights are made up, not recordings.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/so_far.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/phone_checks.dart' show FixAction;
import 'package:eeg_tracker/ui/sleep_so_far.dart';
import 'package:eeg_tracker/ui/sleep_so_far_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

List<String> _run(String s, int minutes) => List.filled(minutes * 2, s);

/// 23:10 to 03:28: awake, three cycles, a wake-up, a 6-minute hole, and 12 minutes the live model read while scoring
/// waited for it, then 4 not scored.
final SoFarResult _night = SoFarResult(
  night: '2026-11-20',
  start: DateTime(2026, 11, 20, 23, 10),
  stages: [
    ..._run('W', 22), ..._run('N1', 5), ..._run('N2', 25), ..._run('N3', 38), ..._run('N2', 12), ..._run('R', 10),
    ..._run('N2', 20), ..._run('W', 9), ..._run('N2', 15), ..._run('gap', 6), ..._run('N3', 22), ..._run('N2', 18),
    ..._run('R', 18), ..._run('N2', 12), ..._run('N3', 10), ..._run('unscored', 4), ..._run('N2', 8), ..._run('R', 4),
  ],
  liveEpochs: 24,
  seconds: 31,
  looks: 3,
  calls: 24,
);

final Map<String, Widget> _pages = {
  'page': SleepSoFarView(result: _night, onUpdate: () {}, onInfo: () {}),
  'scoring': SleepSoFarView(
    result: _night,
    state: const SoFarState(step: 'Scoring 02:14 to 03:12 (2 of 2)', busy: true),
  ),
  'waiting': SleepSoFarView(
    result: _night,
    state: const SoFarState(waiting: 'the live sleep model runs for the smart alarm'),
    onUpdate: () {},
  ),
  'nothing': SleepSoFarView(result: null, onUpdate: () {}),
  'failed': SleepSoFarView(result: null, state: const SoFarState(failed: 'Bad state: no memory'), onUpdate: () {}),
};

NightViewModel _recording({String? line}) => NightViewModel(
  title: 'Recording',
  sentence: 'All good.',
  tone: Tone.live,
  running: true,
  minutes: 242,
  soFarLine: line,
);

Widget _nightView(NightViewModel m, {VoidCallback? onSoFar}) => NightView(
  model: m,
  onStart: () {},
  onStop: () {},
  onFix: (FixAction _) {},
  onSleepSoFar: onSoFar,
);

/// A fake model run: logits from the input, so the page's look is real end to end except ONNX.
class _Run implements StageRun {
  int calls = 0;

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    calls++;
    final out = Float32List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var k = 0; k < 5; k++) {
        out[e * 5 + k] = x[(e * 3840 + k * 97) * 4 + k % 4];
      }
    }
    return out;
  }

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(loadFonts);

  group('the night screen', () {
    testWidgets('while a night records: the line and See sleep so far under the strip', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: _nightView(_recording(line: soFarLine(_night)), onSoFar: () => opened++),
        ),
      );
      expect(find.text('Sleep so far'), findsOneWidget);
      expect(find.text('At the last look: 3 h 37 min asleep by 03:28.'), findsOneWidget);
      await tester.tap(find.text('See sleep so far'));
      expect(opened, 1);
    });

    testWidgets('before the first look it says what the button does; between nights there is no section', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(theme: nightTheme(), home: _nightView(_recording(line: soFarLine(null)), onSoFar: () {})),
      );
      expect(
        find.text('The sleep chart and totals of the night so far, scored on this phone when you open it.'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: _nightView(
            const NightViewModel(title: 'Ready', sentence: 'Tap Start night.', tone: Tone.calm, running: false),
          ),
        ),
      );
      expect(find.text('Sleep so far'), findsNothing);
      expect(find.text('See sleep so far'), findsNothing);
    });

    testWidgets('the DIY board: a plain refusal, no button', (tester) async {
      final line = diySoFarRefusal(['O1', 'O2', 'Fz', 'Fp1']);
      expect(
        line,
        'No sleep so far for the DIY board: the sleep model reads O1, O2, T3 and T4, and the board records '
        'O1 O2 Fz Fp1 (no T3, T4).',
      );
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _nightView(_recording(line: line))));
      expect(find.text(line), findsOneWidget);
      expect(find.text('See sleep so far'), findsNothing);
    });
  });

  test('the sleep model\'s sites by name: T7 and T8 are T3 and T4', () {
    expect(sleepChannelsMissing(['O1', 'O2', 'T3', 'T4']), isNull);
    expect(sleepChannelsMissing(['o1', 'O2', 'T7', 'T8', 'Cz']), isNull);
    expect(sleepChannelsMissing(['Fp1', 'Fp2', 'O1']), 'O2, T3, T4');
  });

  group('the page', () {
    testWidgets('chart, totals and the honest note, all labelled as so far', (tester) async {
      tester.view.physicalSize = const Size(1081, 2400); // the owner's 11T: 393 dp wide
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _pages['page']));
      expect(find.text('Tonight so far'), findsOneWidget);
      expect(find.text('Scored up to 03:28, 2 minutes behind the recording at that look.'), findsOneWidget);
      expect(find.text('asleep so far'), findsOneWidget);
      expect(find.text('fell asleep'), findsOneWidget);
      expect(find.text('23:32'), findsOneWidget);
      expect(find.textContaining('the report may differ slightly'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Awake in between'), 300);
      for (final w in ['Deep', 'Dream', 'Light']) {
        expect(find.text(w), findsWidgets);
      }
      await tester.scrollUntilVisible(find.textContaining('Scored on this phone in 31 s over 3 looks'), 300);
      expect(find.textContaining('12 min of the chart are the live sleep model\'s own readings'), findsOneWidget);
      expect(find.textContaining('4 min not scored yet'), findsOneWidget);
      expect(find.textContaining('6 min not recorded'), findsOneWidget);
      expect(find.textContaining('Awake once over 5 minutes: 01:22 (9 min).'), findsOneWidget);
    });

    testWidgets('a recording without the sleep model\'s sites: the reason in words, nothing else', (tester) async {
      const why = 'Sleep so far needs O1 O2 T3 T4; this recording (DIY: O1 O2 Fz Cz) has no T3, T4.';
      await tester.pumpWidget(
        MaterialApp(theme: nightTheme(), home: SleepSoFarView(result: null, state: const SoFarState(refused: why))),
      );
      expect(find.text(why), findsOneWidget);
      expect(find.textContaining('Could not score'), findsNothing);
    });

    testWidgets('Update is off while a look runs and after Stop', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _pages['scoring']));
      expect(find.text('Scoring 02:14 to 03:12 (2 of 2).'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Update')).onPressed, isNull);
      await tester.pumpWidget(
        MaterialApp(theme: nightTheme(), home: SleepSoFarView(result: _night, state: const SoFarState(ended: true))),
      );
      expect(find.text('The night has ended. Its report is scored after Stop and replaces this.'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Update')).onPressed, isNull);
    });

    for (final scale in [1.0, 1.3]) {
      for (final e in _pages.entries) {
        testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
          tester.view.physicalSize = Size(1081, scale == 1.0 ? 2400 : 3600); // 393 dp wide, tall enough for a look
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
            final image = await boundary.toImage(pixelRatio: 2.0);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File('build/screens/so_far_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(png!.buffer.asUint8List());
          });
        });
      }
    }

    testWidgets('the night screen section at 130 % text', (tester) async {
      tester.view.physicalSize = const Size(1081, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: nightTheme(),
            home: RepaintBoundary(key: key, child: _nightView(_recording(line: soFarLine(_night)), onSoFar: () {})),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('See sleep so far'), 200);
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/screens/so_far_section_text130.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      });
    });

    testWidgets('opening it looks at the night; a look after it finds nothing new to score', (tester) async {
      late Directory root;
      late SleepSoFar soFar;
      final run = _Run();
      await tester.runAsync(() async {
        root = Directory.systemTemp.createTempSync('so_far_screen');
        final rec = Directory('${root.path}/recordings')..createSync();
        // 20 minutes recorded from 23:00: one batch a second
        final start = DateTime(2026, 11, 19, 23);
        const n = 20 * 60 * 250;
        final f32 = ByteData(n * 20), idx = ByteData(n ~/ 250 * 16);
        for (var i = 0; i < n; i++) {
          for (var c = 0; c < 4; c++) {
            f32.setFloat32(i * 20 + 4 + 4 * c, (i % (97 + c * 13)) * 1e-6, Endian.little);
          }
        }
        for (var k = 0; k < n ~/ 250; k++) {
          idx
            ..setFloat64(k * 16, start.millisecondsSinceEpoch / 1000 + k + 1, Endian.little)
            ..setUint64(k * 16 + 8, k * 250, Endian.little);
        }
        File('${rec.path}/2026-11-19-230000.f32').writeAsBytesSync(f32.buffer.asUint8List());
        File('${rec.path}/2026-11-19-230000.idx').writeAsBytesSync(idx.buffer.asUint8List());
        soFar = SleepSoFar(
          SoFarScorer(
            recordingsDir: rec,
            openRun: (_) async => run,
            plan: (d, s) async => planSoFar(d, s),
            prepare: (l, a, b, t) async => prepareWindow(l, a, b, t),
          ),
          nightStartMs: () => start.millisecondsSinceEpoch,
        );
      });
      addTearDown(() => root.deleteSync(recursive: true));
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SleepSoFarScreen(soFar: soFar)));
      for (var i = 0; i < 50 && soFar.busy; i++) {
        await tester.pump(); // the look reads and writes files synchronously; its awaits are microtasks
      }
      expect(soFar.busy, isFalse);
      await tester.pump();
      expect(soFar.failed, isNull);
      expect(soFar.waiting, isNull);
      expect(run.calls, 3, reason: 'one window, three runs');
      expect(soFar.result!.stages, hasLength(40 - soFarBehind));
      expect(find.text('Scored up to 23:18, 2 minutes behind the recording at that look.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => soFar.update());
      expect(run.calls, 3);
      soFar.dispose();
    });
  });
}
