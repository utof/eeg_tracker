// Cross-check: made-up recordings (four channels walking, stopping with a small pulse, and running with a hole and the
// phone's step counter; eight channels of another layout with a dead and a railed electrode and a large pulse-like
// rhythm; four channels at 500 a second) run
// through the Python reference (analysis/walking.py; fixture made by analysis/make_walking_fixture.py) and through the
// Dart port. Every window's reading, every stretch, walk and minute must match: numbers within 1e-9 (the transforms
// round differently in the last bits), every decision exactly.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/walking/detector.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() => jsonDecode(File('test/fixtures/walking.json').readAsStringSync()) as Map<String, Object?>;

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

void _stretch(Stretch s, Map<String, Object?> py, String where) {
  expect([s.first, s.last, s.kind.name, s.confidence], [py['first'], py['last'], py['kind'], py['confidence']], reason: where);
  _near(s.steps, py['steps'], '$where steps');
  _near(s.pace, py['pace'], '$where pace');
  _near(s.score, py['score'], '$where score');
}

void main() {
  final fixture = _load();
  final scale = fixture['scale']! as int;

  test('the fixture is of this detector', () => expect(fixture['detector'], walkDetector));

  for (final c in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test('walking on "${c['name']}": same windows, stretches, walks and minutes as the Python reference', () {
      final names = (c['channels']! as List).cast<String>();
      final n = c['n']! as int, rate = (c['sample_rate']! as num).toInt();
      final x = _signal(c['signal']! as String, names.length, n, scale);
      final missing = List<bool>.filled(n, false);
      for (final s in (c['missing']! as List).cast<List<Object?>>()) {
        for (var i = s[0]! as int; i < (s[1]! as int); i++) {
          missing[i] = true;
        }
      }
      final det = WalkWindows(names.length, rate);
      final quick = WalkWindows(names.length, rate, quick: true);
      final row = Float64List(names.length);
      for (var i = 0; i < n; i++) {
        for (var k = 0; k < names.length; k++) {
          row[k] = x[k][i];
        }
        det.push(row, missing: missing[i]);
        quick.push(row, missing: missing[i]);
      }
      // walking per 30 s epoch, and the windows read without spectra (the sleep scorers' and the pulse's veto)
      final pyEpochs = (c['epochs']! as List).cast<bool>();
      expect(walkingEpochs(det.windows, pyEpochs.length), pyEpochs);
      expect(walkingEpochs(quick.windows, pyEpochs.length), pyEpochs);
      expect([for (final w in quick.windows) w.walks], (c['quick']! as List).cast<bool>());
      expect([for (final w in quick.windows) w.walks], [for (final w in det.windows) w.walks]);

      final pyWindows = (c['windows']! as List).cast<List<Object?>>();
      expect(det.windows.length, pyWindows.length);
      for (var i = 0; i < pyWindows.length; i++) {
        final w = det.windows[i], p = pyWindows[i];
        _near(w.t, p[0], 'window $i t');
        expect(w.read, p[1], reason: 'window $i read');
        _near(w.score, p[2], 'window $i score');
        _near(w.read ? w.pace : null, p[3], 'window $i pace (the same rate)', tol: 1e-12);
        _near(w.amp, p[4], 'window $i amp');
        expect(w.channels, p[5], reason: 'window $i channels');
        _near(w.read ? w.thirds : null, p[6], 'window $i thirds');
        expect(w.walks, p[7], reason: 'window $i walks');
      }

      final found = findWalks(det.windows);
      expect(found.smoothed, (c['smoothed']! as List).cast<bool>());
      final pyMoving = (c['moving']! as List).cast<Map<String, Object?>>();
      expect(found.moving.length, pyMoving.length);
      for (var i = 0; i < pyMoving.length; i++) {
        _stretch(found.moving[i], pyMoving[i], 'stretch $i');
      }
      final pyWalks = (c['walks']! as List).cast<Map<String, Object?>>();
      expect(found.walks.length, pyWalks.length);
      for (var i = 0; i < pyWalks.length; i++) {
        final w = found.walks[i], p = pyWalks[i];
        final ps = (p['stretches']! as List).cast<Map<String, Object?>>();
        expect(w.stretches.length, ps.length, reason: 'walk $i');
        for (var k = 0; k < ps.length; k++) {
          _stretch(w.stretches[k], ps[k], 'walk $i stretch $k');
        }
        _near(w.walkingS, p['walking_s'], 'walk $i walking_s');
        _near(w.stoppedS, p['stopped_s'], 'walk $i stopped_s');
        _near(w.steps, p['steps'], 'walk $i steps');
        _near(w.pace, p['pace'], 'walk $i pace');
      }

      final readings = [
        for (final r in (c['readings']! as List).cast<List<Object?>>()) ((r[0]! as num).toDouble(), (r[1]! as num).toInt()),
      ];
      final phone = phoneMinutes(readings);
      final pyPhone = (c['phone']! as List).cast<List<Object?>>();
      expect(phone.keys.toList(), [for (final p in pyPhone) p[0]]);
      for (final p in pyPhone) {
        _near(phone[p[0]], p[1], 'phone minute ${p[0]}');
      }

      final rows = walkMinutes(found, c['start_unix']! as int, phone);
      final pyRows = (c['minutes']! as List).cast<List<Object?>>();
      expect(rows.length, pyRows.length);
      for (var i = 0; i < pyRows.length; i++) {
        final r = rows[i], p = pyRows[i];
        expect([r.t, r.source], [p[0], p[7]], reason: 'minute $i');
        _near(r.walkS, p[1], 'minute $i walk_s');
        _near(r.runS, p[2], 'minute $i run_s');
        _near(r.hbSteps, p[3], 'minute $i hb_steps');
        _near(r.hbPace, p[4], 'minute $i hb_pace');
        _near(r.phone, p[5], 'minute $i phone');
        _near(r.steps, p[6], 'minute $i steps');
        _near(r.walkingS, p[8], 'minute $i walking_s');
      }
      final check = walkCheck(rows), pc = c['check']! as Map<String, Object?>;
      expect([check.paired, check.right, check.status.name], [pc['paired'], pc['right'], pc['status']]);
      _near(check.hbSteps, pc['hb_steps'], 'check hb_steps');
      _near(check.phoneSteps, pc['phone_steps'], 'check phone_steps');
    });
  }
}
