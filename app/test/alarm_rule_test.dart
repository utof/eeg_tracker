// The smart alarm's rule (lib/alarm/rule.dart) on the hand-worked cases shared with analysis/smart_alarm.py, plus
// the plan's times.
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/sleep/live_stager.dart' show LiveStage;
import 'package:flutter_test/flutter_test.dart';

const Map<String, String> _stage = {'W': 'W', '1': 'N1', '2': 'N2', '3': 'N3', 'R': 'R', '-': 'gap'};

/// Runs one case as the recorder would: each stage at its hand-out time, the clock checked in between.
({int? epoch, String why, int atS}) _run(Map<String, dynamic> c, int behind, int minEpochs) {
  final w = (c['window'] as List).cast<int>();
  final rules = AlarmRules(startMs: w[0] * 1000, endMs: w[1] * 1000); // the clock starts at 0 s
  final stages = (c['stages'] as String).split('');
  for (var e = 0; e < stages.length; e++) {
    final at = (e + 1 + behind < minEpochs ? minEpochs : e + 1 + behind) * 30;
    final due = rules.due(at * 1000);
    if (due != null) break;
    final wake = rules.stage(LiveStage(e, _stage[stages[e]]!, 0.9, behind), nowMs: at * 1000);
    if (wake != null) break;
  }
  final wake = rules.wake ?? rules.due(1 << 40);
  return (epoch: wake!.epoch, why: alarmWhyName(wake.why), atS: wake.atMs ~/ 1000);
}

void main() {
  final fixture = jsonDecode(File('test/fixtures/smart_alarm_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final behind = fixture['behind'] as int, minEpochs = fixture['min_epochs'] as int;

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test(c['name'] as String, () {
      final want = c['expect'] as Map<String, dynamic>;
      final got = _run(c, behind, minEpochs);
      expect(got.epoch, want['epoch']);
      expect(got.why, want['why']);
      expect(got.atS, want['at_s']);
    });
  }

  test('a wake is decided once', () {
    final r = AlarmRules.of(AlarmPlan(endMs: 3600000, windowMin: 30));
    expect(r.stage(const LiveStage(100, 'N2', 0.8, 4), nowMs: 2000000), isNotNull);
    expect(r.stage(const LiveStage(101, 'N2', 0.8, 4), nowMs: 2030000), isNull);
    expect(r.due(3600000), isNull);
    expect(r.wake!.epoch, 100);
    expect(r.wake!.confidence, 0.8);
  });

  test('the plan: the window, the model an hour before it, the next wake-by time', () {
    final p = AlarmPlan(endMs: 10 * 3600000, windowMin: 30);
    expect(p.startMs, 10 * 3600000 - 30 * 60000);
    expect(p.scoreFromMs, 10 * 3600000 - 90 * 60000);
    final evening = DateTime(2026, 11, 30, 23, 10);
    final next = AlarmPlan.next(now: evening, hour: 7, minute: 30, windowMin: 30);
    expect(DateTime.fromMillisecondsSinceEpoch(next.endMs), DateTime(2026, 12, 1, 7, 30));
    final small = AlarmPlan.next(now: DateTime(2026, 12, 1, 1, 0), hour: 7, minute: 30, windowMin: 20);
    expect(DateTime.fromMillisecondsSinceEpoch(small.endMs), DateTime(2026, 12, 1, 7, 30));
    final exactly = AlarmPlan.next(now: DateTime(2026, 12, 1, 7, 30), hour: 7, minute: 30, windowMin: 20);
    expect(DateTime.fromMillisecondsSinceEpoch(exactly.endMs), DateTime(2026, 12, 2, 7, 30));
    expect(AlarmPlan.fromJson(p.toJson())!.endMs, p.endMs);
    expect(AlarmPlan.fromJson({'endMs': 1, 'windowMin': 0}), isNull);
    expect(AlarmPlan.fromJson('x'), isNull);
    expect(() => AlarmPlan(endMs: 0, windowMin: -1), throwsArgumentError);
  });

  test('why in words', () {
    expect(alarmWhyName(AlarmWhy.windowEnd), 'window end');
    expect(alarmWhyFromName('dream'), AlarmWhy.dream);
    expect(alarmWhyFromName('nonsense'), isNull);
  });
}
