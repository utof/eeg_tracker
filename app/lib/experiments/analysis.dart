// A self-experiment's answer (DECISIONS rows 202-204). Pure; numbers in, words out.
//
// TESTED (the primary number only): the mean on "do" days minus the mean on "don't" days, every day counted as it
// was assigned whether you kept to it or not (intention to treat). The test is a randomisation test, the replay
// check's kind (training/reveal.dart): the same difference under every order of days the draw could have given
// (blocks of 4, every weekday with both kinds). It needs no bell curve and stays honest when one day resembles the
// next, because the only chance in it is the draw the app itself made. The range is every constant effect that
// test does not reject at 5 %, so the range and the verdict can never disagree.
//
// SEEN TOGETHER (never tested): the same difference by what you say you did, and the other numbers.
import 'dart:math' as math;
import 'dart:typed_data';

import '../training/check.dart' show blockLayouts;
import 'experiment.dart';

/// Every order is counted up to this many (7 blocks of 4 = 279 936); beyond it 50 000 seeded draws.
const int expMaxExact = 300000, expDraws = 50000;

/// The orders the draw could have given, each reduced to what the test needs. For an order s over the days with a
/// number: [sum] of the numbers on its "do" days, [n] such days, and [same] how many of them really were "do" days.
class Orders {
  Orders._(this.sum, this.n, this.same, this.exact, this.total, this.have, this.realDo, this.realSum);
  final Float64List sum;
  final Int32List n, same;

  /// True: every possible order. False: [expDraws] seeded random ones.
  final bool exact;

  /// The sum and count of all numbers, and of the real "do" days.
  final double total, realSum;
  final int have, realDo;

  int get count => sum.length;

  /// The orders the draw could have given for [order] (the real one, all planned days) and [values] (a day's
  /// number, null without one; days past the end of [values] have none).
  factory Orders.of(List<bool> order, List<double?> values, {int maxExact = expMaxExact, int draws = expDraws, int seed = 1}) {
    final days = order.length;
    double? at(int i) => i < values.length ? values[i] : null;
    final sizes = blockSizes(days);
    final layouts = [for (final z in sizes) blockLayouts(z, z ~/ 2)];
    final starts = <int>[];
    var d0 = 0;
    for (final z in sizes) {
      starts.add(d0);
      d0 += z;
    }
    final colDays = [for (var c = 0; c < 7; c++) (days - c + 6) ~/ 7];
    final colDo = List.filled(7, 0);
    bool spread() {
      for (var c = 0; c < 7; c++) {
        if (colDays[c] >= 3 && (colDo[c] == 0 || colDo[c] == colDays[c])) return false;
      }
      return true;
    }

    final sums = <double>[], ns = <int>[], sames = <int>[];
    final all = layouts.fold<double>(1, (a, l) => a * l.length);
    final exact = all <= maxExact;
    if (exact) {
      void walk(int b, double sum, int n, int same) {
        if (b == sizes.length) {
          if (spread()) {
            sums.add(sum);
            ns.add(n);
            sames.add(same);
          }
          return;
        }
        for (final layout in layouts[b]) {
          var s = sum, k = n, m = same;
          for (final off in layout) {
            final i = starts[b] + off;
            colDo[i % 7]++;
            final v = at(i);
            if (v != null) {
              s += v;
              k++;
              if (order[i]) m++;
            }
          }
          walk(b + 1, s, k, m);
          for (final off in layout) {
            colDo[(starts[b] + off) % 7]--;
          }
        }
      }

      walk(0, 0, 0, 0);
    } else {
      final r = math.Random(seed);
      while (sums.length < draws) {
        colDo.fillRange(0, 7, 0);
        var s = 0.0, k = 0, m = 0;
        for (var b = 0; b < sizes.length; b++) {
          for (final off in layouts[b][r.nextInt(layouts[b].length)]) {
            final i = starts[b] + off;
            colDo[i % 7]++;
            final v = at(i);
            if (v != null) {
              s += v;
              k++;
              if (order[i]) m++;
            }
          }
        }
        if (spread()) {
          sums.add(s);
          ns.add(k);
          sames.add(m);
        }
      }
    }
    var total = 0.0, realSum = 0.0, have = 0, realDo = 0;
    for (var i = 0; i < days; i++) {
      final v = at(i);
      if (v == null) continue;
      total += v;
      have++;
      if (order[i]) {
        realSum += v;
        realDo++;
      }
    }
    return Orders._(Float64List.fromList(sums), Int32List.fromList(ns), Int32List.fromList(sames), exact, total, have, realDo, realSum);
  }

  /// Days of each kind with a number.
  bool get bothKinds => realDo > 0 && realDo < have;

  /// do minus don't of the means as the days really fell, after taking [effect] off every real "do" day.
  double diff([double effect = 0]) => (realSum - effect * realDo) / realDo - (total - realSum) / (have - realDo);

  /// The share of orders whose difference is at least as far from zero as the real one, after taking [effect]
  /// off every real "do" day (two-sided; an order with no day of one kind counts as far). Sampled orders count
  /// the real one too.
  double p([double effect = 0]) {
    final obs = diff(effect).abs() - 1e-12, all = total - effect * realDo;
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

/// The range of constant effects the randomisation test does not reject at [alpha]: an effect stays in the range
/// while the test, with that effect taken off every "do" day, gives p >= alpha. [spread]: the numbers' own range
/// (the search's first step). Null when the test cannot reject anything (too few days): no honest range exists.
({double low, double high})? shiftRange(Orders o, double spread, {double alpha = ExpRule.alpha}) {
  if (!o.bothKinds) return null;
  final centre = o.diff(), step = spread > 0 ? spread : 1.0;
  bool kept(double d) => o.p(d) >= alpha;
  double? edge(int sign) {
    var inside = centre, outside = double.nan;
    for (var k = 0; k < 40; k++) {
      final d = centre + sign * step * math.pow(2, k) / 8;
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

enum Verdict {
  /// Under [ExpRule.minPerArm] days of a kind, or no range can be given.
  tooFew('too few days to say'),

  /// p under [ExpRule.alpha]: the range leaves out zero.
  likelyReal('likely real for you'),

  /// The whole range is smaller than the smallest difference that matters.
  littleOrNone('little or no effect for you'),

  /// Anything else.
  notClear('not clear yet');

  const Verdict(this.words);
  final String words;
}

/// The tested difference of the primary number. On the judging scale: natural logs for powers and ratios.
class Tested {
  const Tested({required this.diff, required this.p, required this.orders, required this.exact, required this.nDo, required this.nDont, this.low, this.high, required this.matters});
  final double diff, p;
  final int orders;
  final bool exact;
  final int nDo, nDont;
  final double? low, high;

  /// The smallest difference that matters, on the same scale.
  final double matters;
}

/// A plain difference that was not tested.
class Seen {
  const Seen(this.outcome, this.diff, this.nDo, this.nDont);
  final Outcome outcome;
  final double diff;
  final int nDo, nDont;
}

double _mean(Iterable<double> v) => v.fold(0.0, (a, b) => a + b) / v.length;

/// do minus don't of [o] over [days] (on the judging scale), labels from [isDo]; null without a day of each kind.
Seen? _seen(Outcome o, List<ExpDay> days, bool? Function(ExpDay d) isDo) {
  final a = <double>[], b = <double>[];
  for (final d in days) {
    final v = d.values[o.id], l = isDo(d);
    if (v == null || l == null || !v.isFinite || (o.logScale && v <= 0)) continue;
    (l ? a : b).add(o.logScale ? math.log(v) : v);
  }
  return a.isEmpty || b.isEmpty ? null : Seen(o, _mean(a) - _mean(b), a.length, b.length);
}

class Adherence {
  const Adherence({required this.days, required this.answered, required this.kept, required this.keptDo, required this.answeredDo});
  final int days, answered, kept;

  /// The same for the "do" days alone (the "don't" days are the rest).
  final int keptDo, answeredDo;
}

class ExpResults {
  const ExpResults({
    required this.outcome,
    required this.days,
    required this.withNumber,
    required this.tested,
    required this.verdict,
    required this.asDone,
    required this.others,
    required this.adherence,
  });

  final Outcome outcome;

  /// Assigned days that are over, and how many of them have the primary number.
  final int days, withNumber;
  final Tested? tested;
  final Verdict verdict;

  /// By what you say you did; null without an answered day of each kind.
  final Seen? asDone;
  final List<Seen> others;
  final Adherence adherence;
}

/// The results over [days] (ExperimentState.analysisDays) for the plan's primary [outcome]. [order]: the whole
/// planned order (ExperimentState.orderForResults).
ExpResults analyse(Outcome outcome, List<ExpDay> days, List<bool> order) {
  final values = List<double?>.filled(order.length, null);
  for (final d in days) {
    final x = d.values[outcome.id];
    if (x == null || !x.isFinite || (outcome.logScale && x <= 0) || d.index >= order.length) continue;
    values[d.index] = outcome.logScale ? math.log(x) : x;
  }
  final v = [for (final x in values) ?x];
  final o = Orders.of(order, values);
  final nDo = o.realDo, nDont = o.have - o.realDo;
  Tested? tested;
  var verdict = Verdict.tooFew;
  if (o.bothKinds) {
    final enough = nDo >= ExpRule.minPerArm && nDont >= ExpRule.minPerArm;
    final range = enough ? shiftRange(o, v.reduce(math.max) - v.reduce(math.min)) : null;
    var matters = outcome.matters;
    if (outcome.relative) matters *= ((o.total - o.realSum) / nDont).abs();
    final p = o.p();
    tested = Tested(diff: o.diff(), p: p, orders: o.count, exact: o.exact, nDo: nDo, nDont: nDont, low: range?.low, high: range?.high, matters: matters);
    if (range != null) {
      verdict = p < ExpRule.alpha
          ? Verdict.likelyReal
          : (range.low > -matters && range.high < matters ? Verdict.littleOrNone : Verdict.notClear);
    }
  }
  final answered = days.where((d) => d.kept != null);
  return ExpResults(
    outcome: outcome,
    days: days.length,
    withNumber: v.length,
    tested: tested,
    verdict: verdict,
    asDone: _seen(outcome, days, (d) => d.kept == null ? null : (d.kept! ? d.doIt : !d.doIt)),
    others: [
      for (final o in outcomes)
        if (o.id != outcome.id) ?_seen(o, days, (d) => d.doIt),
    ],
    adherence: Adherence(
      days: days.length,
      answered: answered.length,
      kept: answered.where((d) => d.kept!).length,
      keptDo: answered.where((d) => d.doIt && d.kept!).length,
      answeredDo: answered.where((d) => d.doIt).length,
    ),
  );
}

// ---- words ----

/// A difference of [o] as a number and its unit, on the screen's scale: (18, "min"), (0.6, "points"), (12, "%").
(double, String) shown(Outcome o, double d) {
  if (o.logScale) return (((math.exp(d) - 1) * 100).roundToDouble(), '%');
  return switch (o.id) {
    'asleep' => (d.roundToDouble(), 'min'),
    'reaction' => (d.roundToDouble(), 'ms'),
    'iaf' => ((d * 100).round() / 100, 'Hz'),
    'jaw' => ((d * 10).round() / 10, 'an hour'),
    _ => ((d * 10).round() / 10, 'points'),
  };
}

String _digits(Outcome o, double n) {
  final a = n.abs();
  if (o.id == 'iaf') return a.toStringAsFixed(2);
  if (o.logScale || o.id == 'asleep' || o.id == 'reaction') return a.round().toString();
  return a.toStringAsFixed(1);
}

/// "+18 min", "−0.6 points", "0 min": a signed difference with its unit.
String signed(Outcome o, double d) {
  final (n, unit) = shown(o, d);
  final sign = n > 0 ? '+' : (n < 0 ? '−' : '');
  return '$sign${_digits(o, n)} $unit';
}

/// "−5 to +41 min": the unit said once.
String rangeWords(Outcome o, double low, double high) {
  final a = signed(o, low), b = signed(o, high);
  return '${a.substring(0, a.indexOf(' '))} to $b';
}

/// "18 min longer", "0.6 points lower", or "the same" when it rounds to nothing.
String sizeWords(Outcome o, double d) {
  final (n, unit) = shown(o, d);
  if (n == 0) return 'the same';
  return '${_digits(o, n)} $unit ${n > 0 ? o.more : o.less}';
}

String pWords(double p) => p < 0.001 ? '< 0.001' : p.toStringAsFixed(p < 0.01 ? 3 : 2);

String _days(int n) => n == 1 ? '1 day' : '$n days';

/// The answer in one sentence. "On “No screens in the last hour before bed” days your time asleep was 18 min
/// longer than on “Screens as usual” days (range −5 to +41 min): not clear yet."
String sentence(ExpResults r, String doText, String dontText) {
  final t = r.tested, o = r.outcome;
  if (t == null || t.low == null) {
    final have = t == null
        ? 'no day of each kind has a number yet'
        : '${_days(t.nDo)} of “$doText” and ${_days(t.nDont)} of “$dontText” have a number';
    return 'Too few days to say: $have, and it takes ${ExpRule.minPerArm} of each.';
  }
  final size = sizeWords(o, t.diff);
  final was = o.plural ? 'were' : 'was';
  final compare = size == 'the same' ? 'the same as' : '$size than';
  return 'On “$doText” days your ${o.noun} $was $compare on “$dontText” days '
      '(range ${rangeWords(o, t.low!, t.high!)}): ${r.verdict.words}.';
}

/// What the verdict means, in plain words (shown under the sentence).
String verdictNote(ExpResults r) {
  final t = r.tested;
  return switch (r.verdict) {
    Verdict.tooFew => 'An experiment needs days of both kinds with a number the next morning. Record the night and do the check-in on more days, then run it again.',
    Verdict.likelyReal =>
      'The app drew the days by chance, and a difference this large would come up by chance alone in fewer than 1 '
          'of 20 draws (p = ${pWords(t!.p)}). The range is where the true effect most likely lies. It is one '
          'experiment on one person: run it once more before you rely on it.',
    Verdict.littleOrNone =>
      'Whatever the effect is, the range says it is smaller than what would matter for this number. That is a '
          'real answer too: this habit does not move it much for you.',
    Verdict.notClear =>
      'The range includes zero and also effects large enough to matter, so these days cannot tell (p = '
          '${pWords(t!.p)}). It does not mean there is no effect. A longer run narrows the range.',
  };
}

/// The results of [s] from the trends' per-day numbers ([series]: measure id -> day -> value). Null while they
/// are closed, unless [early] (the owner asked for an early look, which the store has marked).
ExpResults? resultsFor(ExperimentState s, Map<String, Map<String, double>> series, {bool early = false}) {
  final order = s.orderForResults(early: early);
  return order == null ? null : analyse(s.plan.outcome, s.analysisDays(series), order);
}
