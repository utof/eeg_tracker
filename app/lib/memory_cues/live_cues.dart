// Memory cues during the night (DECISIONS 502-506), on the engine the lucid dream cues share (cues/night_cues.dart):
// in the night recorder's own isolate, behind the recorder's one guard (an exception, more than 2 % of the recorder's
// time or the app growing by over 700 MB switches them off with one log line; the recording goes on), listening to
// the night's one live sleep model (sleep/night_scorer.dart, shared with the smart alarm) from the night's start.
//
// A night joins the test only with an evening session finished in the 3 hours before it (store.dart `freshSession`):
// it gets the next number, and from the hidden schedule (plan.dart) whether it has sound and which half's sound plays.
// In the cue hours (30 minutes to 4.5 hours after Lights off) each second goes through the rule (rule.dart); a sound it
// allows plays through the phone's media player at the evening's "just heard" loudness of that sound, 3 dB under it
// and quieter after each arousal; on a silent night everything is the same, the cue moment and its marker too, only
// no sound plays. Which kind of night and which half never show: not in the markers, the log, the night's record or
// the screen.
import 'dart:io';

import '../cues/night_cues.dart';
import '../lucid/bell.dart' show CueBell;
import '../sleep/live_stager.dart';
import '../sleep/night_scorer.dart';
import 'plan.dart';
import 'rule.dart';
import 'store.dart';

class MemoryCues extends NightCues {
  MemoryCues._(
    this._arm,
    this._sound,
    this.record, {
    required this.store,
    required super.scorer,
    required super.ownScorer,
    required super.bell,
    required super.level,
    required this.cuesAfter,
    required this.cuesUntil,
  }) : super(cuesFromMs: record.cuesFromMs, phase: record.phase, running: record.running);

  /// Tonight's memory cues: null when they are off; a [NoCuesTonight] when no evening session can be cued; else the
  /// night in the test (a night restarted by Android keeps its record, number and session). [scorer]: the night's
  /// shared live model, fed by the recorder; or [model]: the cues open their own and feed it (one of the two).
  static CueWatch? open({
    required MemoryStore store,
    required int nightStartMs,
    LiveModel Function()? model,
    NightScorer? scorer,
    required CueBell bell,
    required DateTime now,
    ScaleFn scale = scaleInBackground,
    Duration slow = slowCall,
    Duration cuesAfter = MemoryRule.cuesFrom,
    Duration cuesUntil = MemoryRule.cuesUntil,
  }) {
    if ((model == null) == (scorer == null)) throw ArgumentError('a model or a shared scorer');
    final prior = store.night(nightStartMs);
    if (!store.settings().on && prior == null) return null;
    final session = prior == null ? store.freshSession(nightStartMs) : store.session(prior.session);
    if (session == null || session.levels == null) {
      return NoCuesTonight(
        'memory cues',
        'memory cues: no evening task finished in the ${sessionFreshFor.inHours} hours before this night, so no '
            'sounds tonight',
      );
    }
    final test = store.ensureTest(now);
    final record =
        prior ??
        MemoryNightRecord(
          startMs: nightStartMs,
          index: store.nextIndex(),
          session: session.id,
          cuesFromMs: nightStartMs + cuesAfter.inMilliseconds,
        );
    final sound = test.sealed.soundOf(record.index);
    store.ensureSounds();
    final w = MemoryCues._(
      test.sealed.armOf(record.index),
      sound,
      record,
      store: store,
      scorer: scorer ?? NightScorer(model: model!, scale: scale, slow: slow),
      ownScorer: scorer == null,
      bell: bell,
      level: session.levels![sound],
      cuesAfter: cuesAfter,
      cuesUntil: cuesUntil,
    );
    if (prior == null) {
      w.say(
        'memory cues on: night ${record.index + 1} of the test; sounds from ${hourMinute(record.cuesFromMs)} to '
        '${hourMinute(record.cuesFromMs + (cuesUntil - cuesAfter).inMilliseconds)}',
      );
    } else if (prior.running) {
      w.off('The app ended while the sleep model ran, so the cues stay off tonight.');
    }
    w.saveNow();
    return w;
  }

  final MemoryStore store;
  MemoryNightRecord record;
  final MemoryArm _arm;

  /// The half whose sound plays tonight (or would, on a silent night).
  final int _sound;
  @override
  final Duration cuesAfter;
  final Duration cuesUntil;

  @override
  String get who => 'memory cues';

  /// From the night's start: the model has warmed up by the cue hours.
  @override
  int get modelFromMs => record.startMs;

  @override
  NightRule newRule(int cuesFromK) =>
      SoundRule(cuesFrom: cuesFromK, cuesUntil: cuesFromK + (cuesUntil - cuesAfter).inSeconds);

  @override
  File? soundFor(RuleCue c) => _arm == MemoryArm.sound ? store.soundFiles[_sound] : null;

  @override
  void played(int atMs, File sound, bool ok, String? error) => store.addPlay(atMs, record.index, _sound, ok, error);

  @override
  String cueLine(int n, double confidence, int step) =>
      'memory cue $n (N2/N3 ${confidence.toStringAsFixed(2)}, $step dB)';

  @override
  String get arousalLine => 'memory cues: arousal after a sound; 3 dB quieter, 5 minutes without sounds';

  @override
  String doneLine(String why) => switch (why) {
    'per night' => 'memory cues: done for tonight (${MemoryRule.perNight} sounds)',
    'three arousals' => 'memory cues: done for tonight (${MemoryRule.stopAfterArousals} arousals)',
    _ => 'memory cues: done for tonight (the cue hours are over)',
  };

  @override
  String lightsOffLine(int fromMs) => 'memory cues from ${hourMinute(fromMs)} (30 min after Lights off)';

  @override
  void persist(CueNightState s) {
    try {
      record = record.copyWith(
        phase: s.phase,
        cuesFromMs: s.cuesFromMs,
        cues: s.cues,
        arousals: s.arousalsMs,
        stops: s.stops,
        running: s.running,
        off: s.off,
        model: s.model,
        mediaVolume: s.mediaVolume,
      );
      store.saveNight(record);
    } catch (_) {}
  }
}

/// Tonight's memory cues in the night recorder's isolate: the night's shared live model ([scorer]; or [model] for a
/// model of their own), the phone's media player for the sound, the files beside the recordings.
CueFactory memoryCuesFor(
  String recordingsDir, {
  LiveModel Function()? model,
  NightScorer? scorer,
  required CueBell bell,
}) => (nightStartMs) {
  final store = MemoryStore(memoryDirFor(recordingsDir)); // the sound files are written only for a night in the test
  return MemoryCues.open(
    store: store,
    nightStartMs: nightStartMs,
    model: model,
    scorer: scorer,
    bell: bell,
    now: DateTime.now(),
  );
};
