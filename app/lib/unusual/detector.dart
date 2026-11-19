// "Unusual for you": the detector (DECISIONS rows 290-299), a line-by-line port of analysis/unusual.py, checked
// against its fixture (test/unusual_cross_check_test.dart). Plain Dart: no files, no clock.
//
// The design is NightSignal's (Alavi et al. 2022, Nat Med 28:175-184; StanfordBioinformatics/wearable-infection,
// nightsignal.py, Apache-2.0): one number a day against your own running median, a fixed threshold in the number's
// own units, and a card only when a number is beyond it on two days in a row (a lone day never), with one missing
// day bridged. Adapted to the trends page's per-day numbers with the research's updates (early-warning pass 2):
//   - the usual is the median of the 28 days with a value that end a week before the day judged (a change that
//     starts slowly does not drag it along), and a number is judged from 14 such days;
//   - "beyond" is the trends page's arrow rule (usual.dart): 2 robust spreads AND the smallest change that matters;
//   - one direction where the research names one (sleepier, lower mood, more tense, slower; sharp hours' day numbers:
//     less sharp, slower), both ways for sleep length and for the headband's signal numbers;
//   - the headband's signal numbers (alpha speed, alpha strength, eyes-closed rise, jaw muscle bursts) are judged
//     and logged but never in the card: the back-test (analysis/validate_unusual.py) found they would more than
//     double the false cards, and no study shows they warn of anything;
//   - silent for the first 28 days with a core number; a gap of more than 14 days starts the usual again;
//     "feeling ill" pauses it for 14 days and keeps those days out of the usual.
import 'dart:math' as math;

import '../trends/days.dart';
import '../trends/usual.dart';

/// Which way of a number counts.
enum Way { both, up, down }

/// Core numbers make the card; the headband's signal numbers are judged and logged only.
enum StreamGroup { core, headband }

class UnusualStream {
  const UnusualStream(this.id, this.scale, this.way, this.group);

  /// The trends page's measure id (trends.dart).
  final String id;
  final Scale scale;
  final Way way;
  final StreamGroup group;
}

const List<UnusualStream> unusualStreams = [
  UnusualStream('asleep', Scale.minutes, Way.both, StreamGroup.core),
  UnusualStream('kss', Scale.rating, Way.up, StreamGroup.core),
  UnusualStream('mood', Scale.rating, Way.down, StreamGroup.core),
  UnusualStream('tension', Scale.rating, Way.up, StreamGroup.core),
  UnusualStream('reaction', Scale.reaction, Way.up, StreamGroup.core),
  // sharp hours' day numbers (DECISIONS row 380): strain one way only, less sharp and slower
  UnusualStream('sharp', Scale.meanRating, Way.down, StreamGroup.core),
  UnusualStream('dayrt', Scale.reaction, Way.up, StreamGroup.core),
  UnusualStream('iaf', Scale.plain, Way.both, StreamGroup.headband),
  UnusualStream('alpha', Scale.log, Way.both, StreamGroup.headband),
  UnusualStream('rise', Scale.log, Way.both, StreamGroup.headband),
  UnusualStream('jaw', Scale.rate, Way.up, StreamGroup.headband),
];

/// Values the usual needs before a day is judged: the trends page's arrows start at the same count.
const int unusualMinBaseline = arrowMinDays;

class UnusualSettings {
  const UnusualSettings({
    this.lagDays = 7,
    this.window = usualWindowDays,
    this.runDays = 2,
    this.bridge = 1,
    this.minStreams = 1,
    this.silentDays = 28,
    this.restartGap = 14,
    this.pauseDays = 14,
  });

  /// The usual ends this many days before the day judged.
  final int lagDays;

  /// Values in the usual, at most.
  final int window;

  /// Days in a row beyond the usual (NightSignal: 2).
  final int runDays;

  /// Missing days a run may span (NightSignal fills in one).
  final int bridge;

  /// Numbers that must be in a run together (the research's stricter variant: 2).
  final int minStreams;

  /// Days with a core number before the card shows.
  final int silentDays;

  /// More missing days than this start the usual again.
  final int restartGap;

  /// "Feeling ill" pauses it this long after the tap.
  final int pauseDays;
}

/// "Feeling ill" tapped on [tapped] for a card that began on [start]: the days from [start] to [pauseDays] after
/// the tap (or to the day before [resumed]) are paused and kept out of the usual.
class Ill {
  const Ill({required this.start, required this.tapped, this.resumed});
  final String start, tapped;
  final String? resumed;
}

enum StreamState { none, unjudged, inRange, up, down }

/// One number on one day.
class StreamDay {
  StreamDay([this.value]);
  final double? value;

  /// Values in the usual; its median, robust spread and half the no-card band (from 7 values).
  int n = 0;
  double? usual, spread, half;
  StreamState state = StreamState.none;

  /// Beyond the usual in a direction that counts.
  bool off = false;

  /// Days beyond the usual in a row up to this one (0 when not off), and the first of them.
  int run = 0;
  String? runStart;
}

/// A number's open run on a day: its length, direction and first day.
class ActiveRun {
  const ActiveRun(this.run, this.state, this.start);
  final int run;
  final StreamState state;
  final String start;
}

enum UnusualPhase { silent, on, paused }

class DayVerdict {
  DayVerdict(this.day, this.phase, this.validBefore, this.epochStart);
  final String day;
  UnusualPhase phase;

  /// Days before this one with a core number.
  final int validBefore;

  /// The first day the usual may use.
  final String? epochStart;
  final Map<String, StreamDay> streams = {};
  final Map<String, ActiveRun> active = {};
  final List<String> onCore = [], onAll = [];
  bool ruleCore = false, ruleAll = false;

  bool get shown => phase == UnusualPhase.on && ruleCore;
}

int _bisectRight(List<String> a, String x) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (x.compareTo(a[mid]) < 0) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

int _bisectLeft(List<String> a, String x) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (a[mid].compareTo(x) < 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

Map<String, double> _clean(Map<String, double> values, Scale scale) => {
  for (final e in values.entries)
    if (e.value.isFinite && (!scale.logScale || e.value > 0)) e.key: e.value,
};

Set<String> _pausedDays(List<Ill> ill, UnusualSettings settings) {
  final out = <String>{};
  for (final e in ill) {
    var end = addDays(e.tapped, settings.pauseDays); // first day no longer paused
    if (e.resumed != null && e.resumed!.compareTo(end) < 0) end = e.resumed!;
    for (var d = e.start; d.compareTo(end) < 0; d = addDays(d, 1)) {
      out.add(d);
    }
  }
  return out;
}

/// The first day after the pause that holds [day]; null when [day] is not paused.
String? pauseEnd(List<Ill> ill, String day, {UnusualSettings settings = const UnusualSettings()}) {
  final p = _pausedDays(ill, settings);
  if (!p.contains(day)) return null;
  var d = day;
  while (p.contains(d)) {
    d = addDays(d, 1);
  }
  return d;
}

/// The log's and the reference's name of a state ("in" for in range).
String stateName(StreamState s) => s == StreamState.inRange ? 'in' : s.name;

List<String> _epochStarts(List<String> dataDays, int gap) => [
  for (final (i, d) in dataDays.indexed)
    if (i == 0 || daysBetween(dataDays[i - 1], d) - 1 > gap) d,
];

/// Every day from [first] to [last], oldest first, as the card would have judged it with these numbers
/// (trends.dart's day key -> value per measure id).
List<DayVerdict> judgeDays(
  Map<String, Map<String, double>> series,
  String first,
  String last, {
  List<Ill> ill = const [],
  UnusualSettings settings = const UnusualSettings(),
  List<UnusualStream> streams = unusualStreams,
}) {
  final clean = {for (final s in streams) s.id: _clean(series[s.id] ?? const {}, s.scale)};
  final valued = {for (final s in streams) s.id: clean[s.id]!.keys.toList()..sort()};
  final dataDays = {for (final s in streams) ...clean[s.id]!.keys}.toList()..sort();
  final coreDays = {
    for (final s in streams)
      if (s.group == StreamGroup.core) ...clean[s.id]!.keys,
  }.toList()..sort();
  final starts = _epochStarts(dataDays, settings.restartGap);
  final paused = _pausedDays(ill, settings);
  // each number's verdict on each day it has a value, then its runs
  final per = <String, Map<String, StreamDay>>{};
  for (final s in streams) {
    final days = valued[s.id]!;
    final out = <String, StreamDay>{};
    String? prev;
    for (final d in days) {
      final sd = _streamDay(s, clean[s.id]!, days, d, starts, paused, settings);
      if (sd.off) {
        final p = prev == null ? null : out[prev];
        if (p != null && p.off && p.state == sd.state && daysBetween(prev!, d) <= settings.bridge + 1) {
          sd
            ..run = p.run + 1
            ..runStart = p.runStart;
        } else {
          sd
            ..run = 1
            ..runStart = d;
        }
      }
      out[d] = sd;
      prev = d;
    }
    per[s.id] = out;
  }
  return [
    for (var d = first; d.compareTo(last) <= 0; d = addDays(d, 1))
      _day(d, streams, per, valued, coreDays, starts, paused, settings),
  ];
}

StreamDay _streamDay(
  UnusualStream s,
  Map<String, double> values,
  List<String> days,
  String d,
  List<String> starts,
  Set<String> paused,
  UnusualSettings settings,
) {
  final sd = StreamDay(values[d]);
  final i = _bisectRight(starts, d) - 1;
  final epoch = i >= 0 ? starts[i] : d;
  final end = addDays(d, -settings.lagDays);
  final window = <String>[];
  var k = _bisectRight(days, end) - 1;
  while (k >= 0 && window.length < settings.window && days[k].compareTo(epoch) >= 0) {
    if (!paused.contains(days[k])) window.add(days[k]);
    k--;
  }
  sd.n = window.length;
  final u = usualOfValues([for (final x in window.reversed) values[x]!], s.scale);
  if (u.ready) {
    sd
      ..usual = u.median
      ..spread = u.spread
      ..half = u.half;
  }
  if (!u.ready || sd.n < unusualMinBaseline) {
    sd.state = StreamState.unjudged;
    return sd;
  }
  final a = u.arrow(values[d]!);
  sd.state = switch (a) {
    Arrow.up => StreamState.up,
    Arrow.down => StreamState.down,
    Arrow.none => StreamState.inRange,
  };
  sd.off = a != Arrow.none && (s.way == Way.both || (s.way == Way.up) == (a == Arrow.up));
  return sd;
}

DayVerdict _day(
  String d,
  List<UnusualStream> streams,
  Map<String, Map<String, StreamDay>> per,
  Map<String, List<String>> valued,
  List<String> coreDays,
  List<String> starts,
  Set<String> paused,
  UnusualSettings settings,
) {
  final i = _bisectRight(starts, d) - 1;
  final v = DayVerdict(d, UnusualPhase.on, _bisectLeft(coreDays, d), i >= 0 ? starts[i] : null);
  if (paused.contains(d)) {
    v.phase = UnusualPhase.paused;
  } else if (v.validBefore < settings.silentDays) {
    v.phase = UnusualPhase.silent;
  }
  for (final s in streams) {
    v.streams[s.id] = per[s.id]![d] ?? StreamDay();
    final days = valued[s.id]!;
    final k = _bisectRight(days, d) - 1;
    if (k < 0 || daysBetween(days[k], d) > settings.bridge) continue;
    final last = per[s.id]![days[k]]!;
    if (last.run > 0 && last.runStart != null) {
      v.active[s.id] = ActiveRun(last.run, last.state, last.runStart!);
      if (last.run >= settings.runDays) {
        v.onAll.add(s.id);
        if (s.group == StreamGroup.core) v.onCore.add(s.id);
      }
    }
  }
  v.ruleCore = v.onCore.length >= settings.minStreams;
  v.ruleAll = v.onAll.length >= settings.minStreams;
  return v;
}

/// Runs of days with the rule (core numbers, or with the headband's added), as (first day, last day);
/// [shownOnly]: only those that began while the card was on.
List<(String, String)> episodes(List<DayVerdict> verdicts, {bool withHeadband = false, bool shownOnly = false}) {
  final out = <(String, String)>[];
  String? start;
  DayVerdict? prev;
  for (final v in verdicts) {
    if (withHeadband ? v.ruleAll : v.ruleCore) {
      start ??= v.day;
    } else if (start != null && prev != null) {
      out.add((start, prev.day));
      start = null;
    }
    prev = v;
  }
  if (start != null && prev != null) out.add((start, prev.day));
  if (!shownOnly) return out;
  final phase = {for (final v in verdicts) v.day: v.phase};
  return [
    for (final e in out)
      if (phase[e.$1] == UnusualPhase.on) e,
  ];
}

/// The mean of a number's values over its run up to [last] (the days with a value).
double runMean(Map<String, double> values, String start, String last) {
  final v = [
    for (final e in values.entries)
      if (e.key.compareTo(start) >= 0 && e.key.compareTo(last) <= 0 && e.value.isFinite) e.value,
  ];
  return v.isEmpty ? double.nan : v.reduce((a, b) => a + b) / v.length;
}

/// Calendar days a run spans, from its first day to [last].
int runSpan(String start, String last) => math.max(1, daysBetween(start, last) + 1);
