// When a sound-for-states session fades and goes silent (ROADMAP row 18, DECISIONS rows 88 and 131). Pure, in whole
// seconds after "lights off": the start of the quiet minute with the headband, the start of the sound without it.
//   every state:  the sound plays for the chosen minutes, the last [SoundPlan.fadeOutS] of them fading out;
//   fall asleep:  also fades over 2.5 min from the second the drift-off detector knew "probably asleep", and is
//                 silent 45 minutes after lights off whatever it says (the same rule as driftTimers in
//                 detectors/drift_off.dart, which a test holds this to).
// Once the sound is fading it never comes back, even if the detector later says "awake again".
import 'dart:math' as math;

import '../detectors/drift_off.dart' show Drift;
import 'presets.dart';

/// Why the sound stops: the chosen minutes ran out, the 45-minute cap, or you were probably asleep.
enum StopWhy { time, cap, asleep }

class SoundStop {
  const SoundStop(this.fadeFromS, this.offAtS, this.why);

  /// Seconds after lights off: the fade starts; the sound is silent.
  final int fadeFromS;
  final int offAtS;
  final StopWhy why;
}

/// The stop for [plan] whose sound started [soundStartS] after lights off; [asleepAtS]: the second the drift-off
/// detector knew "probably asleep" (null if it has not).
SoundStop soundStop(SoundPlan plan, {required int soundStartS, int? asleepAtS}) {
  final out = plan.fadeOutS.round();
  var end = soundStartS + plan.minutes * 60;
  var why = StopWhy.time;
  if (plan.state != SoundState.asleep) return SoundStop(end - out, end, why);
  if (end >= Drift.soundCapS) {
    end = Drift.soundCapS;
    why = StopWhy.cap;
  }
  var fade = end - out;
  if (asleepAtS != null && asleepAtS + 1 < fade) {
    fade = asleepAtS + 1;
    why = StopWhy.asleep;
  }
  return SoundStop(fade, math.min(end, fade + out), why);
}
