// The check just before the phone deletes a raw recording by itself (DECISIONS 756; the security review of 2026-11-20).
//
// An ack (acks.dart) says the laptop held a file's bytes when it acked. Before the Storage page's keep time deletes a
// file, the phone asks again, so that a laptop that lost its copy since (a failing disk, a deleted folder) or someone
// who only holds the pairing's key and the hashes the phone lists cannot make it delete:
// - the app ([RecheckStore.ask], from storage/clear.dart `autoClear`) writes one question per file into
//   `files/transfer/recheck.json`: a fresh nonce and random byte ranges ([pickRanges]) of the file's plain bytes (a
//   packed `.f32.gz` by what it unpacks to, as the laptop holds it);
// - the paired laptop reads them (`GET /recheck`, signed: share/server.dart) and answers with an HMAC over those bytes of
//   its OWN copy (`POST /recheck`; auth.dart `recheckMac`, scripts/pull_phone.py `answer_rechecks`);
// - the server works the same HMAC out from the phone's bytes and keeps the outcome in `files/transfer/proofs.json`
//   ([RecheckStore.prove]). A file with an open question is not handed out (409), so the answer cannot be made from the
//   phone's own copy. A laptop that says it does not hold the file, or answers with other bytes, loses the file's ack:
//   nothing is deleted on it, and the laptop copies and acks it again;
// - `autoClear` deletes only files with a proof made in the last [recheckFresh]; any other is asked about again.
//
// `transfer/` never leaves the phone. Plain dart:io: it runs in the share server's isolate, the screen's and tests.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'acks.dart';
import 'packed.dart' show openRaw, rawLength, rawOnDisk;

/// How long a proof counts for deleting: the laptop proves it "right then".
const Duration recheckFresh = Duration(minutes: 15);

/// A question nobody answered is asked again (a new nonce and ranges) after this long.
const Duration recheckAskLife = Duration(hours: 24);

/// Ranges asked about in a file bigger than [_wholeUpTo], each this long.
const int recheckRanges = 8, recheckRangeBytes = 4096;
const int _wholeUpTo = recheckRanges * recheckRangeBytes;

const String _asksFormat = 'eeg-tracker-recheck', _proofsFormat = 'eeg-tracker-proofs';

/// Where in a file of [size] bytes to ask: all of it up to 32 KB, else 8 ranges of 4 KB, one at a random place in
/// each eighth of the file: spread over all of it, in order, never overlapping (the laptop reads them in one pass).
List<(int, int)> pickRanges(int size, Random random) {
  if (size <= _wholeUpTo) return [(0, size)];
  final part = size ~/ recheckRanges;
  return [
    for (var i = 0; i < recheckRanges; i++)
      (i * part + _below((i == recheckRanges - 1 ? size - i * part : part) - recheckRangeBytes + 1, random), recheckRangeBytes),
  ];
}

/// A random int in [0, n), also for n over 2^32 (Random.nextInt stops there).
int _below(int n, Random r) => n <= (1 << 32) ? r.nextInt(n) : ((r.nextInt(1 << 30) << 32) | r.nextInt(1 << 32)) % n;

/// One question to the laptop about one file (its plain path, as acks are kept).
class RecheckAsk {
  const RecheckAsk({required this.path, required this.nonce, required this.ranges, required this.bytes, required this.sha256, required this.askedMs});
  final String path;
  final String nonce;
  final List<(int, int)> ranges;

  /// The plain file's length and SHA-256 (the ack's), so the laptop knows which bytes are meant.
  final int bytes;
  final String sha256;
  final int askedMs;

  Map<String, Object?> toJson() => {
    'path': path,
    'nonce': nonce,
    'ranges': [for (final r in ranges) [r.$1, r.$2]],
    'bytes': bytes,
    'sha256': sha256,
    'asked_ms': askedMs,
  };

  static RecheckAsk? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['path'], n = j['nonce'], r = j['ranges'], b = j['bytes'], s = j['sha256'], a = j['asked_ms'];
    if (p is! String || n is! String || r is! List || b is! int || s is! String || a is! int) return null;
    final ranges = <(int, int)>[];
    for (final x in r) {
      if (x is! List || x.length != 2 || x[0] is! int || x[1] is! int) return null;
      ranges.add((x[0] as int, x[1] as int));
    }
    return RecheckAsk(path: p, nonce: n, ranges: ranges, bytes: b, sha256: s, askedMs: a);
  }
}

/// The outcome of one question: [ok] the laptop proved the bytes; else [why] not.
typedef RecheckProof = ({String nonce, bool ok, String? why, int atMs});

/// `files/transfer/recheck.json` (the app's questions) and `files/transfer/proofs.json` (the server's outcomes).
class RecheckStore {
  RecheckStore(this.filesDir);
  final Directory filesDir;

  File get _asks => File('${filesDir.path}/$transferFolder/recheck.json');
  File get _proofs => File('${filesDir.path}/$transferFolder/proofs.json');

  Map<String, RecheckAsk> asks() {
    try {
      final j = jsonDecode(_asks.readAsStringSync());
      if (j is! Map || j['format'] != _asksFormat || j['asks'] is! Map) return {};
      final out = <String, RecheckAsk>{};
      for (final e in (j['asks'] as Map).entries) {
        final a = RecheckAsk.fromJson(e.value);
        if (e.key is String && a != null) out[e.key as String] = a;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Map<String, RecheckProof> proofs() {
    try {
      final j = jsonDecode(_proofs.readAsStringSync());
      if (j is! Map || j['format'] != _proofsFormat || j['proofs'] is! Map) return {};
      final out = <String, RecheckProof>{};
      for (final e in (j['proofs'] as Map).entries) {
        final v = e.value;
        if (e.key is! String || v is! Map || v['nonce'] is! String || v['ok'] is! bool || v['at_ms'] is! int) continue;
        out[e.key as String] = (nonce: v['nonce'] as String, ok: v['ok'] as bool, why: v['why'] as String?, atMs: v['at_ms'] as int);
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// The questions not answered yet (no outcome with their nonce).
  Map<String, RecheckAsk> open() {
    final p = proofs();
    return {
      for (final e in asks().entries)
        if (p[e.key]?.nonce != e.value.nonce) e.key: e.value,
    };
  }

  /// Asks about [paths] (plain paths of acked files): a new question for each that has none, one older than
  /// [recheckAskLife], or one whose answer is already used up (stale or failed). Returns the questions asked now.
  List<RecheckAsk> ask(Iterable<String> paths, {required DateTime now, Random? random}) {
    final r = random ?? Random.secure();
    final all = asks(), done = proofs(), acks = AckStore(filesDir).load();
    final made = <RecheckAsk>[];
    for (final path in paths) {
      final had = all[path], outcome = done[path];
      final answered = had != null && outcome?.nonce == had.nonce;
      final fresh = answered && outcome!.ok && now.millisecondsSinceEpoch - outcome.atMs < recheckFresh.inMilliseconds;
      final waiting = had != null && !answered && now.millisecondsSinceEpoch - had.askedMs < recheckAskLife.inMilliseconds;
      if (fresh || waiting) continue;
      final copy = acks[path];
      if (copy == null) continue; // not acked (any more): nothing to delete, nothing to ask
      final bytes = copy.bytes;
      final q = RecheckAsk(
        path: path,
        nonce: base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', ''),
        ranges: pickRanges(bytes, r),
        bytes: bytes,
        sha256: copy.sha256,
        askedMs: now.millisecondsSinceEpoch,
      );
      all[path] = q;
      made.add(q);
    }
    if (made.isNotEmpty) _write(_asks, {'format': _asksFormat, 'version': 1, 'asks': {for (final e in all.entries) e.key: e.value.toJson()}});
    return made;
  }

  /// Whether [path] has a proof made in the last [recheckFresh] for its current question.
  bool proven(String path, DateTime now) {
    final a = asks()[path], p = proofs()[path];
    return a != null && p != null && p.nonce == a.nonce && p.ok && now.millisecondsSinceEpoch - p.atMs < recheckFresh.inMilliseconds;
  }

  /// Keeps the outcome of the question about [path] with [nonce] (the server; one writer at a time).
  void prove(String path, String nonce, {required bool ok, required String? why, required DateTime at}) {
    final all = proofs();
    all[path] = (nonce: nonce, ok: ok, why: why, atMs: at.millisecondsSinceEpoch);
    _write(_proofs, {
      'format': _proofsFormat,
      'version': 1,
      'proofs': {
        for (final e in all.entries) e.key: {'nonce': e.value.nonce, 'ok': e.value.ok, 'why': e.value.why, 'at_ms': e.value.atMs},
      },
    });
  }

  /// Forgets the questions and outcomes of [paths] (deleted, or no longer acked).
  void forget(Iterable<String> paths) {
    final gone = paths.toSet();
    final a = asks(), p = proofs();
    if (a.keys.any(gone.contains)) {
      a.removeWhere((k, _) => gone.contains(k));
      _write(_asks, {'format': _asksFormat, 'version': 1, 'asks': {for (final e in a.entries) e.key: e.value.toJson()}});
    }
    if (p.keys.any(gone.contains)) {
      p.removeWhere((k, _) => gone.contains(k));
      _write(_proofs, {
        'format': _proofsFormat,
        'version': 1,
        'proofs': {for (final e in p.entries) e.key: {'nonce': e.value.nonce, 'ok': e.value.ok, 'why': e.value.why, 'at_ms': e.value.atMs}},
      });
    }
  }

  void _write(File f, Object data) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.${identityHashCode(this)}.tmp');
    tmp.writeAsStringSync(jsonEncode(data), flush: true);
    tmp.renameSync(f.path);
  }
}

/// The bytes of [ask]'s ranges in the phone's own file (packed or not: its plain bytes), in order; null when the
/// file is not there or no longer holds the acked bytes (another length).
List<Uint8List>? phoneRanges(Directory filesDir, RecheckAsk ask) {
  final file = File('${filesDir.path}/${ask.path}');
  final isRaw = ask.path.endsWith('.f32');
  try {
    if (isRaw ? rawOnDisk(file) == null : !file.existsSync()) return null;
    if ((isRaw ? rawLength(file) : file.lengthSync()) != ask.bytes) return null;
    if (isRaw) {
      final r = openRaw(file);
      try {
        return [
          for (final (s, n) in ask.ranges) ...[
            () {
              r.setPositionSync(s);
              return r.readSync(n);
            }(),
          ],
        ];
      } finally {
        r.closeSync();
      }
    }
    final f = file.openSync();
    try {
      return [
        for (final (s, n) in ask.ranges) ...[
          () {
            f.setPositionSync(s);
            return f.readSync(n);
          }(),
        ],
      ];
    } finally {
      f.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}
