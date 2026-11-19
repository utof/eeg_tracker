// The evening practice (DECISIONS 301), targeted lucidity reactivation's training as the home studies ran it (Konkoly
// 2021, 2024; Carr 2023): in bed, about 15 minutes. First the loudness: the cue every 3 s, from very quiet, 2 dB
// louder each time, until you tap "I hear it" (the night starts there and never goes over +6 dB). Then 4 cues with the
// words (am I dreaming? notice your body, your breathing, how this differs from waking; if it is a dream, stay calm and
// signal with the eyes), 45 s apart, then 12 cues with eyes closed at 45-90 s gaps, doing the same each time.
// Pure: a schedule and a step function; the screen runs the clock and the sound.
import 'dart:math' as math;

/// Planning values (DECISIONS 301).
abstract final class PracticeRule {
  /// Loudness: the first cue's share of the media volume, the step (dB) and the time between cues.
  static const double startGain = 0.002, stepDb = 2;
  static const int loudnessEveryS = 3;
  static const int guided = 4, guidedEveryS = 45;
  static const int unguided = 12, gapMinS = 45, gapMaxS = 90;
}

/// The words shown with each guided cue.
const String practiceWords =
    'When you hear this sound, ask yourself: am I dreaming? Look around and at your hands. Notice your body, your '
    'breathing, your thoughts, and how this moment is different from being awake. If it is a dream, stay calm and '
    'move your eyes left-right-left-right, twice.';

/// The cue's share of the media volume at loudness step [k] (from 0), capped at 1.
double loudnessGain(int k) => math.min(1.0, PracticeRule.startGain * math.pow(10, k * PracticeRule.stepDb / 20));

/// The steps of the loudness ramp until the full media volume.
int get loudnessSteps => (20 * math.log(1 / PracticeRule.startGain) / math.ln10 / PracticeRule.stepDb).ceil() + 1;

enum PracticeCueKind { guided, unguided }

/// When each practice cue plays, in seconds after the loudness step ends.
List<(int, PracticeCueKind)> practiceSchedule(math.Random r) {
  final out = <(int, PracticeCueKind)>[];
  var t = 0;
  for (var i = 0; i < PracticeRule.guided; i++) {
    out.add((t, PracticeCueKind.guided));
    t += PracticeRule.guidedEveryS;
  }
  for (var i = 0; i < PracticeRule.unguided; i++) {
    out.add((t, PracticeCueKind.unguided));
    t += PracticeRule.gapMinS + r.nextInt(PracticeRule.gapMaxS - PracticeRule.gapMinS + 1);
  }
  return out;
}

/// The practice's length after the loudness step: the last cue plus a quiet minute.
int practiceLengthS(List<(int, PracticeCueKind)> schedule) => schedule.last.$1 + 60;
