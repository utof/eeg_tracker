// AnySleep on the phone: the three runs' mean softmax per 30 s epoch, as scripts/score_sleep.py `anysleep`, with
// the night fed in pieces so memory stays bounded (DECISIONS row 96): each model call scores [pieceEpochs] epochs
// and sees [contextEpochs] more on each side. The runtime sits behind [StageRun] (ONNX in onnx_runs.dart, fakes in
// tests), so this file is plain Dart.
import 'dart:math' as math;
import 'dart:typed_data';

import 'periods.dart' show gapStage, stageNames;
import 'prep.dart';

/// One hour scored per call, 15 minutes of context each side: a 1.5-hour input, about 250 MB in ONNX Runtime.
const int pieceEpochs = 120;
const int contextEpochs = 30;

/// The phone's model, for the report's `model` field (the laptop writes `anysleep-mid-fusion-3runs@88e13e3`).
const String phoneModelId = 'anysleep-mid-fusion-3runs@88e13e3 onnx-f16 pieces-1h+15min';

abstract interface class StageRun {
  /// Logits, epochs x 5 (W N1 N2 N3 R), for [x]: (epochs * 3840) samples x 4 channels, time-major.
  Future<Float32List> logits(Float32List x, int epochs);
}

/// (first, end) epochs of each model input and (first, end) of the epochs kept from it.
typedef Piece = ({int w0, int w1, int c0, int c1});

List<Piece> pieces(int epochs, {int piece = pieceEpochs, int context = contextEpochs}) {
  if (epochs <= piece + 2 * context) return [(w0: 0, w1: epochs, c0: 0, c1: epochs)];
  return [
    for (var c0 = 0; c0 < epochs; c0 += piece)
      (
        w0: math.max(0, c0 - context),
        w1: math.min(epochs, c0 + piece + context),
        c0: c0,
        c1: math.min(epochs, c0 + piece),
      ),
  ];
}

/// Mean softmax of the runs, epochs x 5. [runs] are opened one at a time by [open] and closed by [close], so only
/// one model is in memory. [progress] gets "run k of n".
Future<Float64List> stageProbabilities(
  ModelInput input,
  int runCount,
  Future<StageRun> Function(int run) open, {
  Future<void> Function(StageRun run)? close,
  void Function(int run, int piece, int pieces)? progress,
  int piece = pieceEpochs,
  int context = contextEpochs,
}) async {
  final n = input.epochs;
  final sum = Float64List(n * 5);
  final plan = pieces(n, piece: piece, context: context);
  for (var r = 1; r <= runCount; r++) {
    final run = await open(r);
    try {
      for (var k = 0; k < plan.length; k++) {
        progress?.call(r, k + 1, plan.length);
        final p = plan[k];
        final logits = await run.logits(input.interleaved(p.w0, p.w1), p.w1 - p.w0);
        if (logits.length != (p.w1 - p.w0) * 5) {
          throw StateError('the model gave ${logits.length} values for ${p.w1 - p.w0} epochs');
        }
        for (var e = p.c0; e < p.c1; e++) {
          _addSoftmax(logits, (e - p.w0) * 5, sum, e * 5);
        }
      }
    } finally {
      await close?.call(run);
    }
  }
  for (var i = 0; i < sum.length; i++) {
    sum[i] /= runCount;
  }
  return sum;
}

void _addSoftmax(Float32List z, int at, Float64List out, int to) {
  var m = double.negativeInfinity;
  for (var k = 0; k < 5; k++) {
    m = math.max(m, z[at + k]);
  }
  final e = [for (var k = 0; k < 5; k++) math.exp(z[at + k] - m)];
  final s = e.reduce((a, b) => a + b);
  for (var k = 0; k < 5; k++) {
    out[to + k] += e[k] / s;
  }
}

/// The stage of each epoch (the most probable one, `gap` where over 5 s were missing) and its top probability.
({List<String> stages, List<double> confidence}) stagesOf(Float64List probs, List<bool> gap) {
  final n = gap.length;
  final stages = <String>[];
  final conf = <double>[];
  for (var e = 0; e < n; e++) {
    var best = 0;
    for (var k = 1; k < 5; k++) {
      if (probs[e * 5 + k] > probs[e * 5 + best]) best = k;
    }
    stages.add(gap[e] ? gapStage : stageNames[best]);
    conf.add(probs[e * 5 + best]);
  }
  return (stages: stages, confidence: conf);
}
