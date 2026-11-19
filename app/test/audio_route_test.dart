// Where the sound goes (lib/sound/audio_route.dart, DECISIONS 424): the phone's answer read leniently, the
// Bluetooth warning in the research's numbers, the platform channel (mocked: no phone here), and a meditation
// that records its route and a switch to Bluetooth part-way. Nothing here measures a delay.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/meditation/controller.dart';
import 'package:eeg_tracker/meditation/store.dart';
import 'package:eeg_tracker/meditation/tracker.dart';
import 'package:eeg_tracker/sound/audio_route.dart';
import 'package:eeg_tracker/sound/feedback_sound.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide Finder;

import 'meditation_test.dart' show DemoBand, Finder, fast, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the phone\'s answer: each kind, a device name, anything odd is unknown', () {
    expect(
      AudioRoute.fromMap({'route': 'bluetooth', 'type': 'a2dp', 'device': 'WH-1000XM4'}),
      const AudioRoute(RouteKind.bluetooth, type: 'a2dp', device: 'WH-1000XM4'),
    );
    for (final k in RouteKind.values) {
      expect(AudioRoute.fromMap({'route': k.name}).kind, k);
    }
    expect(AudioRoute.fromMap({'route': 'satellite'}).kind, RouteKind.unknown);
    expect(AudioRoute.fromMap('bluetooth'), AudioRoute.unknown);
    expect(AudioRoute.fromMap({'route': 'wired', 'device': 42}).device, '');
    const r = AudioRoute(RouteKind.bluetoothLe, type: 'ble_headset', device: 'Buds');
    expect(AudioRoute.fromMap(r.toJson()), r);
    expect(r.bluetooth, isTrue);
    expect(const AudioRoute(RouteKind.wired).bluetooth, isFalse);
    expect(const AudioRoute(RouteKind.speaker).toJson(), {'route': 'speaker'});
  });

  test('the warning: Bluetooth is late (the research\'s numbers), LE Audio unmeasured, others none', () {
    final classic = routeWarning(const AudioRoute(RouteKind.bluetooth, device: 'WH-1000XM4'))!;
    expect(classic, contains('WH-1000XM4'));
    expect(classic, contains('0.25-0.5 s late'));
    expect(classic, contains('You can still start'));
    expect(routeWarning(const AudioRoute(RouteKind.bluetooth)), startsWith('Sound goes to Bluetooth headphones.'));
    final le = routeWarning(const AudioRoute(RouteKind.bluetoothLe, device: 'Buds'))!;
    expect(le, contains('0.03-0.08 s'));
    expect(le, contains('not measured on phones'));
    for (final k in [RouteKind.speaker, RouteKind.wired, RouteKind.other, RouteKind.unknown]) {
      expect(routeWarning(AudioRoute(k)), isNull, reason: k.name);
    }
  });

  group('the platform channel', () {
    const channel = MethodChannel('eeg_tracker/audio_route');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('current: the phone\'s map, read', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'current');
        return {'route': 'wired', 'type': 'wired_headphones', 'device': ''};
      });
      expect(await PhoneAudioRoute().current(), const AudioRoute(RouteKind.wired, type: 'wired_headphones'));
    });

    test('an error or no Android side: unknown, never a failure', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'audio_route'));
      expect(await PhoneAudioRoute().current(), AudioRoute.unknown);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await PhoneAudioRoute().current(), AudioRoute.unknown, reason: 'no handler: MissingPluginException');
    });
  });

  test('a meditation records its route at the start and a switch to Bluetooth part-way', () async {
    final dir = Directory.systemTemp.createTempSync('route');
    addTearDown(() => dir.deleteSync(recursive: true));
    final routes = FixedAudioRoute(const AudioRoute(RouteKind.wired, type: 'wired_headphones'));
    final c = MeditationController(
      finder: Finder([DemoBand(DemoSignal(7))]),
      sound: SilentSound.new,
      store: MeditationStore(dir),
      timing: fast,
      audioRoute: routes,
      silentBlock: Duration.zero,
    );
    await c.start(const Duration(minutes: 1));
    expect(c.route.kind, RouteKind.wired);
    await until(c, () => c.runSeconds > 20);
    routes.set(const AudioRoute(RouteKind.bluetooth, type: 'a2dp', device: 'WH-1000XM4'));
    await until(c, () => c.route.bluetooth);
    await until(c, () => c.stage == Stage.report);
    final info = c.session!.log.info;
    expect(info.first['audioRoute'], {'route': 'wired', 'type': 'wired_headphones'});
    final change = info.singleWhere((i) => i['event'] == 'audio route');
    expect(change['route'], {'route': 'bluetooth', 'type': 'a2dp', 'device': 'WH-1000XM4'});
    expect(change['n'], isA<int>());
    final r = c.report!;
    expect(r.audioRoute, const AudioRoute(RouteKind.wired, type: 'wired_headphones'));
    expect(r.bluetoothSound, isTrue, reason: 'part of it went over Bluetooth');
    expect(MeditationStore(dir).list().single.bluetoothSound, isTrue);
    expect(MeditationSummary.fromJson(r.toJson())!.audioRoute, r.audioRoute);
    expect(routes.listening, isTrue, reason: 'the screen keeps following it until the controller goes');
    c.dispose();
    expect(routes.listening, isFalse);
  });

  test('a route that does not answer in time is unknown; the session starts anyway', () async {
    final c = MeditationController(
      finder: Finder([DemoBand(DemoSignal(7))]),
      sound: SilentSound.new,
      timing: fast,
      audioRoute: _Silent(),
      silentBlock: Duration.zero,
      routeTimeout: const Duration(milliseconds: 20),
    );
    await c.start(const Duration(minutes: 1));
    expect(c.route, AudioRoute.unknown);
    await until(c, () => c.stage == Stage.report);
    expect(c.report!.bluetoothSound, isFalse);
    c.dispose();
  });
}

class _Silent implements AudioRouteSource {
  @override
  Future<AudioRoute> current() => Completer<AudioRoute>().future;
  @override
  Stream<AudioRoute> get changes => const Stream.empty();
}
