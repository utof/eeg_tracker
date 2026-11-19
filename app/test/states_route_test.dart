// Sound for states and where the sound goes (DECISIONS 470): a plain line about the route under the beat choice,
// amber only for a binaural beat on the phone's speaker; the session file keeps the route and its changes.
import 'dart:io';

import 'package:eeg_tracker/sound/audio_route.dart';
import 'package:eeg_tracker/sound/state_sound.dart';
import 'package:eeg_tracker/states/controller.dart';
import 'package:eeg_tracker/states/presets.dart';
import 'package:eeg_tracker/states/store.dart';
import 'package:eeg_tracker/ui/parts.dart' show SectionHeading;
import 'package:eeg_tracker/ui/states_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dream_test.dart' show OneFinder;
import 'states_screens_test.dart' show view;

const speaker = AudioRoute(
  RouteKind.speaker,
  type: 'speaker',
  device: 'Mi 11T',
);
const wired = AudioRoute(RouteKind.wired, type: 'wired_headphones');
const a2dp = AudioRoute(
  RouteKind.bluetooth,
  type: 'a2dp',
  device: 'WH-1000XM4',
);
const le = AudioRoute(
  RouteKind.bluetoothLe,
  type: 'ble_headset',
  device: 'Buds',
);

Future<void> show(WidgetTester tester, StatesViewModel m) async {
  tester.view.physicalSize = const Size(1210, 2695);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: nightTheme(), home: view(m)));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.scrollUntilVisible(find.widgetWithText(SectionHeading, 'Length'), 300);
}

StatesViewModel model(AudioRoute route, Beat beat) => StatesViewModel(
  stage: SoundStage.setup,
  plan: SoundPlan.of(SoundState.relax, beat: beat),
  route: route,
);

Finder said(String part) => find.textContaining(part, skipOffstage: false);

void main() {
  group('the words about the route', () {
    test('a binaural beat on the speaker is the only warning', () {
      for (final r in [
        speaker,
        wired,
        a2dp,
        le,
        AudioRoute.unknown,
        const AudioRoute(RouteKind.other),
      ]) {
        for (final binaural in [true, false]) {
          expect(
            stateRouteNote(r, binaural: binaural).warn,
            r.kind == RouteKind.speaker && binaural,
            reason: '$r $binaural',
          );
        }
      }
      final w = stateRouteNote(speaker, binaural: true).text;
      expect(w, contains('speaker'));
      expect(w, contains('no beat'));
      expect(w, contains('stereo headphones'));
    });

    test('the speaker is claimed only when the sound goes there', () {
      for (final r in [
        wired,
        a2dp,
        le,
        AudioRoute.unknown,
        const AudioRoute(RouteKind.other),
      ]) {
        for (final binaural in [true, false]) {
          expect(
            stateRouteNote(
              r,
              binaural: binaural,
            ).text.contains('phone\'s speaker'),
            isFalse,
            reason: '$r $binaural',
          );
        }
      }
      expect(
        stateRouteNote(speaker, binaural: false).text,
        'Sound plays from the phone\'s speaker.',
      );
      expect(
        stateRouteNote(wired, binaural: false).text,
        'Sound plays to wired headphones.',
      );
    });

    test(
      'Bluetooth: a delay does not matter for sounds that are not feedback',
      () {
        final t = stateRouteNote(a2dp, binaural: true).text;
        expect(t, contains('Bluetooth headphones (WH-1000XM4)'));
        expect(t, contains('not feedback'));
        expect(t, isNot(contains('weaken')));
        expect(
          stateRouteNote(le, binaural: false).text,
          contains('Bluetooth LE headphones (Buds)'),
        );
      },
    );
  });

  group('the states screen', () {
    testWidgets(
      'a binaural beat on the speaker: an amber warning, and no claim that the speaker is kinder',
      (tester) async {
        await show(tester, model(speaker, Beat.binaural));
        expect(said('you will hear no beat'), findsOneWidget);
        final text = tester.widget<Text>(
          find.byWidgetPredicate(
            (w) =>
                w is Text && (w.data ?? '').contains('you will hear no beat'),
          ),
        );
        expect(text.style?.color, Night.caution);
      },
    );

    testWidgets(
      'headphones: the line names them, the speaker is not claimed, no warning',
      (tester) async {
        await show(tester, model(wired, Beat.binaural));
        expect(said('Sound plays to wired headphones.'), findsOneWidget);
        expect(said('you will hear no beat'), findsNothing);
        expect(said('Sound plays from the phone\'s speaker'), findsNothing);
      },
    );

    testWidgets('Bluetooth: said without a warning', (tester) async {
      await show(tester, model(a2dp, Beat.isochronic));
      expect(said('a Bluetooth delay does not matter'), findsOneWidget);
      expect(said('weakens'), findsNothing);
    });

    testWidgets('the speaker with a beat that works there: one plain line', (
      tester,
    ) async {
      await show(tester, model(speaker, Beat.pulsed));
      expect(said('Sound plays from the phone\'s speaker.'), findsOneWidget);
      expect(said('no beat'), findsNothing);
    });
  });

  group('the session file', () {
    late Directory root;
    late SoundStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('states-route');
      store = SoundStore(Directory('${root.path}/sound-states'));
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('keeps the route at the start and a change part-way', () async {
      final routes = FixedAudioRoute(speaker);
      final c = StatesController(
        finder: OneFinder(null),
        sound: SilentStateSound.new,
        store: store,
        timing: const StatesTiming(tick: Duration(milliseconds: 20)),
        audioRoute: routes,
      );
      await c.start(
        SoundPlan.of(SoundState.relax, beat: Beat.binaural),
        useHeadband: false,
      );
      expect(c.route, speaker);
      routes.set(wired);
      for (var i = 0; i < 50 && c.route != wired; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.route, wired);
      await c.stop();
      final s = store.list().single;
      expect(s.audioRoute, speaker);
      expect(
        s.events
            .where((e) => e.text.startsWith('audio route'))
            .map((e) => e.text)
            .single,
        contains('wired headphones'),
      );
      final back = SoundSession.fromJson(s.toJson())!;
      expect(back.audioRoute, speaker);
      expect(
        routes.listening,
        isTrue,
        reason: 'the screen follows it until the controller goes',
      );
      c.dispose();
      expect(routes.listening, isFalse);
    });

    test(
      'without a route source nothing is written and old files still load',
      () async {
        final c = StatesController(
          finder: OneFinder(null),
          sound: SilentStateSound.new,
          store: store,
        );
        await c.start(SoundPlan.of(SoundState.relax), useHeadband: false);
        await c.stop();
        final s = store.list().single;
        expect(s.audioRoute, isNull);
        expect(s.toJson().containsKey('audio'), isFalse);
        expect(SoundSession.fromJson(s.toJson())!.audioRoute, isNull);
        c.dispose();
      },
    );
  });
}
