// The live sleep scorer's input against its Python reference (analysis/live_stager.py): test/fixtures/live_night.json
// was made by fixtures/make_live_fixture.py from a synthetic stream that this test repeats sample by sample
// (rerun it after a change to the reference). Tolerances are far below anything the model could notice: 1e-7 µV
// on the filtered and resampled signal (the high-pass carries offsets of tens of mV, so float64 rounding adds up
// to a few 1e-9 µV), 2e-6 on the scaled input (about 1 in size, float32).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/sleep/live_prep.dart';
import 'package:eeg_tracker/sleep/prep.dart' show epochSamples;
import 'package:flutter_test/flutter_test.dart';

final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/live_night.json').readAsStringSync()) as Map<String, dynamic>;

List<double> nums(Object? v) => [for (final x in v! as List) (x as num).toDouble()];

/// make_live_fixture.py `noise`: uniform noise with unit variance from an integer hash of (sample, channel).
double _noise(int k, int c) {
  final h = ((k * 4 + c) * 2654435761) % (1 << 32);
  return (h / (1 << 32).toDouble() - 0.5) * math.sqrt(12.0);
}

/// make_live_fixture.py `stream`, one sample at a time, before the holes.
List<double> liveFixtureRow(int k) {
  final t = k / 250;
  final off = nums(fx['offsets']);
  return [
    for (var c = 0; c < 4; c++)
      off[c] +
          30 * t +
          (c < 2 ? 20 * math.sin(2 * math.pi * 10 * t) : 30 * math.sin(2 * math.pi * 0.8 * t + 1)) +
          8 * _noise(k, c) +
          (k % 4000 < 20 ? (c.isEven ? 2000 : -2000) : 0),
  ];
}

/// Streams the fixture into [onRow] as the phone would: holes held at the last value and marked missing.
void streamFixture(void Function(List<double> row, bool missing) onRow) {
  final holes = [for (final h in fx['holes'] as List) (h as List).cast<int>()];
  final n = fx['samples'] as int;
  List<double>? last;
  for (var k = 0; k < n; k++) {
    final held = holes.any((h) => k >= h[0] && k < h[0] + h[1]);
    final row = held ? last! : liveFixtureRow(k);
    onRow(row, held);
    last = row;
  }
}

void close(List<double> got, List<double> want, double tol, String what) {
  expect(got.length, want.length, reason: '$what length');
  var worst = 0.0, at = -1;
  for (var i = 0; i < got.length; i++) {
    final d = (got[i] - want[i]).abs();
    if (d > worst) {
      worst = d;
      at = i;
    }
  }
  expect(worst, lessThan(tol), reason: '$what differs most at $at: ${at < 0 ? '' : '${got[at]} vs ${want[at]}'}');
}

void main() {
  test('the stream formula matches the fixture (so both sides see the same samples)', () {
    final rows = <List<double>>[];
    streamFixture((r, _) => rows.add(r));
    final want = [for (final r in fx['input_every_997'] as List) nums(r)];
    for (var i = 0; i < want.length; i++) {
      close(rows[i * 997], want[i], 1e-7, 'input row ${i * 997}');
    }
  });

  test('the 0.3 Hz high-pass: SciPy Butterworth coefficients, steady start, forward only', () {
    final hp = HighPass2.butterworth(0.3, 250);
    close([hp.b0, hp.b1, hp.b2, 1, hp.a1, hp.a2], nums(fx['sos']), 1e-15, 'sos');
    final zi = nums(fx['zi_per_unit']);
    final f = [for (var c = 0; c < 4; c++) HighPass2.butterworth(0.3, 250)];
    final out = <double>[];
    var k = 0;
    streamFixture((r, _) {
      if (k == 0) {
        expect(f[0].startState(r[0]), [closeTo(zi[0] * r[0], 1e-9), closeTo(zi[1] * r[0], 1e-9)]);
      }
      if (k < 3000 && k % 10 == 0) {
        out.addAll([for (var c = 0; c < 4; c++) f[c].step(r[c])]);
      } else if (k < 3000) {
        for (var c = 0; c < 4; c++) {
          f[c].step(r[c]);
        }
      }
      k++;
    });
    close(out, [for (final r in fx['filtered_every_10'] as List) ...nums(r)], 1e-7, 'filtered µV');
  });

  test('the streaming resampler gives resample_poly of the whole stream, each sample once its inputs exist', () {
    final prep = LivePrep(window: fx['window'] as int);
    streamFixture((r, m) => prep.push(r, missing: m));
    expect(prep.modelSamples, fx['ready_model_samples']);
    expect(prep.epochs, fx['n_ep']);
    expect([for (var e = 0; e < prep.epochs; e++) prep.gapAt(e)], fx['gap']);
    // the last window still holds every sample of its epochs: compare those at every 41st position
    final w = prep.window(prep.epochs);
    final want = [for (final r in fx['resampled_every_41'] as List) nums(r)];
    var compared = 0;
    for (var i = 0; i < want.length; i++) {
      final s = i * 41 - w.first * epochSamples;
      if (s < 0 || s >= w.channels[0].length) continue;
      close([for (var c = 0; c < 4; c++) w.channels[c][s]], want[i], 1e-7, 'resampled sample ${i * 41}');
      compared++;
    }
    expect(compared, greaterThan(500));
  });

  test('every call: the same window, gap flags, percentiles and scaled input as the Python reference', () {
    final prep = LivePrep(window: fx['window'] as int);
    final calls = (fx['calls'] as List).cast<Map<String, dynamic>>();
    var next = 0;
    final minEpochs = fx['min_epochs'] as int;
    streamFixture((r, m) {
      final before = prep.epochs;
      prep.push(r, missing: m);
      if (prep.epochs == before || prep.epochs < minEpochs) return;
      final want = calls[next++];
      final w = prep.window(prep.epochs);
      expect([w.first, w.end], [want['first'], want['end']]);
      expect(w.gap, want['gap']);
      final x = scaleWindow(w);
      expect(x.length, want['scaled_len']);
      for (var c = 0; c < 4; c++) {
        close(w.percentiles(c), nums((want['percentiles_uv'] as List)[c]), 1e-7, 'percentiles $c at ${w.end}');
      }
      close([for (var i = 0; i < x.length; i += 151) x[i]], nums(want['scaled_every_151']), 2e-6, 'input at ${w.end}');
    });
    expect(next, calls.length);
  });

  test('values are clipped at the BDF limit and a hold of n samples counts as missing', () {
    final prep = LivePrep(window: 4);
    for (var k = 0; k < 7600; k++) {
      prep.push([k == 10 ? 9e9 : 1.0, 1, 1, 1]);
    }
    prep.hold(7500);
    for (var k = 0; k < 100; k++) {
      prep.push([1, 1, 1, 1]);
    }
    expect(prep.epochs, 2);
    expect(prep.gapAt(0), isFalse);
    expect(prep.gapAt(1), isTrue);
    expect(prep.lastClipped, 400000);
    expect(() => prep.window(1), throwsStateError, reason: 'only the newest edge is kept whole');
  });

  test('a window never keeps more than its epochs, and memory stays bounded over a long stream', () {
    final prep = LivePrep(window: 3);
    final row = <double>[5, 6, 7, 8];
    for (var k = 0; k < 7500 * 9 + 30; k++) {
      prep.push(row);
    }
    final w = prep.window(prep.epochs);
    expect([w.first, w.end], [6, 9]);
    expect(w.channels.every((c) => c.length == 3 * epochSamples), isTrue);
    expect(prep.heldBytes, lessThan(4 * 4 * epochSamples * 8 + 100000));
    expect(scaleWindow(w), isA<Float32List>());
  });
}
