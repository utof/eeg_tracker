// What the Archive needs from the phone's one safe-delete helper (the owner's rules, 2026-11-20: a recording the laptop
// holds a checked copy of goes with one tap; one that exists only on this phone is the Danger zone's, twice confirmed;
// statistics stay unless "Everything" is picked there; DECISIONS 700-709).
//
// The helper is the move-off-phone lane's `recorder/remove.dart` with its laptop acks (`recorder/acks.dart`, DECISIONS
// 690-699). It was not merged when the Archive was built, so the Archive talks to it through [RawRemover] alone, and
// [PhoneRawRemover] stands in for it with the same rules and the same files, so either side's records and acks read the
// same and the merge only swaps the body of [PhoneRawRemover] for calls to theirs:
// - a set's raw files are its samples (`<stamp>.f32`, or `.f32.gz` after a day) and its index (`<stamp>.idx`); its
//   `.log`, `.header.json` and `.markers.jsonl` and every report and summary made from it stay;
// - `<stamp>.removed.json` is written before the first file goes (format `eeg-tracker-removed`, version 1: when, why,
//   whether the laptop held a checked copy, the night, when its data ended, and each file's name, bytes and SHA-256);
// - refused in words, nothing deleted: no raw files left, a file written in the last hour, or (asked for) not every
//   raw file checked on the laptop as it is now;
// - the laptop's checked copies are `files/transfer/acks.json` (`eeg-tracker-acks`): path -> SHA-256, bytes, modified
//   time; a plain file is still that copy while its size and modified time are the acked ones, a packed one while its
//   header's length and SHA-256 are. Without that file the phone has no word from any laptop.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../recorder/chunk_writer.dart' show indexBytes;
import '../recorder/header.dart' show legacyHeader, tryHeader;
import '../recorder/nights.dart' show dateName, nightOf, stemTime;
import '../recorder/packed.dart' show isPackedPath, packedInfo, packedSuffix, plainFileOf, rawLength, rawOnDisk;

const String removedSuffix = '.removed.json';
const String removedFormat = 'eeg-tracker-removed';
const String acksFormat = 'eeg-tracker-acks';

/// Files changed this recently are still being written, or a session just stopped: never removed (the helper's rule).
const Duration removeSettled = Duration(hours: 1);

const String whyByHand = 'deleted by hand';

/// The laptop's word on a file, or a recording.
enum OnLaptop {
  /// It holds a checked copy of it as it is now.
  yes,

  /// It said nothing about it, or about other bytes.
  no,

  /// The phone has no word from any laptop (no acks at all): treated as [no] for deleting.
  unknown,
}

typedef RemoveResult = ({bool removed, String? refused, int freedBytes});

/// The Archive's view of the safe-delete helper.
abstract interface class RawRemover {
  /// The laptop's word on the phone's file [path] (relative to `files/`, `recordings/2026-11-18-231200.f32.gz`).
  OnLaptop onLaptop(String path);

  /// Why the raw files of the set of [f32] (its plain name) cannot go now, in words; null when they can.
  String? whyNotRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now});

  /// Removes the set's samples and index, its record written first; refused in words with nothing deleted.
  RemoveResult removeRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now});

  /// The set of [f32] lost its raw files: when its data ended and whether the laptop held them; null when it did not.
  ({DateTime? end, bool onLaptop})? removedOf(File f32);
}

String _stemPath(File f32) {
  final p = plainFileOf(f32).path;
  return p.endsWith('.f32') ? p.substring(0, p.length - 4) : p;
}

/// `<stamp>.removed.json` beside [f32].
File removedRecordFile(File f32) => File('${_stemPath(f32)}$removedSuffix');

/// The stand-in for the move-off-phone lane's helper (see the top of the file).
class PhoneRawRemover implements RawRemover {
  PhoneRawRemover(this.filesDir) : _acks = _loadAcks(filesDir);
  final Directory filesDir;
  final Map<String, ({String sha256, int bytes, int modifiedMs})>? _acks;

  static Map<String, ({String sha256, int bytes, int modifiedMs})>? _loadAcks(Directory filesDir) {
    try {
      final j = jsonDecode(File('${filesDir.path}/transfer/acks.json').readAsStringSync());
      if (j is! Map || j['format'] != acksFormat || j['files'] is! Map) return null;
      return {
        for (final e in (j['files'] as Map).entries)
          if (e.key is String && e.value is Map)
            if ((e.value as Map)['sha256'] case final String s)
              if ((e.value as Map)['bytes'] case final int b)
                if ((e.value as Map)['modified_ms'] case final int m) e.key as String: (sha256: s, bytes: b, modifiedMs: m),
      };
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  OnLaptop onLaptop(String path) {
    final acks = _acks;
    if (acks == null || acks.isEmpty) return OnLaptop.unknown;
    final a = acks[isPackedPath(path) ? path.substring(0, path.length - packedSuffix.length) : path];
    if (a == null) return OnLaptop.no;
    final f = File('${filesDir.path}/$path');
    try {
      if (isPackedPath(path)) {
        final info = packedInfo(f);
        return info != null && info.bytes == a.bytes && info.sha256 == a.sha256 ? OnLaptop.yes : OnLaptop.no;
      }
      final st = f.statSync();
      final same = st.type == FileSystemEntityType.file && st.size == a.bytes && st.modified.millisecondsSinceEpoch == a.modifiedMs;
      return same ? OnLaptop.yes : OnLaptop.no;
    } on FileSystemException {
      return OnLaptop.no;
    }
  }

  /// The raw files of [f32]'s set on the phone: its samples (plain or packed) and its index.
  List<File> rawFilesOf(File f32) => [
    ?rawOnDisk(plainFileOf(f32)),
    if (File('${_stemPath(f32)}.idx').existsSync()) File('${_stemPath(f32)}.idx'),
  ];

  String _relative(File f) => f.path.substring(filesDir.path.length + 1);

  @override
  String? whyNotRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now}) {
    final files = rawFilesOf(f32);
    if (files.isEmpty) return 'no raw files on the phone';
    for (final f in files) {
      try {
        if (now.difference(f.statSync().modified) < removeSettled) return 'written in the last hour';
      } on FileSystemException {
        return 'not readable now';
      }
    }
    if (onlyIfOnLaptop && !files.every((f) => onLaptop(_relative(f)) == OnLaptop.yes)) return 'not checked on the laptop yet';
    return null;
  }

  @override
  RemoveResult removeRaw(File f32, {required bool onlyIfOnLaptop, required DateTime now}) {
    try {
      final whyNot = whyNotRaw(f32, onlyIfOnLaptop: onlyIfOnLaptop, now: now);
      if (whyNot != null) return (removed: false, refused: whyNot, freedBytes: 0);
      final files = rawFilesOf(f32);
      final plain = plainFileOf(f32);
      final held = files.every((f) => onLaptop(_relative(f)) == OnLaptop.yes);
      final start = stemTime(plain.uri.pathSegments.last);
      final end = dataEndOf(plain);
      final record = {
        'format': removedFormat,
        'version': 1,
        'removed': now.toIso8601String(),
        'removed_ms': now.millisecondsSinceEpoch,
        'on_laptop': held,
        'laptop': null,
        'why': whyByHand,
        'night': start == null ? null : dateName(nightOf(start)),
        'end_ms': end?.millisecondsSinceEpoch,
        'files': [for (final f in files) _fileJson(f, plain)],
      };
      final out = removedRecordFile(f32);
      final tmp = File('${out.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(record), flush: true);
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

  Map<String, Object?> _fileJson(File f, File plain) {
    final name = f.uri.pathSegments.last;
    final phoneBytes = f.lengthSync();
    final acked = _acks?[_relative(isPackedPath(f.path) ? plain : f)];
    if (isPackedPath(f.path)) {
      final info = packedInfo(f);
      return {
        'name': plain.uri.pathSegments.last,
        'bytes': info?.bytes ?? rawLength(plain),
        'sha256': info?.sha256 ?? acked?.sha256,
        'phone_name': name,
        'phone_bytes': phoneBytes,
      };
    }
    return {'name': name, 'bytes': phoneBytes, 'sha256': acked?.sha256, 'phone_name': name, 'phone_bytes': phoneBytes};
  }

  @override
  ({DateTime? end, bool onLaptop})? removedOf(File f32) {
    if (rawOnDisk(plainFileOf(f32)) != null) return null;
    try {
      final j = jsonDecode(removedRecordFile(f32).readAsStringSync());
      if (j is! Map || j['format'] != removedFormat || j['version'] != 1) return null;
      final end = j['end_ms'];
      return (end: end is int ? DateTime.fromMillisecondsSinceEpoch(end) : null, onLaptop: j['on_laptop'] == true);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// When the data of [f32]'s set ended: its last `.idx` row, else its start plus its samples at its header's rate (the
/// nights' own rule). Null without a whole sample.
DateTime? dataEndOf(File f32) {
  final start = stemTime(plainFileOf(f32).uri.pathSegments.last);
  final size = rawLength(f32);
  if (start == null || size == 0) return null;
  final h = tryHeader(f32) ?? legacyHeader;
  final samples = size ~/ h.recordBytes;
  if (samples == 0) return null;
  return lastIndexTime(File('${_stemPath(f32)}.idx'), start) ??
      start.add(Duration(microseconds: (samples * 1e6 / h.sampleRate).round()));
}

/// The arrival time of the last batch in an `.idx` (its last row), or null when it has none or it is not plausible
/// for a set that started at [start] (before it, or a week after).
DateTime? lastIndexTime(File idx, DateTime start) {
  try {
    final len = idx.existsSync() ? idx.lengthSync() : 0;
    if (len < indexBytes) return null;
    final f = idx.openSync();
    try {
      f.setPositionSync((len ~/ indexBytes - 1) * indexBytes);
      final b = f.readSync(8);
      if (b.length < 8) return null;
      final t = b.buffer.asByteData(b.offsetInBytes, 8).getFloat64(0, Endian.little);
      if (!t.isFinite) return null;
      final at = DateTime.fromMicrosecondsSinceEpoch((t * 1e6).round());
      return !at.isBefore(start) && at.isBefore(start.add(const Duration(days: 7))) ? at : null;
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}
