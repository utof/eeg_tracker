// The meditation's one line (.impeccable/surfaces/app-lib-ui-meditation-screen-dart.md, signature): eyes open,
// eyes closed, the session, each segment as long as its real duration, filled as time passes, the live one
// outlined green. After the session its segment draws the calm line, with a mark at each restless (amber) and
// drifting (red) moment at its real time. Cells and colours are the watch strip's (DESIGN.md).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Which part of the line is in progress.
enum TrackPart { open, closed, session }

class PhaseTrack extends StatelessWidget {
  const PhaseTrack({
    super.key,
    required this.sessionSeconds,
    this.openDone = 0,
    this.closedDone = 0,
    this.sessionDone = 0,
    this.live,
    this.calm,
    this.marks = const [],
    this.calmBinSeconds = 30,
  });

  /// Planned session length after calibration.
  final double sessionSeconds;

  /// 0..1 of each part done.
  final double openDone, closedDone, sessionDone;
  final TrackPart? live;

  /// Report: mean calm per bin (0..1), drawn as a line over the session segment.
  final List<double>? calm;
  final double calmBinSeconds;

  /// Report: (seconds into the session, kind) of restless and drifting moments.
  final List<(double, String)> marks;

  bool get _report => calm != null;

  @override
  Widget build(BuildContext context) => Semantics(
    label: _describe(),
    excludeSemantics: true,
    child: SizedBox(
      height: _report ? 76 : 32,
      width: double.infinity,
      child: CustomPaint(
        painter: _TrackPainter(
          sessionSeconds: sessionSeconds,
          done: [openDone, closedDone, sessionDone],
          live: live,
          calm: calm,
          calmBinSeconds: calmBinSeconds,
          marks: marks,
        ),
      ),
    ),
  );

  String _describe() {
    final minutes = (sessionSeconds / 60).round();
    if (_report) {
      final restless = marks.where((m) => m.$2 != 'drifting').length, drifting = marks.length - restless;
      return 'Session line: calm through $minutes minutes, $restless restless and $drifting drifting moments marked';
    }
    final part = switch (live) {
      TrackPart.open => 'eyes open, ${(openDone * 100).round()} percent done',
      TrackPart.closed => 'eyes closed, ${(closedDone * 100).round()} percent done',
      TrackPart.session => 'session, ${(sessionDone * 100).round()} percent done',
      null => 'not started',
    };
    return 'Session line: 30 seconds eyes open, 60 seconds eyes closed, $minutes minutes session; now $part';
  }
}

/// Colour of a mark kind on the report's line.
Color markColor(String kind) => kind == 'drifting' ? Night.problem : Night.caution;

class _TrackPainter extends CustomPainter {
  _TrackPainter({
    required this.sessionSeconds,
    required this.done,
    required this.live,
    required this.calm,
    required this.calmBinSeconds,
    required this.marks,
  });

  final double sessionSeconds;
  final List<double> done;
  final TrackPart? live;
  final List<double>? calm;
  final double calmBinSeconds;
  final List<(double, String)> marks;

  static const double _gap = 6, _minPart = 22, _radius = 6;

  /// Segment widths proportional to 30 s, 60 s and the session, the two short ones at least [_minPart].
  List<double> _widths(double total) {
    final span = total - 2 * _gap, secs = [30.0, 60.0, sessionSeconds];
    final sum = secs.reduce((a, b) => a + b);
    final open = math.max(_minPart, span * secs[0] / sum), closed = math.max(_minPart, span * secs[1] / sum);
    return [open, closed, span - open - closed];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = _widths(size.width);
    var x = 0.0;
    for (var i = 0; i < 3; i++) {
      // in the report the calibration cells keep their working height, so the session's line leads
      final h = calm != null && i < 2 ? math.min(32.0, size.height) : size.height;
      final r = Rect.fromLTWH(x, size.height - h, w[i], h);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(_radius));
      canvas.drawRRect(rr, Paint()..color = Night.track);
      final d = done[i].clamp(0.0, 1.0);
      final isSessionReport = i == 2 && calm != null;
      if (d > 0 && !isSessionReport) {
        canvas
          ..save()
          ..clipRRect(rr)
          ..drawRect(Rect.fromLTWH(x, r.top, w[i] * d, h), Paint()..color = Night.saved)
          ..restore();
      }
      if (isSessionReport) _drawCalm(canvas, r, rr);
      if (live != null && live!.index == i) {
        canvas.drawRRect(
          rr.deflate(1),
          Paint()
            ..color = Night.live
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      x += w[i] + _gap;
    }
  }

  void _drawCalm(Canvas canvas, Rect r, RRect rr) {
    final c = calm!;
    canvas
      ..save()
      ..clipRRect(rr);
    const top = 8.0, bottom = 14.0; // room for the marks along the bottom edge
    double yOf(double v) => r.bottom - bottom - (r.height - top - bottom) * v.clamp(0.0, 1.0);
    double xOf(double s) => r.left + r.width * (s / sessionSeconds).clamp(0.0, 1.0);
    if (c.isNotEmpty) {
      final line = Path(), area = Path();
      for (var i = 0; i < c.length; i++) {
        final p = Offset(xOf((i + 0.5) * calmBinSeconds), yOf(c[i]));
        if (i == 0) {
          line.moveTo(xOf(0), p.dy);
          line.lineTo(p.dx, p.dy);
          area
            ..moveTo(xOf(0), r.bottom)
            ..lineTo(xOf(0), p.dy)
            ..lineTo(p.dx, p.dy);
        } else {
          line.lineTo(p.dx, p.dy);
          area.lineTo(p.dx, p.dy);
        }
      }
      final endX = xOf(c.length * calmBinSeconds);
      line.lineTo(endX, yOf(c.last));
      area
        ..lineTo(endX, yOf(c.last))
        ..lineTo(endX, r.bottom)
        ..close();
      canvas
        ..drawPath(area, Paint()..color = Night.saved.withValues(alpha: 0.35))
        ..drawPath(
          line,
          Paint()
            ..color = Night.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeJoin = StrokeJoin.round,
        );
    }
    for (final (t, kind) in marks) {
      final mx = xOf(t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(mx - 1.5, r.bottom - 11, 3, 9), const Radius.circular(1.5)),
        Paint()..color = markColor(kind),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.sessionSeconds != sessionSeconds ||
      old.live != live ||
      old.calm != calm ||
      old.marks != marks ||
      old.done.join() != done.join();
}
