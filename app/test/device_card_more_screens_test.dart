// The one headband card (lib/ui/device_status.dart, DECISIONS 854, 947) on the three screens that did not have it:
// the hands-free calibration, alpha-theta's setup page (its session already shows it through the meditation view) and
// the DIY board on the Signal tab, which gets the card from an owner of its own connection (the same
// HeadbandConnection class, so no second copy of the state, quality or battery code) for any number of channels.
import 'dart:async';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/handsfree/calibration_controller.dart';
import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:eeg_tracker/headband/connection.dart';
import 'package:eeg_tracker/headband/device_status.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/quality.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:eeg_tracker/training/control.dart' show SessionKind;
import 'package:eeg_tracker/ui/alpha_theta_views.dart';
import 'package:eeg_tracker/ui/device_status.dart';
import 'package:eeg_tracker/ui/hands_free_view.dart';
import 'package:eeg_tracker/ui/meditation_view.dart';
import 'package:eeg_tracker/ui/signal_screen.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'screens_test.dart' show loadFonts;

DeviceStatus _live(List<String> names) => DeviceStatus(
  link: LinkState.live,
  use: BandUse.session,
  name: 'BrainBit',
  quality: QualityVerdict(
    electrodes: [for (final n in names) ElectrodeQuality(name: n, grade: Contact.good, ohms: 120e3)],
    ohmsAt: DateTime(2026, 11, 24, 20, 14),
  ),
  battery: const BandBattery(gauge: 60, estimate: 62),
);

Widget _app(Widget home, DeviceCard? card) => MaterialApp(
  theme: nightTheme(),
  builder: (context, child) => DeviceCardScope(card: card, child: child!),
  home: home,
);

/// A board that is not a BrainBit: [names] channels, no contact reading, no battery (what the DIY board is to the app).
class _Board implements Headband, OtherBoard {
  _Board(this.names);
  final List<String> names;
  final List<String> calls = [];
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _range = StreamController<bool>.broadcast(sync: true);
  int _pack = 0;

  void send([int n = 25]) => _signal.add([
    for (var i = 0; i < n; i++) Sample(_pack++ % 2048, [for (var c = 0; c < names.length; c++) 1e-5 * (c + 1)]),
  ]);

  @override
  String get name => 'DIY board';
  @override
  String get address => 'udp:9000';
  @override
  String get serial => '';
  @override
  int? get rssi => null;
  @override
  BandId get id => const BandId(name: 'DIY board', address: 'udp:9000', family: 'diy');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => const Stream.empty();
  @override
  Stream<bool> get rangeChanges => _range.stream;
  @override
  Future<void> startSignal() async => calls.add('startSignal');
  @override
  Future<void> stopSignal() async => calls.add('stopSignal');
  @override
  Future<void> startResist() async => calls.add('startResist');
  @override
  Future<void> stopResist() async => calls.add('stopResist');
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => throw StateError('this board has no battery reading');
  @override
  Future<void> disconnectAndDispose() async => calls.add('disconnect');
  @override
  BoardLive get board => BoardLive(names: names, mode: 'signal', modeText: 'signal', notEeg: false);
  @override
  RecordingHeader get header => headerForMontage(diyBoardMontage(names), device: 'DIY board');
}

class _BoardFinder implements HeadbandFinder {
  _BoardFinder(this.board);
  final _Board board;
  int finds = 0;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    finds++;
    return board;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => board;
}

const _quick = LinkTiming(
  scanFor: Duration(milliseconds: 10),
  connectTimeout: Duration(milliseconds: 50),
  sdkTimeout: Duration(milliseconds: 200),
  contactFor: Duration(milliseconds: 5),
  settle: Duration.zero,
  reconnectWaits: [Duration(milliseconds: 5)],
  rescanFor: Duration(milliseconds: 10),
);

void main() {
  setUpAll(loadFonts); // the app's own font: the views are laid out as on the phone
  setUp(() => signalPanelOpen.value = false);

  group('the same card, from the app\'s one connection', () {
    late DeviceCard card;
    setUp(() => card = DeviceCard(status: ValueNotifier(_live(const ['O1', 'O2', 'T3', 'T4']))));

    Future<void> seen(WidgetTester tester, Widget page, String screen) async {
      tester.view.physicalSize = const Size(393 * 2, 3000 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(page, card));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: screen);
      expect(find.byType(DeviceStatusCard, skipOffstage: false), findsOneWidget, reason: screen);
      expect(find.text('about 62 %', skipOffstage: false), findsOneWidget, reason: '$screen: the battery');
      expect(find.byType(ElectrodeCell, skipOffstage: false), findsNWidgets(4), reason: '$screen: the electrodes');
    }

    Widget cal(CalViewModel m) => CalibrationView(model: m, onStart: () {}, onStop: () {}, onDone: () {}, onInfo: () {});

    testWidgets('Hands-free calibration: before the start, while it connects, and while it runs', (tester) async {
      await seen(tester, cal(const CalViewModel(stage: CalStage.setup)), 'calibration, setup');
      await seen(tester, cal(const CalViewModel(stage: CalStage.contact, message: 'Checking contact.')), 'calibration, contact');
      await seen(tester, cal(const CalViewModel(stage: CalStage.still)), 'calibration, sitting still');
      await seen(tester, cal(const CalViewModel(stage: CalStage.trying, tryNow: 1, inWindow: true)), 'calibration, a try');
    });

    testWidgets('Hands-free calibration: no card on the result (the headband is let go) and none without a connection', (tester) async {
      await tester.pumpWidget(_app(cal(const CalViewModel(stage: CalStage.failed, message: 'Stopped.')), card));
      expect(find.byType(DeviceStatusCard, skipOffstage: false), findsNothing);
      await tester.pumpWidget(_app(cal(const CalViewModel(stage: CalStage.setup)), null));
      expect(find.byType(DeviceStatusCard, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Alpha-theta: the setup page', (tester) async {
      await seen(
        tester,
        AtSetupView(
          model: const AtSetupModel(done: 2, minutes: 15, lengths: [10, 15]),
          onMinutes: (_) {},
          onCheckIn: () {},
          onResume: () {},
          onDecide: () {},
          onInfo: () {},
          onSettings: () {},
        ),
        'alpha-theta, setup',
      );
    });

    testWidgets('Alpha-theta: its session (the meditation view with the alpha-theta kind)', (tester) async {
      await seen(
        tester,
        MeditationView(
          model: meditationModel(stage: Stage.running, minutes: 15, runSeconds: 60, kind: SessionKind.alphaTheta),
          onMinutes: (_) {},
          onStart: () {},
          onStop: () {},
          onDone: () {},
          onInfo: () {},
        ),
        'alpha-theta, session',
      );
    });
  });

  group('the DIY board on the Signal tab', () {
    const names = ['Fp1', 'Fp2', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2'];

    testWidgets('the card comes from an owner of the board\'s connection: state, 8 electrodes, no contact reading', (tester) async {
      tester.view.physicalSize = const Size(393 * 2, 4000 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final board = _Board(names);
      final finder = _BoardFinder(board);
      final owner = HeadbandConnection(makeFinder: () => finder, tickEvery: const Duration(milliseconds: 20));
      final device = SignalDevice(montage: diyBoardMontage(names), measuresContact: false, diy: true);
      final feed = SignalFeed(
        SignalPhone(
          nightRunning: () async => false,
          leaseNight: (_) {},
          fromRecorder: () => const Stream.empty(),
          device: () async => device,
          readiness: (_) async => null,
          finderFor: (d) => owner.finder,
          diyConnection: owner,
          timing: _quick,
          tickEvery: const Duration(milliseconds: 10),
        ),
      );
      await tester.pumpWidget(_app(Scaffold(body: SignalScreen(feed: feed, recordingsDir: '/nowhere')), null));
      await tester.runAsync(() async {
        for (var i = 0; i < 200 && feed.stage != SignalStage.waiting && feed.stage != SignalStage.live; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        for (var i = 0; i < 6; i++) {
          board.send(250);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(finder.finds, 1, reason: 'one connection: the feed reads through the owner');
      expect(board.calls, isNot(contains('startResist')));
      expect(find.byType(DeviceStatusCard, skipOffstage: false), findsOneWidget);
      expect(find.text('Connected', skipOffstage: false), findsOneWidget);
      expect(find.byType(ElectrodeCell, skipOffstage: false), findsNWidgets(8));
      for (final n in names) {
        expect(
          find.descendant(of: find.byType(ElectrodeCell, skipOffstage: false), matching: find.text(n, skipOffstage: false)),
          findsOneWidget,
          reason: n,
        );
      }
      expect(find.text('This board does not measure contact.', skipOffstage: false), findsOneWidget);
      expect(find.text('Measure contact again', skipOffstage: false), findsNothing);
      expect(owner.status.value.measuresContact, isFalse);
      expect(owner.status.value.quality.electrodes.map((e) => e.name), names);
      // leaving the tab lets the board go at once (nothing is kept for it)
      await tester.runAsync(() => feed.setActive(false));
      expect(board.calls, contains('disconnect'));
      expect(owner.connected, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        feed.dispose();
        await owner.dispose();
      });
      await tester.pump(const Duration(seconds: 2)); // the clocks the screen started end
    });

    testWidgets('during the board\'s night the card is the recorder\'s (the app\'s one connection mirrors it)', (tester) async {
      // the Signal screen picks its card: the board's own owner for its own connection, the shared one for a night
      final own = HeadbandConnection(makeFinder: () => _BoardFinder(_Board(names)));
      final shared = HeadbandConnection(makeFinder: () => _BoardFinder(_Board(names)));
      addTearDown(own.dispose);
      addTearDown(shared.dispose);
      expect(signalCardOwner(diy: true, kind: FeedKind.own, shared: shared, diyOwner: own), same(own));
      expect(signalCardOwner(diy: true, kind: FeedKind.night, shared: shared, diyOwner: own), same(shared));
      expect(signalCardOwner(diy: false, kind: FeedKind.own, shared: shared, diyOwner: own), same(shared));
      expect(signalCardOwner(diy: true, kind: FeedKind.own, shared: shared, diyOwner: null), isNull);
    });
  });
}
