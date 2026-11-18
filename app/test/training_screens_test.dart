// Renders the replay check's and alpha-theta's screens at a phone's size with real fonts, writes PNGs to
// build/screens/training_*.png for a human look (whole pages: the view is as tall as the content needs), and
// fails on any layout overflow, also at 130 % text. The numbers are made up for the pictures; nothing here was
// measured.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/training/check.dart';
import 'package:eeg_tracker/training/control.dart';
import 'package:eeg_tracker/training/reveal.dart';
import 'package:eeg_tracker/ui/alpha_theta_views.dart';
import 'package:eeg_tracker/ui/check_views.dart';
import 'package:eeg_tracker/ui/meditation_view.dart';
import 'package:eeg_tracker/ui/replay_results_screen.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/training_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

MeditationSummary _atReport() => MeditationSummary(
  kind: SessionKind.alphaTheta,
  start: DateTime(2026, 11, 20, 21, 4),
  lengthMin: 15,
  runS: 900,
  complete: true,
  settledS: 410,
  longestSettledS: 60,
  bells: 61,
  restless: {Restless.jaw: 2, Restless.blinks: 3, Restless.movement: 0},
  drifting: 3,
  drowsyS: 240,
  asleepS: 700,
  calm: [0.3, 0.35, 0.42, 0.5, 0.55, 0.61, 0.66, 0.7, 0.72, 0.68, 0.75, 0.8, 0.83, 0.78, 0.7, 0.66, 0.6, 0.58, 0.55, 0.5, 0.5, 0.48, 0.45, 0.47, 0.5, 0.52, 0.5, 0.48, 0.46, 0.5],
  marks: const [(120, 'jaw'), (300, 'blinks'), (520, 'drifting'), (700, 'drifting'), (812, 'jaw')],
  iafHz: 9.75,
  note: '',
  logFile: '',
  at: const {'alphaS': 312.4, 'thetaS': 255.1, 'crossoverS': 41.5, 'asleepS': 122.0, 'countedS': 700.0, 'chimes': 38, 'gongs': 23},
);

Reveal _reveal() {
  final sealed = Sealed.draw('pictures');
  final plan = CheckPlan(kind: SessionKind.meditation, frozen: DateTime(2026, 11, 20, 21), allocationSha256: sealed.sha);
  final records = [
    for (var i = 0; i < 13; i++)
      CheckRecord(
        index: i,
        stem: 's$i',
        start: DateTime(2026, 11, 21 + i, 21),
        arm: sealed.arms[i],
        runS: 600,
        outcome: (sealed.arms[i] == Arm.live ? 0.06 : 0.02) + 0.01 * (i % 3),
        excludedShare: i == 4 ? 0.42 : 0.12,
        asleepS: 0,
        ratings: CheckRatings(
          calm: 3 + i % 2,
          guess: ['live', 'replay', 'unsure'][i % 3],
          confidence: 60,
          control: sealed.arms[i] == Arm.live ? 4 : 3,
          random: 2 + i % 2,
        ),
      ),
  ];
  return reveal(plan: plan, planSha: plan.sha, sealed: sealed, records: records)!;
}

final List<CheckLine> _lines = [
  (
    kind: SessionKind.meditation,
    status: '7 of 24-36 sessions done. Results after 5 more.',
    plan: 'Plan frozen 20 Nov, 21:04',
    fingerprint: '4f2a91c0d3e8b7a6' * 4,
    canReveal: false,
    done: 7,
  ),
  (
    kind: SessionKind.alphaTheta,
    status: 'Live session 3 of 4 before the check begins: it needs your own sessions to replay.',
    plan: null,
    fingerprint: null,
    canReveal: false,
    done: 0,
  ),
];

MeditationView _med(MeditationViewModel m) => MeditationView(
  model: m,
  onMinutes: (_) {},
  onStart: () {},
  onStop: () {},
  onDone: () {},
  onInfo: () {},
  onSettings: () {},
  onAlphaTheta: () {},
);

final Map<String, (Widget, double)> screens = {
  'med_setup_check': (
    _med(meditationModel(stage: Stage.setup, minutes: 10, checkOn: true, checkStatus: 'Check session 7 of 24-36. Results after every 12.')),
    1500,
  ),
  'med_running_check': (
    _med(meditationModel(stage: Stage.running, minutes: 10, chip: Moment.settled, runSeconds: 268, bells: 9, checkOn: true)),
    980,
  ),
  'med_rating': (CheckRatingsView(onDone: (_) {}), 1500),
  'settings': (TrainingSettingsView(on: true, lines: _lines, onToggle: (_) {}, onInfo: () {}, onResults: (_) {}), 1900),
  'settings_off': (TrainingSettingsView(on: false, lines: const [], onToggle: (_) {}, onInfo: () {}, onResults: (_) {}), 1300),
  'results': (ReplayResultsView(kind: SessionKind.meditation, reveal: _reveal(), untilReveal: 11, onInfo: () {}), 3000),
  'results_locked': (ReplayResultsView(kind: SessionKind.alphaTheta, reveal: null, untilReveal: 5, onInfo: () {}), 980),
  'at_first_use': (AtFirstUseView(onAgree: (_, _) {}, onInfo: () {}), 3000),
  'at_setup': (
    AtSetupView(
      model: const AtSetupModel(
        done: 1,
        minutes: 15,
        lengths: [15],
        checkOn: true,
        checkStatus: 'Live session 2 of 4 before the check begins: it needs your own sessions to replay.',
        contact: 'Anna, +7 900 000 00 00',
        grounding: 'Open my eyes, feet on the floor, name five things I can see.',
      ),
      onMinutes: (_) {},
      onCheckIn: () {},
      onResume: () {},
      onDecide: () {},
      onInfo: () {},
      onSettings: () {},
    ),
    1500,
  ),
  'at_setup_later': (
    AtSetupView(
      model: const AtSetupModel(done: 5, minutes: 20, lengths: [20, 25], contact: 'Anna', grounding: 'Feet on the floor.'),
      onMinutes: (_) {},
      onCheckIn: () {},
      onResume: () {},
      onDecide: () {},
      onInfo: () {},
      onSettings: () {},
    ),
    1300,
  ),
  'at_paused': (
    AtSetupView(
      model: const AtSetupModel(
        done: 4,
        minutes: 20,
        lengths: [20, 25],
        pausedWhy: 'Distressing memories came up two sessions in a row.',
        contact: 'Anna',
        grounding: 'Feet on the floor.',
      ),
      onMinutes: (_) {},
      onCheckIn: () {},
      onResume: () {},
      onDecide: () {},
      onInfo: () {},
      onSettings: () {},
    ),
    980,
  ),
  'at_decide': (
    AtSetupView(
      model: const AtSetupModel(done: 10, minutes: 20, lengths: [20, 25], needsDecision: true, contact: 'Anna', grounding: 'x'),
      onMinutes: (_) {},
      onCheckIn: () {},
      onResume: () {},
      onDecide: () {},
      onInfo: () {},
      onSettings: () {},
    ),
    980,
  ),
  'at_checkin': (AtCheckInView(firstSession: false, needReaction: true, onStart: (_, _) {}, onBack: () {}), 2200),
  'at_grounding': (AtGroundingView(ownRoutine: 'Hands on my knees, three slow breaths.', onDone: () {}), 1200),
  'at_after': (AtAfterView(asksGuess: true, onSave: (_, _) {}), 3200),
  'at_alertness': (AtAlertnessView(usualMs: const [298, 310, 305], onDone: (_, _) {}), 1300),
  'at_running_drifting': (
    _med(
      meditationModel(
        stage: Stage.running,
        minutes: 15,
        chip: Moment.drifting,
        runSeconds: 412,
        bells: 23,
        kind: SessionKind.alphaTheta,
      ),
    ),
    980,
  ),
  'at_running_asleep': (
    _med(
      meditationModel(
        stage: Stage.running,
        minutes: 15,
        chip: Moment.drifting,
        runSeconds: 700,
        bells: 31,
        kind: SessionKind.alphaTheta,
        asleepGuard: true,
      ),
    ),
    980,
  ),
  'at_report': (
    _med(
      meditationModel(
        stage: Stage.report,
        minutes: 15,
        report: _atReport(),
        comparison: 'Session 2. Your usual range shows after 4 sessions; a trend needs about 8.',
        kind: SessionKind.alphaTheta,
      ),
    ),
    1900,
  ),
};

void main() {
  setUpAll(loadFonts);

  for (final scale in [1.0, 1.3]) {
    for (final e in screens.entries) {
      testWidgets('training ${e.key} at ${(scale * 100).round()} % text', (tester) async {
        final (widget, heightDp) = e.value;
        tester.view.physicalSize = Size(1210, heightDp * 2.75 * (scale > 1 ? 1.25 : 1));
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
              home: RepaintBoundary(key: key, child: widget),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/screens/training_${e.key}${scale == 1.0 ? '' : '_text130'}.png')
            ..createSync(recursive: true);
          out.writeAsBytesSync(png!.buffer.asUint8List());
        });
        await tester.pumpWidget(const SizedBox()); // ends the pages' timers
      });
    }
  }

  testWidgets('the rating page saves only when every question has an answer', (tester) async {
    CheckRatings? got;
    tester.view.physicalSize = const Size(1210, 2400 * 2.75);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: CheckRatingsView(onDone: (r) => got = r)));
    expect(find.text('Answer each question'), findsOneWidget);
    Future<void> tap(String text, {int at = 0}) async {
      final f = find.text(text).at(at);
      await tester.ensureVisible(f);
      await tester.tap(f);
      await tester.pump();
    }

    await tap('4'); // calm
    await tap('Not sure');
    await tap('3', at: 1); // control
    expect(find.text('Answer each question'), findsOneWidget);
    await tap('2', at: 2); // random
    await tap('Save and see the report');
    expect(got?.toJson(), {'calm': 4, 'guess': 'unsure', 'confidence': 0, 'control': 3, 'random': 2});
  });

  testWidgets('alpha-theta first use: a ticked screening item blocks; consent and a contact continue', (tester) async {
    String? contact;
    tester.view.physicalSize = const Size(1210, 3000 * 2.75);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: AtFirstUseView(onAgree: (c, _) => contact = c, onInfo: () {})),
    );
    await tester.tap(find.text(screeningItemsFirst));
    await tester.pump();
    expect(find.textContaining('not offered here'), findsOneWidget);
    expect(find.text('Not offered'), findsOneWidget);
    await tester.tap(find.text(screeningItemsFirst));
    await tester.pump();
    await tester.tap(find.textContaining('I understand'));
    await tester.enterText(find.byType(TextField).first, 'Anna 123');
    await tester.pump();
    await tester.tap(find.text('Agree and continue'));
    expect(contact, 'Anna 123');
  });
}

const String screeningItemsFirst = 'PTSD, or something traumatic in the last few months';
