// What a training session needs from its sound, for both kinds: one control step at a time (training/control.dart),
// so a live session and a replay drive the sound the same way. Meditation wraps the existing rain-and-drone engine
// (feedback_sound.dart); alpha-theta has its own stream-and-ocean engine (alpha_theta_sound.dart).
import '../feedback/mapping.dart';
import '../training/control.dart';
import 'feedback_sound.dart';

abstract class SessionSound {
  /// Starts the engine with the bed silent. Throws when the audio cannot start.
  Future<void> start();

  /// The bed fades in or out; rewards and cues sound either way.
  void bed({required bool on});

  /// One analysis step: the bed setting, the roughness, a reward.
  void play(Control c);

  /// The soft calibration cue ("close your eyes", "the sound begins", "session over").
  void cue();

  /// A soft rising cue that draws you back from sleep (alpha-theta's sleep guard).
  void wake();

  /// Fades out and releases the audio device.
  Future<void> stop();

  Map<String, Object?> info();
}

/// The meditation engine behind the common interface: the control's level is the bed's calm.
class MeditationSound implements SessionSound {
  MeditationSound(this.inner);
  final FeedbackSound inner;

  @override
  Future<void> start() => inner.start();
  @override
  void bed({required bool on}) => inner.bed(on: on);
  @override
  void play(Control c) {
    inner.glide(Targets.layers(c.level, c.rough, bellsAllowed: !c.gated, neutral: c.gated));
    if (c.reward == 'bell') inner.bell();
  }

  @override
  void cue() => inner.cue();
  @override
  void wake() => inner.cue();
  @override
  Future<void> stop() => inner.stop();
  @override
  Map<String, Object?> info() => inner.info();
}

/// No sound: keeps counts, for tests and as the fallback when the audio engine fails.
class SilentSessionSound implements SessionSound {
  final Map<String, int> rewards = {};
  int cues = 0, wakes = 0, plays = 0;
  bool? bedOn;
  bool started = false, stopped = false;
  Control? last;

  @override
  Future<void> start() async => started = true;
  @override
  void bed({required bool on}) => bedOn = on;
  @override
  void play(Control c) {
    plays++;
    last = c;
    final r = c.reward;
    if (r != null) rewards[r] = (rewards[r] ?? 0) + 1;
  }

  @override
  void cue() => cues++;
  @override
  void wake() => wakes++;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Map<String, Object?> info() => {'engine': 'none'};
}
