// Pairing with a laptop by one scan (DECISIONS rows 530-539, 750-759; scripts/phone_link.py; docs/phone-link.md).
//
// The laptop shows a QR code; the phone's camera opens its page, whose script reads the one-time code from the link's
// `#` part (a browser never sends that part over the network) and opens this app with
// `eegtracker://pair?h=<laptop>&p=<port>&s=<one-time code>&n=<name>`. On Connect the app checks that the laptop knows
// the code (an HMAC over the app's own random nonce, so the code never travels), proves that it knows it too, and
// sends its Share on Wi-Fi port. Both sides then work out the same key from the code and the two nonces (auth.dart),
// so the key never crosses the Wi-Fi either; the laptop's last answer proves it holds the same key. Nothing secret is
// sent: not the code, not the key, not the token.
//
// After the pairing the laptop finds the phone and signs every request with that key (server.dart); the phone tells
// the laptop nothing by itself, and the laptop listens on the Wi-Fi only while a code is shown (DECISIONS 750-751).
//
// Plain dart:io with no Flutter import: it runs in the share isolate, and in tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'auth.dart';

const String linkScheme = 'eegtracker';

/// The pairing's version: 2 derives the key on both sides (DECISIONS 753). A version-1 pairing sent its key over the
/// Wi-Fi and is not used any more: one new scan replaces it.
const int linkVersion = 2;

/// The answer a laptop may give is small; anything longer is not the laptop.
const int _maxAnswer = 16 * 1024;

/// A laptop's address in a link: a private IPv4 address (10.x, 172.16-31.x, 192.168.x, 169.254.x) or this phone
/// itself. Never a name (no DNS) and never an internet address.
bool isLaptopAddress(String host) {
  final a = InternetAddress.tryParse(host);
  if (a == null || a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 127 ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254);
}

/// A laptop's name as shown: letters, digits, space, dot, dash and underscore, at most 40.
String laptopName(Object? raw) {
  if (raw is! String) return 'laptop';
  final clean = raw.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '').trim();
  final cut = clean.length > 40 ? clean.substring(0, 40).trim() : clean;
  return cut.isEmpty ? 'laptop' : cut;
}

/// What the laptop's QR code (through its page) asks the app to do.
class PairLink {
  const PairLink({required this.host, required this.port, required this.code, required this.name});
  final String host;
  final int port;

  /// The one-time code: 16-64 URL-safe characters (the laptop makes 22, 128 bits).
  final String code;
  final String name;

  /// `eegtracker://pair?h=192.168.1.10&p=8771&s=<code>&n=<name>`; null for anything else.
  static PairLink? parse(String? raw) {
    if (raw == null || raw.length > 512) return null;
    final Uri u;
    try {
      u = Uri.parse(raw.trim());
    } on FormatException {
      return null;
    }
    if (u.scheme != linkScheme || u.host != 'pair') return null;
    final q = u.queryParameters;
    final host = q['h'] ?? '', code = q['s'] ?? '';
    final port = int.tryParse(q['p'] ?? '');
    if (!isLaptopAddress(host) || port == null || port < 1024 || port > 65535 || !nonceShape.hasMatch(code)) {
      return null;
    }
    return PairLink(host: host, port: port, code: code, name: laptopName(q['n']));
  }
}

/// The laptop this phone is paired with: where it was at pairing, its name, and the key they both worked out.
class PairedLaptop {
  const PairedLaptop({required this.host, required this.port, required this.key, required this.name, this.pairedAtMs = 0});
  final String host;
  final int port;
  final String key;
  final String name;
  final int pairedAtMs;

  Map<String, Object?> toJson() => {'v': linkVersion, 'host': host, 'port': port, 'key': key, 'name': name, 'paired_at_ms': pairedAtMs};

  /// A version-2 pairing only: an older one (its key crossed the Wi-Fi) reads as none ([oldPairingName] says whose).
  static PairedLaptop? fromJson(Object? j) {
    if (j is! Map || j['v'] != linkVersion) return null;
    final h = j['host'], p = j['port'], k = j['key'], t = j['paired_at_ms'];
    if (h is! String || !isLaptopAddress(h) || p is! int || p < 1024 || p > 65535 || k is! String || !keyShape.hasMatch(k)) {
      return null;
    }
    return PairedLaptop(host: h, port: p, key: k, name: laptopName(j['name']), pairedAtMs: t is int ? t : 0);
  }

  /// The name of a pairing made before version 2, which this app no longer uses (one new scan replaces it); null for
  /// anything else.
  static String? oldPairingName(Object? j) =>
      j is Map && j['v'] != linkVersion && j['key'] is String ? laptopName(j['name']) : null;

  @override
  bool operator ==(Object other) =>
      other is PairedLaptop && other.host == host && other.port == port && other.key == key && other.name == name && other.pairedAtMs == pairedAtMs;

  @override
  int get hashCode => Object.hash(host, port, key, name, pairedAtMs);
}

enum LinkFailure {
  /// No connection, or no answer in time.
  noAnswer,

  /// The one-time code has expired or was used.
  expired,

  /// The answer did not prove the code or the key: nothing was sent.
  wrongLaptop,

  /// The laptop refused this phone's proof or address.
  refused,

  /// Something that is not the laptop's answer.
  bad,

  /// The laptop's scripts are older than this app (they speak the first version of pairing).
  oldLaptop,
}

class LinkError implements Exception {
  const LinkError(this.why, [this.detail = '']);
  final LinkFailure why;
  final String detail;

  @override
  String toString() => detail.isEmpty ? why.name : '${why.name}: $detail';
}

/// The pairing's outcome: the laptop's name and the key both sides worked out.
typedef LinkAnswer = ({String name, String key});

/// The phone's side of the pairing (scripts/phone_link.py is the laptop's).
class LinkClient {
  LinkClient({this.timeout = const Duration(seconds: 8), this.random});
  final Duration timeout;

  /// Tests pass a seeded one; null = the system's secure random.
  final Random? random;

  /// Step one: the laptop proves it knows [code]. Step two, only then: this phone proves it too and says its Share on
  /// Wi-Fi [sharePort]. Both work the key out; the laptop's answer proves it got the same one. Throws [LinkError].
  Future<LinkAnswer> pair({required String host, required int port, required String code, required int sharePort}) async {
    if (!isLaptopAddress(host)) throw const LinkError(LinkFailure.bad, 'not a local-network address');
    final mine = newNonce(random);
    final hello = await _post(host, port, '/link/hello', {'v': linkVersion, 'nonce': mine});
    final theirs = hello['nonce'], given = hello['proof'];
    if (theirs is! String || !nonceShape.hasMatch(theirs) || given is! String) {
      throw const LinkError(LinkFailure.bad, 'an answer without a proof');
    }
    if (!sameSecret(given, linkProof(code, 'laptop', mine, theirs))) throw const LinkError(LinkFailure.wrongLaptop);
    final done = await _post(host, port, '/link/finish', {
      'v': linkVersion,
      'nonce': theirs,
      'proof': linkProof(code, 'phone', theirs, mine),
      'port': sharePort,
    });
    final key = deriveKey(code, mine, theirs);
    final confirm = done['confirm'];
    if (confirm is! String || !sameSecret(confirm, confirmProof(key, mine, theirs))) {
      throw const LinkError(LinkFailure.bad, 'the laptop did not confirm the key');
    }
    return (name: laptopName(done['name'] ?? hello['name']), key: key);
  }

  Future<Map<String, Object?>> _post(String host, int port, String path, Map<String, Object?> body) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'DIRECT');
    try {
      final req = await client.post(host, port, path).timeout(timeout);
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length; // not chunked: the laptop (Python's http.server) reads Content-Length
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final got = <int>[];
      await for (final chunk in res.timeout(timeout)) {
        got.addAll(chunk);
        if (got.length > _maxAnswer) throw const LinkError(LinkFailure.bad, 'answer too long');
      }
      Object? answer;
      try {
        answer = jsonDecode(utf8.decode(got));
      } on FormatException {
        answer = null;
      }
      final error = answer is Map ? answer['error'] : null;
      switch (res.statusCode) {
        case 200 when answer is Map && answer['v'] == linkVersion:
          return answer.cast<String, Object?>();
        case 410:
          throw const LinkError(LinkFailure.expired);
        case 400:
          throw const LinkError(LinkFailure.oldLaptop); // the laptop's scripts speak the first version of pairing
        case 403:
          throw LinkError(LinkFailure.refused, error is String ? error : '');
        default:
          throw LinkError(LinkFailure.bad, 'answer ${res.statusCode}');
      }
    } on LinkError {
      rethrow;
    } on TimeoutException {
      throw const LinkError(LinkFailure.noAnswer, 'no answer in time');
    } on IOException catch (e) {
      throw LinkError(LinkFailure.noAnswer, e.toString().split('\n').first);
    } finally {
      client.close(force: true);
    }
  }
}
