// The watch strip: the night as half-hour cells, one row per four hours of clock time, each cell filled
// with the share of samples actually saved. Gaps show as hollow or part-filled cells.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../recorder/status.dart';
import 'theme.dart';

const int cellsPerRow = 8; // 8 half hours = 4 hours
const double _full = 0.98; // at or above: no gap worth showing

class StripCell {
  const StripCell({required this.slot, required this.column, required this.fraction, required this.current});

  /// unix ms ~/ [slotMs]
  final int slot;

  /// 0..7 within its four-hour row.
  final int column;

  /// Samples saved / samples expected for the part of this half hour inside the night (0..1).
  final double fraction;

  /// The half hour happening now (only while a night runs).
  final bool current;
}

class StripRow {
  const StripRow(this.start, this.cells);

  /// Local start of the four-hour row (20:00, 00:00, 04:00 ...).
  final DateTime start;
  final List<StripCell> cells;
}

/// Lays the night from [startMs] to [endMs] on the local clock. [live]: the last cell is the current one.
List<StripRow> stripRows({required int startMs, required int endMs, required Map<int, int> slots, required bool live}) {
  if (startMs <= 0 || endMs <= startMs) return const [];
  const rowMs = cellsPerRow * slotMs;
  int localMs(int ms) => ms + DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset.inMilliseconds;
  final rows = <int, List<StripCell>>{};
  final last = (endMs - 1) ~/ slotMs;
  for (var slot = startMs ~/ slotMs; slot <= last; slot++) {
    final from = math.max(slot * slotMs, startMs);
    final to = math.min((slot + 1) * slotMs, endMs);
    final current = live && slot == last;
    // The half hour in progress gets 10 s of slack: the newest batch is always a moment old.
    final expected = math.max(0, to - from - (current ? 10000 : 0)) / 1000 * sampleRateHz;
    final got = slots[slot] ?? 0;
    final fraction = expected < sampleRateHz ? (got > 0 ? 1.0 : 0.0) : math.min(1.0, got / expected);
    final local = localMs(slot * slotMs);
    final row = local ~/ rowMs;
    (rows[row] ??= []).add(
      StripCell(slot: slot, column: (local % rowMs) ~/ slotMs, fraction: fraction, current: current),
    );
  }
  return [
    for (final e in rows.entries)
      StripRow(
        DateTime.fromMillisecondsSinceEpoch(e.value.first.slot * slotMs - e.value.first.column * slotMs),
        e.value,
      ),
  ];
}

/// Share of the night's expected samples that were saved (0..1).
double nightCoverage(List<StripRow> rows) {
  var n = 0;
  var sum = 0.0;
  for (final r in rows) {
    for (final c in r.cells) {
      if (c.current) continue; // still filling
      n++;
      sum += c.fraction;
    }
  }
  return n == 0 ? 1 : sum / n;
}

class NightStrip extends StatelessWidget {
  const NightStrip({super.key, required this.rows});
  final List<StripRow> rows;

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.labelMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final gaps = rows.expand((r) => r.cells).where((c) => !c.current && c.fraction < _full).length;
    return Semantics(
      label: gaps == 0 ? 'Every half hour so far is fully recorded' : '$gaps half hours have gaps',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(width: 52, child: Text(_hhmm(r.start), style: label)),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        // seven gaps: six of 6 dp and the two-hour one of 12 dp
                        final cell = math.min(32.0, (c.maxWidth - 6 * (cellsPerRow - 1) - 6) / cellsPerRow);
                        final byColumn = {for (final x in r.cells) x.column: x};
                        return Row(
                          children: [
                            for (var col = 0; col < cellsPerRow; col++) ...[
                              if (col > 0) SizedBox(width: col == 4 ? 12 : 6), // a wider gap marks each two hours
                              SizedBox.square(
                                dimension: cell,
                                // Half hours outside the night keep their place on the clock, faintly.
                                child: byColumn[col] == null ? const _Slot() : _Cell(byColumn[col]!),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.cell);
  final StripCell cell;

  @override
  Widget build(BuildContext context) {
    final f = cell.fraction;
    final complete = f >= (cell.current ? 0.9 : _full);
    final fill = complete ? Night.saved : Night.caution;
    final border = cell.current
        ? Border.all(color: Night.live, width: 2)
        : (f == 0 ? Border.all(color: Night.problem.withValues(alpha: 0.8)) : null);
    return Container(
      decoration: BoxDecoration(color: Night.track, borderRadius: BorderRadius.circular(6)),
      // The outline is drawn over the fill, so the live half hour stays visible when it is full.
      foregroundDecoration: border == null
          ? null
          : BoxDecoration(borderRadius: BorderRadius.circular(6), border: border),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: f.clamp(0.0, 1.0),
            widthFactor: 1,
            child: ColoredBox(color: fill),
          ),
        ),
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Night.track),
    ),
  );
}

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
