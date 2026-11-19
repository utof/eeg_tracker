// The study reminders on disk, in the app's private folder next to the recordings and the sharp-hours log (no
// backup takes it, other apps cannot read it; DECISIONS rows 53, 57, 401):
//   files/study-review/settings.json   the switch and the two times when set by hand (written whole)
//   files/study-review/log.jsonl       one line per one-tap answer: studied tonight (yes / no), recalled (well / some / a little)
//   files/study-review/prompts.jsonl   written by the Android side (SharpPrompts.kt): each reminder shown, skipped,
//                                      late, postponed or swiped away (the sharp-hours log's own format)
//   files/study-review/events.jsonl    each change of the switch or a time
// Times are local with their UTC offset (`2026-11-20T21:40:12+03:00`). Export data takes the folder with everything
// else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';

import '../sharp/store.dart' show PromptEvent;
import '../sleep/report.dart' show isoLocal;
import '../trends/days.dart';
import 'schedule.dart';

/// The study folder for the app's recordings folder.
Directory studyDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/study-review');

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

extension StudyAnswerJson on StudyAnswer {
  Map<String, Object?> toJson() => {
    'version': 1,
    'at': isoLocal(at),
    'kind': isEvening ? 'evening' : 'morning',
    if (isEvening) 'studied': studied else 'recall': recall!.wire,
    'prompt': prompt == null ? null : isoLocal(prompt!),
    'shown': shown == null ? null : isoLocal(shown!),
  };

  /// Null for anything that is not a line this version wrote.
  static StudyAnswer? fromJson(Object? j) {
    if (j is! Map || j['version'] != 1) return null;
    final at = _time(j['at']);
    if (at == null) return null;
    if ((j['prompt'] != null && _time(j['prompt']) == null) || (j['shown'] != null && _time(j['shown']) == null)) {
      return null;
    }
    final prompt = _time(j['prompt']), shown = _time(j['shown']);
    switch (j['kind']) {
      case 'evening':
        final studied = j['studied'];
        return studied is bool ? StudyAnswer.evening(at: at, studied: studied, prompt: prompt, shown: shown) : null;
      case 'morning':
        final recall = Recall.fromWire(j['recall']);
        return recall == null ? null : StudyAnswer.morning(at: at, recall: recall, prompt: prompt, shown: shown);
    }
    return null;
  }
}

class StudyStore {
  StudyStore(this.dir);
  final Directory dir;

  File _f(String name) => File('${dir.path}/$name');

  List<T> _lines<T>(String name, T? Function(Object?) parse) {
    final f = _f(name);
    if (!f.existsSync()) return const [];
    final out = <T>[];
    for (final line in const LineSplitter().convert(f.readAsStringSync())) {
      if (line.trim().isEmpty) continue;
      try {
        final v = parse(jsonDecode(line));
        if (v != null) out.add(v);
      } on FormatException {
        // a line cut off by a crash, or not ours: skipped, never guessed at
      }
    }
    return out;
  }

  void _append(String name, Map<String, Object?> json) {
    dir.createSync(recursive: true);
    _f(name).writeAsStringSync('${jsonEncode(json)}\n', mode: FileMode.append, flush: true);
  }

  StudySettings? settings() {
    try {
      return StudySettings.fromJson(jsonDecode(_f('settings.json').readAsStringSync()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void saveSettings(StudySettings s) {
    dir.createSync(recursive: true);
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_f('settings.json').path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    tmp.renameSync(_f('settings.json').path);
  }

  void addAnswer(StudyAnswer a) => _append('log.jsonl', a.toJson());
  List<StudyAnswer> answers() => _lines('log.jsonl', StudyAnswerJson.fromJson);

  List<PromptEvent> promptEvents() => _lines('prompts.jsonl', PromptEvent.fromJson);

  void logEvent(DateTime at, String event, [Map<String, Object?> more = const {}]) =>
      _append('events.jsonl', {'at': isoLocal(at), 'event': event, ...more});

  /// Removes every study file (the owner's "delete my data").
  void deleteAll() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// The day's number for Trends and the self-experiments, by the 04:00 day: `recall`, the mean of the day's
/// morning answers (1 a little, 2 some, 3 well). The evening's yes or no is not a number of its own.
Map<String, Map<String, double>> studyDayNumbers(List<StudyAnswer> answers) {
  final byDay = <String, List<int>>{};
  for (final a in answers) {
    if (!a.isEvening) byDay.putIfAbsent(dayKey(a.at), () => []).add(a.recall!.value);
  }
  return {
    'recall': {for (final e in byDay.entries) e.key: e.value.reduce((a, b) => a + b) / e.value.length},
  };
}
