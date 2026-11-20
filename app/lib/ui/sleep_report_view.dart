// The sleep report's layout, from a report and plain values, so it renders in tests without a phone: the asleep
// total and missing time, the honest note (with how much of the sleep was read through noise), the chart with its
// Signal lane, the sleep periods as numbered log entries, jaw and movement with the night hour by hour
// (sleep_extras_view.dart), "Was this you?" (wearer_view.dart: a question right after the honest note, otherwise a
// remark after the night's entries), the night's pulse (a Pulse lane under the chart and one line with its "i",
// DECISIONS 815-816), and the past nights. Design: DESIGN.md and
// .impeccable/surfaces/app-lib-ui-sleep-report-screen-dart.md.
import 'package:flutter/material.dart';

import '../detectors/detectors.dart' show EpochQuality;
import '../pulse/detector.dart' show pulseAsleep;
import '../pulse/night.dart' show pulseAsleepWords, pulseLowestWords;
import '../recorder/nights.dart' show nightLabel;
import '../sleep/drift.dart' show driftCheck;
import '../sleep/report.dart';
import '../wearer/wearer.dart' show WearerLine;
import 'alarm_view.dart' show WakingUp, WakingUpSection;
import 'lights_off_view.dart';
import 'parts.dart';
import 'rem_check_view.dart';
import 'pulse_lane.dart';
import 'sleep_chart.dart';
import 'sleep_extras_view.dart';
import 'theme.dart';
import 'wearer_view.dart';

/// `6 h 27 min` as readout parts (numbers big, units small).
List<(String, bool)> durationParts(double minutes) {
  final total = minutes.round();
  if (total < 60) return [('$total', true), (' min', false)];
  return [('${total ~/ 60}', true), (' h ', false), ((total % 60).toString().padLeft(2, '0'), true), (' min', false)];
}

/// `6 h 27 min`, `42 min`, with no-break spaces so a duration never splits across lines.
String durationText(double minutes) => durationParts(minutes).map((p) => p.$1).join().trim().replaceAll(' ', '\u00a0');

String clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// `Tue 17 Nov` for a report's `night_of`.
String nightTitle(String nightOf) => nightLabel(DateTime.parse(nightOf));

class SleepReportView extends StatelessWidget {
  const SleepReportView({
    super.key,
    required this.nightOf,
    this.report,
    this.others = const [],
    this.scoringStep,
    this.blocked,
    this.onInfo,
    this.onExtrasInfo,
    this.onDriftInfo,
    this.onDreamInfo,
    this.alarm,
    this.onAlarmInfo,
    this.onOpenNight,
    this.onRetry,
    this.onRescore,
    this.rawGone,
    this.onLicences,
    this.wearer,
    this.onWearerAnswer,
    this.onWearerInfo,
    this.pulse,
    this.pulseReading = false,
    this.onPulseInfo,
  });

  final String nightOf;

  /// Null while the night has no report yet.
  final SleepReport? report;

  /// Other nights with a report, newest first.
  final List<SleepReport> others;

  /// What the scorer is doing for this night right now, if anything.
  final String? scoringStep;

  /// Why the last scoring of this night stopped ('' when the app stopped while scoring), or null.
  final String? blocked;
  final VoidCallback? onInfo;

  /// The "i" of the jaw and movement section.
  final VoidCallback? onExtrasInfo;

  /// The "i" of the falling asleep section (the drift-off detector's note).
  final VoidCallback? onDriftInfo;

  /// The "i" of the dream sleep check (the sleep-scoring note).
  final VoidCallback? onDreamInfo;

  /// The smart alarm of this night ("Waking up", alarm_view.dart), and its "i".
  final WakingUp? alarm;
  final VoidCallback? onAlarmInfo;
  final void Function(SleepReport night)? onOpenNight;
  final VoidCallback? onRetry;

  /// "Score again", offered when the report came from an older scorer (DECISIONS row 580); null otherwise.
  final VoidCallback? onRescore;

  /// Instead of "Score again" when the night's samples left the phone (remove.dart): where they are, in words.
  final String? rawGone;
  final VoidCallback? onLicences;

  /// "Was this you?" for this night (null: switched off or nothing to say), its answers and its "i".
  final WearerLine? wearer;
  final ValueChanged<String?>? onWearerAnswer;
  final VoidCallback? onWearerInfo;

  /// The night's pulse a minute per epoch on the report's clock (null where not read); null: no pulse file covers the
  /// night (yet). [pulseReading]: it is being read now. [onPulseInfo]: its "i".
  final List<double?>? pulse;
  final bool pulseReading;
  final VoidCallback? onPulseInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = report;
    return Scaffold(
      appBar: AppBar(
        title: Text('Night of ${nightTitle(nightOf)}', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(
            onPressed: onInfo,
            tooltip: 'What the research says',
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          if (scoringStep != null) _Notice('Scoring this night on the phone: ${scoringStep!}.'),
          if (blocked != null && scoringStep == null) _Blocked(reason: blocked!, onRetry: onRetry),
          if (r == null && scoringStep == null && blocked == null) const _Notice('This night has no report yet.'),
          if (r != null && !r.scored) ...[
            Readout(parts: const [('–', true)], label: 'asleep'),
            const SizedBox(height: 16),
            _Notice('Under 5 minutes were recorded (${durationText(r.recordedMin)}): too little to score.'),
          ],
          if (r != null && r.scored) ..._scored(context, r),
          if (others.isNotEmpty) ...[
            const SectionHeading('Past nights'),
            for (final o in others) _NightRow(report: o, onTap: onOpenNight == null ? null : () => onOpenNight!(o)),
          ],
          if (r != null)
            _Footer(report: r, onLicences: onLicences, onRescore: scoringStep == null ? onRescore : null, rawGone: rawGone),
        ],
      ),
    );
  }

  List<Widget> _scored(BuildContext context, SleepReport r) {
    final text = Theme.of(context).textTheme;
    final periods = r.periods;
    final stages = r.stages;
    int epochOf(DateTime t) => (t.difference(r.dataStart).inSeconds / 30).round();
    final bands = [for (final p in periods) (epochOf(p.start), epochOf(p.end) - 1)];
    final missing = r.missingMin;
    final x = r.extras;
    final quality = x?.quality;
    final noisyMin = x?.night.degradedMin ?? 0, unusableMin = x?.night.missingMin ?? 0;
    final drift = r.driftOff;
    final dream = r.remCheckNumbers;
    return [
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: Readout(parts: durationParts(r.asleepMin), label: 'asleep')),
            const VerticalDivider(width: 33),
            Expanded(
              child: Readout(
                parts: durationParts(missing),
                label: 'not recorded',
                color: missing >= 30 ? Night.caution : Night.ink,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'A first guess: the sleep model is not yet validated on this headband.'
        '${x == null ? '' : ' ${noiseSentence(x)}'}',
        style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
      ),
      if (wearerLeads(wearer)) WearerQuestion(line: wearer!, onAnswer: onWearerAnswer, onInfo: onWearerInfo),
      const SizedBox(height: 28),
      SleepChart(
        start: r.dataStart,
        stages: stages,
        periods: bands,
        quality: quality,
        pulse: pulse,
        label: 'Sleep chart, ${clock(r.dataStart)} to ${clock(r.dataEnd)}: '
            '${periods.length == 1 ? '1 sleep period' : '${periods.length} sleep periods'}, '
            '${durationText(missing)} not recorded'
            '${x == null ? '' : '; signal noisy for ${durationText(noisyMin)}, no usable electrode for '
                '${durationText(unusableMin)}'}.',
      ),
      const SizedBox(height: 12),
      SleepLegend(
        showGap: stages.contains('gap'),
        showNoisy: quality?.contains(EpochQuality.degraded) ?? false,
        showUnusable: quality?.contains(EpochQuality.missing) ?? false,
        showPulse: pulse?.any((b) => b != null) ?? false,
      ),
      if (pulse != null || pulseReading) ...[
        const SizedBox(height: 16),
        PulseAsleepLine(
          words: pulse == null ? 'Pulse while asleep: reading the night…' : pulseAsleepWords(pulseAsleep(pulse!, stages)),
          lowest: pulse == null ? null : pulseLowestWords(pulseAsleep(pulse!, stages)),
          onInfo: onPulseInfo,
        ),
      ],
      const SectionHeading('Sleep periods'),
      if (periods.isEmpty)
        Text(
          'No sleep period found: no stretch with 10 minutes or more asleep.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      for (var i = 0; i < periods.length; i++) ...[
        if (i > 0) const Divider(height: 33),
        _PeriodEntry(number: i + 1, period: periods[i]),
      ],
      if (r.straySleepMin > 0) ...[
        const SizedBox(height: 16),
        Text(
          'Plus ${durationText(r.straySleepMin)} scored asleep outside these periods, too short to count.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
      ],
      if (dream != null) DreamSleepCheck(check: dream, onInfo: onDreamInfo),
      if (drift != null)
        FallingAsleepSection(drift: drift, check: driftCheck([r, ...others]), onInfo: onDriftInfo),
      if (alarm != null) WakingUpSection(content: alarm!, onInfo: onAlarmInfo),
      if (x != null) ExtrasSection(extras: x, earlier: earlierJaw(r.nightOf, others), onInfo: onExtrasInfo),
      if (wearer != null && !wearerLeads(wearer))
        WearerRemark(line: wearer!, onAnswer: onWearerAnswer, onInfo: onWearerInfo),
    ];
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(message, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
  );
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.reason, required this.onRetry});
  final String reason;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          reason.isEmpty
              ? 'Scoring this night stopped before it finished; the app may have run out of memory.'
              : 'Scoring this night failed: $reason',
          style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// The chart's legend: the period band, and the swatches of what the chart shows (Sleep so far adds "not scored yet":
/// the empty track where the line breaks).
class SleepLegend extends StatelessWidget {
  const SleepLegend({
    super.key,
    required this.showGap,
    this.showNoisy = false,
    this.showUnusable = false,
    this.showUnscored = false,
    this.showPulse = false,
  });
  final bool showGap;
  final bool showNoisy;
  final bool showUnusable;
  final bool showUnscored;
  final bool showPulse;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted);
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 14,
              decoration: BoxDecoration(color: Night.rule, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 8),
            Text('sleep period, numbered', style: style),
          ],
        ),
        if (showGap)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(size: const Size(18, 14), painter: _HatchSwatch()),
              const SizedBox(width: 8),
              Text('no data', style: style),
            ],
          ),
        if (showNoisy) const SignalSwatch(EpochQuality.degraded),
        if (showUnusable) const SignalSwatch(EpochQuality.missing),
        if (showUnscored)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 14,
                decoration: BoxDecoration(
                  color: Night.track,
                  border: Border.all(color: Night.rule),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Text('not scored yet', style: style),
            ],
          ),
        if (showPulse) const PulseSwatch(),
      ],
    );
  }
}

class _HatchSwatch extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3));
    canvas.clipRRect(r);
    canvas.drawRRect(r, Paint()..color = Night.caution.withValues(alpha: 0.14));
    final p = Paint()
      ..color = Night.caution.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var d = -size.height; d < size.width; d += 6) {
      canvas.drawLine(Offset(d, size.height), Offset(d + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_HatchSwatch old) => false;
}

class _PeriodEntry extends StatelessWidget {
  const _PeriodEntry({required this.number, required this.period});
  final int number;
  final PeriodView period;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = period;
    // label left, minutes right: a log line that stays one line at any text size
    Widget line(String label, double minutes, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(label, style: strong ? text.bodyLarge : text.bodyLarge?.copyWith(color: Night.inkMuted)),
          ),
          Text(
            durationText(minutes),
            style: (strong ? text.titleLarge : text.bodyLarge)?.copyWith(fontFeatures: tabular),
          ),
        ],
      ),
    );
    final wakes = p.wakeUpList;
    final wakeText = p.wakeUps == 0
        ? 'No wake-ups over 5 minutes'
        : 'Awake ${p.wakeUps == 1 ? 'once' : '${p.wakeUps} times'} over 5 minutes: '
              '${[for (final (t, m) in wakes) '${clock(t)} (${durationText(m)})'].join(', ')}';
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Night.rule, borderRadius: BorderRadius.circular(6)),
                child: Text('$number', style: text.titleSmall?.copyWith(fontFeatures: tabular)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  '${clock(p.start)} – ${clock(p.end)}',
                  style: text.titleLarge?.copyWith(fontFeatures: tabular),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          line('Asleep', p.asleepMin, strong: true),
          line('Deep', p.deepMin),
          line('Dream', p.dreamMin),
          line('Light', p.lightMin),
          const SizedBox(height: 12),
          Text(wakeText, style: text.bodyLarge?.copyWith(height: 1.4)),
          if (p.missingMin > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${durationText(p.missingMin)} not recorded inside this period',
              style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _NightRow extends StatelessWidget {
  const _NightRow({required this.report, required this.onTap});
  final SleepReport report;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = report;
    final n = r.periods.length;
    final jaw = r.extras?.asleep.jawPerHour;
    final detail = !r.scored
        ? 'too short to score'
        : '${durationText(r.asleepMin)} asleep · ${n == 1 ? '1 period' : '$n periods'}'
              '${jaw == null ? '' : ' · jaw ${rateText(jaw)}'}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(nightTitle(r.nightOf), style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(detail, style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Night.inkMuted),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.report, required this.onLicences, this.onRescore, this.rawGone});
  final String? rawGone;
  final SleepReport report;
  final VoidCallback? onLicences;
  final VoidCallback? onRescore;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final files = report.inputs.length;
    final s = report.scoringSeconds.round();
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 16),
          Text(
            'Scored on this phone in ${s < 120 ? '$s s' : '${(s / 60).round()} min'} from '
            '${files == 1 ? '1 recording' : '$files recordings'}, ${clock(report.dataStart)} to '
            '${clock(report.dataEnd)}, with AnySleep (three runs averaged; MIT licence).',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
          ),
          if (onRescore != null) ...[
            const SizedBox(height: 12),
            Text(
              'An earlier version of the app scored this night. It is never scored again by itself; scoring it '
              'again takes a few minutes and gives the current model\'s stages.',
              style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onRescore, child: const Text('Score again')),
            ),
          ],
          if (onRescore == null && rawGone != null) ...[
            const SizedBox(height: 12),
            Text(
              'An earlier version of the app scored this night. $rawGone The phone cannot score it again without '
              'it; the laptop can (scripts/sleep_report.py).',
              style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ],
          if (onLicences != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onLicences, child: const Text('Licences')),
            ),
        ],
      ),
    );
  }
}
