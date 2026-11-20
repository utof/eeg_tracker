// Cross-check: made-up recordings (four channels with a pulse, another rhythm for half a minute, a hole, a movement, a
// weaker pulse and steps; eight channels of another layout with a dead and a railed electrode and loud mains hum; four
// channels at 500 a second; one channel at 256) run through the Python reference (analysis/pulse.py; fixture made by
// analysis/make_pulse_fixture.py) and through the Dart port. Every epoch's code, reading, confidence, channel and best
// rate must match: numbers within 1e-9 (the transforms round differently in the last bits), every decision exactly;
// and the summary of pulse while asleep on made-up stages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/pulse/detector.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() => jsonDecode(File('test/fixtures/pulse.json').readAsStringSync()) as Map<String, Object?>;

void _near(num? dart, Object? py, String where, {double tol = 1e-9}) {
  if (py == null) {
    expect(dart == null || dart.isNaN, isTrue, reason: '$where: dart $dart, python none');
    return;
  }
  final p = (py as num).toDouble();
  expect(dart, isNotNull, reason: '$where: dart none, python $p');
  final scale = p.abs() > 1 ? p.abs() : 1;
  expect((dart! - p).abs() <= tol * scale, isTrue, reason: '$where: dart $dart, python $p');
}

/// Channel-major rows of µV from the fixture's gzip-compressed int32 differences (value = integer / scale).
List<Float64List> _signal(String blob, int channels, int n, int scale) {
  final d = Uint8List.fromList(gzip.decode(base64Decode(blob))).buffer.asInt32List();
  expect(d.length, channels * n);
  return [
    for (var c = 0; c < channels; c++)
      () {
        final out = Float64List(n);
        var q = 0;
        for (var i = 0; i < n; i++) {
          q += d[c * n + i];
          out[i] = q / scale;
        }
        return out;
      }(),
  ];
}

void main() {
  final fixture = _load();
  final scale = fixture['scale']! as int;

  test('the fixture is of this detector', () => expect(fixture['detector'], pulseDetector));

  for (final c in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test('pulse on "${c['name']}": the same epochs and summary as the Python reference', () {
      final names = (c['channels']! as List).cast<String>();
      final n = c['n']! as int, rate = (c['sample_rate']! as num).toInt();
      final x = _signal(c['signal']! as String, names.length, n, scale);
      final missing = List<bool>.filled(n, false);
      for (final s in (c['missing']! as List).cast<List<Object?>>()) {
        for (var i = s[0]! as int; i < (s[1]! as int); i++) {
          missing[i] = true;
        }
      }
      final det = PulseEpochs(names.length, rate);
      final row = Float64List(names.length);
      for (var i = 0; i < n; i++) {
        for (var k = 0; k < names.length; k++) {
          row[k] = x[k][i];
        }
        det.push(row, missing: missing[i]);
      }
      final eps = det.finish();
      final py = (c['epochs']! as List).cast<List<Object?>>();
      expect(eps.length, py.length);
      for (var e = 0; e < py.length; e++) {
        final d = eps[e], p = py[e];
        expect([d.code, d.channel, d.channels], [p[0], p[3], p[5]], reason: 'epoch $e');
        _near(d.read ? d.bpm : null, p[1], 'epoch $e bpm', tol: 1e-12);
        _near(d.conf, p[2], 'epoch $e confidence');
        _near(d.best, p[4], 'epoch $e best rate', tol: 1e-12);
      }
      final stages = (c['stages']! as List).cast<String>();
      final a = pulseAsleep([for (final e in eps) e.read ? (e.bpm * 10).round() / 10 : null], stages);
      final pa = c['asleep']! as Map<String, Object?>;
      expect([a.epochs, a.read], [pa['epochs'], pa['read']]);
      _near(a.median, pa['median'], 'asleep median');
      _near(a.lowest, pa['lowest'], 'lowest 5 minutes');
      // the made-up truth: every reading within 1.5 a minute of a rate the case drew
      final truth = (c['truth']! as List).cast<num>();
      for (final e in eps.where((e) => e.read)) {
        expect(truth.any((t) => (e.bpm - t).abs() <= 1.5), isTrue, reason: '${e.bpm} vs $truth');
      }
    });
  }
}
