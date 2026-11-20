// Share on Wi-Fi (DECISIONS rows 220-229): the small pure parts. The setting and its token, which client
// addresses are let in, HTTP Range, and the phases in the laptop recorder's words. Plain Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'link.dart';

/// The laptop recorder's port (scripts/record_night.py --port), so the laptop commands look the same.
const int sharePort = 8765;

/// Sharing turns itself off this long after it was switched on, unless a laptop is paired (DECISIONS 675): then it
/// stays on until the owner turns it off or forgets the laptop.
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

/// How long "Share here" lets a paired phone share on a Wi-Fi that is not its home (DECISIONS 752).
const Duration shareHereFor = Duration(hours: 12);

/// The saved setting. Off by default; the token is made at the first switch-on and kept until "New code".
class ShareConfig {
  const ShareConfig({
    this.on = false,
    this.token = '',
    this.port = sharePort,
    this.offAtMs = 0,
    this.awakeUntilMs = 0,
    this.laptop,
    this.hereUntilMs = 0,
    this.hereNet,
    this.oldLaptop,
  });

  final bool on;
  final String token;
  final int port;

  /// Unix ms at which sharing turns itself off.
  final int offAtMs;

  /// Unix ms until which the app keeps the screen on while it serves between nights.
  final int awakeUntilMs;

  /// The laptop this phone is paired with (link.dart, DECISIONS rows 530-539, 753).
  final PairedLaptop? laptop;

  /// "Share here for 12 hours" (DECISIONS 752): until [hereUntilMs], on the Wi-Fi network [hereNet] (`lanSignature`),
  /// a paired phone shares there although it is not its home.
  final int hereUntilMs;
  final String? hereNet;

  /// The name of a laptop paired the first way (its key crossed the Wi-Fi), no longer used: one new scan pairs again.
  final String? oldLaptop;

  /// A laptop is paired: sharing has no end time (DECISIONS 675).
  bool get paired => laptop != null;

  /// On, with a token, and not past its time; while a laptop is paired there is no time (DECISIONS 675).
  bool activeAt(int nowMs) => on && token.length >= tokenLength && (paired || nowMs < offAtMs);

  /// When the server turns itself off (unix ms); null while a laptop is paired.
  int? get endsAtMs => paired ? null : offAtMs;

  ShareConfig _with({
    bool? on,
    String? token,
    int? offAtMs,
    int? awakeUntilMs,
    PairedLaptop? Function()? laptop,
    int? hereUntilMs,
    String? Function()? hereNet,
    String? Function()? oldLaptop,
  }) => ShareConfig(
    on: on ?? this.on,
    token: token ?? this.token,
    port: port,
    offAtMs: offAtMs ?? this.offAtMs,
    awakeUntilMs: awakeUntilMs ?? this.awakeUntilMs,
    laptop: laptop != null ? laptop() : this.laptop,
    hereUntilMs: hereUntilMs ?? this.hereUntilMs,
    hereNet: hereNet != null ? hereNet() : this.hereNet,
    oldLaptop: oldLaptop != null ? oldLaptop() : this.oldLaptop,
  );

  ShareConfig switchedOn(int nowMs, {Random? random}) => _with(
    on: true,
    token: token.length >= tokenLength ? token : newToken(random),
    offAtMs: nowMs + shareMaxOn.inMilliseconds,
    awakeUntilMs: nowMs + shareAfterStop.inMilliseconds,
  );

  ShareConfig switchedOff() => _with(on: false, offAtMs: 0, awakeUntilMs: 0, hereUntilMs: 0, hereNet: () => null);

  ShareConfig withNewToken({Random? random}) => _with(token: newToken(random));

  /// Paired with [to] (an old pairing is forgotten either way), or with no laptop when null.
  ShareConfig withLaptop(PairedLaptop? to) => _with(laptop: () => to, oldLaptop: () => null);

  /// "Share here for 12 hours" on the Wi-Fi network [net] (`lanSignature`); an empty [net] (no Wi-Fi) ends it.
  ShareConfig sharedHere(int nowMs, String net) =>
      net.isEmpty ? _with(hereUntilMs: 0, hereNet: () => null) : _with(hereUntilMs: nowMs + shareHereFor.inMilliseconds, hereNet: () => net);

  /// "Share here" ended by hand.
  ShareConfig notHere() => _with(hereUntilMs: 0, hereNet: () => null);

  /// Stop was pressed: on for [shareAfterStop] more at most (while a laptop is paired it stays on: DECISIONS 675).
  ShareConfig afterStop(int nowMs) {
    if (!on) return this;
    final end = nowMs + shareAfterStop.inMilliseconds;
    return _with(offAtMs: paired ? offAtMs : min(offAtMs, end), awakeUntilMs: end);
  }

  Map<String, Object?> toJson() => {
    'on': on,
    'token': token,
    'port': port,
    'off_at_ms': offAtMs,
    'awake_until_ms': awakeUntilMs,
    'laptop': laptop?.toJson(),
    'here_until_ms': hereUntilMs,
    'here_net': hereNet,
    if (oldLaptop != null) 'old_laptop': oldLaptop,
  };

  static ShareConfig fromJson(Object? j) {
    if (j is! Map) return const ShareConfig();
    final t = j['token'], p = j['port'], o = j['off_at_ms'], a = j['awake_until_ms'];
    final hu = j['here_until_ms'], hn = j['here_net'], old = j['old_laptop'];
    final laptop = PairedLaptop.fromJson(j['laptop']);
    return ShareConfig(
      on: j['on'] == true,
      token: t is String ? t : '',
      port: p is int && p > 1023 && p < 65536 ? p : sharePort,
      offAtMs: o is int ? o : 0,
      awakeUntilMs: a is int ? a : 0,
      laptop: laptop,
      hereUntilMs: hu is int ? hu : 0,
      hereNet: hn is String ? hn : null,
      // a laptop paired the first way is not used: its name stays until a new scan (or Forget)
      oldLaptop: laptop != null ? null : (PairedLaptop.oldPairingName(j['laptop']) ?? (old is String ? laptopName(old) : null)),
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

/// One local network the phone is on: its own address there and the network's prefix length (`192.168.1.5/24`).
typedef LanNet = ({InternetAddress address, int prefix});

/// Android's own view of the phone's Wi-Fi (PhoneChannel.kt `wifiNets`): `192.168.1.5/24` strings, and a note of
/// what each of its sources returned, for the log when no address is found.
typedef WifiNets = ({List<String> nets, String note});

const WifiNets noWifiAnswer = (nets: <String>[], note: 'no answer');

/// The fallback (DECISIONS row 561), from Dart's interface list: private IPv4 addresses of Wi-Fi-like interfaces,
/// Wi-Fi (`wlan`) first.
List<LanNet> lanNets(List<NetworkInterface> interfaces) {
  final found = <(int, String, LanNet)>[];
  for (final i in interfaces) {
    if (_notLan.hasMatch(i.name)) continue;
    for (final a in i.addresses) {
      if (isPrivateV4(a)) found.add((i.name.startsWith('wlan') ? 0 : 1, i.name, (address: a, prefix: _prefix(a.prefixLength))));
    }
  }
  found.sort((x, y) {
    final c = x.$1.compareTo(y.$1);
    return c != 0 ? c : x.$2.compareTo(y.$2);
  });
  return [for (final f in found) f.$3];
}

List<InternetAddress> lanAddresses(List<NetworkInterface> interfaces) => [for (final n in lanNets(interfaces)) n.address];

/// A prefix Android or the kernel gave; anything that is not 1-32 is read as the home router's usual /24.
int _prefix(int? p) => p != null && p >= 1 && p <= 32 ? p : 24;

/// Android's `192.168.1.5/24` strings (Wi-Fi networks only; PhoneChannel.kt leaves out VPNs and mobile data):
/// private IPv4 only, each once.
List<LanNet> parseLanNets(Iterable<Object?> raw) {
  final out = <String, LanNet>{};
  for (final r in raw) {
    if (r is! String) continue;
    final slash = r.indexOf('/');
    final a = InternetAddress.tryParse(slash < 0 ? r : r.substring(0, slash));
    if (a == null || !isPrivateV4(a)) continue;
    out.putIfAbsent(a.address, () => (address: a, prefix: _prefix(slash < 0 ? null : int.tryParse(r.substring(slash + 1)))));
  }
  return out.values.toList();
}

/// [text] with every IPv4 address written as `x.x.x.x` (a prefix such as `/24` stays): log lines carry no addresses
/// (DECISIONS 757).
String redactAddresses(String text) => text.replaceAll(RegExp(r'(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])'), 'x.x.x.x');

/// `wlan0 192.168.1.5/24, tun0 10.10.10.1/30`: an interface list in one line (for the log, through [redactAddresses]).
String describeInterfaces(List<NetworkInterface> interfaces) {
  final parts = [
    for (final i in interfaces)
      for (final a in i.addresses) '${i.name} ${a.address}/${a.prefixLength}',
  ];
  return parts.isEmpty ? 'none' : parts.join(', ');
}

/// The Wi-Fi networks the server shows and answers on: Android's own answer when it has one, else Dart's interface
/// list ([interfaces], or the [interfaceError] it threw). [why] is empty when one was found, else says what both
/// sources returned.
({List<LanNet> nets, String why}) chooseLan(WifiNets android, {List<NetworkInterface>? interfaces, Object? interfaceError}) {
  final mine = parseLanNets(android.nets);
  if (mine.isNotEmpty) return (nets: mine, why: '');
  final listed = interfaces == null ? const <LanNet>[] : lanNets(interfaces);
  if (listed.isNotEmpty) return (nets: listed, why: '');
  final seen = interfaces != null ? describeInterfaces(interfaces) : 'failed: ${interfaceError ?? 'not looked at'}';
  return (nets: const <LanNet>[], why: 'no Wi-Fi address found (android: ${android.note}; interfaces: $seen)');
}

/// The IPv4 address inside an IPv4-mapped IPv6 one (`::ffff:a.b.c.d`), the IPv4 address itself, or null.
InternetAddress? _v4(InternetAddress a) {
  if (a.type == InternetAddressType.IPv4) return a;
  final b = a.rawAddress;
  final mapped = b.length == 16 && b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  return mapped ? InternetAddress.fromRawAddress(b.sublist(12)) : null;
}

/// The Wi-Fi network(s) the phone is on as one text: each network's own address and prefix (`192.168.1.0/24`),
/// sorted; empty without one. What "home" and "Share here for 12 hours" are remembered by (DECISIONS 752).
String lanSignature(List<LanNet> nets) {
  final out = <String>{};
  for (final n in nets) {
    final b = n.address.rawAddress;
    if (b.length != 4) continue;
    final v = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    final mask = n.prefix <= 0 ? 0 : (0xffffffff << (32 - n.prefix)) & 0xffffffff;
    final m = v & mask;
    out.add('${(m >> 24) & 255}.${(m >> 16) & 255}.${(m >> 8) & 255}.${m & 255}/${n.prefix}');
  }
  return (out.toList()..sort()).join(',');
}

/// Whether [a] is inside [net] (both IPv4).
bool inLan(InternetAddress a, LanNet net) {
  final v = _v4(a), n = net.address.rawAddress;
  if (v == null || n.length != 4) return false;
  final b = v.rawAddress;
  for (var bit = 0; bit < net.prefix; bit++) {
    final mask = 0x80 >> (bit % 8);
    if ((b[bit ~/ 8] & mask) != (n[bit ~/ 8] & mask)) return false;
  }
  return true;
}

/// Who the server answers (DECISIONS row 562): the phone itself (`adb forward` over the cable arrives as loopback),
/// and a private IPv4 client inside one of the phone's Wi-Fi networks [wifi]. The server listens on every address,
/// so a private source alone is not enough: mobile data's carrier network (`ccmni0 10.43.97.139/8` on the owner's
/// phone) and a VPN's tunnel (`tun0 10.10.10.1/30`, whose other end is 10.10.10.2) are private ranges too. Without a
/// known Wi-Fi network only the phone itself is answered.
bool isServedClient(InternetAddress client, List<LanNet> wifi) {
  if (client.isLoopback) return true;
  final v = _v4(client);
  if (v == null) return false;
  if (v.isLoopback) return true;
  return isPrivateV4(v) && wifi.any((n) => inLan(v, n));
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

/// `http://192.168.1.23:8765/`: what the sheet's QR code holds. Never the token (DECISIONS 754): a link's address
/// ends up in browser history, proxies and logs.
String shareUrl(String address, int port) => 'http://$address:$port/';
