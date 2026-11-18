// What the nap coach needs from the phone's sound: only the wake cue (alpha-theta's three rising notes) at a chosen
// volume. The real one is flutter_soloud (sound/nap_sound.dart); tests use [SilentNapSound].
abstract class NapSound {
  /// Starts the engine (at Lights off, so a failure shows before you lie down). Throws when the audio cannot start.
  Future<void> start();

  /// The volume of the first, quietest cue (0..1, against the phone's media volume).
  double get firstVolume;

  /// Plays the wake cue once at [volume] (0..1).
  void wake(double volume);

  /// Fades out and releases the audio device.
  Future<void> stop();

  Map<String, Object?> info();
}

/// No sound: counts the cues, for tests.
class SilentNapSound implements NapSound {
  final List<double> cues = [];
  bool started = false, stopped = false;
  Object? failStart;

  @override
  double get firstVolume => 0.175;

  @override
  Future<void> start() async {
    if (failStart != null) throw failStart!;
    started = true;
  }

  @override
  void wake(double volume) => cues.add(volume);

  @override
  Future<void> stop() async => stopped = true;

  @override
  Map<String, Object?> info() => {'engine': 'none'};
}
