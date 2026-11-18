// Sleep pressure over the last day and a half (trends page): the estimate from the sleep log as an ink line on
// the track ground, the sleep periods as faint rule bands (as on the sleep chart), two worded levels (0 = after a
// regular night, 100 = a regular bedtime), hour rules every 6 hours, and now as a hairline with a dot. Where the
// log cannot tell, there is no line.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../trends/pressure.dart';
import 'theme.dart';

class PressureChart extends StatelessWidget {
  const PressureChart({super.key, required this.model, required this.now, this.hours = 36, this.label});
  final PressureModel model;
  final DateTime now;
  final int hours;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final tick = text.bodyMedium!.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final th = (TextPainter(text: TextSpan(text: '0', style: tick), textScaler: scaler, textDirection: TextDirection.ltr)
          ..layout())
        .height;
    final from = now.subtract(Duration(hours: hours));
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: 150 + th + 6,
        width: double.infinity,
        child: CustomPaint(
          painter: _PressurePainter(
            points: model.curve(from, now, step: const Duration(minutes: 10)),
            sleeps: model.sleepsBetween(from, now),
            from: from,
            to: now,
            tick: tick,
            scaler: scaler,
            tickHeight: th,
          ),
        ),
      ),
    );
  }
}

class _PressurePainter extends CustomPainter {
  _PressurePainter({
    required this.points,
    required this.sleeps,
    required this.from,
    required this.to,
    required this.tick,
    required this.scaler,
    required this.tickHeight,
  });

  final List<({DateTime t, double? level})> points;
  final List<SleepSpan> sleeps;
  final DateTime from, to;
  final TextStyle tick;
  final TextScaler scaler;
  final double tickHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - tickHeight - 6;
    final span = to.difference(from).inSeconds.toDouble();
    double x(DateTime t) => (t.difference(from).inSeconds / span).clamp(0.0, 1.0) * size.width;
    final levels = [
      for (final p in points)
        if (p.level != null) p.level!,
    ];
    final top = math.max(120.0, levels.isEmpty ? 0.0 : levels.reduce(math.max) + 10);
    final bottom = math.min(-15.0, levels.isEmpty ? 0.0 : levels.reduce(math.min) - 5);
    double y(double l) => (top - l) / (top - bottom) * h;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, h), const Radius.circular(6)),
      Paint()..color = Night.track,
    );
    final band = Paint()..color = Night.rule;
    for (final s in sleeps) {
      final a = x(s.start.isBefore(from) ? from : s.start), b = x(s.end.isAfter(to) ? to : s.end);
      canvas.drawRect(Rect.fromLTRB(a, 0, math.max(b, a + 1), h), band);
    }
    // hour rules every 6 hours, labelled with the clock under the chart
    final rule = Paint()
      ..color = Night.rule
      ..strokeWidth = 1;
    var t = DateTime(from.year, from.month, from.day, from.hour - from.hour % 6 + 6);
    while (t.isBefore(to)) {
      final px = x(t);
      canvas.drawLine(Offset(px, 0), Offset(px, h), rule);
      final tp = TextPainter(
        text: TextSpan(text: '${t.hour.toString().padLeft(2, '0')}:00', style: tick),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      final left = (px - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(left, h + 6));
      t = t.add(const Duration(hours: 6));
    }
    // the two worded levels
    for (final (level, word) in [(0.0, 'rested'), (100.0, 'regular bedtime')]) {
      final py = y(level);
      final dash = Paint()
        ..color = Night.inkMuted.withValues(alpha: 0.5)
        ..strokeWidth = 1;
      for (var dx = 0.0; dx < size.width; dx += 8) {
        canvas.drawLine(Offset(dx, py), Offset(math.min(dx + 4, size.width), py), dash);
      }
      final tp = TextPainter(
        text: TextSpan(text: word, style: tick.copyWith(fontSize: (tick.fontSize ?? 14) * 0.9)),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(6, py - tp.height - 1));
    }
    // the estimate
    final line = Paint()
      ..color = Night.ink
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    for (final p in points) {
      final l = p.level;
      if (l == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final o = Offset(x(p.t), y(l));
      path == null ? path = (Path()..moveTo(o.dx, o.dy)) : path.lineTo(o.dx, o.dy);
    }
    if (path != null) canvas.drawPath(path, line);
    // now
    final last = points.isEmpty ? null : points.last;
    canvas.drawLine(
      Offset(size.width - 1, 0),
      Offset(size.width - 1, h),
      Paint()
        ..color = Night.inkMuted
        ..strokeWidth = 1.5,
    );
    if (last?.level != null) canvas.drawCircle(Offset(size.width - 4, y(last!.level!)), 4.5, Paint()..color = Night.ink);
  }

  @override
  bool shouldRepaint(_PressurePainter old) => old.points != points || old.to != to;
}
