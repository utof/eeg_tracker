// Share on Wi-Fi (DECISIONS rows 220-229): the small pure parts. The setting and its token, which client
// addresses are let in, HTTP Range, and the phases in the laptop recorder's words. Plain Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The laptop recorder's port (scripts/record_night.py --port), so the laptop commands look the same.
const int sharePort = 8765;

/// Sharing turns itself off this long after it was switched on.
const Duration shareMaxOn = Duration(hours: 12);

/// After Stop it stays on this long, so the laptop gets the end of the night, then turns itself off. Also how
/// long the app keeps the screen on for it between nights.
const Duration shareAfterStop = Duration(minutes: 15);

/// Letters and digits that are hard to mix up when typed (no 0 o 1 l i).
const String _tokenAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
const int tokenLength = 12; // 31^12: about 59 bits

String newToken([Random? random]) {
  final r = random ?? Random.secure();
  return [for (var i = 0; i < tokenLength; i++) _tokenAlphabet[r.nextInt(_tokenAlphabet.length)]].join();
}

/// The saved setting. Off by default; the token is made at the first switch-on and kept until "New token".
class ShareConfig {
  const ShareConfig({this.on = false, this.token = '', this.port = sharePort, this.offAtMs = 0, this.awakeUntilMs = 0});

  final bool on;
  final String token;
  final int port;

  /// Unix ms at which sharing turns itself off.
  final int offAtMs;

  /// Unix ms until which the app keeps the screen on while it serves between nights.
  final int awakeUntilMs;

  /// On, with a token, and not past its time.
  bool activeAt(int nowMs) => on && token.length >= tokenLength && nowMs < offAtMs;

  ShareConfig switchedOn(int nowMs, {Random? random}) => ShareConfig(
    on: true,
    token: token.length >= tokenLength ? token : newToken(random),
    port: port,
    offAtMs: nowMs + shareMaxOn.inMilliseconds,
    awakeUntilMs: nowMs + shareAfterStop.inMilliseconds,
  );

  ShareConfig switchedOff() => ShareConfig(token: token, port: port);

  ShareConfig withNewToken({Random? random}) =>
      ShareConfig(on: on, token: newToken(random), port: port, offAtMs: offAtMs, awakeUntilMs: awakeUntilMs);

  /// Stop was pressed: on for [shareAfterStop] more at most.
  ShareConfig afterStop(int nowMs) {
    if (!on) return this;
    final end = nowMs + shareAfterStop.inMilliseconds;
    return ShareConfig(on: true, token: token, port: port, offAtMs: min(offAtMs, end), awakeUntilMs: end);
  }

  Map<String, Object?> toJson() => {
    'on': on,
    'token': token,
    'port': port,
    'off_at_ms': offAtMs,
    'awake_until_ms': awakeUntilMs,
  };

  static ShareConfig fromJson(Object? j) {
    if (j is! Map) return const ShareConfig();
    final t = j['token'], p = j['port'], o = j['off_at_ms'], a = j['awake_until_ms'];
    return ShareConfig(
      on: j['on'] == true,
      token: t is String ? t : '',
      port: p is int && p > 1023 && p < 65536 ? p : sharePort,
      offAtMs: o is int ? o : 0,
      awakeUntilMs: a is int ? a : 0,
    );
  }

  String encode() => jsonEncode(toJson());

  static ShareConfig decode(String? raw) {
    if (raw == null) return const ShareConfig();
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return const ShareConfig();
    }
  }
}

/// 10.x, 172.16-31.x, 192.168.x, 169.254.x (link-local): addresses that exist only on a local network.
bool isPrivateV4(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
}

/// Who may connect: the local network and the phone itself (`adb forward` over the cable arrives as loopback).
bool isAllowedClient(InternetAddress a) {
  if (a.isLoopback) return true;
  if (a.type == InternetAddressType.IPv6) {
    final b = a.rawAddress; // an IPv4 client seen through an IPv6 socket: ::ffff:a.b.c.d
    final mapped = b.length == 16 && b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    return mapped && isPrivateV4(InternetAddress.fromRawAddress(b.sublist(12)));
  }
  return isPrivateV4(a);
}

/// Mobile data, VPNs and the like: never served on, whatever their address.
final RegExp _notLan = RegExp(r'^(lo|rmnet|ccmni|pdp|ppp|tun|tap|dummy|v4-|clat|ip6|sit|wwan|ifb|gre|erspan)');

/// The addresses to listen on: private IPv4 addresses of Wi-Fi-like interfaces, Wi-Fi (`wlan`) first.
List<InternetAddress> lanAddresses(List<NetworkInterface> interfaces) {
  final found = <(int, String, InternetAddress)>[];
  for (final i in interfaces) {
    if (_notLan.hasMatch(i.name)) continue;
    for (final a in i.addresses) {
      if (isPrivateV4(a)) found.add((i.name.startsWith('wlan') ? 0 : 1, i.name, a));
    }
  }
  found.sort((x, y) {
    final c = x.$1.compareTo(y.$1);
    return c != 0 ? c : x.$2.compareTo(y.$2);
  });
  return [for (final f in found) f.$3];
}

/// Same length or not, the comparison takes the same time for every wrong token.
bool sameToken(String given, String token) {
  final a = utf8.encode(given), b = utf8.encode(token);
  var diff = a.length ^ b.length;
  for (var i = 0; i < b.length; i++) {
    diff |= (i < a.length ? a[i] : 0) ^ b[i];
  }
  return diff == 0 && token.isNotEmpty;
}

/// One byte range of a file of [size] bytes, both ends included.
typedef ByteRange = ({int start, int end});

/// Parses a `Range` header. Returns null for "the whole file" (no header, or a form we do not serve, which HTTP
/// lets a server ignore); throws [RangeError] when the range starts past the end (answer 416).
ByteRange? parseRange(String? header, int size) {
  if (header == null) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final a = m[1]!, b = m[2]!;
  if (a.isEmpty && b.isEmpty) return null;
  if (a.isEmpty) {
    final n = int.parse(b);
    if (n == 0 || size == 0) throw RangeError('empty range');
    return (start: max(0, size - n), end: size - 1);
  }
  final start = int.parse(a);
  if (start >= size) throw RangeError('range starts past the end');
  final end = b.isEmpty ? size - 1 : min(int.parse(b), size - 1);
  if (end < start) return null;
  return (start: start, end: end);
}

/// The recorder's phase in the laptop recorder's words: its pages know `recording` and `reconnecting`.
String statusWord(String phase) => switch (phase) {
  'recording' => 'recording',
  'checkingContact' => 'checking contact',
  'searching' || 'connecting' || 'reconnecting' => 'reconnecting',
  'stopping' => 'stopping',
  _ => 'not recording',
};

/// `http://192.168.1.23:8765/?token=...`: what the QR code holds.
String shareUrl(String address, int port, String token) => 'http://$address:$port/?token=$token';
