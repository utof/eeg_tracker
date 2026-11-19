// The memory cue rule (DECISIONS 502) against the hand-worked cases shared with the Python reference
// (test/fixtures/memory_cases.json, analysis/memory_cues.py).
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/lucid/rule.dart' show LucidRule;
import 'package:eeg_tracker/memory_cues/rule.dart';
import 'package:flutter_test/flutter_test.dart';

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
      stages.putIfAbsent((e + 1 + MemoryRule.behindEpochs) * 30, () => []).add((
        e,
        r[2]! as String,
        (r[3]! as num).toDouble(),
      ));
    }
  }
  final moved = _spans(c['moved']), jaw = _spans(c['jaw']);
  final drift = List<String?>.filled(n, 'asleep');
  for (final d in (c['drift'] as List? ?? const []).cast<List<Object?>>()) {
    for (var k = d[0]! as int; k < n; k++) {
      drift[k] = d[1]! as String;
    }
  }
  final from = c['cues_from_s']! as int;
  final r = SoundRule(cuesFrom: from, cuesUntil: (c['cues_until_s'] as int?) ?? 1 << 40);
  for (var k = 0; k < n; k++) {
    for (final (e, st, conf) in [...?stages[k]]..sort((a, b) => a.$1.compareTo(b.$1))) {
      r.stage(e, st, conf, k);
    }
    r.second(k, moved: moved.contains(k), jaw: jaw.contains(k), burst: false, drift: drift[k]);
  }
  return {
    'cues': [
      for (final q in r.cues) [q.k, -q.step, q.period],
    ],
    'arousals': r.arousals,
    'stops': [
      for (final s in r.stops) [s.$1, s.$2],
    ],
  };
}

void main() {
  final cases =
      (jsonDecode(File('test/fixtures/memory_cases.json').readAsStringSync()) as Map<String, Object?>)['cases']! as List;
  for (final c in cases.cast<Map<String, Object?>>()) {
    test('shared case: ${c['name']}', () {
      final got = _run(c);
      final exp = c['expect']! as Map<String, Object?>;
      expect(got['cues'], exp['cues']);
      expect(got['arousals'], exp['arousals']);
      if (exp.containsKey('stops')) expect(got['stops'], exp['stops']);
    });
  }

  test('a cue is 3 dB under the evening loudness, and steps only down', () {
    final r = SoundRule(cuesFrom: 0, cuesUntil: 1 << 40);
    expect(r.step, -MemoryRule.marginDb);
    expect(MemoryRule.marginDb, 3);
  });

  test('the cue hours end where the lucid cues begin, so the two never share an hour', () {
    expect(MemoryRule.cuesUntil, lessThanOrEqualTo(LucidRule.cuesFrom));
    expect(MemoryRule.cuesFrom, lessThan(MemoryRule.cuesUntil));
  });

  test('Lights off moves the end of the cue hours with their start', () {
    final r = SoundRule(cuesFrom: 1800, cuesUntil: 1800 + 4 * 3600)..startAt(2400);
    expect(r.cuesFrom, 2400);
    expect(r.cuesUntil, 2400 + 4 * 3600);
  });
}
