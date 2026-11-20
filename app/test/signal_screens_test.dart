// The Signal tab's page (DECISIONS 590-599) at 4, 8 and 16 channels: Head, Traces and Raw rendered at the owner's 393 dp
// with 100 and 130 % text and real fonts, written to build/screens/signal_*.png for a human look; any overflow fails.
// Also the words of each state, the head's gestures (drag, double tap, a tap on an electrode), pause and look back.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eeg_tracker/signal/head3d.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/live_signal.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:eeg_tracker/ui/head_view.dart';
import 'package:eeg_tracker/ui/night_view.dart' show Tone;
import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:eeg_tracker/headband/device_status.dart';
import 'package:eeg_tracker/signal/quality.dart';
import 'package:eeg_tracker/ui/device_status.dart';
import 'package:eeg_tracker/ui/signal_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

Montage _montage(int n) => switch (n) {
  4 => brainBitMontage(),
  8 => helmetPlan8(),
  _ => helmetPlan16(),
};

/// [seconds] of made-up EEG: alpha that differs per channel, a little mains, an electrode offset; channel 1 flat.
LiveSignal _signal(Montage m, {double seconds = 20}) {
  final s = LiveSignal(names: m.names);
  final n = m.count;
  final rnd = math.Random(7);
  final t0 = DateTime(2026, 11, 20, 1, 30);
  final total = (seconds * liveRate).round();
  for (var at = 0; at < total; at += 25) {
    final v = Float32List(25 * n);
    final p = Int32List(25);
    for (var k = 0; k < 25; k++) {
      final i = at + k;
      p[k] = (i + (i > 3000 ? 3 : 0)) % 2048; // three packets lost once
      for (var c = 0; c < n; c++) {
        final t = i / liveRate;
        v[k * n + c] = c == 1
            ? 2500
            : 20000 * (c + 1) +
                  (8 + c) * math.sin(2 * math.pi * 10 * t + c) +
                  4 * math.sin(2 * math.pi * 3 * t) +
                  2 * math.sin(2 * math.pi * 50 * t) +
                  3 * (rnd.nextDouble() - 0.5);
      }
    }
    s.add(LiveBatch(arrival: t0.add(Duration(milliseconds: (at + 25) * 4)), values: v, channels: n, packs: p));
  }
  return s;
}

Map<String, double?> _ohms(Montage m) => {
  for (var i = 0; i < m.count; i++) m.names[i]: const [8.2e5, null, 1.9e6, 3.4e6, 4.6e5][i % 5],
};

SignalViewModel _live(Montage m, {FeedKind kind = FeedKind.own}) => SignalViewModel(
  stage: SignalStage.live,
  kind: kind,
  montage: m,
  ohms: _ohms(m),
  ohmsAt: DateTime(2026, 11, 20, 1, 29),
  ohmsFrom: kind == FeedKind.night ? ContactFrom.nightStart : ContactFrom.now,
  dataAge: 0,
  canMeasure: kind == FeedKind.own,
);

Future<void> _shoot(WidgetTester tester, Widget w, String name, {required double scale, double height = 900}) async {
  tester.view.physicalSize = Size(1080, 1080 / 393 * height);
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
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('build/screens/${name}_393dp_text${(scale * 100).round()}.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Scrolls the page's list until [f] is built and on screen.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.dragUntilVisible(f, find.byType(ListView).first, const Offset(0, -250));
  await tester.pump();
}

DeviceCard _card(SignalViewModel m) => DeviceCard(
  status: ValueNotifier(
    DeviceStatus(
      link: m.stage == SignalStage.live ? LinkState.live : LinkState.off,
      quality: QualityVerdict(
        electrodes: [
          for (final e in m.ohms.entries) ElectrodeQuality(name: e.key, grade: classifyOhms(e.value), ohms: e.value),
        ],
        ohmsAt: m.ohms.isEmpty ? null : m.ohmsAt,
      ),
      battery: const BandBattery(gauge: 71, estimate: 71),
    ),
  ),
  onMeasure: m.canMeasure ? () {} : null,
);

Widget _view(SignalViewModel m, LiveSignal? s, SignalPart part, {ValueNotifier<HeadPose>? pose, bool card = true}) => SignalView(
  model: m,
  signal: s,
  frames: ValueNotifier<int>(0),
  pose: pose ?? ValueNotifier(HeadPose.initial),
  initialPart: part,
  onAction: (_) {},
  // the headband card every screen shares: its status as the app's one connection would give it for this page
  device: card ? _card(m) : null,
  onPositions: () {},
  onInfo: () {},
);

void main() {
  setUpAll(loadFonts);

  group('the words', () {
    test('each state says what it is; trouble offers its one action', () {
      final m = brainBitMontage();
      SignalViewModel at(SignalStage s, {FeedKind kind = FeedKind.own, int? age, bool diy = false}) =>
          SignalViewModel(stage: s, kind: kind, montage: m, dataAge: age, diy: diy, problem: 'the headband connection is stuck');
      expect(describeSignal(at(SignalStage.notFound)).title, 'No headband');
      expect(describeSignal(at(SignalStage.notFound)).sentence, contains('still turns'));
      expect(describeSignal(at(SignalStage.notFound)).action, SignalAction.retry);
      expect(describeSignal(at(SignalStage.noPermission)).action, SignalAction.allow);
      expect(describeSignal(at(SignalStage.bluetoothOff)).action, SignalAction.bluetooth);
      expect(describeSignal(at(SignalStage.failed)).sentence, 'The headband connection is stuck.');
      expect(describeSignal(at(SignalStage.live, kind: FeedKind.night)).sentence, contains('night recording'));
      expect(describeSignal(at(SignalStage.live, kind: FeedKind.session)).sentence, contains('session'));
      expect(describeSignal(at(SignalStage.live)).tone, Tone.live);
      expect(describeSignal(at(SignalStage.waiting, age: 12)).sentence, 'No data for 12 s.');
      expect(describeSignal(at(SignalStage.waiting, age: 50)).tone, Tone.problem);
      expect(describeSignal(at(SignalStage.searching, diy: true)).sentence, contains('UDP port 9000'));
    });

    test('ohms in words', () {
      expect(formatOhms(null), '–');
      expect(formatOhms(double.infinity), 'off');
      expect(formatOhms(512), '512 Ω');
      expect(formatOhms(8.2e5), '820 kΩ');
      expect(formatOhms(1.94e6), '1.9 MΩ');
    });
  });

  for (final scale in [1.0, 1.3]) {
    for (final n in [4, 8, 16]) {
      for (final part in SignalPart.values) {
        testWidgets('signal ${part.name} with $n channels at 393 dp and ${(scale * 100).round()} % text', (tester) async {
          final m = _montage(n);
          final s = _signal(m);
          await _shoot(tester, _view(_live(m), s, part), 'signal_${part.name}_${n}ch', scale: scale, height: 1900);
          switch (part) {
            case SignalPart.head:
              expect(find.byType(HeadView), findsOneWidget);
              expect(find.text(m.names.first), findsWidgets);
              await _reveal(tester, find.text('Measure contact again'));
              expect(find.text('Measure contact again'), findsOneWidget);
            case SignalPart.traces:
              expect(find.text('1-40 Hz'), findsOneWidget);
              expect(find.text(m.names.first), findsOneWidget);
            case SignalPart.raw:
              expect(find.text('Pause'), findsOneWidget);
              expect(find.text('$n'), findsOneWidget); // the channel counter
              expect(find.textContaining('3 in 1 gap'), findsOneWidget);
          }
        });
      }
    }

    testWidgets('signal without a headband at 393 dp and ${(scale * 100).round()} % text', (tester) async {
      final m = brainBitMontage();
      await _shoot(
        tester,
        _view(SignalViewModel(stage: SignalStage.notFound, kind: FeedKind.own, montage: m), null, SignalPart.head),
        'signal_none',
        scale: scale,
      );
      expect(find.text('No headband'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byType(HeadView), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('about 71 %'), findsOneWidget, reason: 'the battery shows on the Signal tab too');
      expect(find.text('Measure contact again'), findsNothing);
    });

    testWidgets('signal during a night at 393 dp and ${(scale * 100).round()} % text', (tester) async {
      final m = brainBitMontage();
      await _shoot(tester, _view(_live(m, kind: FeedKind.night), _signal(m), SignalPart.head), 'signal_night', scale: scale);
      expect(find.textContaining('night recording'), findsOneWidget);
      expect(find.text('about 71 %'), findsOneWidget);
      expect(find.text('Measure contact again'), findsNothing);
    });

    testWidgets('signal for the DIY board at 393 dp and ${(scale * 100).round()} % text', (tester) async {
      final m = diyBoardMontage(const ['O1', 'CH2', 'Fz', 'Fp1']);
      final model = SignalViewModel(stage: SignalStage.live, kind: FeedKind.own, montage: m, measuresContact: false, diy: true, dataAge: 0);
      await _shoot(tester, _view(model, _signal(m), SignalPart.head), 'signal_diy', scale: scale);
      expect(find.textContaining('not measured by this board'), findsOneWidget);
      await _reveal(tester, find.textContaining('No place on the head for CH2'));
      expect(find.textContaining('No place on the head for CH2'), findsOneWidget);
    });
  }

  testWidgets('the head turns with a drag, straightens on a double tap, and a tap picks an electrode', (tester) async {
    final m = brainBitMontage();
    final pose = ValueNotifier(HeadPose.initial);
    tester.view.physicalSize = const Size(1080, 1080 / 393 * 900);
    tester.view.devicePixelRatio = 1080 / 393;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: nightTheme(), home: _view(_live(m), _signal(m), SignalPart.head, pose: pose, card: false)), // the head and its rows alone
    );
    await tester.pump();
    final head = find.byType(HeadView);
    await tester.drag(head, const Offset(-120, 40));
    await tester.pump(const Duration(milliseconds: 400));
    expect(pose.value.yaw, greaterThan(20));
    expect(pose.value.pitch, greaterThan(HeadPose.initial.pitch));
    await tester.tap(head);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(head);
    await tester.pump(const Duration(milliseconds: 400));
    expect(pose.value, HeadPose.initial);
    // O2's mark, where the camera puts it
    final box = tester.getRect(head);
    final o2 = HeadCamera(HeadPose.initial, box.size).site(m.site('O2')!.at!).at;
    await tester.tapAt(box.topLeft + o2);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<HeadView>(head).selected, 'O2');
    // the electrode rows pick too
    await _reveal(tester, find.text('T4'));
    await tester.tap(find.text('T4').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<HeadView>(head).selected, 'T4');
  });

  testWidgets('raw: pause freezes the window, the slider looks back, Back to live returns', (tester) async {
    final m = brainBitMontage();
    final s = _signal(m, seconds: 60);
    tester.view.physicalSize = const Size(1080, 1080 / 393 * 1900);
    tester.view.devicePixelRatio = 1080 / 393;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: _view(_live(m), s, SignalPart.raw)));
    await tester.pump();
    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Back to live'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.textContaining('look back up to'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(-150, 0));
    await tester.pump();
    expect(find.textContaining('back.'), findsOneWidget);
    await tester.tap(find.text('Back to live'));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
  });
}
