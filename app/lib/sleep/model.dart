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

/// Model calls for a night of [epochs]: per run one call when it fits one piece, else a call per piece in each pass.
int modelCalls(int epochs, int runCount, {int piece = pieceEpochs, int context = contextEpochs}) {
  final n = pieces(epochs, piece: piece, context: context).length;
  return runCount * (n == 1 ? 1 : 2 * n);
}

/// Where [stageProbabilities] is in a night, after its last finished model call: what a restart needs to go on
/// from there instead of starting over (DECISIONS row 581). The sums stay in float64 as they were, so a night scored
/// in several goes gets the very numbers of one go.
class ModelProgress {
  ModelProgress(this.epochs, {required this.runCount})
    : sum = Float64List(epochs * 5),
      passSums = Float64List(4 * meansWidth),
      passCounts = Float64List(meansWidth);

  ModelProgress._(this.epochs, this.runCount, this.sum, this.passSums, this.passCounts);

  final int epochs;
  final int runCount;

  /// The run under way (1-based); `runCount + 1` once every run is done.
  int run = 1;

  /// 1: adding up the night's averages, 2: scoring the pieces with them.
  int pass = 1;

  /// The next piece of this pass.
  int piece = 0;

  /// Model calls done so far, over every run.
  int calls = 0;

  /// Softmax summed over the kept epochs scored so far (epochs x 5, all runs).
  final Float64List sum;

  /// Pass 1 of the run under way so far: the skip-connection features summed (4 x [meansWidth]) and their counts.
  final Float64List passSums;
  final Float64List passCounts;

  /// The run's night averages, once its pass 1 is done (null in pass 1 and for a night of one piece).
  Float32List? means;

  bool get done => run > runCount;

  /// Whether this progress can go on over a night of [epochs] cut into [pieceCount] pieces by [runCount] runs.
  bool fits(int epochs, int runCount, int pieceCount) =>
      epochs == this.epochs &&
      runCount == this.runCount &&
      piece <= pieceCount &&
      (done || pieceCount == 1 || pass == 1 || means != null) &&
      calls <= runCount * (pieceCount == 1 ? 1 : 2 * pieceCount);

  static const String _magic = 'EEGSP1';

  /// The progress as bytes, for a file; [fromBytes] reads them back exactly.
  Uint8List toBytes() {
    final m = means;
    final b = BytesBuilder(copy: false)..add(_magic.codeUnits);
    final head = ByteData(4 * 7)
      ..setInt32(0, epochs, Endian.little)
      ..setInt32(4, runCount, Endian.little)
      ..setInt32(8, run, Endian.little)
      ..setInt32(12, pass, Endian.little)
      ..setInt32(16, piece, Endian.little)
      ..setInt32(20, calls, Endian.little)
      ..setInt32(24, m == null ? 0 : 1, Endian.little);
    b
      ..add(head.buffer.asUint8List())
      ..add(_bytes(sum))
      ..add(_bytes(passSums))
      ..add(_bytes(passCounts));
    if (m != null) b.add(Uint8List.fromList(m.buffer.asUint8List(m.offsetInBytes, m.lengthInBytes)));
    return b.takeBytes();
  }

  static Uint8List _bytes(Float64List v) {
    final out = ByteData(v.length * 8);
    for (var i = 0; i < v.length; i++) {
      out.setFloat64(i * 8, v[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// The progress in [b], or null when it is not one (wrong header, sizes or numbers): never trusted blindly.
  static ModelProgress? fromBytes(Uint8List b) {
    const head = 6 + 4 * 7;
    if (b.length < head || String.fromCharCodes(b.sublist(0, 6)) != _magic) return null;
    final d = ByteData.sublistView(b);
    int at(int k) => d.getInt32(6 + 4 * k, Endian.little);
    final epochs = at(0), runCount = at(1), run = at(2), pass = at(3), piece = at(4), calls = at(5), hasMeans = at(6);
    if (epochs <= 0 || runCount <= 0 || run < 1 || run > runCount + 1 || (pass != 1 && pass != 2)) return null;
    if (piece < 0 || calls < 0 || (hasMeans != 0 && hasMeans != 1)) return null;
    final want = head + 8 * (epochs * 5 + 5 * meansWidth) + (hasMeans == 1 ? 4 * 4 * meansWidth : 0);
    if (b.length != want) return null;
    var o = head;
    Float64List f64(int n) {
      final v = Float64List(n);
      for (var i = 0; i < n; i++) {
        v[i] = d.getFloat64(o + i * 8, Endian.little);
      }
      o += n * 8;
      return v;
    }

    final p = ModelProgress._(epochs, runCount, f64(epochs * 5), f64(4 * meansWidth), f64(meansWidth))
      ..run = run
      ..pass = pass
      ..piece = piece
      ..calls = calls;
    if (hasMeans == 1) {
      final m = Float32List(4 * meansWidth);
      for (var i = 0; i < m.length; i++) {
        m[i] = d.getFloat32(o + i * 4, Endian.little);
      }
      p.means = m;
    }
    final all = [...p.sum, ...p.passSums, ...p.passCounts, ...?p.means];
    return all.every((v) => v.isFinite) ? p : null;
  }

  /// One piece of pass 1 added.
  void _addSums(SkipSums s) {
    if (s.sums.length != passSums.length || s.counts.length != passCounts.length) {
      throw StateError(
        'the model gave ${s.sums.length} sums and ${s.counts.length} counts, not ${passSums.length} '
        'and ${passCounts.length}',
      );
    }
    for (var i = 0; i < passSums.length; i++) {
      passSums[i] += s.sums[i];
    }
    for (var i = 0; i < passCounts.length; i++) {
      passCounts[i] += s.counts[i];
    }
  }

  /// Pass 1 is done: the night's average of every skip-connection feature, 4 x [meansWidth], and on to pass 2.
  void _toPass2() {
    final m = Float32List(passSums.length);
    for (var i = 0; i < passSums.length; i++) {
      m[i] = passSums[i] / passCounts[i % meansWidth];
    }
    means = m;
    pass = 2;
    piece = 0;
    passSums.fillRange(0, passSums.length, 0);
    passCounts.fillRange(0, passCounts.length, 0);
  }

  void _nextRun() {
    run++;
    pass = 1;
    piece = 0;
    means = null;
  }
}

/// Mean softmax of the runs, epochs x 5. [runs] are opened one at a time by [open] and closed by [close], so only
/// one model is in memory. Each run makes pass 1 and pass 2 over the pieces (one call when the night is one piece);
/// [progress] gets the run and the step k of n over both passes.
///
/// Resumable (DECISIONS row 581): [from] goes on where an earlier go stopped; [saved] gets the progress after every
/// model call (to keep on disk); [between] runs before every call and may wait (the laptop copies) or throw (a night
/// starts), which ends this go with the progress of its last call saved.
Future<Float64List> stageProbabilities(
  ModelInput input,
  int runCount,
  Future<StageRun> Function(int run) open, {
  Future<void> Function(StageRun run)? close,
  void Function(int run, int step, int steps)? progress,
  int piece = pieceEpochs,
  int context = contextEpochs,
  ModelProgress? from,
  Future<void> Function(ModelProgress p)? saved,
  Future<void> Function()? between,
}) async {
  final n = input.epochs;
  final plan = pieces(n, piece: piece, context: context);
  final two = plan.length > 1;
  final p = from ?? ModelProgress(n, runCount: runCount);
  if (!p.fits(n, runCount, plan.length)) {
    throw ArgumentError('the saved progress (${p.epochs} epochs, ${p.runCount} runs) does not fit this night');
  }
  final first = two ? plan.length : 0; // pass 1's steps
  while (!p.done) {
    final r = p.run;
    if (!two) p.pass = 2;
    await between?.call();
    final run = await open(r);
    try {
      while (p.run == r && p.pass == 1 && p.piece < plan.length) {
        await between?.call();
        final k = p.piece, pc = plan[k];
        progress?.call(r, k + 1, first + plan.length);
        p._addSums(await run.sums(input.interleaved(pc.w0, pc.w1), pc.w1 - pc.w0, from: pc.c0 - pc.w0, to: pc.c1 - pc.w0));
        p
          ..piece = k + 1
          ..calls += 1;
        if (p.piece == plan.length) p._toPass2();
        await saved?.call(p);
      }
      while (p.run == r && p.piece < plan.length) {
        await between?.call();
        final k = p.piece, pc = plan[k];
        progress?.call(r, first + k + 1, first + plan.length);
        final logits = await run.logits(input.interleaved(pc.w0, pc.w1), pc.w1 - pc.w0, means: two ? p.means : null);
        if (logits.length != (pc.w1 - pc.w0) * 5) {
          throw StateError('the model gave ${logits.length} values for ${pc.w1 - pc.w0} epochs');
        }
        for (var e = pc.c0; e < pc.c1; e++) {
          addSoftmax(logits, (e - pc.w0) * 5, p.sum, e * 5);
        }
        p
          ..piece = k + 1
          ..calls += 1;
        if (p.piece == plan.length) p._nextRun();
        await saved?.call(p);
      }
    } finally {
      await close?.call(run);
    }
  }
  return meanProbabilities(p);
}

/// The runs' mean softmax, epochs x 5, from a finished [p].
Float64List meanProbabilities(ModelProgress p) {
  final out = Float64List.fromList(p.sum);
  for (var i = 0; i < out.length; i++) {
    out[i] /= p.runCount;
  }
  return out;
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
