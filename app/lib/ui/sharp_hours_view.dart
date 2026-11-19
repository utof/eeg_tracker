// The sharp-hours page's layout (.impeccable/surfaces/app-lib-ui-sharp-hours-screen-dart.md): the proposal and its
// switch first, the waking window and the count, whether the questions arrive, the collection ledger toward the
// first pattern, the answers by the hour, today, and your data. Built from a SharpPageModel only, so tests render it
// without a phone.
import 'package:flutter/material.dart';

import '../sharp/hours.dart';
import '../sharp/page.dart';
import '../sharp/schedule.dart';
import '../sharp/store.dart';
import 'form_parts.dart' show Para, PinnedAction;
import 'parts.dart';
import 'sharp_chart.dart';
import 'theme.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const String _howWords = 'Never in the quiet hours, during a night recording or during a session. Each question comes '
    'at a random minute; two a day suggest the 1-minute reaction test.';

/// "10:00 to 22:00".
String windowWords(SharpSettings s) => '${clockText(s.fromMin)} to ${clockText(s.untilMin)}';

/// The switch row's status line.
String sharpStatus(SharpPageModel m) => m.on
    ? 'On: ${m.settings.perDay} a day at random moments, ${windowWords(m.settings)}.'
    : (m.saved ? 'Off. Nothing is asked; your answers so far are kept.' : 'Off. Nothing is asked until you switch it on.');

/// Whether the questions reach you, in one sentence; null when there is nothing to say yet.
String? reachWords(SharpPageModel m) {
  final r = m.reach;
  if (!m.on || r.planned == 0) return null;
  if (r.heldBack) {
    return 'Only ${r.arrived} of ${r.planned} questions reached you in the last 7 days. The phone is probably '
        'holding them back: let EEG Tracker start by itself and run without battery limits.';
  }
  final skipped = r.skipped > 0 ? ' ${r.skipped} came during a recording or a session and were skipped.' : '';
  return 'Last 7 days: ${r.arrived} of ${r.planned} questions arrived and you answered ${r.answered}.$skipped';
}

/// The axis chips' words.
String axisName(SharpAxis a) => switch (a) {
  SharpAxis.clock => 'Clock',
  SharpAxis.sinceWake => 'Since waking',
  SharpAxis.pressure => 'Sleep pressure',
};

/// What one axis groups by, and what it could not place.
String axisNote(SharpAxis a, int left) {
  final base = switch (a) {
    SharpAxis.clock => 'By the time of day, 2 hours to a column.',
    SharpAxis.sinceWake => 'By hours since you woke, from your recorded nights, 2 hours to a column.',
    SharpAxis.pressure => 'By the sleep-pressure estimate from your sleep times: 0 just after a regular night, 100 at a '
        'regular bedtime.',
  };
  if (left == 0 || a == SharpAxis.clock) return base;
  final why = a == SharpAxis.sinceWake ? 'no recorded wake-up in the 24 hours before' : 'no estimate at that time';
  return '$base ${left == 1 ? '1 answer has' : '$left answers have'} $why, so ${left == 1 ? 'it is' : 'they are'} not here.';
}

/// The sentence under the ratings chart.
String ratingWords(SharpPageModel m, SharpAxis a) {
  if (!m.gate.open) {
    return 'Dots only for now: no pattern before 3 weeks and about ${SharpGate.ratings} answers, because a few days '
        'can look like a pattern by chance.';
  }
  final b = m.ratings[a]!.profile?.best;
  return b != null
      ? bestWords(a, b, fromMin: m.settings.fromMin, untilMin: m.settings.untilMin)
      : 'No clear best time yet: your hours look alike so far, or the differences are still within chance.';
}

/// The sentence under the reaction chart; null with no test at all.
String? reactionWords(SharpPageModel m, SharpAxis a) {
  final v = m.reactions[a]!;
  if (m.gate.tests == 0) return null;
  if (!m.gate.testsOpen) {
    return 'Dots only until 3 weeks and ${SharpGate.tests} tests: ${m.gate.tests} so far.';
  }
  final b = v.profile?.best;
  return b != null
      ? bestWords(a, b, reaction: true, fromMin: m.settings.fromMin, untilMin: m.settings.untilMin)
      : 'No clearly quicker time yet.';
}

class SharpHoursView extends StatelessWidget {
  const SharpHoursView({
    super.key,
    required this.model,
    required this.axis,
    this.onAxis,
    this.onToggle,
    this.onWindow,
    this.onPerDay,
    this.onRate,
    this.onInfo,
    this.onNotifications,
    this.onPhoneSettings,
    this.onSound,
    this.onDelete,
    this.error,
  });

  final SharpPageModel model;
  final SharpAxis axis;
  final ValueChanged<SharpAxis>? onAxis;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onWindow, onRate, onInfo, onNotifications, onSound, onDelete;
  final ValueChanged<int>? onPerDay;

  /// Opens a phone setting by the name Phone.openSettings knows (`xiaomiAutostart`, `batteryOptimization`...).
  final ValueChanged<String>? onPhoneSettings;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final m = model;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.45);
    final reach = reachWords(m);
    final rv = m.ratings[axis]!, tv = m.reactions[axis]!;
    final blocks = chartBlocks(axis, [...rv.points, ...tv.points], fromMin: m.settings.fromMin, untilMin: m.settings.untilMin);
    final rWords = reactionWords(m, axis);
    return Scaffold(
      appBar: AppBar(
        title: Text('Sharp hours', style: text.titleMedium?.copyWith(color: Night.ink)),
        actions: [
          IconButton(onPressed: onInfo, tooltip: 'What the research says', icon: const Icon(Icons.info_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Text(
            'The assistant\'s idea, not one you asked for: a few one-tap questions a day, to learn when you are '
            'sharpest. Off unless you switch it on; you can delete it all at the bottom.',
            style: muted,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: m.on,
            onChanged: onToggle,
            contentPadding: EdgeInsets.zero,
            title: Text('Questions during the day', style: text.titleLarge),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(sharpStatus(m), style: text.bodyLarge?.copyWith(color: m.on ? Night.live : Night.inkMuted, height: 1.4)),
            ),
          ),
          if (error != null) Para(error!, color: Night.problem),
          if (m.on && !m.notificationsOn)
            WarningLine(
              words: 'Notifications are off for this app, so the questions cannot appear.',
              actions: [TextButton(onPressed: onNotifications, child: const Text('Notification settings'))],
            ),
          const SizedBox(height: 8),
          LogRow(
            label: 'Awake',
            value: windowWords(m.settings),
            action: TextButton(onPressed: onWindow, child: const Text('Change')),
          ),
          LogRow(
            label: 'A day',
            value: '',
            action: SegmentedButton<int>(
              segments: [
                for (final n in SharpRule.perDayChoices) ButtonSegment(value: n, label: Text('$n', style: const TextStyle(fontFeatures: tabular))),
              ],
              selected: {m.settings.perDay},
              showSelectedIcon: false,
              onSelectionChanged: onPerDay == null ? null : (s) => onPerDay!(s.first),
              // the app's segmented rows (form_parts.dart): selected = surface-high with ink, never a state colour
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
              ),
            ),
          ),
          if (!m.on) ...[const SizedBox(height: 6), Text(_howWords, style: muted)],
          if (reach != null)
            m.reach.heldBack
                ? WarningLine(
                    words: reach,
                    actions: [
                      if (m.xiaomi) TextButton(onPressed: () => onPhoneSettings?.call('xiaomiAutostart'), child: const Text('Autostart')),
                      TextButton(
                        onPressed: () => onPhoneSettings?.call(m.xiaomi ? 'xiaomiBatterySaver' : 'batteryOptimization'),
                        child: const Text('Battery'),
                      ),
                    ],
                  )
                : Para(reach, color: Night.inkMuted),
          SectionHeading(m.gate.open ? 'What you have' : 'Collecting'),
          Text(
            m.gate.open || m.gate.ratings == 0 ? m.gate.words : m.gate.counts,
            style: text.titleLarge?.copyWith(fontFeatures: tabular, height: 1.3),
          ),
          if (!m.gate.open) ...[
            const SizedBox(height: 16),
            _Ledger(label: 'Answers', filled: m.gate.ratings, of: SharpGate.ratings, perRow: 20),
            const SizedBox(height: 12),
            _Ledger(label: 'Days', filled: m.gate.day, of: SharpGate.days, perRow: 21),
            const SizedBox(height: 12),
            Text(
              'The first pattern shows when both rows are full: after 3 weeks and about ${SharpGate.ratings} answers.',
              style: muted,
            ),
          ],
          if (m.on) ...[const SizedBox(height: 12), Text(_howWords, style: muted)],
          const SectionHeading('By the hour'),
          // the app's segmented rows (form_parts.dart); a long label wraps inside its own segment at large text
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<SharpAxis>(
              segments: [
                for (final a in SharpAxis.values)
                  ButtonSegment(value: a, label: Text(axisName(a), textAlign: TextAlign.center, maxLines: 2)),
              ],
              selected: {axis},
              showSelectedIcon: false,
              onSelectionChanged: onAxis == null ? null : (s) => onAxis!(s.first),
              style: SegmentedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                selectedBackgroundColor: Night.surfaceHigh,
                selectedForegroundColor: Night.ink,
                foregroundColor: Night.inkMuted,
                side: const BorderSide(color: Night.rule),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(axisNote(axis, rv.left), style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
          const SizedBox(height: 16),
          Text('How sharp', style: text.titleSmall),
          const SizedBox(height: 8),
          SharpChart(
            axis: axis,
            points: rv.points,
            blocks: blocks,
            profile: rv.profile,
            fromMin: m.settings.fromMin,
            untilMin: m.settings.untilMin,
            label: 'How sharp, ${axisName(axis).toLowerCase()}: ${rv.points.length} answers. ${ratingWords(m, axis)}',
          ),
          const SizedBox(height: 12),
          Text(ratingWords(m, axis), style: text.bodyLarge?.copyWith(height: 1.45)),
          const SizedBox(height: 20),
          Text('Reaction time', style: text.titleSmall),
          const SizedBox(height: 8),
          if (tv.points.isEmpty)
            Text(
              rWords == null
                  ? 'No reaction tests yet. Two of the day\'s questions suggest one; it takes a minute.'
                  : 'No test to show here.',
              style: muted,
            )
          else ...[
            SharpChart(
              axis: axis,
              points: tv.points,
              blocks: blocks,
              profile: tv.profile,
              reaction: true,
              fromMin: m.settings.fromMin,
              untilMin: m.settings.untilMin,
              label: 'Reaction time, ${axisName(axis).toLowerCase()}: ${tv.points.length} tests. ${rWords ?? ''}',
            ),
            if (rWords != null) ...[const SizedBox(height: 12), Text(rWords, style: text.bodyLarge?.copyWith(height: 1.45))],
          ],
          const SizedBox(height: 16),
          Text(
            'Seen together, not tested: what you do at those hours (meetings, meals, coffee) shapes this too.',
            style: muted,
          ),
          const SectionHeading('Today'),
          if (m.today.isEmpty)
            Text('No answers today yet.', style: muted)
          else
            for (final (i, r) in m.today.indexed) ...[
              if (i > 0) const Divider(height: 17),
              _TodayRow(rating: r, test: m.todayTests.where((t) => t.ratingAt == r.at).firstOrNull),
            ],
          const SectionHeading('Your data'),
          Text(
            'Kept in the app\'s private folder and copied out by Export data, with everything else. Nothing leaves the '
            'phone otherwise.',
            style: muted,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: onSound, icon: const Icon(Icons.notifications_outlined), label: const Text('Sound of the questions')),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: onDelete, icon: const Icon(Icons.delete_outline), label: const Text('Delete my sharp-hours data')),
          ),
        ],
      ),
      bottomNavigationBar: PinnedAction(
        child: FilledButton(onPressed: onRate, child: const Text('Rate now')),
      ),
    );
  }
}

/// Label left, value right, then the row's own control (DESIGN.md log rows).
class LogRow extends StatelessWidget {
  const LogRow({super.key, required this.label, required this.value, required this.action});
  final String label, value;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(value, textAlign: TextAlign.right, style: text.titleMedium?.copyWith(fontFeatures: tabular)),
          ),
          const SizedBox(width: 8),
          action,
        ],
      ),
    );
  }
}

/// An amber line with its icon and the buttons that fix it (DESIGN.md: never colour alone).
class WarningLine extends StatelessWidget {
  const WarningLine({super.key, required this.words, required this.actions});
  final String words;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.warning_amber_rounded, color: Night.caution, size: 22)),
              const SizedBox(width: 10),
              Expanded(child: Text(words, style: text.bodyLarge?.copyWith(color: Night.caution, height: 1.45))),
            ],
          ),
          if (actions.isNotEmpty) Wrap(alignment: WrapAlignment.end, spacing: 4, children: actions),
        ],
      ),
    );
  }
}

/// The collection ledger: the watch strip's own cells, filled `saved` for each answer or day so far.
class _Ledger extends StatelessWidget {
  const _Ledger({required this.label, required this.filled, required this.of, required this.perRow});
  final String label;
  final int filled, of, perRow;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final n = filled.clamp(0, of);
    final rows = (of / perRow).ceil();
    return Semantics(
      label: '$label: $filled of $of',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
              const Spacer(),
              Text(
                filled > of ? '$filled' : '$filled of $of',
                style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var r = 0; r < rows; r++) ...[
            if (r > 0) const SizedBox(height: 3),
            Row(
              children: [
                for (var c = 0; c < perRow; c++) ...[
                  if (c > 0) SizedBox(width: c % 5 == 0 ? 5 : 2),
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: r * perRow + c < n ? Night.saved : Night.track,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One answer of today: the time, the rating in words, and its reaction test.
class _TodayRow extends StatelessWidget {
  const _TodayRow({required this.rating, this.test});
  final SharpRating rating;
  final SharpReaction? test;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final t = test;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(width: 64, child: Text(_clock(rating.at), style: text.titleMedium?.copyWith(fontFeatures: tabular))),
        Expanded(
          child: Text(
            '${rating.sharp} · ${sharpWords[rating.sharp - 1]}${rating.prompted ? '' : ' (from the page)'}',
            style: text.bodyLarge,
          ),
        ),
        if (t != null)
          Text(
            t.medianMs == null ? 'test: too few taps' : '${t.medianMs} ms',
            style: text.bodyLarge?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
          ),
      ],
    );
  }
}
