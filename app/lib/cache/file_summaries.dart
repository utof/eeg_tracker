// Read each file once (DECISIONS 620-629). The night screen, Trends, the study reminders and "Was this you?" show a
// little from many small files that rarely change; reading every one of them at every start and return, on the
// screen's thread, is what made the phone sluggish. Three tools, all keyed by a file's size and modified time:
//   newestFirst    the files of a folder newest first BY NAME: the app names its files by their start
//                  (`yyyy-MM-dd-HHmmss`), so the newest one is found without opening any
//   JsonMemo       a file's decoded JSON, kept in memory for this isolate while the file is unchanged
//   SummaryIndex   one small summary per file of a folder, kept in memory and on disk (`files/cache/<name>.json`):
//                  a new process or a background isolate reads the index and only the files new or changed since
//   folderValue    one value worked out from a whole folder, kept on disk with every file's key: worked out again
//                  only when a file is new, changed or gone
// `files/cache/` holds what the app can always make again: never exported or shared (export/store.dart). A damaged
// or foreign cache file is ignored and written again. Two isolates may write the same index: each writes a whole
// valid copy (a temporary file, then a rename) and every use checks the files' keys again, so the worst case is one
// more read. Plain Dart: tested on a plain folder.
import 'dart:convert';
import 'dart:io';

/// What says a file is unchanged: its length and its modified time (microseconds).
typedef FileKey = ({int size, int modifiedUs});

/// [f]'s key, or null when it is not a file (gone, or a folder).
FileKey? fileKey(File f) {
  try {
    final st = f.statSync();
    if (st.type != FileSystemEntityType.file) return null;
    return (size: st.size, modifiedUs: st.modified.microsecondsSinceEpoch);
  } on FileSystemException {
    return null;
  }
}

String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

/// The files in [dir] whose names end with [suffix], newest name first (none when the folder is missing). Only the
/// folder is listed: no file is opened.
List<File> newestFirst(Directory dir, String suffix) {
  try {
    if (!dir.existsSync()) return const [];
    return [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith(suffix) && !_name(f.path).startsWith('.')) f,
    ]..sort((a, b) => _name(b.path).compareTo(_name(a.path)));
  } on FileSystemException {
    return const [];
  }
}

/// Decoded JSON per file, kept for this isolate while the file keeps its key. Callers never change what they get.
abstract final class JsonMemo {
  static final Map<String, ({FileKey key, Object? json})> _kept = {};

  /// [f] decoded; null when it is missing, unreadable or not JSON. Read again only when its key changed.
  static Object? read(File f) {
    final key = fileKey(f);
    if (key == null) {
      _kept.remove(f.path);
      return null;
    }
    final k = _kept[f.path];
    if (k != null && k.key == key) return k.json;
    Object? json;
    try {
      json = jsonDecode(f.readAsStringSync());
    } on FormatException {
      json = null;
    } on FileSystemException {
      json = null;
    }
    _kept[f.path] = (key: key, json: json);
    return json;
  }

  /// [f]'s lines, each decoded (a line that is not JSON gives null; blank lines are left out); empty when [f] is
  /// missing. Kept like [read].
  static List<Object?> lines(File f) {
    final key = fileKey(f);
    final k = '${f.path}\u0000lines';
    if (key == null) {
      _kept.remove(k);
      return const [];
    }
    final kept = _kept[k];
    if (kept != null && kept.key == key) return kept.json! as List<Object?>;
    final out = <Object?>[];
    try {
      for (final l in f.readAsLinesSync()) {
        if (l.trim().isEmpty) continue;
        try {
          out.add(jsonDecode(l));
        } on FormatException {
          out.add(null); // a line cut off by a crash
        }
      }
    } on FileSystemException {
      out.clear();
    }
    _kept[k] = (key: key, json: List<Object?>.unmodifiable(out));
    return _kept[k]!.json! as List<Object?>;
  }

  /// Forgets everything (tests).
  static void clear() => _kept.clear();
}

/// The first of [files] (in their order) that [parse] accepts, each read through [JsonMemo]: the newest readable
/// one when [files] come from [newestFirst].
T? firstParsed<T>(Iterable<File> files, T? Function(Object? json) parse) {
  for (final f in files) {
    final v = parse(JsonMemo.read(f));
    if (v != null) return v;
  }
  return null;
}

typedef _Entry = ({int size, int modifiedUs, Object? summary});

/// One summary per file of a folder, kept in memory for this isolate and on disk in [file]. [version] is the
/// summary's own: kept summaries of another version are dropped.
class SummaryIndex {
  SummaryIndex(this.file, {required this.version});

  /// `files/cache/<name>.json`.
  final File file;
  final int version;

  static final Map<String, ({int version, Map<String, _Entry> entries})> _open = {};

  Map<String, _Entry> _load() {
    final open = _open[file.path];
    if (open != null && open.version == version) return open.entries;
    final entries = <String, _Entry>{};
    try {
      final j = jsonDecode(file.readAsStringSync());
      final files = j is Map && j['version'] == version ? j['files'] : null;
      if (files is Map) {
        for (final e in files.entries) {
          final v = e.value;
          if (e.key is String && v is List && v.length == 3 && v[0] is int && v[1] is int) {
            entries[e.key as String] = (size: v[0] as int, modifiedUs: v[1] as int, summary: v[2]);
          }
        }
      }
    } on FileSystemException {
      // no index yet
    } on FormatException {
      // a damaged index is made again
    }
    _open[file.path] = (version: version, entries: entries);
    return entries;
  }

  void _save(Map<String, _Entry> entries) {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'version': version,
          'files': {for (final e in entries.entries) e.key: [e.value.size, e.value.modifiedUs, e.value.summary]},
        }),
        flush: true,
      );
      tmp.renameSync(file.path);
    } on FileSystemException {
      // the summaries are worked out again next time
    } on JsonUnsupportedObjectError {
      // a summary JSON cannot hold (not finite): kept in memory only
    }
  }

  /// The summary of every file in [dir] whose name ends with [suffix], by file name. [summarize] reads a new or
  /// changed file and returns a JSON value (null: the file has nothing to give); it is never called for a file whose
  /// size and modified time are those kept. Files gone are forgotten; the index is written only when it changed.
  Map<String, Object?> summaries(Directory dir, String suffix, Object? Function(File f) summarize) {
    final entries = _load();
    final out = <String, Object?>{};
    var changed = false;
    final seen = <String>{};
    for (final f in newestFirst(dir, suffix)) {
      final name = _name(f.path);
      final key = fileKey(f);
      if (key == null) continue;
      seen.add(name);
      final kept = entries[name];
      if (kept != null && kept.size == key.size && kept.modifiedUs == key.modifiedUs) {
        out[name] = kept.summary;
        continue;
      }
      Object? s;
      try {
        s = summarize(f);
      } on Object {
        s = null; // a file that cannot be read gives nothing, as before
      }
      entries[name] = (size: key.size, modifiedUs: key.modifiedUs, summary: s);
      out[name] = s;
      changed = true;
    }
    final gone = entries.keys.where((n) => !seen.contains(n)).toList();
    if (gone.isNotEmpty) {
      gone.forEach(entries.remove);
      changed = true;
    }
    if (changed) _save(entries);
    return out;
  }

  /// Forgets what this isolate holds in memory (tests: a new process).
  static void forgetAll() => _open.clear();
}

/// The keys of the files in [dir] ending with [suffix], by name, as JSON (what [folderValue] compares).
Map<String, List<int>> _folderKeys(Directory dir, String suffix) => {
  for (final f in newestFirst(dir, suffix))
    if (fileKey(f) case final k?) _name(f.path): [k.size, k.modifiedUs],
};

bool _sameKeys(Object? kept, Map<String, List<int>> now) {
  if (kept is! Map || kept.length != now.length) return false;
  for (final e in now.entries) {
    final k = kept[e.key];
    if (k is! List || k.length != 2 || k[0] != e.value[0] || k[1] != e.value[1]) return false;
  }
  return true;
}

/// One JSON value worked out by [compute] from the files of [dir] ending with [suffix], kept in [cache] with the
/// files' keys: [compute] runs again only when a file is new, changed or gone (or [version] changed).
Object? folderValue(File cache, Directory dir, String suffix, {required int version, required Object? Function() compute}) {
  final keys = _folderKeys(dir, suffix);
  try {
    final j = jsonDecode(cache.readAsStringSync());
    if (j is Map && j['version'] == version && _sameKeys(j['files'], keys)) return j['value'];
  } on FileSystemException {
    // not kept yet
  } on FormatException {
    // damaged: worked out again
  }
  final value = compute();
  try {
    cache.parent.createSync(recursive: true);
    final tmp = File('${cache.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
    tmp.writeAsStringSync(jsonEncode({'version': version, 'files': keys, 'value': value}), flush: true);
    tmp.renameSync(cache.path);
  } on FileSystemException {
    // worked out again next time
  } on JsonUnsupportedObjectError {
    // a value JSON cannot hold (not finite): worked out again next time
  }
  return value;
}
