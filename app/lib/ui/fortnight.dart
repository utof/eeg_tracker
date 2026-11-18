// The trends page's signature (.impeccable/surfaces/app-lib-ui-trends-screen-dart.md): the last 14 days of one
// measure as a row of the watch strip's own cells, one cell per day, oldest on the left. Your usual's normal range
// is a faint rule band across the row once arrows can show; the values are an ink line through the cells (a dot
// where a day stands alone); a day without a value is an empty cell, never a zero; today's cell is outlined.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

class FortnightRow extends StatelessWidget {
  const FortnightRow({
    super.key,
    required this.values,
    this.band,
    this.logScale = false,
    this.label,
    this.height = 40,
  });

  /// One value per day, oldest first, the last is today; null = no value that day.
  final List<double?> values;

  /// Your normal range (low, high), when known.
  final (double, double)? band;

  /// Powers and ratios are drawn on a log scale, as they are judged.
  final bool logScale;

  /// What a screen reader says for the row.
  final String? label;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    excludeSemantics: true,
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _FortnightPainter(values, band, logScale)),
    ),
  );
}

class _FortnightPainter extends CustomPainter {
  _FortnightPainter(this.values, this.band, this.logScale);
  final List<double?> values;
  final (double, double)? band;
  final bool logScale;

  static const double gap = 3;

  double _t(double v) => logScale ? math.log(math.max(v, 1e-9)) : v;

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    final cellW = (size.width - gap * (n - 1)) / n;
    double x(int i) => i * (cellW + gap) + cellW / 2;
    final cell = Paint()..color = Night.track;
    for (var i = 0; i < n; i++) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (cellW + gap), 0, cellW, size.height),
        const Radius.circular(6),
      );
      canvas.drawRRect(r, cell);
      if (i == n - 1) {
        canvas.drawRRect(
          r.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Night.inkMuted,
        );
      }
    }
    final present = [
      for (final v in values)
        if (v != null && v.isFinite && (!logScale || v > 0)) _t(v),
    ];
    if (present.isEmpty) return;
    var lo = present.reduce(math.min), hi = present.reduce(math.max);
    final b = band;
    if (b != null) {
      lo = math.min(lo, _t(b.$1));
      hi = math.max(hi, _t(b.$2));
    }
    if (hi - lo < 1e-9) {
      lo -= 1;
      hi += 1;
    }
    const pad = 7.0;
    double y(double v) => size.height - pad - (_t(v) - lo) / (hi - lo) * (size.height - 2 * pad);
    if (b != null) {
      final top = y(b.$2), bottom = y(b.$1);
      canvas.drawRect(
        Rect.fromLTRB(0, top, size.width, math.max(bottom, top + 1)),
        Paint()..color = Night.rule.withValues(alpha: 0.85),
      );
    }
    final line = Paint()
      ..color = Night.ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = Night.ink;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null || (logScale && v <= 0)) continue;
      final next = i + 1 < n ? values[i + 1] : null;
      if (next != null && (!logScale || next > 0)) {
        canvas.drawLine(Offset(x(i), y(v)), Offset(x(i + 1), y(next)), line);
      }
      canvas.drawCircle(Offset(x(i), y(v)), i == n - 1 ? 4 : 3, dot);
    }
  }

  @override
  bool shouldRepaint(_FortnightPainter old) => old.values != values || old.band != band;
}
