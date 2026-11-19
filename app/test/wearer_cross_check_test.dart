// "Was this you?" on the phone against its Python reference (analysis/wearer_check.py): a fixture made by
// analysis/make_wearer_fixture.py from made-up signals and histories goes through the Dart port, which must give the
// same night signals, the same check-in and report readings and the same verdicts, distances and z-scores.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/wearer/check.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _load() => jsonDecode(File('test/fixtures/wearer.json').readAsStringSync()) as Map<String, Object?>;

/// One channel of µV from the fixture's gzip-compressed int32 differences (value = integer / scale).
Float64List _decode(String blob, int scale) {
  final bytes = Uint8List.fromList(gzip.decode(base64Decode(blob)));
  final d = bytes.buffer.asInt32List(0, bytes.length ~/ 4);
  final out = Float64List(d.length);
  var acc = 0;
  for (var i = 0; i < d.length; i++) {
    acc += d[i];
    out[i] = acc / scale;
  }
  return out;
}

void _close(Object? actual, Object? expected, String what, {double tol = 1e-9}) {
  if (expected == null || expected is bool || expected is String) {
    expect(actual, expected, reason: what);
    return;
  }
  if (expected is Map) {
    expect(actual, isA<Map<Object?, Object?>>(), reason: what);
    final a = actual! as Map;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: what);
    for (final k in expected.keys) {
      _close(a[k], expected[k], '$what.$k', tol: tol);
    }
    return;
  }
  expect(actual, isA<num>(), reason: what);
  final e = (expected as num).toDouble(), a = (actual! as num).toDouble();
  expect((a - e).abs(), lessThanOrEqualTo(tol * (1 + e.abs())), reason: '$what: $a vs $e');
}

/// The window the night pass would keep: from Lights off on, at most 10 minutes, through the sampler itself.
NightWindow? _window(Float64List o1, Float64List o2, int? lightsOff, List<int> missing) {
  final s = NightWindowSampler(lightsOff);
  final gaps = missing.toSet();
  final row = Float64List(4);
  for (var i = 0; i < o1.length; i++) {
    row[0] = o1[i];
    row[1] = o2[i];
    s.push(row, gaps.contains(i));
  }
  return s.window;
}

WearerRecording _recording(Map<String, Object?> j) => WearerRecording(
  id: j['id']! as String,
  kind: j['kind']! as String,
  time: DateTime.parse(j['time']! as String),
  day: j['day']! as String,
  signal: j['signal'] == null ? null : {for (final e in (j['signal']! as Map).entries) e.key as String: (e.value as num).toDouble()},
  why: j['why'] as String?,
  answer: j['answer'] as String?,
);

void main() {
  final fixture = _load();

  test('the planning values are the reference\'s', () {
    final r = (fixture['rules']! as Map).cast<String, Object?>();
    expect(r['n_enrol'], enrolN);
    expect(r['min_days'], enrolDays);
    expect(r['profile_max'], profileMax);
    expect(r['threshold'], wearerThreshold);
    expect(r['min_clean_s'], minCleanS);
    expect(r['night_window_s'], nightWindowS);
    expect(r['floors'], wearerFloors);
  });

  final signals = (fixture['signals']! as Map).cast<String, Object?>();
  final scale = signals['scale']! as int;
  for (final part in ['night', 'noise']) {
    final p = (signals[part]! as Map).cast<String, Object?>();
    final o1 = _decode(p['o1']! as String, scale), o2 = _decode(p['o2']! as String, scale);
    for (final c in (p['cases']! as List).cast<Map<String, Object?>>()) {
      test('night signal: ${c['name']}', () {
        final w = _window(o1, o2, c['lights_off_s'] as int?, (c['missing']! as List).cast<int>());
        final info = nightSignal(w, (c['stages']! as List).cast<String>());
        _close(info, c['info'], 'info');
        final (s, why) = reportSignal(info);
        _close(s, c['signal'], 'signal');
        expect(why, (c['info']! as Map)['why']);
      });
    }
  }

  test('check-in results read as the reference reads them', () {
    for (final c in (fixture['checkins']! as List).cast<Map<String, Object?>>()) {
      final (s, why) = checkInSignal((c['input']! as Map).cast<String, Object?>());
      _close(s, c['signal'], 'signal of ${c['input']}');
      expect(why, c['why'], reason: '${c['input']}');
    }
  });

  test('report objects read as the reference reads them', () {
    for (final c in (fixture['reports']! as List).cast<Map<String, Object?>>()) {
      final (s, why) = reportSignal(c['input']);
      _close(s, c['signal'], 'signal of ${c['input']}');
      expect(why, c['why'], reason: '${c['input']}');
    }
  });

  for (final h in (fixture['histories']! as List).cast<Map<String, Object?>>()) {
    test('history: ${h['name']}', () {
      final recs = [for (final r in (h['recordings']! as List).cast<Map<String, Object?>>()) _recording(r)];
      final mine = judgeWearer(recs);
      final expected = (h['verdicts']! as List).cast<Map<String, Object?>>();
      expect(mine.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        _close(mine[i].toJson(), expected[i], 'verdict $i (${expected[i]['id']})');
      }
    });
  }
}
