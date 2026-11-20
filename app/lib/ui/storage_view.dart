// The Storage page (More, Storage; DECISIONS 690-699), modelled on Telegram's Storage Usage at the owner's word and
// kept inside DESIGN.md (hairlines, label-left / value-right rows, no cards). Top to bottom:
// - the app's space as a readout, the phone's free space in one muted line, the storage bar (storage_bar.dart; a tap
//   opens its category) and what the laptop holds checked copies of;
// - On this phone: the categories with their swatch, size and chevron; each opens to its kinds. What may go has a
//   checkbox; the statistics say "Always kept" and have none;
// - Automatic: per category, how long after the laptop checked a raw recording the phone deletes it (3 days, 1 week,
//   1 month, Never), with the plain promise: only what the laptop has checked, nothing only on this phone;
// - Danger zone (red): what is only on this phone, its own checkboxes, and a button that asks twice;
// - pinned: Clear selected with the size it frees (only what the laptop has checked).
import 'package:flutter/material.dart';

import '../export/store.dart' show sizeText;
import '../storage/clear.dart';
import '../storage/storage.dart';
import 'parts.dart';
import 'storage_bar.dart';
import 'theme.dart';

class StorageViewModel {
  const StorageViewModel({
    this.usage,
    this.space,
    this.settings = const StorageSettings(),
    this.paired = false,
    this.laptop,
    this.selected = const {},
    this.danger = const {},
    this.expanded = const {},
    this.busy,
    this.working = false,
  });

  /// Null while the folders are read.
  final StorageUsage? usage;

  /// The phone's storage, for context; null when unknown.
  final ({int total, int free})? space;
  final StorageSettings settings;
  final bool paired;
  final String? laptop;

  /// Items ticked for Clear selected, and in the Danger zone; categories open.
  final Set<String> selected;
  final Set<String> danger;
  final Set<String> expanded;

  /// Why nothing can be cleared now (a night records, a session runs); null: it can.
  final String? busy;

  /// A clearing runs.
  final bool working;

  int get selectedBytes => selected.fold(0, (n, i) => n + (usage?.clearable[i] ?? 0));
  int get dangerBytes => danger.fold(0, (n, i) => n + (usage?.phoneOnly[i] ?? 0));
  int get dangerCount => danger.fold(0, (n, i) => n + (usage?.phoneOnlyCount[i] ?? 0));
}

/// The sentence the owner asked for, word for word, about what goes by itself.
const String automaticPromise = "Only deletes recordings your laptop has checked. Nothing that's only on this phone.";

class StorageView extends StatelessWidget {
  const StorageView({
    super.key,
    required this.model,
    required this.onSelect,
    required this.onExpand,
    required this.onKeep,
    required this.onClear,
    required this.onDanger,
    required this.onDangerDelete,
    this.onSegment,
    this.rowKeys = const {},
  });

  final StorageViewModel model;
  final void Function(String item, bool on) onSelect;
  final ValueChanged<String> onExpand;
  final void Function(String category, int days) onKeep;
  final VoidCallback onClear;
  final void Function(String item, bool on) onDanger;
  final VoidCallback onDangerDelete;
  final ValueChanged<String>? onSegment;

  /// Keys of the category rows, so a tap on the bar can bring its row into view.
  final Map<String, GlobalKey> rowKeys;

  @override
  Widget build(BuildContext context) {
    final m = model, u = m.usage;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final canClear = u != null && m.busy == null && !m.working && m.selectedBytes > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: u == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                _Overview(usage: u, space: m.space, onSegment: onSegment),
                if (m.busy != null) ...[
                  const SizedBox(height: 12),
                  Text(m.busy!, style: muted?.copyWith(color: Night.caution)),
                ],
                const SectionHeading('On this phone'),
                for (final c in storageCategories)
                  if (u.categoryBytes(c) > 0 || c.id == 'nights')
                    _CategoryRows(
                      key: rowKeys[c.id],
                      category: c,
                      usage: u,
                      selected: m.selected,
                      open: m.expanded.contains(c.id),
                      onSelect: onSelect,
                      onExpand: () => onExpand(c.id),
                    ),
                const SizedBox(height: 12),
                Text(
                  'Clear selected deletes only what your laptop has checked. The statistics always stay: sleep reports, '
                  'check-in results, session summaries, transcripts.',
                  style: muted,
                ),
                const SectionHeading('Automatic'),
                Text(automaticPromise, style: text.bodyLarge?.copyWith(height: 1.4)),
                const SizedBox(height: 6),
                Text(
                  m.paired
                      ? 'A raw recording leaves the phone this long after ${m.laptop ?? 'the laptop'} checked its copy, '
                            'between nights, never while something records.'
                      : 'No laptop is paired, so nothing is checked and nothing leaves the phone by itself. Pair one '
                            'with python3 scripts/phone_link.py.',
                  style: m.paired ? muted : muted?.copyWith(color: Night.caution),
                ),
                for (final c in storageCategories)
                  if (c.keepable) _KeepRow(category: c, days: m.settings.keepDays(c.id), onKeep: onKeep),
                _DangerZone(model: m, onDanger: onDanger, onDelete: onDangerDelete),
              ],
            ),
      bottomNavigationBar: u == null
          ? null
          : SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: FilledButton(
                        onPressed: canClear ? onClear : null,
                        child: Text(
                          m.working
                              ? 'Clearing...'
                              : m.selectedBytes > 0
                              ? 'Clear selected · ${sizeText(m.selectedBytes)}'
                              : 'Clear selected',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.usage, required this.space, this.onSegment});
  final StorageUsage usage;
  final ({int total, int free})? space;
  final ValueChanged<String>? onSegment;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = sizeText(usage.total).split(' ');
    final s = space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Readout(parts: [(total.first, true), (' ${total.last}', false)], label: 'used by EEG Tracker on this phone'),
        if (s != null) ...[
          const SizedBox(height: 4),
          Text(
            '${sizeText(s.free)} free of ${sizeText(s.total)}',
            style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
          ),
        ],
        const SizedBox(height: 18),
        StorageBar(segments: storageSegments(usage), onTap: onSegment),
        const SizedBox(height: 12),
        _ValueRow(label: 'On the laptop, checked', value: sizeText(usage.onLaptop), last: true),
      ],
    );
  }
}

/// Label left, value right in tabular figures, on a hairline.
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value, this.last = false});
  final String label, value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
      child: Row(
        children: [
          Expanded(child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
          const SizedBox(width: 16),
          Text(value, style: text.bodyLarge?.copyWith(fontFeatures: tabular)),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
  );
}

/// A category's row and, open, its kinds.
class _CategoryRows extends StatelessWidget {
  const _CategoryRows({
    super.key,
    required this.category,
    required this.usage,
    required this.selected,
    required this.open,
    required this.onSelect,
    required this.onExpand,
  });

  final StorageCategory category;
  final StorageUsage usage;
  final Set<String> selected;
  final bool open;
  final void Function(String item, bool on) onSelect;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = category;
    final goes = [for (final i in c.items) if (!i.kept && (usage.clearable[i.id] ?? 0) > 0) i.id];
    final ticked = goes.where(selected.contains).length;
    final bool? value = ticked == 0 ? false : (ticked == goes.length ? true : null);
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
      child: Column(
        children: [
          InkWell(
            onTap: onExpand,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: goes.isEmpty
                        ? null
                        : Checkbox(
                            tristate: true,
                            value: value,
                            semanticLabel: 'Select ${c.label}',
                            onChanged: (_) {
                              for (final i in goes) {
                                onSelect(i, value != true);
                              }
                            },
                          ),
                  ),
                  _Swatch(storageTone(c.id)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(c.label, style: text.titleMedium)),
                  const SizedBox(width: 8),
                  Text(sizeText(usage.categoryBytes(c)), style: text.bodyLarge?.copyWith(fontFeatures: tabular)),
                  Icon(open ? Icons.expand_less : Icons.expand_more, color: Night.inkMuted, semanticLabel: open ? 'Close' : 'Open'),
                ],
              ),
            ),
          ),
          if (open)
            for (final i in c.items) _ItemRow(item: i, usage: usage, on: selected.contains(i.id), onSelect: onSelect),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.usage, required this.on, required this.onSelect});
  final StorageItem item;
  final StorageUsage usage;
  final bool on;
  final void Function(String item, bool on) onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final bytes = usage.bytes[item.id] ?? 0;
    final can = usage.clearable[item.id] ?? 0;
    final why = usage.why[item.id];
    final lines = <String>[
      if (item.note.isNotEmpty) item.note,
      if (item.kept) 'Always kept',
      if (!item.kept && bytes > 0 && can < bytes)
        '${can > 0 ? '${sizeText(can)} can go now; ' : ''}${sizeText(bytes - can)} stays${why == null ? '' : ': $why'}',
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: item.kept || can == 0
                ? null
                : Checkbox(value: on, semanticLabel: 'Select ${item.label}', onChanged: (v) => onSelect(item.id, v ?? false)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.label, style: text.bodyLarge),
                  for (final l in lines) Text(l, style: muted),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 12, right: 24),
            child: Text(sizeText(bytes), style: text.bodyLarge?.copyWith(color: Night.inkMuted, fontFeatures: tabular)),
          ),
        ],
      ),
    );
  }
}

/// One category's time: label left, value right, then the four stops.
class _KeepRow extends StatelessWidget {
  const _KeepRow({required this.category, required this.days, required this.onKeep});
  final StorageCategory category;
  final int days;
  final void Function(String category, int days) onKeep;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final at = keepChoices.indexOf(days);
    return Container(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
      child: Column(
        children: [
          Row(
            children: [
              _Swatch(storageTone(category.id)),
              const SizedBox(width: 12),
              Expanded(child: Text(category.label, style: text.bodyLarge)),
              Text(keepWords(days), style: text.bodyLarge?.copyWith(fontFeatures: tabular)),
            ],
          ),
          Slider(
            value: (at < 0 ? keepChoices.length - 1 : at).toDouble(),
            max: (keepChoices.length - 1).toDouble(),
            divisions: keepChoices.length - 1,
            label: keepWords(days),
            semanticFormatterCallback: (v) => keepWords(keepChoices[v.round()]),
            onChanged: (v) => onKeep(category.id, keepChoices[v.round()]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final k in keepChoices)
                  Text(keepWords(k), style: text.bodySmall?.copyWith(color: k == days ? Night.ink : Night.inkMuted)),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _DangerZone extends StatelessWidget {
  const _DangerZone({required this.model, required this.onDanger, required this.onDelete});
  final StorageViewModel model;
  final void Function(String item, bool on) onDanger;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    final u = model.usage!;
    final items = [
      for (final c in storageCategories)
        for (final i in c.items)
          if ((u.phoneOnly[i.id] ?? 0) > 0) (c, i),
    ];
    final all = items.fold(0, (n, e) => n + (u.phoneOnly[e.$2.id] ?? 0));
    final can = model.busy == null && !model.working && model.dangerBytes > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: Night.problem),
          const SizedBox(height: 20),
          Text('Danger zone', style: text.titleMedium?.copyWith(color: Night.problem, fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          Text(
            items.isEmpty
                ? 'Nothing here is only on this phone: your laptop has a checked copy of every raw recording.'
                : '${sizeText(all)} of raw recordings and spoken answers are only on this phone. Deleting them here '
                      'loses them for good: the laptop does not have them. Nothing here is ever deleted by itself.',
            style: muted,
          ),
          for (final (c, i) in items)
            Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Night.rule))),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Checkbox(
                      value: model.danger.contains(i.id),
                      semanticLabel: 'Select ${c.label}, ${i.label}, only on this phone',
                      onChanged: (v) => onDanger(i.id, v ?? false),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('${c.label}: ${i.label.toLowerCase()}', style: text.bodyLarge),
                    ),
                  ),
                  Text(
                    '${u.phoneOnlyCount[i.id] ?? 0} · ${sizeText(u.phoneOnly[i.id] ?? 0)}',
                    style: text.bodyLarge?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                  ),
                ],
              ),
            ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Night.problem,
                  side: BorderSide(color: can ? Night.problem : Night.rule),
                ),
                onPressed: can ? onDelete : null,
                child: Text(
                  model.dangerBytes > 0
                      ? 'Delete from this phone only · ${sizeText(model.dangerBytes)}'
                      : 'Delete from this phone only',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
