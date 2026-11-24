// The pulse lane (DECISIONS 815; DESIGN.md "Pulse lane"): a red line of the pulse a minute in its own lane under a
// time chart (the sleep report's chart, a recording's timeline in the Archive), worded "Pulse" at its left like the
// chart's other lanes, its scale's two ends in muted tabular figures at its right. Drawn only where an epoch has a
// reading: neighbouring readings are joined, a lone one is a short dash across its 30 s, and everything else is a gap.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The lane's word.
const String pulseLaneWord = 'Pulse';

/// A pass's readings on a clock: one per [epochS] seconds from [start]; null where there is none.
class PulseTrack {
  const PulseTrack({required this.start, required this.bpm, this.epochS = 30});
  final DateTime start;
  final List<double?> bpm;
  final double epochS;

  bool get hasReading => bpm.any((b) => b != null);
  DateTime get end => start.add(Duration(milliseconds: (bpm.length * epochS * 1000).round()));
}

/// The lane's scale: the readings' range widened to whole fives, at least 20 a minute tall.
(double, double) pulseScale(Iterable<double?> bpm) {
  final v = [for (final b in bpm) ?b];
  if (v.isEmpty) return (50, 70);
  var lo = (v.reduce(math.min) / 5).floorToDouble() * 5, hi = (v.reduce(math.max) / 5).ceilToDouble() * 5;
  while (hi - lo < 20) {
    lo -= 5;
    hi += 5;
  }
  return (lo, hi);
}

/// Paints the lane in [r]: the track ground, the line for epochs [x] places (x(e): the left edge of epoch e, so
/// x(e + 0.5) is its middle), and the scale's ends at the right in [scaleStyle].
void paintPulseLane(
  Canvas canvas,
  Rect r,
  List<double?> bpm,
  double Function(double epoch) x, {
  required TextStyle scaleStyle,
  required TextScaler scaler,
  (double, double)? scale,
}) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(4));
  canvas.drawRRect(rr, Paint()..color = Night.track);
  final (lo, hi) = scale ?? pulseScale(bpm);
  final pad = 4.0;
  double y(double b) => r.bottom - pad - (b - lo) / (hi - lo) * (r.height - 2 * pad);
  final line = Paint()
    ..color = Night.pulse
    ..strokeWidth = 2
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  canvas.save();
  canvas.clipRRect(rr);
  final path = Path();
  for (var e = 0; e < bpm.length; e++) {
    final b = bpm[e];
    if (b == null) continue;
    final prev = e > 0 ? bpm[e - 1] : null, next = e + 1 < bpm.length ? bpm[e + 1] : null;
    if (prev == null && next == null) {
      // a lone reading: a dash across its epoch, at least 3 dp wide
      final a = x(e.toDouble()), z = x(e + 1.0), mid = (a + z) / 2, half = math.max(1.5, (z - a) / 2);
      path
        ..moveTo(mid - half, y(b))
        ..lineTo(mid + half, y(b));
      continue;
    }
    if (prev == null) {
      path.moveTo(x(e + 0.5), y(b));
    } else {
      path.lineTo(x(e + 0.5), y(b));
    }
  }
  canvas.drawPath(path, line);
  canvas.restore();
  TextPainter t(String s) =>
      TextPainter(text: TextSpan(text: s, style: scaleStyle), textScaler: scaler, textDirection: TextDirection.ltr)..layout();
  final top = t('${hi.round()}'), bottom = t('${lo.round()}');
  if (top.height + bottom.height <= r.height + 2) {
    top.paint(canvas, Offset(r.right - top.width - 3, r.top + 1));
    bottom.paint(canvas, Offset(r.right - bottom.width - 3, r.bottom - bottom.height - 1));
  }
}

/// The legend's swatch: a short red line and its words.
class PulseSwatch extends StatelessWidget {
  const PulseSwatch({super.key, this.words = 'pulse a minute, where it could be read'});
  final String words;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(size: const Size(18, 14), painter: _LineSwatch()),
      const SizedBox(width: 8),
      Text(words, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted)),
    ],
  );
}

class _LineSwatch extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Night.pulse
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(1, size.height * 0.65), Offset(size.width / 2, size.height * 0.35), p);
    canvas.drawLine(Offset(size.width / 2, size.height * 0.35), Offset(size.width - 1, size.height * 0.5), p);
  }

  @override
  bool shouldRepaint(_LineSwatch old) => false;
}

/// The sleep report's pulse line: "Pulse while asleep: about 55/min (read in 22 % of the night)", its "i", the lowest 5
/// minutes and the honest note.
class PulseAsleepLine extends StatelessWidget {
  const PulseAsleepLine({super.key, required this.words, this.lowest, this.onInfo});
  final String words;
  final String? lowest;
  final VoidCallback? onInfo;

  /// Under every pulse number (DECISIONS 816).
  static const String note = 'An experiment: the pulse your heartbeat leaves in the headband\'s signal, read where it '
      'shows; not yet checked against a watch.';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(words, style: text.bodyLarge?.copyWith(fontFeatures: tabular, height: 1.4)),
                ),
              ),
              IconButton(onPressed: onInfo, tooltip: 'About the pulse', icon: const Icon(Icons.info_outline)),
            ],
          ),
          if (lowest != null) Text(lowest!, style: text.bodyLarge?.copyWith(fontFeatures: tabular, height: 1.4)),
          const SizedBox(height: 4),
          Text(note, style: text.bodyMedium?.copyWith(color: Night.inkMuted, height: 1.4)),
        ],
      ),
    );
  }
}
