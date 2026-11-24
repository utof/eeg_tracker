// The confirmation questions' settings page (DECISIONS 860-869): the switch, how many, and the quiet hours. The
// questions' own widgets (ConfirmBatch, ConfirmCard) are in packages/shared_labels. No files here: the screen side is
// confirm_screen.dart.
import 'package:flutter/material.dart';

import 'package:shared_labels/shared_labels.dart';
import 'theme.dart';

String _clock(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// The settings page: the switch, how many, and the quiet hours.
class ConfirmSettingsView extends StatelessWidget {
  const ConfirmSettingsView({
    super.key,
    required this.settings,
    required this.onChanged,
    this.notificationsOn = true,
    this.onNotificationSettings,
    this.onPickTime,
    this.onInfo,
  });

  final ConfirmSettings settings;
  final ValueChanged<ConfirmSettings> onChanged;

  /// The phone allows the questions' notifications.
  final bool notificationsOn;
  final VoidCallback? onNotificationSettings;

  /// Asks for a time of day (minutes), starting from the given one; null when cancelled.
  final Future<int?> Function(int minutes)? onPickTime;
  final VoidCallback? onInfo;

  Future<void> _pick(bool start) async {
    final now = start ? settings.quietStartMin : settings.quietEndMin;
    final got = await onPickTime?.call(now);
    if (got == null) return;
    onChanged(start ? settings.copyWith(quietStartMin: got) : settings.copyWith(quietEndMin: got));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = settings;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4);
    Widget choice(String title, int value, List<int> values, ConfirmSettings Function(int) set) => Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.bodyLarge?.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: [for (final v in values) ButtonSegment(value: v, label: Text('$v'))],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: s.on ? (x) => onChanged(set(x.first)) : null,
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Quick checks', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
        actions: [
          IconButton(onPressed: onInfo, icon: const Icon(Icons.info_outline), tooltip: 'Why the app asks', color: Night.inkMuted),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            'Soon after the app thinks you slept or walked, it asks: "Did you walk 19:08-21:14?" Yes, No or Not sure, '
            'one tap. Until you answer, it is only the app\'s guess.',
            style: text.bodyLarge?.copyWith(height: 1.45),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.only(top: 12),
            title: const Text('Ask me'),
            subtitle: Text(s.on ? 'A notification and a card in the app' : 'Off: nothing is asked', style: muted),
            value: s.on,
            onChanged: (v) => onChanged(s.copyWith(on: v)),
          ),
          if (s.on && !notificationsOn) ...[
            const SizedBox(height: 8),
            Text('Notifications are off for the app or for these questions: only the card in the app asks.', style: muted?.copyWith(color: Night.caution)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: onNotificationSettings, child: const Text('Notification settings')),
            ),
          ],
          choice('Questions at a time, at most', s.perBatch, const [3, 4, 5], (v) => s.copyWith(perBatch: v)),
          choice('Notifications a day, at most', s.perDay, const [1, 2, 3, 4, 6], (v) => s.copyWith(perDay: v)),
          const SizedBox(height: 20),
          Text('Quiet hours', style: text.bodyLarge?.copyWith(height: 1.4)),
          const SizedBox(height: 4),
          Text('No notification between these times; it comes when they end. The card in the app is always there.', style: muted),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: s.on ? () => _pick(true) : null, child: Text('From ${_clock(s.quietStartMin)}'))),
              const SizedBox(width: 12),
              Expanded(child: OutlinedButton(onPressed: s.on ? () => _pick(false) : null, child: Text('To ${_clock(s.quietEndMin)}'))),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Also never while a recording runs with the screen off: you may be asleep. It waits until you use the phone.',
            style: muted,
          ),
        ],
      ),
    );
  }
}
