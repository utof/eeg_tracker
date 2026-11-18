// The live scorer's rhythm without ONNX (it cannot run in `flutter test`): a scripted model says which stage each
// epoch is, a fake clock says how long each call took. Checks when calls come, which epoch each stage belongs to,
// that a busy model is never queued, and the step-down from 3 runs to 1 to the timer alone.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/sleep/live_prep.dart';
import 'package:eeg_tracker/sleep/live_stager.dart';
import 'package:eeg_tracker/sleep/model.dart' show StageRun;
import 'package:flutter_test/flutter_test.dart';

/// Gives each epoch the stage [script] says (as logits 4 apart), and advances [clock] by [costMs] per call.
class ScriptedModel implements LiveModel {
  ScriptedModel(this.script, {this.clock, this.costMs = 0});
  final String Function(int epoch) script;
  final FakeClock? clock;
  int Function(int runs) Function()? cost;
  int costMs;
  final List<({int first, int epochs, int runs})> seen = [];
  Completer<void>? gate;
  Object? fail;
  bool closed = false;

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    seen.add((first: first, epochs: epochs, runs: runs));
    expect(x.length, epochs * 3840 * 4);
    final g = gate;
    if (g != null) await g.future;
    if (fail != null) throw fail!;
    clock?.ms += costMs;
    const names = ['W', 'N1', 'N2', 'N3', 'R'];
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      final k = names.indexOf(script(first + e));
      final z = [for (var j = 0; j < 5; j++) j == k ? 4.0 : 0.0];
      final s = z.fold(0.0, (a, v) => a + math.exp(v));
      for (var j = 0; j < 5; j++) {
        p[e * 5 + j] = math.exp(z[j]) / s;
      }
    }
    return p;
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeClock {
  int ms = 0;
}

/// Pushes [epochs] epochs of a quiet signal (plus the resampler's 20-sample look-ahead), one epoch at a time,
/// letting the stager's calls run in between.
Future<void> feed(LiveStager s, int epochs, {int from = 0}) async {
  for (var e = from; e < from + epochs; e++) {
    for (var k = 0; k < inputEpochSamples; k++) {
      final i = e * inputEpochSamples + k;
      s.push([10 * math.sin(i * 0.25), 8 * math.cos(i * 0.1), 5.0 + (i % 7), -3.0]);
    }
    await pumpCalls(s);
  }
}

/// Lets pending calls finish (the scale and the scripted model complete in microtasks; a gated call stays open).
Future<void> pumpCalls(LiveStager s) async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Float32List> scaleNow(LiveWindow w) async => scaleWindow(w);

LiveStager stager(ScriptedModel m, {FakeClock? clock, bool Function()? mayRun}) => LiveStager(
  model: m,
  prep: LivePrep(window: 12),
  scale: scaleNow,
  mayRun: mayRun,
  clockMs: clock == null ? null : () => clock.ms,
);

void main() {
  test('a call per new epoch from the 10th on; each hands out the epoch 2 minutes (4 epochs) behind (the first also '
      'the epochs before it)', () async {
    final m = ScriptedModel((e) => e < 12 ? 'W' : (e < 16 ? 'N2' : 'N3'));
    final s = stager(m);
    await feed(s, 20);
    // edges 10..19 complete (the 20th waits for 20 more samples): 10 calls
    expect([for (final c in m.seen) c.first + c.epochs], [for (var e = 10; e < 20; e++) e]);
    expect(m.seen.last.first, 7, reason: 'a 12-epoch window');
    expect([for (final st in s.stages) st.epoch], [for (var e = 0; e < 15; e++) e]);
    expect([for (final st in s.stages) st.behind], [9, 8, 7, 6, 5, for (var e = 5; e < 15; e++) behindEpochs]);
    expect([for (final st in s.stages) st.stage].join(','), '${List.filled(12, 'W').join(',')},N2,N2,N2');
    expect(s.stages.first.confidence, closeTo(math.exp(4) / (math.exp(4) + 4), 1e-9));
    expect(m.seen.every((c) => c.runs == 3), isTrue);
    expect(s.mode, LiveMode.full);
  });

  test('an epoch with over 5 s lost is a gap, whatever the model says', () async {
    final m = ScriptedModel((_) => 'N3');
    final s = stager(m);
    await feed(s, 6);
    s.hold(1300); // 5.2 s lost in epoch 6
    await feed(s, 10, from: 6);
    final at6 = s.stages.firstWhere((st) => st.epoch == 6);
    expect(at6.stage, 'gap');
    expect(s.stages.where((st) => st.stage == 'gap'), hasLength(1));
  });

  test('a busy model is not queued: the next call covers the newest epoch and every epoch since the last', () async {
    final m = ScriptedModel((e) => 'N2')..gate = Completer<void>();
    final s = stager(m);
    await feed(s, 11); // edge 10 starts and waits at the gate
    expect(s.busy, isTrue);
    for (var e = 11; e < 14; e++) {
      for (var k = 0; k < inputEpochSamples; k++) {
        s.push([1, 2, 3, 4]);
      }
    }
    expect(m.seen, hasLength(1), reason: 'nothing queued while busy');
    m.gate!.complete();
    m.gate = null;
    await pumpCalls(s);
    expect([for (final c in m.seen) c.first + c.epochs], [10, 13]);
    expect([for (final st in s.stages) (st.epoch, st.behind)], [(0, 9), (1, 8), (2, 7), (3, 6), (4, 5), (5, 4), (6, 6), (7, 5), (8, 4)]);
  });

  test('too slow: 3 runs, then 1 run, then the timer alone, each step said in a sentence', () async {
    final clock = FakeClock();
    final m = ScriptedModel((_) => 'N2', clock: clock, costMs: 9000);
    var changes = 0;
    final s = LiveStager(model: m, prep: LivePrep(window: 12), scale: scaleNow, clockMs: () => clock.ms, onChange: () => changes++);
    await feed(s, 12);
    expect(s.mode, LiveMode.full);
    m.costMs = 16000;
    await feed(s, 1, from: 12);
    expect(s.mode, LiveMode.light);
    expect(s.why, contains('16.0 s'));
    expect(s.why, contains('1 of its 3 runs'));
    await feed(s, 1, from: 13);
    expect(m.seen.last.runs, 1);
    expect(s.mode, LiveMode.timer);
    expect(s.why, contains('timer alone'));
    final n = m.seen.length;
    await feed(s, 3, from: 14);
    expect(m.seen, hasLength(n), reason: 'no model calls on the timer');
    expect(changes, 2);
    expect(s.callTimes!.max, 16000);
  });

  test('a failing model leaves the timer alone and says why', () async {
    final m = ScriptedModel((_) => 'W')..fail = StateError('no ONNX Runtime');
    final s = stager(m);
    await feed(s, 11);
    expect(s.mode, LiveMode.timer);
    expect(s.why, contains('no ONNX Runtime'));
    expect(s.stages, isEmpty);
  });

  test('calls wait while another model runs (last night\'s scoring), then resume', () async {
    var free = false;
    final m = ScriptedModel((_) => 'N1');
    final s = stager(m, mayRun: () => free);
    await feed(s, 13);
    expect(m.seen, isEmpty);
    expect(s.waited, 3);
    free = true;
    await feed(s, 1, from: 13);
    expect(m.seen, hasLength(1));
    expect([for (final st in s.stages) st.epoch], [1, 2, 3, 4, 5, 6, 7, 8], reason: 'the first call gives its whole window');
  });

  test('close waits for the running call and releases the model', () async {
    final m = ScriptedModel((_) => 'W')..gate = Completer<void>();
    final s = stager(m);
    await feed(s, 11);
    final closing = s.close();
    m.gate!.complete();
    await closing;
    expect(m.closed, isTrue);
    expect(s.stages, isEmpty, reason: 'a call that ends after close hands out nothing');
  });

  test('the runs model averages the softmax of the runs it opens, and closes runs it no longer needs', () async {
    final opened = <int>[], closed = <int>[];
    final model = RunsLiveModel(
      open: (r) async {
        opened.add(r);
        return _ConstRun(r);
      },
      closeRun: (run) async => closed.add((run as _ConstRun).run),
    );
    final x = Float32List(2 * 3840 * 4);
    final p3 = await model.probabilities(x, 2, 3, first: 0);
    expect(opened, [1, 2, 3]);
    // run r puts logit 1 on stage r-1: each of W, N1, N2 gets e/(e+4) from one run and 1/(e+4) from two
    final hi = math.e / (math.e + 4), lo = 1 / (math.e + 4);
    expect(p3[0], closeTo((hi + 2 * lo) / 3, 1e-9));
    expect(p3[3], closeTo(lo, 1e-9));
    final p1 = await model.probabilities(x, 2, 1, first: 0);
    expect(closed, [3, 2]);
    expect(p1[0], closeTo(hi, 1e-9));
    await model.close();
    expect(closed, [3, 2, 1]);
  });
}

class _ConstRun implements StageRun {
  _ConstRun(this.run);
  final int run;

  @override
  Future<Float32List> logits(Float32List x, int epochs) async =>
      Float32List.fromList([for (var e = 0; e < epochs; e++) for (var k = 0; k < 5; k++) k == run - 1 ? 1.0 : 0.0]);
}
