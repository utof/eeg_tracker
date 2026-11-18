// What a sound-for-states session needs from the audio engine. The real one is soloud_state_sound.dart (the Dart
// synthesis streamed into flutter_soloud); tests and a phone whose audio fails use [SilentStateSound].
import '../states/presets.dart';

abstract class StateSound {
  /// Makes [plan]'s sound at its loudness and starts it, fading in over [fadeInS] (the plan's own fade by default).
  /// Throws when the audio cannot start.
  Future<void> start(SoundPlan plan, {double? fadeInS});

  /// Fades to silence over [seconds] and stays silent (asleep, or the end of the timer); [stop] releases the device.
  void fadeOut(double seconds);

  /// Fades out over [seconds] and releases the audio device.
  Future<void> stop({double seconds = stopFadeS});

  /// Times the sound ran dry because the app fell behind (0 is right).
  int get stalls;

  /// What the engine reports about itself, for the session file.
  Map<String, Object?> info();
}

/// No sound: keeps what it was asked, for tests and as the fallback.
class SilentStateSound implements StateSound {
  SoundPlan? plan;
  double? fadeIn;
  final List<double> fades = [];
  bool started = false, stopped = false;
  bool fail = false;

  @override
  Future<void> start(SoundPlan plan, {double? fadeInS}) async {
    if (fail) throw StateError('no audio device');
    this.plan = plan;
    fadeIn = fadeInS ?? plan.fadeInS;
    started = true;
  }

  @override
  void fadeOut(double seconds) => fades.add(seconds);

  @override
  Future<void> stop({double seconds = stopFadeS}) async => stopped = true;

  @override
  int get stalls => 0;

  @override
  Map<String, Object?> info() => {'engine': 'none'};
}
