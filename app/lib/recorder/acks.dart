// The laptop's checked copies of the phone's files (DECISIONS 690-699): what the paired laptop said it holds, byte for
// byte.
//
// After the laptop has copied a file and hashed its copy on its own disk again, it tells the phone so (`POST /ack`,
// share/server.dart; scripts/pull_phone.py): the file's path and the SHA-256 of what it holds (the plain `.f32`'s for
// a recording the phone packed after a day). The phone keeps each one that matches its own file in
// `files/transfer/acks.json`, under the plain name (`recordings/<stamp>.f32`, `recordings/<stamp>.idx`,
// `nights/<date>.report.json`), with the size and modified time the file had then. A later look trusts an ack only while the file still holds those bytes:
// a plain file by its size and modified time, a packed one by its header's length and SHA-256 (packed.dart), so an
// ack outlives the packing. The acks are kept whether or not the owner lets the phone delete anything (the Storage
// page, storage/; remove.dart), so switching that on later works at once; Share on Wi-Fi's list marks each acked file (`acked: true`), and a laptop
// that lost its own notes acks it again without reading it twice. `transfer/` never leaves the phone (export/store.dart).
//
// Plain dart:io: it runs in the share server's isolate, the screen's and tests.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../export/store.dart' show isExported;
import 'packed.dart' show isPackedPath, packedInfo, packedSuffix;

/// The folders of `files/` that hold raw recordings: the nights and sessions, the DIY board's, the check-ins'.
const List<String> movableFolders = ['recordings', 'recordings-diy', 'mornings'];

/// `files/transfer/`: the acks and the Storage page's settings (storage/storage.dart); never exported or shared.
const String transferFolder = 'transfer';

const String acksFormat = 'eeg-tracker-acks';
const String _ackTag = 'eeg-tracker ack v1';

/// A file changed this recently is still being written: never acked (the share list's own rule).
const Duration ackSettled = Duration(seconds: 20);

final RegExp _sha = RegExp(r'^[0-9a-f]{64}$');
final RegExp _rawName = RegExp(r'^\d{4}-\d{2}-\d{2}-\d{6}\.(f32|f32\.gz|idx)$');

/// The proof the paired laptop sends with `POST /ack`: HMAC-SHA256 of `eeg-tracker ack v1|` and the request's body,
/// keyed with the key of the pairing (link.dart), in hex. scripts/pull_phone.py computes the same
/// (app/test/fixtures/phone_ack.json).
String ackProof(String key, List<int> body) =>
    Hmac(sha256, utf8.encode(key)).convert([...utf8.encode('$_ackTag|'), ...body]).toString();

bool isSha256(Object? v) => v is String && _sha.hasMatch(v);

/// A file the laptop may ack: any file Share on Wi-Fi lists (export/store.dart's rule), raw recordings and everything
/// else the Storage page can delete (storage/storage.dart).
bool isAckable(String path) => isExported(path);

/// A raw recording's samples or index: `<folder>/<stamp>.f32`, `.f32.gz` or `.idx`.
bool isRawPath(String path) {
  final parts = path.split('/');
  return parts.length == 2 && _rawName.hasMatch(parts.last);
}

/// The name an ack is kept under: the plain `.f32` for its packed form.
String ackPathOf(String path) => isPackedPath(path) ? path.substring(0, path.length - packedSuffix.length) : path;

/// One checked copy on the laptop.
class LaptopCopy {
  const LaptopCopy({required this.sha256, required this.bytes, required this.modifiedMs, required this.ackedMs});

  /// The plain file's SHA-256 and length (a packed file's original).
  final String sha256;
  final int bytes;

  /// The phone file's modified time when it was acked (a packed one's header keeps the plain file's).
  final int modifiedMs;
  final int ackedMs;

  Map<String, Object?> toJson() => {'sha256': sha256, 'bytes': bytes, 'modified_ms': modifiedMs, 'acked_ms': ackedMs};

  static LaptopCopy? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['sha256'], b = j['bytes'], m = j['modified_ms'], a = j['acked_ms'];
    if (!isSha256(s) || b is! int || b < 0 || m is! int || a is! int) return null;
    return LaptopCopy(sha256: s as String, bytes: b, modifiedMs: m, ackedMs: a);
  }

  /// Whether the phone's [file] (`.f32`, `.f32.gz` or `.idx`) still holds the bytes this copy was checked against.
  bool matches(File file) {
    try {
      if (isPackedPath(file.path)) {
        final info = packedInfo(file);
        return info != null && info.bytes == bytes && info.sha256 == sha256;
      }
      final st = file.statSync();
      return st.type == FileSystemEntityType.file && st.size == bytes && st.modified.millisecondsSinceEpoch == modifiedMs;
    } on FileSystemException {
      return false;
    }
  }
}

/// `files/transfer/acks.json`: plain path -> the laptop's checked copy. Written by the share server only (one at a
/// time: the app's or the night recorder's), read by everyone.
class AckStore {
  AckStore(Directory filesDir) : file = File('${filesDir.path}/$transferFolder/acks.json');
  final File file;

  /// The acks; a missing or damaged file holds none (then nothing is deleted until the laptop acks again: safe).
  Map<String, LaptopCopy> load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map || j['format'] != acksFormat || j['files'] is! Map) return {};
      final out = <String, LaptopCopy>{};
      for (final e in (j['files'] as Map).entries) {
        final copy = LaptopCopy.fromJson(e.value);
        if (e.key is String && isAckable(e.key as String) && copy != null) out[e.key as String] = copy;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Adds [more] (replacing older acks of the same files; an ack of the same bytes keeps its first time, which the
  /// Storage page's keep time counts from) and writes the file whole (a temporary file, then a rename).
  void add(Map<String, LaptopCopy> more) {
    if (more.isEmpty) return;
    final all = load();
    for (final e in more.entries) {
      final had = all[e.key], c = e.value;
      all[e.key] = had != null && had.sha256 == c.sha256 && had.bytes == c.bytes
          ? LaptopCopy(sha256: c.sha256, bytes: c.bytes, modifiedMs: c.modifiedMs, ackedMs: had.ackedMs)
          : c;
    }
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.$pid.${identityHashCode(this)}.tmp');
    final keys = all.keys.toList()..sort();
    tmp.writeAsStringSync(
      jsonEncode({
        'format': acksFormat,
        'version': 1,
        'files': {for (final k in keys) k: all[k]!.toJson()},
      }),
      flush: true,
    );
    tmp.renameSync(file.path);
  }
}

/// Whether the laptop holds a checked copy of the phone's raw [file] (relative [path] in `files/`) as it is now.
bool ackedNow(Map<String, LaptopCopy> acks, String path, File file) => acks[ackPathOf(path)]?.matches(file) ?? false;

/// What the laptop's ack of [path] with [sha] gives: the copy to keep, or why it is refused. [plainSha] works out a
/// plain file's SHA-256 (the share server's, from its kept list when the file has not changed); null: unreadable now.
Future<({LaptopCopy? copy, String? why})> checkAck(
  Directory filesDir,
  String path,
  String sha, {
  required DateTime now,
  required Future<String?> Function(File file, FileStat st) plainSha,
}) async {
  if (!isAckable(path)) return (copy: null, why: 'not a file the phone shares');
  if (!isSha256(sha)) return (copy: null, why: 'not a SHA-256');
  final file = File('${filesDir.path}/$path');
  final FileStat st;
  try {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
      return (copy: null, why: 'not on the phone');
    }
    st = file.statSync();
  } on FileSystemException {
    return (copy: null, why: 'not on the phone');
  }
  final ms = st.modified.millisecondsSinceEpoch;
  if (now.millisecondsSinceEpoch - ms < ackSettled.inMilliseconds) return (copy: null, why: 'still being written');
  final at = now.millisecondsSinceEpoch;
  if (isPackedPath(path)) {
    final info = packedInfo(file); // checked when it was packed: it unpacks to these bytes
    if (info == null) return (copy: null, why: 'not readable now');
    if (info.sha256 != sha) return (copy: null, why: 'different bytes');
    return (copy: LaptopCopy(sha256: sha, bytes: info.bytes, modifiedMs: info.modifiedMs, ackedMs: at), why: null);
  }
  final mine = await plainSha(file, st);
  if (mine == null) return (copy: null, why: 'not readable now');
  if (mine != sha) return (copy: null, why: 'different bytes');
  return (copy: LaptopCopy(sha256: sha, bytes: st.size, modifiedMs: ms, ackedMs: at), why: null);
}
