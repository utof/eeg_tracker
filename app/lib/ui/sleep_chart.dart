// The night's stages on the clock (the sleep report's chart): a step line through four worded levels on the
// track ground, hour rules like the watch strip's, missing data hatched amber (the strip's gap colour), and each
// sleep period a faint band numbered as in the period list below the chart.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sleep/periods.dart' show gapStage;
import 'theme.dart';

/// Top to bottom; light sleep is N1 and N2 together, as in the report.
const List<String> chartLevels = ['Awake', 'Dream', 'Light', 'Deep'];

int? levelOf(String stage) => switch (stage) {
  'W' => 0,
  'R' => 1,
  'N1' || 'N2' => 2,
  'N3' => 3,
  _ => null,
};

class SleepChart extends StatelessWidget {
  const SleepChart({super.key, required this.start, required this.stages, this.periods = const [], this.label});

  /// The first epoch's start; one stage per 30 s.
  final DateTime start;
  final List<String> stages;

  /// (first, last) epoch of each sleep period, inclusive, numbered from 1 in this order.
  final List<(int, int)> periods;

  /// What a screen reader says for the whole chart.
  final String? label;

  static const double laneHeight = 34;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final levelStyle = text.bodyMedium!.copyWith(color: Night.inkMuted);
    final tickStyle = text.bodyMedium!.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final numberStyle = text.titleSmall!.copyWith(color: Night.ink, fontFeatures: tabular);
    double height(TextStyle s) => (TextPainter(
      text: TextSpan(text: '0', style: s),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
    )..layout()).height;
    final lane = math.max(laneHeight, height(levelStyle) + 8);
    final top = height(numberStyle) + 6;
    final bottom = height(tickStyle) + 6;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: top + 4 * lane + bottom,
        width: double.infinity,
        child: CustomPaint(
          painter: _ChartPainter(
            start: start,
            stages: stages,
            periods: periods,
            lane: lane,
            top: top,
            levelStyle: levelStyle,
            tickStyle: tickStyle,
            numberStyle: numberStyle,
            scaler: scaler,
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.start,
    required this.stages,
    required this.periods,
    required this.lane,
    required this.top,
    required this.levelStyle,
    required this.tickStyle,
    required this.numberStyle,
    required this.scaler,
  });

  final DateTime start;
  final List<String> stages;
  final List<(int, int)> periods;
  final double lane;
  final double top;
  final TextStyle levelStyle;
  final TextStyle tickStyle;
  final TextStyle numberStyle;
  final TextScaler scaler;

  TextPainter _text(String s, TextStyle style) =>
      TextPainter(text: TextSpan(text: s, style: style), textScaler: scaler, textDirection: TextDirection.ltr)
        ..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final labels = [for (final l in chartLevels) _text(l, levelStyle)];
    final left = labels.map((t) => t.width).reduce(math.max) + 12;
    final plot = Rect.fromLTWH(left, top, size.width - left, 4 * lane);
    final n = stages.length;
    if (n == 0 || plot.width <= 0) return;
    double x(num epoch) => plot.left + plot.width * epoch / n;

    // ground, then the sleep periods as faint bands numbered above the chart
    canvas.drawRRect(RRect.fromRectAndRadius(plot, const Radius.circular(6)), Paint()..color = Night.track);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(plot, const Radius.circular(6)));
    for (var i = 0; i < periods.length; i++) {
      final (a, b) = periods[i];
      canvas.drawRect(Rect.fromLTRB(x(a), plot.top, x(b + 1), plot.bottom), Paint()..color = Night.rule);
    }
    // missing data: amber hatching, the watch strip's gap colour
    final hatch = Paint()
      ..color = Night.caution.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (var e = 0; e < n; e++) {
      if (stages[e] != gapStage) continue;
      var f = e;
      while (f < n && stages[f] == gapStage) {
        f++;
      }
      final r = Rect.fromLTRB(x(e), plot.top, math.max(x(f), x(e) + 2), plot.bottom);
      canvas.drawRect(r, Paint()..color = Night.caution.withValues(alpha: 0.14));
      canvas.save();
      canvas.clipRect(r);
      for (var d = r.left - plot.height; d < r.right; d += 6) {
        canvas.drawLine(Offset(d, plot.bottom), Offset(d + plot.height, plot.top), hatch);
      }
      canvas.restore();
      e = f - 1;
    }
    // hour rules
    final rule = Paint()
      ..color = Night.ground.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final ticks = _ticks(n);
    for (final t in ticks) {
      canvas.drawLine(Offset(x(t.$1), plot.top), Offset(x(t.$1), plot.bottom), rule);
    }
    // the stages: one step line in ink, broken where data is missing
    final line = Paint()
      ..color = Night.ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt;
    double y(int level) => plot.top + lane * (level + 0.5);
    final path = Path();
    int? prev;
    for (var e = 0; e < n; e++) {
      final l = levelOf(stages[e]);
      if (l == null) {
        prev = null;
        continue;
      }
      if (prev == null) {
        path.moveTo(x(e), y(l));
      } else if (prev != l) {
        path.lineTo(x(e), y(l));
      }
      path.lineTo(x(e + 1), y(l));
      prev = l;
    }
    canvas.drawPath(path, line);
    canvas.restore();

    // level words on the left, numbers over the bands, clock times under the chart
    for (var i = 0; i < 4; i++) {
      labels[i].paint(canvas, Offset(0, plot.top + lane * (i + 0.5) - labels[i].height / 2));
    }
    for (var i = 0; i < periods.length; i++) {
      final (a, b) = periods[i];
      final t = _text('${i + 1}', numberStyle);
      final cx = (x(a) + x(b + 1)) / 2;
      t.paint(canvas, Offset((cx - t.width / 2).clamp(plot.left, size.width - t.width), 0));
    }
    double lastRight = -1;
    for (final (epoch, words) in ticks) {
      final t = _text(words, tickStyle);
      final lx = (x(epoch) - t.width / 2).clamp(plot.left, size.width - t.width);
      if (lx < lastRight + 8) continue; // never let two times touch
      t.paint(canvas, Offset(lx, plot.bottom + 6));
      lastRight = lx + t.width;
    }
  }

  /// Whole hours inside the night: every hour up to 6 hours, every 2 up to 12, else every 3.
  List<(int, String)> _ticks(int n) {
    final hours = n / 120;
    final step = hours <= 6 ? 1 : (hours <= 12 ? 2 : 3);
    final out = <(int, String)>[];
    var t = DateTime(start.year, start.month, start.day, start.hour).add(const Duration(hours: 1));
    final end = start.add(Duration(seconds: 30 * n));
    while (t.isBefore(end)) {
      if (t.hour % step == 0) {
        final epoch = t.difference(start).inSeconds / 30;
        out.add((epoch.round(), '${t.hour.toString().padLeft(2, '0')}:00'));
      }
      t = t.add(const Duration(hours: 1));
    }
    return out;
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.stages != stages || old.start != start || old.periods != periods || old.scaler != scaler || old.lane != lane;
}
