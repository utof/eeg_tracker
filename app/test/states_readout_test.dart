// Sound for states: "what the brain does during the sound" (lib/states/readout.dart). Power per whole Hz over the
// last 2 s of the back electrodes, against the quiet minute, with the beat's rate (and twice it) left out, because the
// hearing part of the brain answers at the pulse rate and would otherwise count as "more alpha".
import 'dart:math' as math;

import 'package:eeg_tracker/detectors/detectors.dart' show Second;
import 'package:eeg_tracker/states/readout.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> wave(Map<double, double> hzAmp, {double offset = 0, int n = windowSamples, int from = 0}) => [
  for (var i = from; i < from + n; i++)
    offset + hzAmp.entries.fold(0.0, (s, e) => s + e.value * math.sin(2 * math.pi * e.key * i / 250)),
];

List<double> flat([double v = 1]) => List<double>.filled(readoutTopHz + 1, v);

List<double> withBins(Map<int, double> bins) {
  final p = flat();
  bins.forEach((k, v) => p[k] = v);
  return p;
}

Second clean(int k) => Second(k);

void main() {
  group('power per whole Hz', () {
    test('a 10 Hz wave lands on 10 Hz only (Hann window: 9 and 11 Hz are its zeros); an offset changes nothing', () {
      final p = powers(wave({10: 20}));
      expect(p.length, readoutTopHz + 1);
      for (final f in [1, 2, 5, 8, 9, 11, 12, 15, 19]) {
        expect(p[f], lessThan(p[10] * 1e-3), reason: '$f Hz');
      }
      final shifted = powers(wave({10: 20}, offset: 3000));
      for (var f = 1; f <= readoutTopHz; f++) {
        expect(shifted[f], closeTo(p[f], p[10] * 1e-6), reason: '$f Hz');
      }
      expect(() => powers(List.filled(10, 0)), throwsArgumentError);
    });

    test('power grows with the square of the amplitude', () {
      expect(powers(wave({6: 40}))[6] / powers(wave({6: 20}))[6], closeTo(4, 1e-9));
    });
  });

  group('left out', () {
    test('the beat rate ± 1 Hz and twice it ± 1 Hz, rounded, inside 1-19 Hz', () {
      expect(leftOut(null), isEmpty);
      expect(leftOut(10), {9, 10, 11, 19});
      expect(leftOut(4.4), {3, 4, 5, 7, 8, 9});
      expect(leftOut(16), {15, 16, 17});
      expect(leftOut(1), {1, 2, 3});
    });

    test('band means skip what is left out; nothing left is NaN', () {
      final p = withBins({8: 2, 9: 50, 10: 50, 11: 50, 12: 4});
      expect(band(p, 8, 12, const {}), closeTo((2 + 150 + 4) / 5, 1e-12));
      expect(band(p, 8, 12, leftOut(10)), closeTo(3, 1e-12));
      expect(band(p, 9, 11, leftOut(10)).isNaN, isTrue);
    });
  });

  group('readout against the quiet minute', () {
    test('no comparison before 20 clean quiet seconds', () {
      final r = Readout();
      for (var i = 0; i < Readout.minBaselineS - 1; i++) {
        r.quiet(flat());
      }
      expect(r.hasBaseline, isFalse);
      expect(r.sound(0, flat(2), null), isNull);
      r.quiet(flat());
      expect(r.hasBaseline, isTrue);
      expect(r.baselineS, Readout.minBaselineS);
    });

    test('more alpha and fewer slow waves read as ratios of the quiet minute', () {
      final r = Readout();
      for (var i = 0; i < 30; i++) {
        r.quiet(flat());
      }
      final s = r.sound(5, withBins({8: 1.5, 9: 1.5, 10: 1.5, 11: 1.5, 12: 1.5, 4: 0.5, 5: 0.5, 6: 0.5, 7: 0.5}), null)!;
      expect(s.alpha, closeTo(1.5, 1e-12));
      expect(s.slow, closeTo(0.5, 1e-12));
      expect(s.echo, isNull);
    });

    test('the brain\'s echo of a 10 Hz beat is not "more alpha": it shows as the echo only', () {
      final r = Readout();
      for (var i = 0; i < 30; i++) {
        r.quiet(flat());
      }
      final s = r.sound(5, withBins({10: 9, 20 - 1: 1}), 10)!;
      expect(s.alpha, closeTo(1, 1e-12), reason: '9-11 Hz left out');
      expect(s.echo, closeTo(9, 1e-12));
      final naive = r.sound(6, withBins({10: 9}), null)!;
      expect(naive.alpha, greaterThan(2), reason: 'without leaving it out the echo would count as alpha');
    });

    test('live: medians of the last 30 clean seconds; epochs of 30 s of sound; the whole session', () {
      final r = Readout();
      for (var i = 0; i < 30; i++) {
        r.quiet(flat());
      }
      expect(r.live, isNull);
      for (var s = 0; s < 75; s++) {
        final a = s < 30 ? 1.2 : (s < 60 ? 2.0 : 3.0);
        r.sound(s, withBins({8: a, 9: a, 10: a, 11: a, 12: a}), null);
      }
      expect(r.live!.alpha, closeTo(2.5, 1e-12), reason: 'last 30: 15 at 2.0 and 15 at 3.0, median of an even count');
      expect([for (final e in r.epochs) (e.index, e.cleanS)], [(0, 30), (1, 30), (2, 15)]);
      expect(r.epochs.map((e) => e.alpha), [closeTo(1.2, 1e-12), closeTo(2, 1e-12), closeTo(3, 1e-12)]);
      expect(r.summary!.alpha, closeTo(2.0, 1e-12));
      expect(r.summary!.cleanS, 75);
    });
  });

  group('the back electrodes, second by second', () {
    test('a whole second\'s spectrum covers it and the second before; both must be clean', () {
      final feed = SpectrumFeed();
      final o1 = wave({10: 20}, n: 1000), o2 = wave({6: 20}, n: 1000);
      for (var i = 0; i < 1000; i++) {
        feed.push(o1[i], o2[i]);
      }
      expect(feed.take(clean(0)), isNull, reason: 'second 0 has no second before it');
      final p = feed.take(clean(1))!;
      expect(p[10], greaterThan(100 * p[8]));
      expect(p[6], greaterThan(100 * p[8]), reason: 'both channels, averaged');
      final o1Bad = clean(2)..qrange[0] = 300; // O1 moved too much in second 2
      final only2 = feed.take(o1Bad)!;
      expect(only2[10], lessThan(only2[6] * 1e-3), reason: 'O1 left out');
      final moved = clean(3)
        ..qrange[0] = 300
        ..qrange[1] = 300
        ..qrange[2] = 300;
      expect(feed.take(moved), isNull, reason: 'movement');
    });

    test('a blink or a hole in the signal makes the second unusable', () {
      final feed = SpectrumFeed();
      final x = wave({10: 20}, n: 1500);
      for (final v in x) {
        feed.push(v, v);
      }
      feed.take(clean(0));
      expect(feed.take(clean(1)..blinks = 1), isNull);
      expect(feed.take(clean(2)), isNull, reason: 'the second before had a blink');
      expect(feed.take(clean(3)), isNotNull, reason: 'clean again');
      expect(feed.take(clean(9)), isNull, reason: 'not made yet');
      final gap = SpectrumFeed();
      for (final v in x) {
        gap.push(v, v);
      }
      gap.take(clean(0));
      expect(gap.take(clean(1)..gap = true), isNull);
    });
  });
}
