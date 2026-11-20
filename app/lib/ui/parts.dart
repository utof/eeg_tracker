// Pieces both screens share: a section heading under a hairline, and a big tabular readout.
import 'package:flutter/material.dart';

import 'theme.dart';

/// A hairline, then the section's name (titleMedium 500), 32 dp above it (DESIGN.md Layout).
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 20),
        Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
      ],
    ),
  );
}

/// A big number with small units beside it and a muted label under it (DESIGN.md Readouts).
class Readout extends StatelessWidget {
  const Readout({super.key, required this.parts, required this.label, this.color = Night.ink});

  /// (text, isNumber): numbers large, units small.
  final List<(String, bool)> parts;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final big = text.displayMedium?.copyWith(color: color);
    final unit = text.titleLarge?.copyWith(color: color == Night.ink ? Night.inkMuted : color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [for (final (s, isNumber) in parts) TextSpan(text: s, style: isNumber ? big : unit)],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
      ],
    );
  }
}

