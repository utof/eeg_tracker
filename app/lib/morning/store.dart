// Morning check-ins on the phone: `files/mornings/` next to `files/recordings/`, inside the app's private folder
// (other apps cannot read it, no backup takes it; DECISIONS rows 53, 57 and 125). Per check-in:
//   <start>.morning.json        the result, in the laptop's format plus the phone's additions (docs/data-format.md)
//   <stamp>.f32 .idx .log       the raw signal of the whole visit, the recorder's format (chunk_writer.dart)
//   <stamp>.markers.jsonl       the laptop page's markers, so scripts/morning_check.py can analyse an exported copy
// <start> is the start of the eyes-closed phase (the laptop's name for the result), <stamp> when the signal began.
// Not in files/recordings: a check-in recorded there would join the night before it.
import 'dart:convert';
import 'dart:io';

import '../cache/file_summaries.dart' show firstParsed, newestFirst;
import '../recorder/chunk_writer.dart' show fileStem;
import '../recorder/nights.dart' show stemTime;
import '../trends/days.dart';
import '../wearer/check.dart' show wearerAnswerIn;
import 'result.dart';

/// The mornings folder for the app's recordings folder.
Directory morningsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/mornings');

/// One saved check-in, read back from its JSON (untrusted: every field checked on use).
class MorningRecord {
  MorningRecord._(this.json, this.start);
  final Map<String, Object?> json;

  /// Start of the eyes-closed phase.
  final DateTime start;

  /// Null unless [j] is a check-in result this app can read (version and start present).
  static MorningRecord? fromJson(Object? j) {
    if (j is! Map || j['version'] != morningVersion) return null;
    final start = DateTime.tryParse('${j['start']}');
    if (start == null || j['back'] is! Map) return null;
    return MorningRecord._(j.cast<String, Object?>(), start.toLocal());
  }

  String get day => dayKey(start);

  /// The file stem of the result (`2026-11-20-091205`): the check-in's id in "Was this you?".
  String get id => fileStem(start);

  /// The owner's answer to "Was this you?" (`me` or `someone else`), or null (wearer/wearer.dart).
  String? get wearerAnswer => wearerAnswerIn(json);

  double? _num(String path) => valueAt(json, path)?.toDouble();
  int? _int(String path, int lo, int hi) {
    final v = valueAt(json, path);
    return v is int && v >= lo && v <= hi ? v : null;
  }

  int? get kss => _int('ratings.kss', 1, 9);
  int? get mood => _int('ratings.mood', 1, 5);
  int? get tension => _int('ratings.tension', 1, 5);

  /// "How did you sleep?", 1 very badly to 5 very well: an optional tap, so null when it was not given.
  int? get slept => _int('ratings.sleep', 1, 5);
  double? get alphaEc => _num('back.alpha_ec_uv2');
  double? get ecRise => _num('back.ec_rise');
  double? get iafHz => _num('back.iaf_hz');
  double? get slope => _num('back.aperiodic_slope_ec');
  double? get cleanShare => _num('back.clean_share');

  /// The 1-minute reaction test's median (ms), when it was done.
  double? get reactionMs => _num('reaction.median_ms');
  int? get caffeineCups => _int('habits.caffeine_cups', 0, 5);
  int? get alcoholDrinks => _int('habits.alcohol_drinks', 0, 5);
  bool? get caffeineLate => (json['habits'] as Map?)?['caffeine_late'] is bool
      ? (json['habits']! as Map)['caffeine_late'] as bool
      : null;
  bool? get caffeineToday => (json['habits'] as Map?)?['caffeine_today'] is bool
      ? (json['habits']! as Map)['caffeine_today'] as bool
      : null;
}

class MorningStore {
  MorningStore(this.dir);
  final Directory dir;

  /// The result file of a check-in whose eyes-closed phase started at [start].
  File resultFile(DateTime start) => File('${dir.path}/${fileStem(start)}.morning.json');

  /// Writes the result (to a temporary file, then renamed: a listed result is always whole).
  void save(Map<String, Object?> result, DateTime start) {
    dir.createSync(recursive: true);
    final f = resultFile(start);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(result)}\n', flush: true);
    tmp.renameSync(f.path);
  }

  /// Every readable check-in, newest first. Damaged or foreign files are skipped.
  List<MorningRecord> list() {
    if (!dir.existsSync()) return const [];
    final out = <MorningRecord>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.morning.json')) continue;
      try {
        final r = MorningRecord.fromJson(jsonDecode(f.readAsStringSync()));
        if (r != null) out.add(r);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return out..sort((a, b) => b.start.compareTo(a.start));
  }

  /// The check-in whose id (its file stem) is [id], or null when it is not there or cannot be read.
  MorningRecord? byId(String id) {
    try {
      return MorningRecord.fromJson(jsonDecode(File('${dir.path}/$id.morning.json').readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The first readable check-in of [day] (04:00 to 04:00, trends/days.dart), found by the file names (their start):
  /// only that day's files are opened, and none again while they are unchanged (DECISIONS 620-629).
  MorningRecord? firstOfDay(String day) {
    final files = [
      for (final f in newestFirst(dir, '.morning.json'))
        if (stemTime(f.uri.pathSegments.last) case final t? when dayKey(t) == day) f,
    ].reversed;
    return firstParsed(files, (j) {
      final r = MorningRecord.fromJson(j);
      return r != null && r.day == day ? r : null;
    });
  }

  /// The results before [start], oldest first, at most the last [historyN] (the laptop's comparison history).
  List<Map<String, Object?>> historyBefore(DateTime start) {
    final old = list().where((r) => r.start.isBefore(start)).toList().reversed.toList();
    return [for (final r in old.length > historyN ? old.sublist(old.length - historyN) : old) r.json];
  }
}
