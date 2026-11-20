// The phone's Wi-Fi in the night's log (DECISIONS rows 610-619). On 2026-11-20 the owner's Xiaomi left the Wi-Fi
// network soon after the screen went off, and the laptop lost Share on Wi-Fi for hours with nothing on the phone to
// say when or why. Now the recorder's service looks every 10 s (PhoneChannel.kt `wifiState`) and writes a line when
// something changed (on Wi-Fi or not, the band, which network the default route uses, the screen, Doze, the app's
// Wi-Fi lock) and every 30 minutes, so the morning check (scripts/phone_night_check.py) can say "Wi-Fi: off from
// 03:25 to 07:40". The network's name is never read or written.
import 'dart:async';

/// How often the recorder's service looks at the phone's Wi-Fi.
const Duration wifiWatchEvery = Duration(seconds: 10);

/// A line even without a change this long after the last one: a quiet log then still says the watch was alive.
const Duration wifiWatchHeartbeat = Duration(minutes: 30);

/// Android's answer about the phone's Wi-Fi at one moment (PhoneChannel.kt `wifiState`).
class WifiState {
  const WifiState({
    required this.enabled,
    required this.connected,
    this.linkMbps,
    this.rssi,
    this.freqMhz,
    required this.route,
    this.screenOn,
    this.idle,
    required this.lockHeld,
  });

  /// From the phone channel's map; null for anything that is not one (an older app, a test channel).
  static WifiState? fromMap(Object? m) {
    if (m is! Map) return null;
    final connected = m['connected'];
    if (connected is! bool) return null;
    int? n(String k) => m[k] is num ? (m[k] as num).toInt() : null;
    bool? b(String k) => m[k] is bool ? m[k] as bool : null;
    final route = m['route'] is String ? (m['route'] as String).split(';').first.trim() : '';
    return WifiState(
      enabled: b('enabled'),
      connected: connected,
      linkMbps: n('linkMbps'),
      rssi: n('rssi'),
      freqMhz: n('freqMhz'),
      route: route.isEmpty ? '?' : route,
      screenOn: b('screenOn'),
      idle: b('idle'),
      lockHeld: m['lock'] == true,
    );
  }

  /// Wi-Fi switched on; null when Android did not say.
  final bool? enabled;

  /// On a Wi-Fi network (the network itself, not a VPN over it).
  final bool connected;
  final int? linkMbps;

  /// Signal strength in dBm.
  final int? rssi;
  final int? freqMhz;

  /// Which network the default route uses: `wifi`, `cell`, `vpn over wifi`, `vpn over cell`, `vpn`, `ethernet`,
  /// `other` or `none`.
  final String route;
  final bool? screenOn;

  /// Android's Doze (the device-idle mode).
  final bool? idle;

  /// The app's Wi-Fi lock (one for the process, PhoneChannel.kt).
  final bool lockHeld;

  String get state => connected ? 'connected' : enabled == false ? 'off' : 'not connected';

  /// `2.4`, `5`, `6` (GHz), or null.
  String? get band {
    final f = freqMhz;
    if (f == null) return null;
    if (f >= 2400 && f < 2500) return '2.4';
    if (f >= 4900 && f < 5925) return '5';
    if (f >= 5925 && f < 7125) return '6';
    if (f >= 57000 && f < 72000) return '60';
    return null;
  }

  /// What counts as a change. Link speed and signal move all the time; they come with every line instead.
  String get key => '$state ${band ?? ''} $route $screenOn $idle $lockHeld';

  /// `wifi connected, 866 Mbps, -58 dBm, 5 GHz; default route wifi; screen off; idle no; lock held`.
  String line() {
    final details = connected
        ? [if (linkMbps != null) '$linkMbps Mbps', if (rssi != null) '$rssi dBm', if (band != null) '$band GHz']
        : const <String>[];
    final more = details.isEmpty ? '' : ', ${details.join(', ')}';
    return 'wifi $state$more; default route $route; screen ${_word(screenOn, 'on', 'off')}; '
        'idle ${_word(idle, 'yes', 'no')}; lock ${lockHeld ? 'held' : 'not held'}';
  }

  static String _word(bool? v, String yes, String no) => v == null ? '?' : (v ? yes : no);
}

/// Looks at the phone's Wi-Fi on its period and writes a line to [log] when something changed, and every
/// [heartbeat]. Every method is safe to call at any time and never throws; the recording never waits for it.
class WifiWatch {
  WifiWatch({
    required this.read,
    required this.log,
    this.every = wifiWatchEvery,
    this.heartbeat = wifiWatchHeartbeat,
    this.readTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Future<WifiState?> Function() read;
  final void Function(String line) log;
  final Duration every;
  final Duration heartbeat;
  final Duration readTimeout;
  final DateTime Function() _now;

  Timer? _timer;
  bool _stopped = false;
  bool _busy = false;
  String? _key;
  String? _error;
  DateTime? _lineAt;

  /// Looks at once, then every [every], until [stop].
  void start() {
    if (_timer != null || _stopped) return;
    unawaited(check());
    _timer = Timer.periodic(every, (_) => unawaited(check()));
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// One look: a line when the state changed or [heartbeat] passed; one line per change of a failure.
  Future<void> check() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      WifiState? s;
      String? failed;
      try {
        s = await read().timeout(readTimeout);
        if (s == null) failed = 'no answer';
      } catch (e) {
        final text = '$e';
        failed = text.length > 160 ? text.substring(0, 160) : text;
      }
      if (_stopped) return;
      if (s == null) {
        if (failed != _error) {
          _error = failed;
          _key = null; // the next good look is written whatever it says
          _say('wifi unreadable: $failed');
        }
        return;
      }
      _error = null;
      final now = _now();
      final last = _lineAt;
      if (s.key != _key || last == null || now.difference(last) >= heartbeat) {
        _key = s.key;
        _lineAt = now;
        _say(s.line());
      }
    } finally {
      _busy = false;
    }
  }

  void _say(String line) {
    try {
      log(line);
    } catch (_) {
      // a line that cannot be written is lost; the watch goes on
    }
  }
}
