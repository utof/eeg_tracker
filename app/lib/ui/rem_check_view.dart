// The night report's "Dream sleep check" (DECISIONS 740-749): a few sentences, not a score, from the report's
// `rem_check` (sleep/rem_check.dart `remCheckLines`, the same words scripts/phone_night_check.py prints). The first
// sentence says how much dream sleep was scored against the usual share; the rest are the checks a later scoring fix
// is judged by. Its "i" opens the sleep-scoring note, which warns that dream sleep may be under-counted.
import 'package:flutter/material.dart';

import '../sleep/rem_check.dart';
import 'theme.dart';

class DreamSleepCheck extends StatelessWidget {
  const DreamSleepCheck({super.key, required this.check, this.onInfo});

  /// The report's `rem_check` (or the stage-only check of an older report).
  final Map<String, Object?> check;
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final lines = [for (final l in remCheckLines(check)) _keepTogether(l)];
    final body = text.bodyLarge?.copyWith(height: 1.4);
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 32, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text('Dream sleep check', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    if (onInfo != null)
                      IconButton(
                        onPressed: onInfo,
                        tooltip: 'Why dream sleep may be under-counted',
                        icon: const Icon(Icons.info_outline, color: Night.inkMuted),
                      ),
                  ],
                ),
              ],
            ),
          ),
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: Text(lines[i], style: i == 0 ? body : body?.copyWith(color: Night.inkMuted)),
            ),
        ],
      ),
    );
  }
}

/// `2 h 05 min`, `43 min` and `10 %` never split across lines.
String _keepTogether(String s) => s
    .replaceAllMapped(RegExp(r'(\d) (h|min|%)'), (m) => '${m[1]}\u00a0${m[2]}')
    .replaceAllMapped(RegExp(r'(\d\u00a0h) (\d)'), (m) => '${m[1]}\u00a0${m[2]}');
