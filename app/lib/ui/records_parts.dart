// Pieces of the three record pages under More (App log, How I use the app, Battery; DECISIONS 712-716): the links
// on the More tab, label-left / value-right rows with a muted line under them, a switch row with its sentence, the
// period choice, and the consumer bar (the band strip's 8 dp bar: `saved` on `track`).
import 'package:flutter/material.dart';

import 'battery_screen.dart';
import 'logs_screen.dart';
import 'theme.dart';
import 'usage_screen.dart';

/// The More tab's section "How the app runs": three log rows that open the pages.
class RecordsLinks extends StatelessWidget {
  const RecordsLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Widget row(String title, String line, Widget page, Key key) => InkWell(
      key: key,
      onTap: () => open(page),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.bodyLarge),
                    const SizedBox(height: 2),
                    Text(line, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Night.inkMuted),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'What the app did, how you use it and what costs battery. Kept on this phone; Export data takes it to the laptop.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 8),
        row('App log', 'Every part of the app, errors first', const LogsScreen(), const ValueKey('records-log')),
        const Divider(),
        row('How I use the app', 'Screens, taps, features, hints', const UsageScreen(), const ValueKey('records-usage')),
        const Divider(),
        row('Battery', 'What costs the phone\'s and the headband\'s battery', const BatteryScreen(), const ValueKey('records-battery')),
      ],
    );
  }
}

/// Label left, value right in tabular titleMedium, an optional muted line under both (DESIGN.md log rows).
class RecordRow extends StatelessWidget {
  const RecordRow({super.key, required this.label, required this.value, this.note, this.valueColor = Night.ink});
  final String label, value;
  final String? note;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(label, style: text.bodyLarge)),
              const SizedBox(width: 12),
              Text(value, style: text.titleMedium?.copyWith(fontFeatures: tabular, color: valueColor)),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note!, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35)),
          ],
        ],
      ),
    );
  }
}

/// A muted sentence of a page.
class MutedLine extends StatelessWidget {
  const MutedLine(this.text, {super.key, this.top = 8});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top),
    child: Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
  );
}

/// A switch with its words: the title in ink, what it does in a muted sentence under it.
class RecordSwitch extends StatelessWidget {
  const RecordSwitch({super.key, required this.title, required this.line, required this.value, required this.onChanged});
  final String title, line;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleMedium),
                  const SizedBox(height: 4),
                  Text(line, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// Today, the last 7 days, the last 30 days: the app's segmented row.
class PeriodChoice extends StatelessWidget {
  const PeriodChoice({super.key, required this.days, required this.onChanged, this.choices = const [1, 7, 30]});
  final int days;
  final List<int> choices;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<int>(
    showSelectedIcon: false,
    style: choiceStyle,
    segments: [
      for (final d in choices) ButtonSegment(value: d, label: Text(d == 1 ? 'Today' : '$d days')),
    ],
    selected: {days},
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

/// The app's choice rows (form_parts.dart): the chosen one a step lighter (`rule`) in ink, the others ink-muted.
final ButtonStyle choiceStyle = SegmentedButton.styleFrom(
  minimumSize: const Size.fromHeight(48),
  selectedBackgroundColor: Night.rule,
  selectedForegroundColor: Night.ink,
  foregroundColor: Night.inkMuted,
  side: const BorderSide(color: Night.rule),
);

/// A filter chip as the "Unusual for you" card's (DESIGN.md): ground with a rule outline; chosen, surface-high with an
/// ink check and an ink-muted outline.
class RecordChip extends StatelessWidget {
  const RecordChip({super.key, required this.label, required this.selected, required this.onSelected});
  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    onSelected: onSelected,
    showCheckmark: true,
    checkmarkColor: Night.ink,
    selectedColor: Night.surfaceHigh,
    backgroundColor: Night.ground,
    side: BorderSide(color: selected ? Night.inkMuted : Night.rule),
    labelStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: selected ? Night.ink : Night.inkMuted,
      fontFeatures: tabular,
    ),
  );
}

/// An 8 dp bar: [share] (0-1) of its width in `saved` on the `track` ground.
class ShareBar extends StatelessWidget {
  const ShareBar(this.share, {super.key});
  final double share;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 8,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Night.track),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: share.clamp(0.0, 1.0),
              child: const ColoredBox(color: Night.saved),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The page's body while it loads, or when its folder could not be read.
Widget recordsWaiting(BuildContext context, String? error) => Padding(
  padding: const EdgeInsets.all(24),
  child: Text(
    error == null ? 'Reading…' : 'The app could not read its records: $error',
    style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: error == null ? Night.inkMuted : Night.caution),
  ),
);

/// `412 MB`, `3.4 MB`, `820 kB`.
String sizeWords(num bytes) {
  if (bytes >= 1e9) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 1e7) return '${(bytes / 1e6).toStringAsFixed(0)} MB';
  if (bytes >= 1e6) return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  return '${(bytes / 1e3).toStringAsFixed(0)} kB';
}
