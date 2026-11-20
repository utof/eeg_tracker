// The storage bar (DECISIONS 690-699; the owner, 2026-11-20: "an Android-style storage visualisation"): one stacked
// bar of what the app keeps on this phone, a segment per category in proportion to its bytes, each a warm tone of its
// own that the category's row repeats as a swatch (a colour never stands alone: the row names it). Tapping a segment
// opens its category. Reusable: the Storage page shows it at its top, and an Archive page can too, fed by the same
// [storageSegments] of one scan (storage/clear.dart scanStorage). Inside DESIGN.md: cells of 6 dp radius, no glow,
// nothing bright.
import 'package:flutter/material.dart';

import '../export/store.dart' show sizeText;
import '../storage/clear.dart' show StorageUsage, usageByCategory;
import 'theme.dart';

/// Each category's tone: dim, warm and apart from the navigation-light trio (green, amber, red keep their meanings).
const Map<String, Color> storageTones = {
  'nights': Color(0xFFC9B48A), // sand
  'work': Color(0xFF8FA39A), // sage
  'meditation': Color(0xFF9C8BA8), // heather
  'sound': Color(0xFF7F95AD), // slate
  'naps': Color(0xFFB59A7A), // tan
  'dream': Color(0xFFA88194), // mauve
  'checkins': Color(0xFFD7C9AE), // parchment
  'diy': Color(0xFF8E8A64), // olive
  'logs': Color(0xFF7A6A58), // umber
  'cache': Color(0xFF5E5448), // smoke
  'other': Color(0xFF4A4036), // the rule's warmer twin
};

Color storageTone(String category) => storageTones[category] ?? Night.saved;

/// One segment: a category, its words and its bytes.
typedef StorageSegment = ({String id, String label, int bytes, Color color});

/// The segments of [u], biggest category first, without empty ones.
List<StorageSegment> storageSegments(StorageUsage u) => [
  for (final c in usageByCategory(u))
    if (c.bytes > 0) (id: c.id, label: c.label, bytes: c.bytes, color: storageTone(c.id)),
]..sort((a, b) => b.bytes.compareTo(a.bytes));

class StorageBar extends StatelessWidget {
  const StorageBar({super.key, required this.segments, this.onTap, this.height = 20});
  final List<StorageSegment> segments;

  /// A segment was tapped: its category id.
  final ValueChanged<String>? onTap;
  final double height;

  /// Segment widths in [width]: in proportion, each at least [minWidth] so a small category stays tappable to see.
  static List<double> widths(List<int> bytes, double width, {double gap = 2, double minWidth = 4}) {
    final n = bytes.length;
    if (n == 0) return const [];
    final room = width - gap * (n - 1);
    final total = bytes.fold(0, (a, b) => a + b);
    if (total <= 0 || room <= 0) return [for (final _ in bytes) 0];
    final raw = [for (final b in bytes) room * b / total];
    final small = raw.where((w) => w < minWidth).length;
    final big = raw.where((w) => w >= minWidth).fold(0.0, (a, b) => a + b);
    final scale = big <= 0 ? 0.0 : (room - small * minWidth) / big;
    return [for (final w in raw) w < minWidth ? minWidth : w * scale];
  }

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) {
      return Container(
        height: height,
        decoration: BoxDecoration(color: Night.track, borderRadius: BorderRadius.circular(6)),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final w = widths([for (final s in segments) s.bytes], c.maxWidth);
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Row(
            children: [
              for (var i = 0; i < segments.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Semantics(
                  button: onTap != null,
                  label: '${segments[i].label}, ${sizeText(segments[i].bytes)}',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap == null ? null : () => onTap!(segments[i].id),
                    child: Container(
                      key: ValueKey('storage-segment-${segments[i].id}'),
                      width: w[i],
                      height: height,
                      color: segments[i].color,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
