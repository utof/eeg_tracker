// The phone's two-pass scorer (lib/sleep/model.dart) against the Python reference (analysis/two_pass.py):
// test/fixtures/two_pass was made by test/fixtures/make_two_pass_fixture.py with the app's real model (run 1) on a
// small synthetic night. ONNX Runtime cannot run in `flutter test`, so a fake run replays what the model returned
// there and checks every input the Dart scorer hands it: the window, the kept epochs and the night's averages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/sleep/model.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fixture night's samples, exact in float32 (as make_two_pass_fixture.signal).
double signal(int t, int c) => ((37 * t + 1013 * c) % 997 - 498) / 128;

ModelInput night(int epochs, {List<bool>? gap}) => ModelInput(
  startUnix: 0,
  epochs: epochs,
  gap: gap ?? List.filled(epochs, false),
  channels: [
    for (var c = 0; c < 4; c++) Float32List.fromList([for (var t = 0; t < epochs * epochSamples; t++) signal(t, c)]),
  ],
  percentiles: const [],
  recordedSamples: epochs * 7500,
  missingSamples: 0,
);

void main() {
  final dir = Directory('test/fixtures/two_pass');
  final meta = jsonDecode(File('${dir.path}/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final blob = Float32List.sublistView(File('${dir.path}/outputs.bin').readAsBytesSync());
  final calls = [for (final p in meta['pieces'] as List) p as Map<String, dynamic>];

  test('the means are as wide as the models\' 13 skip connections', () {
    expect(meansWidth, meta['means_width']);
  });

  test('the pieces are the Python reference\'s for every night length', () {
    final plans = meta['plans'] as Map<String, dynamic>;
    for (final e in plans.entries) {
      final want = [for (final p in e.value as List) (p as List).cast<int>()];
      expect(
        [
          for (final p in pieces(int.parse(e.key))) [p.w0, p.w1, p.c0, p.c1],
        ],
        want,
        reason: 'night of ${e.key}',
      );
    }
  });

  test('pieces tile the night on the 16-epoch grid, each with 8+ minutes of context inside the night', () {
    for (final n in [1, 175, 176, 300, 1549, 1680, 1681, 2000]) {
      final ps = pieces(n);
      expect(
        [
          for (final p in ps)
            for (var e = p.c0; e < p.c1; e++) e,
        ],
        List.generate(n, (e) => e),
        reason: '$n',
      );
      if (ps.length == 1) {
        expect(n, lessThanOrEqualTo(maxWindowEpochs));
        continue;
      }
      for (final p in ps) {
        expect((p.w0 % gridEpochs, (n - p.w1) % gridEpochs), (0, 0), reason: '$n $p');
        expect(p.w1 - p.w0, lessThanOrEqualTo(maxWindowEpochs));
        expect(p.c0 - p.w0, p.c0 == 0 ? 0 : contextEpochs);
        expect(p.w1 == n || p.w1 - p.c1 >= contextEpochs, isTrue, reason: '$n $p'); // or the rest of the night
      }
    }
  });

  test('scores the night in two passes exactly as the Python reference', () async {
    final n = meta['epochs'] as int;
    final run = _Replay(calls, blob);
    final probs = await stageProbabilities(
      night(n),
      1,
      (r) async => run,
      piece: meta['piece'] as int,
      context: meta['context'] as int,
    );
    expect(run.log, [
      for (var k = 0; k < calls.length; k++) 'sums $k',
      for (var k = 0; k < calls.length; k++) 'logits $k',
    ]);
    final want = [
      for (final row in meta['probabilities'] as List)
        for (final v in row as List) (v as num).toDouble(),
    ];
    expect(probs.length, want.length);
    for (var i = 0; i < want.length; i++) {
      expect(probs[i], closeTo(want[i], 1e-6), reason: 'value $i');
    }
    expect(stagesOf(probs, List.filled(n, false)).stages, meta['stages']);
  });

  test('progress counts both passes', () async {
    final steps = <(int, int, int)>[];
    await stageProbabilities(
      night(meta['epochs'] as int),
      1,
      (r) async => _Replay(calls, blob),
      piece: meta['piece'] as int,
      context: meta['context'] as int,
      progress: (r, k, n) => steps.add((r, k, n)),
    );
    expect(steps, [for (var k = 1; k <= 2 * calls.length; k++) (1, k, 2 * calls.length)]);
  });

  test('a night that fits one input is one call per run, weighed by its own averages (one pass)', () async {
    final run = _Replay(calls, blob, ownOnly: true);
    await stageProbabilities(night(20), 3, (r) async => run);
    expect(run.log, ['own 20', 'own 20', 'own 20']);
  });

  test('sums that do not match the means\' width are an error, not a report', () async {
    final run = _Replay(calls, blob, badSums: true);
    await expectLater(
      stageProbabilities(
        night(meta['epochs'] as int),
        1,
        (r) async => run,
        piece: meta['piece'] as int,
        context: meta['context'] as int,
      ),
      throwsStateError,
    );
  });
}

/// Replays the model outputs of the fixture, in the order the reference called the model, and checks each input.
class _Replay implements StageRun {
  _Replay(this.calls, this.blob, {this.ownOnly = false, this.badSums = false});
  final List<Map<String, dynamic>> calls;
  final Float32List blob;
  final bool ownOnly;
  final bool badSums;
  final log = <String>[];
  int _pass1 = 0, _pass2 = 0;

  int get _p1Size => 5 * meansWidth; // sums (4 x width) + counts (width)

  void _expectWindow(Float32List x, int epochs, Map<String, dynamic> call) {
    final w0 = call['w0'] as int, w1 = call['w1'] as int;
    expect(epochs, w1 - w0);
    expect(x.length, epochs * epochSamples * 4);
    final last = epochs * epochSamples - 1;
    for (var c = 0; c < 4; c++) {
      expect((x[c], x[last * 4 + c]), (signal(w0 * epochSamples, c), signal(w0 * epochSamples + last, c)));
    }
  }

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) async {
    expect(ownOnly, isFalse);
    final k = _pass1++;
    _expectWindow(x, epochs, calls[k]);
    expect([from, to], calls[k]['keep']);
    log.add('sums $k');
    final at = k * _p1Size;
    return (
      sums: Float32List.sublistView(blob, at, at + 4 * meansWidth - (badSums ? 1 : 0)),
      counts: Float32List.sublistView(blob, at + 4 * meansWidth, at + _p1Size),
    );
  }

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async {
    if (ownOnly) {
      expect(means, isNull);
      log.add('own $epochs');
      return Float32List(epochs * 5);
    }
    final k = _pass2++;
    _expectWindow(x, epochs, calls[k]);
    var at = calls.length * _p1Size;
    for (var j = 0; j < k; j++) {
      at += ((calls[j]['w1'] as int) - (calls[j]['w0'] as int)) * 5;
    }
    final meansAt = blob.length - 4 * meansWidth;
    expect(means, isNotNull);
    expect(means!.length, 4 * meansWidth);
    for (var i = 0; i < means.length; i++) {
      final want = blob[meansAt + i];
      expect((means[i] - want).abs(), lessThanOrEqualTo(1e-6 * (1 + want.abs())), reason: 'mean $i');
    }
    log.add('logits $k');
    return Float32List.sublistView(blob, at, at + epochs * 5);
  }
}
