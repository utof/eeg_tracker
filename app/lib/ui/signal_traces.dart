// The Signal view's traces (DECISIONS 594): one channel's scrolling line on the `track` ground, all channels stacked for
// the raw data, and the band strip. They read signal/live_signal.dart when [LiveSignal]'s frame tick moves (at most 15
// times a second) and draw at most two points per pixel column (the lowest and the highest), so 16 channels stay smooth.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../signal/live_signal.dart';
import 'theme.dart';

/// The scale of a trace: [uv] ± microvolts, null = fitted to what is shown.
typedef TraceScale = double?;

/// The window a trace shows: [seconds] ending at [end] (an absolute sample index; null = the newest).
typedef TraceWindow = ({int seconds, int? end});

/// The values a trace would draw, and its scale.
({Float32List values, double scale}) traceData(
  LiveSignal s,
  int channel,
  TraceFilter filter,
  TraceWindow w,
  TraceScale scale,
) {
  final values = s.window(channel, filter, w.seconds * s.rate, end: w.end);
  return (values: values, scale: scale ?? autoScaleUv(values));
}

/// '±200 µV', '±1 mV'.
String scaleWords(double uv) => uv >= 1000 ? '±${_trim(uv / 1000)} mV' : '±${_trim(uv)} µV';

String _trim(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Draws [values] around their mean, ±[scale] filling [rect]; two points per column at most.
void paintTrace(Canvas canvas, Rect rect, Float32List values, double scale, {Color color = Night.ink, int? slots}) {
  if (values.length < 2 || scale <= 0) return;
  var mean = 0.0;
  for (final v in values) {
    mean += v;
  }
  mean /= values.length;
  final n = values.length;
  final total = slots ?? n;
  final cols = math.max(1, rect.width.floor());
  final mid = rect.center.dy, half = rect.height / 2;
  double y(double v) => (mid - (v - mean) / scale * half).clamp(rect.top, rect.bottom);
  // the newest sample sits at the right edge; a shorter window starts further right
  final x0 = rect.left + rect.width * (total - n) / total;
  final perCol = total / cols;
  final path = Path();
  var started = false;
  if (perCol <= 2) {
    for (var i = 0; i < n; i++) {
      final x = x0 + i * rect.width / (total - 1).clamp(1, 1 << 30);
      final p = Offset(x, y(values[i]));
      started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      started = true;
    }
  } else {
    for (var c = 0; c < cols; c++) {
      final a = (c * perCol - (total - n)).floor(), b = ((c + 1) * perCol - (total - n)).floor();
      if (b <= 0 || a >= n) continue;
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var i = math.max(0, a); i < math.min(n, b); i++) {
        lo = math.min(lo, values[i]);
        hi = math.max(hi, values[i]);
      }
      if (!lo.isFinite) continue;
      final x = rect.left + c + 0.5;
      if (!started) {
        path.moveTo(x, y(hi));
        started = true;
      } else {
        path.lineTo(x, y(hi));
      }
      path.lineTo(x, y(lo));
    }
  }
  canvas.save();
  canvas.clipRect(rect);
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round,
  );
  canvas.restore();
}

void _ground(Canvas canvas, Rect rect) {
  canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)), Paint()..color = Night.track);
  canvas.drawLine(
    Offset(rect.left + 6, rect.center.dy),
    Offset(rect.right - 6, rect.center.dy),
    Paint()
      ..color = Night.rule
      ..strokeWidth = 1,
  );
}

/// One channel's trace.
class TracePainter extends CustomPainter {
  TracePainter({
    required this.signal,
    required this.channel,
    required this.filter,
    required this.window,
    this.scale,
    super.repaint,
  });

  final LiveSignal signal;
  final int channel;
  final TraceFilter filter;
  final TraceWindow window;
  final TraceScale scale;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    _ground(canvas, rect);
    final d = traceData(signal, channel, filter, window, scale);
    paintTrace(canvas, rect.deflate(4), d.values, d.scale, slots: window.seconds * signal.rate);
  }

  @override
  bool shouldRepaint(TracePainter old) =>
      old.signal != signal ||
      old.channel != channel ||
      old.filter != filter ||
      old.window != window ||
      old.scale != scale;
}

/// One channel's trace as a widget, [height] tall, repainting on [frames].
class TraceBox extends StatelessWidget {
  const TraceBox({
    super.key,
    required this.signal,
    required this.channel,
    required this.frames,
    this.filter = TraceFilter.band,
    this.window = (seconds: 5, end: null),
    this.scale,
    this.height = 84,
    this.label,
  });

  final LiveSignal signal;
  final int channel;
  final Listenable frames;
  final TraceFilter filter;
  final TraceWindow window;
  final TraceScale scale;
  final double height;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label ?? '${signal.names[channel]} trace',
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size(double.infinity, height),
        painter: TracePainter(
          signal: signal,
          channel: channel,
          filter: filter,
          window: window,
          scale: scale,
          repaint: frames,
        ),
      ),
    ),
  );
}

/// The scale of a trace in words, kept up to date.
class ScaleLabel extends StatelessWidget {
  const ScaleLabel({
    super.key,
    required this.signal,
    required this.channel,
    required this.frames,
    required this.filter,
    required this.window,
    this.scale,
  });

  final LiveSignal signal;
  final int channel;
  final Listenable frames;
  final TraceFilter filter;
  final TraceWindow window;
  final TraceScale scale;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: frames,
    builder: (context, _) => Text(
      scaleWords(traceData(signal, channel, filter, window, scale).scale),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
    ),
  );
}

/// Every channel stacked, as it came (each around its own mean, its own scale at the right), [rowHeight] a row.
class StackedPainter extends CustomPainter {
  StackedPainter({
    required this.signal,
    required this.window,
    required this.label,
    this.rowHeight = 40,
    this.nameWidth = 44,
    this.scaleWidth = 64,
    super.repaint,
  });

  final LiveSignal signal;
  final TraceWindow window;
  final double rowHeight;
  final double nameWidth;
  final double scaleWidth;

  /// A laid-out muted label (cached by the view).
  final TextPainter Function(String text, {bool muted}) label;

  @override
  void paint(Canvas canvas, Size size) {
    final traceRect = Rect.fromLTWH(nameWidth, 0, size.width - nameWidth - scaleWidth, size.height);
    canvas.drawRRect(RRect.fromRectAndRadius(traceRect, const Radius.circular(6)), Paint()..color = Night.track);
    for (var c = 0; c < signal.channels; c++) {
      final row = Rect.fromLTWH(traceRect.left, c * rowHeight, traceRect.width, rowHeight);
      if (c > 0) {
        canvas.drawLine(
          row.topLeft,
          row.topRight,
          Paint()
            ..color = Night.ground
            ..strokeWidth = 1,
        );
      }
      final d = traceData(signal, c, TraceFilter.raw, window, null);
      paintTrace(canvas, row.deflate(3), d.values, d.scale, slots: window.seconds * signal.rate);
      final name = label(signal.names[c]);
      name.paint(canvas, Offset(0, row.center.dy - name.height / 2));
      final sc = label(scaleWords(d.scale), muted: true);
      sc.paint(canvas, Offset(size.width - sc.width, row.center.dy - sc.height / 2));
    }
  }

  @override
  bool shouldRepaint(StackedPainter old) => old.signal != signal || old.window != window || old.rowHeight != rowHeight;
}

/// Delta, theta, alpha and beta as one bar split by their shares, in four steps of ink (no colour means anything; the
/// words under it say the shares).
class BandStrip extends StatelessWidget {
  const BandStrip({super.key, required this.shares});

  /// Four shares adding up to 1, or null (not enough signal yet).
  final List<double>? shares;

  static const List<Color> _tones = [Night.saved, Night.inkMuted, Night.ink, Night.rule];
  static const List<String> _names = ['Delta', 'Theta', 'Alpha', 'Beta'];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final s = shares;
    if (s == null || s.length != 4) return Text('Bands: none yet (under 2 s, or no signal).', style: muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (var i = 0; i < 4; i++)
                  if (s[i] > 0.005)
                    Expanded(
                      flex: math.max(1, (s[i] * 1000).round()),
                      child: Container(
                        margin: EdgeInsets.only(right: i < 3 ? 2 : 0),
                        color: _tones[i],
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('${[for (var i = 0; i < 4; i++) '${_names[i]} ${(s[i] * 100).round()}'].join(' · ')} %', style: muted),
      ],
    );
  }
}
