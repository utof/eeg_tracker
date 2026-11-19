// The sharp-hours log's day numbers on the Trends page and as self-experiment outcomes (DECISIONS row 287).
import 'package:eeg_tracker/experiments/analysis.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/trends/usual.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter_test/flutter_test.dart';

const TrendInputs _none = (nights: [], mornings: [], sessions: []);

void main() {
  final now = DateTime(2026, 11, 30, 15);

  test('the day numbers join the trends: sharpness and reaction time in the day', () {
    final sharp = {
      'sharp': {for (var d = 1; d <= 29; d++) '2026-11-${d.toString().padLeft(2, '0')}': 3.5, '2026-11-30': 1.4},
      'dayrt': {'2026-11-29': 312.0},
    };
    final series = dailySeries(_none, extra: sharp);
    expect(series['sharp']!['2026-11-30'], 1.4);
    expect(series['dayrt']!['2026-11-29'], 312);
    final m = buildTrends(_none, now, extra: sharp);
    final row = m.rows.singleWhere((r) => r.spec.id == 'sharp');
    expect(row.spec.label, 'Sharpness in the day');
    expect(row.spec.format(3.46), '3.5 of 5');
    expect(row.spec.group, TrendGroup.day);
    expect(row.arrow, Arrow.down, reason: 'two points under a steady 3.5');
    expect(row.spec.down, 'less sharp than usual');
    final rt = m.rows.singleWhere((r) => r.spec.id == 'dayrt');
    expect(rt.spec.label, 'Reaction time in the day');
    expect(rt.value, 312);
    expect(m.daysWithData, 30);
  });

  test('a day mean is judged with a 1-point smallest change, not the 2 points of a single rating', () {
    expect(Scale.meanRating.minChange, 1);
    final steady = {for (var d = 1; d <= 29; d++) '2026-11-${d.toString().padLeft(2, '0')}': 3.0};
    expect(usualOf(steady, '2026-11-30', Scale.meanRating).arrow(3.9), Arrow.none);
    expect(usualOf(steady, '2026-11-30', Scale.meanRating).arrow(4.0), Arrow.up);
  });

  test('never switched on: the sharp numbers are not listed as missing', () {
    final m = buildTrends(_none, now);
    expect(missingMeasures(m), isNot(contains('sharpness in the day')));
    expect(missingMeasures(m), isNot(contains('reaction time in the day')));
    expect(missingMeasures(m), contains('sleepiness'));
  });

  test('self-experiments can test sharpness in the day (judged by the next day, as every outcome)', () {
    final o = outcomeById('sharp')!;
    expect(o.noun, 'sharpness in the day');
    expect(o.matters, 0.5);
    expect(o.relative, isFalse);
    expect(sizeWords(o, 0.64), '0.6\u00a0points higher');
    final rt = outcomeById('dayrt')!;
    expect(rt.relative, isTrue, reason: 'judged against the don\'t days\' mean, as the morning reaction time');
    expect(sizeWords(rt, 12.4), '12\u00a0ms slower');
    expect(rangeWords(rt, -5, 20), '−5 to +20\u00a0ms');
  });
}
