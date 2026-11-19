// Dream signals (DECISIONS 304): the left-right-left-right finder and the double clench against the Python reference
// on recorded excerpts with drawn signals (test/fixtures/lucid_signals.json, analysis/make_lucid_fixture.py), and
// the finder's own rules on hand-made eye movements.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:eeg_tracker/lucid/signals.dart';
import 'package:flutter_test/flutter_test.dart';

List<List<double>> _signal(String blob, int n, int scale) {
  final d = Uint8List.fromList(gzip.decode(base64Decode(blob))).buffer.asInt32List();
  final rows = [for (var i = 0; i < n; i++) List<double>.filled(4, 0)];
  for (var c = 0; c < 4; c++) {
    var q = 0;
    for (var i = 0; i < n; i++) {
      q += d[c * n + i];
      rows[i][c] = q / scale;
    }
  }
  return rows;
}

EyeMove _m(int i, double step) => EyeMove(i, step);

void main() {
  final fixture = jsonDecode(File('test/fixtures/lucid_signals.json').readAsStringSync()) as Map<String, Object?>;
  final scale = fixture['scale']! as int;
  for (final c in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test('as the reference finds them: ${c['name']}', () {
      final n = c['n']! as int;
      final rows = _signal(c['signal']! as String, n, scale);
      final missing = List<bool>.filled(n, false);
      for (final s in (c['missing']! as List).cast<List<Object?>>()) {
        for (var i = s[0]! as int; i < (s[1]! as int); i++) {
          missing[i] = true;
        }
      }
      final cx = (c['clenchX'] as num?)?.toDouble();
      final finder = SignalFinder(
        sweepUv: (c['sweep']! as num).toDouble(),
        clench: cx == null ? null : GestureSettings(clenchX: cx, glanceOn: false),
      );
      for (var i = 0; i < n; i++) {
        finder.push(rows[i], missing: missing[i]);
      }
      final found = finder.finish();
      final want = (c['signals']! as List).cast<List<Object?>>();
      expect(
        [
          for (final s in found.lrlr) [s.start, s.end, s.sweeps],
        ],
        [for (final w in want) w.sublist(0, 3)],
      );
      for (var j = 0; j < want.length; j++) {
        expect(found.lrlr[j].size, closeTo((want[j][3]! as num).toDouble(), 1e-6));
      }
      expect([
        for (final g in found.clenches) [g.start, g.end, g.at],
      ], c['clenches']);
    });
  }

  test('LRLR from the middle: the half steps out and back are no sweeps', () {
    final s = lrlrSignals([_m(1000, 120), _m(1150, -240), _m(1300, 240), _m(1450, -240), _m(1600, 120)]);
    expect(
      [
        for (final x in s) [x.start, x.end, x.sweeps, x.pairs],
      ],
      [
        [1150, 1450, 3, 2],
      ],
    );
  });

  test('a glance out, across and back is no signal; neither are uneven sweeps or an uneven pace', () {
    expect(lrlrSignals([_m(1000, 120), _m(1150, -240), _m(1300, 120)]), isEmpty);
    expect(lrlrSignals([_m(1000, 100), _m(1150, -300), _m(1300, 300)]), isEmpty);
    expect(lrlrSignals([_m(1000, 200), _m(1075, -200), _m(1375, 200)]), isEmpty);
  });

  test('small sweeps need the calibrated look size', () {
    final m = [_m(1000, -70), _m(1150, 70), _m(1300, -70)];
    expect(lrlrSignals(m), isEmpty);
    expect(lrlrSignals(m, sweepUv: 60), hasLength(1));
  });

  test('a run breaks where the direction does not change or a gap is over 1.5 s', () {
    expect(
      [
        for (final r in eyeRuns([_m(0, 1), _m(150, -1), _m(300, -1), _m(450, 1)])) r.length,
      ],
      [2, 2],
    );
    expect(
      [
        for (final r in eyeRuns([_m(0, 1), _m(376, -1)])) r.length,
      ],
      [1, 1],
    );
  });

  test('three pairs, then a second signal after a pause', () {
    final m = [
      for (var j = 0; j < 5; j++) _m(1000 + 150 * j, j.isEven ? -200 : 200),
      for (var j = 0; j < 3; j++) _m(4000 + 150 * j, j.isEven ? 200 : -200),
    ];
    expect(
      [
        for (final s in lrlrSignals(m)) [s.sweeps, s.pairs],
      ],
      [
        [5, 3],
        [3, 2],
      ],
    );
  });
}
