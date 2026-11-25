// Work sessions on the phone (DECISIONS 446): `files/work-sessions/<stem>.work.json`, one per session, next to
// `files/recordings/` in the app's private folder; Export data and Share on Wi-Fi take the whole folder like any other.
// The file is written whole (a temporary file, then a rename; compact JSON) every few minutes during the session and
// at Stop, so a crash loses at most the last minutes. The per-30-s numbers are enough to re-score a session with other
// weights or lines (docs/data-format.md, "Work sessions"); the raw EEG is kept apart, as a recording in
// `files/recordings/` whose header says `session: work` (DECISIONS 683; the file's `raw` names it).
// Reading (DECISIONS 523): a Start opens only the files named for the last 28 hours; the page's list keeps each file's
// summary for as long as the file is unchanged, and decodes new or changed files away from the screen's thread.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../recorder/chunk_writer.dart' show fileStem;
import '../spans/span.dart' show removedSpanIds;
import '../wearer/check.dart' show wearerAnswerIn;
import 'breaks.dart';

const int workFormatVersion = 1;
const String workSuffix = '.work.json';

Directory workDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/work-sessions');

/// What the list of earlier sessions shows.
class WorkSummary {
  const WorkSummary({
    required this.start,
    required this.end,
    required this.wornMin,
    required this.hints,
    required this.breaks,
    required this.drowsyMin,
    required this.alertMin,
    required this.hintList,
    this.wearerAnswer,
    this.stretchMin,
    this.span,
  });

  /// The mark of the recording it ran on (its file's `span`, spans/activities.dart); null: a session with a file set
  /// of its own. Read only: [WorkStore] leaves a session out of its lists while that mark is taken away.
  final String? span;

  final DateTime start, end;
  final double wornMin;
  final int hints, breaks;

  /// Minutes the level read getting drowsy or drowsy, and alert.
  final double drowsyMin, alertMin;
  final List<WorkHint> hintList;

  /// What the owner said about who wore it (`me`, `someone else`), or null (DECISIONS 490).
  final String? wearerAnswer;

  /// The worn minutes since the last break at the file's end (null: a file from before `stretch_min`).
  final double? stretchMin;

  /// The session's file stem (`yyyy-MM-dd-HHmmss` of its start): what "Was this you?" answers are filed under.
  String get id => fileStem(start);

  double get minutes => end.difference(start).inMilliseconds / 60000;

  static WorkSummary? fromJson(Object? j) {
    if (j is! Map || j['kind'] != 'work_session') return null;
    final start = DateTime.tryParse('${j['start']}'), end = DateTime.tryParse('${j['end']}');
    if (start == null || end == null) return null;
    final m = j['minutes'] is Map ? j['minutes'] as Map : const <String, Object?>{};
    double n(Object? v) => v is num ? v.toDouble() : 0;
    final hints = <WorkHint>[];
    for (final h in (j['hints'] is List ? j['hints'] as List : const [])) {
      if (h is! Map) continue;
      try {
        hints.add(WorkHint.fromJson(h.cast<String, Object?>()));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return WorkSummary(
      start: start,
      end: end,
      wornMin: n(j['worn_min']),
      hints: hints.length,
      breaks: j['breaks'] is List ? (j['breaks'] as List).length : 0,
      drowsyMin: n(m['getting_drowsy']) + n(m['drowsy']),
      alertMin: n(m['alert']),
      hintList: hints,
      wearerAnswer: wearerAnswerIn(Map<String, Object?>.from(j)),
      stretchMin: j['stretch_min'] is num ? (j['stretch_min'] as num).toDouble() : null,
      span: j['span'] is String ? j['span'] as String : null,
    );
  }
}

/// A file's summary, decoded once for as long as the file keeps its time and length.
typedef _Cached = ({DateTime modified, int length, WorkSummary? summary});

/// The summaries of the files at [paths] (null for a damaged or foreign one), in order.
List<WorkSummary?> _decode(List<String> paths) => [for (final p in paths) _decodeOne(p)];

WorkSummary? _decodeOne(String path) {
  try {
    return WorkSummary.fromJson(jsonDecode(File(path).readAsStringSync()));
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

/// The start of a session from its file name (`yyyy-MM-dd-HHmmss.work.json`), or null for another name.
DateTime? _startOfName(String path) {
  final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})' '${RegExp.escape(workSuffix)}' r'$').firstMatch(path);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

class WorkStore {
  WorkStore(this.dir);
  final Directory dir;

  /// Writes (or replaces) the session's file whole.
  void save(Map<String, Object?> session) {
    final start = DateTime.parse(session['start']! as String);
    dir.createSync(recursive: true);
    final path = '${dir.path}/${fileStem(start)}$workSuffix';
    final tmp = File('$path.tmp')..writeAsStringSync(jsonEncode(session), flush: true);
    tmp.renameSync(path);
  }

  /// The decoded file of the session [id] (its file stem), or null when it is not there or cannot be read.
  Map<String, Object?>? read(String id) {
    try {
      final j = jsonDecode(File('${dir.path}/$id$workSuffix').readAsStringSync());
      return j is Map && j['kind'] == 'work_session' ? Map<String, Object?>.from(j) : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Each file's summary while the file is unchanged, for this app process (all stores share it).
  static final Map<String, _Cached> _cache = {};

  /// The session files with their time and length (only those [keep] wants, by path).
  List<(String, DateTime, int)> _files([bool Function(String path)? keep]) {
    if (!dir.existsSync()) return const [];
    final out = <(String, DateTime, int)>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith(workSuffix) || !(keep?.call(f.path) ?? true)) continue;
      try {
        final st = f.statSync();
        out.add((f.path, st.modified, st.size));
      } on FileSystemException {
        continue;
      }
    }
    return out;
  }

  static bool _fresh((String, DateTime, int) f) {
    final c = _cache[f.$1];
    return c != null && c.modified == f.$2 && c.length == f.$3;
  }

  /// The summaries of [files], from the cache where the file is unchanged; the rest from [decode].
  static List<WorkSummary> _summaries(List<(String, DateTime, int)> files, List<WorkSummary?> Function(List<String>) decode) {
    final stale = [for (final f in files) if (!_fresh(f)) f];
    final read = stale.isEmpty ? const <WorkSummary?>[] : decode([for (final f in stale) f.$1]);
    for (var i = 0; i < stale.length; i++) {
      _cache[stale[i].$1] = (modified: stale[i].$2, length: stale[i].$3, summary: read[i]);
    }
    // a session whose mark was taken away in the Archive counts nowhere (DECISIONS 1042); its file stays
    final gone = files.isEmpty ? const <String>{} : removedSpanIds(_spansDirOf(files.first.$1));
    return [
      for (final f in files)
        if (_cache[f.$1]?.summary case final s? when !gone.contains(s.span)) s,
    ]..sort((a, b) => b.start.compareTo(a.start));
  }

  /// `files/spans/` for a session file in `files/work-sessions/`.
  static Directory _spansDirOf(String sessionPath) => Directory('${File(sessionPath).parent.parent.path}/spans');

  /// Every readable session, newest first; damaged or foreign files are skipped.
  List<WorkSummary> list() => _summaries(_files(), _decode);

  /// [list], with new or changed files decoded on another thread (the page's list: the screen does not freeze once
  /// there are months of sessions).
  Future<List<WorkSummary>> listAsync() async {
    final files = _files();
    final stale = [for (final f in files) if (!_fresh(f)) f.$1];
    final read = stale.isEmpty ? const <WorkSummary?>[] : await Isolate.run(() => _decode(stale));
    final byPath = {for (var i = 0; i < stale.length; i++) stale[i]: read[i]};
    return _summaries(files, (paths) => [for (final p in paths) byPath.containsKey(p) ? byPath[p] : _decodeOne(p)]);
  }

  /// What a session starting at [now] takes over from the earlier ones of its day (04:00 to 04:00; only the files
  /// named for the last 28 hours are opened): their hints, oldest first, where a hint in the 30 minutes before a
  /// session's end counts as followed by a break (`taken`, in memory only) when 5 minutes or more passed until the next
  /// session or [now] (a Stop for lunch is a break, as 5 minutes away is on the laptop); and the stretch of a session
  /// that ended under 5 minutes before [now] (a restart is not a break: the hour goes on).
  ({List<WorkHint> hints, double stretchMin}) priorOfDay(DateTime now) {
    final from = now.subtract(const Duration(hours: 28));
    bool recent(String path) {
      final start = _startOfName(path);
      return start == null || start.isAfter(from);
    }

    final sessions = _summaries(_files(recent), _decode).where((s) => !s.start.isAfter(now)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final hints = <WorkHint>[];
    var stretch = 0.0;
    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      final next = i + 1 < sessions.length ? sessions[i + 1].start : now;
      final gapMin = next.difference(s.end).inMilliseconds / 60000;
      for (final h0 in s.hintList) {
        if (workDay(h0.at) != workDay(now)) continue;
        final h = WorkHint.fromJson(h0.toJson()); // a copy: the cached summary is not changed
        final beforeEnd = s.end.difference(h.at).inMilliseconds / 60000;
        if (gapMin >= BreakRule.breakMin && beforeEnd >= 0 && beforeEnd <= BreakRule.takenWindowMin) h.taken = true;
        hints.add(h);
      }
      final since = now.difference(s.end).inMilliseconds / 60000;
      if (since >= 0 && since < BreakRule.breakMin) stretch = s.stretchMin ?? 0;
    }
    return (hints: hints..sort((a, b) => a.at.compareTo(b.at)), stretchMin: stretch);
  }

  /// The hints of earlier sessions on [now]'s day (04:00 to 04:00), oldest first (see [priorOfDay]).
  List<WorkHint> hintsOfDay(DateTime now) => priorOfDay(now).hints;
}
