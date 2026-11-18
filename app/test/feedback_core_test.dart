// The feedback core's key cases, ported from tests/web/feedback-core.test.mjs and sound.test.mjs: the same
// demo recipe, the same session scripts and the same limits, so the Dart port is held to what the JS core
// was held to (DECISIONS rows 41-47 and 72).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/features.dart';
import 'package:eeg_tracker/feedback/mapping.dart';
import 'package:eeg_tracker/feedback/reward.dart';
import 'package:eeg_tracker/feedback/session.dart';
import 'package:eeg_tracker/feedback/session_log.dart';
import 'package:eeg_tracker/feedback/sleep_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// One analysis step and the demo clock when it was made (differs from the step's time after a skipped gap).
typedef Stepped = ({StepResult x, double demoT});

/// A calibrated session on the demo: 30 s eyes open, then eyes closed. [script] may change the demo or the
/// session before each step.
({Session s, List<Stepped> steps}) runSession({
  double seconds = 690,
  String mode = 'training',
  bool calibrate = true,
  int seed = 7,
  void Function(DemoSignal d, double t, Session s)? script,
}) {
  final s = Session(mode: mode, calibrate: calibrate), demo = DemoSignal(seed), steps = <Stepped>[];
  while (demo.t < seconds) {
    demo.eyes = calibrate && demo.t < 30 ? 'open' : 'closed';
    script?.call(demo, demo.t, s);
    for (final x in s.push(demo.next(stepSamples))) {
      steps.add((x: x, demoT: demo.t));
    }
  }
  return (s: s, steps: steps);
}

List<double> bellTimes(List<Stepped> steps) => [
  for (final e in steps)
    if (e.x.ring) e.x.t,
];

bool near(double a, double b) => (a - b).abs() < 1e-9;

List<double> sine(double f, double a, [int n = 250]) => [for (var i = 0; i < n; i++) a * math.sin(2 * math.pi * f * i / 250)];

double settle(BandPower band, List<double> x) {
  var v = 0.0;
  for (final s in x) {
    v = band.step(s);
  }
  return v;
}

void main() {
  test('slowed 7.5 Hz alpha (drifting toward sleep) earns far fewer bells than 10 Hz', () {
    final normal = bellTimes(runSession(script: (d, t, _) => t >= 90 ? d.alphaHz = 10 : null).steps);
    final slow = runSession(script: (d, t, _) => t >= 90 ? d.alphaHz = 7.5 : null);
    final slowBells = bellTimes(slow.steps);
    expect(normal.length, greaterThanOrEqualTo(20), reason: '10 Hz: ${normal.length} bells in 10 min');
    expect(slowBells.length * 10, lessThanOrEqualTo(normal.length), reason: '7.5 Hz: ${slowBells.length} bells');
    final late = slow.steps.where((e) => e.x.t > 110 && e.x.phase == 'run').toList();
    final drowsy = late.where((e) => e.x.veto == 'drowsy').length;
    expect(drowsy, greaterThan(0.7 * late.length), reason: 'the sleep guard holds the drowsy gate');
  });

  for (final mode in ['training', 'relax']) {
    final gap = BellRule.gapS[mode]!;
    test('$mode: at most 6 bells in any minute and at least $gap s between bells, even with very strong alpha', () {
      final b = bellTimes(runSession(mode: mode, script: (d, t, _) => t >= 90 ? d.alphaGain = 2 : null).steps);
      expect(b.length, greaterThanOrEqualTo(mode == 'training' ? 40 : 30));
      for (var i = 1; i < b.length; i++) {
        expect(b[i] - b[i - 1], greaterThanOrEqualTo(gap - 1e-9), reason: 'gap at ${b[i]} s');
      }
      for (final t0 in b) {
        expect(b.where((t) => t >= t0 && t < t0 + 60).length, lessThanOrEqualTo(BellRule.perMinute));
      }
    });
  }

  test('no bell during or right after any gate (muscle, blink, drowsy, contact, gap)', () {
    final r = runSession(
      seconds: 900,
      script: (d, t, sess) {
        d.alphaHz = t >= 300 && t < 360 ? 7.5 : 10; // a drowsy minute
        if (near(t, 420)) sess.contact({'O1': null, 'O2': null, 'T3': 1e5, 'T4': 1e5}); // back contact lost
        if (near(t, 450)) sess.contact({'O1': 1e5, 'O2': 1e5, 'T3': 1e5, 'T4': 1e5});
        if (near(t, 500)) {
          sess.gap();
          d.next(250 * 3); // 3 s lost
        }
        if (t >= 600 && t < 660) d.jawUntil = t + 2; // a long clench
      },
    );
    final steps = r.steps;
    final kinds = {
      for (final e in steps)
        if (e.x.phase == 'run') e.x.veto ?? e.x.quality,
    };
    for (final k in ['muscle', 'blink', 'drowsy', 'poor', 'settling']) {
      expect(kinds, contains(k), reason: 'gate $k seen');
    }
    final window = (BellRule.windowS / 0.1).round();
    var rang = 0;
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].x.ring) continue;
      rang++;
      for (var j = i - window + 1; j <= i; j++) {
        expect(steps[j].x.quality, 'good', reason: 'bell at ${steps[i].x.t} s, quality at ${steps[j].x.t} s');
        expect(steps[j].x.veto, isNull, reason: 'bell at ${steps[i].x.t} s, gate at ${steps[j].x.t} s');
      }
    }
    expect(rang, greaterThanOrEqualTo(20));
    // ground truth from the demo's clock: no bell within 4 s after a jaw burst, a blink, the clench or the drowsy minute
    for (final e in steps.where((e) => e.x.ring)) {
      final t = e.demoT;
      expect(t.remainder(45), greaterThanOrEqualTo(3 + 4), reason: 'bell after a jaw burst at $t');
      final sinceBlink = (t - 0.15).remainder(7);
      expect(sinceBlink >= 0.3 + 4 || sinceBlink < 0, isTrue, reason: 'bell after a blink at $t');
      expect(!(t >= 300 && t < 364) && !(t >= 600 && t < 666) && !(t >= 420 && t < 455), isTrue, reason: 'bell at $t');
    }
    expect(r.s.log.lines.any((l) => l['type'] == 'gap'), isTrue);
  });

  test('replay of a logged session reproduces every step, bell and line exactly', () {
    final r = runSession(
      seconds: 400,
      script: (d, t, sess) {
        if (near(t, 0)) sess.contact({'O1': 1e5, 'O2': 2e5, 'T3': 3e5, 'T4': 4e5});
        if (near(t, 200)) {
          sess.gap();
          d.next(250 * 2);
        }
        if (near(t, 250)) sess.contact({'O1': null, 'O2': 2e5, 'T3': 3e5, 'T4': 4e5});
        if (t >= 300) d.alphaGain = 1.4;
      },
    );
    // what a saved session file holds
    final saved = jsonDecode(jsonEncode(r.s.log.toJson())) as Map<String, Object?>;
    expect(decodeInput(saved['input'])[0].length, r.s.n);
    final again = replaySession(saved);
    expect(again.n, r.s.n);
    final lines = saved['lines']! as List;
    expect(lines.where((l) => (l as Map)['type'] == 'bell').length, greaterThan(5));
    expect(lines.any((l) => (l as Map)['type'] == 'block'), isTrue);
    expect(jsonEncode(again.log.lines), jsonEncode(lines), reason: 'every line, bit for bit');
    expect(jsonEncode(again.log.toJson()['input']), jsonEncode(saved['input']));
  });

  test('the output does not depend on how the samples are chunked', () {
    final rows = DemoSignal(5).next(250 * 100);
    final a = Session(calibrate: false), b = Session(calibrate: false);
    a.push(rows);
    for (var i = 0; i < rows.length;) {
      final k = 1 + (i % 23);
      b.push(rows.sublist(i, math.min(rows.length, i + k)));
      i += k;
    }
    expect(jsonEncode(b.log.lines), jsonEncode(a.log.lines));
  });

  test('reaction: the alpha measure gets half-way to its new level within 0.3 s of the eyes closing or opening', () {
    final steps = runSession(
      seconds: 200,
      script: (d, t, _) {
        if (t >= 100) {
          d.eyes = ((t - 100) / 10).floor() % 2 == 0 ? 'open' : 'closed';
          d.blinks = false;
          d.jawBursts = false;
          d.wanders = false;
        }
      },
    ).steps;
    double at(double t) => steps.firstWhere((e) => (e.x.t - t).abs() < 0.01).x.z!;
    for (var t0 = 110.0; t0 < 200; t0 += 10) {
      final before = at(t0), after = at(t0 + 2), half = (before + after) / 2;
      expect((after - before).abs(), greaterThan(5));
      final hit = steps.firstWhere((e) => e.x.t > t0 && (after > before ? e.x.z! >= half : e.x.z! <= half));
      expect(hit.x.t - t0, lessThanOrEqualTo(0.3 + 1e-9), reason: 'switch at $t0 s');
    }
  });

  test('pipeline: calmer with eyes closed, the alpha peak found, eyes-open rise reported', () {
    final demo = DemoSignal(7), s = Session(), out = <StepResult>[];
    final closedAt = <bool>[];
    while (demo.t < 600) {
      final t = demo.t;
      demo.eyes = t < 120 ? (t < 30 ? 'open' : 'closed') : null;
      for (final r in s.push(demo.next(25))) {
        out.add(r);
        closedAt.add(demo.closed(r.t - 0.05));
      }
    }
    expect(s.log.lines.firstWhere((l) => l['type'] == 'calibration')['iaf'], 10);
    expect(s.iaf, 10);
    expect(s.note, matches(RegExp(r'eyes closed gave \d+\.\dx eyes-open alpha$')));
    double meanCalm(bool closed) {
      final v = [
        for (var i = 0; i < out.length; i++)
          if (out[i].t > 125 && out[i].phase == 'run' && out[i].t % 60 > 4 && closedAt[i] == closed) out[i].targets.calm,
      ];
      return v.reduce((a, b) => a + b) / v.length;
    }

    expect(meanCalm(true), greaterThan(0.45));
    expect(meanCalm(false), lessThan(0.3));
    expect(out.where((o) => o.ring).length, greaterThanOrEqualTo(5));
  });

  test('calibration waits for 30 s of clean eyes-closed signal', () {
    final demo = DemoSignal(4), s = Session();
    s.contact({'O1': null, 'O2': null, 'T3': 1e5, 'T4': 1e5});
    late StepResult last;
    for (var k = 0; k < 1000; k++) {
      last = s.push(demo.next(25)).last; // 100 s with no back contact
    }
    expect(last.phase, 'cal-closed');
    s.contact({'O1': 1e5, 'O2': 1e5, 'T3': 1e5, 'T4': 1e5});
    demo.eyes = 'closed';
    for (var k = 0; k < 300; k++) {
      last = s.push(demo.next(25)).last;
    }
    expect(last.phase, 'cal-closed', reason: 'not 30 s clean after 30 s (5 s settle not counted)');
    for (var k = 0; k < 100; k++) {
      last = s.push(demo.next(25)).last;
    }
    expect(last.phase, 'run');
  });

  test('a channel without contact is not used; none at the back means poor quality', () {
    final s = Session(calibrate: false)..contact({'O1': 1e5, 'O2': null, 'T3': 1e5, 'T4': 1e5});
    final demo = DemoSignal(2);
    var steps = s.push(demo.next(500));
    expect(steps.last.channels['O2'], 'off');
    expect(steps.last.channels['O1'], 'ok');
    expect(steps.last.quality, 'learning');
    s.contact({'O1': null, 'O2': null, 'T3': 1e5, 'T4': 1e5});
    steps = s.push(demo.next(50));
    expect(steps.last.quality, 'poor');
    expect(steps.last.reason, contains('not touching'));
  });

  test('target line: held still inside a block, raised above 80 %, lowered under 50 %, gated steps not counted', () {
    final l = TargetLine((line: 2, sd: 0.2));
    final steps = (LineRule.blockS / 0.1).round();
    for (var i = 0; i < steps - 1; i++) {
      expect(l.update(true), isNull);
      expect(l.line, 2);
    }
    var r = l.update(true)!;
    expect(r.moved, 1);
    expect((l.line - (2 + 0.15 * 0.2)).abs(), lessThan(1e-12));
    for (var i = 0; i < steps - 1; i++) {
      l.update(i % 10 < 4);
    }
    r = l.update(false)!;
    expect(r.moved, -1);
    expect((l.line - 2).abs(), lessThan(1e-12));
    BlockEnd? e;
    for (var i = 0; i < steps; i++) {
      e = l.update(i < 200 ? true : null) ?? e;
    }
    expect(e!.moved, 0);
    expect(e.counted, closeTo(20, 1e-9));
    for (var i = 0; i < steps; i++) {
      e = l.update(i % 10 < 7 ? true : (i % 10 < 9 ? false : null)) ?? e;
    }
    expect(e!.moved, 0);
    expect(e.share, closeTo(7 / 9, 1e-9));
  });

  test('firstLine: the 35th percentile, robust SD with a floor', () {
    final f = firstLine([for (var i = 0; i <= 100; i++) i / 100]);
    expect(f.line, closeTo(0.35, 1e-9));
    expect(f.sd, closeTo(1.4826 * 0.25, 1e-9));
    expect(firstLine(List.filled(50, 3.0)).sd, LineRule.sdFloor);
  });

  test('bells: 3 s above the line within 4 clean seconds; a gate clears the count', () {
    final b = Bells();
    var rings = 0;
    for (var i = 0; i < 39; i++) {
      if (b.update(true, i % 4 != 0)) rings++;
    }
    expect(rings, 0);
    expect(b.update(true, true), isTrue);
    final c = Bells();
    for (var i = 0; i < 39; i++) {
      c.update(true, true);
    }
    expect(c.update(false, true), isFalse);
    for (var i = 0; i < 39; i++) {
      expect(c.update(true, true), isFalse);
    }
    expect(c.update(true, true), isTrue);
    final d = Bells();
    for (var i = 0; i < 40; i++) {
      d.update(true, i % 3 == 0);
    }
    expect(d.rung, isEmpty);
  });

  test('sleep guard: each sign fires on its own and not on a steady baseline', () {
    const base = GuardBaseline(alpha: 100, ratio: 0.5, iaf: 10);
    GuardState feed(SleepGuard g, int sec, double a, double th, [double? hz]) {
      late GuardState st;
      for (var i = 0; i < sec * 10; i++) {
        st = g.update(a, th);
        if (i % 10 == 0) g.peak(hz);
      }
      return st;
    }

    var g = SleepGuard(base);
    expect(feed(g, 120, 100, 50, 10).drowsy, isFalse);
    expect(feed(g, 12, 100, 80, 10).theta, isFalse);
    var st = feed(g, 2, 100, 80, 10);
    expect(st.theta && st.drowsy, isTrue);
    g = SleepGuard(base);
    feed(g, 30, 100, 50, 10);
    expect(feed(g, 4, 100, 50, 8.75).slow, isFalse, reason: 'needs 5 clear peaks');
    expect(feed(g, 8, 100, 50, 8.75).slow, isTrue);
    expect(feed(g, 10, 100, 50, 9.5).slow, isFalse, reason: '0.5 Hz slower is not enough');
    g = SleepGuard(base);
    feed(g, 30, 100, 50, 10);
    expect(feed(g, 15, 40, 20).faded, isFalse);
    st = feed(g, 1, 40, 20);
    expect(st.faded, isTrue);
    expect(st.theta, isFalse);
    g.reset();
    expect(g.update(100, 50).drowsy, isFalse);
  });

  test('guardBaseline: medians of the window means, clean steps only', () {
    final alpha = List.filled(100, 100.0), theta = List.filled(100, 30.0), clean = List.filled(100, true);
    alpha[90] = 1e6;
    clean[90] = false;
    final b = guardBaseline(alpha, theta, clean, 9.5);
    expect(b.alpha, 100);
    expect(b.ratio, closeTo(0.3, 1e-12));
    expect(b.iaf, 9.5);
  });

  test('BandPower: a 10 Hz sine of amplitude 10 gives about 50 µV² at 8-12 Hz and almost nothing at 30-45', () {
    expect(settle(BandPower(8, 12), sine(10, 10, 1000)), closeTo(50, 2));
    expect(settle(BandPower(30, 45, notch: 50, quadrature: false), sine(10, 10, 1000)), lessThan(0.05));
    expect(settle(BandPower(30, 45, notch: 50, quadrature: false, tau: 0.25), sine(36.7, 10, 2000)), closeTo(50, 4));
  });

  test('mapping: S-curve, neutral under gates, drowsy brighter, jaw roughens', () {
    expect(sCurve(-2), 0);
    expect(sCurve(0), 0.5);
    expect(sCurve(2), 1);
    final lo = mapState(z: -2, jaw: 0, quality: 'good', veto: null);
    final hi = mapState(z: 2, jaw: 0, quality: 'good', veto: null);
    expect(hi.rain < lo.rain && hi.rainTone < lo.rainTone && hi.warmth > lo.warmth, isTrue);
    expect(hi.bellsAllowed, isTrue);
    for (final quality in ['poor', 'none', 'learning', 'settling']) {
      final t = mapState(z: 1, jaw: 0, quality: quality, veto: null);
      expect((t.calm, t.neutral, t.bellsAllowed), (neutralCalm, true, false));
    }
    expect(mapState(z: 1, jaw: 0, quality: 'good', veto: 'drowsy').calm, nudgeCalm);
    final j = mapState(z: 1, jaw: 0.6, quality: 'good', veto: 'muscle');
    expect((j.rough, j.bellsAllowed), (0.6, false));
  });

  test('mixer: rough rises fast and falls slowly; training glides faster than relax', () {
    final start = {for (final k in mixTimes['training']!.keys) k: 0.0};
    final mx = Mixer(start, mixTimes['relax']);
    var v = mx.step({...start, 'rough': 1}, 0.25);
    expect(v['rough'], greaterThan(0.9));
    v = mx.step({...start, 'rough': 0}, 0.25);
    expect(v['rough'], greaterThan(0.7));
    final fast = Mixer(start).step({...start, 'calm': 1, 'rain': 1}, 0.25);
    expect(fast['rain'], greaterThan(0.6));
  });

  test('helpers match JavaScript: rounding, number printing, float32, percentile, channel quality', () {
    expect(jsRound(-2.5), -2);
    expect(jsRound(2.5), 3);
    expect(jsRound(0.49999999999999994), 0);
    expect(r3(-0.0004), 0);
    expect(r3(-0.0004)!.isNegative, isFalse);
    expect(jsNum(10), '10');
    expect(jsNum(9.75), '9.75');
    expect(fround(0.1), closeTo(0.1, 1e-8));
    expect(fround(0.1) == 0.1, isFalse);
    expect(percentile([3, 1, 2], 0.5), 2);
    expect(percentile([0, 10], 0.1), 1);
    expect(channelQuality(sine(10, 10).toF32()), 'ok');
    expect(channelQuality(sine(10, 10).toF32(), noContact: true), 'off');
    expect(channelQuality(List.filled(250, 0.0).toF32()), 'off');
    expect(channelQuality(sine(1, 200).toF32()), 'noisy');
  });
}

extension on List<double> {
  Float32List toF32() => Float32List.fromList(this);
}
