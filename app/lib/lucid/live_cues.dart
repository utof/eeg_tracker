// Lucid dream cues during the night (DECISIONS 300-303). They run in the night recorder's own isolate, like the
// drift-off detector (recorder/live_drift.dart, DECISIONS 182): fed each batch right after the batch is buffered for
// the files, and every call wrapped by the recorder in a guard (an exception, more than 2 % of the recorder's time
// or the app growing by over 700 MB switches them off for the night with one log line; the recording goes on).
//
// From an hour before the cue hours (the second half of the night: 4.5 h after Lights off, or the night's first
// sample) it runs the nap coach's live sleep model (sleep/live_stager.dart) and the shared detectors on the batches,
// placed on the clock as the drift-off detector places them (a pause over 0.5 s or a new file set is held at the last
// value and counts as lost). Each second goes through the rule (rule.dart); a cue it allows plays through the phone's
// media player (bell.dart), unless tonight is one of the test's silent nights: then everything is the same, the cue
// moment and its marker too, only no sound plays (plan.dart). Which kind of night it is never shows: not in the
// markers, the log, the night's record or the screen.
//
// The night's record (store.dart `LucidNightRecord`) says while the model runs; a process that comes back and finds
// it so did not end cleanly while the model ran, and the cues stay off for the rest of that night.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/detectors.dart';
import '../recorder/chunk_writer.dart' show Sample, unixSeconds;
import '../sleep/live_stager.dart';
import '../sleep/night_signal.dart' show limitMicrovolts, minGapSeconds, roundHalfEven, sampleRate;
import 'bell.dart';
import 'plan.dart';
import 'rule.dart';
import 'store.dart';

/// The night recorder's view of the lucid cues, so a test can put a broken one in.
abstract interface class CueWatch {
  /// One batch as it arrived; [firstOfFile] for the first batch of a new file set.
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false});

  /// The recorder's 10-second check: Lights off (unix ms) and the drift-off detector's state (its name; null when it
  /// is not running).
  void check(DateTime now, {int? lightsOffMs, String? drift});

  /// Marker texts since the last call.
  List<String> takeEvents();

  /// The cues are over for tonight (the night's limit, three arousals, or switched off): the recorder lets it go.
  bool get finished;

  /// Stops the model and frees it (after any running call).
  Future<void> close();
}

String _hm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Makes tonight's cues when they are on, or null. Never throws past the recorder's guard: the guard catches.
typedef CueFactory = CueWatch? Function(int nightStartMs);

class LiveCues implements CueWatch {
  LiveCues._(
    this._arm, {
    required this.store,
    required this.record,
    required this.model,
    required this.bell,
    required this.level,
    required this.cuesAfter,
    required this.modelBefore,
    this.scale = scaleInBackground,
    this.slow = slowCall,
  });

  /// Tonight's cues, or null when they are off. Reads the settings, freezes the test on its first night, and gives the
  /// night its number (a night restarted by Android keeps its record and number).
  static LiveCues? open({
    required LucidStore store,
    required int nightStartMs,
    required LiveModel Function() model,
    required CueBell bell,
    required DateTime now,
    ScaleFn scale = scaleInBackground,
    Duration slow = slowCall,
    Duration cuesAfter = LucidRule.cuesFrom,
    Duration modelBefore = LucidRule.modelBefore,
  }) {
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
      store: store,
      record: record,
      model: model,
      bell: bell,
      level: settings.level,
      cuesAfter: cuesAfter,
      modelBefore: modelBefore,
      scale: scale,
      slow: slow,
    );
    if (prior == null) {
      w._events.add(
        'lucid cues on: night ${record.index + 1} of the test; cues from ${_hm(record.cuesFromMs)}, the sleep model '
        'from ${_hm(record.cuesFromMs - modelBefore.inMilliseconds)}',
      );
      if (settings.level == null) w._off('No loudness is set yet: do the evening practice first.');
    } else if (prior.running) {
      w._off('The app ended while the sleep model ran, so the cues stay off tonight.');
    } else if (prior.phase == 'done' || prior.phase == 'off') {
      w._phase = prior.phase;
    }
    w._save();
    return w;
  }

  final LucidStore store;
  LucidNightRecord record;
  final LiveModel Function() model;
  final CueBell bell;
  final NightArm _arm;
  final double? level;
  final Duration cuesAfter, modelBefore;
  final ScaleFn scale;
  final Duration slow;

  final List<String> _events = [];
  late String _phase = record.phase;
  LiveStager? _stager;
  CueRule? _rule;
  Detectors? _det;
  EyeBursts? _eyes;
  int? _startUnix;
  double _lastArrival = 0;
  List<double>? _lastRow;
  final Float32List _f32 = Float32List(4);
  final Set<int> _bursts = {};
  String? _drift;
  int _lastK = -1, _arousalsSaid = 0;
  final List<CueMoment> _moments = [];
  final List<double> _confidence = [];
  LiveMode? _modeSaid;
  Future<void>? _closing;
  int? _mediaVolume;

  int get _modelFromMs => record.cuesFromMs - modelBefore.inMilliseconds;

  @override
  bool get finished => _phase == 'done' || _phase == 'off';

  /// Tonight's rule, once the model runs (tests).
  CueRule? get rule => _rule;

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
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    if (_stager == null && t0 * 1000 < _modelFromMs) return;
    final start = _startUnix;
    if (start == null) {
      _begin(t0, rows.first);
    } else if (firstOfFile || t0 - _lastArrival > minGapSeconds) {
      final want = roundHalfEven((t0 - start) * sampleRate);
      final have = _eyes!.samples;
      if (want > have) _hold(want - have);
    }
    _lastArrival = arr;
    for (final r in rows) {
      _push(_row(r), missing: false);
    }
  }

  void _begin(double t0, Sample first) {
    final whole = _wholeSecond(t0);
    _startUnix = whole;
    final rule = CueRule(cuesFrom: _cuesFromK(whole));
    _rule = rule;
    _det = Detectors(onSecond: _second);
    final eyes = EyeBursts();
    _eyes = eyes;
    _det!.tap = eyes;
    _stager = LiveStager(model: model(), scale: scale, slow: slow, onStage: _onStage, onChange: _onChange);
    _phase = 'listening';
    record = record.copyWith(running: true);
    _events.add('lucid cues: sleep model on');
    _save();
    unawaited(_readVolume());
    final lead = roundHalfEven((t0 - whole) * sampleRate);
    final row = _row(first);
    for (var i = 0; i < lead; i++) {
      _push(row, missing: true);
    }
  }

  int _cuesFromK(int startUnix) => (record.cuesFromMs / 1000 - startUnix).ceil();

  Future<void> _readVolume() async {
    try {
      _mediaVolume = (await bell.mediaVolume())?.volume;
      record = record.copyWith(mediaVolume: _mediaVolume);
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
    _stager!.push(row, missing: missing);
    final det = _det!;
    det.push(row, missing: missing);
    final b = _eyes!.push(row);
    if (b != null) _bursts.add(b);
    if (det.blinks.length + det.eyeMoves.length + det.bursts.length + det.movement.length > 256) {
      det.blinks.clear();
      det.eyeMoves.clear();
      det.bursts.clear();
      det.movement.clear();
      _eyes!.trim();
    }
    if (det.epochs.length > 256) det.epochs.clear();
  }

  void _second(Second s) {
    final rule = _rule;
    if (rule == null || finished) return;
    _lastK = s.k;
    var burst = false;
    _bursts.removeWhere((k) {
      if (k > s.k) return false;
      burst = true;
      return true;
    });
    final jaw =
        s.muscleOn &&
        math.min(s.muscleX[0].isNaN ? 0.0 : s.muscleX[0], s.muscleX[1].isNaN ? 0.0 : s.muscleX[1]) >= MuscleRule.bothX;
    final cue = rule.second(s.k, moved: s.movement, jaw: jaw, burst: burst, drift: _drift);
    if (cue != null) _cue(cue);
    _afterRule();
  }

  void _onStage(LiveStage st) {
    final rule = _rule;
    if (rule == null || finished) return;
    rule.stage(st.epoch, st.stage, st.confidence, math.max(0, _lastK));
    _confidence.add(st.confidence);
    if (_confidence.length > 8) _confidence.removeAt(0);
    _afterRule();
  }

  void _cue(RuleCue c) {
    final at = (_startUnix! + c.k) * 1000;
    final gain = math.min(1.0, (level ?? 0) * cueGain(c.step));
    final conf = _confidence.isEmpty ? 0.0 : _confidence.last;
    _moments.add(CueMoment(atMs: at, step: c.step, period: c.period, confidence: conf));
    _events.add('lucid cue ${_rule!.cues.length} (dream sleep ${conf.toStringAsFixed(2)}, +${c.step} dB)');
    if (_arm == NightArm.cue) unawaited(_play(at, gain));
    _save();
  }

  Future<void> _play(int atMs, double gain) async {
    try {
      final ok = await bell.play(store.cueWav, gain);
      store.addPlay(atMs, record.index, ok, ok ? null : 'the phone did not play it');
    } catch (e) {
      try {
        store.addPlay(atMs, record.index, false, '$e'.split('\n').first);
      } catch (_) {}
    }
  }

  void _afterRule() {
    final rule = _rule!;
    while (_arousalsSaid < rule.arousals.length) {
      _arousalsSaid++;
      _events.add('lucid cues: arousal after a cue; 3 dB quieter, 5 minutes without cues');
      _save();
    }
    if (rule.done != null && !finished) {
      _phase = 'done';
      _events.add(
        rule.done == 'per night'
            ? 'lucid cues: done for tonight (${LucidRule.perNight} cues)'
            : 'lucid cues: done for tonight (${LucidRule.stopAfterArousals} arousals)',
      );
      _save();
      unawaited(_freeModel());
    }
  }

  void _onChange() {
    final s = _stager;
    if (s == null || s.mode == _modeSaid) return;
    _modeSaid = s.mode;
    if (s.mode == LiveMode.light) _events.add('lucid cues: sleep model 1 run (slow phone)');
    _save();
  }

  @override
  void check(DateTime now, {int? lightsOffMs, String? drift}) {
    _drift = drift;
    if (finished) return;
    if (lightsOffMs != null) {
      final from = lightsOffMs + cuesAfter.inMilliseconds;
      if (from != record.cuesFromMs) {
        record = record.copyWith(cuesFromMs: from);
        final start = _startUnix;
        if (start != null) _rule!.cuesFrom = _cuesFromK(start);
        _events.add('lucid cues from ${_hm(from)} (4.5 h after Lights off)');
        _save();
      }
    }
    final s = _stager;
    if (s != null && s.mode == LiveMode.timer) {
      _off('The sleep model stopped (it failed or was too slow), so no more cues tonight.');
    }
  }

  void _off(String why) {
    if (finished) return;
    _phase = 'off';
    record = record.copyWith(off: why);
    _events.add('lucid cues off: $why');
    _save();
    unawaited(_freeModel());
  }

  /// Switches the cues off for the night ([why]: a sentence; the recorder's guard calls it).
  void off(String why) => _off(why);

  Future<void> _freeModel() async {
    final s = _stager;
    if (s == null) return;
    try {
      await s.close();
    } catch (_) {}
    record = record.copyWith(running: false);
    _save();
  }

  @override
  Future<void> close() => _closing ??= () async {
    if (!finished) _phase = 'ended';
    await _freeModel();
    record = record.copyWith(running: false);
    _save();
  }();

  /// The night's record; never throws.
  void _save() {
    try {
      final rule = _rule;
      final s = _stager, times = s?.callTimes;
      final aroused = {
        for (final c in rule?.cues ?? const <RuleCue>[])
          if (c.aroused) (_startUnix ?? 0) + c.k,
      };
      record = record.copyWith(
        phase: _phase,
        cues: rule == null
            ? record.cues
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
        arousals: rule == null ? record.arousals : [for (final k in rule.arousals) ((_startUnix ?? 0) + k) * 1000],
        stops: rule == null ? record.stops : [for (final (k, why) in rule.stops) (((_startUnix ?? 0) + k) * 1000, why)],
        model: s == null
            ? record.model
            : {
                'mode': s.mode.name,
                'calls': s.calls.length,
                'median_ms': times?.median,
                'max_ms': times?.max,
                'skipped_windows': s.skipped,
              },
        mediaVolume: _mediaVolume,
      );
      store.saveNight(record);
    } catch (_) {}
  }

  /// `datetime.fromtimestamp(t).replace(microsecond=0)`, as the night's pass starts a night.
  static int _wholeSecond(double t) {
    var whole = t.floor();
    if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
    return whole;
  }
}

/// Tonight's cues in the night recorder's isolate: AnySleep's runs on ONNX (as the nap coach and the smart alarm open
/// them), the phone's media player for the sound, the files beside the recordings.
CueFactory lucidCuesFor(String recordingsDir, {required LiveModel Function() model, required CueBell bell}) =>
    (nightStartMs) {
      final store = LucidStore(lucidDirFor(recordingsDir));
      ensureCueWav(store.cueWav);
      return LiveCues.open(store: store, nightStartMs: nightStartMs, model: model, bell: bell, now: DateTime.now());
    };
