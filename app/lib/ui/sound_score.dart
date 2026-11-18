// The sound score (.impeccable/surfaces/app-lib-ui-states-screen-dart.md): a session drawn before Start as its real
// minutes left to right. The quiet minute is blank; the sound's loudness is a band that fades in and out; the beat's
// rate is one line above it, sliding as the plan slides it (no line: no beat). During a session a thin green rule marks
// where it is; afterwards the part that played is filled and a rule marks where and why it ended.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../states/presets.dart';
import 'theme.dart';

class ScoreModel {
  const ScoreModel({required this.plan, this.quietS = 0, this.nowS, this.endS, this.soundStartS});

  final SoundPlan plan;

  /// The quiet minute before the sound (0 without the headband).
  final double quietS;

  /// Seconds after lights off: where the session is now, and where it ended.
  final double? nowS;
  final double? endS;

  /// When the sound really started (after the quiet minute); the plan's quiet minute until then.
  final double? soundStartS;

  double get start => soundStartS ?? quietS;
  double get soundS => plan.minutes * 60.0;

  /// The whole width in seconds: quiet minute and sound (fall asleep: never past 45 minutes after lights off).
  double get totalS {
    final t = start + soundS;
    return plan.state == SoundState.asleep ? math.min(t, 45 * 60) : t;
  }

  /// The sound's loudness (0..1) at [t] s after lights off, as the plan fades it in and out.
  double level(double t) {
    final u = t - start, end = totalS - start;
    if (u <= 0 || u >= end) return 0;
    final rise = plan.fadeInS <= 0 ? 1.0 : u / plan.fadeInS, fall = plan.fadeOutS <= 0 ? 1.0 : (end - u) / plan.fadeOutS;
    return math.min(1, math.min(rise, fall));
  }
}

/// Rates are drawn on a log scale from 2 to 20 Hz.
double rateHeight(double hz) => ((math.log(hz) - math.log(2)) / (math.log(20) - math.log(2))).clamp(0.0, 1.0);

class SoundScore extends StatelessWidget {
  const SoundScore(this.m, {super.key, this.ink = Night.ink, this.muted = Night.inkMuted});
  final ScoreModel m;
  final Color ink;
  final Color muted;

  String _hz(double v) => v == v.roundToDouble() ? '${v.round()} Hz' : '${v.toStringAsFixed(1)} Hz';
  String _min(double s) => '${(s / 60).round()} min';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme, p = m.plan;
    final small = text.bodyMedium?.copyWith(color: muted, fontFeatures: tabular);
    final beat = p.beat != Beat.none;
    final label = [
      if (m.quietS > 0 && m.soundStartS == null) 'a quiet minute',
      '${_min(m.totalS - m.start)} of ${p.line}',
      if (p.state == SoundState.asleep) 'stopping once you are probably asleep',
    ].join(', then ');
    return Semantics(
      label: 'Session plan: $label',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(beat ? _hz(p.fromHz) : 'No beat', style: small)),
              if (beat && p.toHz != p.fromHz) Text(_hz(p.toHz), style: small),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(height: 64, child: CustomPaint(painter: _ScorePainter(m, ink: ink))),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text(m.quietS > 0 ? 'quiet 1 min' : '0', style: small)),
              Text(p.state == SoundState.asleep ? 'sound: ${_min(m.totalS - m.start)} at most' : 'sound: ${_min(m.totalS - m.start)}', style: small),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScorePainter extends CustomPainter {
  _ScorePainter(this.m, {required this.ink});
  final ScoreModel m;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, total = m.totalS;
    if (total <= 0) return;
    double x(double t) => (t / total).clamp(0.0, 1.0) * w;
    const lineH = 22.0, gap = 6.0;
    final bandTop = lineH + gap, bandH = size.height - bandTop;

    // the loudness band: the plan's envelope, sampled every 1 % of the width
    final band = Path()..moveTo(0, size.height);
    for (var i = 0; i <= 100; i++) {
      final t = total * i / 100;
      band.lineTo(x(t), size.height - bandH * m.level(t));
    }
    band
      ..lineTo(w, size.height)
      ..close();
    canvas.drawPath(band, Paint()..color = Night.track);
    final played = m.endS ?? m.nowS;
    if (played != null) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, x(played), size.height));
      canvas.drawPath(band, Paint()..color = Night.saved.withValues(alpha: 0.55));
      canvas.restore();
    }
    // the baseline the band stands on, and the quiet minute as an empty cell
    final rule = Paint()
      ..color = Night.rule
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(w, size.height - 0.5), rule);
    if (m.start > 0) {
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(0.5, bandTop + 0.5, x(m.start) - 3, size.height - 0.5), const Radius.circular(6));
      canvas.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Night.rule,
      );
    }
    // minute ticks every 5 minutes (every 15 past half an hour)
    final every = total > 30 * 60 ? 15 * 60 : 5 * 60;
    for (var t = every.toDouble(); t < total; t += every) {
      canvas.drawLine(Offset(x(t), size.height), Offset(x(t), size.height - 5), rule);
    }
    // the beat's rate
    final p = m.plan;
    if (p.beat != Beat.none) {
      final line = Path();
      final end = total - m.start;
      for (var i = 0; i <= 100; i++) {
        final u = end * i / 100, y = lineH * (1 - rateHeight(p.rateAt(u)!));
        i == 0 ? line.moveTo(x(m.start + u), y) : line.lineTo(x(m.start + u), y);
      }
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = ink,
      );
    }
    // where it is, or where it ended
    if (m.endS != null) {
      canvas.drawLine(Offset(x(m.endS!), 0), Offset(x(m.endS!), size.height), Paint()..color = ink..strokeWidth = 1.5);
    } else if (m.nowS != null) {
      canvas.drawLine(Offset(x(m.nowS!), 0), Offset(x(m.nowS!), size.height), Paint()..color = Night.live..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_ScorePainter old) =>
      old.m.plan.toJson().toString() != m.plan.toJson().toString() ||
      old.m.nowS != m.nowS ||
      old.m.endS != m.endS ||
      old.m.quietS != m.quietS ||
      old.m.soundStartS != m.soundStartS ||
      old.ink != ink;
}
