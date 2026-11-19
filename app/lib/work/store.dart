// Work sessions on the phone (DECISIONS 446): `files/work-sessions/<stem>.work.json`, one per session, next to
// `files/recordings/` in the app's private folder; Export data and Share on Wi-Fi take the whole folder like any other.
// The file is written whole (a temporary file, then a rename) every few minutes during the session and at Stop, so a
// crash loses at most the last minutes. No raw EEG: the per-30-s numbers are enough to re-score a session with
// other weights or lines (docs/data-format.md, "Work sessions").
import 'dart:convert';
import 'dart:io';

import '../recorder/chunk_writer.dart' show fileStem;
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
  });

  final DateTime start, end;
  final double wornMin;
  final int hints, breaks;

  /// Minutes the level read getting drowsy or drowsy, and alert.
  final double drowsyMin, alertMin;
  final List<WorkHint> hintList;

  /// What the owner said about who wore it (`me`, `someone else`), or null (DECISIONS 490).
  final String? wearerAnswer;

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
    );
  }
}

class WorkStore {
  WorkStore(this.dir);
  final Directory dir;

  /// Writes (or replaces) the session's file whole.
  void save(Map<String, Object?> session) {
    final start = DateTime.parse(session['start']! as String);
    dir.createSync(recursive: true);
    final path = '${dir.path}/${fileStem(start)}$workSuffix';
    final tmp = File('$path.tmp')..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(session), flush: true);
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

  /// Every readable session, newest first; damaged or foreign files are skipped.
  List<WorkSummary> list() {
    if (!dir.existsSync()) return const [];
    final out = <WorkSummary>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith(workSuffix)) continue;
      try {
        final s = WorkSummary.fromJson(jsonDecode(f.readAsStringSync()));
        if (s != null) out.add(s);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }

  /// The hints of earlier sessions on [now]'s day (04:00 to 04:00), oldest first.
  List<WorkHint> hintsOfDay(DateTime now) => [
    for (final s in list())
      for (final h in s.hintList)
        if (workDay(h.at) == workDay(now)) h,
  ]..sort((a, b) => a.at.compareTo(b.at));
}
