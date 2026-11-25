// Export data (DECISIONS rows 150-154): copies the app's files into the export folder and writes the manifest the
// laptop checks (scripts/import_phone.py; docs/data-format.md, "The phone's export folder").
//
// In the export folder (`<picked folder>/eeg-export/`), the layout of the app's `files/`:
//   recordings/ nights/ mornings/ meditations/ alpha-theta/ replay-check/ dream-catcher/ sound-states/ settings.json
//   manifest.json   every file exported to this folder so far: path, bytes, SHA-256, the phone's modified time,
//                   when it was written; what is still only on the phone (`not_exported`); written last, every time
//   exports.jsonl   one line per export (the phone's log, copied whole)
// "New" copies new and changed files; "everything" copies every file again. Files are only ever added or replaced
// in the export folder; nothing in the app's folder is changed or deleted. Copies run one file at a time through an
// [ExportTarget]: the system folder grant on the phone (DataExport.kt), a plain folder in tests.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../recorder/remove.dart' show removedRawPaths;
import '../sleep/report.dart' show isoLocal;
import 'store.dart';

typedef Copied = ({int bytes, String sha256});

/// A failure the export folder reported, in words.
class ExportFailure implements Exception {
  const ExportFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where an export writes: the `eeg-export` folder inside the picked one. Paths are relative to it.
abstract interface class ExportTarget {
  /// Finds or creates `eeg-export` in the picked folder; throws [ExportFailure] when the folder cannot be used.
  Future<void> open();

  /// Copies [source] to [path], replacing a file of that name, and returns the bytes written and their SHA-256.
  Future<Copied> copy(File source, String path);

  /// Writes [bytes] to [path], replacing a file of that name.
  Future<Copied> write(String path, List<int> bytes);

  Future<void> close();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// An export into a plain folder (tests, and anything off the phone).
class DirectoryTarget implements ExportTarget {
  DirectoryTarget(this.parent);

  /// The picked folder; the export goes into `eeg-export` inside it.
  final Directory parent;

  Directory get root => Directory('${parent.path}/$exportFolderName');

  File _file(String path) {
    if (!safeExportPath(path)) throw ExportFailure('not a path inside the export folder: $path');
    return File('${root.path}/$path')..parent.createSync(recursive: true);
  }

  @override
  Future<void> open() async {
    if (!parent.existsSync()) throw ExportFailure('the folder ${parent.path} is gone');
    root.createSync();
  }

  @override
  Future<Copied> copy(File source, String path) async {
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final out = _file(path).openWrite();
    var n = 0;
    try {
      await for (final chunk in source.openRead()) {
        hash.add(chunk);
        out.add(chunk);
        n += chunk.length;
      }
    } finally {
      await out.close();
    }
    hash.close();
    return (bytes: n, sha256: digest.value.toString());
  }

  @override
  Future<Copied> write(String path, List<int> bytes) async {
    _file(path).writeAsBytesSync(bytes, flush: true);
    return (bytes: bytes.length, sha256: sha256.convert(bytes).toString());
  }

  @override
  Future<void> close() async {}
}

class ExportProgress {
  const ExportProgress(this.done, this.total, this.bytesDone, this.bytesTotal, this.path);
  final int done, total, bytesDone, bytesTotal;

  /// The file being copied now.
  final String path;
}

/// [stillWritten]: the files left out because a recording that runs is writing their file set: they come with the
/// next export, and an export without them still counts as complete.
typedef ExportOutcome = ({
  List<String> stillWritten,
  int files,
  int bytes,
  bool complete,
  String? error,
  List<String> notExported,
  DateTime at,
});

String _why(Object e) => switch (e) {
  ExportFailure(:final message) => message,
  FileSystemException(:final message, :final osError) =>
    osError == null || message.contains(osError.message) ? message : '$message (${osError.message})',
  _ => '$e',
};

/// The manifest: every file exported to this folder, sorted by path; a file the phone no longer has stays listed
/// with `on_phone: false`, and a raw file that left it (recorder/remove.dart) with `removed`: why (`moved to the
/// laptop`, `deleted by hand`).
Map<String, Object?> buildManifest({
  required ExportState state,
  required Set<String> onPhone,
  required DateTime at,
  required bool everything,
  required List<String> notExported,
  Map<String, String> removed = const {},
}) {
  final paths = state.files.keys.toList()..sort();
  final files = [
    for (final p in paths)
      {
        'path': p,
        'bytes': state.files[p]!.bytes,
        'sha256': state.files[p]!.sha256,
        'modified_ms': state.files[p]!.modifiedMs,
        'written': state.files[p]!.written,
        if (state.files[p]!.original != null) 'original': state.files[p]!.original,
        if (!onPhone.contains(p)) 'on_phone': false,
        if (!onPhone.contains(p) && removed[p] != null) 'removed': removed[p],
      },
  ];
  return {
    'format': manifestFormat,
    'version': manifestVersion,
    'exported': isoLocal(at),
    'mode': everything ? 'everything' : 'new',
    'complete': notExported.isEmpty,
    'files': files,
    'not_exported': notExported,
    'totals': {'files': files.length, 'bytes': state.files.values.fold(0, (n, f) => n + f.bytes)},
  };
}

/// Exports what is new (or [everything]) from [filesDir] to [target]. Never throws: a failure stops the copying,
/// is returned in words, and what was copied before it stays listed in the manifest (when it can still be written).
/// [stopRequested] is asked before each file. [open]: the plain `.f32` paths of the file sets being written, whose
/// files are left out.
Future<ExportOutcome> runExport({
  required Directory filesDir,
  required ExportTarget target,
  required bool everything,
  DateTime Function() clock = DateTime.now,
  void Function(ExportProgress p)? onProgress,
  bool Function()? stopRequested,
  Set<String> open = const {},
}) async {
  final at = clock();
  final store = ExportStore(filesDir);
  final state = store.load();
  final stored = storedFiles(filesDir);
  // the file set a recording writes now (storage/open_sets.dart, DECISIONS 1040) is not copied half-way
  final openStems = {
    for (final p in open)
      if (p.startsWith('${filesDir.path}/') && p.endsWith('.f32')) p.substring(filesDir.path.length + 1, p.length - 3),
  };
  bool isOpen(StoredFile f) => openStems.any(f.path.startsWith);
  final stillWritten = [for (final f in stored) if (isOpen(f)) f.path];
  final todo = [for (final f in everything ? stored : newOrChanged(stored, state)) if (!isOpen(f)) f];
  final total = todo.fold(0, (n, f) => n + f.bytes);
  final written = isoLocal(at);
  var done = 0, bytes = 0;
  String? error;
  try {
    await target.open();
  } on Object catch (e) {
    return (
      files: 0,
      bytes: 0,
      complete: false,
      error: _why(e),
      notExported: [for (final f in todo) f.path],
      at: at,
      stillWritten: stillWritten,
    );
  }
  try {
    for (final f in todo) {
      if (stopRequested?.call() ?? false) break;
      onProgress?.call(ExportProgress(done, todo.length, bytes, total, f.path));
      final c = await target.copy(f.file, f.path);
      final after = f.file.statSync();
      final steady = after.type == FileSystemEntityType.file &&
          after.size == f.bytes &&
          after.modified.millisecondsSinceEpoch == f.modifiedMs &&
          c.bytes == f.bytes;
      state.files[f.path] = ExportedFile(
        bytes: c.bytes,
        modifiedMs: f.modifiedMs,
        sha256: c.sha256,
        written: written,
        recopy: !steady,
        original: f.originalJson, // a packed recording names the .f32 it holds; the laptop unpacks and checks it
      );
      done++;
      bytes += c.bytes;
      if (done % 25 == 0) store.save(state);
    }
  } on Object catch (e) {
    error = _why(e);
  }
  final notExported = [for (final f in todo.skip(done)) f.path];
  var complete = notExported.isEmpty && error == null;
  store.save(state);
  final manifest = buildManifest(
    state: state,
    onPhone: {for (final f in stored) ...{f.path, f.originalPath}}, // a packed recording's .f32 is on the phone too
    at: at,
    everything: everything,
    notExported: notExported,
    removed: removedRawPaths(filesDir),
  );
  store.appendLog({
    'exported': written,
    'mode': everything ? 'everything' : 'new',
    'files': done,
    'bytes': bytes,
    'complete': complete,
    'error': error,
  });
  try {
    await target.write('manifest.json', utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest)));
    await target.write('exports.jsonl', utf8.encode(store.log()));
  } on Object catch (e) {
    // without a fresh manifest the laptop cannot check this export: it does not count as complete
    error ??= 'the list of files could not be written: ${_why(e)}';
    complete = false;
  }
  try {
    await target.close();
  } on Object {
    // nothing left to do with the folder
  }
  state.lastExport = at;
  if (complete) state.lastComplete = at;
  store.save(state);
  return (
    files: done,
    bytes: bytes,
    complete: complete,
    error: error,
    notExported: notExported,
    at: at,
    stillWritten: stillWritten,
  );
}
