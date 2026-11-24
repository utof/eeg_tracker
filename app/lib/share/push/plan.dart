// What a push sends (DECISIONS 840-849): the laptop says which bytes it lacks; the phone checks every wish against
// its own list before it reads a byte, and cuts the rest into chunks. Plain Dart.
import 'dart:io';

import '../protocol.dart';

/// One file the laptop wants: bytes [from] onward of [path], of which it already holds [have] from a cut-off push.
typedef PushWant = ({String path, int from, int have});

/// One request: [length] bytes of [path] starting at [at].
typedef PushChunk = ({String path, int at, int length});

/// The laptop takes chunks up to this size; the phone never reads more than this into memory at once.
const int pushChunkMax = 4 * 1024 * 1024;

/// The path -> bytes of the phone's own list (the `files` of its /files answer).
Map<String, int> listedBytes(Map<String, Object?> list) => {
  for (final f in list['files'] as List? ?? const [])
    if (f is Map && f['path'] is String && f['bytes'] is int) f['path'] as String: f['bytes'] as int,
};

/// The laptop's wishes that the phone may fill: only files of its own list ([listed]), only bytes inside their listed
/// size, each path once, never a file the phone is asking the laptop about before deleting it ([held]: it must prove
/// that from its own copy, DECISIONS 756). Anything else in the answer is left out.
List<PushWant> usableWants(Object? want, Map<String, int> listed, {Set<String> held = const {}}) {
  final out = <PushWant>[];
  final seen = <String>{};
  if (want is! List) return out;
  for (final w in want) {
    if (w is! Map) continue;
    final path = w['path'], from = w['from'], have = w['have'];
    if (path is! String || from is! int || have is! int) continue;
    final bytes = listed[path];
    if (bytes == null || from < 0 || have < 0 || from + have >= bytes) continue; // not listed, or nothing left to send
    if (held.contains(path) || !seen.add(path)) continue;
    out.add((path: path, from: from, have: have));
  }
  return out;
}

/// The chunks of [w], in order, up to the file's listed size [bytes].
Iterable<PushChunk> chunksOf(PushWant w, int bytes, {int max = pushChunkMax}) sync* {
  final step = max < 1 ? pushChunkMax : (max > pushChunkMax ? pushChunkMax : max);
  for (var at = w.from + w.have; at < bytes; at += step) {
    yield (path: w.path, at: at, length: bytes - at < step ? bytes - at : step);
  }
}

/// Where the laptop may be: where its signed requests last came from ([learned]), then where it was at pairing
/// ([paired]); only addresses inside one of the phone's Wi-Fi networks [wifi], each once. A push never leaves the
/// Wi-Fi the phone is on.
List<String> laptopCandidates(String? learned, String? paired, List<LanNet> wifi) {
  final out = <String>[];
  for (final a in [learned, paired]) {
    if (a == null || out.contains(a)) continue;
    final ip = InternetAddress.tryParse(a);
    if (ip != null && ip.type == InternetAddressType.IPv4 && wifi.any((n) => inLan(ip, n))) out.add(a);
  }
  return out;
}

/// Every other address of the phone's Wi-Fi network [net] (a home router's /24, or smaller); empty for a bigger one.
List<String> sweepAddresses(LanNet net, {Set<String> skip = const {}}) {
  if (net.prefix < 24 || net.prefix > 30) return const [];
  final b = net.address.rawAddress;
  if (b.length != 4) return const [];
  final v = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  final mask = (0xffffffff << (32 - net.prefix)) & 0xffffffff;
  final base = v & mask, last = base | (~mask & 0xffffffff);
  final out = <String>[];
  for (var a = base + 1; a < last; a++) {
    if (a == v) continue;
    final text = '${(a >> 24) & 255}.${(a >> 16) & 255}.${(a >> 8) & 255}.${a & 255}';
    if (!skip.contains(text)) out.add(text);
  }
  return out;
}
