// The lucid cue rule (DECISIONS 302-303) against the hand-worked cases shared with the Python reference
// (test/fixtures/lucid_cases.json, analysis/lucid_cues.py), and the eye bursts against recorded excerpts with drawn
// eye signals (test/fixtures/lucid_signals.json, made by analysis/make_lucid_fixture.py).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/lucid/rule.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _expand(List<Object?> items) => [
  for (final it in items)
    if (it is List) ...[for (var k = it[0]! as int; k <= (it[1]! as int); k += it[2]! as int) k] else it! as int,
];

Set<int> _spans(Object? spans) => {
  for (final s in (spans as List? ?? const []).cast<List<Object?>>())
    for (var k = s[0]! as int; k <= (s[1]! as int); k++) k,
};

/// Runs one case as the Python `run_case` does: stages known at a second first, then the second itself.
Map<String, Object?> _run(Map<String, Object?> c) {
  final n = c['seconds']! as int;
  final stages = <int, List<(int, String, double)>>{};
  for (final r in (c['runs'] as List? ?? const []).cast<List<Object?>>()) {
    for (var e = r[0]! as int; e <= (r[1]! as int); e++) {
      stages.putIfAbsent((e + 1 + LucidRule.behindEpochs) * 30, () => []).add((
        e,
        r[2]! as String,
        (r[3]! as num).toDouble(),
      ));
    }
  }
  for (final s in (c['stages'] as List? ?? const []).cast<List<Object?>>()) {
    stages.putIfAbsent(s[0]! as int, () => []).add((s[1]! as int, s[2]! as String, (s[3]! as num).toDouble()));
  }
  final moved = _spans(c['moved']), jaw = _spans(c['jaw']);
  final bursts = _expand(c['bursts'] as List? ?? const []).toSet();
  final drift = List<String?>.filled(n, 'asleep');
  for (final d in (c['drift'] as List? ?? const []).cast<List<Object?>>()) {
    for (var k = d[0]! as int; k < n; k++) {
      drift[k] = d[1]! as String;
    }
  }
  final r = CueRule(cuesFrom: c['cues_from_s']! as int);
  for (var k = 0; k < n; k++) {
    for (final (e, st, conf) in [...?stages[k]]..sort((a, b) => a.$1.compareTo(b.$1))) {
      r.stage(e, st, conf, k);
    }
    r.second(k, moved: moved.contains(k), jaw: jaw.contains(k), burst: bursts.contains(k), drift: drift[k]);
  }
  return {
    'cues': [
      for (final q in r.cues) [q.k, q.step, q.period],
    ],
    'arousals': r.arousals,
    'stops': [
      for (final s in r.stops) [s.$1, s.$2],
    ],
  };
}

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

void main() {
  final cases =
      (jsonDecode(File('test/fixtures/lucid_cases.json').readAsStringSync()) as Map<String, Object?>)['cases']! as List;
  for (final c in cases.cast<Map<String, Object?>>()) {
    test('shared case: ${c['name']}', () {
      final got = _run(c);
      final exp = c['expect']! as Map<String, Object?>;
      expect(got['cues'], exp['cues']);
      expect(got['arousals'], exp['arousals']);
      if (exp.containsKey('stops')) expect(got['stops'], exp['stops']);
    });
  }

  test('the level: whole decibels over the evening level, capped at +6 dB', () {
    expect(cueGain(0), 1.0);
    expect(cueGain(6), closeTo(1.9952623, 1e-6));
    expect(cueGain(40), cueGain(LucidRule.maxSteps));
  });

  test('why no cue: the reasons in the order the rule checks them', () {
    final r = CueRule(cuesFrom: 100);
    expect(r.whyNot(50, 'asleep'), 'before');
    expect(r.whyNot(100, 'asleep'), 'no dream sleep');
    r.stage(0, 'R', 0.9, 150);
    r.stage(1, 'R', 0.9, 180);
    expect(r.whyNot(180, 'asleep'), 'eyes');
    r.second(180, moved: false, jaw: false, burst: true, drift: 'asleep');
    expect(r.cues.length, 1);
    expect(r.whyNot(190, 'asleep'), 'spacing');
    expect(r.whyNot(210, 'awake'), 'awake');
  });

  final fixture = jsonDecode(File('test/fixtures/lucid_signals.json').readAsStringSync()) as Map<String, Object?>;
  final scale = fixture['scale']! as int;
  for (final c in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test('eye bursts as the reference finds them: ${c['name']}', () {
      final n = c['n']! as int;
      final rows = _signal(c['signal']! as String, n, scale);
      final missing = List<bool>.filled(n, false);
      for (final s in (c['missing']! as List).cast<List<Object?>>()) {
        for (var i = s[0]! as int; i < (s[1]! as int); i++) {
          missing[i] = true;
        }
      }
      final eyes = EyeBursts();
      final det = Detectors()..tap = eyes;
      final bursts = <int>[];
      for (var i = 0; i < n; i++) {
        det.push(rows[i], missing: missing[i]);
        final k = eyes.push(rows[i]);
        if (k != null) bursts.add(k);
      }
      expect([for (final m in det.eyeMoves) m.i], [for (final m in (c['moves']! as List).cast<List<Object?>>()) m[0]]);
      expect(eyes.quiet, c['quiet']);
      expect(bursts, c['bursts']);
    });
  }
}
