// Pieces both screens share: a section heading under a hairline, and a big tabular readout.
import 'package:flutter/material.dart';

import '../recorder/contact.dart';
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

/// One channel's contact: name, then a mark and a word in the trio's colour (DESIGN.md Shapes).
class ContactCell extends StatelessWidget {
  const ContactCell(this.channel, this.contact, {super.key});
  final String channel;
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color, word) = switch (contact) {
      Contact.good => (Icons.circle, Night.live, 'good'),
      Contact.fair => (Icons.adjust, Night.caution, 'fair'),
      Contact.poor => (Icons.radio_button_unchecked, Night.problem, 'poor'),
      Contact.none => (Icons.remove, Night.inkMuted, 'none'),
    };
    return Semantics(
      label: '$channel contact $word',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(channel, style: text.titleMedium),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(word, style: text.bodyLarge?.copyWith(color: color)),
            ],
          ),
        ],
      ),
    );
  }
}
