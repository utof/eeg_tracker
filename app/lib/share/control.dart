// Share on Wi-Fi from the screen's side (DECISIONS rows 220-229): the switch, who serves, and when it ends.
//
// During a night the recorder's service serves (it keeps running with the screen off) and tells the screen where;
// between nights the app serves the files itself, keeps the screen on for the first 15 minutes, and keeps itself
// running with a notification while sharing is on ([keepAlive], DECISIONS row 589), so Android does not freeze it in
// the background: a frozen app's port still takes connections and never answers. Only one of the two holds the port:
// the app lets go before a night starts and takes over after Stop.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auto/laptop.dart' show laptopWorkSignal;
import '../phone.dart';
import 'isolate.dart';
import 'link.dart';
import 'protocol.dart';

/// The notification's words while the app keeps itself running to share between nights.
String shareKeepText(int offAtMs) =>
    'Your laptop can copy the files until ${clockText(DateTime.fromMillisecondsSinceEpoch(offAtMs))}. Stop turns it off.';

/// What the main screen's "Your data" section shows.
typedef ShareLine = ({bool on, String text, bool warn, String? address});

/// How a pairing ended: the laptop, or why not.
typedef PairOutcome = ({PairedLaptop? laptop, LinkFailure? failure});

class ShareControl extends ChangeNotifier {
  ShareControl({
    required this.load,
    required this.save,
    required this.sendToRecorder,
    required this.keepScreenOn,
    this.keepAlive,
    ShareHost Function(String filesDir, void Function(ShareStatus) onChange)? host,
    DateTime Function()? clock,
  }) : _makeHost = host ?? _appHost,
       _now = clock ?? DateTime.now;

  final Future<ShareConfig> Function() load;
  final Future<void> Function(ShareConfig config) save;

  /// Sends the setting to the recorder's service while a night runs.
  final void Function(Map<String, Object?> message) sendToRecorder;
  final Future<void> Function(bool on) keepScreenOn;

  /// Keeps the app running in the background while it serves between nights (a notification until [offAtMs]); false
  /// lets go. Null in tests that do not look at it.
  final Future<void> Function(bool on, int offAtMs)? keepAlive;
  final ShareHost Function(String filesDir, void Function(ShareStatus) onChange) _makeHost;
  final DateTime Function() _now;

  /// Between nights the app's server also takes the paired laptop's work signal for automatic recording (DECISIONS
  /// 603): kept in `auto-start/laptop.json`, and a start asks the headband watcher for a check.
  static ShareHost _appHost(String filesDir, void Function(ShareStatus) onChange) => ShareHost(
    filesDir: filesDir,
    onLog: debugPrint,
    onChange: onChange,
    wifi: Phone.wifiNets,
    onWork: (working) => unawaited(laptopWorkSignal(working: working)),
  );

  ShareConfig _config = const ShareConfig();
  ShareStatus _status = shareDown;
  ShareHost? _host;
  bool _night = false;
  bool _awake = false;
  int? _aliveUntil;
  String? _filesDir;
  Future<void> _queue = Future.value();

  ShareConfig get config => _config;

  /// The laptop is copying files from the app's own server (between nights).
  bool get copying => _host?.copying ?? false;
  ShareStatus get status => _status;
  bool get on => _config.activeAt(_now().millisecondsSinceEpoch);

  /// One step at a time: a tick and a tap never start two servers.
  Future<void> _serial(Future<void> Function() step) {
    final next = _queue.then((_) => step()).catchError((Object _) {});
    _queue = next;
    return next;
  }

  /// Brings the server in line with the setting. [night]: the recorder's service runs; [front]: the main screen
  /// is the one on top (only then may the screen's keep-awake be let go).
  Future<void> sync({required bool night, required String? filesDir, bool front = true}) => _serial(() async {
    _filesDir = filesDir ?? _filesDir;
    final was = _night;
    _night = night;
    _config = await load();
    final now = _now().millisecondsSinceEpoch;
    if (_config.on && !_config.activeAt(now)) {
      _config = _config.switchedOff(); // its time is up
      await save(_config);
    }
    if (night) {
      await _stopHost();
      if (!was) _status = shareDown; // the recorder will say where it serves
    } else {
      if (was) _status = shareDown;
      await _serveFromApp();
    }
    await _keepAwake(_config.activeAt(now) && !night && now < _config.awakeUntilMs, front: front);
    await _keepAlive(_config.activeAt(now) && !night);
    notifyListeners();
  });

  Future<void> setOn(bool value) => _serial(() async {
    _config = value ? _config.switchedOn(_now().millisecondsSinceEpoch) : _config.switchedOff();
    await save(_config);
    await _apply();
  });

  Future<void> newToken() => _serial(() async {
    _config = _config.withNewToken();
    await save(_config);
    await _apply();
  });

  /// Pairs with the laptop of [link] (DECISIONS rows 530-539), after the owner tapped Connect. The handshake first
  /// (the laptop proves the one-time code before this phone's token leaves it); only when it worked is sharing
  /// switched on, if it was off, and the laptop remembered, so it is told where this phone is from then on. A
  /// failure changes nothing but a token made for the occasion.
  Future<PairOutcome> pair(PairLink link, {LinkClient? client}) {
    final done = Completer<PairOutcome>();
    unawaited(
      _serial(() async {
        try {
          var c = await load();
          if (c.token.length < tokenLength) {
            c = c.withNewToken(); // the laptop needs the token the server will have
            await save(c);
            _config = c;
          }
          final answer = await (client ?? LinkClient()).handshake(
            host: link.host,
            port: link.port,
            via: 'code',
            secret: link.code,
            sharePort: c.port,
            token: c.token,
          );
          final nowMs = _now().millisecondsSinceEpoch;
          final laptop = PairedLaptop(host: link.host, port: link.port, key: answer.key!, name: answer.name, pairedAtMs: nowMs);
          _config = (c.activeAt(nowMs) ? c : c.switchedOn(nowMs)).withLaptop(laptop);
          await save(_config);
          await _apply();
          done.complete((laptop: laptop, failure: null));
        } on LinkError catch (e) {
          done.complete((laptop: null, failure: e.why));
        } catch (_) {
          done.complete((laptop: null, failure: LinkFailure.bad));
        }
      }),
    );
    return done.future;
  }

  /// Forgets the paired laptop: it is told nothing more (its own copy of the token stops working at New code).
  Future<void> forgetLaptop() => _serial(() async {
    _config = (await load()).withLaptop(null);
    await save(_config);
    await _apply();
  });

  /// Before the recorder's service starts: the app lets go of the port.
  Future<void> beforeNight() => _serial(() async {
    _night = true;
    await _stopHost();
    await _keepAlive(false); // the recorder's service keeps the app running now
    _status = shareDown;
    notifyListeners();
  });

  /// Stop was pressed: sharing stays for [shareAfterStop], so the laptop gets the end of the night.
  Future<void> afterStop() => _serial(() async {
    _config = (await load()).afterStop(_now().millisecondsSinceEpoch);
    await save(_config);
  });

  /// A message from the recorder's service.
  void onRecorderStatus(ShareStatus s) {
    if (!_night) return;
    _status = s;
    notifyListeners();
  }

  Future<void> _apply() async {
    if (_night) {
      await _stopHost();
      sendToRecorder({'kind': 'share', 'config': _config.toJson()});
    } else {
      await _stopHost();
      await _serveFromApp();
      final now = _now().millisecondsSinceEpoch;
      await _keepAwake(_config.activeAt(now) && now < _config.awakeUntilMs, front: true);
    }
    await _keepAlive(_config.activeAt(_now().millisecondsSinceEpoch) && !_night);
    notifyListeners();
  }

  /// Keeps the app running while it serves between nights; once per change.
  Future<void> _keepAlive(bool want) async {
    final until = want ? _config.offAtMs : null;
    if (until == _aliveUntil) return;
    _aliveUntil = until;
    try {
      await keepAlive?.call(until != null, until ?? 0);
    } catch (_) {}
  }

  Future<void> _serveFromApp() async {
    final active = _config.activeAt(_now().millisecondsSinceEpoch);
    final dir = _filesDir;
    if (!active || dir == null) {
      await _stopHost();
      if (!active) _status = shareDown;
      return;
    }
    if (_host?.running ?? false) return;
    final host = _host = _makeHost(dir, (s) {
      if (_night) return;
      _status = s;
      notifyListeners();
    });
    host.setLive(const {});
    await host.start(_config);
  }

  Future<void> _stopHost() async {
    final h = _host;
    _host = null;
    await h?.stop();
  }

  Future<void> _keepAwake(bool want, {required bool front}) async {
    if (want == _awake && !(want && front)) return;
    if (!want && !front) return; // another screen is on top and may be keeping the screen on itself
    _awake = want;
    try {
      await keepScreenOn(want);
    } catch (_) {}
  }

  /// The line under the switch.
  ShareLine line() {
    final nowMs = _now().millisecondsSinceEpoch;
    if (!_config.activeAt(nowMs)) {
      return (on: false, text: 'Lets your laptop watch the signal and copy the files over your home Wi-Fi.', warn: false, address: null);
    }
    final at = shareAddress(_status);
    final until = clockText(DateTime.fromMillisecondsSinceEpoch(_config.offAtMs));
    if (at != null) {
      return (
        on: true,
        text: _night ? 'On at $at until $until.' : 'On at $at until $until. Keep this app open while the laptop copies.',
        warn: false,
        address: at,
      );
    }
    if (_status.up) {
      return (
        on: true,
        text: 'On, but no Wi-Fi address found. Join your home Wi-Fi, or use a USB cable: see Address and code.',
        warn: true,
        address: null,
      );
    }
    final failed = _status.note.contains('could not') || _status.note.contains('stopped');
    return (
      on: true,
      text: failed ? 'Sharing stopped by itself. Switch it off and on again.' : 'Starting.',
      warn: failed,
      address: null,
    );
  }

  @override
  void dispose() {
    unawaited(_stopHost());
    if (_aliveUntil != null) unawaited(keepAlive?.call(false, 0).catchError((Object _) {}));
    super.dispose();
  }
}

/// `07:40`.
String clockText(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
