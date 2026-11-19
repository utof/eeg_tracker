// "Your usual" and when an arrow shows (DECISIONS row 122). Robust and plain:
//   - your usual = the middle value (median) of up to the last 28 days with a value before the day judged (the day
//     itself never counts), shown from 7 such days;
//   - the normal day-to-day spread = 1.4826 x the median distance from it (MAD; equals the standard deviation for
//     bell-shaped data, but one odd day barely moves it);
//   - an arrow only from 14 days, and only when the day is at least 2 spreads away from the usual AND at least the
//     measure's smallest change that matters (sleep 1 hour, ratings 2 points, a day's mean rating 1 point, reaction
//     time 10 %, jaw muscle bursts a quarter of the usual, a planning value): the research's
//     "beyond normal spread" rules (early-warning pass 2, Q4). The band shown as "your normal range" is exactly
//     the stretch with no arrow.
// Alpha strength and the eyes-closed rise are judged on a log scale (a doubling counts the same up and down).
import 'dart:math' as math;

import 'days.dart';

const int usualWindowDays = 28;
const int usualMinDays = 7;
const int arrowMinDays = 14;
const double madToSd = 1.4826;
const double arrowSpreads = 2;

/// How a measure is judged.
enum Scale {
  /// Minutes of sleep: 2 spreads and at least 60 minutes.
  minutes(minChange: 60),

  /// A 1-5 or 1-9 rating: 2 spreads and at least 2 points.
  rating(minChange: 2),

  /// The mean of a day's 1-5 ratings (sharpness in the day, DECISIONS row 287): 2 spreads and at least 1 point.
  meanRating(minChange: 1),

  /// Reaction time (ms): 2 spreads and at least 10 % of the usual.
  reaction(relChange: 0.10),

  /// Counts an hour (jaw muscle bursts an hour asleep): 2 spreads and at least a quarter of the usual.
  rate(relChange: 0.25),

  /// Powers and ratios: on a log scale, 2 spreads.
  log(logScale: true),

  /// Anything else measured: 2 spreads.
  plain(),

  /// Things you choose or note (practice minutes, coffee): a usual, never an arrow.
  noArrows(arrows: false);

  const Scale({this.minChange = 0, this.relChange = 0, this.logScale = false, this.arrows = true});
  final double minChange;
  final double relChange;
  final bool logScale;
  final bool arrows;
}

enum Arrow { up, down, none }

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

class Usual {
  const Usual._({required this.days, required this.scale, this.median, this.spread, this.half, this.centre});

  /// Days with a value in the window.
  final int days;
  final Scale scale;

  /// The usual value (in the measure's own units), null before [usualMinDays].
  final double? median;

  /// The normal day-to-day spread (robust standard deviation; on the log scale for log measures).
  final double? spread;

  /// Half the no-arrow band and its centre, on the judging scale (log for log measures).
  final double? half;
  final double? centre;

  bool get ready => median != null;
  bool get arrowsReady => ready && scale.arrows && days >= arrowMinDays;
  int get daysToUsual => math.max(0, usualMinDays - days);
  int get daysToArrows => math.max(0, arrowMinDays - days);

  double _back(double v) => scale.logScale ? math.exp(v) : v;

  /// The normal range (no arrow inside it), once arrows can show.
  double? get low => arrowsReady ? _back(centre! - half!) : null;
  double? get high => arrowsReady ? _back(centre! + half!) : null;

  Arrow arrow(double value) {
    if (!arrowsReady || half! <= 0 || (scale.logScale && value <= 0)) return Arrow.none;
    final d = (scale.logScale ? math.log(value) : value) - centre!;
    if (d.abs() < half!) return Arrow.none;
    return d > 0 ? Arrow.up : Arrow.down;
  }
}

/// Your usual for [day] from a series of day key -> value.
Usual usualOf(Map<String, double> series, String day, Scale scale) {
  final before = series.keys.where((k) => k.compareTo(day) < 0).toList()..sort();
  final window = before.length > usualWindowDays ? before.sublist(before.length - usualWindowDays) : before;
  return usualOfValues([for (final k in window) series[k]!], scale);
}

/// Your usual from the values of a window already chosen (the "unusual for you" card picks its own, lagged one:
/// lib/unusual/detector.dart); values that cannot be judged (not finite, or not positive on a log scale) are left
/// out.
Usual usualOfValues(List<double> window, Scale scale) {
  final values = [
    for (final v in window)
      if (v.isFinite && (!scale.logScale || v > 0)) v,
  ];
  if (values.length < usualMinDays) return Usual._(days: values.length, scale: scale);
  final judged = scale.logScale ? values.map(math.log).toList() : values;
  final centre = _median(judged);
  final spread = madToSd * _median([for (final v in judged) (v - centre).abs()]);
  final usual = scale.logScale ? math.exp(centre) : centre;
  final half = math.max(arrowSpreads * spread, math.max(scale.minChange, scale.relChange * usual.abs()));
  return Usual._(days: values.length, scale: scale, median: usual, spread: spread, half: half, centre: centre);
}

/// The value of the day before [day], if any ("same as yesterday").
double? yesterdayOf(Map<String, double> series, String day) => series[addDays(day, -1)];
