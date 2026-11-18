// Sleep pressure from the sleep log (DECISIONS rows 64 and 123): process S of the two-process model (Borbely
// 1982; time constants of Daan, Beersma & Borbely 1984, as used in fatigue models): it rises toward a ceiling while
// you are awake (time constant 18.2 h) and drains toward zero while you sleep (4.2 h). Sleep = the sleep periods
// of the phone's sleep reports. Not measured: an estimate from sleep and wake times only. The body clock (process
// C) and caffeine are left out; the screen says so.
//
// Scale: 0 = just after a regular night (8 h asleep after 16 h awake, repeated), 100 = bedtime after a regular
// day. "Like N hours awake" = how long after a regular night you would reach the same level.
//
// Where the log has holes the estimate stops: before the first recorded sleep, across a waking stretch over 30
// hours (a night was not recorded), and from 30 hours after the last recorded sleep. After a hole it starts again
// at the next sleep as if you went to bed at a regular bedtime's level (a planning assumption).
import 'dart:math' as math;

const double riseTauH = 18.2;
const double drainTauH = 4.2;

/// A waking stretch longer than this means a night is missing from the log.
const double maxWakeH = 30;

/// The regular schedule that sets the scale.
const double regularWakeH = 16, regularSleepH = 8;

typedef SleepSpan = ({DateTime start, DateTime end});

final double _eRise = math.exp(-regularWakeH / riseTauH);
final double _eDrain = math.exp(-regularSleepH / drainTauH);

/// S on waking and at bedtime on a regular schedule (the steady state of 16 h up, 8 h asleep).
final double sRested = _eDrain * (1 - _eRise) / (1 - _eRise * _eDrain);
final double sBedtime = 1 - (1 - sRested) * _eRise;

double _wake(double s0, double hours) => 1 - (1 - s0) * math.exp(-hours / riseTauH);
double _sleep(double s0, double hours) => s0 * math.exp(-hours / drainTauH);
double _h(Duration d) => d.inSeconds / 3600;

/// S on the 0-100 scale.
double toLevel(double s) => (s - sRested) / (sBedtime - sRested) * 100;

class PressureModel {
  /// [sleeps] in any order; overlapping spans are merged.
  PressureModel(List<SleepSpan> sleeps) : _sleeps = _merge(sleeps);

  final List<SleepSpan> _sleeps;

  static List<SleepSpan> _merge(List<SleepSpan> spans) {
    final s = [
      for (final x in spans)
        if (x.end.isAfter(x.start)) x,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final out = <SleepSpan>[];
    for (final x in s) {
      if (out.isNotEmpty && !x.start.isAfter(out.last.end)) {
        final last = out.removeLast();
        out.add((start: last.start, end: x.end.isAfter(last.end) ? x.end : last.end));
      } else {
        out.add(x);
      }
    }
    return out;
  }

  bool get isEmpty => _sleeps.isEmpty;

  /// The newest recorded sleep's end.
  DateTime? get lastWake => _sleeps.isEmpty ? null : _sleeps.last.end;

  /// S at [t], or null where the log cannot tell.
  double? sAt(DateTime t) {
    if (_sleeps.isEmpty || t.isBefore(_sleeps.first.start)) return null;
    var s = sBedtime;
    for (var k = 0; k < _sleeps.length; k++) {
      final sl = _sleeps[k];
      if (k > 0) {
        final prevEnd = _sleeps[k - 1].end;
        final gap = _h(sl.start.difference(prevEnd));
        if (t.isBefore(sl.start)) {
          final h = _h(t.difference(prevEnd));
          return gap > maxWakeH && h > maxWakeH ? null : _wake(s, h);
        }
        s = gap > maxWakeH ? sBedtime : _wake(s, gap);
      }
      if (!t.isAfter(sl.end)) return _sleep(s, _h(t.difference(sl.start)));
      s = _sleep(s, _h(sl.end.difference(sl.start)));
    }
    final h = _h(t.difference(_sleeps.last.end));
    return h > maxWakeH ? null : _wake(s, h);
  }

  /// The 0-100 level at [t] (below 0 after a long sleep, over 100 after a long day), or null.
  double? levelAt(DateTime t) {
    final s = sAt(t);
    return s == null ? null : toLevel(s);
  }

  /// How many hours after a regular night you would reach the level of [t]; 0 when at or under the rested level.
  double? hoursAwakeLike(DateTime t) {
    final s = sAt(t);
    if (s == null) return null;
    if (s <= sRested) return 0;
    return -riseTauH * math.log((1 - s) / (1 - sRested));
  }

  /// Asleep at [t] by the log.
  bool asleepAt(DateTime t) => _sleeps.any((s) => !t.isBefore(s.start) && t.isBefore(s.end));

  /// The sleep spans that overlap [from]..[to].
  List<SleepSpan> sleepsBetween(DateTime from, DateTime to) => [
    for (final s in _sleeps)
      if (s.end.isAfter(from) && s.start.isBefore(to)) s,
  ];

  /// Points every [step] from [from] to [to] (both included); level null where the log cannot tell.
  List<({DateTime t, double? level})> curve(DateTime from, DateTime to, {Duration step = const Duration(minutes: 10)}) {
    final out = <({DateTime t, double? level})>[];
    for (var t = from; !t.isAfter(to); t = t.add(step)) {
      out.add((t: t, level: levelAt(t)));
    }
    if (out.isEmpty || out.last.t != to) out.add((t: to, level: levelAt(to)));
    return out;
  }
}
