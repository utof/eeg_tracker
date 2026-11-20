// One recording of the Archive (DECISIONS 700-709; DESIGN.md "Archive"): what it is and who started it, its timeline of
// activity lanes, what was found (a row per lane, opening its stretches), your tags, its files and where they are, then
// Remove from this phone (with the laptop's checked copy) and the Danger zone. Rendered from a plain model.
import 'package:flutter/material.dart';

import '../archive/bands.dart';
import '../archive/items.dart';
import '../archive/raw_remover.dart' show OnLaptop;
import '../archive/tags.dart';
import '../logs/own_text.dart';
import '../recorder/nights.dart' show nightLabel;
import 'archive_timeline.dart';
import 'archive_view.dart' show sizeWords, lengthText, spanText;
import 'form_parts.dart' show Para;
import 'parts.dart';
import 'theme.dart';

class RecordingViewModel {
  const RecordingViewModel({required this.item, this.timeline, this.passRunning = false, this.passWhy, this.loading = false});
  final ArchiveItem item;

  /// Null while its files are read.
  final Timeline? timeline;
  final bool loading;

  /// The detectors' pass runs now.
  final bool passRunning;

  /// Why there are no activity tags from the signal (its layout, its rate, no raw signal left).
  final String? passWhy;
}

/// Where its raw recording is, in words.
String laptopWords(ArchiveItem i) {
  if (i.rawRemoved) return i.removedToLaptop ? 'Raw recording moved there' : 'Raw recording deleted';
  if (!i.hasRaw) return 'Nothing raw to copy';
  return switch (i.laptop) {
    OnLaptop.yes => 'Checked copy of the raw recording',
    OnLaptop.no => 'Not checked there yet',
    OnLaptop.unknown => 'No word from a laptop',
  };
}

/// How good the activity tags are, in plain words (docs/detectors.md; DECISIONS 700-709).
const String howGood =
    'Found by the app, with planning values nobody has checked against what you were doing: asleep comes from the sleep '
    'report (a model not yet validated on this headband); eyes closed and drowsy are read against this recording\'s own '
    'first minutes, so they work best when it starts awake with eyes open; talking is jaw muscle, so chewing counts too; '
    'moving is three electrodes jumping at once. Your tags are the check: tag what you did.';

class RecordingView extends StatelessWidget {
  const RecordingView({
    super.key,
    required this.model,
    this.onBand,
    this.onTime,
    this.onLane,
    this.onAddTag,
    this.onTag,
    this.onRemove,
    this.onDanger,
    this.onSignal,
  });

  final RecordingViewModel model;
  final ValueChanged<Band>? onBand;
  final ValueChanged<DateTime>? onTime;
  final ValueChanged<Lane>? onLane;
  final VoidCallback? onAddTag;
  final ValueChanged<ManualTag>? onTag;

  /// Remove from this phone: only offered with the laptop's checked copy.
  final VoidCallback? onRemove;
  final VoidCallback? onDanger;

  /// The raw signal from the recording's start.
  final VoidCallback? onSignal;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final m = model;
    final i = m.item;
    final tl = m.timeline;
    final names = {for (final s in i.sets) if (s.names.isNotEmpty) s.names.join(' ')};
    final devices = {for (final s in i.sets) ?s.device};
    return Scaffold(
      appBar: AppBar(title: Text('${i.kind.word}, ${nightLabel(i.start)}', style: text.titleMedium?.copyWith(color: Night.ink))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          Readout(parts: _lengthParts(i.length), label: '${spanText(i.start, i.end)}, ${nightLabel(i.start)}'),
          const SizedBox(height: 16),
          _Row('Started', i.started.words),
          if (i.kind.tag != null) _Row('Its tag', '${i.kind.tag} (${i.started.byYou ? 'yours' : 'the watcher\'s guess'})'),
          if (names.isNotEmpty) _Row('Channels', [...names, if (devices.isNotEmpty) devices.join(', ')].join(' · ')),
          _Row('On this phone', sizeWords(i.bytes)),
          _Row('Laptop', laptopWords(i)),
          if (i.copied != null)
            _Row(
              'Export data',
              '${i.copied!.all ? 'Copied' : 'Partly copied'}${i.copied!.at == null ? '' : ' ${nightLabel(i.copied!.at!)}'}',
            ),
          const SectionHeading('Timeline'),
          if (tl == null)
            const Para('Reading the recording…', color: Night.inkMuted, top: 0)
          else ...[
            Text(
              'Tap a band to see it, anywhere else to see the signal at that moment. Two fingers or the buttons zoom.',
              style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35),
            ),
            const SizedBox(height: 8),
            TimelineView(timeline: tl, onBand: onBand, onTime: i.hasRaw ? onTime : null),
            const SizedBox(height: 8),
            Text(_passLine(m), style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35)),
            if (i.hasRaw && onSignal != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: onSignal, icon: const Icon(Icons.ssid_chart), label: const Text('The signal from the start')),
              ),
            ],
          ],
          const SectionHeading('Found'),
          if (tl != null)
            for (final l in Lane.values.where((l) => l != Lane.tags))
              _LaneRow(
                lane: l,
                value: tl.of(l).isEmpty ? 'none' : lengthText(tl.total(l)),
                onTap: onLane == null ? null : () => onLane!(l),
              ),
          const Para(howGood, color: Night.inkMuted),
          const SectionHeading('Your tags'),
          if (i.manualTags.isEmpty)
            const Para('None yet. Tag what you were doing: sleep, work, a walk, a meeting.', color: Night.inkMuted, top: 0)
          else
            for (final t in i.manualTags)
              InkWell(
                onTap: onTag == null ? null : () => onTag!(t),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Row(
                    children: [
                      Expanded(child: OwnText(child: Text(t.label, style: text.bodyLarge))),
                      if (t.truth) ...[
                        const Icon(
                          Icons.check_circle_outline,
                          size: 20,
                          color: Night.inkMuted,
                          semanticLabel: 'what I was doing',
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(spanText(t.start, t.end), style: text.titleMedium?.copyWith(fontFeatures: tabular)),
                      const SizedBox(width: 8),
                      const Icon(Icons.edit_outlined, size: 20, color: Night.inkMuted),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(onPressed: onAddTag, icon: const Icon(Icons.sell_outlined), label: const Text('Add a tag')),
          ),
          const SectionHeading('Files'),
          ..._files(i),
          if (onRemove != null) ...[
            const SectionHeading('On the laptop'),
            Para(
              'The laptop holds a checked copy of the raw recording (${sizeWords(i.rawBytes)}). Removing it from this '
              'phone keeps every statistic here.',
              color: Night.inkMuted,
              top: 0,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onRemove,
                icon: const Icon(Icons.phonelink_erase_outlined),
                label: const Text('Remove from this phone'),
              ),
            ),
          ],
          const _DangerHeading(),
          Para(
            i.hasRaw && i.laptop != OnLaptop.yes
                ? 'Delete it from this phone although it is the only copy: the raw recording only, or everything with '
                      'its statistics. Asks twice.'
                : 'Delete what is left of it, with its statistics, or its raw recording. Asks twice.',
            color: Night.inkMuted,
            top: 0,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Night.problem, side: const BorderSide(color: Night.problem)),
              onPressed: onDanger,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete…'),
            ),
          ),
        ],
      ),
    );
  }

  static List<(String, bool)> _lengthParts(Duration d) {
    final m = (d.inSeconds / 60).round();
    if (m < 60) return [('$m', true), (' min', false)];
    return [('${m ~/ 60}', true), (' h ', false), ((m % 60).toString().padLeft(2, '0'), true), (' min', false)];
  }

  static String _passLine(RecordingViewModel m) {
    if (m.passRunning) return 'Finding activity in the signal: a night takes about a minute. The other lanes are ready.';
    if (m.passWhy != null) return 'No activity from the signal: ${m.passWhy}';
    return m.item.hasRaw ? 'Activity from the signal: done; kept until the recording changes.' : 'No raw signal on the phone.';
  }

  static List<Widget> _files(ArchiveItem i) {
    final live = i.sets.where((s) => !s.removed).length, gone = i.sets.length - live;
    return [
      if (i.sets.isNotEmpty)
        _Row(
          'Raw recording',
          [
            if (live > 0) '${live == 1 ? '1 file set' : '$live file sets'}, ${sizeWords(i.rawBytes)}',
            if (gone > 0) '${gone == 1 ? '1 set' : '$gone sets'} removed',
          ].join('; '),
        ),
      if (i.report != null) _Row('Sleep report', 'Night of ${i.report!.nightOf}'),
      for (final s in i.sessions)
        _Row(s.kind.word, s.companions.isEmpty ? sizeWords(s.bytes) : '${1 + s.companions.length} files, ${sizeWords(s.bytes)}'),
      if (i.tags != null) _Row('Your tags', i.manualTags.length == 1 ? '1 tag' : '${i.manualTags.length} tags'),
    ];
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(value, textAlign: TextAlign.end, style: text.bodyLarge?.copyWith(fontFeatures: tabular)),
          ),
        ],
      ),
    );
  }
}

class _LaneRow extends StatelessWidget {
  const _LaneRow({required this.lane, required this.value, this.onTap});
  final Lane lane;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Expanded(child: Text(_found[lane] ?? lane.word, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
            Text(value, style: text.titleMedium?.copyWith(fontFeatures: tabular, color: value == 'none' ? Night.inkMuted : Night.ink)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Night.inkMuted, size: 20),
          ],
        ),
      ),
    );
  }

  static const Map<Lane, String> _found = {
    Lane.sleep: 'Asleep',
    Lane.talking: 'Talking or chewing',
    Lane.signal: 'No signal or noisy',
    Lane.work: 'Work session',
    Lane.sessions: 'Sessions',
  };
}

/// "Danger zone" under its hairline, in red with its icon (never colour alone).
class _DangerHeading extends StatelessWidget {
  const _DangerHeading();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 32, bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Night.problem, size: 22),
            const SizedBox(width: 10),
            Semantics(
              header: true,
              child: Text(
                'Danger zone',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500, color: Night.problem),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
