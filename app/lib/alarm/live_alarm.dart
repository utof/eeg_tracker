// The smart alarm during the night (DECISIONS 230-236). It runs in the night recorder's own isolate, like the
// drift-off detector (recorder/live_drift.dart, DECISIONS 182): fed each batch right after the batch is buffered for
// the files, and wrapped by the recorder in a guard (an exception, too much time or too much memory switches it off
// with one log line; the recording goes on, and the phone's alarm still rings at the window's end).
//
// It waits until an hour before the window, then listens to the live sleep model (sleep/live_stager.dart: AnySleep on
// the ONNX plugin's thread, the scaling in a background isolate) on the batches from then on. The model is the night's
// one scorer (sleep/night_scorer.dart, DECISIONS 330), shared with the lucid dream cues when they run too; it places
// the batches on the clock as the drift-off detector does. Each stage goes through the rule (rule.dart); the first
// wake moment brings the phone's alarm forward (bell.dart) and lets the model go (freed unless the cues still use
// it). The window's end needs nothing from here: the phone's alarm is set there at Start.
import 'dart:async';
import 'dart:math' as math;

import '../recorder/chunk_writer.dart' show Sample, unixSeconds;
import '../sleep/live_stager.dart';
import '../sleep/night_scorer.dart';
import '../sleep/night_signal.dart' show sampleRate;
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

  /// Stops the model and frees it (after any running call), and waits for an early ring's answer: what it said
  /// (a failure) can be taken with [takeEvents] afterwards.
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

class LiveAlarm implements AlarmWatch, StageListener {
  /// [scorer]: the night's shared live model, fed by the recorder; or [model]: this alarm opens its own and feeds it
  /// (one of the two).
  LiveAlarm({
    required this.plan,
    LiveModel Function()? model,
    NightScorer? scorer,
    required this.bell,
    this.store,
    ScaleFn scale = scaleInBackground,
    Duration slow = slowCall,
    DateTime Function()? clock,
  }) : assert((model == null) != (scorer == null), 'a model or a shared scorer'),
       _own = scorer == null,
       scorer = scorer ?? NightScorer(model: model!, scale: scale, slow: slow),
       _now = clock ?? DateTime.now {
    this.scorer.join(this);
  }

  final AlarmPlan plan;

  /// The live sleep model it listens to from the hour before the window.
  final NightScorer scorer;
  final bool _own;
  final AlarmBell bell;

  /// Where the record goes (null: none).
  final AlarmStore? store;
  final DateTime Function() _now;

  late final AlarmRules rules = AlarmRules.of(plan);

  /// The model it listened to (kept after it let the model go: the record's speed).
  LiveStager? _stager;
  LiveStager? get stager => _stager;

  /// The model's first sample, a whole unix second: epoch e starts at [startUnix] + 30 e.
  int? startUnix;

  /// The first epoch it was given (the record's stages start there).
  int? _firstEpoch;
  final List<String> _letters = [];

  AlarmPhase _phase = AlarmPhase.waiting;
  String? _note;
  String? _latest;
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
  String get who => 'smart alarm';

  /// From the hour before the window until it has finished.
  @override
  bool needs(double t0Ms) => !finished && t0Ms >= plan.scoreFromMs && t0Ms < plan.endMs;

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (finished || rows.isEmpty) return;
    if (_own) scorer.add(arrival, rows, firstOfFile: firstOfFile);
    final arr = unixSeconds(arrival);
    final t0 = arr - rows.length / sampleRate; // a batch arrives just after its last sample
    if (t0 * 1000 < plan.scoreFromMs || arr * 1000 >= plan.endMs) return;
    if (_stager == null) _start(arrival);
  }

  /// The hour before the window has come: from now on it listens to the model (which the scorer started for it on
  /// this batch, or was already running for the lucid cues).
  void _start(DateTime at) {
    final s = scorer.stager;
    if (s == null) {
      off('The sleep model is not running tonight, so the phone\'s alarm wakes you at ${_hm(plan.endMs)}.');
      return;
    }
    _stager = s;
    startUnix = scorer.startUnix;
    _phase = AlarmPhase.scoring;
    _events.add('smart alarm: sleep model on (window $_window)');
    _save(modelFrom: at.millisecondsSinceEpoch);
  }

  @override
  void scored(LiveStage st, int epochStartMs) {
    if (finished || _stager == null) return;
    try {
      _latest = st.stage;
      final first = _firstEpoch ??= st.epoch;
      final i = st.epoch - first;
      if (i >= 0) {
        while (_letters.length <= i) {
          _letters.add('.');
        }
        _letters[i] = _stageChar[st.stage] ?? '-';
      }
      final wake = rules.stage(st, nowMs: _now().millisecondsSinceEpoch, epochStartMs: epochStartMs);
      if (wake != null) _woke(wake);
    } catch (e) {
      off('The smart alarm failed (${_short(e)}), so the phone\'s alarm wakes you at ${_hm(plan.endMs)}.');
    }
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
    _ringing = _ring('${words[0].toUpperCase()}${words.substring(1)}, $early min before ${_hm(plan.endMs)}.');
    unawaited(_freeModel());
  }

  /// The early ring while the phone answers (it never throws).
  Future<void>? _ringing;

  Future<void> _ring(String reason) async {
    try {
      if (!await bell.ringNow(reason)) {
        _events.add('smart alarm: the phone\'s alarm was not brought forward (not set, or already ringing)');
      }
    } catch (e) {
      _events.add('smart alarm: could not ring early (${_short(e)}); the phone\'s alarm rings at ${_hm(plan.endMs)}');
    }
  }

  @override
  void modelChanged() {
    final s = _stager;
    if (s == null || s.mode == _modeSaid) return;
    _modeSaid = s.mode;
    if (s.mode == LiveMode.light) _events.add('smart alarm: sleep model 1 run: ${_why(s) ?? ''}');
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
      off(_why(s) ?? 'The sleep model stopped, so the phone\'s alarm wakes you at ${_hm(plan.endMs)}.');
    }
  }

  /// The model's sentence for stepping down or stopping, ending in what takes over here.
  String? _why(LiveStager s) => modelWhy(s, 'the phone\'s alarm wakes you at ${_hm(plan.endMs)}');

  /// Switches the model off for the night ([why]: a sentence); the phone's alarm stays.
  void off(String why) {
    if (finished) return;
    _phase = AlarmPhase.off;
    _note = why;
    _events.add('smart alarm: sleep model off: $why');
    _save(off: why);
    unawaited(_freeModel());
  }

  /// Lets the model go: the scorer frees it unless the lucid cues still use it.
  Future<void> _freeModel() async {
    try {
      await scorer.leave(this);
    } catch (_) {}
  }

  @override
  Future<void> close() => _closing ??= () async {
    if (!finished) _phase = AlarmPhase.off;
    _save();
    await _freeModel();
    await _ringing?.timeout(const Duration(seconds: 10), onTimeout: () {});
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
      st.write(plan.endMs, {
        'plan': plan.toJson(),
        'phase': _phase.name,
        'model_from_ms': _modelFrom,
        'epochs_from_ms': start == null ? null : (start + (_firstEpoch ?? 0) * 30) * 1000,
        'stages': _letters.join(),
        'model': s == null
            ? null
            : {
                'mode': s.mode.name,
                'why': _why(s),
                'calls': s.calls.length,
                'median_ms': times?.median,
                'max_ms': times?.max,
              },
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
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.substring(0, math.min(s.length, 160));
}
