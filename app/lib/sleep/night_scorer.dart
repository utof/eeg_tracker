// The night's one live sleep model (DECISIONS 330). The smart alarm (alarm/live_alarm.dart) wants the live stages from
// an hour before its window, the lucid dream cues (lucid/live_cues.dart) from an hour before their cue hours; each
// opening AnySleep's three runs for itself would hold two copies of the model, and do every call twice, for up to 90
// minutes of a night with both. So the night recorder keeps one scorer and both listen to it.
//
// It runs while at least one listener needs it: it starts on the first batch one of them needs, a listener that needs
// it later uses the same model (no second copy), and it is freed once none needs it any more; a listener that comes
// after that starts it again. It places the batches on the clock as the drift-off detector does (a pause over 0.5 s or
// a new file set is held at the last value and counts as lost), so epoch e starts at [NightScorer.startUnix] + 30 e,
// and hands each epoch's stage and confidence, with that start, to every listener using it. A listener's own failure
// costs only that listener. The model's failures show in [LiveStager.mode]: each listener reads it in its own check
// (the alarm then leaves the waking to the phone's alarm, the cues stop).
//
// Without a shared scorer (a listener made on its own, as in its tests) a listener makes its own one and feeds it.
import 'dart:async';
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show Sample, unixSeconds;
import 'live_stager.dart';
import 'night_signal.dart' show limitMicrovolts, minGapSeconds, roundHalfEven, sampleRate;

/// Stands in the shared model's sentences ([LiveStager.why]) for what takes over when it stops: each listener says
/// its own through [modelWhy].
const String modelFallback = '<what takes over>';

/// [s]'s sentence for why it stepped down or stopped, with [fallback] for what takes over ("the phone's alarm wakes you
/// at 07:30").
String? modelWhy(LiveStager s, String fallback) => s.why?.replaceAll(modelFallback, fallback);

/// One user of the night's live stages.
abstract interface class StageListener {
  /// Its name in the log ("smart alarm", "lucid cues").
  String get who;

  /// Whether it needs the model for a batch whose first sample is at [t0Ms] (unix ms); false once it is done.
  bool needs(double t0Ms);

  /// One epoch's stage, in epoch order, with the epoch's start on the clock (unix ms).
  void scored(LiveStage st, int epochStartMs);

  /// The model's mode changed ([LiveStager.mode], [LiveStager.why]).
  void modelChanged();
}

class NightScorer {
  NightScorer({required this.model, this.scale = scaleInBackground, this.slow = slowCall});

  /// Opens the sleep model (AnySleep's runs on ONNX on the phone).
  final LiveModel Function() model;
  final ScaleFn scale;
  final Duration slow;

  final List<StageListener> _listeners = [];
  final List<StageListener> _using = [];
  final List<String> _events = [];
  final Float32List _f32 = Float32List(4);
  final List<double> _row = List.filled(4, 0);
  LiveStager? _stager;
  int? _startUnix;
  double _lastArrival = 0;
  bool _closed = false;
  Future<void> _freeing = Future<void>.value();

  /// Models opened in this process (one for a night whose listeners' hours overlap).
  int loads = 0;

  /// The running model, null while none is.
  LiveStager? get stager => _stager;

  /// The running model's first sample, a whole unix second: epoch e starts at [startUnix] + 30 e.
  int? get startUnix => _startUnix;

  /// The listeners using the running model.
  List<String> get users => [for (final l in _using) l.who];

  /// Log lines since the last call (the model on, shared, off).
  List<String> takeEvents() {
    if (_events.isEmpty) return const [];
    final out = List<String>.of(_events);
    _events.clear();
    return out;
  }

  void join(StageListener l) {
    if (!_closed && !_listeners.contains(l)) _listeners.add(l);
  }

  /// [l] is done with the model; it is freed (after any running call) when no other listener uses it.
  Future<void> leave(StageListener l) {
    _listeners.remove(l);
    if (_using.remove(l) && _using.isEmpty) _free('no one needs it');
    return _freeing;
  }

  /// One batch as it arrived; [firstOfFile] for the first batch of a new file set.
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (_closed || rows.isEmpty) return;
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    if (!_use(t0 * 1000)) return;
    var s = _stager;
    final start = _startUnix;
    if (s == null || start == null) {
      s = _start(t0, rows.first);
    } else if (firstOfFile || t0 - _lastArrival > minGapSeconds) {
      final want = roundHalfEven((t0 - start) * sampleRate);
      if (want > s.prep.samples) s.hold(want - s.prep.samples);
    }
    _lastArrival = arr;
    for (final r in rows) {
      _push(s, r);
    }
  }

  /// Who needs the model for this batch; frees it when no one does. False: nothing to feed.
  bool _use(double t0Ms) {
    final now = [
      for (final l in _listeners)
        if (l.needs(t0Ms)) l,
    ];
    if (now.isEmpty) {
      _using.clear();
      if (_stager != null) _free('no one needs it');
      return false;
    }
    if (_stager != null) {
      for (final l in now) {
        if (!_using.contains(l)) _events.add('live sleep model: shared with the ${l.who} (no second copy)');
      }
    }
    _using
      ..clear()
      ..addAll(now);
    return true;
  }

  LiveStager _start(double t0, Sample first) {
    final made = model(); // a factory that throws reaches the caller's guard
    loads++;
    final s = LiveStager(
      model: made,
      scale: scale,
      slow: slow,
      onStage: _onStage,
      onChange: _onChange,
      fallback: modelFallback,
    );
    _stager = s;
    final whole = _wholeSecond(t0);
    _startUnix = whole;
    _events.add('live sleep model on for the ${_using.map((l) => l.who).join(' and ')} (load $loads tonight)');
    final lead = roundHalfEven((t0 - whole) * sampleRate);
    for (var i = 0; i < lead; i++) {
      _push(s, first, missing: true);
    }
    return s;
  }

  void _push(LiveStager s, Sample r, {bool missing = false}) {
    final f = _f32, row = _row;
    f[0] = r.o1;
    f[1] = r.o2;
    f[2] = r.t3;
    f[3] = r.t4;
    for (var c = 0; c < 4; c++) {
      row[c] = (f[c] * 1e6).clamp(-limitMicrovolts, limitMicrovolts); // the files' float32, in µV, as the BDF clips
    }
    s.push(row, missing: missing);
  }

  void _onStage(LiveStage st) {
    final start = _startUnix;
    if (start == null) return;
    final at = (start + st.epoch * 30) * 1000;
    for (final l in List.of(_using)) {
      try {
        l.scored(st, at);
      } catch (_) {
        _using.remove(l); // a listener's own failure costs only that listener
        _listeners.remove(l);
      }
    }
  }

  void _onChange() {
    for (final l in List.of(_using)) {
      try {
        l.modelChanged();
      } catch (_) {}
    }
  }

  void _free(String why) {
    final s = _stager;
    if (s == null) return;
    _stager = null;
    _startUnix = null;
    _using.clear();
    final t = s.callTimes;
    _events.add(
      'live sleep model off, $why (${s.calls.length} calls'
      '${t == null ? '' : ', median ${(t.median / 1000).toStringAsFixed(1)} s'})',
    );
    _freeing = s.close().catchError((Object _) {});
  }

  /// Frees the model for good (the night's end, or the recorder's guard switched it off).
  Future<void> close() {
    _closed = true;
    _listeners.clear();
    _free('closed');
    return _freeing;
  }

  /// `datetime.fromtimestamp(t).replace(microsecond=0)`, as the night's pass starts a night.
  static int _wholeSecond(double t) {
    var whole = t.floor();
    if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
    return whole;
  }
}
