// The Archive's list (DECISIONS 700-709; DESIGN.md "Archive"): what the phone keeps, as a deck log by day. At the top the
// storage bar (the space each kind of recording takes; a segment shows only that kind), then one ruled log row per
// recording, newest first, under its day: its clock span and length, its kind and who started it, your tags and what was
// found in it, and where it is (this phone, the laptop). Rendered from a plain model, so tests need no phone.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../archive/bands.dart' show durationWords, foundWords, noSignalWords;
import '../archive/items.dart';
import '../archive/page.dart';
import '../archive/raw_remover.dart' show OnLaptop;
import '../export/store.dart' show sizeText;
import '../recorder/nights.dart' show nightLabel;
import '../trends/days.dart' show dayNoon;
import 'form_parts.dart' show Para;
import 'theme.dart';

/// The storage bar's groups of kinds.
enum KindGroup {
  nights('Nights'),
  sessions('Sessions'),
  work('Work'),
  checkIns('Check-ins'),
  other('Other');

  const KindGroup(this.word);
  final String word;

  static KindGroup of(ArchiveKind k) => switch (k) {
    ArchiveKind.night || ArchiveKind.board => nights,
    ArchiveKind.work => work,
    ArchiveKind.checkIn => checkIns,
    ArchiveKind.recording => other,
    _ => sessions,
  };
}

/// The bar's tones, one step apart (DESIGN.md: never colour alone; the legend under it names each).
const Map<KindGroup, Color> kindTones = {
  KindGroup.nights: Night.saved,
  KindGroup.sessions: Night.ink,
  KindGroup.work: Night.inkMuted,
  KindGroup.checkIns: Color(0xFF5E5446),
  KindGroup.other: Night.rule,
};

class ArchiveViewModel {
  const ArchiveViewModel({this.page, this.loading = false, this.error, this.filter, this.seeing, this.passing = false});

  final ArchivePage? page;
  final bool loading;
  final String? error;

  /// Only this group is shown (a tap on its segment); null: all.
  final KindGroup? filter;

  /// The recording whose detectors' pass runs now.
  final String? seeing;

  /// Passes run while the page is open (false: they wait for a night or a session to end).
  final bool passing;
}

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// `23:12 – 07:40`.
String spanText(DateTime a, DateTime b) => '${hm(a)} – ${hm(b)}';

/// The length in words: `8 h 28`, `14 min`, `under a minute`.
String lengthText(Duration d) => d.inSeconds < 60 ? 'under a minute' : durationWords(d);

/// `9 KB` under a megabyte, else Export data's words (`2.4 MB`, `410 MB`, `3.1 GB`).
String sizeWords(int bytes) => bytes < 1e6 ? '${math.max(1, (bytes / 1e3).round())}\u00a0KB' : sizeText(bytes);

/// Where an item is, in words: on the phone (and the laptop's word), or what is left once its raw signal went.
String whereText(ArchiveItem i) {
  final size = sizeWords(i.bytes);
  if (i.rawRemoved) {
    return i.removedToLaptop
        ? 'Raw recording on the laptop; $size of results here'
        : 'Raw recording deleted; $size of results here';
  }
  if (!i.hasRaw) return '$size on the phone';
  return switch (i.laptop) {
    OnLaptop.yes => '$size on the phone · checked copy on the laptop',
    OnLaptop.no || OnLaptop.unknown => '$size · only on this phone',
  };
}

/// The day heading's words: `Wed 18 Nov`, or Today / Yesterday.
String dayTitle(String key, DateTime now) {
  final d = dayNoon(key);
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == -1) return 'Yesterday';
  return nightLabel(d);
}

class ArchiveView extends StatelessWidget {
  const ArchiveView({
    super.key,
    required this.model,
    required this.now,
    this.onOpen,
    this.onFilter,
    this.onDay,
    this.storageBar,
    this.onStorage,
  });

  final ArchiveViewModel model;
  final DateTime now;
  final ValueChanged<ArchiveItem>? onOpen;
  final ValueChanged<KindGroup?>? onFilter;

  /// The day's menu: remove its raw recordings the laptop holds, or delete it (the Danger zone).
  final void Function(String day, List<ArchiveItem> items, bool danger)? onDay;

  /// The storage page's own bar (the move-off-phone lane's widget, by category), when the app has it; null: the
  /// Archive's bar by kind of recording.
  final Widget? storageBar;

  /// Opens the Storage page (the move-off-phone lane's); null: not in this build.
  final VoidCallback? onStorage;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final page = model.page;
    final items = page?.list.items ?? const <ArchiveItem>[];
    final shown = model.filter == null ? items : [for (final i in items) if (KindGroup.of(i.kind) == model.filter) i];
    final days = ArchiveList(shown).days;
    return Scaffold(
      appBar: AppBar(title: Text('Archive', style: text.titleMedium?.copyWith(color: Night.ink))),
      body: ListView(
        key: const PageStorageKey('archive'),
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        children: [
          if (model.loading && page == null)
            const Para('Reading what the phone keeps…', color: Night.inkMuted, top: 8)
          else if (model.error != null && page == null)
            Para('The list could not be read: ${model.error}', color: Night.caution, top: 8)
          else if (items.isEmpty)
            const Para(
              'Nothing recorded on this phone yet. Nights, sessions and check-ins appear here as soon as they are recorded.',
              color: Night.inkMuted,
              top: 8,
            )
          else ...[
            storageBar ?? KindBar(items: items, filter: model.filter, onFilter: onFilter),
            if (onStorage != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onStorage, child: const Text('Storage')),
              ),
            const SizedBox(height: 8),
            Text(_summary(page!, model), style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
            if (model.filter != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => onFilter?.call(null),
                  icon: const Icon(Icons.close, size: 18),
                  label: Text('Showing ${model.filter!.word.toLowerCase()} only · Show all'),
                ),
              ),
            for (final (day, list) in days) ...[
              _DayHeading(
                title: dayTitle(day, now),
                items: list,
                onRemove: onDay == null ? null : () => onDay!(day, list, false),
                onDelete: onDay == null ? null : () => onDay!(day, list, true),
              ),
              for (var k = 0; k < list.length; k++) ...[
                if (k > 0) const Divider(height: 1),
                ArchiveRow(
                  item: list[k],
                  found: page.found[list[k].id],
                  why: page.why[list[k].id],
                  seeing: model.seeing == list[k].id,
                  waiting: page.toSee.contains(list[k].id),
                  onTap: onOpen == null ? null : () => onOpen!(list[k]),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  static String _summary(ArchivePage p, ArchiveViewModel m) {
    final n = p.list.items.length;
    final left = p.toSee.length;
    final head = '${n == 1 ? '1 recording' : '$n recordings'}, ${sizeWords(p.list.bytes)} on this phone, newest first.';
    if (left == 0) return head;
    final when = m.passing
        ? 'Finding activity in ${left == 1 ? '1 more recording' : '$left more recordings'} while this page is open.'
        : 'Finding activity waits while a night or a session records (${left == 1 ? '1 recording' : '$left recordings'} to go).';
    return '$head $when';
  }
}

/// The storage bar by kind of recording: one 12 dp bar split by the space each kind takes, the legend under it as
/// rows (tone, word, size); a tap shows only that kind.
class KindBar extends StatelessWidget {
  const KindBar({super.key, required this.items, this.filter, this.onFilter});
  final List<ArchiveItem> items;
  final KindGroup? filter;
  final ValueChanged<KindGroup?>? onFilter;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bytes = <KindGroup, int>{};
    for (final i in items) {
      final g = KindGroup.of(i.kind);
      bytes[g] = (bytes[g] ?? 0) + i.bytes;
    }
    final total = bytes.values.fold(0, (a, b) => a + b);
    final groups = [for (final g in KindGroup.values) if ((bytes[g] ?? 0) > 0) g];
    void tap(KindGroup g) => onFilter?.call(filter == g ? null : g);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Space on this phone by kind: ${[for (final g in groups) '${g.word} ${sizeWords(bytes[g]!)}'].join(', ')}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  if (total > 0)
                    for (final (k, g) in groups.indexed)
                      Expanded(
                        flex: (bytes[g]! * 1000 ~/ total).clamp(1, 1000),
                        child: GestureDetector(
                          onTap: () => tap(g),
                          child: Container(
                            margin: EdgeInsets.only(right: k < groups.length - 1 ? 2 : 0),
                            color: filter == null || filter == g ? kindTones[g] : kindTones[g]!.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 4,
          runSpacing: 0,
          children: [
            for (final g in groups)
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => tap(g),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(color: kindTones[g], borderRadius: BorderRadius.circular(3)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${g.word} ${sizeWords(bytes[g]!)}',
                          style: text.bodyMedium?.copyWith(
                            color: filter == null || filter == g ? Night.ink : Night.inkMuted,
                            fontWeight: filter == g ? FontWeight.w600 : null,
                            fontFeatures: tabular,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.title, required this.items, this.onRemove, this.onDelete});
  final String title;
  final List<ArchiveItem> items;
  final VoidCallback? onRemove, onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bytes = items.fold(0, (n, i) => n + i.bytes);
    final removable = items.any((i) => i.hasRaw && i.laptop == OnLaptop.yes);
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
                ),
              ),
              Text(
                '${items.length} · ${sizeWords(bytes)}',
                style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
              ),
              if (onRemove != null || onDelete != null)
                PopupMenuButton<bool>(
                  tooltip: 'Options for $title',
                  icon: const Icon(Icons.more_vert, color: Night.inkMuted),
                  color: Night.surfaceHigh,
                  onSelected: (danger) => (danger ? onDelete : onRemove)?.call(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: false,
                      enabled: removable && onRemove != null,
                      child: const Text('Remove what the laptop holds'),
                    ),
                    PopupMenuItem(
                      value: true,
                      enabled: onDelete != null,
                      child: Text('Delete this day…', style: TextStyle(color: onDelete == null ? null : Night.problem)),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One recording as a ruled log row.
class ArchiveRow extends StatelessWidget {
  const ArchiveRow({
    super.key,
    required this.item,
    this.found,
    this.why,
    this.seeing = false,
    this.waiting = false,
    this.onTap,
  });
  final ArchiveItem item;
  final Map<String, double>? found;
  final String? why;
  final bool seeing, waiting;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final i = item;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final tags = [?i.kind.tag, for (final t in i.manualTags) t.label];
    final seenWords = [
      ...foundWords(asleepMin: i.report?.asleepMin, minutes: found),
      ?noSignalWords(found),
    ];
    final foundLine = seeing
        ? 'Finding activity in it now…'
        : seenWords.isNotEmpty
        ? 'Found: ${seenWords.join(' · ')}'
        : waiting
        ? 'Activity not read yet'
        : why != null
        ? 'No activity tags: ${why!.contains('O1 O2 T3 T4') ? 'they need O1 O2 T3 T4, which this layout lacks.' : why!}'
        : found != null
        ? 'Found: nothing that stands out'
        : null;
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(spanText(i.start, i.end), style: text.titleMedium?.copyWith(fontFeatures: tabular)),
                        ),
                        Text(lengthText(i.length), style: text.titleMedium?.copyWith(fontFeatures: tabular)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${i.kind.word} · ${i.started.words}', style: text.bodyLarge?.copyWith(height: 1.35)),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('Tags: ${tags.join(' · ')}', style: text.bodyMedium?.copyWith(color: Night.ink, height: 1.35)),
                    ],
                    if (foundLine != null) ...[const SizedBox(height: 2), Text(foundLine, style: muted)],
                    const SizedBox(height: 2),
                    Text(whereText(i), style: muted?.copyWith(fontFeatures: tabular)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Night.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// The More tab's entry (night_view.dart): one sentence and the button.
class ArchiveEntry extends StatelessWidget {
  const ArchiveEntry({super.key, required this.onOpen});
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Para(
        'Every recording on this phone by day: how it started, what was found in it, your tags. Open one to see its '
        'timeline and signal, or to delete it.',
        color: Night.inkMuted,
        top: 0,
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(onPressed: onOpen, icon: const Icon(Icons.inventory_2_outlined), label: const Text('Open the archive')),
    ],
  );
}
