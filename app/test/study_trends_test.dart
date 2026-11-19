// The study log's day number on the Trends page and as a self-experiment outcome and question (DECISIONS row 401).
import 'package:eeg_tracker/experiments/analysis.dart';
import 'package:eeg_tracker/experiments/experiment.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/trends_view.dart' show missingMeasures;
import 'package:flutter_test/flutter_test.dart';

const TrendInputs _none = (nights: [], mornings: [], sessions: []);

void main() {
  final now = DateTime(2026, 11, 30, 15);

  test('the recall joins the trends as a number of the day, shown once something is logged', () {
    final study = {
      'recall': {'2026-11-29': 2.5},
    };
    expect(dailySeries(_none, extra: study)['recall']!['2026-11-29'], 2.5);
    final m = buildTrends(_none, now, extra: study);
    final row = m.rows.singleWhere((r) => r.spec.id == 'recall');
    expect(row.spec.label, 'Recall of what you studied');
    expect(row.spec.format(2.5), '2.5\u00a0of\u00a03');
    expect(row.spec.group, TrendGroup.day);
    expect(row.value, 2.5);
    expect(missingMeasures(buildTrends(_none, now)), isNot(contains('recall of what you studied')));
  });

  test('a self-experiment can test it, and has a ready-made question: study in the evening or in the morning', () {
    final o = outcomeById('recall')!;
    expect(o.noun, 'recall of what you studied');
    expect(o.matters, 0.5);
    expect(o.relative, isFalse);
    expect(sizeWords(o, 0.64), '0.6 points better');
    final p = presets.singleWhere((p) => p.id == 'study');
    expect(p.doText, 'Study in the evening, a few hours before bed');
    expect(p.dontText, 'Study in the morning instead');
    expect(p.outcome, 'recall');
  });
}
