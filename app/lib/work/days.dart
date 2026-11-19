// The work sessions' day numbers for Trends and the self-experiments (DECISIONS rows 480-489), worked out from the
// session files (files/work-sessions/, docs/data-format.md) the way Sharp hours' are (sharp/hours.dart): by the 04:00
// day (trends/days.dart), by measure id.
//
// Work time is the half minutes whose level the app could read (alert, getting drowsy or drowsy): not the noisy
// ones ("Not sure", the baseline's first minutes), not the half minutes read as closed eyes, and not time inside a
// break (a tapped break keeps streaming, so those half minutes are in the file). A day with under
// [workDayMinMinutes] of it has no number at all: the share of such a short stretch would be a few readings, and the
// first hint of a work day comes after 60 worn minutes. Sessions the owner marked as worn by someone else (`wearer`,
// as nights and check-ins are marked, DECISIONS 377) are left out. Nothing here changes a file.
// As in the session (DECISIONS 521-522): a hint in the 30 minutes before a session's Stop was followed by a break when
// 5 minutes or more passed until the next session (or none came); the first drowsy stretch starts its 12 half minutes
// again after each break.
import 'dart:convert';
import 'dart:io';

import '../trends/days.dart' show dayKey;
import '../wearer/check.dart' show answerSomeoneElse;
import 'breaks.dart' show BreakRule;
import 'store.dart' show workDirFor, workSuffix;

/// The least usable work time of a day (minutes) for it to have any work number (DECISIONS 481).
const int workDayMinMinutes = 30;

const Set<String> _read = {'alert', 'getting_drowsy', 'drowsy'};
const Set<String> _up = {'getting_drowsy', 'drowsy'};

/// The measure ids of the numbers (trends/trends.dart).
const List<String> workMeasureIds = [
  'worktime',
  'workdrowsy',
  'workfirst',
  'workhints',
  'workfollowed',
  'workbreaks',
  'worksharp',
];

class _Day {
  int usable = 0, drowsy = 0, hints = 0, followed = 0, breaks = 0;
  double? firstMin;
  final List<int> taps = [];
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v) : null;

/// A half minute's own time: its `at` or its `t` when that is a time, else (the first version of the file wrote
/// the theta number under `t`) the session's start plus its seconds of signal `s`.
DateTime? _epochTime(Map<Object?, Object?> e, DateTime start) {
  final t = _time(e['at']) ?? _time(e['t']);
  if (t != null) return t;
  final s = e['s'];
  return s is num && s.isFinite ? start.add(Duration(seconds: s.round())) : null;
}

/// The day numbers of the decoded session files [sessions] (anything that is not a work session is skipped), by
/// measure id then day.
Map<String, Map<String, double>> workDayNumbers(Iterable<Object?> sessions) {
  final parsed = <(DateTime, Map<Object?, Object?>)>[];
  for (final j in sessions) {
    if (j is! Map || j['kind'] != 'work_session') continue;
    final start = _time(j['start']);
    if (start == null) continue;
    final w = j['wearer'];
    if (w is Map && w['answer'] == answerSomeoneElse) continue;
    parsed.add((start, j));
  }
  parsed.sort((a, b) => a.$1.compareTo(b.$1));
  final days = <String, _Day>{};
  _Day day(DateTime t) => days.putIfAbsent(dayKey(t), _Day.new);
  for (final (i, (start, j)) in parsed.indexed) {
    final end = _time(j['end']) ?? start;
    // the time after the Stop until the next session (none: the day's end) is a break when 5 minutes or more
    final next = i + 1 < parsed.length ? parsed[i + 1].$1 : null;
    final gapAfter = next == null ? j['ended'] == 'stopped' : next.difference(end).inMilliseconds >= BreakRule.breakMin * 60000;
    final breaks = <(DateTime, DateTime)>[];
    for (final b in j['breaks'] is List ? j['breaks'] as List : const []) {
      final from = b is Map ? _time(b['start']) : null;
      if (from == null) continue;
      final to = _time((b as Map)['end']) ?? end;
      breaks.add((from, to));
      if (to.difference(from).inMilliseconds >= BreakRule.breakMin * 60000) day(from).breaks++;
    }
    bool inBreak(DateTime t) => breaks.any((b) => !t.isBefore(b.$1) && t.isBefore(b.$2));
    bool breakSince(DateTime? a, DateTime t) => a != null && breaks.any((b) => b.$1.isAfter(a) && !b.$1.isAfter(t));
    final recent = <bool>[];
    DateTime? lastT;
    for (final e in j['epochs'] is List ? j['epochs'] as List : const []) {
      if (e is! Map || e['level'] is! String || !_read.contains(e['level']) && e['level'] != 'unknown') continue;
      final t = _epochTime(e, start);
      if (t == null) continue;
      if (inBreak(t) || breakSince(lastT, t)) recent.clear(); // the hint rule counts only half minutes since a break
      lastT = t;
      if (inBreak(t)) continue;
      final d = day(t);
      final level = e['level'] as String;
      if (_read.contains(level) && e['eyes_closed'] != true) {
        d.usable++;
        if (_up.contains(level)) d.drowsy++;
      }
      recent.add(_up.contains(level));
      if (recent.length > BreakRule.recentEpochs) recent.removeAt(0);
      if (d.firstMin == null && recent.where((u) => u).length >= BreakRule.drowsyEpochs) d.firstMin = d.usable / 2;
    }
    for (final h in j['hints'] is List ? j['hints'] as List : const []) {
      final at = h is Map ? _time(h['at']) : null;
      if (at == null) continue;
      final d = day(at);
      d.hints++;
      final beforeEnd = end.difference(at).inMilliseconds / 60000;
      final byStop = gapAfter && beforeEnd >= 0 && beforeEnd <= BreakRule.takenWindowMin;
      if ((h as Map)['taken'] == true || byStop) d.followed++;
    }
    for (final r in j['ratings'] is List ? j['ratings'] as List : const []) {
      final at = r is Map ? _time(r['at']) : null;
      final v = r is Map ? r['value'] : null;
      if (at != null && v is int && v >= 1 && v <= 5) day(at).taps.add(v);
    }
  }
  final out = {for (final id in workMeasureIds) id: <String, double>{}};
  for (final MapEntry(key: k, value: d) in days.entries) {
    if (d.usable < workDayMinMinutes * 2) continue;
    out['worktime']![k] = d.usable / 2;
    out['workdrowsy']![k] = d.drowsy / d.usable * 100;
    if (d.firstMin != null) out['workfirst']![k] = d.firstMin!;
    out['workhints']![k] = d.hints.toDouble();
    out['workfollowed']![k] = d.followed.toDouble();
    out['workbreaks']![k] = d.breaks.toDouble();
    if (d.taps.isNotEmpty) out['worksharp']![k] = d.taps.reduce((a, b) => a + b) / d.taps.length;
  }
  return out;
}

/// The numbers from the session files beside [recordingsDir]; a missing folder, a damaged file or a foreign one is
/// simply not there.
Map<String, Map<String, double>> readWorkDayNumbers(String recordingsDir) {
  final dir = workDirFor(recordingsDir);
  final files = <Object?>[];
  if (dir.existsSync()) {
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith(workSuffix)) continue;
      try {
        files.add(jsonDecode(f.readAsStringSync()));
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
  }
  return workDayNumbers(files);
}
