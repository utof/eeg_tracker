// The learning verdict (ROADMAP row 21; DECISIONS 421-422; docs/evidence/meditation-feedback.md): is the trained
// signal going up across your meditations? The research's rule, as written:
//   - only after 8 sessions, checked again at 12 (then every 12, on the latest 12, so a plateau shows as flat);
//     before that "not enough sessions yet", never a verdict from too little data;
//   - the measure is the silent minutes at the end of each session (silent_block.dart): the strongest sign of
//     learning is an upward trend across sessions in short no-feedback blocks;
//   - a robust trend (trend.dart: Theil-Sen) whose 90 % range must stay above zero, and jaw or neck muscle and
//     drowsy time in those minutes must not have clearly risen with it (their own range above zero);
//   - flat or falling is said as plainly as rising.
// It is "seen together, not tested": the sessions and the number rose together, but practice itself, sleep, the
// time of day or the headband's fit can do that too. Only the replay check's randomised blocks test the sound
// itself; when they have revealed a set, their live-against-replay result for the silent minutes is shown with it.
// Pure: summaries in, words out.
import 'dart:math' as math;

import '../training/control.dart' show SessionKind;
import '../training/reveal.dart' show Reveal;
import 'tracker.dart';
import 'trend.dart';

abstract final class LearningRule {
  /// The first verdict, the second check, then every this many sessions on the latest [every].
  static const int first = 8, second = 12, every = 12;
}

enum Verdict { notYet, up, upAlongside, flat, down }

/// The replay check's test of the silent minutes (training/reveal.dart): live minus replay of their number,
/// with its permutation p, over the revealed sessions [first]-[last] (numbers in the check).
typedef SilentTest = ({double diff, double p, int sessions, int first, int last});

class Learning {
  const Learning({
    required this.verdict,
    required this.have,
    this.from = 0,
    this.to = 0,
    this.nextAt = LearningRule.first,
    this.silent,
    this.withSound,
    this.alongside = const [],
    this.bluetooth = 0,
    this.inCheck = 0,
    this.tested,
  });

  final Verdict verdict;

  /// Meditations with a number for their silent minutes (the ones that count).
  final int have;

  /// The sessions the verdict covers, numbered from 1 in the order they happened; [nextAt]: the next check.
  final int from, to, nextAt;

  /// The trend per session of the silent minutes' number (log10), and of the same with the sound on.
  final Trend? silent, withSound;

  /// What rose clearly alongside: 'jaw or neck muscle', 'drowsiness'.
  final List<String> alongside;

  /// Of the covered sessions: how many played over Bluetooth, how many were in the replay check.
  final int bluetooth, inCheck;
  final SilentTest? tested;

  int get count => to - from + 1;

  /// Plain sentences: the verdict first, the honesty line last.
  List<String> get lines {
    final out = <String>[];
    final s = silent;
    if (verdict == Verdict.notYet || s == null) {
      out.add(
        'Not enough sessions yet: $have of ${LearningRule.first} with the silent minutes at the end. The first '
        'verdict comes after ${LearningRule.first}, a second at ${LearningRule.second}.',
      );
    } else {
      final over = from == 1 ? 'over your first $to sessions' : 'over sessions $from-$to';
      final range = '(90 % range ${pct(s.low)} to ${pct(s.high)} %)';
      out.add(switch (verdict) {
        Verdict.up => 'Going up: alpha in the silent minutes rose about ${pct(s.slope)} % a session $over $range.',
        Verdict.upAlongside =>
          'Alpha in the silent minutes rose about ${pct(s.slope)} % a session $over $range, but '
              '${alongside.join(' and ')} rose with it, so it is not counted as learning.',
        Verdict.down => 'Going down: alpha in the silent minutes fell about ${pct(s.slope)} % a session $over $range.',
        _ =>
          'No clear trend: alpha in the silent minutes changed about ${pct(s.slope)} % a session $over $range. '
              'That is common (16-57 % of people do not learn a given rhythm); the practice still counts.',
      });
      final w = withSound;
      if (w != null) {
        out.add('With the sound on: about ${pct(w.slope)} % a session (90 % range ${pct(w.low)} to ${pct(w.high)} %).');
      }
      if (bluetooth > 0) {
        out.add(
          '$bluetooth of these $count sessions played over Bluetooth, where the sound comes about 0.25-0.5 s late.',
        );
      }
      if (inCheck > 0) {
        out.add('$inCheck of these $count sessions were in the replay check, so some had replayed sound.');
      }
    }
    final t = tested;
    if (t != null) {
      final what = t.p < 0.05
          ? 'alpha in the silent minutes was ${_wholePct(t.diff)} after live sound against replayed sound (p = ${_p(t.p)})'
          : 'no clear difference in the silent minutes between live and replayed sound (${_wholePct(t.diff)}, '
                'p = ${_p(t.p)})';
      out.add('Tested by the replay check (sessions ${t.first}-${t.last}): $what.');
    }
    if (verdict != Verdict.notYet) {
      out.add(
        'Seen together, not tested: practice itself, sleep, the time of day or how the headband sits can move this '
        'too. Checked again at $nextAt sessions.',
      );
    }
    return out;
  }
}

/// A per-session change of a log10 number as a signed percentage with one decimal ("+2.3", "−0.4", "0.0").
String pct(double log10Change) {
  final v = (math.pow(10, log10Change) - 1) * 100, r = (v * 10).round() / 10;
  if (r == 0) return '0.0';
  return '${r > 0 ? '+' : '−'}${r.abs().toStringAsFixed(1)}';
}

String _wholePct(double log10Change) {
  final r = ((math.pow(10, log10Change) - 1) * 100).round();
  return '${r > 0
      ? '+'
      : r < 0
      ? '−'
      : ''}${r.abs()} %';
}

String _p(double p) => p < 0.001 ? '< 0.001' : p.toStringAsFixed(p < 0.01 ? 3 : 2);

/// The replay check's test of the silent minutes from its revealed results (null without one).
SilentTest? silentTestOf(Reveal? r) {
  final s = r?.silent;
  if (r == null || s == null) return null;
  return (
    diff: s.diff,
    p: s.p,
    sessions: s.live + s.replay,
    first: r.shown.first.index + 1,
    last: r.shown.last.index + 1,
  );
}

/// The verdict over [sessions] (any order; other kinds and sessions without a silent-minutes number are left
/// out). [tested]: the replay check's revealed test of the silent minutes, when there is one.
Learning learningVerdict(List<MeditationSummary> sessions, {SilentTest? tested}) {
  final counted = [
    for (final s in sessions)
      if (s.kind == SessionKind.meditation && s.silent?.alpha != null) s,
  ]..sort((a, b) => a.start.compareTo(b.start));
  final have = counted.length;
  if (have < LearningRule.first) return Learning(verdict: Verdict.notYet, have: have, tested: tested);
  final at = have < LearningRule.second ? LearningRule.first : have ~/ LearningRule.every * LearningRule.every;
  final from = at <= LearningRule.second ? 1 : at - LearningRule.every + 1;
  final use = counted.sublist(from - 1, at);
  final x = [for (var i = from; i <= at; i++) i.toDouble()];
  Trend? trendOf(double? Function(MeditationSummary s) f) {
    final xs = <double>[], ys = <double>[];
    for (var i = 0; i < use.length; i++) {
      final v = f(use[i]);
      if (v == null) continue;
      xs.add(x[i]);
      ys.add(v);
    }
    return ys.length < LearningRule.first ? null : theilSen(xs, ys);
  }

  final silent = trendOf((s) => s.silent!.alpha)!;
  final alongside = [
    if ((trendOf((s) => s.silent!.muscleShare)?.low ?? 0) > 0) 'jaw or neck muscle',
    if ((trendOf((s) => s.silent!.drowsyShare)?.low ?? 0) > 0) 'drowsiness',
  ];
  final verdict = silent.low > 0
      ? (alongside.isEmpty ? Verdict.up : Verdict.upAlongside)
      : silent.high < 0
      ? Verdict.down
      : Verdict.flat;
  return Learning(
    verdict: verdict,
    have: have,
    from: from,
    to: at,
    nextAt: at < LearningRule.second ? LearningRule.second : at + LearningRule.every,
    silent: silent,
    withSound: trendOf((s) => s.outcome),
    alongside: alongside,
    bluetooth: use.where((s) => s.bluetoothSound).length,
    inCheck: use.where((s) => s.check?['phase'] == 'randomised').length,
    tested: tested,
  );
}
