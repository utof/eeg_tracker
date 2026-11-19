// Sound cues during the night, the part the lucid dream cues (lucid/live_cues.dart, DECISIONS 300-303) and the memory
// cues (memory_cues/live_cues.dart, DECISIONS 500-509) share. One kind runs a night: the recorder holds one cue watch.
// They run in the night recorder's own isolate, like the drift-off detector (recorder/live_drift.dart, DECISIONS
// 182): fed each batch right after the batch is buffered for the files, and every call wrapped by the recorder in a
// guard (an exception, more than 2 % of the recorder's time or the app growing by over 700 MB switches them off for
// the night with one log line; the recording goes on).
//
// From the hour the kind's rule needs it, the cues listen to the night's one live sleep model (sleep/night_scorer.dart,
// DECISIONS 330, shared with the smart alarm) and run the shared detectors on the batches, placed on the clock as the
// drift-off detector places them (a pause over 0.5 s or a new file set is held at the last value and counts as lost).
// The rule counts seconds and epochs on the scorer's clock, so a model the alarm started earlier hands the cues the
// same epochs. Each second goes through the kind's rule; a cue it allows plays through the phone's media player
// (lucid/bell.dart), unless tonight is one of the test's silent nights: then everything is the same, the cue moment
// and its marker too, only no sound plays. Which kind of night it is never shows: not in the markers, the log, the
// night's record or the screen.
//
// The night's record says while the model runs; a process that comes back and finds it so did not end cleanly while
// the model ran, and the cues stay off for the rest of that night.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/detectors.dart';
import '../lucid/bell.dart' show CueBell;
import '../recorder/chunk_writer.dart' show Sample, unixSeconds;
import '../sleep/live_stager.dart';
import '../sleep/night_scorer.dart';
import '../sleep/night_signal.dart' show limitMicrovolts, minGapSeconds, roundHalfEven, sampleRate;
import '../sleep/report.dart' show isoLocal;

/// The night recorder's view of tonight's cues, so a test can put a broken one in.
abstract interface class CueWatch {
  /// Its name in the log ("lucid cues", "memory cues").
  String get who;

  /// One batch as it arrived; [firstOfFile] for the first batch of a new file set.
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false});

  /// The recorder's 10-second check: Lights off (unix ms) and the drift-off detector's state (its name; null when it
  /// is not running).
  void check(DateTime now, {int? lightsOffMs, String? drift});

  /// Marker texts since the last call.
  List<String> takeEvents();

  /// The cues are over for tonight (the night's limit, the arousals, the hours, or switched off): the recorder lets
  /// it go.
  bool get finished;

  /// Stops the model and frees it (after any running call).
  Future<void> close();
}

/// Makes tonight's cues when they are on, or null. Never throws past the recorder's guard: the guard catches.
typedef CueFactory = CueWatch? Function(int nightStartMs);

/// One cue a rule let play: its second, its step (dB against the evening's loudness: up for the lucid cues, down for
/// the memory cues) and its period (from 1).
class RuleCue {
  RuleCue(this.k, this.step, this.period);
  final int k, step, period;
  bool aroused = false;
}

/// A night's cue rule, stepped once a second of signal; the live stages are given as they are handed out.
abstract interface class NightRule {
  List<RuleCue> get cues;

  /// Seconds at which an arousal after a cue was seen.
  List<int> get arousals;

  /// Why the cues ended for the night, with the second.
  List<(int, String)> get stops;

  /// Why the cues are over for the night; null while they go on.
  String? get done;

  /// The cue hours start at second [k] of this rule's clock (Lights off moved them).
  void startAt(int k);

  /// Epoch [epoch] read as [stage] (W N1 N2 N3 R or gap) with top probability [conf], known at second [k].
  void stage(int epoch, String stage, double conf, int k);

  /// Second [k]: [moved] movement in it (3+ channels jumping), [jaw] jaw muscle, [burst] an eye burst became known in
  /// it, [drift] the drift-off detector's state. Returns the cue to play now, if any.
  RuleCue? second(int k, {required bool moved, required bool jaw, required bool burst, required String? drift});
}

/// One cue moment of a night: when, its step (dB against the evening's loudness), its period, the live reading that
/// allowed it, and whether an arousal followed.
class CueMoment {
  const CueMoment({
    required this.atMs,
    required this.step,
    required this.period,
    required this.confidence,
    this.aroused = false,
  });
  final int atMs, step, period;
  final double confidence;
  final bool aroused;

  Map<String, Object?> toJson() => {
    'at': isoLocal(DateTime.fromMillisecondsSinceEpoch(atMs)),
    'atMs': atMs,
    'step': step,
    'period': period,
    'confidence': (confidence * 1000).round() / 1000,
    'aroused': aroused,
  };

  static CueMoment? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['atMs'], s = j['step'], p = j['period'], c = j['confidence'];
    if (a is! int || s is! int || p is! int || c is! num) return null;
    return CueMoment(atMs: a, step: s, period: p, confidence: c.toDouble(), aroused: j['aroused'] == true);
  }
}

/// What the night's record holds about the cues, handed to the kind to save. A null list: unchanged (the rule has not
/// started in this process, so the record keeps what an earlier process saved).
typedef CueNightState = ({
  String phase,
  int cuesFromMs,
  List<CueMoment>? cues,
  List<int>? arousalsMs,
  List<(int, String)>? stops,
  bool running,
  String? off,
  Map<String, Object?>? model,
  int? mediaVolume,
});

/// The cue amplitude for a share [level] of the media volume and a [step] in dB, at most the full media volume.
double cueAmplitude(double level, int step) => math.min(1.0, level * math.pow(10, step / 20).toDouble());

String hourMinute(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// The shared engine; a kind says when it needs the model, its rule, its words, which sound plays and where its
/// record goes.
abstract class NightCues implements CueWatch, StageListener {
  /// [scorer]: the night's shared live model; [ownScorer]: the cues made it themselves and feed it.
  NightCues({
    required this.scorer,
    required bool ownScorer,
    required this.bell,
    required this.level,
    required this._cuesFromMs,
    required this._phase,
    this._running = false,
  }) : _own = ownScorer {
    scorer.join(this);
  }

  /// The live sleep model the cues listen to.
  final NightScorer scorer;
  final bool _own;
  final CueBell bell;

  /// The evening's loudness, a share of the media volume; null when none was set.
  final double? level;

  // ---- what a kind says ----

  /// The model is needed for batches from this moment (unix ms).
  int get modelFromMs;

  /// The cue hours start this long after Lights off.
  Duration get cuesAfter;

  /// The rule for tonight, its cue hours starting at second [cuesFromK] of the model's clock.
  NightRule newRule(int cuesFromK);

  /// The sound to play for [c], or null on a silent night.
  File? soundFor(RuleCue c);

  /// How the phone played the sound of the cue at [atMs] (hidden like the schedule).
  void played(int atMs, File sound, bool ok, String? error);

  /// Saves the night's record; never throws past the engine.
  void persist(CueNightState s);

  /// The marker for cue [n] (from 1), read with [confidence], at [step] dB.
  String cueLine(int n, double confidence, int step);

  /// The marker after an arousal.
  String get arousalLine;

  /// The marker when the rule ends the night's cues for [why].
  String doneLine(String why);

  /// The marker when Lights off moved the cue hours to [fromMs].
  String lightsOffLine(int fromMs);

  /// Each row (µV O1 O2 T3 T4) after the detectors had it; a second in which an eye burst became known, if any.
  int? pushRow(List<double> row) => null;

  /// The detectors are made (an eye-burst tap may go on them).
  void attachDetectors(Detectors det) {}

  /// The detectors' lists were cleared to keep the night's memory flat.
  void trimRows() {}

  // ---- state ----

  final List<String> _events = [];
  String _phase;
  int _cuesFromMs;
  bool _running;
  String? _off;

  /// The model listened to (kept after the cues let it go: the record's speed).
  LiveStager? _stager;
  NightRule? _rule;
  Detectors? _det;

  /// The detectors' first sample, a whole unix second ([_ruleUnix] + [_shiftS]).
  int? _startUnix;

  /// The rule's clock: the model's first sample, so epoch e starts at [_ruleUnix] + 30 e and second k at
  /// [_ruleUnix] + k. The same as [_startUnix] unless another listener started the model earlier.
  int _ruleUnix = 0;
  int _shiftS = 0;
  double _lastArrival = 0;
  List<double>? _lastRow;
  int _samples = 0;
  final Float32List _f32 = Float32List(4);
  final Set<int> _bursts = {};
  String? _drift;
  int _lastK = -1, _arousalsSaid = 0;
  final List<CueMoment> _moments = [];
  final List<double> _confidence = [];
  LiveMode? _modeSaid;
  Future<void>? _closing;
  int? _mediaVolume;

  String get phase => _phase;
  int get cuesFromMs => _cuesFromMs;

  /// Tonight's rule, once the model runs.
  NightRule? get nightRule => _rule;

  @override
  bool get finished => _phase == 'done' || _phase == 'off';

  /// Until the cues end, once begun whatever Lights off says later.
  @override
  bool needs(double t0Ms) => !finished && (_stager != null || t0Ms >= modelFromMs);

  /// A line for the night's markers (the kind's own, e.g. at the start).
  void say(String line) => _events.add(line);

  /// Saves the night's record now (a kind's start); never throws.
  void saveNow() => _save();

  @override
  List<String> takeEvents() {
    if (_events.isEmpty) return const [];
    final out = List<String>.of(_events);
    _events.clear();
    return out;
  }

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (finished || rows.isEmpty) return;
    if (_own) scorer.add(arrival, rows, firstOfFile: firstOfFile);
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    if (_stager == null && t0 * 1000 < modelFromMs) return;
    final start = _startUnix;
    if (start == null) {
      _begin(t0, rows.first);
      if (finished) return;
    } else if (firstOfFile || t0 - _lastArrival > minGapSeconds) {
      final want = roundHalfEven((t0 - start) * sampleRate);
      if (want > _samples) _hold(want - _samples);
    }
    _lastArrival = arr;
    for (final r in rows) {
      _push(_row(r), missing: false);
    }
  }

  /// The model's hour has come: the scorer started the model on this batch, or it already ran for another listener.
  void _begin(double t0, Sample first) {
    final s = scorer.stager, from = scorer.startUnix;
    if (s == null || from == null) {
      _turnOff('The sleep model is not running tonight, so no cues tonight.');
      return;
    }
    final whole = _wholeSecond(t0);
    _startUnix = whole;
    _ruleUnix = from;
    _shiftS = whole - from;
    _lastK = _shiftS - 1;
    _rule = newRule(_cuesFromK(from));
    final det = Detectors(onSecond: _second);
    _det = det;
    attachDetectors(det);
    _stager = s;
    _phase = 'listening';
    _running = true;
    _events.add('$who: sleep model on');
    _save();
    unawaited(_readVolume());
    final lead = roundHalfEven((t0 - whole) * sampleRate);
    final row = _row(first);
    for (var i = 0; i < lead; i++) {
      _push(row, missing: true);
    }
  }

  int _cuesFromK(int ruleUnix) => (_cuesFromMs / 1000 - ruleUnix).ceil();

  Future<void> _readVolume() async {
    try {
      _mediaVolume = (await bell.mediaVolume())?.volume;
    } catch (_) {}
  }

  List<double> _row(Sample r) {
    final f = _f32;
    f[0] = r.o1;
    f[1] = r.o2;
    f[2] = r.t3;
    f[3] = r.t4;
    return [for (var c = 0; c < 4; c++) (f[c] * 1e6).clamp(-limitMicrovolts, limitMicrovolts)]; // as the BDF clips
  }

  void _hold(int n) {
    final last = _lastRow;
    if (last == null) return;
    for (var i = 0; i < n; i++) {
      _push(last, missing: true);
    }
  }

  void _push(List<double> row, {required bool missing}) {
    _lastRow = row;
    _samples++;
    final det = _det!;
    det.push(row, missing: missing);
    final b = pushRow(row);
    if (b != null) _bursts.add(b);
    if (det.blinks.length + det.eyeMoves.length + det.bursts.length + det.movement.length > 256) {
      det.blinks.clear();
      det.eyeMoves.clear();
      det.bursts.clear();
      det.movement.clear();
      trimRows();
    }
    if (det.epochs.length > 256) det.epochs.clear();
  }

  void _second(Second s) {
    final rule = _rule;
    if (rule == null || finished) return;
    var burst = false;
    _bursts.removeWhere((k) {
      if (k > s.k) return false;
      burst = true;
      return true;
    });
    final jaw =
        s.muscleOn &&
        math.min(s.muscleX[0].isNaN ? 0.0 : s.muscleX[0], s.muscleX[1].isNaN ? 0.0 : s.muscleX[1]) >= MuscleRule.bothX;
    final k = s.k + _shiftS; // on the rule's clock
    _lastK = k;
    final cue = rule.second(k, moved: s.movement, jaw: jaw, burst: burst, drift: _drift);
    if (cue != null) _cue(cue);
    _afterRule();
  }

  @override
  void scored(LiveStage st, int epochStartMs) {
    final rule = _rule;
    if (rule == null || finished) return;
    try {
      rule.stage(st.epoch, st.stage, st.confidence, math.max(0, _lastK));
      _confidence.add(st.confidence);
      if (_confidence.length > 8) _confidence.removeAt(0);
      _afterRule();
    } catch (e) {
      _turnOff('The cue rule failed (${'$e'.split('\n').first}), so no more cues tonight.');
    }
  }

  void _cue(RuleCue c) {
    final at = (_ruleUnix + c.k) * 1000;
    final gain = cueAmplitude(level ?? 0, c.step);
    final conf = _confidence.isEmpty ? 0.0 : _confidence.last;
    _moments.add(CueMoment(atMs: at, step: c.step, period: c.period, confidence: conf));
    _events.add(cueLine(_rule!.cues.length, conf, c.step));
    final sound = soundFor(c);
    if (sound != null) unawaited(_play(at, sound, gain));
    _save();
  }

  Future<void> _play(int atMs, File sound, double gain) async {
    try {
      final ok = await bell.play(sound, gain);
      played(atMs, sound, ok, ok ? null : 'the phone did not play it');
    } catch (e) {
      try {
        played(atMs, sound, false, '$e'.split('\n').first);
      } catch (_) {}
    }
  }

  void _afterRule() {
    final rule = _rule!;
    while (_arousalsSaid < rule.arousals.length) {
      _arousalsSaid++;
      _events.add(arousalLine);
      _save();
    }
    final done = rule.done;
    if (done != null && !finished) {
      _phase = 'done';
      _events.add(doneLine(done));
      _save();
      unawaited(_freeModel());
    }
  }

  @override
  void modelChanged() {
    final s = _stager;
    if (s == null || s.mode == _modeSaid) return;
    _modeSaid = s.mode;
    if (s.mode == LiveMode.light) _events.add('$who: sleep model 1 run (slow phone)');
    _save();
  }

  @override
  void check(DateTime now, {int? lightsOffMs, String? drift}) {
    _drift = drift;
    if (finished) return;
    if (lightsOffMs != null) {
      final from = lightsOffMs + cuesAfter.inMilliseconds;
      if (from != _cuesFromMs) {
        _cuesFromMs = from;
        if (_startUnix != null) _rule!.startAt(_cuesFromK(_ruleUnix));
        _events.add(lightsOffLine(from));
        _save();
      }
    }
    final s = _stager;
    if (s != null && s.mode == LiveMode.timer) {
      _turnOff('The sleep model stopped (it failed or was too slow), so no more cues tonight.');
    }
  }

  void _turnOff(String why) {
    if (finished) return;
    _phase = 'off';
    _off = why;
    _events.add('$who off: $why');
    _save();
    unawaited(_freeModel());
  }

  /// Switches the cues off for the night ([why]: a sentence; the recorder's guard calls it).
  void off(String why) => _turnOff(why);

  /// Lets the model go: the scorer frees it unless another listener still uses it.
  Future<void> _freeModel() async {
    try {
      await scorer.leave(this);
    } catch (_) {}
    if (_stager == null) return;
    _running = false;
    _save();
  }

  @override
  Future<void> close() => _closing ??= () async {
    if (!finished) _phase = 'ended';
    await _freeModel();
    _running = false;
    _save();
  }();

  /// The night's record; never throws.
  void _save() {
    try {
      final rule = _rule;
      final s = _stager, times = s?.callTimes;
      final aroused = {
        for (final c in rule?.cues ?? const <RuleCue>[])
          if (c.aroused) _ruleUnix + c.k,
      };
      persist((
        phase: _phase,
        cuesFromMs: _cuesFromMs,
        cues: rule == null
            ? null
            : [
                for (final m in _moments)
                  CueMoment(
                    atMs: m.atMs,
                    step: m.step,
                    period: m.period,
                    confidence: m.confidence,
                    aroused: aroused.contains(m.atMs ~/ 1000),
                  ),
              ],
        arousalsMs: rule == null ? null : [for (final k in rule.arousals) (_ruleUnix + k) * 1000],
        stops: rule == null ? null : [for (final (k, why) in rule.stops) ((_ruleUnix + k) * 1000, why)],
        running: _running,
        off: _off,
        model: s == null
            ? null
            : {
                'mode': s.mode.name,
                'calls': s.calls.length,
                'median_ms': times?.median,
                'max_ms': times?.max,
                'skipped_windows': s.skipped,
              },
        mediaVolume: _mediaVolume,
      ));
    } catch (_) {}
  }

  /// `datetime.fromtimestamp(t).replace(microsecond=0)`, as the night's pass starts a night.
  static int _wholeSecond(double t) {
    var whole = t.floor();
    if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
    return whole;
  }
}
