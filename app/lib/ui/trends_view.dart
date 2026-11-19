// The trends page's layout (.impeccable/surfaces/app-lib-ui-trends-screen-dart.md): a day log. Today's entry first
// (every number with yesterday's and your usual, an arrow only beyond your normal spread, always worded), then
// sleep pressure from the sleep log, the last 14 days as a watch bill, the earlier days' entries, and the
// forecast's status. Built from a TrendsModel only, so tests render it without a phone.
import 'package:flutter/material.dart';

import '../trends/days.dart';
import '../trends/pressure.dart';
import '../trends/trends.dart';
import '../trends/usual.dart';
import 'fortnight.dart';
import 'form_parts.dart' show Para;
import 'parts.dart';
import 'pressure_chart.dart';
import 'theme.dart';

/// Earlier days listed under the lines (the lines cover 14).
const int earlierDays = 7;

String _plural(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

/// The measures with no value in 14 days, lower case, for "Nothing yet for ...". The sharp-hours numbers are left
/// out: the log is a proposal that is off until switched on, so its absence is not news.
List<String> missingMeasures(TrendsModel m) => [
  for (final r in m.rows)
    if (!r.hasData && r.spec.group != TrendGroup.day) r.spec.label.toLowerCase(),
];

/// The page's first lines: what exists, and while it matters, when "usual" and arrows begin.
String trendsSummary(TrendsModel m) {
  if (m.daysWithData == 0) return 'Nothing recorded yet. Your usual shows after $usualMinDays days, arrows after $arrowMinDays.';
  final have = '${_plural(m.nights, 'night', 'nights')}, ${_plural(m.mornings, 'check-in', 'check-ins')} and '
      '${_plural(m.sessions, 'practice session', 'practice sessions')} so far.';
  if (m.daysWithData < arrowMinDays) {
    return '$have Your usual shows after $usualMinDays days with a value, arrows after $arrowMinDays.';
  }
  return '$have Your usual is the middle of your last $usualWindowDays days; an arrow means a day beyond your '
      'normal spread.';
}

/// The sleep-pressure headline: "Like 9 hours awake after a regular night", or why there is none.
String pressureHeadline(PressureModel p, DateTime now) {
  if (p.isEmpty) return 'No scored night yet: the estimate starts with the first one.';
  final h = p.hoursAwakeLike(now);
  if (h == null) {
    final w = p.lastWake!;
    return 'No sleep recorded since ${dayLabel(dayKey(w))}: the estimate needs the last night.';
  }
  if (p.asleepAt(now)) return 'Asleep by the log: pressure is draining.';
  if (h < 0.5) return 'Rested: like just after a regular night.';
  return 'Like ${h.round()} ${h.round() == 1 ? 'hour' : 'hours'} awake after a regular night.';
}

class TrendsView extends StatelessWidget {
  const TrendsView({
    super.key,
    required this.model,
    this.onInfo,
    this.onExperiments,
    this.experimentLine,
    this.onSharp,
    this.sharpLine,
  });
  final TrendsModel model;
  final VoidCallback? onInfo;

  /// Opens the sharp-hours page (the assistant's proposal, DECISIONS rows 280-289); the section shows only with it.
  final VoidCallback? onSharp;
  final String? sharpLine;

  /// Opens the self-experiments page; the section shows only with it. [experimentLine]: today's task or where the
  /// experiment stands (experiments_view.dart), null without one.
  final VoidCallback? onExperiments;
  final String? experimentLine;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final m = model;
    final withData = [
      for (final r in m.rows)
        if (r.hasData) r,
    ];
    final lines = [
      for (final r in withData)
        if (r.line.where((v) => v != null).length >= 2) r,
    ];
    final none = missingMeasures(m);
    final earlier = [
      for (final d in lastDays(addDays(m.today, -1), earlierDays).reversed)
        if (m.rows.any((r) => r.line[lineDays - 1 - daysBetween(d, m.today)] != null)) d,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('Trends', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Para(trendsSummary(m), color: Night.inkMuted, top: 0),
          SectionHeading('Today, ${dayLabel(m.today)}'),
          if (withData.isEmpty) const Para('No numbers in the last 14 days yet.', color: Night.inkMuted, top: 0),
          for (final (i, r) in withData.indexed) ...[
            if (i > 0) const Divider(height: 29),
            MeasureEntry(row: r, today: m.today),
          ],
          if (none.isNotEmpty && withData.isNotEmpty) Para('Nothing yet for ${_join(none)}.', color: Night.inkMuted, top: 20),
          const SectionHeading('Sleep pressure'),
          Text(pressureHeadline(m.pressure, m.now), style: text.titleLarge?.copyWith(height: 1.3)),
          if (!m.pressure.isEmpty) ...[
            const SizedBox(height: 16),
            PressureChart(
              model: m.pressure,
              now: m.now,
              label: 'Sleep pressure over the last 36 hours, an estimate from your sleep times.',
            ),
          ],
          const Para(
            'An estimate from your sleep times only, not measured. Your body clock and coffee are not in it, so an '
            'evening can feel more awake than this shows.',
            color: Night.inkMuted,
          ),
          if (withData.isNotEmpty) ...[
            const SectionHeading('The last 14 days'),
            if (lines.isEmpty)
              const Para('The lines start with a second day.', color: Night.inkMuted, top: 0)
            else ...[
              for (final r in lines) _FortnightEntry(row: r),
              _DayTicks(today: m.today),
            ],
          ],
          if (earlier.isNotEmpty) ...[
            const SectionHeading('Earlier days'),
            for (final (i, d) in earlier.indexed) ...[
              if (i > 0) const Divider(height: 25),
              _DayEntry(day: d, rows: m.rows, today: m.today),
            ],
          ],
          if (onExperiments != null) ...[
            const SectionHeading('Self-experiments'),
            Para(
              experimentLine ??
                  'Everything above is only seen together. To test one habit, let the app draw random days for a '
                      'few weeks.',
              color: experimentLine == null ? Night.inkMuted : Night.ink,
              top: 0,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onExperiments,
              icon: const Icon(Icons.science_outlined),
              label: const Text('Experiments'),
            ),
          ],
          if (onSharp != null) ...[
            const SectionHeading('Sharp hours'),
            Para(sharpLine ?? '', color: Night.inkMuted, top: 0),
            const SizedBox(height: 16),
            OutlinedButton.icon(onPressed: onSharp, icon: const Icon(Icons.schedule), label: const Text('Sharp hours')),
          ],
          const SectionHeading("Tomorrow's sleepiness"),
          if (m.forecast.shown) ...[
            Text(
              'Probably ${m.forecast.low} to ${m.forecast.high} of 9.',
              style: text.titleLarge?.copyWith(fontFeatures: tabular),
            ),
            Para(m.forecast.why, color: Night.inkMuted),
          ] else
            Para(m.forecast.why, color: Night.inkMuted, top: 0),
        ],
      ),
    );
  }
}

String _join(List<String> items) =>
    items.length <= 1 ? items.join() : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

/// The words under a number: yesterday's value and your usual (or how many days until it shows).
String usualLine(TrendRow r, String today) {
  final f = r.spec.format, u = r.usual;
  final y = r.yesterday;
  final before = r.day == today ? 'yesterday' : 'the day before';
  final parts = [
    y == null ? '$before: none' : '$before ${f(y)}',
    u.ready ? 'usual ${f(u.median!)}' : 'usual after ${_plural(u.daysToUsual, 'more day', 'more days')}',
  ];
  return parts.join(' · ');
}

/// "270 to 330 ms", "1 to 7 of 9": a normal range kept inside the measure's scale, the unit said once.
String rangeText(MeasureSpec spec, double low, double high) {
  final lo = spec.format(low < spec.min ? spec.min : low);
  final hi = spec.format(spec.max != null && high > spec.max! ? spec.max! : high);
  final a = lo.indexOf('\u00a0'), b = hi.indexOf('\u00a0');
  final unit = a > 0 ? lo.substring(a) : '';
  // the same unit after both numbers ("ms", "of 9"), but not durations ("h 09 min")
  if (a > 0 && b > 0 && unit == hi.substring(b) && (unit.startsWith('\u00a0of\u00a0') || !RegExp(r'\d').hasMatch(unit))) {
    return '${lo.substring(0, a)} to $hi';
  }
  return '$lo to $hi';
}

/// What the arrow or its absence means, in words; null when nothing is to be said yet.
String? arrowWords(TrendRow r) {
  final u = r.usual;
  if (!r.spec.scale.arrows || !u.ready) return null;
  if (!u.arrowsReady) return 'Arrows after ${_plural(u.daysToArrows, 'more day', 'more days')}.';
  // a rating can only be whole: the range names the whole values that get no arrow
  final whole = r.spec.scale == Scale.rating;
  final range = whole
      ? rangeText(r.spec, (u.low!.floor() + 1).toDouble(), (u.high!.ceil() - 1).toDouble())
      : rangeText(r.spec, u.low!, u.high!);
  return switch (r.arrow) {
    Arrow.up => '${_cap(r.spec.up)} (normal range $range).',
    Arrow.down => '${_cap(r.spec.down)} (normal range $range).',
    Arrow.none => 'Within your normal range ($range).',
  };
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// One number of a day: label and value, then yesterday and your usual, then the arrow in words.
class MeasureEntry extends StatelessWidget {
  const MeasureEntry({super.key, required this.row, required this.today});
  final TrendRow row;
  final String today;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = row;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35, fontFeatures: tabular);
    final words = arrowWords(r);
    final arrow = r.arrow;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(r.spec.label, style: text.bodyLarge)),
              const SizedBox(width: 12),
              if (arrow != Arrow.none) ...[
                Icon(arrow == Arrow.up ? Icons.north_rounded : Icons.south_rounded, size: 20, color: Night.ink),
                const SizedBox(width: 4),
              ],
              Text(r.spec.format(r.value!), style: text.titleLarge?.copyWith(fontFeatures: tabular)),
            ],
          ),
          if (r.day != today) Text('on ${dayLabel(r.day!)}', style: muted),
          const SizedBox(height: 4),
          Text(usualLine(r, today), style: muted),
          if (words != null) ...[
            const SizedBox(height: 2),
            Text(words, style: (arrow == Arrow.none ? muted : text.bodyMedium?.copyWith(height: 1.35))),
          ],
          if (r.spec.note != null) ...[const SizedBox(height: 2), Text(r.spec.note!, style: muted)],
        ],
      ),
    );
  }
}

class _FortnightEntry extends StatelessWidget {
  const _FortnightEntry({required this.row});
  final TrendRow row;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = row;
    final u = r.usual;
    final n = r.line.where((v) => v != null).length;
    final vals = [for (final v in r.line) ?v];
    vals.sort();
    final f = r.spec.format;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.spec.label, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
          const SizedBox(height: 6),
          FortnightRow(
            values: r.line,
            band: u.arrowsReady ? (u.low!, u.high!) : null,
            logScale: r.spec.scale.logScale,
            label: '${r.spec.label}, last 14 days: ${_plural(n, 'day', 'days')} with a value'
                '${n > 1 ? ', from ${f(vals.first)} to ${f(vals.last)}' : ''}.',
          ),
        ],
      ),
    );
  }
}

/// Weekday letters under the watch bill, today last.
class _DayTicks extends StatelessWidget {
  const _DayTicks({required this.today});
  final String today;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: Night.inkMuted);
    final days = lastDays(today, lineDays);
    return ExcludeSemantics(
      child: Row(
        children: [
          for (final (i, d) in days.indexed) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Text(
                i == days.length - 1 ? 'today' : weekdayShort(d)[0],
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: i == days.length - 1 ? style?.copyWith(color: Night.ink) : style,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// An earlier day: its date, then its numbers on one wrapped line.
class _DayEntry extends StatelessWidget {
  const _DayEntry({required this.day, required this.rows, required this.today});
  final String day;
  final List<TrendRow> rows;
  final String today;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final k = lineDays - 1 - daysBetween(day, today);
    final items = [
      for (final r in rows)
        if (r.line[k] != null) '${r.spec.label} ${r.spec.format(r.line[k]!)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(day == addDays(today, -1) ? 'Yesterday, ${dayLabel(day)}' : dayLabel(day), style: text.titleSmall),
        const SizedBox(height: 4),
        Text(
          items.join(' · '),
          style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4, fontFeatures: tabular),
        ),
      ],
    );
  }
}
