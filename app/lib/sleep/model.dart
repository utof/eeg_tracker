// AnySleep on the phone: the three runs' mean softmax per 30 s epoch, as scripts/score_sleep.py `anysleep`, with
// the night fed in pieces so memory stays bounded (DECISIONS rows 96 and 260-264). AnySleep weighs its four channels
// by their features' average over its whole input, so each run scores the night in two passes: pass 1 adds up those
// features over the epochs each piece keeps, pass 2 scores every piece weighed by the night's averages. The pieces
// sit on a 16-epoch grid, so each computes on its kept epochs what one pass over the whole night computes
// (analysis/two_pass.py, the reference). The runtime sits behind [StageRun] (ONNX in onnx_runs.dart, fakes in
// tests), so this file is plain Dart.
import 'dart:math' as math;
import 'dart:typed_data';

import 'periods.dart' show gapStage, stageNames;
import 'prep.dart';

/// 64 minutes kept per call, at least 8 minutes of context each side (AnySleep sees about 7 minutes either way).
const int pieceEpochs = 128;
const int contextEpochs = 16;

/// AnySleep halves the time axis 12 times: only pieces that start a multiple of 16 epochs after the night's start
/// and end a multiple of 16 before its end pool and pad their samples as one pass over the night does.
const int gridEpochs = 16;

/// The longest model input: 175 epochs (87.5 minutes, about 250 MB in ONNX Runtime); a shorter night is one piece.
const int maxWindowEpochs = pieceEpochs + 2 * contextEpochs + gridEpochs - 1;

/// Features over AnySleep's 13 skip connections (6 + 9 + ... + 302): the width of the night's averages.
const int meansWidth = 1037;

/// The phone's model, for the report's `model` field (the laptop writes `anysleep-mid-fusion-3runs@88e13e3`).
/// A report the phone scored with another one is scored again once (report.dart `isStale`).
const String phoneModelId = 'anysleep-mid-fusion-3runs@88e13e3 onnx-f16 two-pass-64min+8min';

/// What pass 1 gets from one piece: AnySleep's skip-connection features summed over the kept epochs, channel by
/// channel (4 x [meansWidth], channel-major), and how many samples each sum covers ([meansWidth]).
typedef SkipSums = ({Float32List sums, Float32List counts});

abstract interface class StageRun {
  /// Logits, epochs x 5 (W N1 N2 N3 R), for [x]: (epochs * 3840) samples x 4 channels, time-major. The channels are
  /// weighed by [means] (4 x [meansWidth], the night's averages from pass 1) or, without it, by [x]'s own averages
  /// (AnySleep as it is: the live scorer, and a night that fits one piece).
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means});

  /// Pass 1: the skip-connection features of [x] summed over its epochs [from, to).
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to});
}

/// (first, end) epochs of each model input and (first, end) of the epochs kept from it.
typedef Piece = ({int w0, int w1, int c0, int c1});

/// Kept epochs [c0, c1) tile the night; every input starts a multiple of [gridEpochs] after the night's start and
/// ends a multiple of it before the night's end ([piece] and [context] must be multiples of it too).
List<Piece> pieces(int epochs, {int piece = pieceEpochs, int context = contextEpochs}) {
  assert(piece % gridEpochs == 0 && context % gridEpochs == 0);
  if (epochs <= piece + 2 * context + gridEpochs - 1) return [(w0: 0, w1: epochs, c0: 0, c1: epochs)];
  return [
    for (var c0 = 0; c0 < epochs; c0 += piece)
      (
        w0: math.max(0, c0 - context),
        w1: _onGrid(math.min(epochs, c0 + piece) + context, epochs),
        c0: c0,
        c1: math.min(epochs, c0 + piece),
      ),
  ];
}

/// The first end at or after [w1] that lies a multiple of [gridEpochs] before [epochs], or the night's end.
int _onGrid(int w1, int epochs) => math.min(epochs, w1 + (epochs - w1) % gridEpochs);

/// Pass 1 for one run: the night's average of every skip-connection feature, 4 x [meansWidth].
Future<Float32List> nightMeans(
  StageRun run,
  ModelInput input,
  List<Piece> plan, {
  void Function(int piece)? progress,
}) async {
  final sums = Float64List(4 * meansWidth), counts = Float64List(meansWidth);
  for (var k = 0; k < plan.length; k++) {
    progress?.call(k);
    final p = plan[k];
    final s = await run.sums(input.interleaved(p.w0, p.w1), p.w1 - p.w0, from: p.c0 - p.w0, to: p.c1 - p.w0);
    if (s.sums.length != sums.length || s.counts.length != counts.length) {
      throw StateError(
        'the model gave ${s.sums.length} sums and ${s.counts.length} counts, not ${sums.length} '
        'and ${counts.length}',
      );
    }
    for (var i = 0; i < sums.length; i++) {
      sums[i] += s.sums[i];
    }
    for (var i = 0; i < counts.length; i++) {
      counts[i] += s.counts[i];
    }
  }
  final means = Float32List(sums.length);
  for (var i = 0; i < sums.length; i++) {
    means[i] = sums[i] / counts[i % meansWidth];
  }
  return means;
}

/// Mean softmax of the runs, epochs x 5. [runs] are opened one at a time by [open] and closed by [close], so only
/// one model is in memory. Each run makes pass 1 and pass 2 over the pieces (one call when the night is one piece);
/// [progress] gets the run and the step k of n over both passes.
Future<Float64List> stageProbabilities(
  ModelInput input,
  int runCount,
  Future<StageRun> Function(int run) open, {
  Future<void> Function(StageRun run)? close,
  void Function(int run, int step, int steps)? progress,
  int piece = pieceEpochs,
  int context = contextEpochs,
}) async {
  final n = input.epochs;
  final sum = Float64List(n * 5);
  final plan = pieces(n, piece: piece, context: context);
  final first = plan.length == 1 ? 0 : plan.length; // pass 1's steps
  for (var r = 1; r <= runCount; r++) {
    final run = await open(r);
    try {
      final means = plan.length == 1
          ? null
          : await nightMeans(run, input, plan, progress: (k) => progress?.call(r, k + 1, first + plan.length));
      for (var k = 0; k < plan.length; k++) {
        progress?.call(r, first + k + 1, first + plan.length);
        final p = plan[k];
        final logits = await run.logits(input.interleaved(p.w0, p.w1), p.w1 - p.w0, means: means);
        if (logits.length != (p.w1 - p.w0) * 5) {
          throw StateError('the model gave ${logits.length} values for ${p.w1 - p.w0} epochs');
        }
        for (var e = p.c0; e < p.c1; e++) {
          addSoftmax(logits, (e - p.w0) * 5, sum, e * 5);
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

/// Adds the softmax of the 5 logits at z[at..] to out[to..].
void addSoftmax(Float32List z, int at, Float64List out, int to) {
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
