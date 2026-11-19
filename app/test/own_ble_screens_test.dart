// Renders the "Headband connection" page in its states at a phone's size with real fonts, writes
// build/screens/own_ble_*.png for a human look, and fails on any layout overflow (also at 130 % text). The words
// of each state are checked without a phone (describeOwnBle).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:eeg_tracker/headband/own/controller.dart' show OwnStage;
import 'package:eeg_tracker/ui/meditation_view.dart' show MarkShape;
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/own_ble_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

const _lines = <(bool?, String)>[
  (true, 'The signal arrives at 250 samples a second.'),
  (true, 'Packets have the expected size (108 bytes).'),
  (true, 'The headband numbers its samples as expected.'),
  (null, 'Some samples were lost on the way (not a failure; they are counted).'),
  (true, 'Stop works.'),
  (true, 'The contact check works.'),
  (true, 'The signal starts again after a contact check, without a new connection.'),
  (true, 'Signal and contact together (command 5) works: contact can be measured all night.'),
  (true, 'Eyes closed: the rhythm rose on the two back electrodes, as assumed.'),
  (null, 'The lifts did not settle which contact value belongs to which electrode.'),
  (true, 'Channel order as assumed (O2 T3 T4 O1).'),
];

const _passed = OwnBleViewModel(
  probeAt: '2026-11-19-081500',
  probePassed: true,
  probeWorn: true,
  probeLine: 'Passed. Our own connection can be tried for a night.',
  probeFolder: 'own-ble/probe/2026-11-19-081500',
  command5: true,
  lines: _lines,
);

final Map<String, OwnBleViewModel> _states = {
  'own_ble_first': const OwnBleViewModel(),
  'own_ble_passed': _passed,
  'own_ble_on': OwnBleViewModel(
    useOwn: true,
    signalResist: true,
    probeAt: _passed.probeAt,
    probePassed: true,
    probeWorn: true,
    probeLine: _passed.probeLine,
    probeFolder: _passed.probeFolder,
    command5: true,
    lines: _lines,
  ),
  'own_ble_on_anyway': const OwnBleViewModel(useOwn: true, triedAnyway: true),
  'own_ble_failed': const OwnBleViewModel(
    probeAt: '2026-11-19-081500',
    probeLine: "Not passed. Our own connection is not ready; BrainBit's SDK stays in use.",
    probeFolder: 'own-ble/probe/2026-11-19-081500',
    lines: [
      (true, 'The signal arrives at 250 samples a second.'),
      (false, 'Packets have another size than expected.'),
      (false, 'The signal did NOT start again after the contact check.'),
    ],
  ),
  'own_ble_pairing': const OwnBleViewModel(
    probeAt: '2026-11-19-081500',
    probeLine:
        'The headband asks for pairing. Hold its button 4 seconds until it blinks fast, then run the probe again '
        'with pairing on.',
    needsPairing: true,
    pairFirst: true,
    lines: [(false, 'It stopped early: connect: subscribe failed; the headband may need pairing')],
  ),
  'own_ble_blocked': const OwnBleViewModel(
    blocked: 'A night is recording. Stop it first: the headband keeps one connection.',
  ),
  'own_ble_connecting': const OwnBleViewModel(stage: OwnStage.connecting),
  'own_ble_ready': const OwnBleViewModel(
    stage: OwnStage.waitingReady,
    stepName: 'ready',
    stepText: 'Put the headband on, electrodes on the skin, sit still and relaxed. Tap Ready.',
  ),
  'own_ble_lift': const OwnBleViewModel(
    stage: OwnStage.running,
    stepName: 'lift_T3',
    stepText: 'Lift the LEFT TEMPLE electrode off the skin now.',
    secondsLeft: 3.2,
    fraction: 0.46,
  ),
  'own_ble_quiet_step': const OwnBleViewModel(stage: OwnStage.running, stepName: 'signal_again', secondsLeft: 6, fraction: 0.97),
};

Future<void> _shoot(WidgetTester tester, Widget w, String name, {double scale = 1, double height = 980}) async {
  tester.view.physicalSize = Size(1210, height * 2.75); // about a Xiaomi 12T: 440 x 980 dp
  tester.view.devicePixelRatio = 2.75;
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
    final image = await boundary.toImage(pixelRatio: height > 980 ? 2.0 : 2.75);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadFonts);

  group('the words of each state', () {
    test('before any probe: BrainBit\'s connection, and why ours waits', () {
      final s = describeOwnBle(_states['own_ble_first']!);
      expect(s.title, "BrainBit's connection");
      expect(s.sentence, contains('run the probe first'));
      expect(s.mark, MarkShape.ring);
    });

    test('a pass offers the switch; on says what it does; on without a pass warns in amber', () {
      final passed = describeOwnBle(_states['own_ble_passed']!);
      expect(passed.title, "BrainBit's connection");
      expect(passed.sentence, 'The probe passed (19 Nov, 08:15). You can switch to our own connection below and try a night.');
      final on = describeOwnBle(_states['own_ble_on']!);
      expect(on.title, 'Our own connection');
      expect(on.color, Night.live);
      final anyway = describeOwnBle(_states['own_ble_on_anyway']!);
      expect(anyway.color, Night.caution);
      expect(anyway.sentence, contains('the probe has not passed'));
    });

    test('a failed probe, a night recording', () {
      expect(describeOwnBle(_states['own_ble_failed']!).sentence, startsWith('Not passed.'));
      expect(describeOwnBle(_states['own_ble_failed']!).color, Night.caution);
      expect(describeOwnBle(_states['own_ble_blocked']!).title, 'Not now');
      expect(probeWhen('2026-01-05-230901'), '5 Jan, 23:09');
      expect(probeWhen('nonsense'), 'nonsense');
    });
  });

  testWidgets('the switch is off and locked before a pass, with "Try anyway" beside it', (tester) async {
    bool? switched;
    var anyway = 0;
    Future<void> show(OwnBleViewModel m) => tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: OwnBleView(model: m, onUseOwn: (v) => switched = v, onTryAnyway: () => anyway++, onRun: () {}),
      ),
    );
    await show(const OwnBleViewModel());
    final sw = tester.widget<Switch>(find.byType(Switch).first);
    expect(sw.value, isFalse);
    expect(sw.onChanged, isNull, reason: 'not offered before a passed probe');
    await tester.tap(find.text('Try anyway'));
    expect(anyway, 1);
    expect(find.text('Run the probe'), findsOneWidget);

    await show(_passed);
    expect(find.text('Try anyway'), findsNothing);
    await tester.tap(find.byType(Switch).first);
    expect(switched, isTrue);
    expect(find.text('Run the probe again'), findsOneWidget);
    expect(find.text('Measure contact all night'), findsNothing, reason: 'only with our own connection on');

    await show(_states['own_ble_on']!);
    expect(find.text('Measure contact all night'), findsOneWidget);
  });

  for (final scale in [1.0, 1.3]) {
    for (final e in _states.entries) {
      testWidgets('${e.key} at ${(scale * 100).round()} % text', (tester) async {
        await _shoot(
          tester,
          OwnBleView(
            model: e.value,
            onRun: () {},
            onReady: () {},
            onStop: () {},
            onUseOwn: (_) {},
            onTryAnyway: () {},
            onSignalResist: (_) {},
            onWorn: (_) {},
            onPairFirst: (_) {},
          ),
          '${e.key}${scale == 1.0 ? '' : '_text130'}',
          scale: scale,
        );
      });
    }
  }

  testWidgets('own_ble_passed_full: the whole page', (tester) async {
    await _shoot(tester, OwnBleView(model: _states['own_ble_on']!), 'own_ble_on_full', height: 2300);
  });

  testWidgets('night_connection_full: the night screen\'s way in, between nights only', (tester) async {
    const model = NightViewModel(
      title: 'Ready',
      sentence: 'Last night is saved. Put the headband on to start a new one.',
      tone: Tone.calm,
      running: false,
    );
    await _shoot(tester, NightView(model: model, onStart: () {}, onStop: () {}, onFix: (_) {}), 'night_connection_full', height: 1900);
    expect(find.text('Headband connection'), findsOneWidget);
    expect(find.text("Connection: BrainBit's library."), findsOneWidget);
    const recording = NightViewModel(title: 'Recording', sentence: 'All good.', tone: Tone.calm, running: true);
    await _shoot(tester, NightView(model: recording, onStart: () {}, onStop: () {}, onFix: (_) {}), 'night_connection_running', height: 1900);
    expect(find.text('Headband connection'), findsNothing, reason: 'the headband is busy while a night records');
  });
}
