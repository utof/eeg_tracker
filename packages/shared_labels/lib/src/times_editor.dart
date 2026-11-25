// "Yes, but the times are off" (asking.md): the stretch on a timeline strip with a little time before and after it,
// where both edges can be moved, by dragging or by the step buttons. A plain Yes says only that it happened; times
// count as yours once you saw them here and saved, moved or not. No files here.
import 'package:flutter/material.dart';

import 'estimate.dart';

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

abstract final class TimesRule {
  /// The strip shows this much before and after the stretch: a quarter of its length, at least [minPadMin].
  static const double padShare = 0.25;
  static const int minPadMin = 20;

  /// A step button moves an edge by this; the shortest stretch that can be saved.
  static const int stepMin = 5;
  static const int shortestMin = 1;
}

/// The start and end you set.
typedef Times = ({DateTime start, DateTime end});

/// Opens the editor over [e]'s stretch; null when cancelled. [around]: what else was found near it, drawn faintly so
/// you see what came before and after. [now]: no edge can be moved past it.
Future<Times?> showTimesEditor(BuildContext context, Estimate e, {List<Estimate> around = const [], DateTime? now}) => showDialog<Times>(
  context: context,
  builder: (d) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: SizedBox(
        width: 480,
        child: TimesEditor(estimate: e, around: around, now: now, onCancel: () => Navigator.pop(d), onSave: (t) => Navigator.pop(d, t)),
      ),
    ),
  ),
);

class TimesEditor extends StatefulWidget {
  const TimesEditor({super.key, required this.estimate, required this.onSave, this.onCancel, this.around = const [], this.now});
  final Estimate estimate;
  final List<Estimate> around;
  final DateTime? now;
  final ValueChanged<Times> onSave;
  final VoidCallback? onCancel;

  @override
  State<TimesEditor> createState() => _TimesEditorState();
}

class _TimesEditorState extends State<TimesEditor> {
  late DateTime _start = widget.estimate.start, _end = widget.estimate.end;
  late final DateTime _from, _to;

  @override
  void initState() {
    super.initState();
    final e = widget.estimate;
    final pad = Duration(minutes: (e.length.inMinutes * TimesRule.padShare).round().clamp(TimesRule.minPadMin, 240));
    _from = e.start.subtract(pad);
    final to = e.end.add(pad), now = widget.now;
    _to = now != null && now.isBefore(to) && now.isAfter(e.end) ? now : to;
  }

  int get _spanMin => _to.difference(_from).inMinutes;

  void _move({required bool start, required int minutes}) => _set(start: start, to: (start ? _start : _end).add(Duration(minutes: minutes)));

  void _set({required bool start, required DateTime to}) {
    const gap = Duration(minutes: TimesRule.shortestMin);
    var t = DateTime(to.year, to.month, to.day, to.hour, to.minute);
    if (start) {
      if (t.isBefore(_from)) t = _from;
      if (t.isAfter(_end.subtract(gap))) t = _end.subtract(gap);
    } else {
      if (t.isAfter(_to)) t = _to;
      if (t.isBefore(_start.add(gap))) t = _start.add(gap);
    }
    setState(() => start ? _start = t : _end = t);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    final e = widget.estimate;
    Widget edge(String name, DateTime t, bool start) => Row(
      children: [
        Expanded(child: Text('$name ${_clock(t)}', key: ValueKey(start ? 'times-start' : 'times-end'), style: text.titleMedium)),
        IconButton(
          key: ValueKey(start ? 'times-start-earlier' : 'times-end-earlier'),
          onPressed: () => _move(start: start, minutes: -TimesRule.stepMin),
          icon: const Icon(Icons.remove),
          tooltip: '$name ${TimesRule.stepMin} minutes earlier',
        ),
        IconButton(
          key: ValueKey(start ? 'times-start-later' : 'times-end-later'),
          onPressed: () => _move(start: start, minutes: TimesRule.stepMin),
          icon: const Icon(Icons.add),
          tooltip: '$name ${TimesRule.stepMin} minutes later',
        ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${e.label.chip}: set the times', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text('Drag the two ends, or use the buttons. About right is fine.', style: text.bodyMedium?.copyWith(color: c.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            double x(DateTime t) => (t.difference(_from).inSeconds / (_spanMin * 60) * w).clamp(0.0, w);
            DateTime at(double px) => _from.add(Duration(minutes: (px / w * _spanMin).round()));
            Widget handle(bool start) => Positioned(
              left: x(start ? _start : _end) - 22,
              top: 0,
              bottom: 0,
              width: 44,
              child: GestureDetector(
                key: ValueKey(start ? 'times-handle-start' : 'times-handle-end'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => _set(start: start, to: at(x(start ? _start : _end) + d.delta.dx)),
                child: Center(child: Container(width: 4, decoration: BoxDecoration(color: c.primary, borderRadius: BorderRadius.circular(2)))),
              ),
            );
            return SizedBox(
              height: 56,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(top: 16, bottom: 16, child: DecoratedBox(decoration: BoxDecoration(color: c.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)))),
                  for (final o in widget.around)
                    if (o.id != e.id && o.end.isAfter(_from) && o.start.isBefore(_to))
                      Positioned(left: x(o.start), width: (x(o.end) - x(o.start)).clamp(2.0, w), top: 22, bottom: 22, child: ColoredBox(color: c.outline)),
                  Positioned(left: x(_start), width: (x(_end) - x(_start)).clamp(2.0, w), top: 16, bottom: 16, child: ColoredBox(color: c.primary.withValues(alpha: 0.45))),
                  handle(true),
                  handle(false),
                ],
              ),
            );
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_clock(_from), style: text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            Text(_clock(_to), style: text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ],
        ),
        for (final o in widget.around)
          if (o.id != e.id && o.end.isAfter(_from) && o.start.isBefore(_to))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Also found: ${o.label.chip.toLowerCase()} ${_clock(o.start)}-${_clock(o.end)}', style: text.bodySmall?.copyWith(color: c.onSurfaceVariant)),
            ),
        const SizedBox(height: 8),
        edge('Start', _start, true),
        edge('End', _end, false),
        const SizedBox(height: 4),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 8,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            FilledButton(onPressed: () => widget.onSave((start: _start, end: _end)), child: const Text('Save these times')),
          ],
        ),
      ],
    );
  }
}
