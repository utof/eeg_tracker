// Renders sound for states in its states at a phone's size with real fonts, writes PNGs to build/screens/states_*.png
// for a human look, and fails on any layout overflow (also at 130 % text). The sessions below are made up for the
// pictures; nothing here was measured. Also: the result's plain sentences, and the controls reaching their callbacks.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/readout.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/states/timers.dart';
import 'package:eeg_tracker/ui/dream_view.dart' show faceGround;
import 'package:eeg_tracker/ui/sound_score.dart';
import 'package:eeg_tracker/ui/states_view.dart';
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
  'night_running': StatesViewModel(stage: SoundStage.setup, plan: SoundPlan.of(SoundState.asleep, minutes: 45), nightRunning: true),
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

StatesView view(
  StatesViewModel m, {
  ValueChanged<SoundState>? onState,
  ValueChanged<Beat>? onBeat,
  ValueChanged<int>? onRate,
  VoidCallback? onStart,
  VoidCallback? onSkip,
  VoidCallback? onListen,
  ValueChanged<bool>? onScreen,
}) => StatesView(
  model: m,
  onState: onState ?? (_) {},
  onBed: (_) {},
  onBeat: onBeat ?? (_) {},
  onMinutes: (_) {},
  onHeadband: (_) {},
  onThenNight: (_) {},
  onScreen: onScreen,
  onListen: onListen ?? () {},
  onStart: onStart ?? () {},
  onStop: () {},
  onSkip: onSkip ?? () {},
  onRate: onRate ?? (_) {},
  onInfo: () {},
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
