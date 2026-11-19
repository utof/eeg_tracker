// The robust trend the learning verdict fits across sessions (docs/evidence/meditation-feedback.md; the research
// report: "after 8 or more sessions the app fits robust trends ... learning only if the 90 % range is clear of
// zero"): the Theil-Sen slope, the median of the slopes between every pair of sessions, so one wild session
// cannot swing it, and Sen's (1968) range from the spread of Kendall's S. The same numbers as SciPy's
// `stats.theilslopes(y, x, alpha=0.9)` (app/test/fixtures/make_trend_fixture.py). Its range is clear of zero
// about when a Mann-Kendall trend test would say p < 0.1. Pure.
import 'dart:math' as math;

/// The slope per step of x, and its 90 % range. [n]: the number of points.
typedef Trend = ({double slope, double low, double high, int n});

/// The standard normal's 95th percentile: a two-sided 90 % range (SciPy: -special.ndtri(0.05)).
const double z90 = 1.6448536269514729;

/// Theil-Sen slope of [y] against [x] with its 90 % range; null without two different x values.
Trend? theilSen(List<double> x, List<double> y) {
  final n = y.length;
  if (x.length != n) throw ArgumentError('x and y differ in length');
  final slopes = <double>[];
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final dx = x[i] - x[j];
      if (dx != 0) slopes.add((y[i] - y[j]) / dx);
    }
  }
  if (slopes.isEmpty) return null;
  slopes.sort();
  final nt = slopes.length, mid = nt ~/ 2;
  final slope = nt.isOdd ? slopes[mid] : 0.5 * slopes[mid - 1] + 0.5 * slopes[mid];
  // Sen (1968), equation 2.6: the variance of Kendall's S, less what tied values take away
  double ties(List<double> v) {
    final counts = <double, int>{};
    for (final a in v) {
      counts[a] = (counts[a] ?? 0) + 1;
    }
    return counts.values.fold(0.0, (s, k) => s + k * (k - 1) * (2 * k + 5));
  }

  final sigsq = (n * (n - 1) * (2 * n + 5) - ties(x) - ties(y)) / 18;
  final sigma = math.sqrt(math.max(0, sigsq));
  final hi = math.min(roundHalfEven((nt + z90 * sigma) / 2), nt - 1);
  final lo = math.max(roundHalfEven((nt - z90 * sigma) / 2) - 1, 0);
  return (slope: slope, low: slopes[lo], high: slopes[hi], n: n);
}

/// Rounds to the nearest integer, a half to the even one (numpy's `round`, which SciPy uses for the ranks).
int roundHalfEven(double v) {
  final f = v.floorToDouble(), d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}
