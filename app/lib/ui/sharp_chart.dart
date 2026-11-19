// The sharp-hours chart (.impeccable/surfaces/app-lib-ui-sharp-hours-screen-dart.md): the answers by block on the
// track ground, one column per block (2 hours of the clock, 2 hours since waking, or a quarter of the
// sleep-pressure scale). Ratings sit on five worded levels, Foggy to Very sharp, as ink dots side by side, so a
// count reads as a row of dots; reaction times as dots at their milliseconds. Once the page may show a pattern,
// each block with enough answers gets its 80 % range as a faint rule band (the best block's outlined) and its
// mean as an ink tick; a block without enough keeps only its dots. The block edges are labelled under the columns.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sharp/hours.dart';
import '../sharp/store.dart' show sharpWords;
import 'theme.dart';

/// The columns an axis shows: the clock only inside [fromHour]..[untilHour] (plus any block with answers);
/// hours since waking and sleep pressure in full.
List<int> chartBlocks(SharpAxis axis, List<SharpPoint> points, {int fromMin = 600, int untilMin = 1320}) {
  final have = {for (final p in points) p.block};
  if (axis != SharpAxis.clock) return [for (var b = 0; b < blockCount(axis); b++) b];
  final inWindow = <int>{};
  final len = ((untilMin - fromMin) % 1440 + 1440) % 1440;
  for (var m = 0; m < len; m += 30) {
    inWindow.add(((fromMin + m) % 1440) ~/ 120);
  }
  final all = {...inWindow, ...have}.toList()..sort();
  // a window past midnight: the evening's blocks first, then the small hours
  if (fromMin > untilMin && all.isNotEmpty) {
    final start = fromMin ~/ 120;
    return [...all.where((b) => b >= start), ...all.where((b) => b < start)];
  }
  return all;
}

class SharpChart extends StatelessWidget {
  const SharpChart({
    super.key,
    required this.axis,
    required this.points,
    required this.blocks,
    this.profile,
    this.reaction = false,
    required this.label,
    this.fromMin = 600,
    this.untilMin = 1320,
  });

  final SharpAxis axis;
  final List<SharpPoint> points;
  final List<int> blocks;
  final SharpProfile? profile;

  /// Reaction times (ms, quicker at the top) instead of 1-5 ratings.
  final bool reaction;
  final String label;

  /// The waking window: the clock's end ticks show where the questions start and stop.
  final int fromMin, untilMin;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final tick = text.bodySmall!.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    TextPainter tp(String s, [TextStyle? st]) =>
        TextPainter(text: TextSpan(text: s, style: st ?? tick), textScaler: scaler, textDirection: TextDirection.ltr)..layout();
    // one gutter for both charts, so the ratings' and the reaction times' columns line up
    final gutter = [sharpWords.last, sharpWords.first, 'quicker', 'slower'].map((w) => tp(w).width).reduce(math.max) + 10;
    final th = tp('0').height;
    final plot = reaction ? 120.0 : 168.0;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: plot + th + 8,
        width: double.infinity,
        child: CustomPaint(
          painter: _ChartPainter(
            axis: axis,
            points: points,
            blocks: blocks,
            profile: profile,
            reaction: reaction,
            tick: tick,
            scaler: scaler,
            gutter: gutter,
            plot: plot,
            fromMin: fromMin,
            untilMin: untilMin,
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.axis,
    required this.points,
    required this.blocks,
    required this.profile,
    required this.reaction,
    required this.tick,
    required this.scaler,
    required this.gutter,
    required this.plot,
    required this.fromMin,
    required this.untilMin,
  });

  final SharpAxis axis;
  final List<SharpPoint> points;
  final List<int> blocks;
  final SharpProfile? profile;
  final bool reaction;
  final TextStyle tick;
  final TextScaler scaler;
  final double gutter, plot;
  final int fromMin, untilMin;

  TextPainter _tp(String s, TextStyle st) =>
      TextPainter(text: TextSpan(text: s, style: st), textScaler: scaler, textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (blocks.isEmpty) return;
    final left = gutter, w = size.width - gutter;
    final colW = w / blocks.length;
    final ground = RRect.fromRectAndRadius(Rect.fromLTWH(left, 0, w, plot), const Radius.circular(6));
    canvas.drawRRect(ground, Paint()..color = Night.track);
    final rule = Paint()
      ..color = Night.rule
      ..strokeWidth = 1;
    // levels: five worded ratings, or the reaction times' own span (quicker at the top)
    double lo, hi;
    if (reaction) {
      final v = [for (final p in points) p.value];
      final pr = profile;
      if (pr != null) {
        for (final b in pr.blocks) {
          if (b.low != null) v.addAll([b.low!, b.high!]);
        }
      }
      lo = v.isEmpty ? 250 : v.reduce(math.min);
      hi = v.isEmpty ? 400 : v.reduce(math.max);
      final pad = math.max(10.0, (hi - lo) * 0.12);
      lo -= pad;
      hi += pad;
    } else {
      lo = 0.5;
      hi = 5.5;
    }
    // reaction: quicker (lower ms) up; ratings: sharper (higher) up
    double y(double v) => reaction ? (v - lo) / (hi - lo) * plot : (hi - v) / (hi - lo) * plot;
    if (!reaction) {
      for (var v = 1; v <= 5; v++) {
        canvas.drawLine(Offset(left, y(v.toDouble())), Offset(left + w, y(v.toDouble())), rule..color = Night.ground);
      }
      rule.color = Night.rule;
    }
    for (var i = 1; i < blocks.length; i++) {
      canvas.drawLine(Offset(left + i * colW, 0), Offset(left + i * colW, plot), Paint()..color = Night.ground..strokeWidth = 2);
    }
    // the two worded ends
    final top = _tp(reaction ? 'quicker' : sharpWords.last, tick), bottom = _tp(reaction ? 'slower' : sharpWords.first, tick);
    top.paint(canvas, Offset(0, (reaction ? 0 : y(5)) - (reaction ? 0 : top.height / 2)).translate(0, reaction ? 2 : 0));
    bottom.paint(canvas, Offset(0, (reaction ? plot - bottom.height - 2 : y(1) - bottom.height / 2)));
    // ranges and means, once shown
    final shown = {
      for (final b in profile?.blocks ?? const <SharpBlock>[])
        if (b.shown) b.index: b,
    };
    final best = {for (final b in profile?.best?.blocks ?? const <SharpBlock>[]) b.index};
    final band = Paint()..color = Night.rule;
    final bestEdge = Paint()
      ..color = Night.inkMuted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final (i, b) in blocks.indexed) {
      final blk = shown[b];
      if (blk == null) continue;
      final cx = left + (i + 0.5) * colW;
      final half = colW * 0.34;
      final y1 = y(blk.low!), y2 = y(blk.high!);
      final rr = RRect.fromRectAndRadius(Rect.fromLTRB(cx - half, math.min(y1, y2) - 2, cx + half, math.max(y1, y2) + 2), const Radius.circular(3));
      canvas.drawRRect(rr, band);
      if (best.contains(b)) canvas.drawRRect(rr, bestEdge);
      canvas.drawLine(Offset(cx - half, y(blk.mean!)), Offset(cx + half, y(blk.mean!)), Paint()..color = Night.ink..strokeWidth = 2.5);
    }
    // the answers as dots: ratings side by side per level (a count reads as a row), reaction times at their value
    // dots in ink while they are all there is; muted once the ranges and means carry the page
    final dot = Paint()..color = shown.isEmpty ? Night.ink : Night.inkMuted;
    final byCell = <(int, int), int>{};
    final r = math.min(2.6, colW / 14);
    for (final p in points) {
      final i = blocks.indexOf(p.block);
      if (i < 0) continue;
      final cx = left + (i + 0.5) * colW;
      if (reaction) {
        final k = byCell.update((i, p.value ~/ 8), (n) => n + 1, ifAbsent: () => 0);
        final dx = ((k % 5) - 2) * (r * 2.4);
        canvas.drawCircle(Offset(cx + dx, y(p.value)), r, dot);
      } else {
        final v = p.value.round();
        final k = byCell.update((i, v), (n) => n + 1, ifAbsent: () => 0);
        // fill outward from the column's middle, up to its width, then a second row just above
        final perRow = math.max(1, ((colW * 0.8) / (r * 2.4)).floor());
        final row = k ~/ perRow, pos = k % perRow;
        final offset = (pos.isEven ? pos ~/ 2 : -(pos + 1) ~/ 2) * (r * 2.4);
        canvas.drawCircle(Offset(cx + offset, y(v.toDouble()) - row * r * 2.4), r, dot);
      }
    }
    // the block edges under the columns, as on any axis: 10 12 14 ... (hours), 0 2 4 ... (hours awake), 25 50 75 100
    double edge(int b) => switch (axis) {
      SharpAxis.clock => (b * 2 % 24).toDouble(),
      SharpAxis.sinceWake => b * 2.0,
      SharpAxis.pressure => b * 25.0,
    };
    // labels never touch: the two ends first, then the inner edges that leave a gap to everything drawn
    final taken = <(double, double)>[];
    void label(double x, String s, {double align = 0.5}) {
      final t = _tp(s, tick);
      final x0 = (x - t.width * align).clamp(0.0, size.width - t.width), x1 = x0 + t.width;
      if (taken.any((r) => x0 < r.$2 + 4 && x1 > r.$1 - 4)) return;
      taken.add((x0, x1));
      t.paint(canvas, Offset(x0, plot + 6));
    }

    String fmt(double v) => v.round().toString();
    switch (axis) {
      case SharpAxis.pressure:
        label(left, 'rested', align: 0);
      case SharpAxis.sinceWake:
        label(left, fmt(edge(blocks.first)), align: 0);
      case SharpAxis.clock:
        // the ends where the questions start and stop (no question is asked outside the waking window)
        final first = blocks.first * 120, last = blocks.last * 120 + 120;
        final from = fromMin > first && fromMin < first + 120 ? fromMin : first;
        final until = untilMin > last - 120 && untilMin < last ? untilMin : last;
        String hm(int m) => m % 60 == 0 ? '${(m ~/ 60) == 24 ? 24 : (m ~/ 60) % 24}' : '${(m ~/ 60) % 24}:${(m % 60).toString().padLeft(2, '0')}';
        label(left, hm(from), align: 0);
        label(left + w, hm(until), align: 1);
    }
    for (var i = 1; i < blocks.length; i++) {
      // the pressure scale's 100 is a regular bedtime: worded, as on the Trends chart
      label(left + i * colW, axis == SharpAxis.pressure && blocks[i] == 4 ? 'bedtime' : fmt(edge(blocks[i])));
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.points != points || old.profile != profile || old.blocks != blocks || old.axis != axis || old.scaler != scaler;
}
