// The night's stages on the clock (the sleep report's chart): a step line through four worded levels on the
// track ground, hour rules like the watch strip's, missing data hatched amber (the strip's gap colour), and each
// sleep period a faint band numbered as in the period list below the chart. Under it, when the report has the
// detectors' extras, a Signal lane on the same clock: empty where the signal was clean, amber dots where the model
// read through noise, solid amber where no electrode was usable (DECISIONS 141).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../detectors/detectors.dart' show EpochQuality;
import '../sleep/periods.dart' show gapStage;
import 'theme.dart';

/// Top to bottom; light sleep is N1 and N2 together, as in the report.
const List<String> chartLevels = ['Awake', 'Dream', 'Light', 'Deep'];
const String signalLevel = 'Signal';

int? levelOf(String stage) => switch (stage) {
  'W' => 0,
  'R' => 1,
  'N1' || 'N2' => 2,
  'N3' => 3,
  _ => null,
};

class SleepChart extends StatelessWidget {
  const SleepChart({
    super.key,
    required this.start,
    required this.stages,
    this.periods = const [],
    this.quality,
    this.label,
  });

  /// The first epoch's start; one stage per 30 s.
  final DateTime start;
  final List<String> stages;

  /// (first, last) epoch of each sleep period, inclusive, numbered from 1 in this order.
  final List<(int, int)> periods;

  /// The detectors' signal quality per epoch (same clock as [stages]); null: no Signal lane.
  final List<EpochQuality?>? quality;

  /// What a screen reader says for the whole chart.
  final String? label;

  static const double laneHeight = 34;

  /// The Signal lane's height and its gap to the stages.
  static const double signalHeight = 18, signalGap = 8;

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
    final signal = quality == null ? 0.0 : signalGap + math.max(signalHeight, height(levelStyle) + 2);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: top + 4 * lane + signal + bottom,
        width: double.infinity,
        child: CustomPaint(
          painter: _ChartPainter(
            start: start,
            stages: stages,
            periods: periods,
            quality: quality,
            lane: lane,
            signal: signal,
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
    required this.quality,
    required this.lane,
    required this.signal,
    required this.top,
    required this.levelStyle,
    required this.tickStyle,
    required this.numberStyle,
    required this.scaler,
  });

  final DateTime start;
  final List<String> stages;
  final List<(int, int)> periods;
  final List<EpochQuality?>? quality;
  final double lane;

  /// Height of the Signal lane with its gap above (0: none).
  final double signal;
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
    final labels = [for (final l in [...chartLevels, if (quality != null) signalLevel]) _text(l, levelStyle)];
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
    final q = quality;
    if (q != null) {
      final lanePlot = Rect.fromLTRB(plot.left, plot.bottom + SleepChart.signalGap, plot.right, plot.bottom + signal);
      paintSignalLane(canvas, lanePlot, q, n);
      labels.last.paint(canvas, Offset(0, lanePlot.center.dy - labels.last.height / 2));
    }

    // level words on the left, numbers over the bands, clock times under the chart
    for (var i = 0; i < chartLevels.length; i++) {
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
      t.paint(canvas, Offset(lx, plot.bottom + signal + 6));
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
      old.stages != stages ||
      old.start != start ||
      old.periods != periods ||
      old.quality != quality ||
      old.scaler != scaler ||
      old.lane != lane;
}

/// Stretches of the same quality, (first epoch, end epoch, quality), for drawing.
Iterable<(int, int, EpochQuality)> qualityRuns(List<EpochQuality?> q, int n) sync* {
  var e = 0;
  final end = math.min(q.length, n);
  while (e < end) {
    final v = q[e];
    var f = e + 1;
    while (f < end && q[f] == v) {
      f++;
    }
    if (v != null && v != EpochQuality.good) yield (e, f, v);
    e = f;
  }
}

/// The Signal lane: the track ground, amber dots where the signal was noisy (degraded), solid amber where no
/// electrode was usable (missing). [n] epochs span the rect's width.
void paintSignalLane(Canvas canvas, Rect r, List<EpochQuality?> quality, int n) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(4));
  canvas.drawRRect(rr, Paint()..color = Night.track);
  canvas.save();
  canvas.clipRRect(rr);
  double x(num epoch) => r.left + r.width * epoch / n;
  final dot = Paint()..color = Night.caution.withValues(alpha: 0.85);
  final solid = Paint()..color = Night.caution.withValues(alpha: 0.6);
  final faint = Paint()..color = Night.caution.withValues(alpha: 0.18);
  for (final (a, b, q) in qualityRuns(quality, n)) {
    final span = Rect.fromLTRB(x(a), r.top, math.max(x(b), x(a) + 1.5), r.bottom);
    if (q == EpochQuality.missing) {
      canvas.drawRect(span, solid);
      continue;
    }
    // a faint amber ground (so a stretch of one or two epochs still shows) with dots on a fixed 4.5 dp grid, so
    // neighbouring stretches line up
    canvas.drawRect(span, faint);
    canvas.save();
    canvas.clipRect(span);
    const step = 4.5;
    for (var cx = (span.left / step).floor() * step + step / 2; cx < span.right + step / 2; cx += step) {
      for (var cy = r.top + step / 2; cy < r.bottom; cy += step) {
        canvas.drawCircle(Offset(cx, cy), 1.1, dot);
      }
    }
    canvas.restore();
  }
  canvas.restore();
}
