// The sleep report of one night (opened from the night screen's Sleep section), following the scorer live:
// while the night is being scored the page says so, and the report appears when it is written.
import 'package:flutter/material.dart';

import '../alarm/record.dart';
import '../sleep/report.dart';
import 'alarm_view.dart';
import 'evidence_sheet.dart';
import 'sleep_report_view.dart';
import 'sleep_scoring.dart';

class SleepReportScreen extends StatelessWidget {
  const SleepReportScreen({super.key, required this.scoring, required this.nightOf});
  final SleepScoring scoring;
  final String nightOf;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scoring,
    builder: (context, _) {
      final all = scoring.reports;
      final report = all.where((r) => r.nightOf == nightOf).firstOrNull;
      return SleepReportView(
        nightOf: nightOf,
        report: report,
        others: [for (final r in all) if (r.nightOf != nightOf) r],
        scoringStep: scoring.night == nightOf ? scoring.step : null,
        blocked: scoring.blocked[nightOf],
        onInfo: () => showEvidence(context, 'sleep-scoring'),
        onExtrasInfo: () => showEvidence(context, 'jaw-and-blinks'),
        onDriftInfo: () => showEvidence(context, 'dream-catcher'),
        alarm: report == null || !report.scored ? null : _alarm(report),
        onAlarmInfo: () => showEvidence(context, 'smart-alarm'),
        onOpenNight: (SleepReport r) => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => SleepReportScreen(scoring: scoring, nightOf: r.nightOf)),
        ),
        onRetry: () => scoring.retry(nightOf),
        onLicences: () => showLicensePage(context: context, applicationName: 'EEG Tracker'),
      );
    },
  );

  /// The smart alarm of the night, if it had one (a few small files; never breaks the report).
  WakingUp? _alarm(SleepReport r) {
    try {
      final a = AlarmStore(alarmsDirFor(scoring.scorer.recordingsDir.path)).forNight(r.dataStart, r.dataEnd);
      return a == null ? null : wakingUp(a, r);
    } catch (_) {
      return null;
    }
  }
}
