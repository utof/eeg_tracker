// Where the phone's sound goes now: the speaker, wired headphones, Bluetooth (DECISIONS 424). Shared by every
// feedback session (meditation now; sound for states can use it too). Android answers over a small channel
// (android/.../AudioRoute.kt): from Android 13 the device media plays on, before that the connected output Android
// prefers for media. Nothing here measures a delay: the warning uses the research's numbers (research A, pass 2):
//   - classic Bluetooth headphones: 308-369 ms on average by codec, 244 ms on a Pixel to 484 ms on a Huawei
//     (SoundGuys), most of it buffering inside the headset (Oboe's note); Android counts it only when the headset
//     reports it;
//   - LE Audio: makers claim about 30-80 ms (reference hardware 31-46 ms), never measured independently on phones;
//   - wired or the speaker with Android's low-latency path: 45 ms or less (Android NDK);
//   - the one direct test of feedback delay: 244 ms trained best, at 744 ms nothing lasting remained
//     (Belinskaia 2020).
import 'dart:async';

import 'package:flutter/services.dart';

enum RouteKind { speaker, wired, bluetooth, bluetoothLe, other, unknown }

class AudioRoute {
  const AudioRoute(this.kind, {this.type = '', this.device = ''});

  static const AudioRoute unknown = AudioRoute(RouteKind.unknown);

  final RouteKind kind;

  /// Android's device type in words ('a2dp', 'ble_headset', 'wired_headphones', 'speaker', ...); '' when unknown.
  final String type;

  /// The name Android gives the device (the headphones' name; the phone's model for its speaker); '' when none.
  final String device;

  /// The sound goes over Bluetooth, classic or LE Audio: it comes late.
  bool get bluetooth => kind == RouteKind.bluetooth || kind == RouteKind.bluetoothLe;

  Map<String, Object?> toJson() => {
    'route': kind.name,
    if (type.isNotEmpty) 'type': type,
    if (device.isNotEmpty) 'device': device,
  };

  /// The phone's map (or a saved one) read leniently: anything that is not a known kind is unknown.
  static AudioRoute fromMap(Object? m) {
    if (m is! Map) return unknown;
    final kind = RouteKind.values.where((k) => k.name == m['route']).firstOrNull ?? RouteKind.unknown;
    String text(Object? v) => v is String ? v : '';
    return AudioRoute(kind, type: text(m['type']), device: text(m['device']));
  }

  @override
  bool operator ==(Object other) =>
      other is AudioRoute && other.kind == kind && other.type == type && other.device == device;

  @override
  int get hashCode => Object.hash(kind, type, device);

  @override
  String toString() => 'AudioRoute(${kind.name}, $type, $device)';
}

/// What the screen says about the route before and during a feedback session; null when nothing needs saying.
String? routeWarning(AudioRoute r) {
  final name = r.device.isEmpty ? '' : ' (${r.device})';
  return switch (r.kind) {
    RouteKind.bluetooth =>
      'Sound goes to Bluetooth headphones$name. Bluetooth makes it about 0.25-0.5 s late, which weakens the '
          'feedback. Wired headphones or the phone\'s speaker are better. You can still start.',
    RouteKind.bluetoothLe =>
      'Sound goes to Bluetooth LE headphones$name. Their makers claim 0.03-0.08 s of delay, not measured on phones; '
          'ordinary Bluetooth is 0.25-0.5 s late. Wired headphones or the phone\'s speaker are surer. You can still '
          'start.',
    _ => null,
  };
}

/// The route in plain words, without a sentence around it: "the phone's speaker", "wired headphones",
/// "Bluetooth headphones (WH-1000XM4)".
String routeWords(AudioRoute r) {
  final device = r.device.isEmpty ? '' : ' (${r.device})';
  return switch (r.kind) {
    RouteKind.speaker => 'the phone\'s speaker',
    RouteKind.wired => 'wired headphones$device',
    RouteKind.bluetooth => 'Bluetooth headphones$device',
    RouteKind.bluetoothLe => 'Bluetooth LE headphones$device',
    RouteKind.other => 'another output$device',
    RouteKind.unknown => 'not known',
  };
}

/// Where the sound goes, in plain words, for sound for states (DECISIONS 470): its sounds are not feedback, so a
/// Bluetooth delay changes nothing there. What matters is the beat: binaural beats need a different tone in each ear,
/// so they do nothing on the phone's speaker ([warn]: that case only). Pulsed noise and isochronic tones carry the
/// pulse in the sound and work anywhere.
({String text, bool warn}) stateRouteNote(AudioRoute r, {required bool binaural}) {
  switch (r.kind) {
    case RouteKind.speaker:
      return binaural
          ? (
              text:
                  'Sound plays from the phone\'s speaker. A binaural beat needs a different tone in each ear, so on the '
                  'speaker you will hear no beat. Put stereo headphones on, or choose pulsed noise or isochronic tones.',
              warn: true,
            )
          : (text: 'Sound plays from the phone\'s speaker.', warn: false);
    case RouteKind.wired:
    case RouteKind.other:
      return (text: 'Sound plays to ${routeWords(r)}.', warn: false);
    case RouteKind.bluetooth:
    case RouteKind.bluetoothLe:
      return (
        text:
            'Sound plays to ${routeWords(r)}. These sounds are not feedback, so a Bluetooth delay does not matter '
            'here.',
        warn: false,
      );
    case RouteKind.unknown:
      return (
        text: binaural
            ? 'The phone did not say where the sound goes. A binaural beat needs stereo headphones: on a speaker you '
                  'will hear no beat.'
            : 'The phone did not say where the sound goes.',
        warn: false,
      );
  }
}

abstract class AudioRouteSource {
  /// The route now; [AudioRoute.unknown] when the phone cannot say.
  Future<AudioRoute> current();

  /// The route whenever it changes, while listened to.
  Stream<AudioRoute> get changes;
}

/// Android's answer over "eeg_tracker/audio_route".
class PhoneAudioRoute implements AudioRouteSource {
  static const MethodChannel _method = MethodChannel('eeg_tracker/audio_route');
  static const EventChannel _events = EventChannel('eeg_tracker/audio_route/changes');

  @override
  Future<AudioRoute> current() async {
    try {
      return AudioRoute.fromMap(await _method.invokeMethod<Object?>('current'));
    } on PlatformException {
      return AudioRoute.unknown;
    } on MissingPluginException {
      return AudioRoute.unknown;
    }
  }

  @override
  Stream<AudioRoute> get changes => _events
      .receiveBroadcastStream()
      .map(AudioRoute.fromMap)
      .handleError((Object _) {}, test: (e) => e is PlatformException || e is MissingPluginException);
}

/// A route that changes only when told: for tests, and wherever no phone is behind it.
class FixedAudioRoute implements AudioRouteSource {
  FixedAudioRoute([this._route = AudioRoute.unknown]);

  AudioRoute _route;
  final StreamController<AudioRoute> _changes = StreamController<AudioRoute>.broadcast();

  /// Someone follows the changes now.
  bool get listening => _changes.hasListener;

  void set(AudioRoute r) {
    _route = r;
    _changes.add(r);
  }

  @override
  Future<AudioRoute> current() async => _route;

  @override
  Stream<AudioRoute> get changes => _changes.stream;
}
