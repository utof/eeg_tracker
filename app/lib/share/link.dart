// Pairing with a laptop by one scan (DECISIONS rows 530-539; scripts/phone_link.py; docs/phone-link.md).
//
// The laptop shows a QR code; the phone's camera opens its page, which opens this app with
// `eegtracker://pair?h=<laptop>&p=<port>&s=<one-time code>&n=<name>`. On Connect the app checks that the laptop knows
// the code (an HMAC over the app's own random nonce, so the code never travels back), proves that it knows it too,
// and only then sends its Share on Wi-Fi port and token. The laptop answers with a key of their own. With that key
// the app later tells the laptop where it is now, by the same two steps: whenever sharing starts and every 5 minutes
// while it is on ([LaptopAnnouncer], in the share isolate). The laptop takes the phone's address from the connection
// itself, so nothing here needs to know the phone's own address.
//
// Plain dart:io with no Flutter import: it also runs in the share isolate, and in tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

const String linkScheme = 'eegtracker';
const int linkVersion = 1;
const String _proofTag = 'eeg-tracker link v1';
final RegExp _nonceShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// How often a paired phone tells the laptop where it is while sharing is on.
const Duration announceEvery = Duration(minutes: 5);

/// After a failed try: the next ones, then [announceEvery].
const List<Duration> announceRetries = [Duration(seconds: 30), Duration(minutes: 1), Duration(minutes: 2)];

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
    if (!isLaptopAddress(host) || port == null || port < 1024 || port > 65535 || !_nonceShape.hasMatch(code)) {
      return null;
    }
    return PairLink(host: host, port: port, code: code, name: laptopName(q['n']));
  }
}

/// The laptop this phone is paired with: where it was, and the key they share.
class PairedLaptop {
  const PairedLaptop({required this.host, required this.port, required this.key, required this.name, this.pairedAtMs = 0});
  final String host;
  final int port;
  final String key;
  final String name;
  final int pairedAtMs;

  Map<String, Object?> toJson() => {'host': host, 'port': port, 'key': key, 'name': name, 'paired_at_ms': pairedAtMs};

  static PairedLaptop? fromJson(Object? j) {
    if (j is! Map) return null;
    final h = j['host'], p = j['port'], k = j['key'], t = j['paired_at_ms'];
    if (h is! String || !isLaptopAddress(h) || p is! int || p < 1024 || p > 65535 || k is! String || k.length < 32) {
      return null;
    }
    return PairedLaptop(host: h, port: p, key: k, name: laptopName(j['name']), pairedAtMs: t is int ? t : 0);
  }

  @override
  bool operator ==(Object other) =>
      other is PairedLaptop && other.host == host && other.port == port && other.key == key && other.name == name && other.pairedAtMs == pairedAtMs;

  @override
  int get hashCode => Object.hash(host, port, key, name, pairedAtMs);
}

/// HMAC-SHA256 of `eeg-tracker link v1|<who>|<via>|<first>|<second>` keyed with the code or the key, in hex; the same
/// as `proof()` in scripts/phone_link.py (both checked against app/test/fixtures/phone_link.json).
String linkProof(String secret, String who, String via, String first, String second) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode([_proofTag, who, via, first, second].join('|'))).toString();

/// 16 random bytes, URL-safe, no padding (22 characters).
String newNonce([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', '');
}

bool _same(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < y.length; i++) {
    diff |= (i < x.length ? x[i] : 0) ^ y[i];
  }
  return diff == 0;
}

enum LinkFailure {
  /// No connection, or no answer in time.
  noAnswer,

  /// The one-time code has expired or was used.
  expired,

  /// The laptop has no key (it was never paired, or its pairing file is gone).
  notPaired,

  /// The answer did not prove the code or the key: nothing was sent.
  wrongLaptop,

  /// The laptop refused this phone's proof or address.
  refused,

  /// Something that is not the laptop's answer.
  bad,
}

class LinkError implements Exception {
  const LinkError(this.why, [this.detail = '']);
  final LinkFailure why;
  final String detail;

  @override
  String toString() => detail.isEmpty ? why.name : '${why.name}: $detail';
}

/// The laptop's answer to a finished handshake: its name, and the new key after a pairing.
typedef LinkAnswer = ({String name, String? key});

/// The phone's side of the handshake (scripts/phone_link.py is the laptop's).
class LinkClient {
  LinkClient({this.timeout = const Duration(seconds: 8), this.random});
  final Duration timeout;

  /// Tests pass a seeded one; null = the system's secure random.
  final Random? random;

  /// Step one: the laptop proves it knows [secret] (the one-time code with [via] `code`, the shared key with `key`).
  /// Step two, only then: this phone proves it too and sends [sharePort] and [token]. Throws [LinkError].
  Future<LinkAnswer> handshake({
    required String host,
    required int port,
    required String via,
    required String secret,
    required int sharePort,
    required String token,
  }) async {
    if (!isLaptopAddress(host)) throw const LinkError(LinkFailure.bad, 'not a local-network address');
    final mine = newNonce(random);
    final hello = await _post(host, port, '/link/hello', {'v': linkVersion, 'via': via, 'nonce': mine});
    final theirs = hello['nonce'], given = hello['proof'];
    if (theirs is! String || !_nonceShape.hasMatch(theirs) || given is! String) {
      throw const LinkError(LinkFailure.bad, 'an answer without a proof');
    }
    if (!_same(given, linkProof(secret, 'laptop', via, mine, theirs))) {
      throw const LinkError(LinkFailure.wrongLaptop);
    }
    final done = await _post(host, port, '/link/finish', {
      'v': linkVersion,
      'via': via,
      'nonce': theirs,
      'proof': linkProof(secret, 'phone', via, theirs, mine),
      'port': sharePort,
      'token': token,
    });
    final key = done['key'];
    if (via == 'code' && (key is! String || key.length < 32)) throw const LinkError(LinkFailure.bad, 'no key');
    return (name: laptopName(done['name'] ?? hello['name']), key: key is String ? key : null);
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
        case 404 when error == 'not paired':
          throw const LinkError(LinkFailure.notPaired);
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

/// Tells the paired laptop where this phone is: at once, then every [every] while it works, sooner after a failure.
/// Lives in the share isolate (isolate.dart), so it runs wherever the server runs (the app or the night recorder)
/// and ends with it. One line to [onLine] when the state changes, never one per try.
class LaptopAnnouncer {
  LaptopAnnouncer({
    required this.laptop,
    required this.sharePort,
    required this.token,
    LinkClient? client,
    this.onLine,
    this.every = announceEvery,
    this.retries = announceRetries,
  }) : _client = client ?? LinkClient();

  final PairedLaptop laptop;
  final int sharePort;
  final String token;
  final LinkClient _client;
  final void Function(String line)? onLine;
  final Duration every;
  final List<Duration> retries;

  Timer? _timer;
  bool _closed = false, _busy = false, _again = false;
  int _fails = 0;
  LinkFailure? _last;
  bool _known = false;

  /// Tries so far that reached the laptop and were accepted.
  int told = 0;

  void start() => _schedule(Duration.zero);

  /// The phone's network came back or changed (DECISIONS 676): one try now, not at the next 5 minutes, and the
  /// quick retries again after a failure. A try under way finishes first; then one more follows.
  void soon() {
    if (_closed) return;
    _fails = 0;
    if (_busy) {
      _again = true;
      return;
    }
    _schedule(Duration.zero);
  }

  void stop() {
    _closed = true;
    _timer?.cancel();
  }

  void _schedule(Duration d) {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(d, () => unawaited(tell()));
  }

  /// One try now; true when the laptop took it.
  Future<bool> tell() async {
    if (_closed) return false;
    _busy = true;
    try {
      return await _tell();
    } finally {
      _busy = false;
      if (_again && !_closed) {
        _again = false;
        _schedule(Duration.zero);
      }
    }
  }

  Future<bool> _tell() async {
    LinkFailure? failure;
    try {
      await _client.handshake(
        host: laptop.host,
        port: laptop.port,
        via: 'key',
        secret: laptop.key,
        sharePort: sharePort,
        token: token,
      );
    } on LinkError catch (e) {
      failure = e.why;
    } catch (_) {
      failure = LinkFailure.bad;
    }
    if (_closed) return failure == null;
    if (failure == null) {
      told++;
      if (!_known) _say('the laptop ${laptop.name} knows where this phone is');
      _known = true;
      _fails = 0;
      _last = null;
      _schedule(every);
      return true;
    }
    if (_known || _last != failure) {
      _say(switch (failure) {
        LinkFailure.notPaired || LinkFailure.wrongLaptop => 'the laptop ${laptop.name} no longer knows this phone: scan its code again',
        _ => 'the laptop ${laptop.name} did not answer (${failure.name}); trying again',
      });
    }
    _known = false;
    _last = failure;
    _schedule(_fails < retries.length ? retries[_fails] : every);
    _fails++;
    return false;
  }

  void _say(String line) {
    try {
      onLine?.call(line);
    } catch (_) {}
  }
}
