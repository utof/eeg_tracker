// What costs battery (DECISIONS 716). Plain Dart over the power samples (metrics.dart) and the night logs' phone
// battery lines; the Battery page shows the result.
//
// 1. Samples of every engine, sorted by time; between two neighbours is a stretch. A stretch with a charger at either
//    end, or whose charge went up, is left out. Its use is the drop of the charge counter (mAh), or of the level times
//    the battery's size when the phone has no counter.
// 2. A stretch up to 10 minutes long is "watched": what was on is the union of every engine's latest sample from the
//    5 minutes before its start, plus `screen` when the screen was on. A longer stretch (up to a day) had none of the
//    app's work in it: the phone with the app closed, other apps and their screen time included.
// 3. Per combination of things on: hours, mAh, mAh an hour, the app's CPU time.
// 4. Things always on together (the night's recording and its headband link) cannot be told apart: they become one
//    group. Each group's mAh an hour is fitted so the groups on in a combination add up to its rate (least squares
//    weighted by hours, no group below 0). So "Signal tab adds 60 mAh/h" means: over the app's other pages, with the
//    screen counted in the group it is always on with.
// 5. The headband's own battery from the night logs, without the gauge's stuck values (headband_battery below).
import 'dart:math' as math;

import '../headband/battery_estimate.dart';
import 'activity.dart' show featureLabel;

/// A watched stretch is at most this long; a longer one is "app closed".
const Duration watchedMax = Duration(minutes: 10);

/// An engine's sample still tells what is on in it this long after it was taken.
const Duration sampleStale = Duration(minutes: 5);

/// A stretch longer than this says nothing (the phone was off, the app was not used for days).
const Duration closedMax = Duration(hours: 24);

/// A group needs this much time on before the page gives it a number.
const Duration groupMin = Duration(minutes: 15);

class PowerPoint {
  const PowerPoint({
    required this.t,
    required this.engine,
    this.pct,
    this.uah,
    this.plug,
    this.screen,
    this.cpu,
    this.on = const [],
  });

  final DateTime t;
  final String engine;
  final int? pct, uah, cpu;
  final String? plug;
  final bool? screen;
  final List<String> on;

  bool get plugged => plug != null && plug != 'no';

  /// A metrics `power` line of [engine]; null for anything else.
  static PowerPoint? fromLine(Map<String, Object?> j, String engine) {
    if (j['kind'] != 'power') return null;
    final t = DateTime.tryParse('${j['t']}');
    if (t == null) return null;
    int? i(String k) => j[k] is num ? (j[k]! as num).toInt() : null;
    final on = j['on'];
    return PowerPoint(
      t: t,
      engine: engine,
      pct: i('pct'),
      uah: i('uah'),
      plug: j['plug'] is String ? j['plug']! as String : null,
      screen: j['screen'] is bool ? j['screen']! as bool : null,
      cpu: i('cpu'),
      on: on is List ? [for (final f in on) if (f is String) f] : const [],
    );
  }
}

final RegExp _phoneLine = RegExp(
  r'^(\S+) phone battery (\d+|\?)% charge (-?\d+|\?) uAh current (-?\d+|\?) uA (unplugged|plugged (\S+)|plugged \?)',
);

/// A night log's `phone battery 93% charge 3556000 uAh ...` line as a sample of a night (the night's recording and
/// its headband on; the screen not known). Null for any other line.
PowerPoint? nightLogPoint(String line) {
  final m = _phoneLine.firstMatch(line);
  if (m == null) return null;
  final t = DateTime.tryParse(m.group(1)!);
  if (t == null) return null;
  final unplugged = m.group(5) == 'unplugged';
  return PowerPoint(
    t: t,
    engine: 'night-log',
    pct: int.tryParse(m.group(2)!),
    uah: int.tryParse(m.group(3)!),
    plug: unplugged ? 'no' : (m.group(6) ?? '?'),
    on: const ['night', 'headband'],
  );
}

class Stretch {
  const Stretch({required this.from, required this.to, required this.mah, required this.on, this.cpuMs, this.watched = true});
  final DateTime from, to;
  final double mah;

  /// What was on, sorted (`screen` among them when the screen was on); empty for a closed stretch.
  final List<String> on;
  final int? cpuMs;
  final bool watched;

  double get hours => to.difference(from).inMilliseconds / 3600000;
}

/// The battery's size in mAh from the samples that have both the level and the counter (their median), or null.
double? capacityMah(List<PowerPoint> points) {
  final v = [
    for (final p in points)
      if (p.uah != null && p.pct != null && p.pct! >= 10 && p.uah! > 0) p.uah! / 1000 * 100 / p.pct!,
  ]..sort();
  return v.isEmpty ? null : v[v.length ~/ 2];
}

/// The stretches between neighbouring samples ([points] in any order), the night logs' own samples dropped where an
/// engine's sample lies within 3 minutes (the same night measured twice).
List<Stretch> stretches(List<PowerPoint> points) {
  final own = points.where((p) => p.engine != 'night-log').map((p) => p.t.millisecondsSinceEpoch).toList()..sort();
  bool near(DateTime t) {
    final ms = t.millisecondsSinceEpoch;
    var lo = 0, hi = own.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (own[mid] < ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (final k in [lo - 1, lo]) {
      if (k >= 0 && k < own.length && (own[k] - ms).abs() <= 180000) return true;
    }
    return false;
  }

  final all = [
    for (final p in points)
      if (p.engine != 'night-log' || !near(p.t)) p,
  ]..sort((a, b) => a.t.compareTo(b.t));
  final cap = capacityMah(all);
  final latest = <String, PowerPoint>{};
  final out = <Stretch>[];
  for (var i = 0; i + 1 < all.length; i++) {
    final a = all[i], b = all[i + 1];
    latest[a.engine] = a;
    final dt = b.t.difference(a.t);
    if (dt <= Duration.zero || dt > closedMax || a.plugged || b.plugged) continue;
    double? mah;
    if (a.uah != null && b.uah != null) {
      mah = (a.uah! - b.uah!) / 1000;
    } else if (a.pct != null && b.pct != null && cap != null) {
      mah = (a.pct! - b.pct!) * cap / 100;
    }
    if (mah == null || mah < 0) continue;
    final watched = dt <= watchedMax;
    final on = <String>{};
    if (watched) {
      for (final p in latest.values) {
        if (a.t.difference(p.t) <= sampleStale) on.addAll(p.on);
      }
      if (a.screen == true) on.add('screen');
    }
    final cpu = a.cpu != null && b.cpu != null && b.cpu! >= a.cpu! ? b.cpu! - a.cpu! : null;
    out.add(Stretch(from: a.t, to: b.t, mah: mah, on: on.toList()..sort(), cpuMs: watched ? cpu : null, watched: watched));
  }
  return out;
}

/// One combination of things on, or one group of things always on together.
class Use {
  Use(this.key, this.members);

  /// `night+headband+screen`; the members joined.
  final String key;
  final List<String> members;
  double hours = 0, mah = 0;

  /// Hours with the screen on, and the CPU time over the hours it is known for.
  double screenHours = 0, cpuHours = 0;
  int cpuMs = 0;

  /// The days it was on.
  final Set<String> days = {};

  double get rate => hours > 0 ? mah / hours : 0;

  /// The share of its time the app's code kept one CPU core busy (0-1, can exceed 1 on several cores), or null.
  double? get cpuShare => cpuHours > 0 ? cpuMs / (cpuHours * 3600000) : null;

  double get screenShare => hours > 0 ? screenHours / hours : 0;

  void add(Stretch s) {
    hours += s.hours;
    mah += s.mah;
    if (s.on.contains('screen')) screenHours += s.hours;
    if (s.cpuMs != null) {
      cpuHours += s.hours;
      cpuMs += s.cpuMs!;
    }
    days.add(s.from.toIso8601String().substring(0, 10));
  }
}

/// A group's cost: what it adds an hour, and what it was on.
class GroupCost {
  const GroupCost({required this.use, required this.adds, required this.perDay});
  final Use use;

  /// mAh an hour this group adds where it is on (the fit), or null when there is too little to fit.
  final double? adds;

  /// mAh a day at the rate it adds and the hours a day it ran (over the days with any samples).
  final double? perDay;
}

class BatteryReport {
  const BatteryReport({
    required this.combos,
    required this.groups,
    required this.closed,
    required this.capacity,
    required this.watchedHours,
    required this.days,
  });

  /// Every combination of things on, most hours first.
  final List<Use> combos;

  /// Every group with its cost, most mAh a day first.
  final List<GroupCost> groups;

  /// The phone with the app closed (other apps and the screen included), or null without such stretches.
  final Use? closed;
  final double? capacity;
  final double watchedHours;

  /// Days with any watched stretch.
  final int days;

  bool get empty => combos.isEmpty && closed == null;
}

BatteryReport batteryReport(List<PowerPoint> points) {
  final all = stretches(points);
  final combos = <String, Use>{};
  Use? closed;
  final days = <String>{};
  var watchedHours = 0.0;
  for (final s in all) {
    if (!s.watched) {
      (closed ??= Use('', const [])).add(s);
      continue;
    }
    if (s.on.isEmpty) continue; // nothing of the app on in a watched stretch: not the app's (rare: between engines)
    final key = s.on.join('+');
    combos.putIfAbsent(key, () => Use(key, s.on)).add(s);
    days.add(s.from.toIso8601String().substring(0, 10));
    watchedHours += s.hours;
  }
  final list = combos.values.toList()..sort((a, b) => b.hours.compareTo(a.hours));
  return BatteryReport(
    combos: list,
    groups: _groups(list, math.max(1, days.length)),
    closed: closed,
    capacity: capacityMah(points),
    watchedHours: watchedHours,
    days: days.length,
  );
}

/// Features that are on in exactly the same combinations become one group; each group's rate is fitted.
List<GroupCost> _groups(List<Use> combos, int days) {
  final where = <String, Set<String>>{};
  for (final c in combos) {
    for (final f in c.members) {
      (where[f] ??= {}).add(c.key);
    }
  }
  final bySignature = <String, List<String>>{};
  for (final e in where.entries) {
    final sig = (e.value.toList()..sort()).join('|');
    (bySignature[sig] ??= []).add(e.key);
  }
  final groups = [
    for (final members in bySignature.values) Use((members..sort()).join('+'), members),
  ];
  for (final g in groups) {
    for (final c in combos) {
      if (c.members.contains(g.members.first)) {
        g.hours += c.hours;
        g.mah += c.mah;
        g.screenHours += c.screenHours;
        g.cpuHours += c.cpuHours;
        g.cpuMs += c.cpuMs;
        g.days.addAll(c.days);
      }
    }
  }
  final beta = fitRates(combos, groups);
  final out = <GroupCost>[];
  for (var k = 0; k < groups.length; k++) {
    final g = groups[k];
    final enough = g.hours * 60 >= groupMin.inMinutes;
    final adds = enough ? beta[k] : null;
    out.add(GroupCost(use: g, adds: adds, perDay: adds == null ? null : adds * g.hours / days));
  }
  out.sort((a, b) => (b.perDay ?? -1).compareTo(a.perDay ?? -1));
  return out;
}

/// Non-negative weighted least squares: each combination's rate as the sum of its groups' rates, weighted by hours
/// (coordinate descent; the problem is convex, so it settles on the best fit). Returns one rate per group.
List<double> fitRates(List<Use> combos, List<Use> groups, {int rounds = 2000}) {
  final x = [
    for (final c in combos) [for (final g in groups) c.members.contains(g.members.first) ? 1.0 : 0.0],
  ];
  final w = [for (final c in combos) c.hours];
  final y = [for (final c in combos) c.rate];
  final beta = List<double>.filled(groups.length, 0);
  final pred = List<double>.filled(combos.length, 0);
  for (var round = 0; round < rounds; round++) {
    var moved = 0.0;
    for (var k = 0; k < groups.length; k++) {
      var num = 0.0, den = 0.0;
      for (var c = 0; c < combos.length; c++) {
        if (x[c][k] == 0) continue;
        num += w[c] * (y[c] - pred[c] + beta[k]);
        den += w[c];
      }
      if (den == 0) continue;
      final next = math.max(0.0, num / den);
      final d = next - beta[k];
      if (d == 0) continue;
      for (var c = 0; c < combos.length; c++) {
        if (x[c][k] != 0) pred[c] += d;
      }
      beta[k] = next;
      moved = math.max(moved, d.abs());
    }
    if (moved < 1e-9) break;
  }
  return beta;
}

/// A group's words: `Headband link, Night recording`; the screen goes unsaid beside the open app (it is on with it).
String groupLabel(Use g) {
  final open = g.members.contains('app-open');
  return [
    for (final f in g.members)
      if (!(open && f == 'screen')) f == 'screen' ? 'Screen on' : featureLabel(f),
  ].join(', ');
}

/// The plain sentences about a group's cost after its rate: its share of the battery an hour, what it adds to what
/// runs with it, whether it is mostly the screen, the processor, and its mAh a day. Empty when there is too little.
List<String> adviceParts(GroupCost c, {double? capacity, GroupCost? screen}) {
  final g = c.use;
  if (c.adds == null) return const [];
  final parts = <String>[];
  if (capacity != null && capacity > 0) parts.add('${(g.rate / capacity * 100).toStringAsFixed(1)} % of the battery an hour');
  if (g.members.length == 1 && g.rate - c.adds! > 1) {
    parts.add('it adds about ${c.adds!.round()} mAh an hour to what runs with it');
  }
  final screenAdds = screen?.adds;
  if (g.screenShare >= 0.7 && !g.members.contains('screen') && screenAdds != null && screenAdds > c.adds!) {
    parts.add('mostly the screen being on');
  }
  final cpu = g.cpuShare;
  if (cpu != null && cpu >= 0.25) {
    parts.add('the app\'s code kept the processor busy ${(cpu * 100).round()} % of the time: worth optimising');
  } else if (cpu != null && cpu < 0.05 && c.adds! >= 50) {
    parts.add('little of it is the app\'s code (the radio, the screen or the sound)');
  }
  if (c.perDay != null && c.perDay! >= 1) parts.add('about ${c.perDay!.round()} mAh a day as you use it');
  return parts;
}

/// One plain sentence of advice for a group (`Signal tab: 210 mAh an hour while on; ...`), or null when there is too
/// little to say: for the log and the assistant; the page shows [adviceParts] under the rate.
String? advice(GroupCost c, {double? capacity, GroupCost? screen}) {
  if (c.adds == null) return null;
  final parts = adviceParts(c, capacity: capacity, screen: screen);
  final head = '${groupLabel(c.use)}: ${c.use.rate.round()} mAh an hour while on';
  if (parts.isNotEmpty && parts.first.endsWith('of the battery an hour')) {
    final pct = parts.removeAt(0).replaceFirst(' an hour', '');
    return '$head ($pct)${parts.isEmpty ? '' : '; ${parts.join('; ')}'}.';
  }
  return '$head${parts.isEmpty ? '' : '; ${parts.join('; ')}'}.';
}

/// [parts] as sentences for the page: each starts with a capital and ends with a full stop.
String sentences(List<String> parts) =>
    [for (final p in parts) '${p[0].toUpperCase()}${p.substring(1)}.'].join(' ');

// ---------------------------------------------------------------------------------------------------------------------
// The headband's battery (DECISIONS 40, 716): the gauge reads whole percent and sticks at 0-2 % and 100 % while
// streaming (scripts/battery.py), and on 2026-11-19 it held 6 % for nine hours: a value that does not move for an hour
// is stuck too. Which values and how long: the one battery rule (headband/battery_estimate.dart `BandBatteryRule`).

/// The line under the Battery page's "Now" row: the hours the card's estimate stands for, by the one rule.
String bandNowWords(BandBattery b) {
  final h = b.hoursLeft;
  final rate = BandBatteryRule.drainPctPerHour;
  final r = rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toStringAsFixed(1);
  return '${h == null ? '' : 'about ${h.toStringAsFixed(1)} h of streaming left at $r % an hour · '}'
      'the same estimate as on the headband card';
}

final RegExp _bandLine = RegExp(r'^(\S+) .*\bbattery (\d+)%');

/// `(time, percent)` of a night log's headband lines (`samples ... battery 37%`, `connected ... battery 100%`); the
/// phone's own battery lines are not the headband's.
List<(DateTime, int)> headbandReadings(Iterable<String> lines) {
  final out = <(DateTime, int)>[];
  for (final l in lines) {
    if (l.contains(' phone battery ')) continue;
    final m = _bandLine.firstMatch(l);
    if (m == null) continue;
    final t = DateTime.tryParse(m.group(1)!);
    final v = int.tryParse(m.group(2)!);
    if (t != null && v != null) out.add((t, v));
  }
  return out;
}

class HeadbandRun {
  const HeadbandRun({required this.start, required this.end, this.first, this.last, this.perHour, this.stuckAt});
  final DateTime start, end;

  /// The first and last believable readings, or null when there were none.
  final int? first, last;

  /// The drain in % an hour from a straight line through the believable readings, or null.
  final double? perHour;

  /// The value the gauge stuck at most of the time, when it did.
  final int? stuckAt;

  double get hours => end.difference(start).inMilliseconds / 3600000;
}

/// One run's headband battery: the stuck values dropped, a jump up of over 3 % (a charge) restarts the trend.
HeadbandRun? headbandRun(List<(DateTime, int)> readings) {
  if (readings.isEmpty) return null;
  final r = [...readings]..sort((a, b) => a.$1.compareTo(b.$1));
  // a value seen over an hour or more (the rule's time) that makes up at least half of the readings in that span is stuck (a value seen
  // again after a charge has other values between)
  final seen = <int, (int, int)>{};
  for (var i = 0; i < r.length; i++) {
    final h = seen[r[i].$2];
    seen[r[i].$2] = h == null ? (i, i) : (h.$1, i);
  }
  final flat = <int>{};
  for (final e in seen.entries) {
    final (a, b) = e.value;
    if (r[b].$1.difference(r[a].$1) < BandBatteryRule.flatStuck) continue;
    final mine = r.sublist(a, b + 1).where((x) => x.$2 == e.key).length;
    if (mine * 2 >= b - a + 1) flat.add(e.key);
  }
  final counts = <int, int>{};
  for (final (_, v) in r) {
    if (BandBatteryRule.stuckLevels.contains(v) || flat.contains(v)) counts[v] = (counts[v] ?? 0) + 1;
  }
  var good = [
    for (final (t, v) in r)
      if (!BandBatteryRule.stuckLevels.contains(v) && !flat.contains(v)) (t, v),
  ];
  for (var i = good.length - 1; i > 0; i--) {
    if (good[i].$2 > good[i - 1].$2 + 3) {
      good = good.sublist(i);
      break;
    }
  }
  int? stuckAt;
  if (counts.isNotEmpty) {
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (top.value * 2 >= r.length) stuckAt = top.key;
  }
  double? perHour;
  if (good.length >= 2 &&
      good.last.$1.difference(good.first.$1) >= const Duration(minutes: 20) &&
      good.first.$2 - good.last.$2 >= 2) {
    final n = good.length;
    final t0 = good.first.$1.millisecondsSinceEpoch;
    final ts = [for (final (t, _) in good) (t.millisecondsSinceEpoch - t0) / 3600000];
    final vs = [for (final (_, v) in good) v.toDouble()];
    final mt = ts.reduce((a, b) => a + b) / n, mv = vs.reduce((a, b) => a + b) / n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (ts[i] - mt) * (vs[i] - mv);
      den += (ts[i] - mt) * (ts[i] - mt);
    }
    if (den > 0 && -num / den > 0.1) perHour = -num / den;
  }
  return HeadbandRun(
    start: r.first.$1,
    end: r.last.$1,
    first: good.isEmpty ? null : good.first.$2,
    last: good.isEmpty ? null : good.last.$2,
    perHour: perHour,
    stuckAt: stuckAt,
  );
}

/// The run in words: `9.3 h · 96 % to 41 % · 6.1 % an hour`, or why there is no rate.
String headbandWords(HeadbandRun r) {
  final h = '${r.hours.toStringAsFixed(1)} h';
  if (r.first == null) return '$h · the gauge was stuck${r.stuckAt == null ? '' : ' at ${r.stuckAt} %'} the whole time';
  final span = '${r.first} % to ${r.last} %';
  final rate = r.perHour == null ? 'too little change for a rate' : '${r.perHour!.toStringAsFixed(1)} % an hour';
  final stuck = r.stuckAt == null ? '' : ' (the gauge stuck at ${r.stuckAt} % most of the time)';
  return '$h · $span · $rate$stuck';
}

// ---------------------------------------------------------------------------------------------------------------------
// The headband's link and contact over the day (DECISIONS 715, 718): the contact readings (metrics `contact` lines:
// the night's start, a session's link, the Signal tab, the headband watcher's checks) and the recorder's drops and
// reconnects in the app log.

typedef ContactBlock = ({int fromHour, Map<String, double> medianKohm, int readings});

double _median(List<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// The contact readings by blocks of [hours] of the day (local time): each channel's median in kΩ and how many
/// readings. Readings without a value (off the head) are left out of the medians.
List<ContactBlock> contactByBlock(List<Map<String, Object?>> lines, {int hours = 3}) {
  final by = <int, Map<String, List<double>>>{};
  final n = <int, int>{};
  for (final l in lines) {
    if (l['kind'] != 'contact' || l['ohms'] is! Map) continue;
    final t = DateTime.tryParse('${l['t']}')?.toLocal();
    if (t == null) continue;
    final block = t.hour ~/ hours * hours;
    n[block] = (n[block] ?? 0) + 1;
    for (final e in (l['ohms']! as Map).entries) {
      final v = e.value;
      if (v is num && v.isFinite && v > 0) ((by[block] ??= {})['${e.key}'] ??= []).add(v / 1000);
    }
  }
  return [
    for (final b in (n.keys.toList()..sort()))
      (
        fromHour: b,
        medianKohm: {for (final e in (by[b] ?? const <String, List<double>>{}).entries) e.key: _median(e.value)},
        readings: n[b]!,
      ),
  ];
}

typedef LinkSummary = ({int drops, Map<String, int> causes, Duration? medianBack, int? medianRssi, int connects});

/// The recorder's `headband link dropped: <why>` and `headband back after a drop` lines (with `reconnect_ms`), and the
/// signal strength of each `connected` line, from app log lines (`sub`, `msg`, `data`).
LinkSummary linkSummary(Iterable<({String sub, String msg, Map<String, Object?>? data})> lines) {
  var drops = 0, connects = 0;
  final causes = <String, int>{};
  final back = <double>[], rssi = <double>[];
  for (final l in lines) {
    if (l.sub != 'recorder') continue;
    if (l.msg.startsWith('headband link dropped: ')) {
      drops++;
      final why = l.msg.substring('headband link dropped: '.length);
      causes[why] = (causes[why] ?? 0) + 1;
    } else if (l.msg.startsWith('headband back after a drop') && l.data?['reconnect_ms'] is num) {
      back.add((l.data!['reconnect_ms']! as num).toDouble());
    } else if (l.msg.startsWith('connected ')) {
      connects++;
      if (l.data?['rssi'] is num) rssi.add((l.data!['rssi']! as num).toDouble());
    }
  }
  return (
    drops: drops,
    causes: causes,
    medianBack: back.isEmpty ? null : Duration(milliseconds: _median(back).round()),
    medianRssi: rssi.isEmpty ? null : _median(rssi).round(),
    connects: connects,
  );
}
