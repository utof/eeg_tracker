// Renders sound for states in its states at a phone's size with real fonts, writes PNGs to build/screens/states_*.png
// for a human look, and fails on any layout overflow (also at 130 % text). The sessions below are made up for the
// pictures; nothing here was measured. Also: the result's plain sentences, and the controls reaching their callbacks.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/readout.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/states/timers.dart';
import 'package:eeg_tracker/states/trial.dart';
import 'package:eeg_tracker/states/trial_store.dart';
import 'package:eeg_tracker/states/weeks.dart';
import 'package:eeg_tracker/trends/days.dart' show addDays, dayNoon;
import 'package:eeg_tracker/ui/dream_view.dart' show faceGround;
import 'package:eeg_tracker/ui/parts.dart' show SectionHeading;
import 'package:eeg_tracker/ui/sound_score.dart';
import 'package:eeg_tracker/ui/states_view.dart';
import 'package:eeg_tracker/ui/states_weeks_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

SoundSession made(
  SoundPlan plan, {
  String headband = HeadbandUse.used,
  String end = SoundEnd.time,
  ReadSummary? summary = const ReadSummary(0, 512, 1.18, 0.94, 2.3),
  Map<String, Object?> drift = const {},
  int? rating,
  String? night,
  DateTime? start,
}) => SoundSession(
  start: start ?? DateTime(2026, 11, 18, 22, 41),
  plan: plan,
  headband: headband,
  soundStartS: headband == HeadbandUse.used ? 64 : 0,
  baselineS: headband == HeadbandUse.used ? 60 : 0,
  endS: (headband == HeadbandUse.used ? 64 : 0) + plan.minutes * 60.0,
  end: end,
  summary: headband == HeadbandUse.used ? summary : null,
  drift: drift,
  night: night,
  rating: rating,
);

final _relax = SoundPlan.of(SoundState.relax, beat: Beat.isochronic);
final _asleep = SoundPlan.of(SoundState.asleep, beat: Beat.pulsed);
final _asleepSession = SoundSession(
  start: DateTime(2026, 11, 18, 23, 5),
  plan: _asleep,
  headband: HeadbandUse.used,
  soundStartS: 66,
  baselineS: 60,
  fadeFromS: 1021,
  offAtS: 1171,
  endS: 1171,
  end: SoundEnd.asleep,
  summary: const ReadSummary(0, 702, 0.62, 1.41, 1.8),
  drift: const {'asleepAtS': 1020, 'epochs': 'bbaaaddddss'},
  night: 'started',
);
final _earlier = [
  made(SoundPlan.of(SoundState.focus), headband: HeadbandUse.soundOnly, rating: 3, start: DateTime(2026, 11, 18, 10, 2)),
  made(SoundPlan.of(SoundState.pause, beat: Beat.binaural), rating: 4, start: DateTime(2026, 11, 17, 16, 30)),
];
const _contact = {'O1': 4.2e5, 'O2': 1.6e6, 'T3': 8.1e5, 'T4': null};

final Map<String, StatesViewModel> states = {
  'first': StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.asleep)),
  'beat_chosen': StatesViewModel(stage: SoundStage.setup, plan: _asleep, listening: true, earlier: _earlier),
  'binaural_sound_only': StatesViewModel(
    stage: SoundStage.setup,
    plan: SoundPlan.of(SoundState.wake, beat: Beat.binaural),
    useHeadband: false,
  ),
  'night_running': StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.asleep, minutes: 45), recordingRuns: true),
  'ended_relax': StatesViewModel(stage: SoundStage.done, plan: _relax, last: made(_relax), justEnded: true, earlier: _earlier),
  'ended_asleep': StatesViewModel(stage: SoundStage.done, plan: _asleep, last: _asleepSession, justEnded: true),
  'later_rated': StatesViewModel(
    stage: SoundStage.setup,
    plan: SoundPlan.of(SoundState.relax),
    last: made(SoundPlan.of(SoundState.relax), headband: HeadbandUse.soundOnly, rating: 4),
    earlier: _earlier,
  ),
  'failed': StatesViewModel(stage: SoundStage.failed, plan: _relax, message: 'The sound did not start (no audio device).'),
  'face_quiet': StatesViewModel(stage: SoundStage.quiet, plan: _relax, headbandUse: HeadbandUse.used, quietS: 23, contact: _contact),
  'face_relax': StatesViewModel(
    stage: SoundStage.playing,
    plan: _relax,
    headbandUse: HeadbandUse.used,
    secondsLeft: 414,
    rateNow: 10,
    hasBaseline: true,
    live: const ReadSummary(0, 27, 1.22, 0.97, 2.1),
  ),
  'face_asleep': StatesViewModel(
    stage: SoundStage.playing,
    plan: _asleep,
    headbandUse: HeadbandUse.used,
    secondsLeft: 1420,
    rateNow: 6.2,
    hasBaseline: true,
    driftState: DriftState.drowsy,
    live: const ReadSummary(0, 25, 0.71, 1.3, 1.6),
  ),
  'face_fading': StatesViewModel(
    stage: SoundStage.fading,
    plan: _asleep,
    headbandUse: HeadbandUse.used,
    secondsLeft: 131,
    rateNow: 4.1,
    hasBaseline: true,
    driftState: DriftState.asleep,
    stopWhy: StopWhy.asleep,
  ),
  'face_can_lock': StatesViewModel(
    stage: SoundStage.playing,
    plan: _asleep,
    headbandUse: HeadbandUse.nightRecording,
    secondsLeft: 2500,
    screenNote: 'You can lock the phone. The sound goes on.',
  ),
  'face_sound_only': StatesViewModel(
    stage: SoundStage.playing,
    plan: SoundPlan.of(SoundState.focus),
    headbandUse: HeadbandUse.notFound,
    message: 'Headband not found, so the sound plays by its timer alone.',
    secondsLeft: 1490,
  ),
  'face_no_signal': StatesViewModel(
    stage: SoundStage.playing,
    plan: _relax,
    headbandUse: HeadbandUse.used,
    secondsLeft: 300,
    rateNow: 10,
    hasBaseline: true,
    noData: true,
  ),
};

// ---- over weeks (made up for the pictures; nothing measured) ----

/// 24 bedtimes of Fall asleep: pink noise alone on most, pulsed on every fourth, two without the headband.
final List<SoundSession> _weeks = [
  for (var i = 0; i < 24; i++)
    SoundSession(
      start: DateTime(2026, 10, 20, 23, 10).add(Duration(days: i)),
      plan: SoundPlan.of(SoundState.asleep, beat: i % 4 == 1 ? Beat.pulsed : Beat.none),
      headband: i == 7 || i == 15 ? HeadbandUse.soundOnly : HeadbandUse.used,
      soundStartS: 64,
      baselineS: 60,
      endS: 1800,
      end: i == 7 || i == 15 ? SoundEnd.time : SoundEnd.asleep,
      drift: i == 7 || i == 15 ? const {} : {'baselineS': 70, 'onsetS': (9 + i * 7 % 13) * 60},
    ),
];
final _ledger = compareSounds(SoundState.asleep, _weeks);

final Directory _testDir = Directory.systemTemp.createTempSync('states-screens');
final TrialStore _tests = TrialStore(trialsDirFor(_testDir));
final TrialState _made = _tests.create(
  state: SoundState.asleep,
  a: const SoundPick(Bed.pink, Beat.pulsed),
  b: const SoundPick(Bed.pink, Beat.none),
  minutes: 30,
  weeks: 4,
  now: DateTime(2026, 11, 19, 9),
  random: math.Random(5),
);
TrialState _testOn(String day, int hour) => _tests.load(_made.plan.id, dayNoon(day).add(Duration(hours: hour - 12)))!;
final TrialState _running = _testOn('2026-11-28', 21);
final TrialState _done = _testOn('2026-12-19', 9);

/// Every night of the test played as drawn, three of them without the headband.
final TrialResults _answer = () {
  final order = _done.orderForResults()!;
  return trialResults(_done, [
    for (var i = 0; i < 28; i++)
      SoundSession(
        start: dayNoon(addDays(_done.plan.start, i)).add(const Duration(hours: 11)),
        plan: _done.plan.planFor(order[i]),
        headband: i % 9 == 4 ? HeadbandUse.soundOnly : HeadbandUse.used,
        soundStartS: 64,
        baselineS: 60,
        endS: 1800,
        end: SoundEnd.asleep,
        drift: i % 9 == 4 ? const {} : {'baselineS': 70, 'onsetS': ((order[i] ? 13 : 17) + i * 5 % 7) * 60},
        trial: TrialTag(_done.plan.id, addDays(_done.plan.start, i), order[i] ? 'a' : 'b'),
      ),
  ]);
}();

/// The page scrolled to its anchor text for the picture.
final Map<String, (StatesViewModel, Finder)> weeksStates = {
  'weeks_ledger': (
    StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.asleep), comparison: _ledger),
    find.text('What works for you'),
  ),
  'weeks_empty': (
    StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.relax), comparison: compareSounds(SoundState.relax, _weeks)),
    find.text('What works for you'),
  ),
  'test_locked': (
    StatesViewModel(
      stage: SoundStage.setup,
      plan: _running.plan.planFor(_running.todayIsA!),
      comparison: _ledger,
      test: _running,
      soundLocked: true,
    ),
    find.widgetWithText(SectionHeading, 'Sound'),
  ),
  'test_running': (
    StatesViewModel(stage: SoundStage.setup, plan: _running.plan.planFor(_running.todayIsA!), comparison: _ledger, test: _running, soundLocked: true),
    find.text('A fair test'),
  ),
  'test_answer': (
    StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.asleep), comparison: _ledger, test: _done, testResults: _answer),
    find.text('A fair test'),
  ),
};

Widget _setup({ValueChanged<FairTestChoice>? onStart}) => FairTestSetup(
  state: SoundState.asleep,
  first: const SoundPick(Bed.pink, Beat.none),
  minutes: 30,
  now: DateTime(2026, 11, 19, 9),
  onStart: onStart ?? (_) {},
);

Future<void> _shoot(WidgetTester tester, GlobalKey key, String name, double scale) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/states_$name${scale == 1.0 ? '' : '_text130'}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

StatesView view(
  StatesViewModel m, {
  ValueChanged<SoundState>? onState,
  ValueChanged<Bed>? onBed,
  ValueChanged<Beat>? onBeat,
  ValueChanged<int>? onMinutes,
  VoidCallback? onPlanTest,
  VoidCallback? onStopTest,
  ValueChanged<int>? onRate,
  VoidCallback? onStart,
  VoidCallback? onSkip,
  VoidCallback? onListen,
  ValueChanged<bool>? onScreen,
}) => StatesView(
  model: m,
  onState: onState ?? (_) {},
  onBed: onBed ?? (_) {},
  onBeat: onBeat ?? (_) {},
  onMinutes: onMinutes ?? (_) {},
  onHeadband: (_) {},
  onThenNight: (_) {},
  onScreen: onScreen,
  onListen: onListen ?? () {},
  onStart: onStart ?? () {},
  onStop: () {},
  onSkip: onSkip ?? () {},
  onRate: onRate ?? (_) {},
  onInfo: () {},
  onPlanTest: onPlanTest,
  onStopTest: onStopTest,
);

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in states.entries) {
      testWidgets('sound for states ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695); // about a Xiaomi 11T: 440 x 980 dp
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(key: key, child: view(e.value)),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2.75);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/screens/states_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());
        });
      });
    }
  }

  tearDownAll(() => _testDir.deleteSync(recursive: true));

  for (final scale in [1.0, 1.3]) {
    for (final e in weeksStates.entries) {
      testWidgets('sound for states ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        tester.view.physicalSize = const Size(1210, 2695);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nightTheme(),
              home: RepaintBoundary(key: key, child: view(e.value.$1, onPlanTest: () {}, onStopTest: () {})),
            ),
          ),
        );
        await tester.scrollUntilVisible(e.value.$2, 300);
        await tester.ensureVisible(e.value.$2);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _shoot(tester, key, e.key, scale);
      });
    }
    testWidgets('sound for states test_setup at ${(scale * 100).round()} % text', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: MaterialApp(debugShowCheckedModeBanner: false, theme: nightTheme(), home: RepaintBoundary(key: key, child: _setup())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await _shoot(tester, key, 'test_setup', scale);
    });
  }

  group('over weeks', () {
    testWidgets('the ledger: a row per sound, the median once 14 have a number, the count before; seen together', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(weeksStates['weeks_ledger']!.$1)));
      await tester.scrollUntilVisible(find.text('6 sessions with a number: not enough yet'), 300);
      await tester.ensureVisible(find.text('6 sessions with a number: not enough yet'));
      await tester.pumpAndSettle();
      expect(find.text('Pink noise, no beat'), findsWidgets);
      expect(find.text(rowValue(_ledger.measure, _ledger.rows.first)), findsOneWidget);
      expect(_ledger.rows.first.enough, isTrue);
      expect(find.text('6 of 14'), findsOneWidget);
      expect(find.text('6 sessions with a number: not enough yet'), findsOneWidget);
      expect(find.bySemanticsLabel('6 of 14 sessions with a number'), findsOneWidget);
      expect(find.textContaining('Seen together, not tested'), findsOneWidget);
      expect(find.text('Plan a fair test'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets("a fair test's day: the sound and the length are drawn, so their chips do nothing", (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      Bed? bed;
      Beat? beat;
      int? minutes;
      var stopped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: view(
            weeksStates['test_locked']!.$1,
            onBed: (v) => bed = v,
            onBeat: (v) => beat = v,
            onMinutes: (v) => minutes = v,
            onStopTest: () => stopped = true,
          ),
        ),
      );
      const drawn = 'Drawn for day 9 of your fair test. The sound and the length stay as they are today.';
      await tester.scrollUntilVisible(find.text(drawn), 200);
      expect(find.text(drawn), findsOneWidget);
      await tester.ensureVisible(find.text('Ocean'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ocean'));
      await tester.scrollUntilVisible(find.text('Isochronic tones'), 200);
      await tester.ensureVisible(find.text('Isochronic tones'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Isochronic tones'));
      await tester.scrollUntilVisible(find.text('15 min'), 200);
      await tester.ensureVisible(find.text('15 min'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15 min'));
      expect((bed, beat, minutes), (null, null, null));
      await tester.scrollUntilVisible(find.text('Stop this test'), 300);
      await tester.ensureVisible(find.text('Stop this test'));
      await tester.pumpAndSettle();
      expect(find.text('Day 9 of 28'), findsOneWidget);
      expect(find.textContaining("Today's sound, drawn for you: "), findsOneWidget);
      await tester.tap(find.text('Stop this test'));
      expect(stopped, isTrue);
    });

    testWidgets('the answer: the tested sentence, its log rows, and Plan another test', (tester) async {
      var planned = false;
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(weeksStates['test_answer']!.$1, onPlanTest: () => planned = true)));
      await tester.scrollUntilVisible(find.text('Plan another test'), 300);
      await tester.ensureVisible(find.text('Plan another test'));
      await tester.pumpAndSettle();
      expect(find.text(trialSentence(_answer)), findsOneWidget);
      expect(find.text('Tested'), findsOneWidget);
      expect(find.text('${_answer.withNumber} of 28'), findsOneWidget);
      expect(find.text('Plan and order unchanged'), findsOneWidget);
      await tester.tap(find.text('Plan another test'));
      expect(planned, isTrue);
    });

    testWidgets('the setup: two different sounds, then Start tomorrow hands back the choice', (tester) async {
      tester.view.physicalSize = const Size(1210, 2695);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      FairTestChoice? got;
      await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _setup(onStart: (c) => got = c)));
      expect(find.text('Fair test: Fall asleep'), findsOneWidget);
      expect(find.text('Pink noise, pulsed noise 10 to 3 Hz'), findsOneWidget, reason: 'the second sound offered: the same bed with a pulse');
      await tester.tap(find.text('Start tomorrow'));
      expect(got, (a: const SoundPick(Bed.pink, Beat.none), b: const SoundPick(Bed.pink, Beat.pulsed), minutes: 30, weeks: 4));
      // the second sound made the same as the first: no start
      await tester.scrollUntilVisible(find.text('No beat').last, 200);
      await tester.ensureVisible(find.text('No beat').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('No beat').last);
      await tester.pump();
      expect(find.text('Choose two different sounds'), findsOneWidget);
      got = null;
      await tester.tap(find.text('Choose two different sounds'));
      expect(got, isNull);
    });

    test('the lanes share one scale per state', () {
      final m = stateMeasures[SoundState.asleep]!;
      expect((lanePosition(m, 0), lanePosition(m, 22.5), lanePosition(m, 60)), (0.0, 0.5, 1.0));
      final r = stateMeasures[SoundState.relax]!;
      expect((lanePosition(r, 0.5), lanePosition(r, 1), lanePosition(r, 2)), (0.0, 0.5, 1.0));
      expect(lanePosition(stateMeasures[SoundState.focus]!, 3), 0.5);
      expect(otherSound(SoundState.relax, const SoundPick(Bed.none, Beat.binaural)), const SoundPick(Bed.ocean, Beat.none));
    });
  });

  group('result sentences', () {
    test('a measured session: alpha and slow waves against the quiet minute, the expectation, the echo named honestly', () {
      final lines = resultLines(made(_relax));
      expect(lines[0], 'Against your quiet minute: alpha 18 % higher, slow waves 6 % lower (back of the head, 9 min of clean signal).');
      expect(lines[1], presets[SoundState.relax]!.expect);
      expect(lines[2], contains('Echo at the beat\'s rate: 2.3 times'));
      expect(lines[2], contains('not a sign'));
      expect(lines[2], contains('earbuds'));
      expect(lines[2], contains('left out'));
    });

    test('no beat: no echo line; small changes read as "about the same"', () {
      final lines = resultLines(made(SoundPlan.of(SoundState.relax), summary: const ReadSummary(0, 300, 1.03, 0.97, null)));
      expect(lines[0], startsWith('Against your quiet minute: alpha about the same, slow waves about the same'));
      expect(lines.any((l) => l.contains('Echo')), isFalse);
    });

    test('nothing measured is said plainly; fall asleep says when, and that the night started', () {
      expect(resultLines(made(_relax, headband: HeadbandUse.soundOnly)).first, 'Sound only: nothing was measured.');
      expect(resultLines(made(_relax, headband: HeadbandUse.notFound)).first, contains('not found'));
      expect(resultLines(made(_relax, summary: null)).first, contains('Too little clean signal'));
      final asleep = resultLines(_asleepSession);
      expect(asleep, contains('Probably asleep 17 min after lights off; the sound faded out from then.'));
      expect(asleep, contains('The night recording started.'));
      expect(echoLine(1.1), 'No clear echo at the beat\'s rate.');
      expect(change('alpha', double.nan), 'alpha not measured');
    });

    test('the score: quiet minute, fades, and the 45-minute cap for sleep', () {
      final m = ScoreModel(plan: SoundPlan.of(SoundState.asleep, minutes: 45), quietS: 60);
      expect(m.totalS, 45 * 60);
      expect(m.level(30), 0, reason: 'the quiet minute is silent');
      expect(m.level(60 + 22.5), closeTo(0.5, 1e-9), reason: 'half way through the 45 s fade in');
      expect(m.level(45 * 60 - 75), closeTo(0.5, 1e-9), reason: 'half way through the 150 s fade out');
      expect(rateHeight(2), 0);
      expect(rateHeight(20), 1);
    });
  });

  testWidgets('the controls reach their callbacks; the face is black with no filled button', (tester) async {
    tester.view.physicalSize = const Size(1210, 2695);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    SoundState? picked;
    Beat? beat;
    var started = false, listened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: view(
          states['first']!,
          onState: (v) => picked = v,
          onBeat: (v) => beat = v,
          onStart: () => started = true,
          onListen: () => listened = true,
        ),
      ),
    );
    await tester.tap(find.text('Relax'));
    await tester.scrollUntilVisible(find.text('Pulsed noise'), 200);
    await tester.tap(find.text('Pulsed noise'));
    await tester.scrollUntilVisible(find.byTooltip('Play Listen'), 200);
    await tester.ensureVisible(find.byTooltip('Play Listen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play Listen'));
    await tester.tap(find.text('Start'));
    expect((picked, beat, started, listened), (SoundState.relax, Beat.pulsed, true, true));

    int? rating;
    await tester.pumpWidget(const SizedBox()); // a fresh list, scrolled to the top
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(states['ended_relax']!, onRate: (v) => rating = v)));
    await tester.scrollUntilVisible(find.text('Did it help you relax?'), 200);
    await tester.ensureVisible(find.text('Did it help you relax?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4').last);
    expect(rating, 4);

    var skipped = false;
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(states['face_quiet']!, onSkip: () => skipped = true)));
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, faceGround);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.text('Start the sound now'));
    expect(skipped, isTrue);

    // the phone can be locked: said on the face; "Screen" on the setup page reaches its callback
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(states['face_can_lock']!)));
    expect(find.text('You can lock the phone. The sound goes on.'), findsOneWidget);
    bool? staysOn;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(states['first']!, onScreen: (v) => staysOn = v)));
    await tester.scrollUntilVisible(find.text('Stays on'), 200);
    await tester.ensureVisible(find.text('Stays on'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Lock the phone or let the screen turn off'), findsOneWidget);
    await tester.tap(find.text('Stays on'));
    expect(staysOn, isTrue);
  });
}
