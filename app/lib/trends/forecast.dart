// Tomorrow morning's sleepiness, hidden until it earns its place (DECISIONS rows 63 and 124). The guess is the
// research's simplest strong baseline: half yesterday's rating, half your mean of the last 28 days (forecasting
// pass 2, rung 0). It is scored every day against "same as yesterday" on the days before (rolling origin: each
// day guessed only from the days before it) and shown only when
//   - 60 days have a sleepiness rating,
//   - over the last 60 scored days its mean error is at least 5 % smaller than "same as yesterday"'s, and
//   - today's rating is in (a guess seen before you rate can colour the rating).
// Then it is shown in words with a range (80 % of its past errors fall inside) and its track record.
import 'dart:math' as math;

import 'days.dart';

const int forecastMinRatedDays = 60;
const int forecastScoreDays = 60;
const double forecastMinSkill = 0.05;
const int _meanDays = 28, _meanMin = 7;

class Forecast {
  const Forecast({
    required this.shown,
    required this.why,
    required this.ratedDays,
    this.scoredDays = 0,
    this.value,
    this.low,
    this.high,
    this.mae,
    this.persistenceMae,
  });

  final bool shown;

  /// Why it is hidden, or what the track record is, in plain words.
  final String why;
  final int ratedDays;
  final int scoredDays;
  final double? value;
  final int? low, high;
  final double? mae, persistenceMae;

  /// How much smaller the guess's mean error is than "same as yesterday"'s (0.1 = 10 %).
  double? get skill => mae == null || persistenceMae == null || persistenceMae == 0 ? null : 1 - mae! / persistenceMae!;
}

double? _guess(Map<String, double> s, String day) {
  final y = s[addDays(day, -1)];
  if (y == null) return null;
  final past = [
    for (var k = 1; k <= _meanDays; k++)
      if (s[addDays(day, -k)] != null) s[addDays(day, -k)]!,
  ];
  if (past.length < _meanMin) return null;
  return 0.5 * y + 0.5 * past.reduce((a, b) => a + b) / past.length;
}

double _quantile(List<double> v, double q) {
  final s = [...v]..sort();
  final at = q * (s.length - 1);
  final lo = at.floor(), hi = math.min(lo + 1, s.length - 1);
  return s[lo] + (s[hi] - s[lo]) * (at - lo);
}

/// The sleepiness (1-9) forecast for the day after [today] from a day key -> rating series.
Forecast sleepinessForecast(Map<String, double> ratings, String today) {
  final rated = ratings.keys.where((k) => k.compareTo(today) <= 0).toList()..sort();
  if (rated.length < forecastMinRatedDays) {
    return Forecast(
      shown: false,
      ratedDays: rated.length,
      why: 'Hidden until $forecastMinRatedDays mornings have a sleepiness rating (${rated.length} so far), and then '
          'only if it beats "same as yesterday" by ${(forecastMinSkill * 100).round()} %.',
    );
  }
  final errs = <double>[], persist = <double>[];
  for (final d in rated) {
    final g = _guess(ratings, d);
    if (g == null) continue;
    errs.add((ratings[d]! - g).abs());
    persist.add((ratings[d]! - ratings[addDays(d, -1)]!).abs());
  }
  final n = math.min(forecastScoreDays, errs.length);
  final e = errs.sublist(errs.length - n), p = persist.sublist(persist.length - n);
  double mean(List<double> v) => v.isEmpty ? double.nan : v.reduce((a, b) => a + b) / v.length;
  final mae = mean(e), pmae = mean(p);
  final skill = pmae > 0 ? 1 - mae / pmae : double.negativeInfinity;
  String fmt(double v) => v.toStringAsFixed(1);
  final record = 'Over the last $n days this guess was off by ${fmt(mae)} points on average; '
      '"same as yesterday" by ${fmt(pmae)}.';
  if (n < forecastScoreDays ~/ 2 || !(skill >= forecastMinSkill)) {
    return Forecast(
      shown: false,
      ratedDays: rated.length,
      scoredDays: n,
      mae: mae,
      persistenceMae: pmae,
      why: 'Hidden: it does not beat "same as yesterday" by ${(forecastMinSkill * 100).round()} % yet. $record',
    );
  }
  if (ratings[today] == null) {
    return Forecast(
      shown: false,
      ratedDays: rated.length,
      scoredDays: n,
      mae: mae,
      persistenceMae: pmae,
      why: "Shown after today's check-in, so it cannot colour your answer.",
    );
  }
  final g = _guess(ratings, addDays(today, 1))!;
  final q = _quantile(e, 0.8);
  return Forecast(
    shown: true,
    ratedDays: rated.length,
    scoredDays: n,
    value: g,
    low: (g - q).round().clamp(1, 9),
    high: (g + q).round().clamp(1, 9),
    mae: mae,
    persistenceMae: pmae,
    why: record,
  );
}
