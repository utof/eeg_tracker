// The phone's sleep-model input against the laptop's: test/fixtures/sleep_night was made by
// fixtures/make_sleep_fixture.py with scripts/to_bdf.py and scripts/score_sleep.py themselves (rerun it after a
// change to either). Tolerances are far below anything the model could notice: the scaled input is about 1 in size.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/sleep/dsp.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/sleep/prep.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Directory('test/fixtures/sleep_night');
  final expected = jsonDecode(File('${dir.path}/expected.json').readAsStringSync()) as Map<String, dynamic>;
  List<File> files() => [for (final f in expected['files'] as List) File('${dir.path}/$f')];
  List<double> nums(Object? v) => [for (final x in v! as List) (x as num).toDouble()];

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

  test('joining the runs: start, length, gaps and padding as to_bdf.py', () {
    final layout = joinLayout(files());
    expect(layout.startUnix.toDouble(), expected['start_unix']);
    expect(layout.samples, expected['samples']);
    expect([for (final b in layout.bad) [b.at, b.samples, b.text]], [
      for (final b in (expected['bad'] as List).cast<Map<String, dynamic>>()) [b['onset_samples'], b['samples'], b['text']],
    ]);
    final rows = expected['uv_every_500'] as List;
    for (var c = 0; c < 4; c++) {
      final ch = layout.channel(c);
      close([for (var i = 0; i < ch.length; i += 500) ch[i]], [for (final r in rows) nums(r)[c]], 1e-5, 'µV $c');
    }
    final epochs = layout.samples ~/ (250 * 30);
    expect(epochs, expected['n_ep']);
    expect(gapEpochs(layout, epochs), expected['gap']);
  });

  test('filter taps match MNE and SciPy', () {
    final hp = expected['high_pass'] as Map<String, dynamic>;
    final h = mneHighPassTaps(0.3, 250);
    expect(h.length, hp['taps']);
    close(h.sublist(0, 3), nums(hp['first']), 1e-15, 'high-pass first taps');
    expect(h[h.length ~/ 2], closeTo(hp['centre'] as double, 1e-14));
    expect(h.fold(0.0, (s, v) => s + v.abs()), closeTo(hp['sum_abs'] as double, 1e-12));
    final rs = expected['resample'] as Map<String, dynamic>;
    final n = rs['taps'] as int;
    final lp = firwinLowPass(n, 1 / 125, kaiserWindow(n, 5.0));
    close(lp.sublist(0, 3), nums(rs['first']), 1e-15, 'resampler first taps');
    expect(lp[n ~/ 2], closeTo(rs['centre'] as double, 1e-15));
    expect(lp.fold(0.0, (s, v) => s + v.abs()), closeTo(rs['sum_abs'] as double, 1e-12));
  });

  test('high-pass, resampling and percentiles match the Python step by step', () {
    final layout = joinLayout(files());
    final taps = mneHighPassTaps(0.3, 250);
    final filteredWant = expected['filtered_uv_every_40'] as List;
    final resampledWant = expected['resampled_uv_every_20'] as List;
    final pctWant = expected['percentiles_uv'] as List;
    for (var c = 0; c < 4; c++) {
      final filtered = zeroPhaseFir(layout.channel(c), taps);
      close([for (var i = 0; i < filtered.length; i += 40) filtered[i]], nums(filteredWant[c]), 1e-7, 'filtered $c');
      final resampled = resamplePoly(filtered, 128, 250);
      expect(resampled.length, expected['resampled_samples']);
      close([for (var i = 0; i < resampled.length; i += 20) resampled[i]], nums(resampledWant[c]), 1e-7,
          'resampled $c');
      close(percentiles(resampled, const [25, 50, 75]), nums(pctWant[c]), 1e-9, 'percentiles $c');
    }
  });

  test('the whole model input matches score_sleep.prepare to float32 precision', () {
    final input = prepareNight(files(), atLeast: 1)!; // the fixture is 5 epochs long
    final shape = (expected['model_input_shape'] as List).cast<int>();
    expect(input.epochs * epochSamples, shape[0]);
    expect(input.gap, expected['gap']);
    final want = File('${dir.path}/${expected['model_input']}').readAsBytesSync();
    final w = Float32List.view(Uint8List.fromList(want).buffer);
    final got = input.interleaved(0, input.epochs);
    expect(got.length, w.length);
    close(got.toList(), w.toList(), 2e-6, 'model input');
  });

  test('a night under 5 minutes is not prepared', () {
    final tmp = Directory.systemTemp.createTempSync('short_night');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/2026-11-24-001200.f32')..writeAsBytesSync(Uint8List(20 * 250 * 60));
    expect(prepareNight([f]), isNull);
  });

  test('percentiles follow NumPy, including ties and both halves of the interpolation', () {
    final x = Float64List.fromList([5, 1, 4, 4, 2, 9, 7, 3]);
    // np.percentile([5,1,4,4,2,9,7,3], [0, 10, 25, 50, 75, 90, 100]) = 1, 1.7, 2.75, 4, 5.5, 7.6, 9
    close(percentiles(x, const [0, 10, 25, 50, 75, 90, 100]), [1, 1.7, 2.75, 4, 5.5, 7.6, 9], 1e-12, 'small');
    expect(x, [5, 1, 4, 4, 2, 9, 7, 3]); // the caller's data is not reordered
  });

  test('Python rounding: halves go to the even neighbour', () {
    expect([0.5, 1.5, 2.5, -0.5, 2.4999, 2.5001].map(roundHalfEven), [0, 2, 2, 0, 2, 3]);
  });
}
