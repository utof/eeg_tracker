// Raw recordings packed after a day (DECISIONS rows 540-549): `<stamp>.f32.gz` in place of `<stamp>.f32`, read as
// if it were the plain file. The owner's decision (2026-11-19): raw recordings older than one day are compressed,
// losslessly. Plain dart:io and package:crypto (already used): gzip is the codec Android ships, no new package.
//
// Every reader of a raw `.f32` on the phone goes through this file, so it opens either form:
//   rawOnDisk, rawExists     the file holding a raw file's bytes (the plain one first, else the packed one)
//   rawLength                the plain file's length without unpacking (the packed file's header holds it)
//   openRaw, readRaw         the plain file's bytes (a packed file is unpacked as it is read)
// Readers keep the plain name (`<stamp>.f32`): a sleep report's `inputs`, the nights' chaining and the `.idx`,
// `.log` and `.markers.jsonl` beside it stay as they were. Only `.f32` is packed (the bulk; the nights' chaining reads
// the last `.idx` row of every recording, often).
//
// A packed file is a standard gzip file (`gunzip -N` gives back the `.f32` with its name and time) whose header says
// what it holds: the name field the `.f32`'s name, the comment field `{"name","bytes","sha256","modified_ms"}` of the
// `.f32`. Export data and Share on Wi-Fi send the packed file as it is and name its original, so the laptop checks
// what it unpacks and never fetches a night twice because its name changed.
//
// [packRaw] writes the packed copy under a temporary name, unpacks it to check that it gives back the same bytes
// (length and SHA-256), gives it the original's modified time, puts it in place, and only then removes the original.
// [packOldRecordings] does that for every closed recording nothing has written for a day; the night screen runs it
// between nights (never while a night or a session records), one file at a time off the screen's thread.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../logs/activity.dart' show Activity;
import '../logs/app_log.dart' show AppLog;
import 'nights.dart' show stemTime;

final AppLog _appLog = AppLog('packing');

const String rawSuffix = '.f32';
const String packedSuffix = '.gz';

/// A recording nothing has written for this long is closed: it is packed.
const Duration packAfter = Duration(hours: 24);

/// Smaller files stay plain: under 13 s of signal, little to gain.
const int packMinBytes = 64 * 1024;

/// The folders of `files/` whose recordings are packed: the nights and sessions, the DIY board's, the check-ins'.
const List<String> packedFolders = ['recordings', 'recordings-diy', 'mornings'];

/// One line per packing run that did something, in the app's folder (exported with the rest, so the laptop sees
/// what the phone packed).
const String packingLogName = 'packing.jsonl';

const int _chunk = 1 << 20;
const int _gzipLevel = 6;

/// What a packed file holds: the plain file's name, length, SHA-256 and modified time.
class PackedInfo {
  const PackedInfo({required this.name, required this.bytes, required this.sha256, required this.modifiedMs});

  final String name;
  final int bytes;
  final String sha256;
  final int modifiedMs;

  Map<String, Object?> toJson() => {'name': name, 'bytes': bytes, 'sha256': sha256, 'modified_ms': modifiedMs};

  @override
  bool operator ==(Object other) =>
      other is PackedInfo &&
      other.name == name &&
      other.bytes == bytes &&
      other.sha256 == sha256 &&
      other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(name, bytes, sha256, modifiedMs);
}

/// The packed form's path of a plain `.f32`.
File packedFileOf(File plain) => File('${plain.path}$packedSuffix');

/// Whether [path] names a packed recording (`<stamp>.f32.gz`).
bool isPackedPath(String path) => path.endsWith('$rawSuffix$packedSuffix');

/// The plain name of a raw file: `<stamp>.f32` for `<stamp>.f32.gz`.
File plainFileOf(File f) => isPackedPath(f.path) ? File(f.path.substring(0, f.path.length - packedSuffix.length)) : f;

/// The file holding a raw file's bytes: the plain one, else its packed one; null when neither is there.
File? rawOnDisk(File f) {
  if (isPackedPath(f.path)) return f.existsSync() ? f : null;
  if (f.existsSync()) return f;
  final p = packedFileOf(f);
  return p.existsSync() ? p : null;
}

bool rawExists(File f) => rawOnDisk(f) != null;

final Map<String, (int, int, PackedInfo?)> _infos = {};

/// What a packed file says it holds, from its header (cached while its size and time stay); null for a gzip file
/// without it, or no gzip file.
PackedInfo? packedInfo(File gz) {
  try {
    final st = gz.statSync();
    final ms = st.modified.millisecondsSinceEpoch;
    final hit = _infos[gz.path];
    if (hit != null && hit.$1 == st.size && hit.$2 == ms) return hit.$3;
    final f = gz.openSync();
    try {
      final info = parsePackedHeader(f.readSync(4096));
      _infos[gz.path] = (st.size, ms, info);
      return info;
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

/// The plain file's length, packed or not (a packed one's from its header, else from gzip's own length field at its
/// end); 0 when neither form is there.
int rawLength(File f) {
  final d = rawOnDisk(f);
  if (d == null) return 0;
  try {
    if (!isPackedPath(d.path)) return d.lengthSync();
    return packedInfo(d)?.bytes ?? _trailerLength(d);
  } on FileSystemException {
    return 0;
  }
}

int _trailerLength(File gz) {
  final f = gz.openSync();
  try {
    final n = f.lengthSync();
    if (n < 18) return 0;
    f.setPositionSync(n - 4);
    return ByteData.sublistView(f.readSync(4)).getUint32(0, Endian.little);
  } finally {
    f.closeSync();
  }
}

/// All of the plain file's bytes, packed or not.
Uint8List readRaw(File f) {
  final d = rawOnDisk(f);
  if (d == null) throw FileSystemException('no such recording', f.path);
  final bytes = d.readAsBytesSync();
  return isPackedPath(d.path) ? Uint8List.fromList(gzip.decode(bytes)) : bytes;
}

/// Reads a raw file from a position, as [RandomAccessFile] does: the plain file's own, or a packed one unpacked as it
/// is read (forward is cheap; going back starts again from the beginning).
abstract interface class RawReader {
  void setPositionSync(int position);

  /// Up to [bytes] bytes; fewer only at the end.
  Uint8List readSync(int bytes);
  void closeSync();
}

/// Opens [f], packed or not. Throws [FileSystemException] when neither form is there.
RawReader openRaw(File f) {
  final d = rawOnDisk(f);
  if (d == null) throw FileSystemException('no such recording', f.path);
  return isPackedPath(d.path) ? _PackedReader(d) : _PlainReader(d.openSync());
}

class _PlainReader implements RawReader {
  _PlainReader(this._f);
  final RandomAccessFile _f;

  @override
  void setPositionSync(int position) => _f.setPositionSync(position);

  @override
  Uint8List readSync(int bytes) => _f.readSync(bytes);

  @override
  void closeSync() => _f.closeSync();
}

/// Unpacked bytes waiting to be read.
class _Pending implements Sink<List<int>> {
  final List<Uint8List> _parts = [];
  int _first = 0; // bytes of _parts.first already read
  int length = 0;

  @override
  void add(List<int> data) {
    if (data.isEmpty) return;
    _parts.add(data is Uint8List ? data : Uint8List.fromList(data));
    length += data.length;
  }

  @override
  void close() {}

  Uint8List take(int n) {
    final out = Uint8List(math.min(n, length));
    var at = 0;
    while (at < out.length) {
      final p = _parts.first;
      final k = math.min(out.length - at, p.length - _first);
      out.setRange(at, at + k, p, _first);
      at += k;
      _first += k;
      if (_first == p.length) {
        _parts.removeAt(0);
        _first = 0;
      }
    }
    length -= out.length;
    return out;
  }

  void clear() {
    _parts.clear();
    _first = 0;
    length = 0;
  }
}

class _PackedReader implements RawReader {
  _PackedReader(this._file) {
    _start();
  }

  final File _file;
  late RandomAccessFile _in;
  late ByteConversionSink _unpack;
  final _Pending _out = _Pending();
  int _pos = 0;
  bool _ended = false;

  void _start() {
    _in = _file.openSync();
    _out.clear();
    _unpack = gzip.decoder.startChunkedConversion(_out);
    _pos = 0;
    _ended = false;
  }

  void _fill(int n) {
    while (_out.length < n && !_ended) {
      final b = _in.readSync(_chunk);
      if (b.isEmpty) {
        _ended = true;
        _unpack.close();
      } else {
        _unpack.add(b);
      }
    }
  }

  @override
  Uint8List readSync(int bytes) {
    _fill(bytes);
    final r = _out.take(bytes);
    _pos += r.length;
    return r;
  }

  @override
  void setPositionSync(int position) {
    if (position < _pos) {
      _in.closeSync();
      _start();
    }
    while (_pos < position) {
      if (readSync(math.min(position - _pos, _chunk)).isEmpty) break;
    }
  }

  @override
  void closeSync() => _in.closeSync();
}

// ---- the packed file's header ----------------------------------------------------------------------------------

/// The gzip header of a packed file: the name and comment fields set (RFC 1952), the original's time in seconds.
Uint8List packedHeader(PackedInfo info) {
  final t = (info.modifiedMs ~/ 1000) & 0xffffffff;
  return Uint8List.fromList([
    0x1f, 0x8b, 8, 8 | 16, // magic, deflate, FNAME | FCOMMENT
    t & 0xff, (t >> 8) & 0xff, (t >> 16) & 0xff, (t >> 24) & 0xff,
    0, 3, // no extra flags, Unix
    ...latin1.encode(info.name), 0,
    ...latin1.encode(jsonEncode(info.toJson())), 0,
  ]);
}

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// What a gzip header says the file holds; null when it is not a packed file's header.
PackedInfo? parsePackedHeader(Uint8List h) {
  if (h.length < 10 || h[0] != 0x1f || h[1] != 0x8b || h[2] != 8) return null;
  final flags = h[3];
  var o = 10;
  if (flags & 4 != 0) {
    if (o + 2 > h.length) return null;
    o += 2 + (h[o] | h[o + 1] << 8);
  }
  if (flags & 8 != 0) {
    final z = h.indexOf(0, math.min(o, h.length));
    if (z < 0) return null;
    o = z + 1;
  }
  if (flags & 16 == 0 || o >= h.length) return null;
  final z = h.indexOf(0, o);
  if (z < 0) return null;
  try {
    final j = jsonDecode(latin1.decode(h.sublist(o, z)));
    if (j is! Map) return null;
    final name = j['name'], bytes = j['bytes'], sha = j['sha256'], ms = j['modified_ms'];
    if (name is! String || bytes is! int || bytes < 0 || sha is! String || !_hex64.hasMatch(sha) || ms is! int) {
      return null;
    }
    return PackedInfo(name: name, bytes: bytes, sha256: sha, modifiedMs: ms);
  } on FormatException {
    return null;
  }
}

// ---- packing ---------------------------------------------------------------------------------------------------

/// A file was not packed; it stays as it was.
class PackFailure implements Exception {
  const PackFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// What packing one file did.
class PackedFile {
  const PackedFile(this.packed, this.info, this.packedBytes);
  final File packed;
  final PackedInfo info;
  final int packedBytes;
}

/// Where [packRaw] writes before the check: hidden, ending in `.tmp` (never exported, never taken for a recording).
File packingTempOf(File plain) {
  final name = plain.uri.pathSegments.last;
  return File('${plain.parent.path}/.$name$packedSuffix.packing.tmp');
}

/// Writes to a file, dropping the 10-byte header zlib starts with and writing [header] in its place.
class _HeaderSwap implements Sink<List<int>> {
  _HeaderSwap(this._out, this._header);
  final RandomAccessFile _out;
  final Uint8List _header;
  final List<int> _head = [];
  bool _swapped = false;
  int written = 0;

  @override
  void add(List<int> data) {
    if (_swapped) {
      _out.writeFromSync(data);
      written += data.length;
      return;
    }
    _head.addAll(data);
    if (_head.length < 10) return;
    if (_head[0] != 0x1f || _head[1] != 0x8b || _head[2] != 8 || _head[3] != 0) {
      throw const PackFailure('gzip wrote an unexpected header');
    }
    _out.writeFromSync(_header);
    _out.writeFromSync(_head, 10);
    written += _header.length + _head.length - 10;
    _head.clear();
    _swapped = true;
  }

  @override
  void close() {
    if (!_swapped) throw const PackFailure('gzip wrote nothing');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Length and SHA-256 of what a packed file unpacks to (gzip checks its own CRC on the way).
({int bytes, String sha256}) unpackedDigest(File gz) {
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  final r = _PackedReader(gz); // by its content, whatever its name (the copy is checked under a temporary one)
  var n = 0;
  try {
    while (true) {
      final b = r.readSync(_chunk);
      if (b.isEmpty) break;
      hash.add(b);
      n += b.length;
    }
  } finally {
    r.closeSync();
  }
  hash.close();
  return (bytes: n, sha256: digest.value.toString());
}

bool _same(File f, FileStat st) {
  try {
    final now = f.statSync();
    return now.type == FileSystemEntityType.file && now.size == st.size && now.modified == st.modified;
  } on FileSystemException {
    return false;
  }
}

/// Packs one raw file nothing writes any more. Throws [PackFailure] (the original untouched, nothing left behind)
/// when it changed while it was read or the packed copy does not give back the same bytes. Synchronous: run it off
/// the screen's thread. One read of the original: the header's SHA-256 has a fixed length, so it is written as zeros
/// first and filled in once the file has been read.
/// [beforeCheck] runs between writing the copy and checking it (tests: a crash, a write, a damaged copy).
PackedFile packRaw(File plain, {void Function(File copy)? beforeCheck}) {
  final st = plain.statSync();
  final name = plain.uri.pathSegments.last;
  final dst = packedFileOf(plain), tmp = packingTempOf(plain);
  final blank = '0' * 64;
  final header = packedHeader(
    PackedInfo(name: name, bytes: st.size, sha256: blank, modifiedMs: st.modified.millisecondsSinceEpoch),
  );
  final shaAt = latin1.decode(header).indexOf(blank);
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  try {
    final out = tmp.openSync(mode: FileMode.write);
    var n = 0;
    try {
      final pack = ZLibEncoder(gzip: true, level: _gzipLevel).startChunkedConversion(_HeaderSwap(out, header));
      final input = plain.openSync();
      try {
        while (true) {
          final b = input.readSync(_chunk);
          if (b.isEmpty) break;
          n += b.length;
          hash.add(b);
          pack.add(b);
        }
      } finally {
        input.closeSync();
      }
      pack.close();
      hash.close();
      out.setPositionSync(shaAt);
      out.writeFromSync(latin1.encode(digest.value.toString()));
      out.flushSync();
    } finally {
      out.closeSync();
    }
    final info = PackedInfo(
      name: name,
      bytes: st.size,
      sha256: digest.value.toString(),
      modifiedMs: st.modified.millisecondsSinceEpoch,
    );
    beforeCheck?.call(tmp);
    if (n != st.size || !_same(plain, st)) throw PackFailure('$name changed while it was packed; left as it was');
    final ({int bytes, String sha256}) back;
    try {
      back = unpackedDigest(tmp);
    } on Object catch (e) {
      throw PackFailure('the packed copy of $name does not unpack ($e); left as it was');
    }
    if (back.bytes != info.bytes || back.sha256 != info.sha256 || packedInfo(tmp) != info) {
      throw PackFailure('the packed copy of $name does not give back the same bytes; left as it was');
    }
    try {
      tmp.setLastModifiedSync(st.modified);
    } on FileSystemException {
      // the header keeps the original's time; the file's own is only a convenience
    }
    tmp.renameSync(dst.path);
    if (!_same(plain, st)) {
      dst.deleteSync();
      throw PackFailure('$name changed while it was packed; left as it was');
    }
    plain.deleteSync();
    return PackedFile(dst, info, dst.lengthSync());
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } on FileSystemException {
      // nothing more to do; the next run removes it
    }
    rethrow;
  }
}

/// A plain file whose packed copy is already there (a run stopped between putting the copy in place and removing the
/// original): when the copy unpacks to the same bytes the original goes and the copy is returned; otherwise the copy
/// (ours, and wrong) goes and null is returned, so the file is packed again.
PackedFile? finishPacking(File plain) {
  final dst = packedFileOf(plain);
  final st = plain.statSync();
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  final f = plain.openSync();
  try {
    while (true) {
      final b = f.readSync(_chunk);
      if (b.isEmpty) break;
      hash.add(b);
    }
  } finally {
    f.closeSync();
  }
  hash.close();
  ({int bytes, String sha256})? back;
  try {
    back = unpackedDigest(dst);
  } on Object {
    back = null;
  }
  final info = packedInfo(dst);
  if (back != null && back.bytes == st.size && back.sha256 == digest.value.toString() && info != null &&
      info.sha256 == back.sha256 && _same(plain, st)) {
    plain.deleteSync();
    return PackedFile(dst, info, dst.lengthSync());
  }
  dst.deleteSync();
  return null;
}

/// The closed recordings to pack in [filesDir]: `<stamp>.f32` in [packedFolders] of at least [packMinBytes] that
/// nothing has written for [age].
List<File> packCandidates(Directory filesDir, DateTime now, {Duration age = packAfter}) {
  final out = <File>[];
  for (final folder in packedFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith(rawSuffix) || stemTime(name) == null) continue;
      try {
        final st = f.statSync();
        if (st.type == FileSystemEntityType.file && st.size >= packMinBytes && now.difference(st.modified) >= age) {
          out.add(f);
        }
      } on FileSystemException {
        continue;
      }
    }
  }
  return out..sort((a, b) => a.path.compareTo(b.path));
}

/// Temporary files of a run that was stopped (packRaw removes its own otherwise). Only between runs.
void removePackingLeftovers(Directory filesDir) {
  for (final folder in packedFolders) {
    final dir = Directory('${filesDir.path}/$folder');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.startsWith('.') && name.endsWith('$rawSuffix$packedSuffix.packing.tmp')) {
        try {
          f.deleteSync();
        } on FileSystemException {
          continue;
        }
      }
    }
  }
}

/// One packing run's outcome.
class PackRun {
  final List<PackedFile> packed = [];
  final List<(File, String)> failed = [];
  int left = 0; // candidates not reached (stopped)

  int get bytes => packed.fold(0, (n, p) => n + p.info.bytes);
  int get packedBytes => packed.fold(0, (n, p) => n + p.packedBytes);
}

/// Packs one candidate (finishing a half-done one first). Synchronous; for an isolate.
PackedFile packOne(String path) {
  final plain = File(path);
  if (packedFileOf(plain).existsSync()) {
    final done = finishPacking(plain);
    if (done != null) return done;
  }
  return packRaw(plain);
}

/// [packOne] in a background isolate (a top-level function: the closure carries the path alone).
Future<PackedFile> packInBackground(String path) => Isolate.run(() => packOne(path), debugName: 'pack-recording');

/// Packs the closed recordings older than [packAfter] in [filesDir], one file at a time through [pack] (an isolate
/// on the phone), asking [busy] before each: it stops as soon as a sleep stretch or a session records. [open]: the
/// plain `.f32` paths of the sets being written, which are left alone. Appends a line to
/// `files/packing.jsonl` when it packed something or failed. Never throws.
Future<PackRun> packOldRecordings(
  Directory filesDir, {
  required Future<bool> Function() busy,
  required Future<PackedFile> Function(String path) pack,
  DateTime Function() clock = DateTime.now,
  Set<String> open = const {},
}) async {
  final run = PackRun();
  var marked = false;
  try {
    if (await busy()) return run;
    removePackingLeftovers(filesDir);
    // never the set a recording writes (storage/open_sets.dart, DECISIONS 1039), whatever its age says
    final todo = [for (final f in packCandidates(filesDir, clock())) if (!open.contains(f.path)) f];
    if (todo.isNotEmpty) {
      Activity.begin('packing'); // the battery samples (lib/logs, DECISIONS 715)
      marked = true;
    }
    for (var k = 0; k < todo.length; k++) {
      if (await busy()) {
        run.left = todo.length - k;
        break;
      }
      try {
        run.packed.add(await pack(todo[k].path));
      } on Object catch (e) {
        run.failed.add((todo[k], '$e'));
      }
    }
    if (run.packed.isNotEmpty || run.failed.isNotEmpty) _log(filesDir, run, clock());
  } on Object catch (e) {
    run.failed.add((File(filesDir.path), '$e'));
  } finally {
    if (marked) {
      Activity.end('packing');
      _appLog.info('packed ${run.packed.length} recordings, ${run.failed.length} failed, ${run.left} left', {
        'bytes': run.bytes,
        'packed_bytes': run.packedBytes,
        if (run.failed.isNotEmpty) 'problems': [for (final (_, why) in run.failed) why],
      });
    }
  }
  return run;
}

void _log(Directory filesDir, PackRun run, DateTime at) {
  final base = filesDir.path.length + 1;
  String rel(File f) => f.path.length > base ? f.path.substring(base) : f.path;
  final line = {
    'packed': at.toIso8601String(),
    'files': run.packed.length,
    'bytes': run.bytes,
    'packed_bytes': run.packedBytes,
    'failed': run.failed.length,
    'list': [
      for (final p in run.packed)
        {'path': rel(p.packed), 'bytes': p.info.bytes, 'packed_bytes': p.packedBytes, 'sha256': p.info.sha256},
    ],
    'problems': [
      for (final (f, why) in run.failed) {'path': rel(f), 'why': why},
    ],
  };
  try {
    File('${filesDir.path}/$packingLogName').writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // the files are packed and checked; only the note is missing
  }
}
