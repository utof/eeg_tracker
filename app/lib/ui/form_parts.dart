// Answer controls for the after-session questions, the check-in and the screening: Material components in the
// night-watch theme (DESIGN.md), each with its question above it in body text and, for scales, the meaning of
// both ends under it. Nothing is preselected: an answer is always the user's own.
import 'package:flutter/material.dart';

import 'theme.dart';

/// A question over one row of choices (a 1-5 scale, live / replay / not sure, yes / no).
class ChoiceQuestion<T extends Object> extends StatelessWidget {
  const ChoiceQuestion({
    super.key,
    required this.question,
    required this.choices,
    required this.value,
    required this.onChanged,
    this.ends,
  });

  final String question;

  /// (value, label) per segment.
  final List<(T, String)> choices;
  final T? value;
  final ValueChanged<T> onChanged;

  /// Words under the first and the last segment, for a scale.
  final (String, String)? ends;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: text.bodyLarge?.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              segments: [for (final (v, label) in choices) ButtonSegment(value: v, label: Text(label))],
              selected: {?value},
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                if (s.isNotEmpty) onChanged(s.first);
              },
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
          if (ends != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text(ends!.$1, style: muted)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(ends!.$2, style: muted, textAlign: TextAlign.end),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A 1-5 scale question.
ChoiceQuestion<int> scaleQuestion(String q, int? value, ValueChanged<int> on, (String, String) ends) =>
    ChoiceQuestion<int>(
      question: q,
      choices: [for (var i = 1; i <= 5; i++) (i, '$i')],
      value: value,
      onChanged: on,
      ends: ends,
    );

/// A question answered on a slider (distress 0-10, sleepiness 1-9, confidence 0-100), the value shown beside it.
class SliderQuestion extends StatelessWidget {
  const SliderQuestion({
    super.key,
    required this.question,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.ends,
    this.step = 1,
    this.unit = '',
  });

  final String question;

  /// Null until moved: the thumb rests in the middle, the readout says "not set".
  final int? value;
  final int min, max, step;
  final ValueChanged<int> onChanged;
  final (String, String) ends;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted);
    final v = value;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(question, style: text.bodyLarge?.copyWith(height: 1.4))),
              const SizedBox(width: 16),
              Text(
                v == null ? 'not set' : '$v$unit',
                style: (v == null ? muted : text.titleMedium)?.copyWith(fontFeatures: tabular),
              ),
            ],
          ),
          Slider(
            value: (v ?? (min + max) / 2).toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: (max - min) ~/ step,
            label: v == null ? null : '$v$unit',
            activeColor: v == null ? Night.rule : Night.inkMuted,
            inactiveColor: Night.track,
            thumbColor: v == null ? Night.inkMuted : Night.ink,
            onChanged: (d) => onChanged(d.round()),
          ),
          Row(
            children: [
              Expanded(child: Text(ends.$1, style: muted)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(ends.$2, style: muted, textAlign: TextAlign.end),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tick what applies: one checkbox row per item (48 dp rows, the box first).
class Checklist extends StatelessWidget {
  const Checklist({super.key, required this.items, required this.ticked, required this.onChanged});
  final List<String> items;
  final Set<int> ticked;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final (i, item) in items.indexed)
        CheckboxListTile(
          value: ticked.contains(i),
          onChanged: (v) => onChanged(v == true ? ({...ticked, i}) : ({...ticked}..remove(i))),
          title: Text(item, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.3)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          activeColor: Night.inkMuted,
          checkColor: Night.ground,
          side: const BorderSide(color: Night.inkMuted, width: 1.5),
        ),
    ],
  );
}

/// A plain paragraph in body text.
class Para extends StatelessWidget {
  const Para(this.text, {super.key, this.color = Night.ink, this.top = 12});
  final String text;
  final Color color;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top),
    child: Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: color, height: 1.45)),
  );
}

/// The screen's one action, pinned at the bottom (DESIGN.md Layout).
class PinnedAction extends StatelessWidget {
  const PinnedAction({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 16), child: child),
  );
}
