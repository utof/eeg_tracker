// Renders "Was this you?" in its states on the sleep report, the check-in's result and the Settings page at the
// owner's Xiaomi 11T size (393 dp wide) with real fonts, writes build/screens/wearer_*.png for a human look, and fails
// on any layout overflow (also at 130 % text). Then the controls, and the sleep report's wiring on a fake app folder:
// a far night asks, "Someone else" tags its report and says what it did, Undo takes it back. Made-up nights only.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/morning/store.dart';
import 'package:eeg_tracker/morning/controller.dart' show MorningStage;
import 'package:eeg_tracker/recorder/chunk_writer.dart' show fileStem;
import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/report.dart';
import 'package:eeg_tracker/sleep/scorer.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/morning_screen.dart' show outcomeFor;
import 'package:eeg_tracker/ui/morning_view.dart';
import 'package:eeg_tracker/ui/sleep_report_screen.dart';
import 'package:eeg_tracker/ui/sleep_report_view.dart';
import 'package:eeg_tracker/ui/sleep_scoring.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/wearer_view.dart';
import 'package:eeg_tracker/wearer/check.dart';
import 'package:eeg_tracker/wearer/wearer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

List<String> _run(String s, int minutes) => List.filled(minutes * 2, s);

Map<String, dynamic> _night(String nightOf, {double iaf = 9.9, double alpha = 30}) {
  final start = DateTime.parse('${nightOf}T23:30:00');
  final r = jsonDecode(jsonEncode(buildReport(
    nightOf: nightOf,
    built: start.add(const Duration(hours: 8)),
    scoringSeconds: 120,
    start: start,
    lengthSeconds: 7.5 * 3600,
    inputs: {'${fileStem(start)}.f32': 1000},
    model: phoneModelId,
    stages: [..._run('W', 14), ..._run('N2', 60), ..._run('N3', 50), ..._run('R', 30), ..._run('N2', 200), ..._run('R', 50), ..._run('W', 46)],
    confidence: List.filled(900, 0.74),
  ))) as Map<String, dynamic>;
  r['wearer_signal'] = {
    'version': 1, 'from_s': 120, 'epochs': 12, 'clean_s': 340.0, 'iaf_hz': iaf, 'alpha_uv2': alpha, 'slope': -1.5,
    'why': null,
  };
  return r;
}

final _report = SleepReport(_night('2026-11-17'));

WearerResult _result(WearerVerdict v, {String? answer, WearerSignal? signal}) => WearerResult(
  on: true,
  verdicts: {'${v.kind}:${v.id}': v},
  answers: {'${v.kind}:${v.id}': ?answer},
  signals: {'${v.kind}:${v.id}': ?signal},
);

const _far = WearerVerdict(
  id: 'x',
  kind: kindNight,
  state: WearerState.notLikeYou,
  distance: 4.2,
  z: {'iaf': -6.1, 'alpha': 3.4, 'slope': 0.4},
  usual: {'iaf': 9.92, 'alpha': 1.48, 'slope': -1.52},
  biggest: 'iaf',
  profileN: 14,
);
const WearerSignal _farSignal = {'iaf': 8.24, 'alpha': 1.95, 'slope': -1.46};

WearerLine _line(String kind, WearerVerdict v, {String? answer}) => wearerLine(
  _result(WearerVerdict(id: 'x', kind: kind, state: v.state, why: v.why, have: v.have, days: v.days, distance: v.distance, z: v.z, usual: v.usual, biggest: v.biggest), answer: answer, signal: _farSignal),
  kind,
  'x',
)!;

final Map<String, WearerLine> _lines = {
  'question': _line(kindNight, _far),
  'asked_someone_else': _line(kindNight, _far, answer: answerSomeoneElse),
  'asked_me': _line(kindNight, _far, answer: answerMe),
  'learning': _line(kindNight, const WearerVerdict(id: 'x', kind: kindNight, state: WearerState.learning, have: 3, days: 3)),
  'like_you': _line(kindNight, const WearerVerdict(id: 'x', kind: kindNight, state: WearerState.likeYou, distance: 0.9)),
  'unchecked': _line(kindNight, const WearerVerdict(id: 'x', kind: kindNight, state: WearerState.unchecked, why: whyLightsOff)),
  'told_someone_else': _line(
    kindNight,
    const WearerVerdict(id: 'x', kind: kindNight, state: WearerState.likeYou, distance: 1.2),
    answer: answerSomeoneElse,
  ),
};

Widget _sleep(WearerLine line) => SleepReportView(
  nightOf: '2026-11-17',
  report: _report,
  onInfo: () {},
  wearer: line,
  onWearerAnswer: (_) {},
  onWearerInfo: () {},
);

MorningRecord _checkIn() => MorningRecord.fromJson({
  'version': 'morning-v1',
  'start': '2026-11-20T09:12:05+03:00',
  'channels': {
    'O1': {'clean_s_ec': 112.0},
    'O2': {'clean_s_ec': 110.0},
  },
  'back': {'iaf_hz': 8.24, 'alpha_ec_uv2': 89.0, 'aperiodic_slope_ec': -1.46, 'ec_rise': 2.4, 'clean_share': 0.95},
  'ratings': {'kss': 3, 'mood': 4, 'tension': 2},
})!;

Widget _morning(WearerLine line) {
  final done = _checkIn();
  return MorningView(
    model: MorningViewModel(
      stage: MorningStage.result,
      outcome: outcomeFor(done, (nights: const [], mornings: [done], sessions: const [])),
      wearer: line,
    ),
    onDone: () {},
    onTrends: () {},
    onInfo: () {},
    onWearerAnswer: (_) {},
    onWearerInfo: () {},
  );
}

Widget _settings(bool on) => SettingsView(
  model: SettingsViewModel(
    wearerOn: on,
    wearerStatus: on ? 'On. Check-ins: learning, 3 of 10; nights: checked.' : wearerStatus(const WearerResult(on: false)),
  ),
  onToggle: (_) {},
  onCalibrate: () {},
  onInfo: () {},
  onWearerSwitch: (_) {},
  onWearerInfo: () {},
);

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 873}) async {
  tester.view.physicalSize = Size(1080, height * 1080 / 393); // the owner's Xiaomi 11T: 393 x 873 dp
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: w)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: height > 873 ? 1.6 : 1080 / 393);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  test('the states are the ones named', () {
    expect(_lines['question']!.question, isTrue);
    expect([for (final l in _lines.values) wearerLeads(l)], [true, true, true, false, false, false, false]);
    expect(_lines['question']!.detail, 'Its alpha rhythm was slower than yours usually is: 8.2 Hz, usually about 9.9.');
  });

  for (final scale in [1.0, 1.3]) {
    final suffix = scale == 1.0 ? '' : '_text130';
    for (final e in _lines.entries) {
      testWidgets('sleep report: ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        await _shoot(tester, _sleep(e.value), 'wearer_sleep_${e.key}$suffix', scale: scale);
        await _shoot(tester, _sleep(e.value), 'wearer_sleep_${e.key}${suffix}_whole', scale: scale, height: 2600);
      });
    }
    for (final k in ['question', 'asked_someone_else', 'learning', 'told_someone_else']) {
      testWidgets('check-in result: $k at ${(scale * 100).round()} % text', (tester) async {
        final l = wearerLine(
          _result(WearerVerdict(id: 'x', kind: kindCheckIn, state: _lines[k]!.question || _lines[k]!.asked
              ? WearerState.notLikeYou : (k == 'learning' ? WearerState.learning : WearerState.likeYou),
              have: 3, days: 2, z: _far.z, usual: _far.usual, biggest: 'iaf', distance: 4.2),
              answer: k.contains('someone_else') ? answerSomeoneElse : null, signal: _farSignal),
          kindCheckIn,
          'x',
        )!;
        await _shoot(tester, _morning(l), 'wearer_morning_$k$suffix', scale: scale);
        await _shoot(tester, _morning(l), 'wearer_morning_$k${suffix}_whole', scale: scale, height: 1800);
      });
    }
    for (final on in [true, false]) {
      testWidgets('settings: ${on ? 'on' : 'off'} at ${(scale * 100).round()} % text', (tester) async {
        await _shoot(tester, _settings(on), 'wearer_settings_${on ? 'on' : 'off'}${suffix}_whole', scale: scale, height: 2200);
      });
    }
  }

  group('the controls', () {
    Future<void> pump(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: Scaffold(body: ListView(children: [w]))));
    }

    testWidgets('the question answers me or someone else; an answer can be taken back', (tester) async {
      final said = <String?>[];
      await pump(tester, WearerQuestion(line: _lines['question']!, onAnswer: said.add));
      await tester.tap(find.text('Yes, it was me'));
      await tester.tap(find.text('Someone else'));
      expect(said, [answerMe, answerSomeoneElse]);
      await pump(tester, WearerQuestion(line: _lines['asked_someone_else']!, onAnswer: said.add));
      expect(find.text('Yes, it was me'), findsNothing);
      await tester.tap(find.text('Undo'));
      expect(said.last, isNull);
    });

    testWidgets('the remark offers "Someone else wore it"; the switch says off', (tester) async {
      final said = <String?>[];
      await pump(tester, WearerRemark(line: _lines['like_you']!, onAnswer: said.add));
      await tester.tap(find.text('Someone else wore it'));
      expect(said, [answerSomeoneElse]);
      bool? on;
      await pump(tester, WearerSettings(on: true, status: 'On.', onSwitch: (v) => on = v));
      await tester.tap(find.byType(Switch));
      expect(on, isFalse);
    });
  });

  group('the sleep report on a fake app folder', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('wearer_screens'));
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('a far night asks; "Someone else" tags it and says so; Undo takes it back', (tester) async {
      final rec = Directory('${tmp.path}/files/recordings')..createSync(recursive: true);
      final store = NightReportStore(nightsDirFor(rec.path));
      for (var d = 1; d <= 10; d++) {
        store.write(_night('2026-11-${d.toString().padLeft(2, '0')}', iaf: 9.85 + 0.05 * (d % 3)));
      }
      store.write(_night('2026-11-11', iaf: 8.2, alpha: 90));
      final scoring = SleepScoring(SleepScorer(recordingsDir: rec, store: store, openRun: (_) => throw UnimplementedError()));
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 393;
      addTearDown(tester.view.reset);
      // the check is worked out in a background isolate (DECISIONS 620-629): real time passes until it shows
      Future<void> until(Finder f) async {
        for (var i = 0; i < 200 && f.evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
      }

      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SleepReportScreen(scoring: scoring, nightOf: '2026-11-11')));
      await until(find.text("This doesn't look like your usual brain signal. Was it you?"));
      expect(find.text("This doesn't look like your usual brain signal. Was it you?"), findsOneWidget);
      await tester.tap(find.text('Someone else'));
      await tester.pump();
      expect(store.read('2026-11-11')!.wearerAnswer, answerSomeoneElse);
      await until(find.textContaining('this night is left out of your trends'));
      expect(find.textContaining('this night is left out of your trends'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(store.read('2026-11-11')!.wearerAnswer, isNull);
      await until(find.text("This doesn't look like your usual brain signal. Was it you?"));
      expect(find.text("This doesn't look like your usual brain signal. Was it you?"), findsOneWidget);
      final events = File('${wearerDirFor(rec.path).path}/events.jsonl').readAsLinesSync();
      expect(events, hasLength(2));
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: SleepReportScreen(scoring: scoring, nightOf: '2026-11-05')));
      await until(find.text('Learning what your brain looks like: 4 of 10 nights.'));
      await tester.scrollUntilVisible(find.text('Someone else wore it'), 300);
      expect(find.text('Learning what your brain looks like: 4 of 10 nights.'), findsOneWidget);
    });
  });
}
