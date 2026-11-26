// A work session the headband watcher starts (DECISIONS 604): the app's work page opens and starts at once. Silent
// unless "Chime in automatic work sessions" is on (a sound needs your say-so; the hints still show on the screen and
// the lock-screen card). It has an end only under the battery guard's stopping rule, which is off (the guard only
// warns: BatteryRule.onlyWarns, DECISIONS 1010).
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

/// Who marked the work span of a session on the recording: the headband watcher's start is the app's guess
/// (`auto_start`, the stop sheet still asks and no truth row is made from it), your own start is `owner_button`
/// (DECISIONS 1131).
String workSpanSource(AutoWorkStart? auto) => auto == null ? 'owner_button' : 'auto_start';
