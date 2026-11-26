// The morning check-in offer's line above the Record tab's buttons (DECISIONS 1110): one muted sentence and two
// buttons, in the pinned bar like the sleep experiment's question. The rule is morning/offer.dart; this only draws it.
import 'package:flutter/material.dart';

import '../morning/offer.dart';
import 'theme.dart';

class MorningOfferLine extends StatelessWidget {
  const MorningOfferLine({super.key, required this.offer, required this.onCheckIn, required this.onNotNow});

  final MorningOffer offer;
  final VoidCallback onCheckIn;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(offer.line, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35)),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: onNotNow, child: const Text('Not now')),
              FilledButton(onPressed: onCheckIn, child: const Text('Check in')),
            ],
          ),
        ],
      ),
    );
  }
}
