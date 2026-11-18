// Live sleep stages (DECISIONS rows 79 and 170-172): fed the headband's samples as they arrive, it runs AnySleep
// each time a 30 s epoch is complete, on the last 60 minutes prepared live (live_prep.dart), and hands out the stage
// of the epoch 2 minutes (4 epochs) behind the newest, with its confidence. On the owner's recorded night that agreed
// with the full-night scoring on most epochs (docs/evidence/nap-coach.md, analysis/live_stager.py).
//
// It never blocks the screen: the window is copied (a few milliseconds), scaled in a background isolate, and the
// model runs on the ONNX plugin's own thread. A call that is still running when the next epoch completes is not
// queued: the next call starts as soon as it ends, on the newest epoch, and hands out every epoch since the last one
// it gave (those few read slightly further behind). It times every call and steps down when one is too slow for the
// 30 s rhythm: 3 runs, then 1 run, then the timer only (no model); a model that fails also leaves the timer only.
// Callers must work without stages: a nap still ends at its length.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'live_prep.dart';
import 'model.dart' show StageRun, addSoftmax;
import 'periods.dart' show gapStage, stageNames;

/// The stage read this many epochs behind the newest one (2 minutes; DECISIONS row 79).
const int behindEpochs = 4;

/// AnySleep's shortest input: the first call comes once 5 minutes are in.
const int liveMinEpochs = 10;

/// A call slower than this (prepare + model) steps down: it must fit the 30 s rhythm with room to spare.
const Duration slowCall = Duration(seconds: 15);

enum LiveMode {
  /// AnySleep's three runs averaged, as the night's report.
  full,

  /// One run (a third of the time).
  light,

  /// No model: the caller's timer alone.
  timer,
}

/// One epoch's live stage: W N1 N2 N3 R, or `gap` (over 5 s of it was lost), read [behind] epochs behind the newest.
class LiveStage {
  const LiveStage(this.epoch, this.stage, this.confidence, this.behind);
  final int epoch;
  final String stage;
  final double confidence;
  final int behind;
}

/// One model call: the window's edge and size, the runs used, and how long it took (preparing and the model).
class LiveCall {
  const LiveCall(this.edge, this.epochs, this.runs, this.ms, this.prepMs);
  final int edge;
  final int epochs;
  final int runs;
  final int ms;
  final int prepMs;
}

/// The sleep model as the live scorer uses it (ONNX in live_onnx.dart, scripted fakes in tests).
abstract interface class LiveModel {
  /// The mean softmax of runs 1..[runs], [epochs] x 5 (W N1 N2 N3 R), for [x] ([epochs] * 3840 samples x 4 channels,
  /// time-major, scaled). [first] is the window's first epoch counted from the start (for scripted fakes).
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first});

  Future<void> close();
}

typedef ScaleFn = Future<Float32List> Function(LiveWindow w);

/// Scales the window in a background isolate (the closure holds only the window).
Future<Float32List> scaleInBackground(LiveWindow w) => Isolate.run(() => scaleWindow(w), debugName: 'live-scale');

class LiveStager {
  LiveStager({
    required this.model,
    LivePrep? prep,
    this.scale = scaleInBackground,
    this.behind = behindEpochs,
    this.minEpochs = liveMinEpochs,
    this.slow = slowCall,
    this.mayRun,
    this.onStage,
    this.onChange,
    int Function()? clockMs,
  }) : prep = prep ?? LivePrep(),
       _ms = clockMs ?? _wallMs;

  final LiveModel model;
  final LivePrep prep;
  final ScaleFn scale;
  final int behind;
  final int minEpochs;
  final Duration slow;

  /// When false, calls wait (another model is running, e.g. last night's scoring; memory). Null: always.
  final bool Function()? mayRun;

  /// Each new stage, in epoch order.
  final void Function(LiveStage s)? onStage;

  /// The mode changed (with [why]).
  final void Function()? onChange;
  final int Function() _ms;

  static final Stopwatch _wall = Stopwatch()..start();
  static int _wallMs() => _wall.elapsedMilliseconds;

  LiveMode mode = LiveMode.full;

  /// Why the mode stepped down (a plain sentence), null while at full.
  String? why;

  /// Every stage handed out, in epoch order, and every call.
  final List<LiveStage> stages = [];
  final List<LiveCall> calls = [];

  /// Calls skipped because [mayRun] said no.
  int waited = 0;

  Future<void>? _running;
  int _scoredUpTo = -1; // the last epoch handed out
  bool _closed = false;

  int get runs => mode == LiveMode.full ? 3 : 1;
  bool get busy => _running != null;

  /// One row of µV (O1 O2 T3 T4); [missing]: a held value standing in for a lost sample.
  void push(List<double> row, {bool missing = false}) {
    final before = prep.epochs;
    prep.push(row, missing: missing);
    if (prep.epochs != before) _due();
  }

  /// A hole of [n] lost samples, held at the last value.
  void hold(int n) {
    final before = prep.epochs;
    prep.hold(n);
    if (prep.epochs != before) _due();
  }

  void _due() {
    if (_closed || mode == LiveMode.timer || _running != null || prep.epochs < minEpochs) return;
    if (prep.epochs - 1 - behind <= _scoredUpTo) return;
    if (mayRun != null && !mayRun!()) {
      waited++;
      return;
    }
    _running = _call().whenComplete(() {
      _running = null;
      _due(); // epochs completed meanwhile: score the newest now
    });
  }

  Future<void> _call() async {
    final t0 = _ms();
    final w = prep.window(prep.epochs);
    final runs = this.runs;
    try {
      final x = await scale(w);
      final prepMs = _ms() - t0;
      if (_closed) return;
      final p = await model.probabilities(x, w.epochs, runs, first: w.first);
      if (p.length != w.epochs * 5) throw StateError('the model gave ${p.length} values for ${w.epochs} epochs');
      final ms = _ms() - t0;
      calls.add(LiveCall(w.end, w.epochs, runs, ms, prepMs));
      if (_closed) return;
      final newest = w.end - 1 - behind;
      for (var e = math.max(_scoredUpTo + 1, w.first); e <= newest; e++) {
        stages.add(_stageOf(p, e - w.first, e, w.end - 1 - e, w.gap[e - w.first]));
        onStage?.call(stages.last);
      }
      _scoredUpTo = math.max(_scoredUpTo, newest);
      if (ms > slow.inMilliseconds) _stepDown(ms);
    } catch (e) {
      if (_closed) return;
      mode = LiveMode.timer;
      why = 'The sleep model stopped ($e), so the timer alone ends the nap.';
      onChange?.call();
    }
  }

  static LiveStage _stageOf(Float64List p, int i, int epoch, int lag, bool gap) {
    var best = 0;
    for (var k = 1; k < 5; k++) {
      if (p[i * 5 + k] > p[i * 5 + best]) best = k;
    }
    return LiveStage(epoch, gap ? gapStage : stageNames[best], p[i * 5 + best], lag);
  }

  void _stepDown(int ms) {
    final s = (ms / 1000).toStringAsFixed(1);
    if (mode == LiveMode.full) {
      mode = LiveMode.light;
      why = 'One check took $s s with the full model, so it now uses 1 of its 3 runs.';
    } else {
      mode = LiveMode.timer;
      why = 'The sleep model is too slow on this phone ($s s for one check), so the timer alone ends the nap.';
    }
    onChange?.call();
  }

  /// Waits for a running call (tests, the end of a session).
  Future<void> idle() async {
    while (_running != null) {
      await _running;
    }
  }

  /// Stops scoring and releases the model (after any running call).
  Future<void> close() async {
    _closed = true;
    await idle();
    await model.close();
  }

  /// Median and largest call time (ms), null before the first call.
  ({int median, int max})? get callTimes {
    if (calls.isEmpty) return null;
    final ms = [for (final c in calls) c.ms]..sort();
    return (median: ms[ms.length ~/ 2], max: ms.last);
  }
}

/// The live model on AnySleep's runs (ONNX's [StageRun]s on the phone): runs are opened when first needed and kept
/// open for the session (opening one takes a moment); stepping down to fewer runs closes the others.
class RunsLiveModel implements LiveModel {
  RunsLiveModel({required this.open, this.closeRun});
  final Future<StageRun> Function(int run) open;
  final Future<void> Function(StageRun run)? closeRun;
  final List<StageRun> _runs = [];

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    while (_runs.length > runs) {
      await closeRun?.call(_runs.removeLast());
    }
    final sum = Float64List(epochs * 5);
    for (var r = 0; r < runs; r++) {
      if (r == _runs.length) _runs.add(await open(r + 1));
      final z = await _runs[r].logits(x, epochs);
      if (z.length != epochs * 5) throw StateError('the model gave ${z.length} values for $epochs epochs');
      for (var e = 0; e < epochs; e++) {
        addSoftmax(z, e * 5, sum, e * 5);
      }
    }
    for (var i = 0; i < sum.length; i++) {
      sum[i] /= runs;
    }
    return sum;
  }

  @override
  Future<void> close() async {
    while (_runs.isNotEmpty) {
      await closeRun?.call(_runs.removeLast());
    }
  }
}
