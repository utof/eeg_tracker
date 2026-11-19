// What the sharp-hours page may say, and when (DECISIONS rows 286-287). Pure: the page only lays it out.
//
// - No pattern before 3 weeks and about 60 ratings (the research: a week or two is too short, and self-rated
//   sharpness changes little with the hour); until then only the answers themselves.
// - Then three ways to group the answers: 2-hour blocks of clock time, of hours since your recorded wake-up, and of
//   the sleep-pressure estimate (trends/pressure.dart). Each block: its mean and an 80 % range from resampling
//   whole days (answers on one day resemble each other, so days, not answers, are the units drawn).
// - A best time is named only when the same block beats every other block in at least 9 of 10 resamples AND it
//   stands out by half a point (5 % for reaction time); when the best block alone does not, it is tried once more
//   together with its better neighbour, as one 4-hour span (a real peak is often broader than 2 hours). Everything here is seen together, not tested: what you do at those hours
//   (meetings, meals, coffee) shapes it too.
import 'dart:math' as math;

import '../trends/days.dart';
import '../trends/pressure.dart';
import 'schedule.dart';
import 'store.dart';

/// Planning values (DECISIONS row 286).
abstract final class SharpGate {
  static const int days = 21, ratings = 60, tests = 30;

  /// A block's mean is shown with at least this many answers from at least [minDays] days.
  static const int minPerBlock = 5, minDays = 3;

  /// Resamples of whole days, and the share of them a best time must win.
  static const int draws = 1000;
  static const double sure = 0.9;

  /// The least difference for a best time: half a point of the rating, 5 % of reaction time.
  static const double ratingGap = 0.5, reactionShare = 0.05;
}

class GateState {
  const GateState({required this.ratings, required this.tests, required this.day});
  final int ratings, tests;

  /// Day 1 is the day of the first rating; 0 before any.
  final int day;

  bool get open => day > SharpGate.days && ratings >= SharpGate.ratings;
  bool get testsOpen => open && tests >= SharpGate.tests;

  /// `23 of about 60 ratings, day 9 of 21.` while collecting.
  String get counts => '$ratings of about ${SharpGate.ratings} ratings, day ${math.min(day, SharpGate.days)} of ${SharpGate.days}.';

  String get words {
    if (ratings == 0) return 'Nothing rated yet.';
    if (!open) return 'Collecting: $counts';
    final t = tests == 0 ? 'no reaction tests' : (tests == 1 ? '1 reaction test' : '$tests reaction tests');
    return '$ratings ratings and $t over $day days.';
  }
}

GateState sharpGate(List<SharpRating> ratings, List<SharpReaction> tests, String today) {
  if (ratings.isEmpty) return GateState(ratings: 0, tests: tests.length, day: 0);
  final first = ratings.map((r) => dayKey(r.at)).reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  return GateState(ratings: ratings.length, tests: tests.length, day: daysBetween(first, today) + 1);
}

enum SharpAxis { clock, sinceWake, pressure }

/// The block of a value on [axis]: clock hours and hours since waking in 2-hour steps (16 hours or more after
/// waking together); sleep pressure in quarters of its 0-100 scale, with under 25 and 100 or more at the ends.
int blockOf(SharpAxis axis, double v) => switch (axis) {
  SharpAxis.clock => (v ~/ 2).clamp(0, 11),
  SharpAxis.sinceWake => (v ~/ 2).clamp(0, 8),
  SharpAxis.pressure => (v < 0 ? 0 : (v ~/ 25)).clamp(0, 4),
};

/// How many blocks an axis has.
int blockCount(SharpAxis axis) => switch (axis) {
  SharpAxis.clock => 12,
  SharpAxis.sinceWake => 9,
  SharpAxis.pressure => 5,
};

String _two(int h) => h.toString().padLeft(2, '0');

/// `10:00 to 12:00`, `2 to 4 hours after waking`, `sleep pressure 25 to 50`.
String blockWords(SharpAxis axis, int i) => switch (axis) {
  SharpAxis.clock => '${_two(i * 2)}:00 to ${_two(i * 2 + 2)}:00',
  SharpAxis.sinceWake => i >= 8 ? '16 hours or more after waking' : '${i * 2} to ${i * 2 + 2} hours after waking',
  SharpAxis.pressure => i == 0 ? 'sleep pressure under 25' : (i >= 4 ? 'sleep pressure 100 or more' : 'sleep pressure ${i * 25} to ${i * 25 + 25}'),
};

/// The chart's tick under a block: `10`, `2`, `25`.
String blockShort(SharpAxis axis, int i) => switch (axis) {
  SharpAxis.clock => '${i * 2}',
  SharpAxis.sinceWake => i >= 8 ? '16+' : '${i * 2}',
  SharpAxis.pressure => i == 0 ? '<25' : (i >= 4 ? '100+' : '${i * 25}'),
};

/// Hours from the latest recorded wake-up in the 24 hours before [at]; null without one.
double? hoursSinceWake(DateTime at, List<DateTime> wakes) {
  DateTime? last;
  for (final w in wakes) {
    if (!w.isAfter(at) && (last == null || w.isAfter(last))) last = w;
  }
  if (last == null) return null;
  final h = at.difference(last).inSeconds / 3600;
  return h > 24 ? null : h;
}

/// One answer (a rating, or a reaction test's median) placed on an axis.
class SharpPoint {
  const SharpPoint({required this.at, required this.day, required this.value, required this.block});
  final DateTime at;
  final String day;
  final double value;
  final int block;
}

typedef Placed = ({List<SharpPoint> placed, int left});

/// [values] on [axis]: the answers it can place, and how many it cannot (no recorded wake-up in the 24 hours
/// before, or no sleep-pressure estimate at that time).
Placed axisPoints(
  SharpAxis axis,
  List<({DateTime at, double value})> values, {
  List<DateTime> wakes = const [],
  PressureModel? pressure,
}) {
  final out = <SharpPoint>[];
  var left = 0;
  for (final v in values) {
    final x = switch (axis) {
      SharpAxis.clock => v.at.hour + v.at.minute / 60,
      SharpAxis.sinceWake => hoursSinceWake(v.at, wakes),
      SharpAxis.pressure => pressure?.levelAt(v.at),
    };
    if (x == null) {
      left++;
      continue;
    }
    out.add(SharpPoint(at: v.at, day: dayKey(v.at), value: v.value, block: blockOf(axis, x)));
  }
  return (placed: out, left: left);
}

class SharpBlock {
  const SharpBlock({required this.index, required this.n, required this.days, this.mean, this.low, this.high});
  final int index;

  /// Answers in the block, and the days they came from.
  final int n, days;

  /// Shown only with enough answers from enough days; the range holds 80 % of the resampled means.
  final double? mean, low, high;

  bool get shown => mean != null;
}

class BestTime {
  const BestTime({required this.blocks, required this.mean, required this.gap, required this.low, required this.high, required this.sure});

  /// One block, or two neighbouring blocks taken together when a peak spans both.
  final List<SharpBlock> blocks;

  /// The answers' mean in [blocks].
  final double mean;

  /// [mean] minus the mean of every other answer, with its 80 % range.
  final double gap, low, high;

  /// The share of resamples in which [blocks] beat every other block.
  final double sure;
}

class SharpProfile {
  const SharpProfile({required this.axis, required this.blocks, this.best});
  final SharpAxis axis;

  /// Every block that has answers, in order.
  final List<SharpBlock> blocks;
  final BestTime? best;
}

double _q(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  final x = p * (sorted.length - 1);
  final lo = x.floor(), hi = x.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (x - lo);
}

/// The blocks of [points] with their ranges, and the best time if one stands out. [higherBetter]: ratings (true)
/// or reaction times (false). Resampling is seeded: the same answers always give the same page.
SharpProfile sharpProfile(
  SharpAxis axis,
  List<SharpPoint> points, {
  required bool higherBetter,
  int minPerBlock = SharpGate.minPerBlock,
  int seed = 1,
  int draws = SharpGate.draws,
}) {
  final nb = blockCount(axis);
  final byDay = <String, List<SharpPoint>>{};
  for (final p in points) {
    byDay.putIfAbsent(p.day, () => []).add(p);
  }
  final days = byDay.keys.toList()..sort();
  final n = List.filled(nb, 0), sum = List.filled(nb, 0.0);
  final dayCount = List.filled(nb, 0);
  for (final d in days) {
    final seen = <int>{};
    for (final p in byDay[d]!) {
      n[p.block]++;
      sum[p.block] += p.value;
      seen.add(p.block);
    }
    for (final b in seen) {
      dayCount[b]++;
    }
  }
  final shown = [for (var b = 0; b < nb; b++) n[b] >= minPerBlock && dayCount[b] >= SharpGate.minDays];
  final total = sum.fold(0.0, (a, b) => a + b), count = n.fold(0, (a, b) => a + b);
  final better = higherBetter ? 1.0 : -1.0;
  int? bestIx;
  for (var b = 0; b < nb; b++) {
    if (shown[b] && (bestIx == null || better * sum[b] / n[b] > better * sum[bestIx] / n[bestIx])) bestIx = b;
  }
  // resample whole days with replacement; keep each draw's sums per block
  final r = math.Random(seed);
  final means = List.generate(nb, (_) => <double>[]);
  final drawn = <(List<double>, List<int>)>[];
  for (var k = 0; k < draws && days.isNotEmpty; k++) {
    final s = List.filled(nb, 0.0), c = List.filled(nb, 0);
    for (var i = 0; i < days.length; i++) {
      for (final p in byDay[days[r.nextInt(days.length)]]!) {
        s[p.block] += p.value;
        c[p.block]++;
      }
    }
    for (var b = 0; b < nb; b++) {
      if (c[b] > 0) means[b].add(s[b] / c[b]);
    }
    drawn.add((s, c));
  }
  final blocks = <SharpBlock>[];
  for (var b = 0; b < nb; b++) {
    if (n[b] == 0) continue;
    final m = (means[b]..sort());
    blocks.add(SharpBlock(
      index: b,
      n: n[b],
      days: dayCount[b],
      mean: shown[b] ? sum[b] / n[b] : null,
      low: shown[b] ? _q(m, 0.1) : null,
      high: shown[b] ? _q(m, 0.9) : null,
    ));
  }
  // the best block, then (when it does not stand out alone) the best block with its better neighbour
  BestTime? test(Set<int> span) {
    final ns = span.fold(0, (a, b) => a + n[b]);
    if (ns == 0 || ns >= count) return null;
    final mean = span.fold(0.0, (a, b) => a + sum[b]) / ns;
    final restMean = (total - span.fold(0.0, (a, b) => a + sum[b])) / (count - ns);
    var wins = 0;
    final gaps = <double>[];
    for (final (s, c) in drawn) {
      final cs = span.fold(0, (a, b) => a + c[b]);
      if (cs == 0) continue;
      final ms = span.fold(0.0, (a, b) => a + s[b]) / cs;
      var beats = true;
      for (var b = 0; b < nb && beats; b++) {
        if (span.contains(b) || !shown[b] || c[b] == 0) continue;
        if (better * (s[b] / c[b]) >= better * ms) beats = false;
      }
      if (beats) wins++;
      final rest = c.fold(0, (a, b) => a + b) - cs;
      if (rest > 0) gaps.add(ms - (s.fold(0.0, (a, b) => a + b) - span.fold(0.0, (a, b) => a + s[b])) / rest);
    }
    final gap = mean - restMean;
    final need = higherBetter ? SharpGate.ratingGap : SharpGate.reactionShare * restMean.abs();
    final sure = drawn.isEmpty ? 0.0 : wins / drawn.length;
    if (gaps.isEmpty || sure < SharpGate.sure || better * gap < need) return null;
    gaps.sort();
    return BestTime(
      blocks: [for (final b in blocks) if (span.contains(b.index)) b],
      mean: mean,
      gap: gap,
      low: _q(gaps, 0.1),
      high: _q(gaps, 0.9),
      sure: sure,
    );
  }

  BestTime? best;
  if (bestIx != null) {
    best = test({bestIx});
    if (best == null) {
      final next = [bestIx - 1, bestIx + 1].where((b) => b >= 0 && b < nb && shown[b]).toList()
        ..sort((a, b) => (better * sum[b] / n[b]).compareTo(better * sum[a] / n[a]));
      if (next.isNotEmpty) best = test({bestIx, next.first});
    }
  }
  return SharpProfile(axis: axis, blocks: blocks, best: best);
}

/// `10:00 to 12:00`, `08:00 to 12:00`, `2 to 6 hours after waking`, `sleep pressure 25 to 75`: one block or two
/// neighbouring ones.
String spanWords(SharpAxis axis, List<SharpBlock> span) {
  final a = span.map((b) => b.index).reduce(math.min), z = span.map((b) => b.index).reduce(math.max);
  if (a == z) return blockWords(axis, a);
  return switch (axis) {
    SharpAxis.clock => '${_two(a * 2)}:00 to ${_two(z * 2 + 2)}:00',
    SharpAxis.sinceWake => z >= 8 ? '${a * 2} hours or more after waking' : '${a * 2} to ${z * 2 + 2} hours after waking',
    SharpAxis.pressure => a == 0
        ? 'sleep pressure under ${z * 25 + 25}'
        : (z >= 4 ? 'sleep pressure ${a * 25} or more' : 'sleep pressure ${a * 25} to ${z * 25 + 25}'),
  };
}

/// "Sharpest 10:00 to 12:00: 0.8 points above your other times (probably 0.4 to 1.2)." or, for reaction times,
/// "Quickest 10:00 to 12:00: 12 % quicker than at your other times (probably 6 to 18 %)."
String bestWords(SharpAxis axis, BestTime b, {bool reaction = false}) {
  final where = spanWords(axis, b.blocks);
  if (!reaction) {
    return 'Sharpest $where: ${b.gap.toStringAsFixed(1)} points above your other times '
        '(probably ${b.low.toStringAsFixed(1)} to ${b.high.toStringAsFixed(1)}).';
  }
  final rest = b.mean - b.gap;
  int pct(double g) => (-g / rest * 100).round();
  final lo = math.min(pct(b.low), pct(b.high)), hi = math.max(pct(b.low), pct(b.high));
  return 'Quickest $where: ${pct(b.gap)} % quicker than at your other times (probably $lo to $hi %).';
}

/// The day's numbers for Trends and the self-experiments (DECISIONS row 287), by the 04:00 day: `sharp` = the mean
/// of the day's ratings, `dayrt` = the median of the day's reaction tests (tests without a median left out).
Map<String, Map<String, double>> sharpDayNumbers(List<SharpRating> ratings, List<SharpReaction> tests) {
  final byDay = <String, List<int>>{};
  for (final r in ratings) {
    byDay.putIfAbsent(dayKey(r.at), () => []).add(r.sharp);
  }
  final rt = <String, List<int>>{};
  for (final t in tests) {
    final m = t.medianMs;
    if (m != null) rt.putIfAbsent(dayKey(t.ratingAt), () => []).add(m);
  }
  double median(List<int> v) {
    final s = [...v]..sort();
    return s.length.isOdd ? s[s.length ~/ 2].toDouble() : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
  }

  return {
    'sharp': {for (final e in byDay.entries) e.key: e.value.reduce((a, b) => a + b) / e.value.length},
    'dayrt': {for (final e in rt.entries) e.key: median(e.value)},
  };
}

/// Whether the questions reach the owner: over the last [days] full days since the last change of the settings.
class Reach {
  const Reach({this.planned = 0, this.arrived = 0, this.shown = 0, this.skipped = 0, this.late = 0, this.answered = 0});

  /// Moments planned; of them, those the phone rang at all (shown, skipped or late), shown, skipped, late; and
  /// those answered.
  final int planned, arrived, shown, skipped, late, answered;

  /// Fewer than 3 in 4 planned moments arrived, with at least 6 planned: the phone (HyperOS, a battery saver)
  /// probably held them back.
  bool get heldBack => planned >= 6 && arrived < planned * 0.75;
}

Reach reachOf(SharpSettings s, List<PromptEvent> events, List<SharpRating> ratings, DateTime now, {int days = 7}) {
  if (!s.on) return const Reach();
  final since = s.changed ?? s.firstOn;
  final today = dayKey(now);
  final planned = <int>{};
  for (var d = 1; d <= days; d++) {
    final day = addDays(today, -d);
    if (since != null && windowStart(day, s.fromMin).isBefore(since)) continue;
    for (final p in promptsForDay(day, s)) {
      if (p.at.isBefore(now)) planned.add(p.at.millisecondsSinceEpoch);
    }
  }
  final first = <int, PromptEventKind>{};
  for (final e in events) {
    final k = e.planned.millisecondsSinceEpoch;
    if (!planned.contains(k)) continue;
    if (e.event == PromptEventKind.shown || e.event == PromptEventKind.skipped || e.event == PromptEventKind.late) {
      first.putIfAbsent(k, () => e.event);
    }
  }
  final answered = {
    for (final r in ratings)
      if (r.prompt != null && planned.contains(r.prompt!.millisecondsSinceEpoch)) r.prompt!.millisecondsSinceEpoch,
  };
  return Reach(
    planned: planned.length,
    arrived: first.length,
    shown: first.values.where((k) => k == PromptEventKind.shown).length,
    skipped: first.values.where((k) => k == PromptEventKind.skipped).length,
    late: first.values.where((k) => k == PromptEventKind.late).length,
    answered: answered.length,
  );
}
