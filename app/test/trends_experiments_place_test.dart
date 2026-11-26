// Where the two kinds of experiment sit on Trends, and what their headings say (DECISIONS 1083): right under today's
// numbers, next to each other, each heading saying how it works.
import 'package:eeg_tracker/sleep_experiments/kinds.dart';
import 'package:eeg_tracker/trends/trends.dart';
import 'package:eeg_tracker/ui/sleep_experiments_view.dart';
import 'package:eeg_tracker/ui/theme.dart';
import 'package:eeg_tracker/ui/trends_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sleep_experiments_test.dart' show logOf;

void main() {
  testWidgets('both experiment sections come right after Today, before Sleep pressure, with telling headings', (tester) async {
    tester.view.physicalSize = const Size(1210, 12000);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final model = buildTrends((nights: const [], mornings: const [], sessions: const []), DateTime(2026, 11, 10, 18));
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: TrendsView(
          model: model,
          onExperiments: () {},
          sleepExperiments: SleepExperimentSection(log: logOf(kindById('alcohol')!, const {}), today: '2026-11-10', line: '0 with, 0 without so far', onOpen: () {}),
        ),
      ),
    );
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    final today = tester.getTopLeft(find.textContaining('Today, ')).dy;
    final sleep = y('Sleep experiments: one tap each evening'), self = y('Self-experiments: a task on days the app picks');
    expect(today < sleep && sleep < self && self < y('Sleep pressure'), isTrue);
    // each button carries its own name
    expect(find.widgetWithText(OutlinedButton, 'Sleep experiments'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Self-experiments'), findsOneWidget);
    expect(find.textContaining('Everything above'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
