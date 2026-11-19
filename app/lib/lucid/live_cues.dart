// Lucid dream cues during the night (DECISIONS 300-303). The engine they share with the memory cues
// (cues/night_cues.dart) runs them in the night recorder's own isolate, like the drift-off detector
// (recorder/live_drift.dart, DECISIONS 182): fed each batch right after the batch is buffered for the files, and every
// call wrapped by the recorder in a guard (an exception, more than 2 % of the recorder's time or the app growing by
// over 700 MB switches them off for the night with one log line; the recording goes on).
//
// From an hour before the cue hours (the second half of the night: 4.5 h after Lights off, or the night's first
// sample) it listens to the nap coach's live sleep model (sleep/live_stager.dart) and runs the shared detectors on the
// batches, placed on the clock as the drift-off detector places them (a pause over 0.5 s or a new file set is held at
// the last value and counts as lost). The model is the night's one scorer (sleep/night_scorer.dart, DECISIONS 330),
// shared with the smart alarm when it runs too; the rule counts seconds and epochs on the scorer's clock, so a model
// the alarm started earlier hands the cues the same epochs. Each second goes through the rule (rule.dart); a cue it
// allows plays through the phone's media player (bell.dart), unless tonight is one of the test's silent nights: then
// everything is the same, the cue moment and its marker too, only no sound plays (plan.dart). Which kind of night it
// is never shows: not in the markers, the log, the night's record or the screen.
//
// The night's record (store.dart `LucidNightRecord`) says while the model runs; a process that comes back and finds
// it so did not end cleanly while the model ran, and the cues stay off for the rest of that night.
import 'dart:io';

import '../cues/night_cues.dart';
import '../detectors/detectors.dart' show Detectors;
import '../sleep/live_stager.dart';
import '../sleep/night_scorer.dart';
import 'bell.dart';
import 'plan.dart';
import 'rule.dart';
import 'store.dart';

export '../cues/night_cues.dart' show CueFactory, CueWatch;

class LiveCues extends NightCues {
  LiveCues._(
    this._arm,
    this.record, {
    required this.store,
    required super.scorer,
    required super.ownScorer,
    required super.bell,
    required super.level,
    required this.cuesAfter,
    required this.modelBefore,
  }) : super(cuesFromMs: record.cuesFromMs, phase: record.phase, running: record.running);

  /// Tonight's cues, or null when they are off. Reads the settings, freezes the test on its first night, and gives the
  /// night its number (a night restarted by Android keeps its record and number). [scorer]: the night's shared live
  /// model, fed by the recorder; or [model]: the cues open their own and feed it (one of the two).
  static LiveCues? open({
    required LucidStore store,
    required int nightStartMs,
    LiveModel Function()? model,
    NightScorer? scorer,
    required CueBell bell,
    required DateTime now,
    ScaleFn scale = scaleInBackground,
    Duration slow = slowCall,
    Duration cuesAfter = LucidRule.cuesFrom,
    Duration modelBefore = LucidRule.modelBefore,
  }) {
    if ((model == null) == (scorer == null)) throw ArgumentError('a model or a shared scorer');
    final settings = store.settings();
    final prior = store.night(nightStartMs);
    if (!settings.on && prior == null) return null;
    final test = store.ensureTest(now);
    final record =
        prior ??
        LucidNightRecord(
          startMs: nightStartMs,
          index: store.nextIndex(),
          cuesFromMs: nightStartMs + cuesAfter.inMilliseconds,
          level: settings.level,
        );
    final w = LiveCues._(
      test.sealed.armOf(record.index),
      record,
      store: store,
      scorer: scorer ?? NightScorer(model: model!, scale: scale, slow: slow),
      ownScorer: scorer == null,
      bell: bell,
      level: settings.level,
      cuesAfter: cuesAfter,
      modelBefore: modelBefore,
    );
    if (prior == null) {
      w.say(
        'lucid cues on: night ${record.index + 1} of the test; cues from ${hourMinute(record.cuesFromMs)}, the sleep '
        'model from ${hourMinute(record.cuesFromMs - modelBefore.inMilliseconds)}',
      );
      if (settings.level == null) w.off('No loudness is set yet: do the evening practice first.');
    } else if (prior.running) {
      w.off('The app ended while the sleep model ran, so the cues stay off tonight.');
    }
    w.saveNow();
    return w;
  }

  final LucidStore store;
  LucidNightRecord record;
  final NightArm _arm;
  @override
  final Duration cuesAfter;
  final Duration modelBefore;
  EyeBursts? _eyes;

  @override
  String get who => 'lucid cues';

  @override
  int get modelFromMs => cuesFromMs - modelBefore.inMilliseconds;

  /// Tonight's rule, once the model runs (tests).
  CueRule? get rule => nightRule as CueRule?;

  @override
  NightRule newRule(int cuesFromK) => CueRule(cuesFrom: cuesFromK);

  @override
  void attachDetectors(Detectors det) {
    final eyes = EyeBursts();
    _eyes = eyes;
    det.tap = eyes;
  }

  @override
  int? pushRow(List<double> row) => _eyes?.push(row);

  @override
  void trimRows() => _eyes?.trim();

  @override
  File? soundFor(RuleCue c) => _arm == NightArm.cue ? store.cueWav : null;

  @override
  void played(int atMs, File sound, bool ok, String? error) => store.addPlay(atMs, record.index, ok, error);

  @override
  String cueLine(int n, double confidence, int step) =>
      'lucid cue $n (dream sleep ${confidence.toStringAsFixed(2)}, +$step dB)';

  @override
  String get arousalLine => 'lucid cues: arousal after a cue; 3 dB quieter, 5 minutes without cues';

  @override
  String doneLine(String why) => why == 'per night'
      ? 'lucid cues: done for tonight (${LucidRule.perNight} cues)'
      : 'lucid cues: done for tonight (${LucidRule.stopAfterArousals} arousals)';

  @override
  String lightsOffLine(int fromMs) => 'lucid cues from ${hourMinute(fromMs)} (4.5 h after Lights off)';

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

/// Tonight's cues in the night recorder's isolate: the night's shared live model ([scorer]: AnySleep's runs on ONNX,
/// as the nap coach and the smart alarm open them; or [model] for a model of their own), the phone's media player for
/// the sound, the files beside the recordings.
CueFactory lucidCuesFor(
  String recordingsDir, {
  LiveModel Function()? model,
  NightScorer? scorer,
  required CueBell bell,
}) => (nightStartMs) {
  final store = LucidStore(lucidDirFor(recordingsDir));
  final cues = LiveCues.open(
    store: store,
    nightStartMs: nightStartMs,
    model: model,
    scorer: scorer,
    bell: bell,
    now: DateTime.now(),
  );
  if (cues != null) ensureCueWav(store.cueWav); // only for a night with the cues on: no folder otherwise
  return cues;
};
