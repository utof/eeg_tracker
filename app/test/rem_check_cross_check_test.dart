// Cross-check of the dream sleep check against the Python reference (analysis/rem_check.py; fixture made by
// analysis/make_rem_fixture.py from made-up signals and nights, no recordings):
// - the report's `probs`: the same bytes from the same probabilities;
// - the eye pair the same recording headers give;
// - the eye-movement counter fed a synthetic left-right pair sample by sample: each second's swing, correlation and
//   artefact level, and the eye-movement seconds per epoch;
// - the same signal as T3 and T4 of two recorder runs with a pause between them, joined and counted by `seeNight`;
// - made-up nights: every number of the check and every sentence of its words.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/recorder/chunk_writer.dart' show indexBytes, recordBytes;
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:eeg_tracker/sleep/rem_check.dart';
import 'package:flutter_test/flutter_test.dart';

final Map<String, dynamic> _fx =
    jsonDecode(File('test/fixtures/rem_check.json').readAsStringSync()) as Map<String, dynamic>;

/// The pair (left, right) in µV, as make_rem_fixture.py packs it: int32 differences in 1/scale µV, gzip, base64.
(List<double>, List<double>) _pair(Map<String, dynamic> s) {
  final n = s['n'] as int, scale = s['scale'] as int;
  final d = Uint8List.fromList(gzip.decode(base64Decode(s['signal'] as String))).buffer.asInt32List();
  List<double> channel(int c) {
    var q = 0;
    return [
      for (var i = 0; i < n; i++) (q += d[c * n + i]) / scale,
    ];
  }

  return (channel(0), channel(1));
}

File _writeRun(Directory dir, String name, double t0, List<List<double>> uv, int batch, double arrival) {
  final n = uv.length;
  final rec = ByteData(n * recordBytes);
  for (var i = 0; i < n; i++) {
    rec.setUint32(i * recordBytes, i % 2048, Endian.little);
    for (var c = 0; c < 4; c++) {
      rec.setFloat32(i * recordBytes + 4 + 4 * c, uv[i][c] * 1e-6, Endian.little);
    }
  }
  final f = File('${dir.path}/$name.f32')..writeAsBytesSync(rec.buffer.asUint8List());
  final rows = (n + batch - 1) ~/ batch;
  final idx = ByteData(rows * indexBytes);
  for (var k = 0; k < rows; k++) {
    final last = (k + 1) * batch < n ? (k + 1) * batch : n;
    idx
      ..setFloat64(k * indexBytes, t0 + last / 250 + arrival, Endian.little)
      ..setUint64(k * indexBytes + 8, k * batch, Endian.little);
  }
  File('${dir.path}/$name.idx').writeAsBytesSync(idx.buffer.asUint8List());
  return f;
}

EyeSeen? _eye(Object? j) {
  if (j is! Map) return null;
  final pair = j['pair'] as String?;
  return pair == null
      ? EyeSeen.not(j['why'] as String)
      : EyeSeen.measured(pair, [for (final v in j['epochs'] as List) v as int?]);
}

void main() {
  test('the constants are the reference\'s', () {
    final c = _fx['constants'] as Map<String, dynamic>;
    expect(
      [c['swing_uv'], c['max_r'], c['artefact_uv'], c['measured_s'], c['dense_s'], c['low_hz'], c['high_hz'], c['artefact_hp_hz']],
      [
        EyeMoveRule.swingUv, EyeMoveRule.maxR, EyeMoveRule.artefactUv, EyeMoveRule.measuredS, EyeMoveRule.denseS,
        EyeMoveRule.lowHz, EyeMoveRule.highHz, EyeMoveRule.artefactHpHz,
      ],
    );
  });

  test('probabilities: the same bytes', () {
    final p = _fx['probs'] as Map<String, dynamic>;
    final rows = [for (final r in p['rows'] as List) for (final v in r as List) (v as num).toDouble()];
    expect(encodeProbs(rows), p['encoded']);
    expect(decodeProbs(p['encoded']), p['decoded']);
  });

  for (final c in (_fx['pairs'] as List).cast<Map<String, dynamic>>()) {
    test('the eye pair: ${c['what']}', () {
      final p = eyePairOf(RecordingHeader.fromJson(c['header']));
      final want = c['pair'] as Map<String, dynamic>?;
      expect(p == null ? null : {'left': p.left, 'right': p.right, 'label': p.label}, want);
    });
  }

  test('the counter, second by second and epoch by epoch', () {
    final s = _fx['signal'] as Map<String, dynamic>;
    final (left, right) = _pair(s);
    final miss = (s['missing'] as List).cast<int>();
    final trace = <(double, double, double)>[];
    final counter = EyeMoveCounter(trace: trace);
    for (var i = 0; i < left.length; i++) {
      counter.push(left[i], right[i], missing: i >= miss[0] && i < miss[1]);
    }
    final swing = s['swing'] as List, r = s['r'] as List, big = s['big'] as List;
    expect(trace, hasLength(swing.length));
    for (var k = 0; k < trace.length; k++) {
      final (sw, rr, bg) = trace[k];
      expect(sw, closeTo((swing[k] as num).toDouble(), 1e-6), reason: 'swing, second $k');
      if (r[k] == null) {
        expect(rr.isNaN, isTrue, reason: 'r, second $k');
      } else {
        expect(rr, closeTo((r[k] as num).toDouble(), 1e-7), reason: 'r, second $k');
      }
      expect(bg, closeTo((big[k] as num).toDouble(), 1e-6), reason: 'artefact level, second $k');
    }
    expect(counter.finish(), s['epochs']);
  });

  test('a night of two runs with a pause, through seeNight', () {
    final s = _fx['signal'] as Map<String, dynamic>, f = _fx['files'] as Map<String, dynamic>;
    final (left, right) = _pair(s);
    final dir = Directory.systemTemp.createTempSync('rem_cross');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = [
      for (final run in (f['runs'] as List).cast<Map<String, dynamic>>())
        _writeRun(
          dir,
          run['file'] as String,
          (run['t0'] as num).toDouble(),
          [
            for (var i = run['from'] as int; i < (run['to'] as int); i++) [left[i], right[i], left[i], right[i]],
          ],
          f['batch'] as int,
          (f['arrival_s'] as num).toDouble(),
        ),
    ];
    final seen = seeNight(files)!;
    expect(seen.eye!.pair, f['pair']);
    expect(seen.eye!.epochs, f['epochs']);
  });

  for (final n in (_fx['nights'] as List).cast<Map<String, dynamic>>()) {
    test('the night "${n['what']}": every number and sentence', () {
      final probs = n['probs'] as List?;
      final check = remCheck(
        stages: (n['stages'] as List).cast<String>(),
        periods: [for (final p in n['periods'] as List) ((p as List)[0] as int, p[1] as int)],
        probs: probs == null ? null : [for (final r in probs) (r as List).cast<int>()],
        eye: _eye(n['eye']),
      );
      expect(jsonDecode(jsonEncode(check)), n['check']);
      expect(remCheckLines(check), n['lines']);
      expect(remCheckLines((n['check'] as Map).cast<String, Object?>()), n['lines']); // read back from JSON
    });
  }
}
