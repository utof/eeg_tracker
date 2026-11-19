// The hands-free gestures on made-up signals (the recorded excerpts are in gestures_cross_check_test.dart): a double
// clench and a glance are found once, their near misses are not, a hole spoils them, the settings are checked, and
// the calibration tunes the levels from cued tries.
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

const int fs = 250;
const List<double> offsets = [85000, 82000, 78000, 79000];

/// Four channels of white noise (µV) around the headband's electrode offsets, so the muscle band has a rest level.
List<List<double>> quiet(double seconds, {int seed = 1}) {
  final r = math.Random(seed);
  double g() => (r.nextDouble() + r.nextDouble() + r.nextDouble() - 1.5) * 4;
  return [
    for (var i = 0; i < (seconds * fs).round(); i++) [for (var c = 0; c < 4; c++) offsets[c] + g()],
  ];
}

/// Broadband muscle noise on [sides] (T3, T4 by default) from [atS] for [lengthS].
void clench(List<List<double>> x, double atS, double lengthS, {double uv = 40, List<int> sides = const [2, 3]}) {
  final r = math.Random((atS * 10).round());
  for (var i = (atS * fs).round(); i < ((atS + lengthS) * fs).round(); i++) {
    for (final c in sides) {
      x[i][c] += (r.nextDouble() - 0.5) * 3.46 * uv;
    }
  }
}

void doubleClench(List<List<double>> x, double atS, {double uv = 40, double first = 0.4, double pause = 0.6}) {
  clench(x, atS, first, uv: uv);
  clench(x, atS + first + pause, 0.4, uv: uv);
}

/// A sideways eye movement: T3-T4 changes by [uv] within about 50 ms and stays.
void step(List<List<double>> x, double atS, double uv) {
  for (var i = 0; i < x.length; i++) {
    final s = uv * 0.5 * (1 + _tanh((i / fs - atS) / 0.02));
    x[i][2] += s / 2;
    x[i][3] -= s / 2;
  }
}

double _tanh(double v) => v > 20 ? 1 : (v < -20 ? -1 : (math.exp(2 * v) - 1) / (math.exp(2 * v) + 1));

void glance(List<List<double>> x, double atS, {double uv = 120, bool back = true}) {
  step(x, atS, uv);
  step(x, atS + 0.7, -2 * uv);
  if (back) step(x, atS + 1.4, uv);
}

List<GestureSecond> inputs(List<List<double>> x, {List<bool>? missing}) {
  final out = <GestureSecond>[];
  final d = Detectors()..tap = GestureTap(out.add);
  for (var i = 0; i < x.length; i++) {
    d.push(x[i], missing: missing?[i] ?? false);
  }
  return out;
}

List<Gesture> found(List<List<double>> x, {GestureSettings settings = const GestureSettings(), List<bool>? missing}) {
  final g = Gestures(settings: settings);
  for (final s in inputs(x, missing: missing)) {
    g.second(s);
  }
  return g.gestures;
}

void main() {
  test('a double clench is found once, two quiet seconds after it', () {
    final x = quiet(50);
    doubleClench(x, 40);
    final g = found(x);
    expect([for (final e in g) e.kind], [GestureKind.clench]);
    expect([g.first.start, g.first.at], [400, 43]);
    expect(g.first.end, inInclusiveRange(413, 414)); // 41.4 s, give or take the filter's ring
    expect(g.first.level, greaterThan(20));
  });

  final misses = <String, void Function(List<List<double>>)>{
    'one clench': (x) => clench(x, 40, 0.5),
    'three clenches': (x) => [doubleClench(x, 40), clench(x, 42, 0.4)],
    'two clenches 2 s apart': (x) => doubleClench(x, 40, pause: 2),
    'two clenches 0.2 s apart': (x) => doubleClench(x, 40, pause: 0.2),
    'a long first clench': (x) => doubleClench(x, 40, first: 1.5),
    'other jaw muscle 1.5 s before': (x) => [clench(x, 38, 0.3), doubleClench(x, 40)],
    'one side only': (x) => [clench(x, 40, 0.4, sides: [2]), clench(x, 41, 0.4, sides: [2])],
    'before the rest level is known': (x) => doubleClench(x, 20),
    'weak clenches': (x) => doubleClench(x, 40, uv: 4),
  };
  for (final m in misses.entries) {
    test('not a double clench: ${m.key}', () {
      final x = quiet(50);
      m.value(x);
      expect(found(x).where((e) => e.kind == GestureKind.clench), isEmpty);
    });
  }

  test('one-sided muscle around a double clench does not spoil it', () {
    final x = quiet(50);
    doubleClench(x, 40);
    clench(x, 38.5, 0.3, sides: [3]);
    expect([for (final e in found(x)) e.kind], [GestureKind.clench]);
  });

  test('a Bluetooth hole within 2 s spoils a double clench', () {
    final x = quiet(50), missing = List<bool>.filled(x.length, false);
    doubleClench(x, 40);
    for (var i = (42.6 * fs).round(); i < (42.7 * fs).round(); i++) {
      missing[i] = true;
    }
    expect(found(x, missing: missing), isEmpty);
  });

  test('a glance one way, then the other and back; left once known', () {
    final x = quiet(50);
    glance(x, 40);
    expect([for (final e in found(x)) e.kind], [GestureKind.glance]);
    expect(found(x, settings: const GestureSettings(leftSign: 1)), hasLength(1));
    expect(found(x, settings: const GestureSettings(leftSign: -1)), isEmpty);
    expect(found(x, settings: const GestureSettings(glanceOn: false)), isEmpty);
    final y = quiet(50);
    glance(y, 40, back: false);
    expect(found(y), hasLength(1));
  });

  final glanceMisses = <String, void Function(List<List<double>>)>{
    'one step': (x) => step(x, 40, 150),
    'small steps': (x) => glance(x, 40, uv: 50),
    'steps 2 s apart': (x) => [step(x, 40, 120), step(x, 42, -120)],
    'both steps the same way': (x) => [step(x, 40, 120), step(x, 40.7, 120)],
  };
  for (final m in glanceMisses.entries) {
    test('not a glance: ${m.key}', () {
      final x = quiet(50);
      m.value(x);
      expect(found(x).where((e) => e.kind == GestureKind.glance), isEmpty);
    });
  }

  test('a tap attached in the middle of a second marks that second spoiled', () {
    final x = quiet(3), out = <GestureSecond>[];
    final d = Detectors();
    for (var i = 0; i < 100; i++) {
      d.push(x[i]);
    }
    d.tap = GestureTap(out.add);
    for (var i = 100; i < x.length; i++) {
      d.push(x[i]);
    }
    expect(out.first.tickGap, everyElement(isTrue));
    expect(out[1].tickGap, everyElement(isFalse));
  });

  test('settings: saved and read back; out-of-range or broken settings are refused', () {
    const s = GestureSettings(clenchX: 22.5, glanceUv: 95, leftSign: -1, glanceOn: false);
    final back = GestureSettings.fromJson(s.toJson());
    expect([back.clenchX, back.glanceUv, back.leftSign, back.clenchOn, back.glanceOn], [22.5, 95.0, -1, true, false]);
    for (final bad in [
      null,
      {'clenchX': 8, 'glanceUv': 95, 'leftSign': 0, 'clenchOn': true, 'glanceOn': true},
      {'clenchX': 20, 'glanceUv': 900, 'leftSign': 0, 'clenchOn': true, 'glanceOn': true},
      {'clenchX': 20, 'glanceUv': 95, 'leftSign': 2, 'clenchOn': true, 'glanceOn': true},
      {'clenchX': 20, 'glanceUv': 95, 'leftSign': 0, 'clenchOn': 'yes', 'glanceOn': true},
    ]) {
      expect(() => GestureSettings.fromJson(bad), throwsFormatException, reason: '$bad');
    }
  });

  group('calibration', () {
    const cues = [40, 50, 60], looks = [70, 80, 90];
    final tries = [
      for (final c in cues) GestureTry(GestureKind.clench, c, c + 5),
      for (final c in looks) GestureTry(GestureKind.glance, c, c + 5),
    ];

    test('sets the levels from the weakest try and sees all six', () {
      final x = quiet(100);
      for (final (at, uv) in [(40, 60.0), (50, 35.0), (60, 45.0)]) {
        doubleClench(x, at + 0.8, uv: uv);
      }
      for (final (at, uv) in [(70, 110.0), (80, 130.0), (90, 150.0)]) {
        glance(x, at + 0.6, uv: uv);
      }
      final cal = calibrate(inputs(x), tries);
      final weakest = cal.tries.where((r) => r.kind == GestureKind.clench).map((r) => r.level!).reduce(math.min);
      expect(cal.settings.clenchX, closeTo(math.min(math.max(0.5 * weakest, 10), 60), 1e-9));
      final smallest = cal.tries.where((r) => r.kind == GestureKind.glance).map((r) => r.level!).reduce(math.min);
      expect(cal.settings.glanceUv, closeTo(math.max(0.6 * smallest, 70), 1e-9));
      expect(cal.settings.leftSign, 1);
      expect([for (final r in cal.tries) r.why], List.filled(6, 'ok'));
      expect([cal.clenchSeen, cal.glanceSeen, cal.others, cal.leftKnown], [3, 3, 0, true]);
      expect([cal.settings.clenchOn, cal.settings.glanceOn], [true, true]);
    });

    test('says why a try was missed, and a gesture needs 2 of 3', () {
      final x = quiet(100, seed: 4);
      doubleClench(x, 40.8);
      clench(x, 50.8, 0.5);
      doubleClench(x, 60.8, pause: 2.5);
      for (final at in looks) {
        glance(x, at + 0.6);
      }
      final cal = calibrate(inputs(x), tries);
      expect([for (final r in cal.tries.where((r) => r.kind == GestureKind.clench)) r.why], ['ok', 'one', 'one']);
      expect([cal.clenchSeen, cal.settings.clenchOn, cal.glanceSeen, cal.settings.glanceOn], [1, false, 3, true]);
    });

    test('nothing at all: the planning values stay and nothing is usable', () {
      final cal = calibrate(inputs(quiet(100, seed: 5)), tries);
      expect([cal.settings.clenchX, cal.settings.glanceUv, cal.settings.leftSign], [GestureRule.clenchX, GestureRule.glanceUv, 0]);
      expect([for (final r in cal.tries) r.why], List.filled(6, 'none'));
      expect([cal.settings.clenchOn, cal.settings.glanceOn], [false, false]);
    });
  });
}
