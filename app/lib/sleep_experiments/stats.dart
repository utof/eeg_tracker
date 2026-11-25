// The arithmetic of a sleep experiment (DECISIONS rows 838, 896, 1050-1069). Pure; numbers in, numbers out.
//
// - How many nights each way: about 16 / (expected change / your own night-to-night spread)^2, plus a quarter
//   because one night resembles the next, never under 5 (research 2026-11-24, section 3).
// - The difference: the mean of the nights with, minus the mean of the nights without.
// - The test: the same difference with the labels shuffled. Free nights: every way to deal the labels (up to
//   200 000, else 20 000 seeded shuffles). Nights the app picked: every order its draw could have given (blocks
//   of 4 with 2 of each). The range is every constant effect that test does not reject at 5 %, so the range and the
//   verdict cannot disagree (the self-experiments' rule, row 203).
// - Matched: the same difference among nights of the same kind of day (work day, day off) whose sleep began within
//   an hour of the usual for that kind of day (row 838).
import 'dart:math' as math;
import 'dart:typed_data';

import '../training/check.dart' show blockLayouts;

/// Planning values.
abstract final class StatRule {
  /// Nights of each kind before the two averages are shown at all.
  static const int minPerPile = 5;

  /// Nights of each kind before any verdict, whatever the spread says (row 896).
  static const int minForVerdict = 10;

  /// A result is called a difference when the test's p is under this.
  static const double alpha = 0.05;

  /// Ordinary nights before your own spread is used instead of other people's.
  static const int ownSpreadNights = 14;

  /// On top of the textbook figure, because one night resembles the next.
  static const double extra = 1.25;

  /// The app's draw: blocks of this many test nights, half of them "with".
  static const int blockSize = 4, withPerBlock = 2;

  /// Sleep must begin within this many minutes of the usual for that kind of day to be matched.
  static const double matchWithinMin = 60;

  static const int maxExact = 200000, draws = 20000;
}

double mean(List<double> v) => v.fold(0.0, (a, b) => a + b) / v.length;

/// The usual spread from one night to the next (sample standard deviation); 0 with fewer than 2 values.
double spreadOf(List<double> v) {
  if (v.length < 2) return 0;
  final m = mean(v);
  return math.sqrt(v.fold(0.0, (a, b) => a + (b - m) * (b - m)) / (v.length - 1));
}

double median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Nights needed with, and as many without, to have 4 chances in 5 of seeing a change of [effect] against a
/// night-to-night spread of [spread]. Null when either is not a positive number.
int? nightsNeeded(double effect, double spread) {
  if (!(effect > 0) || !(spread > 0)) return null;
  final signal = effect / spread;
  return math.max(StatRule.minPerPile, (StatRule.extra * 16 / (signal * signal)).ceil());
}

/// The labellings chance could have given, each reduced to what the test needs: over the nights with a number, the
/// [sum] of the numbers labelled "with", how many ([n]), and how many of those really were "with" ([same]).
class Shuffles {
  Shuffles._(this.sum, this.n, this.same, this.exact, this.total, this.have, this.realWith, this.realSum);
  final Float64List sum;
  final Int32List n, same;

  /// True: every possible labelling. False: seeded random ones.
  final bool exact;
  final double total, realSum;
  final int have, realWith;

  /// Nights that fell as they fell: every way to give [withIt]'s number of "with" labels to the nights.
  factory Shuffles.free(
    List<double> values,
    List<bool> withIt, {
    int maxExact = StatRule.maxExact,
    int draws = StatRule.draws,
    int seed = 1,
  }) {
    final have = values.length, k = withIt.where((w) => w).length;
    final sums = <double>[], ns = <int>[], sames = <int>[];
    var ways = 1.0;
    for (var i = 0; i < k; i++) {
      ways = ways * (have - i) / (i + 1);
    }
    final exact = ways <= maxExact + 0.5;
    if (exact) {
      void walk(int from, int left, double s, int m) {
        if (left == 0) {
          sums.add(s);
          ns.add(k);
          sames.add(m);
          return;
        }
        for (var i = from; i <= have - left; i++) {
          walk(i + 1, left - 1, s + values[i], m + (withIt[i] ? 1 : 0));
        }
      }

      walk(0, k, 0, 0);
    } else {
      final r = math.Random(seed), idx = [for (var i = 0; i < have; i++) i];
      for (var d = 0; d < draws; d++) {
        var s = 0.0, m = 0;
        for (var i = 0; i < k; i++) {
          final j = i + r.nextInt(have - i), t = idx[i];
          idx[i] = idx[j];
          idx[j] = t;
          s += values[idx[i]];
          if (withIt[idx[i]]) m++;
        }
        sums.add(s);
        ns.add(k);
        sames.add(m);
      }
    }
    return Shuffles._pack(sums, ns, sames, exact, values, withIt);
  }

  /// Nights the app picked, in the order it picked them: [values] has one entry per pick (null: no number for
  /// that night), [picks] says which were "with". The labellings are every order the draw could have given.
  factory Shuffles.picked(
    List<double?> values,
    List<bool> picks, {
    int maxExact = StatRule.maxExact,
    int draws = StatRule.draws,
    int seed = 1,
  }) {
    final count = picks.length, blocks = (count / StatRule.blockSize).ceil();
    final layouts = blockLayouts(StatRule.blockSize, StatRule.withPerBlock);
    final sums = <double>[], ns = <int>[], sames = <int>[];
    final exact = math.pow(layouts.length, blocks) <= maxExact;
    (double, int, int) add(int b, List<int> layout, double s, int n, int m) {
      for (final off in layout) {
        final i = b * StatRule.blockSize + off;
        if (i >= count) continue;
        final v = values[i];
        if (v == null) continue;
        s += v;
        n++;
        if (picks[i]) m++;
      }
      return (s, n, m);
    }

    if (exact) {
      void walk(int b, double s, int n, int m) {
        if (b == blocks) {
          sums.add(s);
          ns.add(n);
          sames.add(m);
          return;
        }
        for (final layout in layouts) {
          final (s2, n2, m2) = add(b, layout, s, n, m);
          walk(b + 1, s2, n2, m2);
        }
      }

      walk(0, 0, 0, 0);
    } else {
      final r = math.Random(seed);
      for (var d = 0; d < draws; d++) {
        var s = 0.0, n = 0, m = 0;
        for (var b = 0; b < blocks; b++) {
          (s, n, m) = add(b, layouts[r.nextInt(layouts.length)], s, n, m);
        }
        sums.add(s);
        ns.add(n);
        sames.add(m);
      }
    }
    final kept = <double>[], with_ = <bool>[];
    for (var i = 0; i < count; i++) {
      if (values[i] == null) continue;
      kept.add(values[i]!);
      with_.add(picks[i]);
    }
    return Shuffles._pack(sums, ns, sames, exact, kept, with_);
  }

  factory Shuffles._pack(List<double> sums, List<int> ns, List<int> sames, bool exact, List<double> values, List<bool> withIt) {
    var total = 0.0, realSum = 0.0, realWith = 0;
    for (var i = 0; i < values.length; i++) {
      total += values[i];
      if (withIt[i]) {
        realSum += values[i];
        realWith++;
      }
    }
    return Shuffles._(Float64List.fromList(sums), Int32List.fromList(ns), Int32List.fromList(sames), exact, total, values.length, realWith, realSum);
  }

  int get count => sum.length;
  bool get bothKinds => realWith > 0 && realWith < have;

  /// With minus without of the means as the nights really fell, after taking [effect] off every real "with" night.
  double diff([double effect = 0]) => (realSum - effect * realWith) / realWith - (total - realSum) / (have - realWith);

  /// The share of labellings whose difference is at least as far from zero as the real one, after taking [effect]
  /// off every real "with" night (two-sided; a labelling with no night of one kind counts as far). Sampled
  /// labellings count the real one too.
  double p([double effect = 0]) {
    final obs = diff(effect).abs() - 1e-9, all = total - effect * realWith;
    var hits = 0;
    for (var k = 0; k < sum.length; k++) {
      final m = n[k];
      if (m == 0 || m == have) {
        hits++;
        continue;
      }
      final s = sum[k] - effect * same[k];
      if ((s / m - (all - s) / (have - m)).abs() >= obs) hits++;
    }
    return exact ? hits / sum.length : (hits + 1) / (sum.length + 1);
  }
}

/// Every constant effect the test does not reject at [alpha]. [step]: the numbers' own spread (the search's first
/// step). Null when the test cannot reject anything: no honest range exists.
({double low, double high})? rangeOf(Shuffles s, double step, {double alpha = StatRule.alpha}) {
  if (!s.bothKinds) return null;
  final centre = s.diff(), first = step > 0 ? step : 1.0;
  bool kept(double d) => s.p(d) >= alpha;
  double? edge(int sign) {
    var inside = centre, outside = double.nan;
    for (var k = 0; k < 40; k++) {
      final d = centre + sign * first * math.pow(2, k) / 8;
      if (!kept(d)) {
        outside = d;
        break;
      }
      inside = d;
    }
    if (outside.isNaN) return null;
    for (var i = 0; i < 40; i++) {
      final mid = (inside + outside) / 2;
      if (kept(mid)) {
        inside = mid;
      } else {
        outside = mid;
      }
    }
    return inside;
  }

  final low = edge(-1), high = edge(1);
  return low == null || high == null ? null : (low: low, high: high);
}

/// One night for matching: its number, its pile, when sleep began (minutes after noon) and the kind of day.
typedef MatchNight = ({double value, bool withIt, double startMin, bool dayOff});

/// With minus without among similar nights: work-day nights and day-off nights apart, each keeping only the nights
/// whose sleep began within [within] minutes of the middle one of that kind of day; the two differences are then
/// averaged by how many "with" nights each kind of day kept. Null when no kind of day keeps both piles.
({double diff, int nWith, int nWithout})? matchedDiff(List<MatchNight> nights, {double within = StatRule.matchWithinMin}) {
  var weighted = 0.0, nWith = 0, nWithout = 0;
  for (final off in [false, true]) {
    final kind = [
      for (final n in nights)
        if (n.dayOff == off) n,
    ];
    if (kind.isEmpty) continue;
    final usual = median([for (final n in kind) n.startMin]);
    final a = <double>[], b = <double>[];
    for (final n in kind) {
      if ((n.startMin - usual).abs() <= within) (n.withIt ? a : b).add(n.value);
    }
    if (a.isEmpty || b.isEmpty) continue;
    weighted += (mean(a) - mean(b)) * a.length;
    nWith += a.length;
    nWithout += b.length;
  }
  return nWith == 0 ? null : (diff: weighted / nWith, nWith: nWith, nWithout: nWithout);
}
