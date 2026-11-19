// The smart alarm during the night (DECISIONS 230-236). It runs in the night recorder's own isolate, like the
// drift-off detector (recorder/live_drift.dart, DECISIONS 182): fed each batch right after the batch is buffered for
// the files, and wrapped by the recorder in a guard (an exception, too much time or too much memory switches it off
// with one log line; the recording goes on, and the phone's alarm still rings at the window's end).
//
// It waits until an hour before the window, then starts the live sleep model (sleep/live_stager.dart: AnySleep on the
// ONNX plugin's thread, the scaling in a background isolate) on the batches from then on, placed on the clock as the
// drift-off detector places them (a pause over 0.5 s or a new file set is held at the last value and counts as lost).
// Each stage goes through the rule (rule.dart); the first wake moment brings the phone's alarm forward (bell.dart)
// and frees the model. The window's end needs nothing from here: the phone's alarm is set there at Start.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show Sample, unixSeconds;
import '../sleep/live_stager.dart';
import '../sleep/night_signal.dart' show limitMicrovolts, minGapSeconds, roundHalfEven, sampleRate;
import '../sleep/periods.dart' show gapStage;
import 'bell.dart';
import 'record.dart';
import 'rule.dart';

enum AlarmPhase {
  /// Before the model's hour.
  waiting,

  /// The live model runs.
  scoring,

  /// The rule woke you (the phone's alarm was brought forward).
  woke,

  /// The window's end came without a wake moment: the phone's alarm rings by itself.
  ended,

  /// The model stopped (failed, too slow, no data); the phone's alarm rings at the window's end.
  off,
}

/// What the night screen shows of the smart alarm.
class AlarmLive {
  const AlarmLive({required this.phase, this.stage, this.wake, this.note});
  final AlarmPhase phase;

  /// The newest live stage (W N1 N2 N3 R or gap), 2 minutes behind.
  final String? stage;
  final AlarmWake? wake;

  /// Why the model stopped, in a sentence (phase [AlarmPhase.off]).
  final String? note;
}

/// The night recorder's view of the smart alarm, so a test can put a broken one in.
abstract interface class AlarmWatch {
  /// One batch as it arrived; [firstOfFile] for the first batch of a new file set.
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false});

  /// The recorder's 10-second check: the window's end, the model's state.
  void check(DateTime now);

  /// Marker texts since the last call.
  List<String> takeEvents();

  AlarmLive get live;

  /// Woke, ended or off: the recorder lets it go.
  bool get finished;

  /// Stops the model and frees it (after any running call).
  Future<void> close();
}

String _hm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _hms(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

const Map<String, String> _stageWords = {'N1': 'light sleep', 'N2': 'light sleep', 'R': 'dream sleep', 'W': 'awake'};
const Map<String, String> _stageChar = {'W': 'W', 'N1': '1', 'N2': '2', 'N3': '3', 'R': 'R', gapStage: '-'};

class LiveAlarm implements AlarmWatch {
  LiveAlarm({
    required this.plan,
    required this.model,
    required this.bell,
    this.store,
    this.scale = scaleInBackground,
    this.slow = slowCall,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AlarmPlan plan;

  /// Opens the sleep model when the hour before the window starts.
  final LiveModel Function() model;
  final AlarmBell bell;

  /// Where the record goes (null: none).
  final AlarmStore? store;
  final ScaleFn scale;
  final Duration slow;
  final DateTime Function() _now;

  late final AlarmRules rules = AlarmRules.of(plan);
  LiveStager? _stager;
  LiveStager? get stager => _stager;

  /// The model's first sample, a whole unix second: epoch e starts at [startUnix] + 30 e.
  int? startUnix;

  AlarmPhase _phase = AlarmPhase.waiting;
  String? _note;
  String? _latest;
  double _lastArrival = 0;
  final Float32List _f32 = Float32List(4);
  final List<double> _row = List.filled(4, 0);
  final List<String> _events = [];
  LiveMode? _modeSaid;
  Future<void>? _closing;

  @override
  AlarmLive get live => AlarmLive(phase: _phase, stage: _latest, wake: rules.wake, note: _note);

  @override
  bool get finished => _phase.index >= AlarmPhase.woke.index;

  @override
  List<String> takeEvents() {
    if (_events.isEmpty) return const [];
    final out = List<String>.of(_events);
    _events.clear();
    return out;
  }

  String get _window => '${_hm(plan.startMs)}-${_hm(plan.endMs)}';

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (finished || rows.isEmpty) return;
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    if (t0 * 1000 < plan.scoreFromMs || arr * 1000 >= plan.endMs) return;
    var s = _stager;
    final start = startUnix;
    if (s == null || start == null) {
      s = _start(arrival);
      final whole = _wholeSecond(t0);
      startUnix = whole;
      final lead = roundHalfEven((t0 - whole) * sampleRate);
      for (var i = 0; i < lead; i++) {
        _push(s, rows.first, missing: true);
      }
    } else if (firstOfFile || t0 - _lastArrival > minGapSeconds) {
      final want = roundHalfEven((t0 - start) * sampleRate);
      if (want > s.prep.samples) s.hold(want - s.prep.samples);
    }
    _lastArrival = arr;
    for (final r in rows) {
      _push(s, r);
    }
  }

  LiveStager _start(DateTime at) {
    final s = LiveStager(
      model: model(),
      scale: scale,
      slow: slow,
      onStage: _onStage,
      onChange: _onChange,
      fallback: 'the phone\'s alarm wakes you at ${_hm(plan.endMs)}',
    );
    _stager = s;
    _phase = AlarmPhase.scoring;
    _events.add('smart alarm: sleep model on (window $_window)');
    _save(modelFrom: at.millisecondsSinceEpoch);
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
    if (finished) return;
    _latest = st.stage;
    final start = startUnix ?? 0;
    final wake = rules.stage(st, nowMs: _now().millisecondsSinceEpoch, epochStartMs: (start + st.epoch * 30) * 1000);
    if (wake != null) _woke(wake);
  }

  void _woke(AlarmWake w) {
    _phase = AlarmPhase.woke;
    final words = _stageWords[w.stage] ?? w.stage ?? 'a light moment';
    final early = ((plan.endMs - w.atMs) / 60000).round();
    _events.add(
      'smart alarm: wake, $words (${w.stage} at ${_hms(w.epochStartMs ?? 0)}, read ${(w.behind ?? 0) * 30 ~/ 60} min '
      'behind; $early min before ${_hm(plan.endMs)})',
    );
    _save();
    unawaited(_ring('${words[0].toUpperCase()}${words.substring(1)}, $early min before ${_hm(plan.endMs)}.'));
    unawaited(_freeModel());
  }

  Future<void> _ring(String reason) async {
    try {
      if (!await bell.ringNow(reason)) {
        _events.add('smart alarm: the phone\'s alarm was not brought forward (not set, or already ringing)');
      }
    } catch (e) {
      _events.add('smart alarm: could not ring early (${_short(e)}); the phone\'s alarm rings at ${_hm(plan.endMs)}');
    }
  }

  void _onChange() {
    final s = _stager;
    if (s == null || s.mode == _modeSaid) return;
    _modeSaid = s.mode;
    if (s.mode == LiveMode.light) _events.add('smart alarm: sleep model 1 run: ${s.why ?? ''}');
    _save();
  }

  @override
  void check(DateTime now) {
    if (finished) return;
    final due = rules.due(now.millisecondsSinceEpoch);
    if (due != null) {
      _phase = AlarmPhase.ended;
      _events.add(
        _stager == null
            ? 'smart alarm: the window\'s end (${_hm(plan.endMs)}) came before the sleep model had any data'
            : 'smart alarm: the window\'s end (${_hm(plan.endMs)}) came without light sleep; the phone\'s alarm rings',
      );
      _save();
      unawaited(_freeModel());
      return;
    }
    final s = _stager;
    if (s != null && s.mode == LiveMode.timer) {
      off(s.why ?? 'The sleep model stopped, so the phone\'s alarm wakes you at ${_hm(plan.endMs)}.');
    }
  }

  /// Switches the model off for the night ([why]: a sentence); the phone's alarm stays.
  void off(String why) {
    if (finished) return;
    _phase = AlarmPhase.off;
    _note = why;
    _events.add('smart alarm: sleep model off: $why');
    _save(off: why);
    unawaited(_freeModel());
  }

  Future<void> _freeModel() async {
    try {
      await _stager?.close();
    } catch (_) {}
  }

  @override
  Future<void> close() => _closing ??= () async {
    if (!finished) _phase = AlarmPhase.off;
    _save();
    await _freeModel();
  }();

  int? _modelFrom;
  String? _off;

  /// The record for the morning report; never throws.
  void _save({int? modelFrom, String? off}) {
    _modelFrom ??= modelFrom;
    _off ??= off;
    final st = store;
    if (st == null) return;
    try {
      final s = _stager, w = rules.wake, times = s?.callTimes;
      final start = startUnix;
      final n = s == null ? 0 : s.stages.isEmpty ? 0 : s.stages.last.epoch + 1;
      final letters = List.filled(n, '.');
      for (final x in s?.stages ?? const <LiveStage>[]) {
        letters[x.epoch] = _stageChar[x.stage] ?? '-';
      }
      st.write(plan.endMs, {
        'plan': plan.toJson(),
        'phase': _phase.name,
        'model_from_ms': _modelFrom,
        'epochs_from_ms': start == null ? null : start * 1000,
        'stages': letters.join(),
        'model': s == null
            ? null
            : {'mode': s.mode.name, 'why': s.why, 'calls': s.calls.length, 'median_ms': times?.median, 'max_ms': times?.max},
        'wake': w == null
            ? null
            : {
                'at_ms': w.atMs,
                'why': alarmWhyName(w.why),
                'stage': w.stage,
                'epoch_start_ms': w.epochStartMs,
                'behind': w.behind,
                'confidence': w.confidence == null ? null : (w.confidence! * 1000).round() / 1000,
              },
        'off': _off,
      });
    } catch (_) {}
  }

  /// `datetime.fromtimestamp(t).replace(microsecond=0)`, as the night's pass starts a night.
  static int _wholeSecond(double t) {
    var whole = t.floor();
    if (roundHalfEven((t - whole) * 1e6) >= 1000000) whole += 1;
    return whole;
  }
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.substring(0, math.min(s.length, 160));
}
