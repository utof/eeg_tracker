// "Try these" (DECISIONS 340; .impeccable/surfaces/app-lib-ui-try-these-screen-dart.md): the page from a plain model,
// so it renders in tests without a phone. Every feature's first try is a numbered stop, in order; the open stop reads
// what it is, what to do, a button to its screen, what to tell the assistant, a note, and Done / Skip. The try ledger on
// top counts the stops in the watch strip's own cells. The night screen's section is [TryEntryView].
import 'package:flutter/material.dart';

import '../try_these/cards.dart';
import '../try_these/progress.dart';
import '../recorder/nights.dart' show nightLabel;
import 'parts.dart';
import 'theme.dart';

const Map<TryOpen, IconData> _openIcons = {
  TryOpen.nightScreen: Icons.bedtime_outlined,
  TryOpen.sleepReport: Icons.bar_chart_rounded,
  TryOpen.alarm: Icons.wb_twilight_outlined,
  TryOpen.morning: Icons.wb_twilight_rounded,
  TryOpen.trends: Icons.show_chart_rounded,
  TryOpen.export: Icons.drive_folder_upload_outlined,
  TryOpen.meditation: Icons.self_improvement,
  TryOpen.alphaTheta: Icons.waves_outlined,
  TryOpen.training: Icons.tune,
  TryOpen.dream: Icons.nights_stay_outlined,
  TryOpen.nap: Icons.airline_seat_flat_angled_outlined,
  TryOpen.sound: Icons.graphic_eq,
  TryOpen.settings: Icons.settings_outlined,
  TryOpen.experiments: Icons.science_outlined,
  TryOpen.sharpHours: Icons.schedule,
  TryOpen.study: Icons.menu_book_outlined,
  TryOpen.memory: Icons.grid_view_outlined,
  TryOpen.ownBle: Icons.bluetooth_searching,
  TryOpen.archive: Icons.inventory_2_outlined,
};

/// The muted line under a finished stop's title: when, and who ticked it.
String finishedLine(CardProgress? p) {
  if (p == null) return '';
  final when = p.at == null ? '' : ' ${nightLabel(p.at!)}';
  return switch (p.state) {
    TryState.skipped => 'Skipped$when.',
    TryState.done when p.byApp => 'Seen by the app$when.',
    TryState.done => 'Done$when.',
    TryState.open => '',
  };
}

class TryTheseView extends StatelessWidget {
  const TryTheseView({
    super.key,
    required this.page,
    required this.expanded,
    required this.showFinished,
    required this.onToggle,
    required this.onOpen,
    required this.onDone,
    required this.onSkip,
    required this.onReopen,
    required this.onNote,
    required this.onShowFinished,
    this.openLabel,
    this.stopKey,
    this.error,
  });

  final TryPage page;

  /// The one stop shown whole (its id), or null.
  final String? expanded;
  final bool showFinished;
  final ValueChanged<String> onToggle;
  final ValueChanged<TryCard> onOpen;
  final ValueChanged<String> onDone;
  final ValueChanged<String> onSkip;
  final ValueChanged<String> onReopen;
  final void Function(String id, String note) onNote;
  final VoidCallback onShowFinished;

  /// The button's words for a card (the screen may send a stop back to the main screen); default [tryOpenLabels].
  final String Function(TryCard card)? openLabel;

  /// A key per stop, so the screen can scroll the next one into view.
  final GlobalKey Function(String id)? stopKey;

  /// Why the progress could not be read or saved, or null.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4);
    Widget stop(TryCard c) => _Stop(
      key: stopKey?.call(c.id),
      card: c,
      page: page,
      open: expanded == c.id,
      openLabel: openLabel?.call(c) ?? tryOpenLabels[c.opens]!,
      onToggle: () => onToggle(c.id),
      onOpen: () => onOpen(c),
      onDone: () => onDone(c.id),
      onSkip: () => onSkip(c.id),
      onReopen: () => onReopen(c.id),
      onNote: (s) => onNote(c.id, s),
    );
    final finished = page.finished;
    final exportCard = page.cards.where((c) => c.opens == TryOpen.export).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text('Try these', style: text.titleMedium?.copyWith(color: Night.inkMuted)),
      ),
      // Every stop is built (about twenty rows), so the page can scroll the next stop into view after Done.
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Tally(page),
            const SizedBox(height: 14),
            TryLedger(page: page),
            const SizedBox(height: 16),
            Text(
              page.next == null
                  ? 'Every stop is done or skipped. Open one below to add to its note: notes go out with Export data.'
                  : 'One at a time, in this order. Each ends with what to tell the assistant; a note here goes out with '
                        'Export data.',
              style: muted,
            ),
            if (page.next == null && exportCard != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => onOpen(exportCard),
                icon: Icon(_openIcons[TryOpen.export]),
                label: Text(openLabel?.call(exportCard) ?? tryOpenLabels[TryOpen.export]!),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: muted?.copyWith(color: Night.caution)),
            ],
            for (final g in page.groups) ...[
              SectionHeading(tryGroupTitles[g.group]!),
              ..._ruled([for (final c in g.cards) stop(c)]),
            ],
            if (finished.isNotEmpty) ...[
              const SectionHeading('Done and skipped'),
              if (!showFinished)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onShowFinished,
                    icon: const Icon(Icons.expand_more),
                    label: Text(finished.length == 1 ? 'Show 1 stop' : 'Show ${finished.length} stops'),
                  ),
                )
              else
                ..._ruled([for (final c in finished) stop(c)]),
            ],
          ],
        ),
      ),
    );
  }
}

/// Stops with a hairline between them (the section heading draws the one above the first).
List<Widget> _ruled(List<Widget> stops) => [
  for (var i = 0; i < stops.length; i++) ...[if (i > 0) const Divider(), stops[i]],
];

/// "4 of 20 tried" with the skipped count at the right.
class _Tally extends StatelessWidget {
  const _Tally(this.page);
  final TryPage page;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(page.tally, style: text.titleLarge?.copyWith(fontFeatures: tabular)),
        ),
        if (page.skipped > 0)
          Text(
            '${page.skipped} skipped',
            style: text.bodyLarge?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
          ),
      ],
    );
  }
}

/// One cell per stop, in order, ten to a row with a wider gap after five: filled `saved` when done, a dash on `track`
/// when skipped, the next stop outlined green like the half hour in progress, `track` while still to come.
class TryLedger extends StatelessWidget {
  const TryLedger({super.key, required this.page});
  final TryPage page;

  static const double _gap = 6, _wide = 14;

  @override
  Widget build(BuildContext context) {
    final cards = page.cards;
    final next = page.next;
    final label =
        '${page.tally}${page.skipped > 0 ? ', ${page.skipped} skipped' : ''}'
        '${next == null ? '' : '. Next: number ${page.number(next.id)}, ${next.title}'}.';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = ((box.maxWidth - 8 * _gap - _wide) / 10).clamp(12.0, 32.0);
          final rows = <Widget>[];
          for (var r = 0; r * 10 < cards.length; r++) {
            final cells = <Widget>[];
            for (var i = r * 10; i < cards.length && i < r * 10 + 10; i++) {
              if (i % 10 != 0) cells.add(SizedBox(width: i % 5 == 0 ? _wide : _gap));
              cells.add(_LedgerCell(mark: page.mark(cards[i].id), size: size));
            }
            if (r > 0) rows.add(const SizedBox(height: _gap));
            rows.add(Row(children: cells));
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
        },
      ),
    );
  }
}

class _LedgerCell extends StatelessWidget {
  const _LedgerCell({required this.mark, required this.size});
  final LedgerMark mark;
  final double size;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return AnimatedContainer(
      duration: still ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: mark == LedgerMark.done ? Night.saved : Night.track,
        borderRadius: BorderRadius.circular(6),
        border: mark == LedgerMark.next ? Border.all(color: Night.live, width: 2) : null,
      ),
      child: mark == LedgerMark.skipped ? Icon(Icons.remove, size: size * 0.6, color: Night.inkMuted) : null,
    );
  }
}

/// A stop's number in a strip cell: filled when done (the number in ground ink), a dash when skipped, a green outline
/// when it is next.
class _NumberCell extends StatelessWidget {
  const _NumberCell({required this.number, required this.mark});
  final int number;
  final LedgerMark mark;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontFeatures: tabular,
      fontWeight: FontWeight.w500,
      color: switch (mark) {
        LedgerMark.done => Night.ground,
        LedgerMark.next => Night.ink,
        _ => Night.inkMuted,
      },
    );
    return SizedBox.square(
      dimension: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3).scale(36),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: mark == LedgerMark.done ? Night.saved : Night.track,
          borderRadius: BorderRadius.circular(6),
          border: mark == LedgerMark.next ? Border.all(color: Night.live, width: 2) : null,
        ),
        child: Center(
          child: mark == LedgerMark.skipped
              ? const Icon(Icons.remove, size: 20, color: Night.inkMuted)
              : MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: Text('$number', style: style)),
        ),
      ),
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({
    super.key,
    required this.card,
    required this.page,
    required this.open,
    required this.openLabel,
    required this.onToggle,
    required this.onOpen,
    required this.onDone,
    required this.onSkip,
    required this.onReopen,
    required this.onNote,
  });

  final TryCard card;
  final TryPage page;
  final bool open;
  final String openLabel;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final VoidCallback onReopen;
  final ValueChanged<String> onNote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final p = page.progress[card.id];
    final mark = page.mark(card.id);
    final finished = mark == LedgerMark.done || mark == LedgerMark.skipped;
    final sub = finished ? finishedLine(p) : card.takes;
    final still = MediaQuery.disableAnimationsOf(context);
    final header = Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NumberCell(number: page.number(card.id), mark: mark),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(card.title, style: open ? text.titleLarge : text.titleMedium),
                      ),
                      const SizedBox(height: 4),
                      Text(sub, style: muted),
                      if (card.proposal && !open) Text('The assistant\'s idea.', style: muted),
                      if (card.weakEvidence && !open) Text('The evidence is weak.', style: muted),
                      if (!open && p != null && p.note.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Note: ${p.note}',
                            style: muted?.copyWith(color: Night.ink),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Icon(open ? Icons.expand_less : Icons.expand_more, color: Night.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        AnimatedSize(
          duration: still ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? _StopBody(
                  card: card,
                  progress: p,
                  finished: finished,
                  openLabel: openLabel,
                  onOpen: onOpen,
                  onDone: onDone,
                  onSkip: onSkip,
                  onReopen: onReopen,
                  onNote: onNote,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The open stop: what it is, whose idea, how weak the evidence is, the steps, the button to its screen, what to tell the assistant, the note,
/// then Done (the page's one filled button) and Skip; a finished stop ends with Not done yet instead.
class _StopBody extends StatelessWidget {
  const _StopBody({
    required this.card,
    required this.progress,
    required this.finished,
    required this.openLabel,
    required this.onOpen,
    required this.onDone,
    required this.onSkip,
    required this.onReopen,
    required this.onNote,
  });

  final TryCard card;
  final CardProgress? progress;
  final bool finished;
  final String openLabel;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  final VoidCallback onSkip;
  final VoidCallback onReopen;
  final ValueChanged<String> onNote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.4);
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.35);
    final seen = progress?.byApp == true ? progress?.seen : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(card.what, style: body),
          if (card.proposal) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.lightbulb_outline, size: 20, color: Night.inkMuted),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The assistant\'s idea, not one of your wishes. Skip it if you do not want it.',
                    style: muted,
                  ),
                ),
              ],
            ),
          ],
          if (card.weakEvidence) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.science_outlined, size: 20, color: Night.inkMuted),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The evidence is weak: it may do nothing for you. The i on its screen says why.',
                    style: muted,
                  ),
                ),
              ],
            ),
          ],
          if (seen != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.visibility_outlined, size: 20, color: Night.inkMuted),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(seen, style: muted)),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Text('What to do', style: muted),
          const SizedBox(height: 8),
          for (var i = 0; i < card.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${i + 1}',
                      style: body?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
                    ),
                  ),
                  Expanded(child: Text(card.steps[i], style: body)),
                ],
              ),
            ),
          const SizedBox(height: 6),
          OutlinedButton.icon(onPressed: onOpen, icon: Icon(_openIcons[card.opens]), label: Text(openLabel)),
          const SizedBox(height: 24),
          Text('Then tell the assistant', style: muted),
          const SizedBox(height: 8),
          for (final t in card.tell)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 26,
                    child: Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox.square(
                          dimension: 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Night.inkMuted, shape: BoxShape.circle),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: Text(t, style: body)),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text('What happened', style: muted),
          _NoteField(key: ValueKey('note-${card.id}'), note: progress?.note ?? '', onChanged: onNote),
          const SizedBox(height: 20),
          if (finished)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onReopen,
                icon: const Icon(Icons.undo),
                label: const Text('Not done yet'),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.icon(onPressed: onDone, icon: const Icon(Icons.check), label: const Text('Done')),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextButton(
                    onPressed: onSkip,
                    style: TextButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                    child: const Text('Skip'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// "What happened", saved as you type (the dream catcher's note field).
class _NoteField extends StatefulWidget {
  const _NoteField({super.key, required this.note, required this.onChanged});
  final String note;
  final ValueChanged<String> onChanged;

  @override
  State<_NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<_NoteField> {
  late final TextEditingController _c = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    onChanged: widget.onChanged,
    minLines: 2,
    maxLines: 8,
    textCapitalization: TextCapitalization.sentences,
    style: Theme.of(context).textTheme.bodyLarge,
    decoration: const InputDecoration(
      hintText: 'Optional. Goes out with Export data.',
      hintStyle: TextStyle(color: Night.inkMuted),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(vertical: 10),
      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.rule)),
      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Night.inkMuted)),
    ),
  );
}

/// The night screen's "Try these" section (between nights): the tally and the next stop in one muted line, and the
/// button to the page.
class TryEntryView extends StatelessWidget {
  const TryEntryView({super.key, required this.line, required this.onOpen});
  final String line;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line, style: text.bodyLarge?.copyWith(color: Night.inkMuted, height: 1.4)),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.checklist_rounded),
          label: const Text('Try these'),
        ),
      ],
    );
  }
}
