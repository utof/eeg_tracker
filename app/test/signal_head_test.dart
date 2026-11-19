// The Signal view's 3D head as math (DECISIONS 593): the pose, the camera's projection and rotation, the mesh's
// winding and culling, and picking an electrode by a tap.
import 'dart:ui';

import 'package:eeg_tracker/signal/head3d.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _size = Size(300, 300);

ScreenPoint _at(String name, HeadPose pose) => HeadCamera(pose, _size).site(standardSites[name]!);

void main() {
  test('from behind (yaw 0, level): the back faces the viewer, the head\'s right is on the screen\'s right', () {
    const pose = HeadPose(yaw: 0, pitch: 0);
    final oz = _at('Oz', pose), fpz = _at('Fpz', pose), t8 = _at('T8', pose), t7 = _at('T7', pose), cz = _at('Cz', pose);
    expect(oz.facing, isTrue);
    expect(fpz.facing, isFalse);
    expect(oz.at.dx, closeTo(150, 1e-9));
    expect(t8.at.dx, greaterThan(150));
    expect(t7.at.dx, lessThan(150));
    expect(cz.at.dy, lessThan(oz.at.dy)); // the top is up
    expect(oz.depth, greaterThan(fpz.depth)); // nearer
  });

  test('turned 90 degrees: the right ear faces the viewer, the nose points to the screen\'s right', () {
    const pose = HeadPose(yaw: 90, pitch: 0);
    final t8 = _at('T8', pose), t7 = _at('T7', pose), fpz = _at('Fpz', pose);
    expect(t8.facing, isTrue);
    expect(t7.facing, isFalse);
    expect(t8.at.dx, closeTo(150, 1e-9));
    expect(fpz.at.dx, greaterThan(200));
  });

  test('face on (yaw 180): the forehead faces the viewer and the head\'s right is on the screen\'s left', () {
    const pose = HeadPose(yaw: 180, pitch: 0);
    expect(_at('Fpz', pose).facing, isTrue);
    expect(_at('Oz', pose).facing, isFalse);
    expect(_at('T8', pose).at.dx, lessThan(150));
  });

  test('from above (pitch 90): the vertex in the middle, the nose up, the back down, right on the right', () {
    const pose = HeadPose(yaw: 0, pitch: 90);
    final cz = _at('Cz', pose), fz = _at('Fz', pose), pz = _at('Pz', pose), c4 = _at('C4', pose);
    expect(cz.facing, isTrue);
    expect(cz.at.dx, closeTo(150, 1e-9));
    expect(fz.at.dy, lessThan(cz.at.dy));
    expect(pz.at.dy, greaterThan(cz.at.dy));
    expect(c4.at.dx, greaterThan(150));
    // the sites of the 90-degree ring sit on the edge; the lower ring is hidden
    expect(_at('T9', pose).facing, isFalse);
  });

  test('the first view shows all four BrainBit sites; the forehead reference is round the back', () {
    for (final n in ['O1', 'O2', 'T7', 'T8']) {
      expect(_at(n, HeadPose.initial).facing, isTrue, reason: n);
    }
    expect(_at('Fpz', HeadPose.initial).facing, isFalse);
  });

  test('zoom scales the head about the middle', () {
    final one = _at('T8', const HeadPose(yaw: 0, pitch: 0, zoom: 1)).at - const Offset(150, 150);
    final two = _at('T8', const HeadPose(yaw: 0, pitch: 0, zoom: 2)).at - const Offset(150, 150);
    expect(two.dx, closeTo(one.dx * 2, 1e-6));
    expect(two.dy, closeTo(one.dy * 2, 1e-6));
  });

  test('a drag turns the surface with the finger: a full width is half a turn; pitch and zoom stay in range', () {
    const p = HeadPose(yaw: 0, pitch: 30);
    expect(p.dragged(const Offset(300, 0), 300).yaw, closeTo(-180, 1e-9));
    expect(p.dragged(const Offset(-150, 0), 300).yaw, closeTo(90, 1e-9));
    expect(p.dragged(const Offset(0, 100), 300).pitch, closeTo(90, 1e-9));
    expect(p.dragged(const Offset(0, -1000), 300).pitch, HeadPose.minPitch);
    expect(p.dragged(const Offset(-500, 0), 300).yaw, inInclusiveRange(-180, 180));
    expect(p.zoomed(10).zoom, HeadPose.maxZoom);
    expect(p.zoomed(0.01).zoom, HeadPose.minZoom);
    // the facing surface moves the way the finger does
    final before = _at('Oz', const HeadPose(yaw: 0, pitch: 0)).at;
    final after = _at('Oz', const HeadPose(yaw: 0, pitch: 0).dragged(const Offset(20, 0), 300)).at;
    expect(after.dx, greaterThan(before.dx));
  });

  test('the mesh is small and wound outward; about half of it faces the viewer, drawn far to near', () {
    final m = headMesh;
    expect(m.count, lessThan(700));
    for (var t = 0; t < m.count; t++) {
      if (m.parts[t] != MeshPart.scalp) continue;
      final a = m.points[m.triangles[3 * t]], b = m.points[m.triangles[3 * t + 1]], c = m.points[m.triangles[3 * t + 2]];
      final n = (b - a).cross(c - a);
      if (n.length < 1e-12) continue;
      expect(n.dot((a + b + c) * (1 / 3)), greaterThan(0), reason: 'triangle $t');
    }
    final shaded = shadeMesh(HeadCamera(HeadPose.initial, _size));
    final scalp = shaded.where((t) => t.part == MeshPart.scalp).length;
    final all = m.parts.where((p) => p == MeshPart.scalp).length;
    expect(scalp, inInclusiveRange(all * 0.35, all * 0.65));
    for (var i = 1; i < shaded.length; i++) {
      expect(shaded[i].depth, greaterThanOrEqualTo(shaded[i - 1].depth));
    }
    expect(shaded.every((t) => t.light >= 0.3 && t.light <= 1), isTrue);
    // turned face on, the nose is drawn; from behind it is not
    expect(shadeMesh(HeadCamera(const HeadPose(yaw: 180, pitch: 0), _size)).any((t) => t.part == MeshPart.nose), isTrue);
    expect(shadeMesh(HeadCamera(const HeadPose(yaw: 0, pitch: 0), _size)).any((t) => t.part == MeshPart.nose), isFalse);
  });

  test('a tap picks the nearest electrode that faces the viewer, within reach', () {
    final m = brainBitMontage();
    final camera = HeadCamera(HeadPose.initial, _size);
    final o1 = camera.site(m.site('O1')!.at!).at;
    expect(siteAt(o1 + const Offset(5, 3), camera, m.all), 'O1');
    expect(siteAt(const Offset(0, 0), camera, m.all), isNull);
    final ref = camera.site(m.site('Ref')!.at!);
    expect(ref.facing, isFalse);
    expect(siteAt(ref.at, camera, m.all, radius: 2), isNull); // hidden: never picked
  });
}
