// The sleep report of one night (opened from the night screen's Sleep section), following the scorer live:
// while the night is being scored the page says so, and the report appears when it is written. "Was this you?"
// (DECISIONS 370-379) is worked out from the app's files when the page opens, when the report changes, and after
// an answer, in a background isolate (DECISIONS 620-629): its line appears a moment after the report. The night's pulse
// (DECISIONS 815) is read the same way: the pulse pass over its raw files when none is kept for them (never while a
// night records, a session runs or the scoring runs: then only what is kept), drawn as the chart's Pulse lane.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../alarm/record.dart';
import '../pulse/night.dart' show NightPulse, nightPulseInBackground;
import '../recorder/remove.dart' show rawGoneText, removedOfNight;
import '../sleep/report.dart';
import '../wearer/check.dart' show kindNight;
import '../wearer/wearer.dart';
import 'alarm_view.dart';
import 'archive_screen.dart' show phoneArchiveBusy;
import 'evidence_sheet.dart';
import 'sleep_report_view.dart';
import 'sleep_scoring.dart';

class SleepReportScreen extends StatefulWidget {
  const SleepReportScreen({super.key, required this.scoring, required this.nightOf, this.pulse});
  final SleepScoring scoring;
  final String nightOf;

  /// Tests: the night's pulse without an isolate or the phone's busy check ([run]: the pass may run).
  final Future<NightPulse> Function(String recordingsPath, String nightOf, int startMs, int n, bool run)? pulse;

  @override
  State<SleepReportScreen> createState() => _SleepReportScreenState();
}

class _SleepReportScreenState extends State<SleepReportScreen> {
  WearerResult? _wearer;

  /// The report's `built` time the check was asked for (a rebuilt report is checked again), and whether it was.
  String? _checkedFor;
  bool _asked = false;

  /// The newest check asked for: an older one that ends later is dropped.
  int _check = 0;

  /// The night's pulse on its report's clock, the report's `built` time it was read for, and whether it is being read.
  List<double?>? _pulse;
  String? _pulseFor;
  bool _pulseAsked = false, _pulseReading = false;

  String get _dir => widget.scoring.scorer.recordingsDir.path;

  /// Where the night's samples are when they left the phone (remove.dart), read once: "Score again" needs them.
  late final String? _rawGone = _safeRawGone();

  String? _safeRawGone() {
    try {
      return rawGoneText(removedOfNight(Directory(_dir), widget.nightOf));
    } catch (_) {
      return null;
    }
  }

  /// Works the check out in the background; the page shows it when it is done.
  void _ask(String? built) {
    _checkedFor = built;
    _asked = true;
    final n = ++_check;
    unawaited(
      wearerInBackground(_dir, DateTime.now()).then<WearerResult?>((w) => w, onError: (Object _) => null).then((w) {
        // the check is never worth breaking the report
        if (mounted && n == _check) setState(() => _wearer = w);
      }),
    );
  }

  /// Reads the night's pulse in the background (the pass first, when nothing records or scores); shown when done.
  void _askPulse(SleepReport r, String? built) {
    _pulseFor = built;
    _pulseAsked = true;
    _pulseReading = true;
    final dir = _dir, night = widget.nightOf;
    final start = r.dataStart.millisecondsSinceEpoch, n = r.stages.length;
    unawaited(() async {
      NightPulse? p;
      try {
        final load = widget.pulse;
        if (load != null) {
          p = await load(dir, night, start, n, true);
        } else {
          final b = await phoneArchiveBusy();
          p = await nightPulseInBackground(dir, night, start, n, run: !(b.nightRecording || b.sessionRunning || b.scoring));
        }
      } catch (_) {
        p = null; // the pulse is never worth breaking the report
      }
      if (!mounted || _pulseFor != built) return;
      setState(() {
        _pulse = p?.bpm;
        _pulseReading = false;
      });
    }());
  }

  void _answer(String? answer) {
    try {
      answerWearer(_dir, kindNight, widget.nightOf, answer, DateTime.now());
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not saved: $e')));
    }
    _ask(_checkedFor);
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
      if (!_asked || built != _checkedFor) _ask(built);
      if (report != null && report.scored && (!_pulseAsked || _pulseFor != built)) {
        _askPulse(report, built);
      }
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
        onDreamInfo: () => showEvidence(context, 'sleep-scoring'),
        alarm: report == null || !report.scored ? null : _alarm(report),
        onAlarmInfo: () => showEvidence(context, 'smart-alarm'),
        onOpenNight: (SleepReport r) => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => SleepReportScreen(scoring: scoring, nightOf: r.nightOf)),
        ),
        onRetry: () => scoring.retry(nightOf),
        onRescore: report != null && report.scored && scoring.scorer.olderScorer(report) && !scoring.busy && _rawGone == null
            ? () => scoring.rescore(nightOf)
            : null,
        rawGone: report != null && report.scored && scoring.scorer.olderScorer(report) ? _rawGone : null,
        onLicences: () => showLicensePage(context: context, applicationName: 'EEG Tracker'),
        wearer: w == null ? null : wearerLine(w, kindNight, nightOf),
        onWearerAnswer: _answer,
        onWearerInfo: () => showEvidence(context, 'was-this-you'),
        pulse: _pulseFor == built ? _pulse : null,
        pulseReading: _pulseReading,
        onPulseInfo: () => showEvidence(context, 'pulse'),
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
