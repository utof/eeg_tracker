// "Was this you?" on disk (DECISIONS rows 370-379), in the app's private folder next to the recordings:
//   files/wearer/settings.json   the switch: {"on": true|false, "changed": ...}; missing or damaged = on
//   files/wearer/events.jsonl    one line per change: switched on / off, an answer (kind, id, answer; null = taken back)
//   files/wearer/log.jsonl       one line per recording the first time it is judged while the check is on: what it
//                                said then; written once, never rewritten
// The answers themselves live in the recordings' own result files (`wearer` in the night's report or the check-in's
// result), so the trends can leave them out; the profile is worked out again from those files every time.
// Export data takes the folder with everything else (its rule is "everything except").
import 'dart:convert';
import 'dart:io';

/// The folder for the app's recordings folder.
Directory wearerDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/wearer');

class WearerStore {
  WearerStore(this.dir);
  final Directory dir;

  File get _settings => File('${dir.path}/settings.json');
  File get _events => File('${dir.path}/events.jsonl');
  File get log => File('${dir.path}/log.jsonl');

  /// On unless switched off (the assistant's proposal: shown, and the owner can switch it off).
  bool get on {
    try {
      final j = jsonDecode(_settings.readAsStringSync());
      return j is Map && j['on'] is bool ? j['on'] as bool : true;
    } on FileSystemException {
      return true;
    } on FormatException {
      return true;
    }
  }

  void setOn(bool on, DateTime now) {
    dir.createSync(recursive: true);
    // a temporary file, then a rename: an export never copies a half-written file (it skips *.tmp)
    final tmp = File('${_settings.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({'on': on, 'changed': now.toIso8601String()}), flush: true);
    tmp.renameSync(_settings.path);
    event(now, on ? 'switched on' : 'switched off');
  }

  void event(DateTime now, String what, [Map<String, Object?> more = const {}]) {
    dir.createSync(recursive: true);
    _events.writeAsStringSync(
      '${jsonEncode({'at': now.toIso8601String(), 'event': what, ...more})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// `kind:id` of every recording already in the log (a damaged line is skipped).
  Set<String> logged() {
    if (!log.existsSync()) return {};
    final out = <String>{};
    for (final line in log.readAsLinesSync()) {
      try {
        final j = jsonDecode(line);
        if (j is Map && j['kind'] is String && j['id'] is String) out.add('${j['kind']}:${j['id']}');
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  void append(List<Map<String, Object?>> lines) {
    if (lines.isEmpty) return;
    dir.createSync(recursive: true);
    log.writeAsStringSync('${lines.map(jsonEncode).join('\n')}\n', mode: FileMode.append, flush: true);
  }
}
