// The Archive's sheets and dialogs (DECISIONS 700-709; DESIGN.md "Archive"): a band, a lane's bands, the tag editor,
// and the two ways to delete (the owner's rules, 2026-11-20): Remove from this phone (one confirmation, only with the
// laptop's checked copy) and the Danger zone (red, says when it is the only copy, asks twice; "Everything" only here).
import 'package:flutter/material.dart';

import '../archive/bands.dart';
import '../archive/delete.dart';
import '../archive/items.dart';
import '../archive/tags.dart';
import 'archive_view.dart' show sizeWords, hm, lengthText, spanText;
import 'theme.dart';

/// What a band's sheet asks for.
enum BandAction { signal, tag, edit }

TextStyle? _muted(BuildContext c) => Theme.of(c).textTheme.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);

/// A band: its word, its span, where it comes from; Show the signal, Tag this span (or Change, for your own tag).
Future<BandAction?> showBandSheet(BuildContext context, Band b, {required bool hasSignal}) =>
    showModalBottomSheet<BandAction>(
      context: context,
      showDragHandle: true,
      backgroundColor: Night.surfaceHigh,
      builder: (c) {
        final text = Theme.of(c).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(b.lane.word, style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                const SizedBox(height: 4),
                Text(b.label, style: text.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '${spanText(b.start, b.end)} · ${lengthText(b.length)}',
                  style: text.titleMedium?.copyWith(fontFeatures: tabular),
                ),
                const SizedBox(height: 8),
                Text(b.source, style: _muted(c)),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (hasSignal)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(c, BandAction.signal),
                        icon: const Icon(Icons.ssid_chart),
                        label: const Text('Show the signal'),
                      ),
                    if (b.tag != null)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(c, BandAction.edit),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Change this tag'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(c, BandAction.tag),
                        icon: const Icon(Icons.sell_outlined),
                        label: const Text('Tag this span'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

/// A lane's bands as rows; a tap returns that band.
Future<Band?> showLaneSheet(BuildContext context, Lane lane, List<Band> bands) => showModalBottomSheet<Band>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: Night.surfaceHigh,
  builder: (c) {
    final text = Theme.of(c).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                bands.isEmpty ? '${lane.word}: none found.' : '${lane.word}: ${bands.length == 1 ? '1 stretch' : '${bands.length} stretches'}',
                style: text.titleLarge,
              ),
            ),
            for (final b in bands)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: Text(spanText(b.start, b.end), style: text.titleMedium?.copyWith(fontFeatures: tabular)),
                subtitle: Text('${b.label} · ${lengthText(b.length)}', style: text.bodyMedium?.copyWith(color: Night.inkMuted)),
                trailing: const Icon(Icons.chevron_right, color: Night.inkMuted),
                onTap: () => Navigator.pop(c, b),
              ),
          ],
        ),
      ),
    );
  },
);

/// What the tag editor returns: a tag to save, or the old one to remove.
typedef TagEdit = ({ManualTag? save, bool remove});

/// The moment of [t] (a time of day) inside [from]..[to], the first day that fits; clamped to the span.
DateTime momentIn(TimeOfDay t, DateTime from, DateTime to) {
  for (var d = 0; d < 3; d++) {
    final c = DateTime(from.year, from.month, from.day + d, t.hour, t.minute);
    if (!c.isBefore(DateTime(from.year, from.month, from.day, from.hour, from.minute)) && !c.isAfter(to)) return c;
  }
  final c = DateTime(from.year, from.month, from.day, t.hour, t.minute);
  return c.isBefore(from) ? from : (c.isAfter(to) ? to : c);
}

/// Add or change a tag on a span inside the recording [within]: the word (a preset or typed), from, to.
Future<TagEdit?> showTagEditor(
  BuildContext context, {
  required (DateTime, DateTime) within,
  required DateTime start,
  required DateTime end,
  ManualTag? tag,
  String? label,
}) => showModalBottomSheet<TagEdit>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: Night.surfaceHigh,
  builder: (c) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
    child: _TagEditor(within: within, start: tag?.start ?? start, end: tag?.end ?? end, tag: tag, label: label),
  ),
);

class _TagEditor extends StatefulWidget {
  const _TagEditor({required this.within, required this.start, required this.end, this.tag, this.label});
  final (DateTime, DateTime) within;
  final DateTime start, end;
  final ManualTag? tag;

  /// The word offered first for a new tag.
  final String? label;

  @override
  State<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<_TagEditor> {
  late String _word = widget.tag?.label ?? widget.label ?? '';
  late DateTime _start = widget.start, _end = widget.end;
  late bool _truth = widget.tag?.truth ?? false;
  late final TextEditingController _typed = TextEditingController(
    text: presetTags.contains(_word) ? '' : _word,
  );

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final now = isStart ? _start : _end;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t == null || !mounted) return;
    final m = momentIn(t, widget.within.$1, widget.within.$2);
    setState(() => isStart ? _start = m : _end = m);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final word = cleanTag(_word);
    final ok = word.isNotEmpty && _end.isAfter(_start);
    Widget timeRow(String label, DateTime t, bool isStart) => InkWell(
      onTap: () => _pick(isStart),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Expanded(child: Text(label, style: text.bodyLarge?.copyWith(color: Night.inkMuted))),
            Text(hm(t), style: text.titleLarge?.copyWith(fontFeatures: tabular)),
            const SizedBox(width: 8),
            const Icon(Icons.schedule, color: Night.inkMuted, size: 20),
          ],
        ),
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.tag == null ? 'Tag a span' : 'Change the tag', style: text.titleLarge),
            const SizedBox(height: 6),
            Text('What were you doing? Your tags are kept with the recording and leave with Export data.', style: _muted(context)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final p in presetTags)
                  ChoiceChip(
                    label: Text(p),
                    selected: word == p,
                    onSelected: (_) => setState(() {
                      _word = p;
                      _typed.clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _typed,
              maxLength: maxTagLength,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(labelText: 'Or your own word'),
              onChanged: (v) => setState(() => _word = v),
            ),
            timeRow('From', _start, true),
            const Divider(height: 1),
            timeRow('To', _end, false),
            if (!_end.isAfter(_start))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('The end comes before the start.', style: text.bodyMedium?.copyWith(color: Night.caution)),
              ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _truth,
              onChanged: (v) => setState(() => _truth = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('This is what I was doing'),
              subtitle: Text(
                'Sure of the word and the times? The laptop then checks its detectors against it.',
                style: _muted(context),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: ok
                  ? () => Navigator.pop(context, (
                      save: ManualTag(start: _start, end: _end, label: word, made: widget.tag?.made, truth: _truth),
                      remove: false,
                    ))
                  : null,
              child: const Text('Save'),
            ),
            if (widget.tag != null) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context, (save: null, remove: true)),
                  child: const Text('Remove the tag'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _list(List<String> parts) => parts.length <= 1
    ? parts.join()
    : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';

String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Remove from this phone, with the laptop's checked copy: one confirmation. True: go ahead.
Future<bool> confirmRemove(BuildContext context, List<ArchiveItem> items) async {
  final plan = planDeleteAll(items, DeleteMode.rawOnLaptop);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: Night.surfaceHigh,
      title: const Text('Remove from this phone?'),
      content: Text(
        '${_cap(_list(plan.removes))} (${sizeWords(plan.freedBytes)}) leaves this phone. It stays on your laptop, which '
        'has checked its copy. ${plan.keeps.isEmpty ? '' : '${_cap(_list(plan.keeps))} stay here.'}',
        style: _muted(c),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
      ],
    ),
  );
  return ok ?? false;
}

/// The Danger zone: what to delete, a clear word when it is the only copy, then once more. [name]: "this night", "the
/// recordings of Wed 18 Nov". Null: cancelled.
Future<DeleteMode?> confirmDanger(BuildContext context, List<ArchiveItem> items, {required String name}) async {
  final first = await showDialog<DeleteMode>(
    context: context,
    builder: (c) => _DangerChoice(items: items, name: name),
  );
  if (first == null || !context.mounted) return null;
  final plan = planDeleteAll(items, first);
  final sure = await showDialog<bool>(
    context: context,
    builder: (c) {
      final text = Theme.of(c).textTheme;
      return AlertDialog(
        backgroundColor: Night.surfaceHigh,
        icon: const Icon(Icons.delete_forever_outlined, color: Night.problem),
        title: Text('Delete for good?', style: text.headlineSmall?.copyWith(color: Night.problem)),
        content: Text(
          '${_cap(_list(plan.removes))} of $name (${sizeWords(plan.freedBytes)}) will be deleted from this phone. '
          '${plan.onlyCopy ? 'No other copy exists: it cannot be brought back.' : 'This cannot be undone here.'}',
          style: text.bodyLarge?.copyWith(color: Night.ink, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Night.problem, foregroundColor: Night.ground),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return sure == true ? first : null;
}

class _DangerChoice extends StatefulWidget {
  const _DangerChoice({required this.items, required this.name});
  final List<ArchiveItem> items;
  final String name;

  @override
  State<_DangerChoice> createState() => _DangerChoiceState();
}

class _DangerChoiceState extends State<_DangerChoice> {
  late final bool _hasRaw = widget.items.any((i) => i.hasRaw);
  late DeleteMode _mode = _hasRaw ? DeleteMode.rawOnly : DeleteMode.everything;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final raw = planDeleteAll(widget.items, DeleteMode.rawOnly), all = planDeleteAll(widget.items, DeleteMode.everything);
    Widget option(DeleteMode m, String title, String body) => RadioListTile<DeleteMode>(
      value: m,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: text.titleMedium),
      subtitle: Text(body, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35)),
    );
    return AlertDialog(
      backgroundColor: Night.surfaceHigh,
      icon: const Icon(Icons.warning_amber_rounded, color: Night.problem),
      title: Text('Delete ${widget.name}?', style: text.headlineSmall?.copyWith(color: Night.problem)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (raw.onlyCopy)
              Text(
                'This is the only copy: the laptop has not checked a copy of its raw recording. Deleted here, it is gone.',
                style: text.bodyLarge?.copyWith(color: Night.problem, height: 1.4),
              )
            else if (_hasRaw)
              Text('The laptop has a checked copy of its raw recording.', style: _muted(context)),
            const SizedBox(height: 12),
            RadioGroup<DeleteMode>(
              groupValue: _mode,
              onChanged: (m) => setState(() => _mode = m ?? _mode),
              child: Column(
                children: [
                  if (_hasRaw)
                    option(
                      DeleteMode.rawOnly,
                      'The raw recording only (${sizeWords(raw.freedBytes)})',
                      raw.keeps.isEmpty ? 'Nothing else is kept of it.' : '${_cap(_list(raw.keeps))} stay.',
                    ),
                  option(
                    DeleteMode.everything,
                    'Everything (${sizeWords(all.freedBytes)})',
                    all.keeps.isEmpty && raw.keeps.isEmpty
                        ? 'Every file of it.'
                        : 'Also the statistics made from it: ${_list(raw.keeps)}.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Night.problem),
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// The page's word on a delete's outcome.
String deleteWords(DeleteOutcome o) {
  if (o.complete) return 'Deleted: ${sizeWords(o.freedBytes)} freed.';
  final why = o.refused.first;
  return o.freedBytes > 0 ? 'Partly deleted (${sizeWords(o.freedBytes)} freed); left: $why' : 'Nothing deleted: $why';
}
