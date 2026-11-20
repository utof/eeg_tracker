// A recording's timeline (DECISIONS 700-709; DESIGN.md "Activity lanes"): the sleep chart's `track` lanes on the
// recording's clock, one per activity, each worded at its left, so a tone always repeats a word. Bands in `saved` (found),
// a lighter `saved` (weaker: getting drowsy, noisy, a break), `caution` amber (no signal, like the watch strip's gaps)
// and `ink` (your tags), with their word inside when it fits. Hour rules and tabular clock ticks under the lanes.
// Zoom with two fingers or the buttons, drag sideways to move; a tap on a band opens it, a tap anywhere else opens the
// signal at that moment. One finger dragging up or down scrolls the page as usual.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../archive/bands.dart';
import 'archive_view.dart' show hm, lengthText;
import 'theme.dart';

class TimelineView extends StatefulWidget {
  const TimelineView({super.key, required this.timeline, this.onBand, this.onTime});
  final Timeline timeline;
  final ValueChanged<Band>? onBand;
  final ValueChanged<DateTime>? onTime;

  @override
  State<TimelineView> createState() => TimelineViewState();
}

/// The shortest stretch the timeline zooms into.
const Duration minView = Duration(minutes: 2);

class TimelineViewState extends State<TimelineView> {
  late DateTime _from = widget.timeline.start;
  late Duration _len = _whole;
  final Map<int, Offset> _pointers = {};
  double _width = 1;

  Duration get _whole {
    final l = widget.timeline.length;
    return l < minView ? minView : l;
  }

  DateTime get from => _from;
  Duration get shown => _len;

  @override
  void didUpdateWidget(TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeline.start != widget.timeline.start || oldWidget.timeline.end != widget.timeline.end) {
      _from = widget.timeline.start;
      _len = _whole;
    }
  }

  void _set(DateTime from, Duration len) {
    final whole = _whole;
    final l = len < minView ? minView : (len > whole ? whole : len);
    final latest = widget.timeline.start.add(whole - l);
    var f = from.isBefore(widget.timeline.start) ? widget.timeline.start : from;
    if (f.isAfter(latest)) f = latest;
    if (f != _from || l != _len) {
      setState(() {
        _from = f;
        _len = l;
      });
    }
  }

  /// Zooms by [factor] (over 1: closer) keeping the moment at [fraction] of the width in place.
  void zoom(double factor, {double fraction = 0.5}) {
    final at = _from.add(_len * fraction);
    final len = Duration(microseconds: (_len.inMicroseconds / factor).round());
    _set(at.subtract(len * fraction), len);
  }

  void showWhole() => _set(widget.timeline.start, _whole);

  void _pan(double dx) => _set(_from.subtract(Duration(microseconds: (dx / _width * _len.inMicroseconds).round())), _len);

  void _pointerMove(PointerMoveEvent e) {
    if (_pointers.length == 2 && _pointers.containsKey(e.pointer)) {
      final other = _pointers.entries.firstWhere((p) => p.key != e.pointer).value;
      final before = (_pointers[e.pointer]!.dx - other.dx).abs(), after = (e.localPosition.dx - other.dx).abs();
      if (before > 20 && after > 20) zoom(after / before, fraction: ((e.localPosition.dx + other.dx) / 2 / _width).clamp(0.0, 1.0));
    }
    _pointers[e.pointer] = e.localPosition;
  }

  DateTime _timeAt(double x) => _from.add(Duration(microseconds: (x / _width * _len.inMicroseconds).round()));

  void _tap(Offset p, _Geometry g) {
    final t = _timeAt(p.dx);
    final lane = g.laneAt(p.dy);
    if (lane != null) {
      // a narrow band is hit within 8 dp of it
      final slack = Duration(microseconds: (8 / _width * _len.inMicroseconds).round());
      Band? hit = bandAt(widget.timeline, lane, t);
      hit ??= [
        for (final b in widget.timeline.of(lane))
          if (!t.isBefore(b.start.subtract(slack)) && t.isBefore(b.end.add(slack))) b,
      ].firstOrNull;
      if (hit != null) {
        widget.onBand?.call(hit);
        return;
      }
    }
    widget.onTime?.call(t);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = text.bodyMedium!.copyWith(color: Night.inkMuted);
    final tickStyle = text.bodyMedium!.copyWith(color: Night.inkMuted, fontFeatures: tabular);
    final bandStyle = text.labelMedium!.copyWith(color: Night.ground, fontFeatures: tabular);
    double height(TextStyle s) =>
        (TextPainter(text: TextSpan(text: '0', style: s), textScaler: scaler, textDirection: TextDirection.ltr)..layout()).height;
    final laneH = math.max(26.0, height(labelStyle) + 6);
    final g = _Geometry(laneH: laneH, gap: 6, lanes: lanes.length);
    final labelW = scaler.scale(96).clamp(96.0, 140.0);
    final tickH = height(tickStyle) + 8;
    final end = _from.add(_len);
    final tl = widget.timeline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _len >= _whole ? 'The whole recording, ${lengthText(tl.length)}' : '${hm(_from)} – ${hm(end)}, ${lengthText(_len)} shown',
                style: text.bodyMedium?.copyWith(color: Night.inkMuted, fontFeatures: tabular),
              ),
            ),
            IconButton(
              tooltip: 'Zoom out',
              onPressed: _len >= _whole ? null : () => zoom(0.5),
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              tooltip: 'Zoom in',
              onPressed: _len <= minView ? null : () => zoom(2),
              icon: const Icon(Icons.zoom_in),
            ),
            IconButton(
              tooltip: 'The whole recording',
              onPressed: _len >= _whole ? null : showWhole,
              icon: const Icon(Icons.fit_screen_outlined),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Semantics(
          label: _describe(tl),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: labelW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in lanes)
                      SizedBox(
                        height: laneH + g.gap,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(l.word, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    _width = math.max(1, c.maxWidth);
                    return Listener(
                      onPointerDown: (e) => _pointers[e.pointer] = e.localPosition,
                      onPointerMove: _pointerMove,
                      onPointerUp: (e) => _pointers.remove(e.pointer),
                      onPointerCancel: (e) => _pointers.remove(e.pointer),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (d) => _pointers.length > 1 ? null : _pan(d.delta.dx),
                        onTapUp: (d) => _tap(d.localPosition, g),
                        child: CustomPaint(
                          size: Size(c.maxWidth, g.height + tickH),
                          painter: _LanesPainter(
                            timeline: tl,
                            from: _from,
                            length: _len,
                            g: g,
                            tickStyle: tickStyle,
                            bandStyle: bandStyle,
                            scaler: scaler,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _describe(Timeline tl) {
    final parts = [
      for (final l in lanes)
        if (tl.of(l).isNotEmpty) '${l.word}: ${tl.of(l).length} ${tl.of(l).length == 1 ? 'stretch' : 'stretches'}, ${lengthText(tl.total(l))}',
    ];
    return 'Timeline from ${hm(tl.start)} to ${hm(tl.end)}. ${parts.isEmpty ? 'Nothing found yet.' : parts.join('. ')}. '
        'The Found section below lists the same.';
  }
}

class _Geometry {
  const _Geometry({required this.laneH, required this.gap, required this.lanes});
  final double laneH, gap;
  final int lanes;

  double get height => lanes * (laneH + gap);
  double top(int i) => i * (laneH + gap) + gap / 2;

  Lane? laneAt(double y) {
    final i = (y / (laneH + gap)).floor();
    return i >= 0 && i < lanes ? Lane.values[i] : null;
  }
}

/// Minutes between clock ticks, the first that leaves 64 dp between them.
int tickMinutes(Duration shown, double width) {
  const steps = [1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360, 720];
  for (final s in steps) {
    if (shown.inSeconds / 60 / s * 64 <= width) return s;
  }
  return 1440;
}

class _LanesPainter extends CustomPainter {
  _LanesPainter({
    required this.timeline,
    required this.from,
    required this.length,
    required this.g,
    required this.tickStyle,
    required this.bandStyle,
    required this.scaler,
  });

  final Timeline timeline;
  final DateTime from;
  final Duration length;
  final _Geometry g;
  final TextStyle tickStyle, bandStyle;
  final TextScaler scaler;

  double _x(DateTime t, double w) => t.difference(from).inMicroseconds / length.inMicroseconds * w;

  TextPainter _text(String s, TextStyle style) =>
      TextPainter(text: TextSpan(text: s, style: style), textScaler: scaler, textDirection: TextDirection.ltr, maxLines: 1)..layout();

  static Color _fill(BandTone t) => switch (t) {
    BandTone.found => Night.saved,
    BandTone.faint => Night.saved.withValues(alpha: 0.45),
    BandTone.warn => Night.caution,
    BandTone.yours => Night.ink,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final track = Paint()..color = Night.track;
    for (var i = 0; i < g.lanes; i++) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, g.top(i), w, g.laneH), const Radius.circular(6)), track);
    }
    // hour rules and ticks
    final step = tickMinutes(length, w);
    final first = DateTime(from.year, from.month, from.day, from.hour);
    final rule = Paint()
      ..color = Night.ground
      ..strokeWidth = 1;
    final end = from.add(length);
    var lastLabelEnd = -1e9;
    for (var t = first; !t.isAfter(end); t = t.add(Duration(minutes: step))) {
      if (t.isBefore(from)) continue;
      final x = _x(t, w);
      canvas.drawLine(Offset(x, 0), Offset(x, g.height), rule);
      final label = _text(hm(t), tickStyle);
      final lx = (x - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)).toDouble();
      if (lx > lastLabelEnd + 6) {
        label.paint(canvas, Offset(lx, g.height + 4));
        lastLabelEnd = lx + label.width;
      }
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, g.height));
    for (final b in timeline.bands) {
      if (!b.end.isAfter(from) || !b.start.isBefore(end)) continue;
      final i = b.lane.index;
      final x1 = math.max(0.0, _x(b.start, w)), x2 = math.min(w, _x(b.end, w));
      final r = Rect.fromLTRB(x1, g.top(i) + 3, math.max(x2, x1 + 2), g.top(i) + g.laneH - 3);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), Paint()..color = _fill(b.tone));
      if (r.width > 40) {
        final style = b.tone == BandTone.faint ? bandStyle.copyWith(color: Night.ink) : bandStyle;
        final label = _text(b.label, style);
        if (label.width + 8 <= r.width) label.paint(canvas, Offset(r.left + 4, r.center.dy - label.height / 2));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LanesPainter old) =>
      old.timeline != timeline || old.from != from || old.length != length || old.g.laneH != g.laneH || old.scaler != scaler;
}
