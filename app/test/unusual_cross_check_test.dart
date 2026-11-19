// Cross-check: made-up per-day numbers judged by the Python reference (analysis/unusual.py, fixture made by
// analysis/make_unusual_fixture.py) and by the Dart port (lib/unusual/detector.dart). Every day's phase, every
// number's verdict, run and usual, the card's rule with and without the headband's numbers, and the cards' days
// must match; the usual's numbers within 1e-9.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/unusual/detector.dart';
import 'package:flutter_test/flutter_test.dart';

void _near(double? dart, Object? py, String where) {
  if (py == null) {
    expect(dart, isNull, reason: where);
    return;
  }
  final p = (py as num).toDouble();
  expect(dart, isNotNull, reason: where);
  final scale = p.abs() > 1 ? p.abs() : 1;
  expect((dart! - p).abs() <= 1e-9 * scale, isTrue, reason: '$where: dart $dart, python $p');
}

const _states = {
  StreamState.none: 'none',
  StreamState.unjudged: 'unjudged',
  StreamState.inRange: 'in',
  StreamState.up: 'up',
  StreamState.down: 'down',
};

void main() {
  final fixture = jsonDecode(File('test/fixtures/unusual.json').readAsStringSync()) as Map<String, Object?>;

  test('the fixture is the reference\'s, with the settings the phone uses', () {
    expect(fixture['made_by'], 'analysis/make_unusual_fixture.py');
    final s = fixture['settings']! as Map<String, Object?>;
    const d = UnusualSettings();
    expect(s['lag_days'], d.lagDays);
    expect(s['window'], d.window);
    expect(s['min_baseline'], unusualMinBaseline);
    expect(s['spreads'], 2.0);
    expect(s['run_days'], d.runDays);
    expect(s['bridge'], d.bridge);
    expect(s['min_streams'], d.minStreams);
    expect(s['silent_days'], d.silentDays);
    expect(s['restart_gap'], d.restartGap);
    expect(s['pause_days'], d.pauseDays);
  });

  for (final c in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
    test(c['name']! as String, () {
      final series = {
        for (final e in (c['series']! as Map<String, Object?>).entries)
          e.key: {for (final d in (e.value! as Map<String, Object?>).entries) d.key: (d.value! as num).toDouble()},
      };
      final ill = [
        for (final e in (c['ill']! as List).cast<Map<String, Object?>>())
          Ill(start: e['start']! as String, tapped: e['tapped']! as String, resumed: e['resumed'] as String?),
      ];
      final s = c['settings']! as Map<String, Object?>;
      final settings = UnusualSettings(minStreams: s['min_streams']! as int, runDays: s['run_days']! as int);
      final got = judgeDays(series, c['first']! as String, c['last']! as String, ill: ill, settings: settings);
      final want = (c['days']! as List).cast<Map<String, Object?>>();
      expect(got.length, want.length);
      for (final (i, w) in want.indexed) {
        final g = got[i];
        final at = '${c['name']} ${w['day']}';
        expect(g.day, w['day'], reason: at);
        expect(g.phase.name, w['phase'], reason: at);
        expect(g.validBefore, w['valid_before'], reason: at);
        expect(g.epochStart, w['epoch_start'], reason: at);
        expect(g.onCore, w['on_core'], reason: at);
        expect(g.onAll, w['on_all'], reason: at);
        expect(g.ruleCore, w['rule_core'], reason: at);
        expect(g.ruleAll, w['rule_all'], reason: at);
        final active = (w['active']! as Map<String, Object?>).map((k, v) => MapEntry(k, v! as List));
        expect(g.active.keys.toSet(), active.keys.toSet(), reason: at);
        for (final MapEntry(key: id, value: a) in active.entries) {
          final r = g.active[id]!;
          expect([r.run, _states[r.state], r.start], a, reason: '$at $id active');
        }
        for (final MapEntry(key: id, value: x) in (w['streams']! as Map<String, Object?>).entries) {
          final e = x! as Map<String, Object?>;
          final d = g.streams[id]!;
          final where = '$at $id';
          expect(d.n, e['n'], reason: where);
          _near(d.usual, e['usual'], '$where usual');
          _near(d.spread, e['spread'], '$where spread');
          _near(d.half, e['half'], '$where half');
          expect(_states[d.state], e['state'], reason: where);
          expect(d.off, e['off'], reason: where);
          expect(d.run, e['run'], reason: where);
          expect(d.runStart, e['run_start'], reason: where);
        }
      }
      List<List<String>> eps(List<(String, String)> e) => [for (final (a, b) in e) [a, b]];
      expect(eps(episodes(got)), c['episodes']);
      expect(eps(episodes(got, withHeadband: true)), c['episodes_all']);
    });
  }
}
