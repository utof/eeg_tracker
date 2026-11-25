// Share on Wi-Fi from the screen's side (DECISIONS rows 220-229, 750-759): the switch, who serves, when it ends, and
// where a paired phone shares (its home Wi-Fi, or one allowed by hand for 12 hours: no notification says so, this
// screen and the laptop's tray do).
//
// During a night the recorder's service serves (it keeps running with the screen off) and tells the screen where;
// between nights the app serves the files itself while it runs (open, or holding a session such as a Work session)
// and keeps the screen on for the first 15 minutes. No notification keeps it running for sharing (the owner,
// 2026-11-20; DECISIONS 678 replaces row 589): in the background Android may freeze it, and the paired laptop copies
// what it missed when the app is opened again or records. Only one of the two holds the port:
// the app lets go before a night starts and takes over after Stop. Whoever serves holds the phone's Wi-Fi lock
// ([wifiLock], DECISIONS row 612) under its own name, so the hand-over never drops it.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auto/laptop.dart' show laptopWorkSignal;
import '../phone.dart';
import 'isolate.dart';
import 'link.dart';
import 'local_network.dart';
import 'protocol.dart';
import 'shared_session.dart';

/// What the main screen's "Your data" section shows.
typedef ShareLine = ({bool on, String text, bool warn, String? address});

/// How a pairing ended: the laptop, or why not.
typedef PairOutcome = ({PairedLaptop? laptop, LinkFailure? failure});

/// Makes the app's own server: the files folder, where its status goes, and the Wi-Fi lock it holds while it serves.
typedef ShareHostMaker =
    ShareHost Function(String filesDir, void Function(ShareStatus) onChange, Future<void> Function(bool on)? wifiLock);

class ShareControl extends ChangeNotifier {
  ShareControl({
    required this.load,
    required this.save,
    required this.sendToRecorder,
    required this.keepScreenOn,
    this.wifiLock,
    ShareHostMaker? host,
    DateTime Function()? clock,
    ValueListenable<Map<String, Object?>?>? session,
    Stream<void>? networkChanges,
    Future<bool> Function()? localNetwork,
    Future<void> Function(bool on)? pushSchedule,
  }) : _makeHost = host ?? _appHost,
       pushSchedule = pushSchedule ?? ((on) => Phone.pushSchedule(on: on)),
       _localNetwork = localNetwork ?? ensureLocalNetwork,
       _now = clock ?? DateTime.now,
       _session = session ?? sharedSession {
    _session.addListener(_sessionChanged);
    sharedAlert.addListener(_alertChanged);
    _network = networkChanges?.listen((_) => unawaited(_host?.networkChanged()), onError: (Object _) {});
  }

  /// Android's network changes (NetworkWatch): the server looks at its Wi-Fi again at once.

  /// Android 17's local-network permission (local_network.dart, DECISIONS 758): asked when the owner switches sharing
  /// on or pairs; the minute's look only reads the last answer, so a refusal is not asked about again and again.
  final Future<bool> Function() _localNetwork;
  bool? _lan;

  /// Whether the app may use the local network; [ask]: the owner just asked for it, so the permission may be asked.
  Future<bool> _mayUseLan({bool ask = false}) async {
    if (_lan == true || (_lan == false && !ask)) return _lan!;
    try {
      _lan = await _localNetwork();
    } catch (_) {
      _lan = true; // no answer (no Android): the socket says the rest
    }
    return _lan!;
  }

  /// Arms or ends Android's push job (`Phone.pushSchedule`; tests count the calls).
  final Future<void> Function(bool on) pushSchedule;

  /// The daytime session that holds the headband (lib/share/shared_session.dart), for /state (DECISIONS 671).
  final ValueListenable<Map<String, Object?>?> _session;

  StreamSubscription<void>? _network;

  /// The session's summary to the server (/state's `session`), with the newest headband notice beside it (`alert`,
  /// DECISIONS 857).
  /// While a recording runs the recorder's service serves, so it is told too (a session that runs as an activity of
  /// the recording, Record first step 4): the paired laptop's tray keeps seeing the work session.
  void _sessionChanged() {
    final session = sessionWithAlert(_session.value, sharedAlert.value);
    _host?.setSession(session);
    sendToRecorder({'kind': shareSessionKind, 'session': session});
  }

  void _alertChanged() => _sessionChanged();

  final Future<ShareConfig> Function() load;
  final Future<void> Function(ShareConfig config) save;

  /// Sends the setting to the recorder's service while a night runs.
  final void Function(Map<String, Object?> message) sendToRecorder;
  final Future<void> Function(bool on) keepScreenOn;

  /// Keeps the phone's Wi-Fi awake while the app's own server runs between nights, also with the screen off and
  /// during a session (`Phone.wifiLock` as `screen`); null in tests that do not look at it.
  final Future<void> Function(bool on)? wifiLock;
  final ShareHostMaker _makeHost;
  final DateTime Function() _now;

  /// Between nights the app's server also takes the paired laptop's work signal for automatic recording (DECISIONS
  /// 603): kept in `auto-start/laptop.json`, and a start asks the headband watcher for a check.
  static ShareHost _appHost(String filesDir, void Function(ShareStatus) onChange, Future<void> Function(bool on)? lock) =>
      ShareHost(
        filesDir: filesDir,
        onLog: debugPrint,
        onChange: onChange,
        wifi: Phone.wifiNets,
        wifiLock: lock,
        onWork: (working, meeting) => unawaited(laptopWorkSignal(working: working, meeting: meeting)),
      );

  ShareConfig _config = const ShareConfig();
  ShareStatus _status = shareDown;
  ShareHost? _host;
  bool _night = false;
  bool _awake = false;
  String? _filesDir;
  Future<void> _queue = Future.value();

  ShareConfig get config => _config;

  /// Counts the laptop's proofs before deleting (recheck.dart): the night screen deletes what is now proven.
  final ValueNotifier<int> proofs = ValueNotifier(0);

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
    _armPush();
    notifyListeners();
  });

  Future<void> setOn(bool value) => _serial(() async {
    if (value) await _mayUseLan(ask: true);
    _config = value ? _config.switchedOn(_now().millisecondsSinceEpoch) : _config.switchedOff();
    await save(_config);
    await _apply();
  });

  Future<void> newToken() => _serial(() async {
    _config = _config.withNewToken();
    await save(_config);
    await _apply();
  });

  /// Pairs with the laptop of [link] (DECISIONS rows 530-539, 753), after the owner tapped Connect. The laptop proves
  /// the one-time code first; both sides then work out the same key (nothing secret crosses the Wi-Fi). Only when it
  /// worked is sharing switched on, if it was off, and the laptop remembered. A failure changes nothing but a token
  /// made for the occasion.
  Future<PairOutcome> pair(PairLink link, {LinkClient? client}) {
    final done = Completer<PairOutcome>();
    unawaited(
      _serial(() async {
        try {
          if (!await _mayUseLan(ask: true)) throw const LinkError(LinkFailure.localNetwork);
          var c = await load();
          if (c.token.length < tokenLength) {
            c = c.withNewToken(); // the server needs a token for the cable and for tools given the code by hand
            await save(c);
            _config = c;
          }
          final answer = await (client ?? LinkClient()).pair(host: link.host, port: link.port, code: link.code, sharePort: c.port);
          final nowMs = _now().millisecondsSinceEpoch;
          final laptop = PairedLaptop(host: link.host, port: link.port, key: answer.key, name: answer.name, pairedAtMs: nowMs);
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

  /// "Share here for 12 hours" (DECISIONS 752): a paired phone also shares on the Wi-Fi it is on now, which is not
  /// its home; [on] false ends it at once.
  Future<void> shareHere(bool on) => _serial(() async {
    final c = await load();
    _config = on ? c.sharedHere(_now().millisecondsSinceEpoch, _status.net) : c.notHere();
    await save(_config);
    await _apply();
  });

  /// Forgets the paired laptop: its signed requests are refused from now on (the token it never had is not needed).
  Future<void> forgetLaptop() => _serial(() async {
    _config = (await load()).withLaptop(null);
    await save(_config);
    await _apply();
  });

  /// Before the recorder's service starts: the app lets go of the port.
  Future<void> beforeNight() => _serial(() async {
    _night = true;
    await _stopHost();
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

  /// Android's job that sends the paired laptop what it lacks (push/; DECISIONS 840-849): armed while sharing is on
  /// and a laptop is paired, ended otherwise; told to Android only when that changes.
  bool? _pushArmed;
  void _armPush() {
    final want = _config.paired && _config.activeAt(_now().millisecondsSinceEpoch);
    if (want == _pushArmed) return;
    _pushArmed = want;
    unawaited(pushSchedule(want));
  }

  Future<void> _apply() async {
    _armPush();
    if (_night) {
      await _stopHost();
      sendToRecorder({'kind': 'share', 'config': _config.toJson()});
    } else {
      await _stopHost();
      await _serveFromApp();
      final now = _now().millisecondsSinceEpoch;
      await _keepAwake(_config.activeAt(now) && now < _config.awakeUntilMs, front: true);
    }
    notifyListeners();
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
    if (_lan == false || (_lan == null && !await _mayUseLan())) {
      await _stopHost();
      _status = shareDown;
      return;
    }
    final host = _host = _makeHost(dir, (s) {
      if (_night) return;
      _status = s;
      notifyListeners();
    }, wifiLock);
    host.onProved = (n) => proofs.value += n;
    host.setLive(const {});
    host.setSession(sessionWithAlert(_session.value, sharedAlert.value));
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

  /// The line under the switch: whether it shares, where, and when the laptop last copied (DECISIONS 752: this, the
  /// sheet and the laptop's tray say it, not a notification).
  ShareLine line() {
    final nowMs = _now().millisecondsSinceEpoch;
    final old = _config.oldLaptop;
    if (_lan == false && _config.activeAt(nowMs)) return (on: true, text: lanBlockedText, warn: true, address: null);
    if (!_config.activeAt(nowMs)) {
      if (old != null && !_config.paired) {
        return (on: false, text: 'Paired with $old before this update: pair once more (one scan of its code) to share safely.', warn: true, address: null);
      }
      return (on: false, text: 'Lets your laptop watch the signal and copy the files over your home Wi-Fi.', warn: false, address: null);
    }
    final at = shareAddress(_status);
    final laptop = _config.laptop;
    final copied = copiedText(_status, laptop?.name);
    if (at != null && laptop != null) {
      final text = switch (_status.here) {
        'home' => 'On, on your home Wi-Fi, for ${laptop.name}. $copied',
        'here' => 'On, on this Wi-Fi until ${clockText(DateTime.fromMillisecondsSinceEpoch(_config.hereUntilMs))} (allowed by you). $copied',
        _ => 'Paused on this Wi-Fi until ${laptop.name} says it is your home Wi-Fi. Not at home? Address and code: Share here.',
      };
      return (on: true, text: text, warn: false, address: at);
    }
    if (at != null) {
      final until = 'until ${clockText(DateTime.fromMillisecondsSinceEpoch(_config.offAtMs))}';
      return (
        on: true,
        text: _night ? 'On at $at $until.' : 'On at $at $until. Keep this app open while the laptop copies.',
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
    proofs.dispose();
    _session.removeListener(_sessionChanged);
    sharedAlert.removeListener(_alertChanged);
    unawaited(_network?.cancel());
    unawaited(_stopHost());
    super.dispose();
  }
}

/// Android 17 blocks the local network for this app (DECISIONS 758).
const String lanBlockedText =
    'Android blocks the local network for this app. Allow "Nearby devices" in Settings, Apps, EEG tracker, '
    'Permissions, then switch sharing off and on.';

/// `07:40`.
String clockText(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Last copied by my-laptop at 14:05." (or "on 19 Nov at 14:05" before today), or "Nothing copied yet.".
String copiedText(ShareStatus s, String? laptop, {DateTime? now}) {
  if (s.copiedAtMs <= 0) return 'Nothing copied yet.';
  final at = DateTime.fromMillisecondsSinceEpoch(s.copiedAtMs), today = now ?? DateTime.now();
  final by = switch (s.copiedBy) {
    'laptop' => laptop ?? 'the paired laptop',
    'cable' => 'a computer on the USB cable',
    _ => 'a device with the code',
  };
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final sameDay = at.year == today.year && at.month == today.month && at.day == today.day;
  return 'Last copied by $by ${sameDay ? '' : 'on ${at.day} ${months[at.month - 1]} '}at ${clockText(at)}.';
}
