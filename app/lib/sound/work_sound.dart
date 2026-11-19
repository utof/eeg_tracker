// The work session's sounds (DECISIONS 444): a soft falling two-note chime with each break hint, and the eyes-closed
// minute's two cues. Plain Dart, so tests and laptop tools run without the sound engine; the real one is
// soloud_work_sound.dart. Never throws: a hint without sound is still a hint on screen and in the notification.
abstract interface class WorkSound {
  /// The break hint's chime.
  Future<void> chime();

  /// Close your eyes (low) / open them (higher), for the optional eyes-closed minute.
  Future<void> cue({required bool close});

  /// Lets the engine go (end of the session).
  Future<void> stop();
}

/// No sound: keeps what it was asked, for tests.
class SilentWorkSound implements WorkSound {
  final List<String> played = [];

  @override
  Future<void> chime() async => played.add('chime');

  @override
  Future<void> cue({required bool close}) async => played.add(close ? 'close' : 'open');

  @override
  Future<void> stop() async => played.add('stop');
}
