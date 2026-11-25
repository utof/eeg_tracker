// A sleep experiment's honest result (DECISIONS rows 838, 896, 1050-1069). Pure: the log and the nights' numbers in,
// piles, differences and plain words out.
//
// - An evening's answer is judged by the night that follows (the sleep report of the next day, as every sleep number
//   in Trends). A night with no report that counts (removed or "Not sleep", too short to score, someone else's, too
//   noisy) is in neither pile.
// - Under 5 nights of a kind: only the counts. From 5 of each: the two averages, "too early to say". From the
//   nights needed (never under 10 of each): the test and its range.
// - Nights that fell as they fell are "seen together"; only nights the app picked are "tested".
import '../sleep/report.dart' show SleepReport;
import '../trends/days.dart';
import '../trends/sleep_days.dart' show countsForSleepNumbers, efficiencyMinInBedMin;
import '../sleep/drift.dart' show LightsOffFrom;
import 'kinds.dart';
import 'stats.dart';
import 'store.dart';

/// One day's sleep as the experiments read it: the numbers by measure id, the minutes asleep, and when sleep began
/// (minutes after noon, so an evening and the small hours stay in order).
class NightNumbers {
  const NightNumbers(this.values, {required this.asleepMin, required this.startMin});
  final Map<String, double> values;
  final double asleepMin, startMin;
}

double _afterNoon(DateTime t) => ((t.hour * 60 + t.minute + t.second / 60) - 720) % 1440;

/// Day (the day you woke) -> the night's numbers, from the sleep reports that count ([countsForSleepNumbers]) and
/// the pulse the app read beside them ([pulse]: day -> beats a minute). Only the report is read: no channel names.
Map<String, NightNumbers> nightNumbersFrom(Iterable<SleepReport> reports, {Map<String, double> pulse = const {}}) {
  final byDay = <String, List<SleepReport>>{};
  for (final r in reports) {
    if (!countsForSleepNumbers(r)) continue;
    final wake = r.periods.map((p) => p.end).reduce((a, b) => a.isAfter(b) ? a : b);
    byDay.putIfAbsent(wakeDay(wake), () => []).add(r);
  }
  final out = <String, NightNumbers>{};
  for (final MapEntry(key: day, value: rs) in byDay.entries) {
    var asleep = 0.0, deep = 0.0, dream = 0.0, awake = 0.0, inBed = 0.0, bedAsleep = 0.0;
    DateTime? onset;
    for (final r in rs) {
      final first = r.periods.map((p) => p.start).reduce((a, b) => a.isBefore(b) ? a : b);
      final last = r.periods.map((p) => p.end).reduce((a, b) => a.isAfter(b) ? a : b);
      if (onset == null || first.isBefore(onset)) onset = first;
      var nightAsleep = 0.0;
      for (final p in r.periods) {
        nightAsleep += p.asleepMin;
        deep += p.deepMin;
        dream += p.dreamMin;
        awake += p.awakeMin;
      }
      asleep += nightAsleep;
      // time in bed as Trends counts it (sleep_days.dart): from the Lights off tap, else the recording's start
      final lo = r.driftOff;
      final tapped = lo != null && lo.from != LightsOffFrom.nightStart ? lo.lightsOff : null;
      final from = tapped ?? r.dataStart;
      final bed = last.difference(from.isBefore(first) ? from : first).inSeconds / 60;
      if (bed >= efficiencyMinInBedMin) {
        inBed += bed;
        bedAsleep += nightAsleep;
      }
    }
    out[day] = NightNumbers(
      {
        'deep': deep,
        'dream': dream,
        'awake': awake,
        'sleep_start': _afterNoon(onset!),
        if (inBed > 0) 'efficiency': (bedAsleep / inBed * 100).clamp(0, 100).toDouble(),
        if (pulse[day] case final p? when p.isFinite) 'pulse': p,
      },
      asleepMin: asleep,
      startMin: _afterNoon(onset),
    );
  }
  return out;
}

/// A night in one of the two piles.
class CountedNight {
  const CountedNight({required this.day, required this.withIt, required this.night, this.kept, this.pickIndex});

  /// The evening's day key (the night ends the day after).
  final String day;
  final bool withIt;
  final NightNumbers night;

  /// On a night the app picked: whether the owner did as picked (null: not answered).
  final bool? kept;
  final int? pickIndex;

  /// Friday and Saturday evenings lead into days off (from the date alone).
  bool get dayOff {
    final w = dayNoon(day).weekday;
    return w == DateTime.friday || w == DateTime.saturday;
  }
}

/// The nights sorted into the two piles, and the ones left out with the reason.
class Piles {
  const Piles(this.counted, this.leftOut);
  final List<CountedNight> counted;
  final Map<LeftOut, int> leftOut;
  int get nWith => counted.where((n) => n.withIt).length;
  int get nWithout => counted.length - nWith;
}

/// Sorts every logged evening of [e] into with, without or left out. [nights]: [nightNumbersFrom].
Piles sortNights(ExperimentLog e, Map<String, NightNumbers> nights) {
  final counted = <CountedNight>[], out = <LeftOut, int>{};
  void leave(LeftOut why) => out[why] = (out[why] ?? 0) + 1;
  final days = e.days.keys.where((d) => d.compareTo(e.plan.start) >= 0).toList()..sort();
  for (final day in days) {
    final log = e.day(day);
    final bool withIt;
    if (e.plan.picked) {
      if (log.pick == null) continue; // not a test night
      withIt = log.pick!;
    } else {
      if (log.answer == null) continue;
      if (log.answer == Answer.neither) {
        leave(LeftOut.inBetween);
        continue;
      }
      withIt = log.answer == Answer.withIt;
    }
    final night = nights[addDays(day, 1)];
    if (night == null) {
      // tonight's night has not been slept yet: nothing to say about it
      if (e.running && day == days.last && log.odd.isEmpty) continue;
      leave(LeftOut.noNight);
      continue;
    }
    if (log.odd.isNotEmpty) {
      leave(LeftOut.odd);
      continue;
    }
    final before = e.day(addDays(day, -1));
    if (e.plan.kind.nightAfterOut && !withIt && before.answer == Answer.withIt) {
      leave(LeftOut.nightAfter);
      continue;
    }
    final last = nights[day];
    if (last != null && last.asleepMin < shortNightMin) {
      leave(LeftOut.afterShortNight);
      continue;
    }
    counted.add(
      CountedNight(
        day: day,
        withIt: withIt,
        night: night,
        pickIndex: log.pickIndex,
        kept: !e.plan.picked || log.answer == null ? null : (log.answer == Answer.withIt) == withIt && log.answer != Answer.neither,
      ),
    );
  }
  return Piles(counted, out);
}

enum Stage {
  /// Under 5 nights of a kind with this number: counts only.
  notEnough,

  /// From 5 of each: the two averages, no verdict.
  soFar,

  /// From the nights needed (at least 10 of each): the test.
  verdict,
}

/// One watched number's result.
class MeasureResult {
  const MeasureResult({
    required this.measure,
    required this.expected,
    required this.nWith,
    required this.nWithout,
    required this.needed,
    required this.ownSpread,
    required this.stage,
    this.meanWith,
    this.meanWithout,
    this.p,
    this.range,
    this.matched,
  });
  final NightMeasure measure;

  /// The change the studies found (its size).
  final double expected;
  final int nWith, nWithout;

  /// Nights needed of each kind; null when it cannot be worked out. [ownSpread]: from the owner's own nights (true)
  /// or from other people's typical spread (false).
  final int? needed;
  final bool ownSpread;
  final Stage stage;
  final double? meanWith, meanWithout, p;
  final ({double low, double high})? range;
  final ({double diff, int nWith, int nWithout})? matched;

  double? get diff => meanWith == null || meanWithout == null ? null : meanWith! - meanWithout!;

  /// Nights of each kind before a verdict.
  int get verdictAt => needed == null || needed! < StatRule.minForVerdict ? StatRule.minForVerdict : needed!;
  bool get clear => stage == Stage.verdict && p != null && p! < StatRule.alpha;
}

/// How many nights of each kind [kind]'s watched number [w] needs, from the owner's own spread when [ordinary] has
/// 14 values or more, else from other people's.
({int? needed, bool own}) neededFor(Watched w, List<double> ordinary) {
  final own = ordinary.length >= StatRule.ownSpreadNights && spreadOf(ordinary) > 0;
  return (needed: nightsNeeded(w.expected, own ? spreadOf(ordinary) : w.measure.typicalSpread), own: own);
}

/// The ordinary nights' values of a measure: every night that counts and is not a night with.
List<double> ordinaryValues(String measureId, Map<String, NightNumbers> nights, Set<String> withDays) => [
  for (final MapEntry(key: day, value: n) in nights.entries)
    if (!withDays.contains(day) && n.values[measureId] != null) n.values[measureId]!,
];

class ExperimentResult {
  const ExperimentResult(this.log, this.piles, this.measures);
  final ExperimentLog log;
  final Piles piles;
  final List<MeasureResult> measures;
  bool get tested => log.plan.picked;

  /// Of the picked nights the owner answered: how many went as picked.
  ({int kept, int answered}) get keptTo {
    final a = piles.counted.where((n) => n.kept != null);
    return (kept: a.where((n) => n.kept!).length, answered: a.length);
  }
}

ExperimentResult resultFor(ExperimentLog e, Map<String, NightNumbers> nights, {int seed = 1}) {
  final piles = sortNights(e, nights);
  // the wake days of the nights with, so they stay out of "ordinary nights"
  final withDays = {
    for (final n in piles.counted)
      if (n.withIt) addDays(n.day, 1),
  };
  final results = <MeasureResult>[];
  for (final w in e.plan.kind.watched) {
    final id = w.measure.id;
    final have = [
      for (final n in piles.counted)
        if (n.night.values[id] != null) n,
    ];
    final a = [
      for (final n in have)
        if (n.withIt) n.night.values[id]!,
    ];
    final b = [
      for (final n in have)
        if (!n.withIt) n.night.values[id]!,
    ];
    final need = neededFor(w, ordinaryValues(id, nights, withDays));
    final verdictAt = need.needed == null || need.needed! < StatRule.minForVerdict ? StatRule.minForVerdict : need.needed!;
    final least = a.length < b.length ? a.length : b.length;
    final stage = least < StatRule.minPerPile
        ? Stage.notEnough
        : least < verdictAt
        ? Stage.soFar
        : Stage.verdict;
    double? p;
    ({double low, double high})? range;
    if (stage == Stage.verdict) {
      final Shuffles s;
      if (e.plan.picked) {
        final count = have.map((n) => n.pickIndex!).reduce((x, y) => x > y ? x : y) + 1;
        final values = List<double?>.filled(count, null), picks = [for (var i = 0; i < count; i++) pickAt(e.plan.salt!, i)];
        for (final n in have) {
          values[n.pickIndex!] = n.night.values[id];
        }
        s = Shuffles.picked(values, picks, seed: seed);
      } else {
        s = Shuffles.free([for (final n in have) n.night.values[id]!], [for (final n in have) n.withIt], seed: seed);
      }
      p = s.p();
      range = rangeOf(s, spreadOf([...a, ...b]));
    }
    results.add(
      MeasureResult(
        measure: w.measure,
        expected: w.expected,
        nWith: a.length,
        nWithout: b.length,
        needed: need.needed,
        ownSpread: need.own,
        stage: stage,
        meanWith: stage == Stage.notEnough ? null : mean(a),
        meanWithout: stage == Stage.notEnough ? null : mean(b),
        p: p,
        range: range,
        // matching by when sleep began would hide a change in when sleep begins
        matched: stage == Stage.notEnough || w.measure == sleepStart
            ? null
            : matchedDiff([
                for (final n in have) (value: n.night.values[id]!, withIt: n.withIt, startMin: n.night.startMin, dayOff: n.dayOff),
              ]),
      ),
    );
  }
  return ExperimentResult(e, piles, results);
}

// ---- words ----

String _nights(int n) => n == 1 ? '1 night' : '$n nights';

/// A size in the measure's units, without a sign: "28 minutes", "6 points", "3 beats a minute".
String amount(NightMeasure m, double v) {
  final a = v.abs();
  switch (m.unit) {
    case Unit.minutes || Unit.clock:
      final r = a.round();
      return r == 1 ? '1 minute' : '$r minutes';
    case Unit.points:
      final r = a.round();
      return r == 1 ? '1 point' : '$r points';
    case Unit.beats:
      final r = a >= 10 ? a.round().toString() : _one(a);
      return r == '1' ? '1 beat a minute' : '$r beats a minute';
  }
}

String _one(double a) {
  final s = a.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// A night's average as a readout: "82 %", "1 h 12 min", "58 a minute", "23:40".
String level(NightMeasure m, double v) {
  switch (m.unit) {
    case Unit.points:
      return '${v.round()} %';
    case Unit.minutes:
      final r = v.round();
      return r >= 60 ? '${r ~/ 60} h ${r % 60} min' : '$r min';
    case Unit.beats:
      return '${_one(v)} a minute';
    case Unit.clock:
      final t = (v.round() + 720) % 1440;
      return '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
  }
}

/// "6 points lower", "36 minutes later", "no different".
String change(NightMeasure m, double diff) {
  final size = amount(m, diff);
  if (size.startsWith('0 ')) return 'no different';
  return '$size ${diff > 0 ? m.more : m.less}';
}

String _between(NightMeasure m, ({double low, double high}) r) {
  String side(double v) => m.unit == Unit.beats ? _one(v.abs()) : '${v.abs().round()}';
  final lo = r.low, hi = r.high;
  if (lo < 0 && hi > 0) return 'likely between ${side(lo)} ${m.less} and ${side(hi)} ${m.more}';
  final (near, far) = lo.abs() <= hi.abs() ? (lo, hi) : (hi, lo);
  return 'likely between ${side(near)} and ${side(far)}';
}

/// "your sleep began", "your deep sleep was": the number as the subject of a sentence.
String _subject(NightMeasure m) => m.unit == Unit.clock ? 'your sleep began' : 'your ${m.noun} was';

/// What "needs about N of each" says, before the start and while it runs.
String neededLine(MeasureResult r) => neededWords(r.measure, r.needed, r.ownSpread);

String neededWords(NightMeasure m, int? needed, bool own) {
  final from = own ? 'how much your own nights vary' : 'how much other people\'s nights vary (yours are used from 14 nights on)';
  if (needed == null) return 'How many nights this needs cannot be said yet.';
  final at = needed < StatRule.minForVerdict ? StatRule.minForVerdict : needed;
  if (at > 60) {
    return 'From what studies found and $from, ${m.noun} would need more than 60 nights with and 60 without. '
        'Most likely this will end as "no difference seen".';
  }
  return 'From what studies found and $from, this needs about $at nights with and $at without. With fewer, the app '
      'cannot tell.';
}

/// The one sentence for a watched number, by stage.
String sentence(ExperimentResult res, MeasureResult r) {
  final k = res.log.plan.kind, m = r.measure;
  switch (r.stage) {
    case Stage.notEnough:
      return 'Not enough yet: ${_nights(r.nWith)} with, ${r.nWithout} without. The averages show from '
          '${StatRule.minPerPile} of each.';
    case Stage.soFar:
      return 'So far ${level(m, r.meanWith!)} with (${_nights(r.nWith)}) and ${level(m, r.meanWithout!)} without '
          '(${_nights(r.nWithout)}). Too early to say: this needs about ${r.verdictAt} of each.';
    case Stage.verdict:
      final range = r.range;
      if (!r.clear || range == null) {
        final small = range == null ? null : (range.low.abs() > range.high.abs() ? range.low.abs() : range.high.abs());
        return 'No difference seen in ${r.nWith} + ${r.nWithout} nights. Either there is none for you'
            '${small == null ? '' : ', or it is smaller than about ${amount(m, small)}, which this many nights cannot show'}.';
      }
      final what = '${_subject(m)} ${change(m, r.diff!)}';
      return res.tested
          ? 'Tested: on the ${r.nWith} nights the app picked for ${k.thing}, $what than on the ${r.nWithout} nights '
                'it picked without (${_between(m, range)}).'
          : 'On your ${r.nWith} nights with ${k.thing}, $what than on ${r.nWithout} nights without '
                '(${_between(m, range)}). Seen together, not proven: other things about those days may differ too.';
  }
}

/// The line about similar nights, or null when there is nothing to say.
String? matchedLine(ExperimentResult res, MeasureResult r) {
  if (r.stage == Stage.notEnough || r.measure == sleepStart) return null;
  final m = r.matched, d = r.diff;
  if (m == null || d == null) return 'Too few similar nights yet to compare like with like (same kind of day, usual bedtime).';
  final line = 'Among similar nights (same kind of day, sleep within an hour of usual; ${m.nWith} with, ${m.nWithout} '
      'without): ${change(r.measure, m.diff)}.';
  if (r.clear && m.diff.abs() < d.abs() / 2) return '$line Part of the gap may be late nights, not ${res.log.plan.kind.thing}.';
  return line;
}

/// "Left out: 3 nights (2 in between, 1 ill or not your own bed)."; null when none.
String? leftOutLine(Piles p) {
  if (p.leftOut.isEmpty) return null;
  final total = p.leftOut.values.fold(0, (a, b) => a + b);
  final parts = [
    for (final why in LeftOut.values)
      if (p.leftOut[why] case final n?) '$n ${why.words}',
  ];
  return 'Left out: ${_nights(total)} (${parts.join(', ')}).';
}
