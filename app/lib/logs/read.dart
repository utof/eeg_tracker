// Reading the records back for the pages (DECISIONS 712, 714, 716). Plain Dart, run off the screen's thread
// (`Isolate.run`): a week of logs is a few MB.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'battery_report.dart';
import 'files.dart';
import 'usage_report.dart';

/// One line of the app log.
class LogLine {
  const LogLine({
    required this.t,
    required this.level,
    required this.sub,
    required this.msg,
    required this.engine,
    this.data,
    this.error,
    this.stack,
    this.screen,
  });

  final DateTime t;

  /// `fine`, `info`, `warn` or `error`.
  final String level;
  final String sub, msg, engine;
  final Map<String, Object?>? data;
  final String? error, stack, screen;

  static LogLine? fromJson(Map<String, Object?> j, String engine) {
    final t = DateTime.tryParse('${j['t']}');
    if (t == null || j['msg'] is! String) return null;
    final data = j['data'];
    return LogLine(
      t: t,
      level: j['level'] is String ? j['level']! as String : 'info',
      sub: j['sub'] is String ? j['sub']! as String : 'app',
      msg: j['msg']! as String,
      engine: engine,
      data: data is Map<String, Object?> ? data : null,
      error: j['error'] is String ? j['error']! as String : null,
      stack: j['stack'] is String ? j['stack']! as String : null,
      screen: j['screen'] is String ? j['screen']! as String : null,
    );
  }

  /// One line of text for Copy and Share: `14:31:02.123 warn recorder [screen] message · error`.
  String toText() {
    final time = logTime(t);
    final head = '${time.substring(0, 10)} ${time.substring(11, 23)} $level $sub [$engine] $msg';
    final more = [
      if (data != null && data!.isNotEmpty) jsonEncode(data),
      ?error,
      if (stack != null) '\n$stack',
    ];
    return more.isEmpty ? head : '$head · ${more.join(' · ')}';
  }
}

const List<String> logLevels = ['fine', 'info', 'warn', 'error'];

/// The app log of the last [days] days, newest first, at most [max] lines.
List<LogLine> readAppLog(Directory logsDir, {required DateTime now, int days = 7, int max = 5000}) {
  final cutoff = logDay(now.subtract(Duration(days: days - 1)));
  final out = <LogLine>[];
  for (final f in logFiles(logsDir, kind: LogKind.app)) {
    final n = parseLogFileName(f.uri.pathSegments.last)!;
    if (n.day.compareTo(cutoff) < 0) continue;
    for (final j in readJsonl(f)) {
      final l = LogLine.fromJson(j, n.engine);
      if (l != null) out.add(l);
    }
  }
  out.sort((a, b) => b.t.compareTo(a.t));
  return out.length <= max ? out : out.sublist(0, max);
}

/// The lines at [minLevel] or above, of [subs] (all when empty), with [query] in their words (any case).
List<LogLine> filterLog(List<LogLine> lines, {String minLevel = 'info', Set<String> subs = const {}, String query = ''}) {
  final min = logLevels.indexOf(minLevel);
  final q = query.trim().toLowerCase();
  return [
    for (final l in lines)
      if (logLevels.indexOf(l.level) >= min &&
          (subs.isEmpty || subs.contains(l.sub)) &&
          (q.isEmpty || l.msg.toLowerCase().contains(q) || (l.error?.toLowerCase().contains(q) ?? false)))
        l,
  ];
}

/// The subsystems in [lines] with their line counts, most first.
List<(String, int)> logSubsystems(List<LogLine> lines) {
  final n = <String, int>{};
  for (final l in lines) {
    n[l.sub] = (n[l.sub] ?? 0) + 1;
  }
  return (n.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => (e.key, e.value)).toList();
}

/// Every line of [kind] from the last [days] days, each with its engine as `g`.
List<Map<String, Object?>> readKind(Directory logsDir, LogKind kind, {required DateTime now, required int days}) {
  final cutoff = logDay(now.subtract(Duration(days: days - 1)));
  final out = <Map<String, Object?>>[];
  for (final f in logFiles(logsDir, kind: kind)) {
    final n = parseLogFileName(f.uri.pathSegments.last)!;
    if (n.day.compareTo(cutoff) < 0) continue;
    for (final j in readJsonl(f)) {
      out.add({...j, 'g': n.engine});
    }
  }
  return out;
}

/// The Usage page's summary over the last [days] days (with today), from the app's [filesDir].
UsageSummary loadUsage(String filesDir, {required DateTime now, required int days}) {
  final logs = Directory('$filesDir/logs');
  final since = DateTime(now.year, now.month, now.day).subtract(Duration(days: days - 1));
  return usageSummary(
    readKind(logs, LogKind.usage, now: now, days: days),
    readKind(logs, LogKind.metrics, now: now, days: 8),
    since: since,
    now: now,
    auto: readJsonl(File('$filesDir/auto-start/log.jsonl')),
  );
}

/// What the Battery page shows.
typedef BatteryInputs = ({
  BatteryReport report,
  List<HeadbandRun> headband,
  List<ContactBlock> contact,
  LinkSummary link,
});

/// The power samples of the last [days] days, the night logs' phone battery lines of the same days, the headband's
/// battery per recording (newest first), its contact over the day and its link's drops, from the app's [filesDir].
BatteryInputs loadBattery(String filesDir, {required DateTime now, int days = 14}) {
  final logs = Directory('$filesDir/logs');
  final points = <PowerPoint>[];
  final contact = <Map<String, Object?>>[];
  for (final j in readKind(logs, LogKind.metrics, now: now, days: days)) {
    if (j['kind'] == 'contact') contact.add(j);
    final p = PowerPoint.fromLine(j, '${j['g']}');
    if (p != null) points.add(p);
  }
  final link = linkSummary([
    for (final l in readAppLog(logs, now: now, days: days, max: 1 << 30))
      if (l.sub == 'recorder') (sub: l.sub, msg: l.msg, data: l.data),
  ]);
  final runs = <HeadbandRun>[];
  final rec = Directory('$filesDir/recordings');
  final from = now.subtract(Duration(days: days));
  if (rec.existsSync()) {
    for (final f in rec.listSync()) {
      if (f is! File || !f.path.endsWith('.log')) continue;
      try {
        if (f.lastModifiedSync().isBefore(from)) continue;
        final lines = f.readAsLinesSync();
        for (final l in lines) {
          final p = nightLogPoint(l);
          if (p != null) points.add(p);
        }
        final run = headbandRun(headbandReadings(lines));
        if (run != null) runs.add(run);
      } catch (_) {}
    }
  }
  runs.sort((a, b) => b.start.compareTo(a.start));
  return (report: batteryReport(points), headband: runs, contact: contactByBlock(contact), link: link);
}

// Off the screen's thread. Top-level, so the isolate's closure holds only its arguments (a closure made inside a
// page's State would try to send the whole page along).

typedef AppLogRead = ({List<LogLine> lines, Map<LogKind, ({int files, int bytes})> sizes});

Future<AppLogRead> appLogInBackground(Directory logsDir, DateTime now) =>
    Isolate.run(() => (lines: readAppLog(logsDir, now: now, max: 20000), sizes: logSizes(logsDir)), debugName: 'read-app-log');

Future<UsageSummary> usageInBackground(String filesDir, DateTime now, int days) =>
    Isolate.run(() => loadUsage(filesDir, now: now, days: days), debugName: 'read-usage');

Future<BatteryInputs> batteryInBackground(String filesDir, DateTime now) =>
    Isolate.run(() => loadBattery(filesDir, now: now), debugName: 'read-battery');
