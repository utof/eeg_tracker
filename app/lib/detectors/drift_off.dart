// The drift-off detector (DECISIONS 62), shared by the meditation's "drifting" state and, later, the sleep-sound
// auto-stop and the dream catcher. A line-by-line port of DriftOff in analysis/eeg_detectors.py.
//
// "Lights off" starts it. The first 60 clean seconds without a blink give the eyes-closed alpha baseline (O1/O2).
// Then each 30 s epoch counted from lights off is faded (alpha under half the baseline in over half of its clean
// seconds) or not. Two faded epochs in a row: drowsy; six: probably asleep (the onset is the first of them);
// two unfaded: awake again. Movement (3 s) or open eyes (2 blinks, before sleep) make an epoch unfaded; an epoch
// with under 10 clean seconds is skipped. On the owner's two recorded sleep onsets it agreed with AnySleep within
// 0.5 min (docs/detectors.md). Both timers back it up: the sound stops 45 min after lights off whatever it says,
// and the dream catcher asks at a random moment inside the usual time to fall asleep if drowsy never comes.
// It cannot tell open eyes in the dark from sleep when no blink shows; the timers make every action safe.
import 'dart:math' as math;

import '../feedback/features.dart' show median, percentile;
import 'detectors.dart' show epochS;

abstract final class Drift {
  static const int baselineS = 60, minCleanS = 10, drowsyEpochs = 2, asleepEpochs = 6, wakeEpochs = 2;
  static const int moveBreakS = 3, eyesOpenBlinks = 2, semWindowS = 10;
  static const double fadeX = 0.5, fadeShare = 0.5, semX = 4;
  static const int soundFadeS = 150, soundCapS = 45 * 60;

  /// The usual time to fall asleep (min) until there are 3 own nights (planning value).
  static const List<double> dreamWindowMin = [10, 20];
}

enum DriftState { baseline, awake, drowsy, asleep }

class DriftEpoch {
  const DriftEpoch(this.index, this.start, this.cleanS, this.fadedShare, this.faded, this.rolls, this.blinks, this.state);

  /// Epoch number from lights off, and its first second (counted like the input's seconds).
  final int index;
  final int start;
  final int cleanS;

  /// Share of clean seconds with alpha under half the baseline; null when skipped.
  final double? fadedShare;

  /// Null: skipped (before the baseline, or under 10 clean seconds).
  final bool? faded;

  /// Slow eye rolls on T3-T4 (reported only: on the recorded nights they came as often before sleep as after).
  final bool rolls;
  final int blinks;

  /// The state after this epoch.
  final DriftState state;
}

class DriftOff {
  /// [lightsOff]: the second (counted like the seconds that will be fed) when the person closed their eyes.
  DriftOff(this.lightsOff);

  final int lightsOff;
  double? baselineAlpha;
  double? baselineSem;

  /// The second the 60 clean seconds were complete.
  int? baselineDone;
  final List<DriftEpoch> epochs = [];

  /// The second the app first knew "drowsy".
  int? drowsyAt;

  /// The first second of the first "probably asleep" run, and the second the app knew it.
  int? onset;
  int? asleepAt;

  /// Every (onset, known) pair, including after waking; seconds when "awake again" was known.
  final List<(int, int)> onsets = [];
  final List<int> wakes = [];
  DriftState state = DriftState.baseline;

  final List<double> _baseA = [], _baseS = [], _sem = [];
  final List<({double alpha, bool clean, bool movement, double sem10, int blinks})> _ep = [];
  int _run = 0, _unfaded = 0, _runStart = 0;

  /// Second [k] (k >= lightsOff): back alpha (µV²), whether it was clean, movement, T3-T4 slow-roll power (µV²)
  /// and the blinks found in it.
  DriftState second(int k, double alpha, bool clean, bool movement, double sem, int blinks) {
    if (!clean || movement) {
      _sem.clear();
    } else {
      _sem.add(sem);
      if (_sem.length > Drift.semWindowS) _sem.removeAt(0);
    }
    final sem10 = _sem.length == Drift.semWindowS ? _sem.fold(0.0, (a, b) => a + b) / _sem.length : double.nan;
    if (baselineAlpha == null && clean && !movement && blinks == 0) {
      _baseA.add(alpha);
      _baseS.add(sem);
      if (_baseA.length == Drift.baselineS) {
        baselineAlpha = median(_baseA);
        baselineSem = median(_baseS);
        baselineDone = k;
        state = DriftState.awake;
      }
    }
    _ep.add((alpha: alpha, clean: clean, movement: movement, sem10: sem10, blinks: blinks));
    if (_ep.length == epochS) {
      _endEpoch(k - epochS + 1);
      _ep.clear();
    }
    return state;
  }

  void _endEpoch(int start) {
    final idx = (start - lightsOff) ~/ epochS, base = baselineAlpha, bs = baselineSem;
    final clean = [
      for (final e in _ep)
        if (e.clean) e.alpha,
    ];
    final moved = _ep.where((e) => e.movement).length;
    final blinked = _ep.fold(0, (a, e) => a + e.blinks);
    final rolls = bs != null && _ep.any((e) => !e.sem10.isNaN && e.sem10 > Drift.semX * bs);
    if (base == null || clean.length < Drift.minCleanS) {
      epochs.add(DriftEpoch(idx, start, clean.length, null, null, rolls, blinked, state));
      return;
    }
    final share = clean.where((a) => a < Drift.fadeX * base).length / clean.length;
    final eyesOpen = blinked >= Drift.eyesOpenBlinks && state != DriftState.asleep;
    final faded = share > Drift.fadeShare && moved < Drift.moveBreakS && !eyesOpen;
    final end = start + epochS - 1;
    if (faded) {
      _run++;
      _unfaded = 0;
      if (_run == 1) _runStart = start;
      if (state == DriftState.awake && _run >= Drift.drowsyEpochs) {
        state = DriftState.drowsy;
        drowsyAt ??= end;
      }
      if (state == DriftState.drowsy && _run >= Drift.asleepEpochs) {
        state = DriftState.asleep;
        onsets.add((_runStart, end));
        if (onset == null) {
          onset = _runStart;
          asleepAt = end;
        }
      }
    } else {
      _run = 0;
      _unfaded++;
      if (state == DriftState.drowsy) {
        state = DriftState.awake;
      } else if (state == DriftState.asleep && _unfaded >= Drift.wakeEpochs) {
        state = DriftState.awake;
        wakes.add(end);
      }
    }
    epochs.add(DriftEpoch(idx, start, clean.length, share, faded, rolls, blinked, state));
  }

  /// Both timers (seconds after lights off), for the sleep-sound auto-stop and the dream catcher.
  DriftTimers timers(List<double> earlierLatenciesMin, double u) => driftTimers(this, earlierLatenciesMin, u);
}

class DriftTimers {
  const DriftTimers(this.soundFadeFrom, this.soundOffAt, this.dreamCueAt);

  /// Seconds after lights off: start fading sleep sounds; sound silent; the dream catcher asks.
  final int soundFadeFrom;
  final int soundOffAt;
  final int dreamCueAt;
}

/// Sound: fade over 2.5 min once probably asleep, silent by 45 min after lights off at the latest. Dream catcher:
/// when drowsy is known, or, if that never comes, at a random moment ([u] in 0..1) inside the usual time to fall
/// asleep (the middle half of earlier onset latencies once there are 3, else 10-20 min).
DriftTimers driftTimers(DriftOff d, List<double> earlierLatenciesMin, double u) {
  final fallback = dreamFallbackS(earlierLatenciesMin, u);
  var fade = Drift.soundCapS - Drift.soundFadeS;
  final asleep = d.asleepAt, drowsy = d.drowsyAt;
  if (asleep != null) fade = math.min(fade, asleep - d.lightsOff + 1);
  var cue = fallback;
  if (drowsy != null) cue = math.min(cue, drowsy - d.lightsOff + 1);
  return DriftTimers(fade, math.min(Drift.soundCapS, fade + Drift.soundFadeS), cue);
}

/// The dream catcher's timer (seconds after lights off): a random moment ([u] in 0..1) inside the usual time to fall
/// asleep: the middle half of [earlierLatenciesMin] once there are 3, else [Drift.dreamWindowMin].
int dreamFallbackS(List<double> earlierLatenciesMin, double u) {
  if (!(u >= 0 && u <= 1)) throw ArgumentError.value(u, 'u', 'must be in 0..1');
  var lo = Drift.dreamWindowMin[0], hi = Drift.dreamWindowMin[1];
  if (earlierLatenciesMin.length >= 3) {
    lo = percentile(earlierLatenciesMin, 0.25);
    hi = percentile(earlierLatenciesMin, 0.75);
  }
  return ((lo + (hi - lo) * u) * 60 + 0.5).floor();
}
