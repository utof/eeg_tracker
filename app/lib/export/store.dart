// Export data (DECISIONS rows 150-154): what leaves the phone, and the phone's own record of what already did.
//
// Everything the app keeps in its private `files/` folder is exported in the same layout (recordings/, nights/,
// mornings/, meditations/, alpha-theta/, replay-check/, settings.json, dream-catcher/, sound-states/, experiments/ and whatever a
// later feature adds), except:
//   models/      copies of the app's own sleep-model assets (made again from the APK)
//   export/      this file's state: the index of what was exported and the export log
//   *.tmp        half-written files (every store writes a temporary file, then renames it)
//   *.scoring    the sleep scorer's "working on it" marker
//   profileInstalled, flutter_callback_cache.json
//                what Android and the plugins keep at the top of `files/` for themselves (androidx's profile
//                installer, flutter_foreground_task's callback handle; seen on the emulator, DECISIONS row 160)
// The index (`files/export/state.json`) holds each exported file's size, modified time and SHA-256, so an export of
// "what is new" needs to read only new or changed files, and the manifest can list every file without reading it
// again. Plain Dart: tested on a plain folder.
import 'dart:convert';
import 'dart:io';

import '../sleep/report.dart' show isoLocal;

/// The folder an export creates inside the one the owner picked (or a Syncthing folder).
const String exportFolderName = 'eeg-export';
const String manifestFormat = 'eeg-tracker-phone-export';
const int manifestVersion = 1;

/// Days after the last complete export from which the main screen warns, when something new is only on the phone.
const int exportReminderDays = 3;

const Set<String> _staysTop = {'models', 'export'};
const Set<String> _platformFiles = {'profileInstalled', 'flutter_callback_cache.json'};

/// A relative path inside the export folder: `/`-separated, no empty, `.` or `..` parts.
bool safeExportPath(String p) =>
    p.isNotEmpty && !p.startsWith('/') && !p.contains(r'\') && p.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');

/// Whether a file at [path] (relative to `files/`) leaves the phone.
bool isExported(String path) {
  final parts = path.split('/');
  if (parts.length > 1 && _staysTop.contains(parts.first)) return false;
  if (parts.length == 1 && _platformFiles.contains(path)) return false;
  return safeExportPath(path) && !path.endsWith('.tmp') && !path.endsWith('.scoring');
}

/// One file in the app's folder.
class StoredFile {
  const StoredFile(this.path, this.file, this.bytes, this.modifiedMs);

  /// Relative to `files/`, with `/` (`recordings/2026-11-18-231200.f32`).
  final String path;
  final File file;
  final int bytes;
  final int modifiedMs;
}

/// Every file that leaves the phone, sorted by path. A file that vanishes while listed is skipped.
List<StoredFile> storedFiles(Directory filesDir) {
  if (!filesDir.existsSync()) return const [];
  final base = filesDir.path.length + 1;
  final out = <StoredFile>[];
  for (final e in filesDir.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final path = e.path.substring(base).replaceAll(Platform.pathSeparator, '/');
    if (!isExported(path)) continue;
    final st = e.statSync();
    if (st.type != FileSystemEntityType.file) continue;
    out.add(StoredFile(path, e, st.size, st.modified.millisecondsSinceEpoch));
  }
  return out..sort((a, b) => a.path.compareTo(b.path));
}

/// What an export wrote for one file.
class ExportedFile {
  const ExportedFile({
    required this.bytes,
    required this.modifiedMs,
    required this.sha256,
    required this.written,
    this.recopy = false,
  });

  final int bytes;

  /// The phone's modified time of the copy that was exported.
  final int modifiedMs;
  final String sha256;

  /// When the export that wrote it ran (local ISO time with offset).
  final String written;

  /// It changed while it was being copied: the next export copies it again.
  final bool recopy;

  bool sameAs(StoredFile f) => !recopy && bytes == f.bytes && modifiedMs == f.modifiedMs;

  Map<String, Object?> toJson() => {
    'bytes': bytes,
    'modified_ms': modifiedMs,
    'sha256': sha256,
    'written': written,
    if (recopy) 'recopy': true,
  };

  static ExportedFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = j['bytes'], m = j['modified_ms'], s = j['sha256'], w = j['written'];
    if (b is! int || m is! int || s is! String || w is! String) return null;
    return ExportedFile(bytes: b, modifiedMs: m, sha256: s, written: w, recopy: j['recopy'] == true);
  }
}

class ExportState {
  ExportState({this.folder, this.folderLabel, this.lastExport, this.lastComplete, Map<String, ExportedFile>? files})
    : files = files ?? {};

  /// The picked folder (an Android tree URI) and how to show it (`Download/EEG`); null before the first pick.
  final String? folder;
  final String? folderLabel;

  /// The last export that ran, and the last that left nothing behind.
  DateTime? lastExport;
  DateTime? lastComplete;

  /// Path -> what was exported to [folder].
  final Map<String, ExportedFile> files;

  Map<String, Object?> toJson() => {
    'version': 1,
    'folder': folder,
    'folder_label': folderLabel,
    'last_export': lastExport == null ? null : isoLocal(lastExport!),
    'last_complete': lastComplete == null ? null : isoLocal(lastComplete!),
    'files': {for (final e in files.entries) e.key: e.value.toJson()},
  };

  static ExportState fromJson(Object? j) {
    if (j is! Map) return ExportState();
    DateTime? time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
    final raw = j['files'];
    final files = <String, ExportedFile>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final f = ExportedFile.fromJson(e.value);
        if (e.key is String && safeExportPath(e.key as String) && f != null) files[e.key as String] = f;
      }
    }
    return ExportState(
      folder: j['folder'] is String ? j['folder'] as String : null,
      folderLabel: j['folder_label'] is String ? j['folder_label'] as String : null,
      lastExport: time(j['last_export']),
      lastComplete: time(j['last_complete']),
      files: files,
    );
  }
}

/// `files/export/`: the index and the log of exports, app-private like everything else.
class ExportStore {
  ExportStore(this.filesDir);
  final Directory filesDir;

  Directory get dir => Directory('${filesDir.path}/export');
  File get _state => File('${dir.path}/state.json');
  File get logFile => File('${dir.path}/exports.jsonl');

  /// The saved state; a missing or damaged file starts empty (then everything is exported again: safe).
  ExportState load() {
    try {
      return ExportState.fromJson(jsonDecode(_state.readAsStringSync()));
    } on Object {
      return ExportState();
    }
  }

  void save(ExportState s) {
    dir.createSync(recursive: true);
    final tmp = File('${_state.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(s.toJson()), flush: true);
    tmp.renameSync(_state.path);
  }

  /// Remembers the picked folder. Another folder than before starts again: nothing has been exported there yet.
  ExportState chooseFolder(String folder, String label) {
    final s = load();
    final next = s.folder == folder
        ? ExportState(
            folder: folder,
            folderLabel: label,
            lastExport: s.lastExport,
            lastComplete: s.lastComplete,
            files: s.files,
          )
        : ExportState(folder: folder, folderLabel: label);
    save(next);
    return next;
  }

  void appendLog(Map<String, Object?> line) {
    dir.createSync(recursive: true);
    logFile.writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
  }

  String log() {
    try {
      return logFile.readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }
}

/// The files an export of what is new would copy: new, changed, or not finished last time.
List<StoredFile> newOrChanged(List<StoredFile> stored, ExportState s) => [
  for (final f in stored)
    if (!(s.files[f.path]?.sameAs(f) ?? false)) f,
];

typedef Pending = ({int files, int bytes, DateTime? lastComplete});

/// What the export page shows before an export: the phone's files, what is new, the folder.
typedef ExportSummary = ({
  int phoneFiles,
  int phoneBytes,
  int pendingFiles,
  int pendingBytes,
  DateTime? lastComplete,
  String? folder,
  String? folderLabel,
});

ExportSummary summarizeExport(Directory filesDir) {
  final s = ExportStore(filesDir).load();
  final stored = storedFiles(filesDir);
  final todo = newOrChanged(stored, s);
  return (
    phoneFiles: stored.length,
    phoneBytes: stored.fold(0, (n, f) => n + f.bytes),
    pendingFiles: todo.length,
    pendingBytes: todo.fold(0, (n, f) => n + f.bytes),
    lastComplete: s.lastComplete,
    folder: s.folder,
    folderLabel: s.folderLabel,
  );
}

/// What the next "Export new" would copy, and when the last complete export was. Reads only file sizes and times.
Pending pendingExport(Directory filesDir) {
  final s = ExportStore(filesDir).load();
  final todo = newOrChanged(storedFiles(filesDir), s);
  return (files: todo.length, bytes: todo.fold(0, (n, f) => n + f.bytes), lastComplete: s.lastComplete);
}

/// `2.4 MB`, `210 MB`, `3.1 GB`.
String sizeText(int bytes) => bytes >= 1e9
    ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
    : '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB';

/// `today`, `yesterday`, `5 days ago` (calendar days, local time).
String daysAgo(DateTime then, DateTime now) {
  final d = _calendarDays(then, now);
  return d <= 0 ? 'today' : (d == 1 ? 'yesterday' : '$d days ago');
}

int _calendarDays(DateTime a, DateTime b) =>
    (DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inHours / 24).round();

/// The line on the main screen: when the last export was and what is only on this phone since; [warn] from
/// [exportReminderDays] days with something new, or when nothing was ever exported. Null with nothing to export.
({String text, bool warn})? exportLine({
  required DateTime? lastComplete,
  required int pendingFiles,
  required int pendingBytes,
  required DateTime now,
}) {
  if (lastComplete == null) {
    return pendingFiles == 0 ? null : (text: 'Never exported: all of it is only on this phone.', warn: true);
  }
  final ago = daysAgo(lastComplete, now);
  if (pendingFiles == 0) return (text: 'Last export $ago; nothing new since.', warn: false);
  final what = '${pendingFiles == 1 ? '1 new file' : '$pendingFiles new files'} (${sizeText(pendingBytes)})';
  if (_calendarDays(lastComplete, now) >= exportReminderDays) {
    return (text: 'Last export $ago: $what ${pendingFiles == 1 ? 'is' : 'are'} only on this phone.', warn: true);
  }
  return (text: 'Last export $ago; $what since.', warn: false);
}
