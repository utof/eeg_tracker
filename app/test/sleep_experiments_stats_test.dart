// Sleep experiments, the arithmetic (DECISIONS rows 1050-1069): nights needed, the shuffle test for nights that
// fell as they fell and for nights the app picked, the range, and the matched difference. Expected values come from
// an independent brute-force Python version (itertools over every labelling), not from this code.
import 'package:eeg_tracker/sleep_experiments/stats.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> d(List<num> v) => [for (final x in v) x.toDouble()];

const wA = [78, 81, 74, 85, 79, 76], oA = [88, 84, 90, 86, 91, 83, 87];
const wB = [52, 61, 47, 70, 58, 66, 49, 73, 55, 63], oB = [75, 68, 59, 80, 71, 64, 77, 83, 69, 72];

void main() {
  test('nights needed: 16 over the signal squared, a quarter more, never under 5', () {
    expect(nightsNeeded(9.5, 6.5), 10);
    expect(nightsNeeded(3, 3), 20);
    expect(nightsNeeded(1.5, 3), 80);
    expect(nightsNeeded(34, 25), 11);
    expect(nightsNeeded(30, 10), 5);
    expect(nightsNeeded(0, 3), isNull);
    expect(nightsNeeded(3, 0), isNull);
  });

  test('mean, spread and median by hand', () {
    expect(mean(d(oA)), closeTo(87, 1e-12));
    expect(spreadOf(d(oA)), closeTo(2.943920288775949, 1e-12));
    expect(spreadOf([4]), 0);
    expect(median(d([5, 1, 9])), 5);
    expect(median(d([5, 1, 9, 7])), 6);
  });

  group('nights that fell as they fell', () {
    test('every labelling: difference, p and range (6 with, 7 without: 1716 ways)', () {
      final s = Shuffles.free(d([...wA, ...oA]), [for (var i = 0; i < 13; i++) i < 6]);
      expect(s.exact, isTrue);
      expect(s.count, 1716);
      expect(s.diff(), closeTo(-8.1666666667, 1e-9));
      expect(s.p(), closeTo(0.002913752913752914, 1e-12));
      final r = rangeOf(s, 4)!;
      expect(r.low, closeTo(-12.333, 0.02));
      expect(r.high, closeTo(-3.970, 0.02));
      // the range and the test agree: an effect just inside is kept, one just outside is rejected
      expect(s.p(r.low + 0.05), greaterThanOrEqualTo(0.05));
      expect(s.p(r.low - 0.05), lessThan(0.05));
    });

    test('nothing there: a large p, and the range holds zero', () {
      final s = Shuffles.free(d([60, 72, 65, 58, 70, 63, 69, 66, 61, 71, 64, 68, 59, 73]), [for (var i = 0; i < 14; i++) i < 7]);
      expect(s.p(), closeTo(0.8356643356643356, 1e-12));
      final r = rangeOf(s, 5)!;
      expect(r.low < 0 && r.high > 0, isTrue);
    });

    test('10 with, 10 without: all 184 756 ways, and 20 000 seeded shuffles land within 0.01 of them', () {
      final values = <double>[], labels = <bool>[];
      for (var i = 0; i < 10; i++) {
        values..add(wB[i].toDouble())..add(oB[i].toDouble());
        labels..add(true)..add(false);
      }
      final all = Shuffles.free(values, labels);
      expect(all.exact, isTrue);
      expect(all.count, 184756);
      expect(all.diff(), closeTo(-12.4, 1e-9));
      expect(all.p(), closeTo(0.003929507025482257, 1e-12));
      final some = Shuffles.free(values, labels, maxExact: 0, seed: 7);
      expect(some.exact, isFalse);
      expect(some.count, 20000);
      expect(some.p(), closeTo(0.003929507025482257, 0.01));
    });

    test('one pile empty: no range', () {
      expect(rangeOf(Shuffles.free(d([1, 2, 3]), [true, true, true]), 1), isNull);
    });
  });

  group('nights the app picked (blocks of 4, 2 of each)', () {
    List<bool> picks(String s) => [for (final c in s.split('')) c == '1'];

    test('three blocks, one night without a number: 216 orders', () {
      final s = Shuffles.picked([61, 55, 58, 66, 57, 64, null, 54, 67, 62, 56, 53], picks('100101101100'));
      expect(s.exact, isTrue);
      expect(s.count, 216);
      expect(s.realWith, 5);
      expect(s.have, 11);
      expect(s.diff(), closeTo(8.5, 1e-9));
      expect(s.p(), closeTo(0.009259259259259259, 1e-12));
      final r = rangeOf(s, 5)!;
      expect(r.low, closeTo(5.0, 0.02));
      expect(r.high, closeTo(12.0, 0.02));
    });

    test('a last block still open (10 picks)', () {
      final s = Shuffles.picked([61, 55, 58, 66, 57, 64, 60, 54, 67, 62], picks('1001011010'));
      expect(s.count, 216);
      expect(s.diff(), closeTo(6.4, 1e-9));
      expect(s.p(), closeTo(0.027777777777777776, 1e-12));
    });

    test('seeded draws stay within 0.01 of every order', () {
      final s = Shuffles.picked([61, 55, 58, 66, 57, 64, 60, 54, 67, 62], picks('1001011010'), maxExact: 0, seed: 3);
      expect(s.exact, isFalse);
      expect(s.p(), closeTo(0.027777777777777776, 0.01));
    });
  });

  group('matched nights', () {
    MatchNight n(double v, bool w, double start, {bool off = false}) => (value: v, withIt: w, startMin: start, dayOff: off);

    test('late nights are dropped, and work days and days off are compared apart', () {
      // work days: usual start 690 (23:30). with 80, 82; without 90, 88; a with-night at 02:00 (840) is left out
      // days off: usual start 750. with 70; without 76, 78
      final m = matchedDiff([
        n(80, true, 690), n(82, true, 700), n(60, true, 840), n(90, false, 680), n(88, false, 690),
        n(70, true, 750, off: true), n(76, false, 740, off: true), n(78, false, 760, off: true),
      ])!;
      // work days: 81 - 89 = -8 (2 with); days off: 70 - 77 = -7 (1 with); (-8*2 + -7*1) / 3
      expect(m.diff, closeTo(-23 / 3, 1e-12));
      expect(m.nWith, 3);
      expect(m.nWithout, 4);
    });

    test('no kind of day with both piles: nothing', () {
      expect(matchedDiff([n(1, true, 700), n(2, false, 700, off: true)]), isNull);
      expect(matchedDiff(const []), isNull);
    });
  });
}
