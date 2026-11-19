// Cross-check: excerpts of the owner's recordings with synthetic gestures drawn over them, run through the Python
// reference (analysis/hands_free.py, fixture made by analysis/make_gesture_fixture.py) and through the Dart port
// (the detectors with a GestureTap, then Gestures). Both must give the same per-second inputs, the same clusters
// with the same verdicts, the same gestures and, for the calibration run, the same tuned settings. Numbers are
// stored with nine significant digits, so they are compared within 1e-8; every decision must match exactly.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void _near(num dart, num? py, String where, {double tol = 1e-8}) {
  if (py == null) {
    expect(dart.isNaN, isTrue, reason: '$where: dart $dart, python NaN');
    return;
  }
  final scale = py.abs() > 1 ? py.abs() : 1;
  expect((dart - py).abs() <= tol * scale, isTrue, reason: '$where: dart $dart, python $py');
}

List<List<double>> _signal(String blob, int n, int scale) {
  final d = Uint8List.fromList(gzip.decode(base64Decode(blob))).buffer.asInt32List();
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

const _kinds = {'clench': GestureKind.clench, 'glance': GestureKind.glance};

/// The case's samples through the detectors and a tap: every second the recogniser gets.
List<GestureSecond> _seconds(Map<String, Object?> e, int scale) {
  final n = e['n']! as int;
  final rows = _signal(e['signal']! as String, n, scale);
  final missing = List<bool>.filled(n, false);
  for (final s in (e['missing']! as List).cast<List<Object?>>()) {
    for (var i = s[0]! as int; i < (s[1]! as int); i++) {
      missing[i] = true;
    }
  }
  final out = <GestureSecond>[];
  final det = Detectors()..tap = GestureTap(out.add);
  for (var i = 0; i < n; i++) {
    det.push(rows[i], missing: missing[i]);
  }
  return out;
}

void main() {
  final fixture = jsonDecode(File('test/fixtures/gestures.json').readAsStringSync()) as Map<String, Object?>;
  final scale = fixture['scale']! as int;

  for (final e in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test('gestures on "${e['name']}": same inputs, clusters and gestures as the Python reference', () {
      final seconds = _seconds(e, scale);
      final py = (e['seconds']! as List).cast<List<Object?>>();
      expect(seconds.length, py.length);
      for (var k = 0; k < py.length; k++) {
        final s = seconds[k], p = py[k];
        expect(s.k, p[0], reason: 'second $k');
        for (var j = 0; j < ticksPerSecond; j++) {
          _near(s.p3[j], (p[1]! as List)[j] as num?, 'p3 at $k.$j');
          _near(s.p4[j], (p[2]! as List)[j] as num?, 'p4 at $k.$j');
          expect(s.tickGap[j], (p[3]! as List)[j] == 1, reason: 'tick gap at $k.$j');
        }
        _near(s.rest3, p[4] as num?, 'rest3 at $k');
        _near(s.rest4, p[5] as num?, 'rest4 at $k');
        expect(s.movement, p[6] == 1, reason: 'movement at $k');
        final moves = (p[7]! as List).cast<List<Object?>>();
        expect([for (final m in s.moves) m.i], [for (final m in moves) m[0]], reason: 'eye moves at $k');
        for (var m = 0; m < moves.length; m++) {
          _near(s.moves[m].step, moves[m][1]! as num, 'eye move step at $k');
        }
      }

      final settings = GestureSettings.fromJson(e['settings']);
      final g = Gestures(settings: settings);
      for (final s in seconds) {
        g.second(s);
      }
      final clusters = (e['clusters']! as List).cast<List<Object?>>();
      expect(g.clusters.length, clusters.length);
      for (var n = 0; n < clusters.length; n++) {
        final c = g.clusters[n], p = clusters[n];
        expect(c.kind, _kinds[p[0]], reason: 'cluster $n kind');
        expect(c.at, p[1], reason: 'cluster $n second');
        expect(c.clean, p[2], reason: 'cluster $n clean');
        final bursts = (p[3]! as List).cast<List<Object?>>();
        expect([for (final b in c.bursts) [b.start, b.end]], [for (final b in bursts) [b[0], b[1]]], reason: 'cluster $n bursts');
        for (var b = 0; b < bursts.length; b++) {
          _near(c.bursts[b].peak, bursts[b][2]! as num, 'cluster $n burst $b peak', tol: 1e-7);
        }
        expect([for (final m in c.moves) m.i], p[4], reason: 'cluster $n moves');
        expect(c.kind == GestureKind.clench ? clenchWhy(c, settings) : glanceWhy(c, settings), p[5], reason: 'cluster $n why');
      }
      final gestures = (e['gestures']! as List).cast<List<Object?>>();
      expect([for (final x in g.gestures) [x.kind.name, x.start, x.end, x.at]], [for (final x in gestures) [x[0], x[1], x[2], x[3]]]);
      for (var n = 0; n < gestures.length; n++) {
        _near(g.gestures[n].level, gestures[n][4]! as num, 'gesture $n level', tol: 1e-7);
      }

      final cal = e['calibration'] as Map<String, Object?>?;
      if (cal == null) return;
      final tries = [
        for (final t in (cal['tries']! as List).cast<List<Object?>>()) GestureTry(_kinds[t[0]]!, t[1]! as int, t[2]! as int),
      ];
      final got = calibrate(seconds, tries);
      final want = cal['settings']! as Map<String, Object?>;
      _near(got.settings.clenchX, want['clenchX']! as num, 'calibrated clench level', tol: 1e-7);
      _near(got.settings.glanceUv, want['glanceUv']! as num, 'calibrated glance size', tol: 1e-7);
      expect([got.settings.leftSign, got.settings.clenchOn, got.settings.glanceOn], [want['leftSign'], want['clenchOn'], want['glanceOn']]);
      expect([got.clenchSeen, got.glanceSeen, got.leftKnown, got.others], [cal['clenchSeen'], cal['glanceSeen'], cal['leftKnown'], cal['others']]);
      final results = (cal['results']! as List).cast<List<Object?>>();
      expect([for (final r in got.tries) [r.kind.name, r.cue, r.sign, r.why]], [for (final r in results) [r[0], r[1], r[3], r[4]]]);
      for (var n = 0; n < results.length; n++) {
        final want = results[n][2] as num?, have = got.tries[n].level;
        if (want == null) {
          expect(have, isNull, reason: 'try $n level');
        } else {
          _near(have!, want, 'try $n level', tol: 1e-7);
        }
      }
    });
  }
}
