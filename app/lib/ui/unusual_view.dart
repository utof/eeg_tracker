// The "Unusual for you" section (.impeccable/surfaces/app-lib-ui-unusual-view-dart.md; DECISIONS 290-299), in the
// Trends page's one slot for it, right after the page's summary line. A remark in the day log: the heading with
// its "i" and the switch always in the same place; most days one line under it; with a card, the day's first entry
// as a sentence, what it is based on, the everyday causes, and "What might explain it?". Words, never colours.
// Built from an UnusualCard only, so tests render it without a phone.
import 'package:flutter/material.dart';

import '../unusual/card.dart';
import 'theme.dart';

class UnusualSection extends StatelessWidget {
  const UnusualSection({
    super.key,
    required this.card,
    this.error,
    this.onSwitch,
    this.onInfo,
    this.onCauses,
    this.onResume,
  });

  /// Today's card; null when it could not be worked out ([error] says why).
  final UnusualCard? card;
  final String? error;
  final ValueChanged<bool>? onSwitch;
  final VoidCallback? onInfo;

  /// The causes chosen for the card shown (ids from card.dart's unusualCauses).
  final ValueChanged<Set<String>>? onCauses;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = card;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final ink = text.bodyLarge?.copyWith(height: 1.45);
    final big = text.titleLarge?.copyWith(height: 1.3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Heading(on: c != null && c.kind != CardKind.off, onSwitch: c == null ? null : onSwitch, onInfo: onInfo),
        if (c == null)
          Text('It could not be worked out: ${error ?? 'unknown reason'}.', style: muted)
        else
          ...switch (c.kind) {
            CardKind.off || CardKind.learning => [Text('${c.headline} ${c.status ?? ''}'.trim(), style: muted)],
            CardKind.quiet => [
              Text(c.headline, style: ink),
              if (c.status != null) ...[const SizedBox(height: 4), Text(c.status!, style: muted)],
            ],
            CardKind.alert => _alert(context, c, big, ink, muted),
            CardKind.back => [
              Text(c.headline, style: big),
              for (final l in c.lines) ...[const SizedBox(height: 6), Text(l, style: muted)],
            ],
            CardKind.paused => [
              Text(c.headline, style: big),
              if (c.status != null) ...[const SizedBox(height: 6), Text(c.status!, style: muted)],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: onResume, child: const Text('Resume now')),
              ),
            ],
          },
      ],
    );
  }

  List<Widget> _alert(BuildContext context, UnusualCard c, TextStyle? big, TextStyle? ink, TextStyle? muted) {
    final text = Theme.of(context).textTheme;
    return [
      Text(c.headline, style: big),
      for (final l in c.lines) ...[const SizedBox(height: 8), Text(l, style: ink)],
      if (c.status != null) ...[const SizedBox(height: 12), Text(c.status!, style: muted)],
      const SizedBox(height: 8),
      Text(cardCaveat, style: muted),
      const SizedBox(height: 12),
      Text('If you can, take it easy today.', style: ink),
      const SizedBox(height: 24),
      Text('What might explain it?', style: text.titleSmall),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (id, label) in unusualCauses)
            FilterChip(
              label: Text(label),
              selected: c.causes.contains(id),
              onSelected: onCauses == null
                  ? null
                  : (on) => onCauses!(on ? ({...c.causes, id}) : ({...c.causes}..remove(id))),
              showCheckmark: true,
              checkmarkColor: Night.ink,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              selectedColor: Night.surfaceHigh,
              backgroundColor: Night.ground,
              side: BorderSide(color: c.causes.contains(id) ? Night.inkMuted : Night.rule),
              labelStyle: text.bodyLarge?.copyWith(color: c.causes.contains(id) ? Night.ink : Night.inkMuted),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'Optional, for your own record. "Feeling ill" pauses these cards for two weeks and keeps those days out of '
        'your usual.',
        style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4),
      ),
    ];
  }
}

/// The hairline, the title, its "i" and the switch: the same place in every state.
class _Heading extends StatelessWidget {
  const _Heading({required this.on, this.onSwitch, this.onInfo});
  final bool on;
  final ValueChanged<bool>? onSwitch;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Unusual for you',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            IconButton(
              onPressed: onInfo,
              tooltip: 'What the research says about unusual-for-you cards',
              icon: const Icon(Icons.info_outline, color: Night.inkMuted),
            ),
            Semantics(
              label: 'Unusual-for-you cards',
              child: Switch(value: on, onChanged: onSwitch),
            ),
          ],
        ),
      ],
    ),
  );
}
