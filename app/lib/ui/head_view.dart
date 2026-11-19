// The Signal view's head (DECISIONS 593): drawn with Flutter's canvas from signal/head3d.dart (no package), turned by a
// drag, zoomed by a pinch, straightened by a double tap; each electrode a state mark in the contact's colour (the
// DESIGN.md marks: filled good, ringed dot fair, ring poor, dash none) with its name and ohms beside it, the
// reference and the bias as squares. A tap on a mark picks that electrode. It repaints only when the pose, the marks
// or the pick change.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../recorder/contact.dart';
import '../signal/head3d.dart';
import '../signal/layout.dart';
import 'theme.dart';

/// One electrode's mark: its contact class, and the words beside its name ('820 kΩ'); [measured] false when the
/// device has no contact reading for it (the DIY board), which draws a dash.
typedef SiteMark = ({Contact contact, String? value, bool measured});

class HeadView extends StatefulWidget {
  const HeadView({
    super.key,
    required this.montage,
    required this.marks,
    required this.pose,
    this.selected,
    this.onSelect,
    this.height = 300,
  });

  final Montage montage;

  /// By site name; a channel without a mark draws a dash.
  final Map<String, SiteMark> marks;
  final ValueNotifier<HeadPose> pose;
  final String? selected;
  final ValueChanged<String>? onSelect;
  final double height;

  @override
  State<HeadView> createState() => _HeadViewState();
}

class _HeadViewState extends State<HeadView> {
  HeadPose _startPose = HeadPose.initial;
  final Map<String, TextPainter> _labels = {};

  @override
  void dispose() {
    for (final t in _labels.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _tap(Offset at, Size size) {
    final pick = siteAt(at, HeadCamera(widget.pose.value, size), widget.montage.all, radius: 32);
    if (pick != null) widget.onSelect?.call(pick);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.montage.count;
    final scaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 14);
    return Semantics(
      label: 'Head with $n electrode${n == 1 ? '' : 's'}. Drag to turn it, pinch to zoom, double-tap to straighten it.',
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, widget.height);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => _startPose = widget.pose.value,
              onScaleUpdate: (d) {
                final now = widget.pose.value;
                widget.pose.value = d.pointerCount >= 2
                    ? HeadPose(yaw: now.yaw, pitch: now.pitch, zoom: _startPose.zoom).zoomed(d.scale)
                    : now.dragged(d.focalPointDelta, size.width);
              },
              onDoubleTap: () => widget.pose.value = HeadPose.initial,
              onTapUp: (d) => _tap(d.localPosition, size),
              child: ValueListenableBuilder<HeadPose>(
                valueListenable: widget.pose,
                builder: (context, pose, _) => CustomPaint(
                  size: size,
                  painter: HeadPainter(
                    pose: pose,
                    montage: widget.montage,
                    marks: widget.marks,
                    selected: widget.selected,
                    label: (text) => _labels.putIfAbsent(
                      text,
                      () => TextPainter(
                        text: TextSpan(
                          text: text,
                          style: style.copyWith(color: Night.ink, fontFeatures: tabular),
                        ),
                        textDirection: TextDirection.ltr,
                        textScaler: scaler,
                      )..layout(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(HeadView old) {
    super.didUpdateWidget(old);
    if (_labels.length > 200) {
      for (final t in _labels.values) {
        t.dispose();
      }
      _labels.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the text size may have changed: lay the labels out again
    for (final t in _labels.values) {
      t.dispose();
    }
    _labels.clear();
  }
}

/// Paints the head for one pose.
class HeadPainter extends CustomPainter {
  HeadPainter({required this.pose, required this.montage, required this.marks, this.selected, required this.label});

  final HeadPose pose;
  final Montage montage;
  final Map<String, SiteMark> marks;
  final String? selected;

  /// A laid-out label for a text (cached by the view).
  final TextPainter Function(String text) label;

  static const Color _dark = Color(0xFF1A1510), _lit = Color(0xFF4B4034), _guide = Color(0xFF5E5245);

  @override
  void paint(Canvas canvas, Size size) {
    final camera = HeadCamera(pose, size);
    _head(canvas, camera);
    _guides(canvas, camera);
    final placed = [
      for (final s in montage.all)
        if (s.at != null) (site: s, p: camera.site(s.at!)),
    ]..sort((a, b) => a.p.depth.compareTo(b.p.depth));
    for (final e in placed) {
      if (!e.p.facing) _hidden(canvas, e.p.at);
    }
    final facing = [for (final e in placed) if (e.p.facing) e];
    _labels(canvas, facing, size);
    for (final e in facing) {
      _site(canvas, e.site, e.p.at);
    }
  }

  /// Names (and ohms, for a few electrodes or the picked one) beside the marks: outward from the head's middle, else
  /// inward, else above or below; a label that would cover another label or a mark is left out (turn or zoom to see it). The picked one
  /// first, then the nearest.
  void _labels(Canvas canvas, List<({Site site, ScreenPoint p})> facing, Size size) {
    final taken = <Rect>[for (final e in facing) Rect.fromCircle(center: e.p.at, radius: 11)];
    final order = [...facing]..sort((a, b) {
      if (a.site.name == selected) return -1;
      if (b.site.name == selected) return 1;
      return b.p.depth.compareTo(a.p.depth);
    });
    final few = montage.count <= 6;
    for (final e in order) {
      final s = e.site, at = e.p.at;
      final value = marks[s.name]?.value;
      final withValue = value != null && value.isNotEmpty && (few || s.name == selected);
      final tp = label(withValue ? '${s.name}  $value' : s.name);
      final outwardRight = at.dx >= size.width / 2;
      Rect side(bool right) => Offset(right ? at.dx + 15 : at.dx - 15 - tp.width, at.dy - tp.height / 2) & tp.size;
      Rect over(bool above) => Offset(at.dx - tp.width / 2, above ? at.dy - 15 - tp.height : at.dy + 15) & tp.size;
      bool fits(Rect r) =>
          r.left >= 2 &&
          r.right <= size.width - 2 &&
          r.top >= 2 &&
          r.bottom <= size.height - 2 &&
          !taken.any((t) => t.overlaps(r.inflate(2)) && !t.contains(at));
      final r = [side(outwardRight), side(!outwardRight), over(true), over(false)].where(fits).firstOrNull;
      if (r == null) continue;
      taken.add(r.inflate(3));
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(4)).inflate(3),
        Paint()..color = Night.ground.withValues(alpha: 0.72),
      );
      tp.paint(canvas, r.topLeft);
    }
  }

  void _head(Canvas canvas, HeadCamera camera) {
    final tris = shadeMesh(camera);
    final pos = <Offset>[];
    final colors = <Color>[];
    for (final t in tris) {
      final shade = t.part == MeshPart.underside ? t.light * 0.55 : t.light;
      final c = Color.lerp(_dark, _lit, shade.clamp(0, 1))!;
      pos.addAll([t.a, t.b, t.c]);
      colors.addAll([c, c, c]);
    }
    if (pos.isEmpty) return;
    canvas.drawVertices(ui.Vertices(VertexMode.triangles, pos, colors: colors), BlendMode.dst, Paint());
  }

  void _guides(Canvas canvas, HeadCamera camera) {
    final paint = Paint()
      ..color = _guide
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final line in guideLines) {
      final pts = [for (final d in line) camera.site(d)];
      for (var i = 0; i + 1 < pts.length; i++) {
        if (pts[i].facing && pts[i + 1].facing) canvas.drawLine(pts[i].at, pts[i + 1].at, paint);
      }
    }
  }

  /// A site on the far side: a faint ring, so the count is still there.
  void _hidden(Canvas canvas, Offset at) => canvas.drawCircle(
    at,
    4,
    Paint()
      ..color = Night.inkMuted.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2,
  );

  void _site(Canvas canvas, Site s, Offset at) {
    final mark = marks[s.name];
    // a dark disc under every mark, so it reads on the lit scalp
    canvas.drawCircle(at, 10, Paint()..color = Night.ground.withValues(alpha: 0.85));
    if (s.kind != SiteKind.channel) {
      canvas.drawRect(Rect.fromCenter(center: at, width: 11, height: 11), _stroke(Night.inkMuted, 1.6));
    } else {
      _mark(canvas, at, mark);
    }
    if (s.name == selected) canvas.drawCircle(at, 13, _stroke(Night.ink, 1.6));
  }

  static Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w;

  void _mark(Canvas canvas, Offset at, SiteMark? mark) {
    final contact = mark == null || !mark.measured ? Contact.none : mark.contact;
    switch (contact) {
      case Contact.good:
        canvas.drawCircle(at, 7, Paint()..color = Night.live);
      case Contact.fair:
        canvas.drawCircle(at, 6.5, _stroke(Night.caution, 2));
        canvas.drawCircle(at, 2.6, Paint()..color = Night.caution);
      case Contact.poor:
        canvas.drawCircle(at, 6.5, _stroke(Night.problem, 2));
      case Contact.none:
        canvas.drawLine(at.translate(-6, 0), at.translate(6, 0), _stroke(Night.inkMuted, 2.4));
    }
  }

  @override
  bool shouldRepaint(HeadPainter old) =>
      old.pose != pose || !identical(old.marks, marks) || old.selected != selected || !identical(old.montage, montage);
}
