// The one headband card (lib/ui/device_status.dart, DECISIONS 854): what it shows, and that every screen shows this
// same component with the same numbers, not a display of its own.
import 'dart:typed_data';

import 'package:eeg_tracker/dream/controller.dart';
import 'package:eeg_tracker/headband/battery_estimate.dart';
import 'package:eeg_tracker/headband/device_status.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/nap/controller.dart';
import 'package:eeg_tracker/signal/head3d.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/live_signal.dart';
import 'package:eeg_tracker/signal/quality.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/store.dart' show HeadbandUse;
import 'package:eeg_tracker/ui/device_status.dart';
import 'package:eeg_tracker/ui/dream_view.dart';
import 'package:eeg_tracker/ui/lost_notice_setting.dart';
import 'package:eeg_tracker/ui/meditation_view.dart';
import 'package:eeg_tracker/ui/nap_view.dart';
import 'package:eeg_tracker/ui/night_view.dart';
import 'package:eeg_tracker/ui/signal_view.dart';
import 'package:eeg_tracker/ui/states_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/work_view.dart';
import 'package:eeg_tracker/work/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime(2026, 11, 21, 22, 14);

QualityVerdict _verdict(List<String> names, {Trouble trouble = Trouble.none, bool settling = false}) => QualityVerdict(
  electrodes: [
    for (var i = 0; i < names.length; i++)
      ElectrodeQuality(
        name: names[i],
        grade: i == 1 ? Contact.poor : (i == 2 ? Contact.ok : Contact.good),
        ohms: i == 1 ? 1.4e6 : (i == 2 ? 600e3 : 120e3),
        fromSignal: true,
      ),
  ],
  trouble: trouble,
  ohmsAt: _at,
  settling: settling,
);

DeviceStatus _live({List<String> names = const ['O1', 'O2', 'T3', 'T4'], Trouble trouble = Trouble.electrodes}) => DeviceStatus(
  link: LinkState.live,
  use: BandUse.signal,
  name: 'BrainBit',
  quality: _verdict(names, trouble: trouble),
  battery: const BandBattery(gauge: 6, estimate: 62, stuck: true),
);

Widget _app(Widget home, DeviceCard card) => MaterialApp(
  theme: nightTheme(),
  builder: (context, child) => DeviceCardScope(card: card, child: child!),
  home: home,
);

void main() {
  setUp(() => signalPanelOpen.value = false);

  testWidgets('connected: the state, the battery estimate with the gauge\'s own number, each electrode with its ohms and their time', (tester) async {
    final card = DeviceCard(status: ValueNotifier(_live()));
    await tester.pumpWidget(_app(Scaffold(body: ListView(children: [DeviceStatusCard(card: card)])), card));
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('about 62 %'), findsOneWidget);
    expect(find.textContaining('own gauge says 6 %'), findsOneWidget);
    for (final n in ['O1', 'O2', 'T3', 'T4']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.text('good'), findsNWidgets(2));
    expect(find.text('poor'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('1.4 MΩ'), findsOneWidget);
    expect(find.text('120 kΩ'), findsNWidgets(2));
    expect(find.textContaining('Contact measured at 22:14'), findsOneWidget);
    expect(find.textContaining('cannot be measured while the signal runs'), findsOneWidget);
    expect(find.textContaining('O2: this electrode has poor contact'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Measure contact again'), findsNothing, reason: 'only where the screen may measure');
  });

  testWidgets('busy is you, not an electrode: every electrode says busy, and the sentence says the band is on', (tester) async {
    final card = DeviceCard(status: ValueNotifier(_live(trouble: Trouble.busy)));
    await tester.pumpWidget(_app(Scaffold(body: ListView(children: [DeviceStatusCard(card: card)])), card));
    expect(find.text('busy'), findsNWidgets(4));
    expect(find.text('poor'), findsNothing);
    expect(find.textContaining('The band is on'), findsOneWidget);
  });

  testWidgets('any number of electrodes: 8 and 16 fit at 393 dp and at 130 % text', (tester) async {
    tester.view.physicalSize = const Size(393 * 2, 851 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    for (final n in [8, 16]) {
      final names = [for (var i = 1; i <= n; i++) 'CH$i'];
      final card = DeviceCard(status: ValueNotifier(_live(names: names)));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(393, 851), textScaler: TextScaler.linear(1.3)),
          child: _app(Scaffold(body: ListView(padding: const EdgeInsets.all(24), children: [DeviceStatusCard(card: card)])), card),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$n electrodes');
      expect(find.byType(ElectrodeCell), findsNWidgets(n));
    }
  });

  testWidgets('not connected: the word, the last battery estimate, and Connect; a status change shows at once', (tester) async {
    var connects = 0, measures = 0;
    final status = ValueNotifier(const DeviceStatus(battery: BandBattery(gauge: 80, estimate: 80)));
    final card = DeviceCard(status: status, onConnect: () => connects++, onMeasure: () => measures++);
    await tester.pumpWidget(_app(Scaffold(body: ListView(children: [DeviceStatusCard(card: card)])), card));
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('about 80 %'), findsOneWidget);
    expect(find.text('Measure contact again'), findsNothing);
    await tester.tap(find.text('Connect'));
    expect(connects, 1);
    status.value = _live().copyWith(lingering: true);
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Kept ready for the next start.'), findsOneWidget);
    await tester.tap(find.text('Measure contact again'));
    expect(measures, 1);
    status.value = const DeviceStatus(link: LinkState.reconnecting);
    await tester.pump();
    expect(find.text('Headband lost, reconnecting'), findsOneWidget);
  });

  testWidgets('a new fit says to wait; a board without a contact reading says so', (tester) async {
    final status = ValueNotifier(
      DeviceStatus(link: LinkState.live, quality: _verdict(['O1', 'O2', 'T3', 'T4'], trouble: Trouble.electrodes, settling: true)),
    );
    final card = DeviceCard(status: status);
    await tester.pumpWidget(_app(Scaffold(body: ListView(children: [DeviceStatusCard(card: card)])), card));
    expect(find.textContaining('2 to 5 minutes'), findsOneWidget);
    status.value = const DeviceStatus(link: LinkState.live, measuresContact: false);
    await tester.pump();
    expect(find.text('This board does not measure contact.'), findsOneWidget);
  });

  testWidgets('the signal panel: folded, a thin line per electrode; unfolded, the raw traces with numbers; the source works only while shown', (tester) async {
    final signal = LiveSignal(names: const ['O1', 'O2', 'T3', 'T4']);
    final values = Float32List(4 * 500);
    for (var i = 0; i < values.length; i++) {
      values[i] = (i % 7) * 3.0;
    }
    signal.add(LiveBatch(arrival: _at, values: values, channels: 4));
    final watched = <bool>[];
    final card = DeviceCard(
      status: ValueNotifier(_live()),
      panel: PanelSource(signal: () => signal, frames: ValueNotifier<int>(0), watch: watched.add),
    );
    await tester.pumpWidget(_app(Scaffold(body: ListView(children: [DeviceStatusCard(card: card)])), card));
    await tester.pump();
    expect(watched, [true]);
    expect(find.text('Signal'), findsOneWidget);
    expect(find.text('Unfold'), findsOneWidget);
    expect(find.textContaining('mains'), findsNothing);
    await tester.tap(find.text('Unfold'));
    await tester.pump();
    expect(find.text('Signal, raw'), findsOneWidget);
    expect(find.textContaining('mains'), findsNWidgets(4));
    expect(signalPanelOpen.value, isTrue, reason: 'one choice for every screen');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(watched, [true, false]);
  });

  group('every screen shows this same card', () {
    late DeviceCard card;
    setUp(() => card = DeviceCard(status: ValueNotifier(_live())));

    Future<void> seen(WidgetTester tester, Widget page, String screen) async {
      tester.view.physicalSize = const Size(393 * 2, 3000 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(page, card));
      await tester.pump();
      expect(find.byType(DeviceStatusCard, skipOffstage: false), findsOneWidget, reason: screen);
      expect(find.text('about 62 %', skipOffstage: false), findsOneWidget, reason: '$screen: the battery');
      expect(find.byType(ElectrodeCell, skipOffstage: false), findsNWidgets(4), reason: '$screen: the electrodes');
    }

    testWidgets('Night (Sleep)', (tester) async {
      await seen(
        tester,
        NightView(
          model: const NightViewModel(title: 'Ready', sentence: 'Tap Start night.', tone: Tone.calm, running: false),
          onStart: () {},
          onStop: () {},
          onFix: (_) {},
        ),
        'Night',
      );
    });

    testWidgets('Signal: the battery shows here too', (tester) async {
      await seen(
        tester,
        SignalView(
          model: SignalViewModel(stage: SignalStage.live, kind: FeedKind.own, montage: brainBitMontage()),
          device: card,
          signal: null,
          frames: ValueNotifier<int>(0),
          pose: ValueNotifier(HeadPose.initial),
        ),
        'Signal',
      );
    });

    testWidgets('Work, before and during', (tester) async {
      await seen(tester, const WorkView(model: WorkViewModel(stage: WorkStage.setup)), 'Work, setup');
      await seen(tester, const WorkView(model: WorkViewModel(stage: WorkStage.running)), 'Work, running');
    });

    testWidgets('Nap', (tester) async {
      await seen(
        tester,
        NapView(
          model: const NapViewModel(stage: NapStage.setup),
          onLength: (_) {},
          onLightsOff: () {},
          onStop: () {},
          onAwake: () {},
          onOpen: (_) {},
          onInfo: () {},
        ),
        'Nap',
      );
    });

    testWidgets('Meditation, while it runs', (tester) async {
      await seen(
        tester,
        MeditationView(
          model: meditationModel(stage: Stage.running, minutes: 10, runSeconds: 60),
          onMinutes: (_) {},
          onStart: () {},
          onStop: () {},
          onDone: () {},
          onInfo: () {},
        ),
        'Meditation',
      );
    });

    testWidgets('Sound for states, the quiet minute', (tester) async {
      await seen(
        tester,
        StatesView(
          model: StatesViewModel(stage: SoundStage.quiet, plan: SoundPlan.of(SoundState.relax), headbandUse: HeadbandUse.used, quietS: 23),
          onState: (_) {},
          onBed: (_) {},
          onBeat: (_) {},
          onMinutes: (_) {},
          onHeadband: (_) {},
          onThenNight: (_) {},
          onListen: () {},
          onStart: () {},
          onStop: () {},
          onSkip: () {},
          onRate: (_) {},
          onInfo: () {},
        ),
        'Sound for states',
      );
    });

    testWidgets('Dream catcher, the baseline', (tester) async {
      await seen(
        tester,
        DreamView(
          model: const DreamViewModel(stage: DreamStage.baseline),
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
        ),
        'Dream catcher',
      );
    });
  });

  testWidgets('the lost-headband setting: on by default at 5 minutes, 5 to 10 to choose', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: const Scaffold(body: LostNoticeSetting())));
    await tester.pump();
    expect(find.text('Tell me when the headband is lost'), findsOneWidget);
    expect(find.textContaining('for 5 minutes'), findsOneWidget);
    for (var m = 5; m <= 10; m++) {
      expect(find.widgetWithText(ChoiceChip, '$m'), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(ChoiceChip, '8'));
    await tester.pump();
    expect(find.textContaining('for 8 minutes'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.byType(ChoiceChip), findsNothing);
  });
}
