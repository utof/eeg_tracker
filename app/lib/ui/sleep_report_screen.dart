// The sleep report of one night (opened from the night screen's Sleep section), following the scorer live:
// while the night is being scored the page says so, and the report appears when it is written. "Was this you?"
// (DECISIONS 370-379) is worked out from the app's files when the page opens, when the report changes, and after
// an answer.
import 'package:flutter/material.dart';

import '../alarm/record.dart';
import '../sleep/report.dart';
import '../wearer/check.dart' show kindNight;
import '../wearer/wearer.dart';
import 'alarm_view.dart';
import 'evidence_sheet.dart';
import 'sleep_report_view.dart';
import 'sleep_scoring.dart';

class SleepReportScreen extends StatefulWidget {
  const SleepReportScreen({super.key, required this.scoring, required this.nightOf});
  final SleepScoring scoring;
  final String nightOf;

  @override
  State<SleepReportScreen> createState() => _SleepReportScreenState();
}

class _SleepReportScreenState extends State<SleepReportScreen> {
  WearerResult? _wearer;

  /// The report's `built` time the check was worked out for (a rebuilt report is checked again).
  String? _checkedFor;

  String get _dir => widget.scoring.scorer.recordingsDir.path;

  void _check(String? built) {
    _checkedFor = built;
    try {
      _wearer = refreshWearer(_dir, DateTime.now());
    } catch (_) {
      _wearer = null; // the check is never worth breaking the report
    }
  }

  void _answer(String? answer) {
    try {
      answerWearer(_dir, kindNight, widget.nightOf, answer, DateTime.now());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not saved: $e')));
    }
    setState(() => _check(_checkedFor));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.scoring,
    builder: (context, _) {
      final scoring = widget.scoring;
      final nightOf = widget.nightOf;
      final all = scoring.reports;
      final report = all.where((r) => r.nightOf == nightOf).firstOrNull;
      final built = report?.json['built'] as String?;
      if (_wearer == null || built != _checkedFor) _check(built);
      final w = _wearer;
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
        onRescore: report != null && scoring.scorer.olderScorer(report) && !scoring.busy
            ? () => scoring.rescore(nightOf)
            : null,
        onLicences: () => showLicensePage(context: context, applicationName: 'EEG Tracker'),
        wearer: w == null ? null : wearerLine(w, kindNight, nightOf),
        onWearerAnswer: _answer,
        onWearerInfo: () => showEvidence(context, 'was-this-you'),
      );
    },
  );

  /// The alarm read for the report of this `built` time (the page rebuilds at every scoring step).
  (String?, WakingUp?)? _alarmMemo;

  /// The smart alarm of the night, if it had one (a few small files; never breaks the report); read once per report.
  WakingUp? _alarm(SleepReport r) {
    final built = r.json['built'] as String?;
    final memo = _alarmMemo;
    if (memo != null && memo.$1 == built) return memo.$2;
    WakingUp? found;
    try {
      final a = AlarmStore(alarmsDirFor(_dir)).forNight(r.dataStart, r.dataEnd);
      found = a == null ? null : wakingUp(a, r);
    } catch (_) {
      found = null;
    }
    _alarmMemo = (built, found);
    return found;
  }
}
