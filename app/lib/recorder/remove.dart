// Removing a recording's raw files from the phone (DECISIONS 690-699): the one place that does it, for the move to
// the laptop (share/move.dart) and for the owner's own deletions (an Archive page).
//
// A file set's raw files are its samples (`<stamp>.f32`, or `<stamp>.f32.gz` after a day) and its index
// (`<stamp>.idx`): the bulk. Everything else of the set stays: its `.log`, `.header.json` and `.markers.jsonl`, and
// every report, summary and result made from it. Before the first file goes, `<stamp>.removed.json` is written beside
// them: what went, when, why, whether the paired laptop holds a checked copy (acks.dart), the night it belonged to and
// when its data ended. So the nights keep their shape (nights.dart chains a removed set by it, and the sleep scoring
// never scores a night again from what is left), and each screen that needs the samples says where they are instead
// of failing ([rawGoneText]). [removeRaw] refuses in words, with nothing deleted, a set:
// - that something on the phone reads now ([RawUse]: the sleep scoring, the lucid cues' morning search);
// - written in the last hour ([removeSettled]): a recording or a session going on, or just stopped;
// - with `onlyIfOnLaptop` (the move; the Archive when the owner asks for it) whose raw files the laptop has not acked
//   as they are now.
//
// Plain dart:io; synchronous and quick (a few deletes): run it on the isolate whose readers [RawUse] knows.
import 'dart:convert';
import 'dart:io';

import 'acks.dart';
import 'nights.dart' show dataEndOf, dateName, nightOf, stemTime;
import 'packed.dart' show isPackedPath, packedInfo, plainFileOf, rawLength, rawOnDisk;

const String removedSuffix = '.removed.json';
const String removedFormat = 'eeg-tracker-removed';

/// Files changed this recently are still being written (a run going on, or a session just stopped): never removed.
const Duration removeSettled = Duration(hours: 1);

/// Why raw files were removed, as the record says it.
const String whyMoved = 'moved to the laptop';
const String whyByHand = 'deleted by hand';

/// Raw files being read on this isolate: a plain `.f32` path (one file set) or a folder (every set in it).
class RawUse {
  RawUse._();
  static final Map<String, int> _held = {};

  /// Runs [body] with [paths] marked as read: [removeRaw] refuses them until it ends.
  static Future<T> hold<T>(Iterable<String> paths, Future<T> Function() body) async {
    final list = [for (final p in paths) _plain(p)];
    for (final p in list) {
      _held[p] = (_held[p] ?? 0) + 1;
    }
    try {
      return await body();
    } finally {
      for (final p in list) {
        final n = (_held[p] ?? 1) - 1;
        if (n <= 0) {
          _held.remove(p);
        } else {
          _held[p] = n;
        }
      }
    }
  }

  /// Whether the set of [f32] (plain or packed name) or its folder is being read.
  static bool inUse(File f32) {
    final p = plainFileOf(f32).path;
    return _held.containsKey(p) || _held.containsKey(f32.parent.path);
  }

  static String _plain(String p) => isPackedPath(p) ? plainFileOf(File(p)).path : p;
}

/// One raw file a record says went: its plain name, length and SHA-256 (null when unknown: deleted by hand without
/// an ack), and the name and bytes it had on the phone (a packed file's are its own).
class RemovedFile {
  const RemovedFile({required this.name, required this.bytes, this.sha256, required this.phoneName, required this.phoneBytes});
  final String name;
  final int bytes;
  final String? sha256;
  final String phoneName;
  final int phoneBytes;

  Map<String, Object?> toJson() => {
    'name': name,
    'bytes': bytes,
    'sha256': sha256,
    'phone_name': phoneName,
    'phone_bytes': phoneBytes,
  };

  static RemovedFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['name'], b = j['bytes'], s = j['sha256'], pn = j['phone_name'], pb = j['phone_bytes'];
    if (n is! String || b is! int || (s != null && !isSha256(s))) return null;
    return RemovedFile(
      name: n,
      bytes: b,
      sha256: s as String?,
      phoneName: pn is String ? pn : n,
      phoneBytes: pb is int ? pb : b,
    );
  }
}

/// `<stamp>.removed.json`: the raw files of a set that left the phone.
class RemovedRecord {
  const RemovedRecord({
    required this.removedMs,
    required this.onLaptop,
    required this.why,
    required this.files,
    this.laptop,
    this.night,
    this.endMs,
  });

  final int removedMs;

  /// The paired laptop held a checked copy of every file when it went.
  final bool onLaptop;
  final String why;
  final List<RemovedFile> files;

  /// The paired laptop's name, when it held the copy.
  final String? laptop;

  /// The night it belonged to (`2026-11-18`); null for a set of no night.
  final String? night;

  /// When its data ended (unix ms); null for a set without samples.
  final int? endMs;

  /// The space the files took on the phone.
  int get phoneBytes => files.fold(0, (n, f) => n + f.phoneBytes);

  /// The plain `.f32`'s length (0 when only its index went).
  int get samplesBytes => files.where((f) => f.name.endsWith('.f32')).fold(0, (n, f) => n + f.bytes);

  Map<String, Object?> toJson() => {
    'format': removedFormat,
    'version': 1,
    'removed': DateTime.fromMillisecondsSinceEpoch(removedMs).toIso8601String(),
    'removed_ms': removedMs,
    'on_laptop': onLaptop,
    'laptop': laptop,
    'why': why,
    'night': night,
    'end_ms': endMs,
    'files': [for (final f in files) f.toJson()],
  };

  static RemovedRecord? fromJson(Object? j) {
    if (j is! Map || j['format'] != removedFormat || j['version'] != 1 || j['files'] is! List) return null;
    final ms = j['removed_ms'], end = j['end_ms'], night = j['night'], laptop = j['laptop'];
    final files = [for (final f in j['files'] as List) ?RemovedFile.fromJson(f)];
    if (ms is! int) return null;
    return RemovedRecord(
      removedMs: ms,
      onLaptop: j['on_laptop'] == true,
      why: j['why'] is String ? j['why'] as String : whyMoved,
      files: files,
      laptop: laptop is String ? laptop : null,
      night: night is String ? night : null,
      endMs: end is int ? end : null,
    );
  }
}

String _stemPath(File f) {
  final p = plainFileOf(f).path;
  return p.endsWith('.f32') ? p.substring(0, p.length - 4) : p;
}

/// `<stamp>.removed.json` beside [f32] (plain or packed name).
File removedRecordFile(File f32) => File('${_stemPath(f32)}$removedSuffix');

/// The record of [f32]'s set, or null when none (or it cannot be read).
RemovedRecord? removedRecordOf(File f32) {
  try {
    return RemovedRecord.fromJson(jsonDecode(removedRecordFile(f32).readAsStringSync()));
  } catch (_) {
    return null;
  }
}

/// The set's samples are gone from the phone and its record says so.
bool rawRemoved(File f32) => rawOnDisk(f32) == null && removedRecordOf(f32) != null;

/// The raw files of [f32]'s set that are on the phone: its samples (plain or packed) and its index.
List<File> rawFilesOf(File f32) {
  final out = <File>[];
  final samples = rawOnDisk(plainFileOf(f32));
  if (samples != null) out.add(samples);
  final idx = File('${_stemPath(f32)}.idx');
  if (idx.existsSync()) out.add(idx);
  return out;
}

/// `recordings/<name>`: [f]'s path relative to `files/` (its folder is one of the app's).
String relativeRaw(File f) {
  final parts = f.uri.pathSegments;
  return '${parts[parts.length - 2]}/${parts.last}';
}

/// Why [f32]'s set cannot lose its raw files now; null when it can. [acks]: the laptop's checked copies.
String? whyNotRemove(File f32, {required bool onlyIfOnLaptop, required Map<String, LaptopCopy> acks, required DateTime now}) {
  final files = rawFilesOf(f32);
  if (files.isEmpty) return 'no raw files on the phone';
  if (RawUse.inUse(f32)) return 'being read on the phone';
  for (final f in files) {
    try {
      if (now.difference(f.statSync().modified) < removeSettled) return 'written in the last hour';
    } on FileSystemException {
      return 'not readable now';
    }
  }
  if (onlyIfOnLaptop && !files.every((f) => ackedNow(acks, relativeRaw(f), f))) return 'not checked on the laptop yet';
  return null;
}

/// What [removeRaw] did.
typedef RemoveOutcome = ({bool removed, String? refused, int freedBytes});

/// Removes [f32]'s raw files after writing its record (see the top of this file); refused in words, with nothing
/// deleted, when [whyNotRemove] gives a reason. [night]: the night it belongs to, for the record ([nightOf] its start
/// when null). Never throws.
RemoveOutcome removeRaw(
  File f32, {
  required bool onlyIfOnLaptop,
  required Map<String, LaptopCopy> acks,
  required String why,
  String? laptop,
  String? night,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  try {
    final whyNot = whyNotRemove(f32, onlyIfOnLaptop: onlyIfOnLaptop, acks: acks, now: at);
    if (whyNot != null) return (removed: false, refused: whyNot, freedBytes: 0);
    final files = rawFilesOf(f32);
    final plain = plainFileOf(f32);
    final onLaptop = files.every((f) => ackedNow(acks, relativeRaw(f), f));
    final gone = <RemovedFile>[
      for (final f in files) _removedFile(f, acks[ackPathOf(relativeRaw(f))], plain),
    ];
    final before = removedRecordOf(f32); // a removal stopped half-way: its files stay listed
    final end = dataEndOf(plain);
    final start = stemTime(plain.uri.pathSegments.last);
    final record = RemovedRecord(
      removedMs: at.millisecondsSinceEpoch,
      onLaptop: onLaptop && (before?.onLaptop ?? true),
      why: why,
      files: [
        ...?before?.files.where((b) => !gone.any((g) => g.name == b.name)),
        ...gone,
      ],
      laptop: onLaptop ? laptop : before?.laptop,
      night: night ?? before?.night ?? (start == null ? null : dateName(nightOf(start))),
      endMs: end?.millisecondsSinceEpoch ?? before?.endMs,
    );
    final out = removedRecordFile(f32);
    final tmp = File('${out.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
    tmp.renameSync(out.path);
    var freed = 0;
    for (final f in files) {
      final n = f.lengthSync();
      f.deleteSync();
      freed += n;
    }
    return (removed: true, refused: null, freedBytes: freed);
  } on Object catch (e) {
    return (removed: false, refused: 'could not delete: $e', freedBytes: 0);
  }
}

RemovedFile _removedFile(File f, LaptopCopy? acked, File plain) {
  final name = f.uri.pathSegments.last;
  final phoneBytes = f.lengthSync();
  if (isPackedPath(f.path)) {
    final info = packedInfo(f);
    return RemovedFile(
      name: plain.uri.pathSegments.last,
      bytes: info?.bytes ?? rawLength(plain),
      sha256: info?.sha256 ?? acked?.sha256,
      phoneName: name,
      phoneBytes: phoneBytes,
    );
  }
  return RemovedFile(name: name, bytes: phoneBytes, sha256: acked?.sha256, phoneName: name, phoneBytes: phoneBytes);
}

/// The records of the sets of [nightName] (`2026-11-18`) in [dir] whose samples are gone; empty when none. Only the
/// records whose names fall from that evening to two days later are opened.
List<RemovedRecord> removedOfNight(Directory dir, String nightName) {
  final day = DateTime.tryParse(nightName);
  if (day == null) return const [];
  final from = day.add(const Duration(hours: 12)), to = day.add(const Duration(days: 2, hours: 12));
  final out = <RemovedRecord>[];
  try {
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith(removedSuffix)) continue;
      final t = stemTime(name);
      if (t == null || t.isBefore(from) || !t.isBefore(to)) continue;
      final plain = File('${f.path.substring(0, f.path.length - removedSuffix.length)}.f32');
      final r = removedRecordOf(plain);
      if (r != null && (r.night ?? dateName(nightOf(t))) == nightName && rawOnDisk(plain) == null) out.add(r);
    }
  } on FileSystemException {
    return const [];
  }
  return out;
}

/// What a screen that needs a night's samples says when they are gone: on the laptop when every removed set's record
/// says so; null when none is gone.
String? rawGoneText(List<RemovedRecord> removed, {String what = "This night's raw recording"}) {
  if (removed.isEmpty) return null;
  if (removed.every((r) => r.onLaptop)) {
    final names = {for (final r in removed) ?r.laptop};
    return '$what is on the laptop now${names.length == 1 ? ' (${names.first})' : ''}.';
  }
  return '$what was deleted from this phone.';
}

/// Every raw file that left the phone, by its path in `files/` (plain and as it was on the phone) -> why, from the
/// records in [movableFolders]: Export data's manifest names them.
Map<String, String> removedRawPaths(Directory filesDir) {
  final out = <String, String>{};
  for (final folder in movableFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    try {
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith(removedSuffix)) continue;
        final r = removedRecordOf(File('${f.path.substring(0, f.path.length - removedSuffix.length)}.f32'));
        for (final g in r?.files ?? const <RemovedFile>[]) {
          out['$folder/${g.name}'] = r!.why;
          out['$folder/${g.phoneName}'] = r.why;
        }
      }
    } on FileSystemException {
      continue;
    }
  }
  return out;
}

/// What a screen says for a file it needs that is gone from the phone (a spoken dream answer cleared on the Storage
/// page): on the laptop when the laptop had acked it, else deleted. [path] relative to [filesDir].
String fileGoneText(Directory filesDir, String path, {String what = 'This recording'}) =>
    AckStore(filesDir).load().containsKey(ackPathOf(path))
    ? '$what is on the laptop now, not on this phone.'
    : '$what was deleted from this phone.';
