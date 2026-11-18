// When a spoken answer is over (DECISIONS row 112), pure: the microphone's level every 0.1 s in, "stop now, and why"
// out. The room's own level comes from the first 0.3 s after the question (nobody answers that fast); voice is 10 dB
// over it. The answer ends after 3 s of silence once a voice was heard, after 10 s if none was, and at 30 s in any
// case. Planning values until the owner's own recordings show how loud a drowsy answer is.
import 'dart:math' as math;

import '../feedback/features.dart' show median;

abstract final class VoiceRule {
  /// The microphone's level comes this often (s).
  static const double stepS = 0.1;

  /// Readings that set the room's level, and the extras below, in readings of [stepS].
  static const int floorN = 3;

  /// Voice: this much louder than the room (dB).
  static const double aboveDb = 10;

  /// A room quieter than this counts as this (dBFS): digital silence must not make every breath a voice.
  static const double quietestDb = -70;

  /// No voice by then: no answer (s).
  static const double firstWordS = 10;

  /// After a voice, this much silence ends the answer (s).
  static const double silenceS = 3;

  /// The longest answer (s).
  static const double capS = 30;
}

enum AnswerEnd {
  /// 3 s of silence after the voice.
  silence,

  /// 30 s.
  cap,

  /// No voice in the first 10 s (the file is kept anyway: a whisper may be in it).
  noVoice,

  /// Stop was pressed.
  stopped,

  /// The microphone did not record.
  failed,
}

int _n(double s) => (s / VoiceRule.stepS).round();

class VoiceGate {
  final List<double> _first = [];

  /// Readings so far.
  int readings = 0;

  /// The room's level (dBFS), once known.
  double? floor;

  /// Readings with a voice, and the last of them (null before the first).
  int voiced = 0;
  int? lastVoice;

  /// Seconds recorded and seconds with a voice.
  double get seconds => readings * VoiceRule.stepS;
  double get voiceSeconds => voiced * VoiceRule.stepS;
  bool get heard => lastVoice != null;

  /// One reading (dBFS, as the recorder reports it; -inf or NaN for digital silence). Returns why the answer is
  /// over, or null to keep recording.
  AnswerEnd? add(double dbfs) {
    final db = dbfs.isNaN ? VoiceRule.quietestDb : math.max(dbfs, VoiceRule.quietestDb);
    readings++;
    if (readings <= VoiceRule.floorN) {
      _first.add(db);
      floor = median(_first);
    } else {
      final f = floor!;
      if (db >= f + VoiceRule.aboveDb) {
        voiced++;
        lastVoice = readings;
      } else if (db < f) {
        floor = db; // the room got quieter
      }
    }
    if (readings >= _n(VoiceRule.capS)) return AnswerEnd.cap;
    final last = lastVoice;
    if (last == null) return readings >= _n(VoiceRule.firstWordS) ? AnswerEnd.noVoice : null;
    return readings - last >= _n(VoiceRule.silenceS) ? AnswerEnd.silence : null;
  }
}
