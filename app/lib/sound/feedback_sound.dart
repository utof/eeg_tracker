// What the meditation needs from a sound engine. The real one is soloud_sound.dart (flutter_soloud); tests and
// a phone whose audio fails use [SilentSound], so the session itself never depends on audio working.
import '../feedback/mapping.dart';

abstract class FeedbackSound {
  /// Starts the engine with the bed silent (calibration is silent). Throws when the audio cannot start.
  Future<void> start();

  /// The bed (rain, wind, drone) fades in or out over about a second; bells and cues sound either way.
  void bed({required bool on});

  /// New settings from the core, once per analysis step; the engine glides there on the audio thread.
  void glide(Targets target);

  /// One reward bell.
  void bell();

  /// The soft calibration cue ("close your eyes", "calibration done", "session over").
  void cue();

  /// Fades out and releases the audio device.
  Future<void> stop();

  /// What the engine reports about itself (buffer, delays), for the session log.
  Map<String, Object?> info();
}

/// No sound: keeps a count, for tests and as the fallback when the audio engine fails.
class SilentSound implements FeedbackSound {
  int bells = 0;
  int cues = 0;
  int glides = 0;
  bool? bedOn;
  bool started = false;
  bool stopped = false;
  Targets? last;

  @override
  Future<void> start() async => started = true;

  @override
  void bed({required bool on}) => bedOn = on;

  @override
  void glide(Targets target) {
    glides++;
    last = target;
  }

  @override
  void bell() => bells++;

  @override
  void cue() => cues++;

  @override
  Future<void> stop() async => stopped = true;

  @override
  Map<String, Object?> info() => {'engine': 'none'};
}
