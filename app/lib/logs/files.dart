// The app's own records in `files/logs/` (DECISIONS 710-711): one JSON line per entry, in day files per kind and per
// Flutter engine, so the screen, the night recorder's service and the headband watcher never write the same file:
//
//   app-2026-11-20-screen.jsonl       the levelled log of every subsystem, errors with their context (7 days, 20 MB)
//   usage-2026-11-20-screen.jsonl     how the app is used: screens, taps, scrolls, features, hints (90 days, 10 MB)
//   metrics-2026-11-20-recorder.jsonl measurements: battery, CPU, memory, frames, start-up, storage (60 days, 20 MB)
//   settings.json                     the switches of the Usage and Battery pages
//
// A file over 4 MB continues in `-2`, `-3`. The folder leaves the phone with Export data and Share on Wi-Fi like every
// other folder of `files/` (export/store.dart) and lands in `_local/phone/logs/` on the laptop. Plain Dart: no Flutter.
import 'dart:convert';
import 'dart:io';

/// `files/logs/`, next to `files/recordings/`.
Directory logsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/logs');

enum LogKind {
  app(Duration(days: 7), 20 << 20),
  usage(Duration(days: 90), 10 << 20),
  metrics(Duration(days: 60), 20 << 20);

  const LogKind(this.keep, this.maxBytes);

  /// Files older than this go.
  final Duration keep;

  /// Then the oldest files of the kind go until all of them fit in this many bytes.
  final int maxBytes;
}

/// One file's size before the next part starts.
const int logPartBytes = 4 << 20;

/// A file written in the last 10 minutes may be open in another engine: pruning never deletes it.
const Duration logOpenWindow = Duration(minutes: 10);

String _two(int v) => v.toString().padLeft(2, '0');

/// `2026-11-20`, the local day.
String logDay(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';

/// `2026-11-20T14:31:02.123+03:00`: local time with milliseconds and the offset.
String logTime(DateTime t) {
  final l = t.toLocal();
  final off = l.timeZoneOffset;
  final m = off.inMinutes.abs();
  return '${logDay(l)}T${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}.${l.millisecond.toString().padLeft(3, '0')}'
      '${off.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
}

typedef LogFileName = ({LogKind kind, String day, String engine, int part});

final RegExp _name = RegExp(r'^(app|usage|metrics)-(\d{4}-\d{2}-\d{2})-([a-z][a-z0-9]*)(?:-(\d+))?\.jsonl$');

String logFileName(LogKind kind, String day, String engine, [int part = 1]) =>
    '${kind.name}-$day-$engine${part > 1 ? '-$part' : ''}.jsonl';

/// The parts of a log file's name, or null for anything else in the folder.
LogFileName? parseLogFileName(String name) {
  final m = _name.firstMatch(name);
  if (m == null) return null;
  return (
    kind: LogKind.values.byName(m.group(1)!),
    day: m.group(2)!,
    engine: m.group(3)!,
    part: m.group(4) == null ? 1 : int.parse(m.group(4)!),
  );
}

/// Every log file in [dir] (of [kind] when given), oldest day first, parts in order.
List<File> logFiles(Directory dir, {LogKind? kind}) {
  if (!dir.existsSync()) return const [];
  final out = <(LogFileName, File)>[];
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File) continue;
    final n = parseLogFileName(e.uri.pathSegments.last);
    if (n != null && (kind == null || n.kind == kind)) out.add((n, e));
  }
  out.sort((a, b) {
    final d = a.$1.day.compareTo(b.$1.day);
    if (d != 0) return d;
    final g = a.$1.engine.compareTo(b.$1.engine);
    return g != 0 ? g : a.$1.part.compareTo(b.$1.part);
  });
  return [for (final (_, f) in out) f];
}

/// Appends JSON lines to the day's file of one kind and one engine. Each line is one write to a file opened for
/// appending, so a crash loses at most the line being written. Never throws: a line that cannot be written (storage
/// full, the folder deleted) is counted in [lost] and the next one tries again.
class JsonlWriter {
  JsonlWriter(this.dir, this.kind, this.engine, {DateTime Function()? clock, this.partBytes = logPartBytes})
    : _clock = clock ?? DateTime.now;

  final Directory dir;
  final LogKind kind;
  final String engine;
  final int partBytes;
  final DateTime Function() _clock;

  RandomAccessFile? _file;
  String? _day;
  int _part = 1;
  int _bytes = 0;

  /// When the file was last seen in the folder: a Delete on the log page (from any engine) unlinks it, and lines
  /// written to an unlinked file are lost, so the writer looks again every [_lookEvery] and starts a new file.
  DateTime? _seen;
  static const Duration _lookEvery = Duration(seconds: 10);

  /// Lines that could not be written.
  int lost = 0;

  /// The file being written, or null before the first line.
  String? get path => _day == null ? null : '${dir.path}/${logFileName(kind, _day!, engine, _part)}';

  void write(Map<String, Object?> line) {
    List<int> bytes;
    try {
      bytes = utf8.encode('${jsonEncode(line, toEncodable: _plain)}\n');
    } catch (_) {
      try {
        bytes = utf8.encode('${jsonEncode(_finite(line), toEncodable: _plain)}\n'); // NaN and infinity as null
      } catch (_) {
        lost++;
        return;
      }
    }
    try {
      final now = _clock();
      final day = logDay(now);
      if (day != _day || _file == null || _gone(now)) _open(day);
      if (_bytes > 0 && _bytes + bytes.length > partBytes) {
        _close();
        _part++;
        _openPart();
      }
      _file!.writeFromSync(bytes);
      _bytes += bytes.length;
    } catch (_) {
      lost++;
      _close(); // opened again for the next line
    }
  }

  bool _gone(DateTime now) {
    final seen = _seen;
    if (seen != null && now.difference(seen).abs() < _lookEvery) return false;
    _seen = now;
    return !File(path!).existsSync();
  }

  void _open(String day) {
    _close();
    _day = day;
    dir.createSync(recursive: true);
    // a restarted engine continues the day's last part
    _part = 1;
    for (final f in logFiles(dir, kind: kind)) {
      final n = parseLogFileName(f.uri.pathSegments.last)!;
      if (n.day == day && n.engine == engine && n.part > _part) _part = n.part;
    }
    _openPart();
  }

  void _openPart() {
    final f = File(path!);
    _file = f.openSync(mode: FileMode.append);
    _bytes = _file!.lengthSync();
  }

  void _close() {
    try {
      _file?.closeSync();
    } catch (_) {}
    _file = null;
  }

  void close() {
    _close();
    _day = null;
  }
}

/// [o] with every NaN or infinite number as null (JSON has neither).
Object? _finite(Object? o) => switch (o) {
  final double d when !d.isFinite => null,
  final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': _finite(e.value)},
  final List<Object?> l => [for (final v in l) _finite(v)],
  _ => o,
};

/// Something jsonEncode cannot write as it is: its words.
Object? _plain(Object? o) => switch (o) {
  final double d when !d.isFinite => null, // JSON has no NaN or infinity
  final DateTime t => logTime(t),
  final Duration d => d.inMilliseconds,
  _ => o.toString(),
};

/// Deletes the log files past their kind's days, then the oldest of a kind while the kind is over its bytes; never a
/// file written in the last [logOpenWindow] (another engine may hold it open). Returns how many went. Never throws.
int pruneLogs(Directory dir, DateTime now) {
  var gone = 0;
  try {
    for (final kind in LogKind.values) {
      final files = logFiles(dir, kind: kind);
      final cutoff = logDay(now.subtract(kind.keep));
      final left = <(File, int, DateTime)>[];
      for (final f in files) {
        final n = parseLogFileName(f.uri.pathSegments.last)!;
        final FileStat st;
        try {
          st = f.statSync();
        } catch (_) {
          continue;
        }
        final open = now.difference(st.modified) < logOpenWindow;
        if (!open && n.day.compareTo(cutoff) < 0) {
          if (_delete(f)) gone++;
        } else {
          left.add((f, st.size, st.modified));
        }
      }
      var total = left.fold<int>(0, (s, e) => s + e.$2);
      for (final (f, size, modified) in left) {
        if (total <= kind.maxBytes) break;
        if (now.difference(modified) < logOpenWindow) continue;
        if (_delete(f)) {
          gone++;
          total -= size;
        }
      }
    }
  } catch (_) {}
  return gone;
}

bool _delete(File f) {
  try {
    f.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Bytes and files of [dir]'s logs by kind (the pages say how much is kept).
Map<LogKind, ({int files, int bytes})> logSizes(Directory dir) {
  final out = {for (final k in LogKind.values) k: (files: 0, bytes: 0)};
  for (final f in logFiles(dir)) {
    final n = parseLogFileName(f.uri.pathSegments.last)!;
    int size;
    try {
      size = f.lengthSync();
    } catch (_) {
      continue;
    }
    final was = out[n.kind]!;
    out[n.kind] = (files: was.files + 1, bytes: was.bytes + size);
  }
  return out;
}

/// Deletes every log file of [kinds] (the pages' Delete). An engine writing one of them starts a new file within
/// 10 seconds ([JsonlWriter]). Returns how many went.
int deleteLogs(Directory dir, Set<LogKind> kinds) {
  var gone = 0;
  for (final f in logFiles(dir)) {
    if (kinds.contains(parseLogFileName(f.uri.pathSegments.last)!.kind) && _delete(f)) gone++;
  }
  return gone;
}

/// The JSON objects of [file], oldest first; a cut or foreign line is skipped.
List<Map<String, Object?>> readJsonl(File file) {
  final out = <Map<String, Object?>>[];
  String text;
  try {
    text = file.readAsStringSync();
  } catch (_) {
    return out;
  }
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    try {
      final j = jsonDecode(line);
      if (j is Map<String, Object?>) out.add(j);
    } catch (_) {}
  }
  return out;
}
