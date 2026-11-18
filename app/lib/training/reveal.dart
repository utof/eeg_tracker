// The replay check's results (DECISIONS row 103): only whole sets of 12 randomised sessions, never one session.
// A plain randomisation test: the difference of the mean primary measure, live minus replay, against every way
// the labels could have fallen inside each block (the schedule's own randomness), plus how often the guesses
// were right against a coin. Pure; numbers in, words out.
import 'dart:math' as math;

import 'check.dart';
import 'control.dart';

typedef PermutationResult = ({double diff, double p, int orders, bool exact, int live, int replay});

/// Two-sided permutation test of mean(live) - mean(replay). Labels are shuffled only inside each block
/// ([blocks] gives each value's block), keeping each block's number of live values. Every order is counted
/// when there are at most [maxExact]; otherwise [draws] seeded random orders (p counts the observed one too).
/// Null without at least one value of each kind.
PermutationResult? permutationTest(
  List<double> values,
  List<bool> live,
  List<int> blocks, {
  int maxExact = 200000,
  int draws = 50000,
  int seed = 1,
}) {
  final n = values.length;
  if (live.length != n || blocks.length != n) throw ArgumentError('values, labels and blocks differ in length');
  final nLive = live.where((l) => l).length, nRep = n - nLive;
  if (nLive == 0 || nRep == 0) return null;
  final total = values.fold(0.0, (a, b) => a + b);
  double diffOf(double liveSum) => liveSum / nLive - (total - liveSum) / nRep;
  var observed = 0.0;
  for (var i = 0; i < n; i++) {
    if (live[i]) observed += values[i];
  }
  final obs = diffOf(observed);

  // per block: its values and how many of them are live
  final byBlock = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    byBlock.putIfAbsent(blocks[i], () => []).add(i);
  }
  final groups = [
    for (final idx in byBlock.values) (vals: [for (final i in idx) values[i]], k: idx.where((i) => live[i]).length),
  ];
  // the possible live sums of each block, one per way to choose its live positions
  final sums = [for (final g in groups) _choiceSums(g.vals, g.k)];
  final orders = sums.fold<double>(1, (a, s) => a * s.length);
  bool asExtreme(double liveSum) => diffOf(liveSum).abs() >= obs.abs() - 1e-12;

  if (orders <= maxExact) {
    var hits = 0, count = 0;
    void walk(int b, double acc) {
      if (b == sums.length) {
        count++;
        if (asExtreme(acc)) hits++;
        return;
      }
      for (final s in sums[b]) {
        walk(b + 1, acc + s);
      }
    }

    walk(0, 0);
    return (diff: obs, p: hits / count, orders: count, exact: true, live: nLive, replay: nRep);
  }
  final r = math.Random(seed);
  var hits = 1;
  for (var d = 0; d < draws; d++) {
    var acc = 0.0;
    for (final s in sums) {
      acc += s[r.nextInt(s.length)];
    }
    if (asExtreme(acc)) hits++;
  }
  return (diff: obs, p: hits / (draws + 1), orders: orders.round(), exact: false, live: nLive, replay: nRep);
}

List<double> _choiceSums(List<double> vals, int k) {
  final out = <double>[];
  void pick(int from, int left, double acc) {
    if (left == 0) {
      out.add(acc);
      return;
    }
    for (var i = from; i <= vals.length - left; i++) {
      pick(i + 1, left - 1, acc + vals[i]);
    }
  }

  pick(0, k, 0);
  return out;
}

/// P(X >= k) for X ~ Binomial(n, 1/2): the chance of guessing at least [k] of [n] right by luck.
double binomialTail(int k, int n) {
  if (k <= 0) return 1;
  if (k > n) return 0;
  var p = 0.0, c = 1.0; // C(n, 0)
  for (var i = 0; i <= n; i++) {
    if (i >= k) p += c;
    c = c * (n - i) / (i + 1);
  }
  return p / math.pow(2, n);
}

class Reveal {
  const Reveal({
    required this.kind,
    required this.shown,
    required this.hidden,
    required this.planOk,
    required this.primary,
    required this.excluded,
    required this.right,
    required this.judged,
    required this.unsure,
    required this.guessP,
    required this.means,
    this.deviations = 0,
  });

  final SessionKind kind;

  /// The sessions revealed (whole sets of 12), oldest first; [hidden]: sessions after them, still sealed.
  final List<CheckRecord> shown;
  final int hidden;

  /// The plan's hash, the schedule's hash and the schedule drawn again from the salt all agree.
  final bool planOk;
  final PermutationResult? primary;
  final int excluded;

  /// Guesses: right of those that said live or replay, and how many said "not sure".
  final int right, judged, unsure;
  final double? guessP;

  /// Mean ratings per arm: 'calm', 'control', 'random' -> (live, replay); null without ratings.
  final Map<String, (double?, double?)> means;

  /// Sessions that played something other than the schedule said (a replay whose donor could not be read
  /// played live). They are analysed as what they were.
  final int deviations;

  /// The honest note under the numbers, in plain words.
  List<String> get note {
    final what = kind == SessionKind.meditation ? 'your alpha during the sound' : 'your theta-to-alpha balance';
    final lines = <String>[
      'This tests one thing: whether, within a session, the live link changed $what more than a replay of your '
          'own earlier sound. It does not test learning over weeks or any health effect.',
    ];
    final p = primary;
    if (p == null) {
      lines.add('Too few usable sessions of each kind for the test yet.');
    } else if (p.p < 0.05) {
      lines.add(
        'Live and replay differed more than the shuffled labels usually do (p = ${_p(p.p)}). One test on one '
        'person: the next ${CheckRule.revealEvery} sessions should show it again before you trust it.',
      );
    } else {
      lines.add(
        'No clear difference between live and replay (p = ${_p(p.p)}). For one person that is a likely and '
        'legitimate result: in the own-replay study live beat replay in only 6-11 of 24 people.',
      );
    }
    if (judged > 0 && (guessP ?? 1) < 0.05) {
      lines.add(
        'You told live from replay more often than chance ($right of $judged), so the check was partly unblinded: '
        'differences in how sessions felt may be partly expectation. The brain measure is less affected.',
      );
    } else if (judged > 0) {
      lines.add('Your guesses were right $right of $judged times, about what chance gives: the blinding held.');
    }
    if (deviations > 0) {
      lines.add(
        '$deviations ${deviations == 1 ? 'session' : 'sessions'} played live instead of the scheduled replay '
        '(a saved session could not be read); counted as what they were.',
      );
    }
    lines.add(
      'Plan ${CheckRule.plannedSessions}-${CheckRule.maxSessions} sessions; ${CheckRule.revealEvery} are a pilot. '
      'Every session is counted, and the check does not stop early on a good result.',
    );
    return lines;
  }
}

String _p(double p) => p < 0.001 ? '< 0.001' : p.toStringAsFixed(p < 0.01 ? 3 : 2);

/// The results, or null while fewer than [CheckRule.revealEvery] randomised sessions exist (locked).
/// [planSha]: the hash saved with the plan.
Reveal? reveal({
  required CheckPlan plan,
  required String planSha,
  required Sealed sealed,
  required List<CheckRecord> records,
}) {
  final sorted = [...records]..sort((a, b) => a.index.compareTo(b.index));
  final sets = sorted.length ~/ CheckRule.revealEvery;
  if (sets == 0) return null;
  final shown = sorted.take(sets * CheckRule.revealEvery).toList();
  final planOk = plan.sha == planSha && sealed.sha == plan.allocationSha256 && sealed.consistent;
  // each session counts as what it played; the hashes vouch that the schedule behind it did not change
  Arm armOf(CheckRecord r) => r.arm;
  final deviations = shown.where((r) => r.index < sealed.arms.length && r.arm != sealed.arms[r.index]).length;
  final used = [
    for (final r in shown)
      if (!r.excluded) r,
  ];
  final primary = permutationTest([for (final r in used) r.outcome!], [for (final r in used) armOf(r) == Arm.live], [
    for (final r in used) r.block,
  ]);
  var right = 0, judged = 0, unsure = 0;
  for (final r in shown) {
    final g = r.ratings?.guess;
    if (g == null) continue;
    if (g == 'unsure') {
      unsure++;
    } else {
      judged++;
      if (g == armOf(r).name) right++;
    }
  }
  (double?, double?) mean(int? Function(CheckRatings r) f) {
    double? m(Arm a) {
      final v = [
        for (final r in shown)
          if (armOf(r) == a && r.ratings != null) f(r.ratings!),
      ].whereType<int>().toList();
      return v.isEmpty ? null : v.reduce((x, y) => x + y) / v.length;
    }

    return (m(Arm.live), m(Arm.replay));
  }

  return Reveal(
    kind: plan.kind,
    shown: shown,
    hidden: sorted.length - shown.length,
    planOk: planOk,
    primary: primary,
    excluded: shown.length - used.length,
    right: right,
    judged: judged,
    unsure: unsure,
    guessP: judged == 0 ? null : binomialTail(right, judged),
    means: {'calm': mean((r) => r.calm), 'control': mean((r) => r.control), 'random': mean((r) => r.random)},
    deviations: deviations,
  );
}
