// The shared detectors and the drift-off detector on made-up signals (the recorded excerpts are in
// detectors_cross_check_test.dart): blinks, glances, jaw bursts, epoch flags, holes, and the drift-off steps and
// timers.
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/detectors.dart';
import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/detectors/filters.dart';
import 'package:flutter_test/flutter_test.dart';

const int fs = 250;
const List<double> offsets = [85000, 82000, 78000, 79000];

/// Four channels of white noise (µV) around the headband's electrode offsets.
List<List<double>> noise(int n, {double uv = 5, int seed = 1}) {
  final r = math.Random(seed);
  double g() => (r.nextDouble() + r.nextDouble() + r.nextDouble() - 1.5) * 2 * uv;
  return [
    for (var i = 0; i < n; i++) [for (var c = 0; c < 4; c++) offsets[c] + g()],
  ];
}

/// A blink-shaped dip at [atS] (fast fall, slower return), µV.
double dip(int i, double atS, double depth, double widthS) {
  final t = i / fs - atS, w = t < 0 ? widthS * 0.35 : widthS * 0.65;
  return -depth * math.exp(-(t / w) * (t / w));
}

/// Band-limited muscle-like noise (60-110 Hz) between [fromS] and [toS].
List<double> muscle(int n, double fromS, double toS, double uv, int seed) {
  final r = math.Random(seed), c = Chain(bandPair(60, 110));
  return [
    for (var i = 0; i < n; i++)
      () {
        final y = c.step((r.nextDouble() - 0.5) * 3.46 * uv);
        return i >= fromS * fs && i < toS * fs ? y : 0.0;
      }(),
  ];
}

Detectors run(List<List<double>> x, {List<bool>? missing, List<Second>? seconds}) {
  final d = Detectors(onSecond: seconds?.add);
  for (var i = 0; i < x.length; i++) {
    d.push(x[i], missing: missing?[i] ?? false);
  }
  d.finish();
  return d;
}

DriftOff feed(List<double> alpha, {Map<int, int> blinks = const {}, Set<int> unclean = const {}, Set<int> moving = const {}}) {
  final d = DriftOff(0);
  for (var k = 0; k < alpha.length; k++) {
    d.second(k, alpha[k], !unclean.contains(k), moving.contains(k), 1, blinks[k] ?? 0);
  }
  return d;
}

List<double> repeat(double v, int n) => List.filled(n, v);

void main() {
  test('blinks: dips on all four channels are found; slow, one-sided or shallow dips are not', () {
    const n = 30 * fs;
    final x = noise(n);
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < 4; c++) {
        x[i][c] += dip(i, 4, 90, 0.15) + dip(i, 9, 90, 0.8) + dip(i, 21, 35, 0.15) + dip(i, 26, 90, 0.15);
        if (c < 2) x[i][c] += dip(i, 14, 120, 0.15);
      }
    }
    final found = run(x).blinks;
    expect([for (final b in found) (b.i / fs).toStringAsFixed(1)], ['4.0', '26.0']);
    expect(found.every((b) => b.depth > 70 && b.t34.abs() < 10), isTrue);
  });

  test('glances: a step that pulls T3 and T4 apart is an eye movement; a common step is not', () {
    const n = 20 * fs;
    final x = noise(n);
    for (var i = 0; i < n; i++) {
      final step = (i >= 6 * fs ? 35.0 : 0.0) - (i >= 13 * fs ? 35.0 : 0.0);
      x[i][2] += step;
      x[i][3] -= step;
      if (i >= 17 * fs) {
        for (var c = 0; c < 4; c++) {
          x[i][c] += 80;
        }
      }
    }
    final moves = run(x).eyeMoves;
    expect([for (final m in moves) (m.i / fs).round()], [6, 13]);
    expect(moves[0].step, greaterThan(EyeRule.minUv));
    expect(moves[1].step, lessThan(-EyeRule.minUv));
  });

  test('jaw: muscle on both sides is a jaw burst, on one side a one-sided burst; none before a baseline', () {
    const n = 120 * fs;
    final x = noise(n);
    final t3 = muscle(n, 50, 53, 40, 1), t4 = muscle(n, 50, 53, 40, 2), only4 = muscle(n, 90, 93, 40, 3);
    final early = muscle(n, 10, 12, 40, 4);
    for (var i = 0; i < n; i++) {
      x[i][2] += t3[i] + early[i];
      x[i][3] += t4[i] + only4[i] + early[i];
    }
    final b = run(x).bursts;
    expect([for (final r in b) (r.start, r.end, r.kind)], [(50, 52, BurstKind.jaw), (90, 92, BurstKind.oneSided)]);
    expect(b.first.peakX, greaterThan(10));
  });

  test('epochs: flat channel degraded, a long hole missing; seconds come one second late with their blinks', () {
    const n = 3 * 30 * fs;
    final x = noise(n);
    final missing = List<bool>.filled(n, false);
    for (var i = 30 * fs; i < 60 * fs; i++) {
      x[i][0] = offsets[0];
    }
    for (var i = 60 * fs; i < 70 * fs; i++) {
      missing[i] = true;
    }
    for (var i = 0; i < n; i++) {
      for (var c = 0; c < 4; c++) {
        x[i][c] += dip(i, 80.5, 90, 0.15);
      }
    }
    final seconds = <Second>[];
    final d = run(x, missing: missing, seconds: seconds);
    expect([for (final e in d.epochs) e.quality], [EpochQuality.good, EpochQuality.degraded, EpochQuality.missing]);
    expect(d.epochs[1].usable, [false, true, true, true]);
    expect(d.epochs[2].gapS, 10);
    expect([for (final s in seconds) s.k], List.generate(90, (k) => k));
    expect(seconds[80].blinks, 1);
    expect(seconds.where((s) => s.gap).length, 10);
  });

  test('hold: a live hole is held and marked missing, as the BDF fills one', () {
    final x = noise(4 * fs);
    final d = Detectors();
    for (final r in x.take(2 * fs)) {
      d.push(r);
    }
    d.hold(fs);
    for (final r in x.skip(2 * fs)) {
      d.push(r);
    }
    expect(d.n, 5 * fs);
    expect(() => d.push([1, 2, double.nan, 4]), throwsArgumentError);
  });

  group('drift-off', () {
    test('baseline, then faded alpha: drowsy after 1 min, probably asleep after 3', () {
      final d = feed([...repeat(20, 60), ...repeat(15, 300), ...repeat(5, 600)]);
      expect(d.baselineAlpha, 20);
      expect(d.baselineDone, 59);
      expect(d.drowsyAt, 360 + 59);
      expect((d.onset, d.asleepAt), (360, 360 + 179));
      expect([for (final e in d.epochs.sublist(12, 19)) e.state.name], ['awake', 'drowsy', 'drowsy', 'drowsy', 'drowsy', 'asleep', 'asleep']);
    });

    test('open eyes (2 blinks), movement or an alpha burst break the run', () {
      final base = [...repeat(20, 60), ...repeat(15, 60)], faded = repeat(5, 240);
      final eyesOpen = feed([...base, ...faded], blinks: {120 + 95: 1, 120 + 110: 1});
      expect(eyesOpen.onset, isNull);
      expect(eyesOpen.drowsyAt, isNotNull);
      expect(feed([...base, ...faded], moving: {180, 181, 182}).onset, isNull);
      expect(feed([...base, ...repeat(5, 90), ...repeat(20, 30), ...repeat(5, 120)]).onset, isNull);
    });

    test('epochs without enough clean signal are skipped, not counted against the run', () {
      final d = feed([...repeat(20, 60), ...repeat(5, 240)], unclean: {for (var k = 120; k < 150; k++) k});
      expect(d.epochs[4].faded, isNull);
      expect((d.onset, d.asleepAt), (60, 60 + 7 * 30 - 1));
    });

    test('awake again after a minute of alpha; the next onset is found too', () {
      final d = feed([...repeat(20, 60), ...repeat(5, 240), ...repeat(20, 60), ...repeat(5, 210)]);
      expect(d.onsets.first.$1, 60);
      expect(d.wakes, [60 + 240 + 59]);
      expect(d.onsets.length, 2);
      expect(d.onsets[1].$1, 360);
    });

    test('timers: the sound stops by 45 min and the dream cue falls inside the usual window', () {
      final nothing = feed(repeat(20, 3000));
      var t = nothing.timers(const [], 0);
      expect((t.soundOffAt, t.dreamCueAt), (Drift.soundCapS, 600));
      t = nothing.timers(const [8, 12, 14, 30], 1);
      expect(t.dreamCueAt, 18 * 60);
      final asleep = feed([...repeat(20, 60), ...repeat(5, 300)]);
      t = asleep.timers(const [], 0.5);
      expect(t.soundFadeFrom, asleep.asleepAt! + 1);
      expect(t.soundOffAt, t.soundFadeFrom + Drift.soundFadeS);
      expect(t.dreamCueAt, asleep.drowsyAt! + 1);
      expect(() => asleep.timers(const [], 1.5), throwsArgumentError);
    });
  });
}
