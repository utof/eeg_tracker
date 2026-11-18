// The night screen's Morning section (between nights, right after Sleep): whether today's check-in is done, and
// the ways to the check-in and the trends. Kept in its own file so the night screen's change stays two lines.
import 'package:flutter/material.dart';

import 'theme.dart';

class MorningSection extends StatelessWidget {
  const MorningSection({super.key, required this.doneAt, required this.onCheckIn, required this.onTrends});

  /// When today's first check-in was saved ("09:12"), or null.
  final String? doneAt;
  final VoidCallback? onCheckIn;
  final VoidCallback? onTrends;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          doneAt == null
              ? 'About 6 minutes: eyes closed, eyes open on a dot, a few taps and a 1\u2011minute reaction test.'
              : 'Checked in today at $doneAt.',
          style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onCheckIn,
          icon: const Icon(Icons.wb_twilight_rounded),
          label: const Text('Morning check-in'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onTrends, icon: const Icon(Icons.show_chart_rounded), label: const Text('Trends')),
      ],
    );
  }
}
