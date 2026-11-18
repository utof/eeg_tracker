// Cross-check: excerpts of the owner's recordings run through the Python reference (analysis/eeg_detectors.py,
// fixture made by analysis/make_detector_fixture.py) and through the Dart port. Both must find the same blinks,
// eye movements, bursts, movement and epoch flags at the same samples, and the drift-off detector must take the
// same steps on the same per-second inputs. Numbers may differ in the last bits (sin and cos of the filter
// coefficients), so they are compared with a small tolerance; every decision must match exactly.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() =>
    jsonDecode(File('test/fixtures/detectors.json').readAsStringSync()) as Map<String, Object?>;

void _near(num dart, num py, String where, {double tol = 1e-9}) {
  final scale = py.abs() > 1 ? py.abs() : 1;
  expect((dart - py).abs() <= tol * scale, isTrue, reason: '$where: dart $dart, python $py');
}

/// Rows of µV from the fixture's gzip-compressed int32 differences (value = integer / scale).
List<List<double>> _signal(String blob, int n, int scale) {
  final bytes = Uint8List.fromList(gzip.decode(base64Decode(blob)));
  final d = bytes.buffer.asInt32List();
  expect(d.length, 4 * n);
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

const _kinds = {'jaw': BurstKind.jaw, 'one-sided': BurstKind.oneSided, 'movement': BurstKind.movement};

void main() {
  final fixture = _load();
  final scale = fixture['scale']! as int;

  for (final e in (fixture['excerpts']! as List).cast<Map<String, Object?>>()) {
    test('detectors on "${e['name']}": same events as the Python reference', () {
      final n = e['n']! as int;
      final rows = _signal(e['signal']! as String, n, scale);
      final missing = List<bool>.filled(n, false);
      for (final s in (e['missing']! as List).cast<List<Object?>>()) {
        for (var i = s[0]! as int; i < (s[1]! as int); i++) {
          missing[i] = true;
        }
      }
      final seconds = <Second>[];
      final det = Detectors(onSecond: seconds.add);
      for (var i = 0; i < n; i++) {
        det.push(rows[i], missing: missing[i]);
      }
      det.finish();

      final py = e['seconds']! as Map<String, Object?>;
      final gap = (py['gap']! as List).cast<bool>();
      expect(seconds.length, gap.length);
      List<List<Object?>> rowsOf(String k) => (py[k]! as List).cast<List<Object?>>();
      for (var k = 0; k < gap.length; k++) {
        final s = seconds[k];
        expect(s.k, k);
        expect(s.gap, gap[k], reason: 'gap at $k');
        expect(s.flat, rowsOf('flat')[k], reason: 'flat at $k');
        expect(s.railed, rowsOf('railed')[k], reason: 'railed at $k');
        for (var c = 0; c < 4; c++) {
          _near(s.qrange[c], rowsOf('qrange')[k][c]! as num, 'qrange[$c] at $k');
          _near(s.muscle[c], rowsOf('muscle')[k][c]! as num, 'muscle[$c] at $k');
        }
        for (var b = 0; b < 2; b++) {
          _near(s.alpha[b], rowsOf('alpha')[k][b]! as num, 'alpha[$b] at $k');
          _near(s.theta[b], rowsOf('theta')[k][b]! as num, 'theta[$b] at $k');
        }
        _near(s.sem, (py['sem']! as List)[k]! as num, 'sem at $k');
      }

      final blinks = (e['blinks']! as List).cast<List<Object?>>();
      expect([for (final b in det.blinks) b.i], [for (final b in blinks) b[0]], reason: 'blink samples');
      for (var j = 0; j < blinks.length; j++) {
        _near(det.blinks[j].depth, blinks[j][1]! as num, 'blink $j depth');
        _near(det.blinks[j].t34, blinks[j][2]! as num, 'blink $j T3-T4');
      }
      expect(seconds.fold(0, (a, s) => a + s.blinks), det.blinks.where((b) => b.i < gap.length * 250).length);

      final eyes = (e['eyeMoves']! as List).cast<List<Object?>>();
      expect([for (final m in det.eyeMoves) m.i], [for (final m in eyes) m[0]], reason: 'eye movement samples');
      for (var j = 0; j < eyes.length; j++) {
        _near(det.eyeMoves[j].step, eyes[j][1]! as num, 'eye move $j');
      }

      final bursts = (e['bursts']! as List).cast<List<Object?>>();
      expect([for (final b in det.bursts) (b.start, b.end, b.kind)], [for (final b in bursts) (b[0], b[1], _kinds[b[2]])]);
      for (var j = 0; j < bursts.length; j++) {
        _near(det.bursts[j].peakX, bursts[j][3]! as num, 'burst $j peak');
      }
      expect(det.movement, [for (final m in (e['movement']! as List).cast<List<Object?>>()) (m[0], m[1])]);

      final epochs = (e['epochs']! as List).cast<List<Object?>>();
      expect(det.epochs.length, epochs.length);
      for (var j = 0; j < epochs.length; j++) {
        final d = det.epochs[j], p = epochs[j];
        expect([d.quality.name, d.gapS, d.badS, d.usable, d.movementS, d.muscleS], [p[0], p[1], p[2], p[3], p[4], p[5]]);
      }
    });
  }

  for (final c in (fixture['drift']! as List).cast<Map<String, Object?>>()) {
    test('drift-off on "${c['name']}": same steps as the Python reference', () {
      final d = DriftOff(0);
      final rows = (c['seconds']! as List).cast<List<Object?>>();
      for (var k = 0; k < rows.length; k++) {
        final r = rows[k];
        d.second(k, (r[0]! as num).toDouble(), r[1] == 1, r[2] == 1, (r[3]! as num).toDouble(), r[4]! as int);
      }
      final x = c['expect']! as Map<String, Object?>;
      expect(d.baselineAlpha, x['baselineAlpha']);
      expect(d.baselineSem, x['baselineSem']);
      expect(d.baselineDone, x['baselineDone']);
      expect(d.drowsyAt, x['drowsyAt']);
      expect(d.onset, x['onset']);
      expect(d.asleepAt, x['asleepAt']);
      expect([for (final o in d.onsets) [o.$1, o.$2]], x['onsets']);
      expect(d.wakes, x['wakes']);
      final epochs = (x['epochs']! as List).cast<List<Object?>>();
      expect(d.epochs.length, epochs.length);
      for (var j = 0; j < epochs.length; j++) {
        final e = d.epochs[j], p = epochs[j];
        expect([e.index, e.start, e.cleanS, e.fadedShare, e.faded, e.rolls, e.blinks, e.state.name], p, reason: 'epoch $j');
      }
    });
  }
}
