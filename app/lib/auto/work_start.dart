// A work session the headband watcher starts (DECISIONS 604): the app's work page opens and starts at once. Silent
// unless "Chime in automatic work sessions" is on (a sound needs your say-so; the hints still show on the screen and
// the lock-screen card), and it stops itself when the battery guard's limit is reached, so tonight's charge is kept.
import '../sound/work_sound.dart';

class AutoWorkStart {
  const AutoWorkStart({this.quiet = true, this.limit});
  final bool quiet;

  /// The session stops itself after this long; null: no limit.
  final Duration? limit;
}

/// The work session's sounds without the hint's chime (the eyes-closed minute's cues stay: that minute is chosen by
/// hand only).
class QuietWorkSound implements WorkSound {
  QuietWorkSound(this.inner);
  final WorkSound inner;

  @override
  Future<void> chime() async {}

  @override
  Future<void> cue({required bool close}) => inner.cue(close: close);

  @override
  Future<void> stop() => inner.stop();
}
