// "Sleep so far" (DECISIONS 640-649): the night screen's section while a night records, and its page, from plain
// values so both render in tests without a phone. The page is the sleep report's own chart and lines cut off 2 minutes
// behind the recording, with the provisional nature said next to the numbers. Design: DESIGN.md and
// .impeccable/surfaces/app-lib-ui-sleep-so-far-view-dart.md.
import 'package:flutter/material.dart';

import '../sleep/periods.dart' show gapStage;
import '../sleep/so_far.dart';
import 'parts.dart';
import 'sleep_chart.dart';
import 'sleep_report_view.dart' show SleepLegend, clock, durationParts, durationText;
import 'theme.dart';

/// The section's line: what the last look found, or what the button does; [refusal] when there is no sleep so far
/// (the DIY board).
String soFarLine(SoFarResult? r, {String? refusal}) {
  if (refusal != null) return refusal;
  if (r == null || r.stages.isEmpty) {
    return 'The sleep chart and totals of the night so far, scored on this phone when you open it.';
  }
  return 'At the last look: ${durationText(r.asleepMin)} asleep by ${clock(r.end)}.';
}

/// Why a board's night has no sleep so far: the sleep model reads O1, O2, T3 and T4 (T7 and T8 are the same sites);
/// null when [names] has them.
String? sleepChannelsMissing(List<String> names) {
  final have = {for (final n in names) n.toUpperCase()};
  final missing = [
    for (final (want, alias) in const [('O1', 'O1'), ('O2', 'O2'), ('T3', 'T7'), ('T4', 'T8')])
      if (!have.contains(want) && !have.contains(alias)) want,
  ];
  return missing.isEmpty ? null : missing.join(', ');
}

/// The DIY board's plain refusal.
String diySoFarRefusal(List<String> names) {
  final missing = sleepChannelsMissing(names);
  return missing == null
      ? 'No sleep so far for the DIY board: its recordings are a test, and the sleep model reads only the '
            'BrainBit\'s nights.'
      : 'No sleep so far for the DIY board: the sleep model reads O1, O2, T3 and T4, and the board records '
            '${names.join(' ')} (no $missing).';
}

/// The night screen's section: one muted line and the button (none for a refusal).
class SoFarSection extends StatelessWidget {
  const SoFarSection({super.key, required this.line, this.onOpen});
  final String line;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
        if (onOpen != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.show_chart),
            label: const Text('See sleep so far'),
          ),
        ],
      ],
    );
  }
}

/// What the page is doing, in the status line.
class SoFarState {
  const SoFarState({this.step, this.waiting, this.failed, this.ended = false, this.busy = false});

  /// The look's current step ("Scoring 01:04 to 02:08 (2 of 4)").
  final String? step;

  /// Why the last look waits ("the live sleep model runs for the smart alarm").
  final String? waiting;

  /// Why the last look failed.
  final String? failed;

  /// The night was stopped: its report comes next.
  final bool ended;
  final bool busy;
}

class SleepSoFarView extends StatelessWidget {
  const SleepSoFarView({
    super.key,
    required this.result,
    this.state = const SoFarState(),
    this.everyMinutes = 15,
    this.onUpdate,
    this.onInfo,
  });

  /// Null or empty: nothing to show yet.
  final SoFarResult? result;
  final SoFarState state;
  final int everyMinutes;
  final VoidCallback? onUpdate;
  final VoidCallback? onInfo;

  String _status(SoFarResult? r) {
    final s = state;
    if (s.ended) return 'The night has ended. Its report is scored after Stop and replaces this.';
    if (s.step != null) return '${s.step}.';
    if (s.failed != null) return 'Could not score just now: ${s.failed}';
    if (s.waiting != null) {
      return 'Waiting: ${s.waiting}. Its readings fill in until it is done.';
    }
    if (r == null || r.stages.isEmpty) return 'Nothing to show yet: the sleep model needs 5 minutes of recording.';
    return 'Scored up to ${clock(r.end)}, 2 minutes behind the recording at that look.';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = result;
    final has = r != null && r.stages.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text('Tonight so far', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [
          _StatusLine(
            text: _status(r),
            caution: state.failed != null,
            onUpdate: state.busy || state.ended ? null : onUpdate,
          ),
          if (has) ..._scored(context, r),
        ],
      ),
    );
  }

  List<Widget> _scored(BuildContext context, SoFarResult r) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final body = text.bodyLarge?.copyWith(height: 1.4);
    final fell = r.fellAsleep;
    final periods = r.periods;
    final wakes = [for (final p in periods) ...p.wakeUpList];
    final missing = r.missingMin;
    final unscoredMin = r.unscored * 0.5, liveMin = r.liveEpochs * 0.5;
    return [
      const SizedBox(height: 20),
      IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: Readout(parts: durationParts(r.asleepMin), label: 'asleep so far')),
            const VerticalDivider(width: 33),
            Expanded(
              child: Readout(parts: [(fell == null ? '–' : clock(fell), true)], label: 'fell asleep'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'So far: after Stop the whole night is scored together, which can move some edges between stages, so the '
        'report may differ slightly. A first guess: the sleep model is not yet validated on this headband.',
        style: muted,
      ),
      const SizedBox(height: 28),
      SleepChart(
        start: r.start,
        stages: r.stages,
        periods: r.bands,
        label: 'Sleep chart so far, ${clock(r.start)} to ${clock(r.end)}: '
            '${periods.length == 1 ? '1 sleep period' : '${periods.length} sleep periods'}'
            '${missing > 0 ? ', ${durationText(missing)} not recorded' : ''}'
            '${unscoredMin > 0 ? ', ${durationText(unscoredMin)} not scored yet' : ''}.',
      ),
      const SizedBox(height: 12),
      SleepLegend(showGap: r.stages.contains(gapStage), showUnscored: r.unscored > 0),
      const SectionHeading('So far'),
      _Line('Asleep', r.asleepMin, strong: true),
      _Line('Deep', r.deepMin),
      _Line('Dream', r.dreamMin),
      _Line('Light', r.lightMin),
      _Line('Awake in between', r.awakeMin),
      const SizedBox(height: 12),
      Text(
        periods.isEmpty
            ? 'No sleep period yet: no stretch with 10 minutes or more asleep.'
            : wakes.isEmpty
            ? 'No wake-ups over 5 minutes.'
            : 'Awake ${wakes.length == 1 ? 'once' : '${wakes.length} times'} over 5 minutes: '
                  '${[for (final (t, m) in wakes) '${clock(t)} (${durationText(m)})'].join(', ')}.',
        style: body,
      ),
      if (periods.length > 1) ...[
        const SizedBox(height: 8),
        Text('${periods.length} sleep periods, numbered on the chart (an hour or more awake between them).', style: body),
      ],
      if (missing > 0) ...[
        const SizedBox(height: 8),
        Text('${durationText(missing)} not recorded (hatched on the chart).', style: body?.copyWith(color: Night.caution)),
      ],
      if (r.straySleepMin > 0) ...[
        const SizedBox(height: 8),
        Text('Plus ${durationText(r.straySleepMin)} asleep outside the periods, too short to count.', style: muted),
      ],
      if (liveMin > 0) ...[
        const SizedBox(height: 8),
        Text(
          '${durationText(liveMin)} of the chart are the live sleep model\'s own readings, shown while scoring '
          'waited for it.',
          style: muted,
        ),
      ],
      if (unscoredMin > 0) ...[
        const SizedBox(height: 8),
        Text('${durationText(unscoredMin)} not scored yet: blank on the chart until the next look.', style: muted),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(),
            const SizedBox(height: 16),
            Text(
              'Scored on this phone in ${r.seconds < 120 ? '${r.seconds.round()} s' : '${(r.seconds / 60).round()} min'} '
              'over ${r.looks == 1 ? '1 look' : '${r.looks} looks'}, each scoring only what was new. It looks again '
              'every $everyMinutes minutes while this page is open, never with the screen off.',
              style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
            ),
          ],
        ),
      ),
    ];
  }
}

/// The page's status in the alarm line's form: one muted line with one text button at its right.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.caution, required this.onUpdate});
  final String text;
  final bool caution;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              text,
              style: t.bodyMedium?.copyWith(color: caution ? Night.caution : Night.inkMuted, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onUpdate, child: const Text('Update')),
        ],
      ),
    );
  }
}

/// Label left, minutes right, as a sleep period's lines.
class _Line extends StatelessWidget {
  const _Line(this.label, this.minutes, {this.strong = false});
  final String label;
  final double minutes;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
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
  }
}
