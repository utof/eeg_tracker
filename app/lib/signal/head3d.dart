// The Signal view's 3D head, as plain math (DECISIONS 593): how it is turned (the pose), where a point of the head lands
// on the screen (a camera with a little perspective), and a small mesh (an ellipsoid head with a nose and ears for
// orientation, about 600 triangles) that the painter (ui/head_view.dart) shades and sorts. No package: Flutter's
// canvas draws it.
import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'layout.dart';

/// Half the head's width, length and height in units of the 10-20 sphere: a head is narrower than it is long.
const double headA = 0.84, headB = 1.0, headC = 1.02;

/// The head is drawn down to this polar angle (just under the ears), then closed by a flat underside.
const double headLowestPolar = 138;

/// How the head is seen. [yaw]: degrees turned about the vertical (0 from behind, with the head's left on the
/// screen's left as on a cap seen from behind; 90 from the right ear; 180 face on). [pitch]: degrees from above (0
/// level, 90 straight down onto the top with the nose up). [zoom]: 1 fits the head to the canvas.
class HeadPose {
  const HeadPose({this.yaw = 0, this.pitch = 35, this.zoom = 1});

  /// From behind and a little above: the BrainBit's four sites all in view (T3 and T4 on the rim).
  static const HeadPose initial = HeadPose();

  static const double minZoom = 0.6, maxZoom = 2.5, minPitch = -60, maxPitch = 90;

  final double yaw, pitch, zoom;

  /// A drag of [delta] logical pixels on a canvas [extent] wide: the surface under the finger follows it, a full
  /// width turns the head half round.
  HeadPose dragged(Offset delta, double extent) {
    final k = 180 / math.max(extent, 1);
    return HeadPose(
      yaw: _wrap(yaw - delta.dx * k),
      pitch: (pitch + delta.dy * k).clamp(minPitch, maxPitch).toDouble(),
      zoom: zoom,
    );
  }

  /// Pinched by [factor] (more than 1: closer).
  HeadPose zoomed(double factor) =>
      HeadPose(yaw: yaw, pitch: pitch, zoom: (zoom * factor).clamp(minZoom, maxZoom).toDouble());

  static double _wrap(double deg) => (deg + 180) % 360 - 180;

  @override
  bool operator ==(Object other) => other is HeadPose && other.yaw == yaw && other.pitch == pitch && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(yaw, pitch, zoom);
}

/// A point of the head on the screen: [at] in logical pixels, [depth] toward the viewer (larger is nearer), and
/// whether the surface there faces the viewer.
typedef ScreenPoint = ({Offset at, double depth, bool facing});

/// The camera for one pose and canvas.
class HeadCamera {
  HeadCamera(this.pose, this.size)
    : _xc = Vec3(math.cos(_r(pose.yaw)), math.sin(_r(pose.yaw)), 0),
      _yc = _up(pose),
      _zc = _toward(pose),
      _scale = math.min(size.width, size.height) / 2 / 1.32 * pose.zoom;

  final HeadPose pose;
  final Size size;
  final Vec3 _xc, _yc, _zc;
  final double _scale;

  /// The eye's distance from the head's centre, in head units: a little perspective, never a fish-eye.
  static const double eye = 6;

  /// The middle of the drawn head (it reaches lower than the 10-20 sphere's centre).
  static const Vec3 centre = Vec3(0, 0, 0.13);

  static double _r(double d) => d * math.pi / 180;

  /// Screen right is the camera's x; toward the viewer (level) and up, then tilted by the pitch.
  static Vec3 _towardLevel(HeadPose p) => Vec3(math.sin(_r(p.yaw)), -math.cos(_r(p.yaw)), 0);
  static Vec3 _toward(HeadPose p) =>
      _towardLevel(p) * math.cos(_r(p.pitch)) + const Vec3(0, 0, 1) * math.sin(_r(p.pitch));
  static Vec3 _up(HeadPose p) => const Vec3(0, 0, 1) * math.cos(_r(p.pitch)) - _towardLevel(p) * math.sin(_r(p.pitch));

  /// Head coordinates to the camera's: x right, y up, z toward the viewer.
  Vec3 toCamera(Vec3 p) {
    final q = p - centre;
    return Vec3(q.dot(_xc), q.dot(_yc), q.dot(_zc));
  }

  /// A direction (a normal) in the camera's axes.
  Vec3 turn(Vec3 v) => Vec3(v.dot(_xc), v.dot(_yc), v.dot(_zc));

  /// A camera point on the canvas.
  Offset screen(Vec3 c) {
    final k = _scale * eye / (eye - c.z);
    return Offset(size.width / 2 + c.x * k, size.height / 2 - c.y * k);
  }

  /// Whether a surface at camera point [c] with camera normal [n] faces the eye.
  static bool faces(Vec3 c, Vec3 n) => n.dot(const Vec3(0, 0, eye) - c) > 0;

  /// A site's place on the drawn head, given its direction on the 10-20 sphere. A site just past the rim (up to about
  /// 12 degrees) still counts as facing: it shows on the head's outline.
  ScreenPoint site(Vec3 direction) {
    final c = toCamera(onHead(direction) * 1.015);
    final toEye = (const Vec3(0, 0, eye) - c).unit;
    return (at: screen(c), depth: c.z, facing: turn(headNormal(direction)).dot(toEye) > -0.2);
  }
}

/// A direction of the 10-20 sphere on the drawn (ellipsoid) head.
Vec3 onHead(Vec3 d) => Vec3(d.x * headA, d.y * headB, d.z * headC);

/// The head's outward normal at that place.
Vec3 headNormal(Vec3 d) => Vec3(d.x / headA, d.y / headB, d.z / headC).unit;

enum MeshPart { scalp, underside, nose, ear }

/// Triangles in head coordinates, each wound outward (the ears are two-sided).
class HeadMesh {
  const HeadMesh(this.points, this.triangles, this.parts);
  final List<Vec3> points;

  /// Three indices into [points] per triangle.
  final List<int> triangles;

  /// One part per triangle.
  final List<MeshPart> parts;

  int get count => parts.length;
}

/// The one mesh: 10 rings of 24 around the scalp, its underside, a 4-sided nose and two 8-sided ears.
final HeadMesh headMesh = _buildMesh();

HeadMesh _buildMesh() {
  final pts = <Vec3>[];
  final tri = <int>[];
  final parts = <MeshPart>[];
  const rings = 10, around = 24;
  int at(int r, int c) => r == 0 ? 0 : 1 + (r - 1) * around + c % around;
  pts.add(onHead(fromAngles(0, 0)));
  for (var r = 1; r <= rings; r++) {
    for (var c = 0; c < around; c++) {
      pts.add(onHead(fromAngles(headLowestPolar * r / rings, 360.0 * c / around)));
    }
  }
  void add(int a, int b, int c, MeshPart part, {Vec3? inside}) {
    final pa = pts[a], pb = pts[b], pc = pts[c];
    final n = (pb - pa).cross(pc - pa);
    final mid = (pa + pb + pc) * (1 / 3);
    // wound outward: the normal points away from [inside] (the head's centre, or the nose's base)
    final outward = n.dot(mid - (inside ?? const Vec3(0, 0, 0))) >= 0;
    tri.addAll(outward ? [a, b, c] : [a, c, b]);
    parts.add(part);
  }

  for (var r = 0; r < rings; r++) {
    for (var c = 0; c < around; c++) {
      if (r == 0) {
        add(at(0, 0), at(1, c), at(1, c + 1), MeshPart.scalp);
      } else {
        add(at(r, c), at(r + 1, c), at(r + 1, c + 1), MeshPart.scalp);
        add(at(r, c), at(r + 1, c + 1), at(r, c + 1), MeshPart.scalp);
      }
    }
  }
  // the underside: a fan from the middle of the lowest ring
  final low = onHead(fromAngles(headLowestPolar, 0)).z;
  pts.add(Vec3(0, 0, low));
  final bottom = pts.length - 1;
  for (var c = 0; c < around; c++) {
    add(bottom, at(rings, c), at(rings, c + 1), MeshPart.underside, inside: const Vec3(0, 0, 0.5));
  }
  // the nose: a pyramid on the face just under the Fpz ring, pointing forward
  final base = onHead(fromAngles(110, 0));
  final noseBase = [
    onHead(fromAngles(98, 0)),
    onHead(fromAngles(112, 11)),
    onHead(fromAngles(124, 0)),
    onHead(fromAngles(112, -11)),
  ];
  final tip = base + const Vec3(0, 0.24, -0.06);
  final n0 = pts.length;
  pts.addAll([...noseBase, tip]);
  for (var i = 0; i < 4; i++) {
    add(n0 + i, n0 + (i + 1) % 4, n0 + 4, MeshPart.nose, inside: base * 0.9);
  }
  // the ears: flat ovals just outside the sides at the ears' level, a little behind the middle
  for (final side in [-1.0, 1.0]) {
    final centre = Vec3(side * (headA + 0.03), -0.08, -0.36);
    final e0 = pts.length;
    pts.add(centre);
    for (var k = 0; k < 8; k++) {
      final a = 2 * math.pi * k / 8;
      pts.add(centre + Vec3(side * 0.02 * math.cos(a), 0.11 * math.cos(a), 0.19 * math.sin(a)));
    }
    for (var k = 0; k < 8; k++) {
      tri.addAll([e0, e0 + 1 + k, e0 + 1 + (k + 1) % 8]);
      parts.add(MeshPart.ear);
    }
  }
  return HeadMesh(List.unmodifiable(pts), List.unmodifiable(tri), List.unmodifiable(parts));
}

/// One triangle ready to draw: its corners on the canvas, its brightness (0..1) and its depth (larger is nearer).
typedef ShadedTriangle = ({Offset a, Offset b, Offset c, double light, double depth, MeshPart part});

/// The mesh seen through [camera]: back faces dropped (the ears are drawn from both sides), farthest first, shaded by a
/// light above the viewer's left shoulder.
List<ShadedTriangle> shadeMesh(HeadCamera camera, {HeadMesh? mesh}) {
  final m = mesh ?? headMesh;
  final cam = [for (final p in m.points) camera.toCamera(p)];
  final scr = [for (final c in cam) camera.screen(c)];
  const light = Vec3(-0.45, 0.6, 0.66);
  final out = <ShadedTriangle>[];
  for (var t = 0; t < m.count; t++) {
    final i = m.triangles[3 * t], j = m.triangles[3 * t + 1], k = m.triangles[3 * t + 2];
    final a = cam[i], b = cam[j], c = cam[k];
    final n = (b - a).cross(c - a);
    if (n.length == 0) continue;
    final facing = HeadCamera.faces(a, n);
    final part = m.parts[t];
    if (!facing && part != MeshPart.ear) continue;
    final unit = (facing ? n : n * -1).unit;
    final lit = 0.3 + 0.7 * math.max(0.0, unit.dot(light.unit));
    out.add((a: scr[i], b: scr[j], c: scr[k], light: lit, depth: (a.z + b.z + c.z) / 3, part: part));
  }
  out.sort((x, y) => x.depth.compareTo(y.depth));
  return out;
}

/// The cap's guide lines (the ring through Fpz T7 Oz T8, the midline and the line ear to ear over Cz) as polylines of
/// sphere directions.
final List<List<Vec3>> guideLines = [
  [for (var a = 0; a <= 360; a += 10) fromAngles(90, a.toDouble())],
  [for (var p = -110; p <= 110; p += 10) fromAngles(p.abs().toDouble(), p < 0 ? 180 : 0)],
  [for (var p = -110; p <= 110; p += 10) fromAngles(p.abs().toDouble(), p < 0 ? -90 : 90)],
];

/// The channel or site whose mark is nearest to [tap] within [radius] logical pixels, among those facing the viewer.
String? siteAt(Offset tap, HeadCamera camera, Iterable<Site> sites, {double radius = 28}) {
  String? best;
  var bestD = radius;
  for (final s in sites) {
    final at = s.at;
    if (at == null) continue;
    final p = camera.site(at);
    if (!p.facing) continue;
    final d = (p.at - tap).distance;
    if (d <= bestD) {
      bestD = d;
      best = s.name;
    }
  }
  return best;
}
