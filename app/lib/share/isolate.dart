// Share on Wi-Fi: where the server runs (DECISIONS row 221). The server lives in a Dart isolate of its own, with
// its own memory and event loop. The isolate that records (the night recorder's service isolate, or the app
// between nights) only ever *sends* to it: sample batches and a status map through a port, which never waits
// and never blocks. A crash, an exception or a hang in the server therefore cannot stop or slow the recording;
// [ShareHost] hears that the isolate ended, writes one log line and stops feeding it.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../recorder/chunk_writer.dart';
import 'link.dart';
import 'protocol.dart';
import 'server.dart';

/// How often the phone's Wi-Fi address is looked at again (a new lease, another network).
const Duration _addressCheck = Duration(seconds: 60);

/// How long the host waits for Android's answer about the Wi-Fi address.
const Duration _wifiWait = Duration(seconds: 3);

/// The other host (the app, or the recorder) may still hold the port at a hand-over: for a moment after Stop, and up
/// to a minute when the night starts from another screen (the dream catcher's or sound's "Record the night"), since
/// the night screen lets go of the app's server at its once-a-minute sync. So tries cover 80 s.
const int _bindTries = 40;

/// How long after its last file request the laptop still counts as copying.
const Duration copyingQuiet = Duration(seconds: 15);
const Duration _bindWait = Duration(seconds: 2);

/// What a host passes to the isolate, with Android's first answer about the Wi-Fi address. A plain list crosses the
/// isolate border.
List<Object?> shareIsolateArgs(SendPort toHost, String filesDir, ShareConfig c, [WifiNets wifi = noWifiAnswer]) => [
  toHost,
  filesDir,
  c.token,
  c.port,
  c.offAtMs,
  wifi.nets,
  wifi.note,
  c.laptop?.toJson(), // the paired laptop, told where this phone is (link.dart)
];

/// The server isolate. Messages in: `['b', stem, first, t, Float32List]` a batch, `['s', map]` the status,
/// `['m', id, t, i]` a marker's answer (t null = not recording), `['w', nets, note]` Android's answer about the
/// Wi-Fi address again, `['x']` stop. Messages out: `['port', SendPort]`, `['up', addresses, port, why]` (why: empty,
/// or what each source returned when no Wi-Fi address was found), `['marker', id, text]`, `['copying', n]` file
/// requests being answered, `['error', text]` an error that did not stop it, `['log', line]` (the paired laptop),
/// `['down', why]`.
///
/// Every error inside it is caught (DECISIONS row 587): before the server listens it ends the isolate the orderly way
/// (`['down', ...]`); after, it is reported and the server goes on answering. An uncaught error (running out of memory
/// while a long night was scored, most likely) used to end the isolate at once, and a dead isolate keeps its
/// listening socket: the system kept accepting the laptop's connections into the socket's queue with nobody to take
/// them, until even the phone's own connects timed out, and no new server could listen until the app was closed.
@pragma('vm:entry-point')
Future<void> shareIsolateMain(List<Object?> args) => guardedShare(args, serveShare);

/// Runs [body] (the server's setup) in a zone that catches every error, as [shareIsolateMain] says. [body] gets a
/// setter for what to do with an error once the server listens.
Future<void> guardedShare(
  List<Object?> args,
  Future<void> Function(List<Object?> args, void Function(void Function(Object e) onError) setOnError) body,
) {
  final toHost = args[0]! as SendPort;
  final ready = Completer<void>();
  void Function(Object e)? onError;
  runZonedGuarded(
    () => body(args, (f) => onError = f).whenComplete(() {
      if (!ready.isCompleted) ready.complete();
    }),
    (Object e, StackTrace _) {
      try {
        final handle = onError;
        if (handle != null) return handle(e);
        toHost.send(['down', 'failed: $e']); // before it listens: nothing to keep
        if (!ready.isCompleted) ready.complete();
      } catch (_) {
        // even reporting failed (out of memory): the server must still go on answering
      }
    },
  );
  return ready.future;
}

/// The server's setup: its messages, the bind, the off timer and the Wi-Fi look.
Future<void> serveShare(List<Object?> args, void Function(void Function(Object e) onError) setOnError) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  final waiting = <int, Completer<MarkerResult?>>{};
  var nextId = 0;
  WifiNets android = (
    nets: [for (final n in args.length > 5 ? args[5]! as List : const <Object?>[]) n as String],
    note: args.length > 6 ? args[6]! as String : noWifiAnswer.note,
  );
  final server = ShareServer(
    filesDir: Directory(args[1]! as String),
    token: args[2]! as String,
    port: args[3]! as int,
    onMarker: (text) {
      final id = nextId++;
      final c = waiting[id] = Completer<MarkerResult?>();
      toHost.send(['marker', id, text]);
      return c.future.whenComplete(() => waiting.remove(id));
    },
    hashCache: File('${args[1]! as String}/cache/share-hashes.json'),
    onCopying: (n) => toHost.send(['copying', n]),
  );
  Timer? addressTimer;
  Timer? offTimer;
  LaptopAnnouncer? announcer;
  var closing = false;

  /// The bind in flight: [end] waits for it, so a socket it opens is closed too (a killed isolate keeps its
  /// sockets open, so this isolate closes them itself before it says it is down).
  Future<void>? binding;

  Future<void> end(String why) async {
    if (closing) return;
    closing = true;
    addressTimer?.cancel();
    offTimer?.cancel();
    announcer?.stop();
    try {
      await binding?.timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await server.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    toHost.send(['down', why]);
    inbox.close();
  }

  // Which Wi-Fi networks to show and answer (DECISIONS rows 560-562): Android's answer, else Dart's interface list.
  var bound = false;
  var shown = '';
  Future<void> lookNow() async {
    if (!bound || closing) return;
    var chosen = chooseLan(android);
    if (chosen.nets.isEmpty) {
      try {
        chosen = chooseLan(android, interfaces: await NetworkInterface.list(type: InternetAddressType.IPv4));
      } catch (e) {
        chosen = chooseLan(android, interfaceError: e);
      }
    }
    if (closing) return;
    server.lan = chosen.nets;
    final now = '${server.addresses.join(',')} ${chosen.why}';
    if (now == shown) return;
    shown = now;
    toHost.send(['up', server.addresses, server.boundPort, chosen.why]);
  }

  // One look at a time; a request during one (Android's new answer) runs one more after it.
  Future<void>? looking;
  var lookAgain = false;
  Future<void> look() {
    final busy = looking;
    if (busy != null) {
      lookAgain = true;
      return busy;
    }
    return looking = () async {
      try {
        do {
          lookAgain = false;
          await lookNow();
        } while (lookAgain && !closing);
      } finally {
        looking = null;
      }
    }();
  }

  inbox.listen((Object? m) {
    if (m is! List || m.isEmpty) return;
    switch (m[0]) {
      case 'b':
        server.addBatch(m[1] as String, m[2] as int, m[3] as double, m[4] as Float32List);
      case 's':
        server.setLive(m[1] as Map);
      case 'm':
        final t = m[2], i = m[3];
        waiting[m[1]]?.complete(t is double && i is int ? (t: t, i: i) : null);
      case 'w':
        android = (nets: [for (final n in m[1] as List) n as String], note: m[2] as String);
        unawaited(look());
      case 'x':
        unawaited(end('stopped'));
    }
  });
  toHost.send(['port', inbox.sendPort]);

  for (var attempt = 1; ; attempt++) {
    try {
      await (binding = server.listen());
      bound = true;
      break;
    } catch (e) {
      if (attempt >= _bindTries) {
        await end('could not listen on port ${server.port}: $e');
        return;
      }
      await Future<void>.delayed(_bindWait);
      if (closing) return;
    }
  }
  if (closing) return; // stopped while binding: end() closed what was bound
  var said = 0;
  setOnError((e) {
    if (closing || ++said > 5) return; // the first few are enough to find it
    final text = '$e';
    toHost.send(['error', text.length > 300 ? '${text.substring(0, 300)}...' : text]);
  });
  final laptop = PairedLaptop.fromJson(args.length > 7 ? args[7] : null);
  if (laptop != null) {
    announcer = LaptopAnnouncer(
      laptop: laptop,
      sharePort: server.boundPort,
      token: args[2]! as String,
      onLine: (line) => toHost.send(['log', 'sharing on Wi-Fi: $line']),
    )..start();
  }
  final left = (args[4]! as int) - DateTime.now().millisecondsSinceEpoch;
  offTimer = Timer(Duration(milliseconds: left < 0 ? 0 : left), () => unawaited(end('time is up')));
  await look();
  if (closing) return;
  addressTimer = Timer.periodic(_addressCheck, (_) => unawaited(look()));
}

/// What the screen and the notification show.
typedef ShareStatus = ({bool up, List<String> addresses, int port, String note});

const ShareStatus shareDown = (up: false, addresses: <String>[], port: sharePort, note: '');

/// Owns the server isolate from the recording side. Every method is safe to call at any time and never throws.
class ShareHost {
  ShareHost({
    required this.filesDir,
    required this.onLog,
    this.onMarker,
    this.onChange,
    this.wifiLock,
    this.wifi,
    this.entry = shareIsolateMain,
  });

  final String filesDir;

  /// One line when sharing starts, and one when it stops or fails.
  final void Function(String line) onLog;

  /// Writes a marker into the run being recorded; null when nothing records.
  final MarkerResult? Function(String text)? onMarker;
  final void Function(ShareStatus status)? onChange;

  /// Keeps Wi-Fi awake with the screen off (PhoneChannel.kt); only the night recorder passes it.
  final Future<void> Function(bool on)? wifiLock;

  /// Android's own answer about the phone's Wi-Fi address (`Phone.wifiNets`, PhoneChannel.kt), asked before the
  /// server starts and every minute; it runs here because the server's isolate has no platform channel. Null in
  /// tests: the server then uses Dart's interface list alone.
  final Future<WifiNets> Function()? wifi;

  /// Tests replace the server with one that throws.
  final Future<void> Function(List<Object?> args) entry;

  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _port;
  ShareStatus _status = shareDown;
  bool _ended = true;
  Map<Object?, Object?>? _live;
  Timer? _wifiTimer;
  String _why = '';

  ShareStatus get status => _status;
  bool get running => !_ended;

  Future<void> start(ShareConfig config) async {
    if (!_ended) return;
    try {
      if (!config.activeAt(DateTime.now().millisecondsSinceEpoch)) return;
      _ended = false;
      final events = _events = ReceivePort();
      events.listen(_onEvent);
      final wifiNow = await _askWifi();
      if (_ended) return;
      if (_stopped != null) return _end('sharing on Wi-Fi off'); // Stop came while Android answered: no server
      _isolate = await Isolate.spawn(
        entry,
        shareIsolateArgs(events.sendPort, filesDir, config, wifiNow),
        onError: events.sendPort,
        onExit: events.sendPort,
        errorsAreFatal: true,
        debugName: 'share',
      );
      ChunkWriter.onBatch = feed;
      _lock(true);
      if (wifi != null) _wifiTimer = Timer.periodic(_addressCheck, (_) => unawaited(_sendWifi()));
    } catch (e) {
      _end('sharing on Wi-Fi could not start: $e');
    }
  }

  /// Android's answer, or what went wrong asking; never throws, never waits more than [_wifiWait].
  Future<WifiNets> _askWifi() async {
    final ask = wifi;
    if (ask == null) return noWifiAnswer;
    try {
      return await ask().timeout(_wifiWait);
    } catch (e) {
      final text = '$e';
      return (nets: const <String>[], note: 'failed: ${text.length > 120 ? text.substring(0, 120) : text}');
    }
  }

  Future<void> _sendWifi() async {
    final w = await _askWifi();
    try {
      _port?.send(['w', w.nets, w.note]);
    } catch (_) {}
  }

  /// A batch from [ChunkWriter.addBatch]: copied into one small list and sent; nothing is awaited.
  void feed(String stem, int first, DateTime arrival, List<Sample> samples) {
    final port = _port;
    if (port == null) return;
    try {
      final v = Float32List(samples.length * 4);
      var o = 0;
      for (final s in samples) {
        v[o] = s.o1;
        v[o + 1] = s.o2;
        v[o + 2] = s.t3;
        v[o + 3] = s.t4;
        o += 4;
      }
      port.send(['b', stem, first, unixSeconds(arrival), v]);
    } catch (e) {
      _end('sharing on Wi-Fi stopped: $e');
    }
  }

  /// The recorder's status (`RecorderStatus.toMap`), about once a second.
  void setLive(Map<Object?, Object?> live) {
    _live = live;
    try {
      _port?.send(['s', live]);
    } catch (e) {
      _end('sharing on Wi-Fi stopped: $e');
    }
  }

  Future<void> stop() async {
    if (_ended) return;
    try {
      _port?.send(['x']);
      final done = Completer<void>();
      _stopped = done;
      await done.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    } catch (_) {}
    _end('sharing on Wi-Fi off');
  }

  Completer<void>? _stopped;
  int _copying = 0;
  DateTime? _copiedAt;

  /// The laptop is copying files: a file request is being answered, or one ended under [copyingQuiet] ago (the
  /// laptop asks for the next file at once). The night's sleep scoring waits meanwhile (DECISIONS row 583).
  bool get copying {
    if (_ended) return false;
    final at = _copiedAt;
    return _copying > 0 || (at != null && DateTime.now().difference(at) < copyingQuiet);
  }

  void _onEvent(Object? m) {
    try {
      if (m == null) return _end('sharing on Wi-Fi stopped: the server ended'); // onExit
      if (m is! List || m.isEmpty) return;
      switch (m[0]) {
        case 'port':
          _port = m[1] as SendPort;
          if (_stopped != null) {
            // Stop came before the server was ready: it must still close its sockets itself (a killed isolate
            // keeps them open, and the port with them), so it gets the stop message now.
            _port!.send(['x']);
            return;
          }
          final live = _live;
          if (live != null) _port!.send(['s', live]);
        case 'up':
          final addresses = [for (final a in m[1] as List) a as String];
          final first = !_status.up, moved = addresses.join(',') != _status.addresses.join(',');
          _status = (up: true, addresses: addresses, port: m[2] as int, note: '');
          if (first) {
            onLog('sharing on Wi-Fi on: ${_where(_status)}');
          } else if (moved) {
            onLog('sharing on Wi-Fi now at ${_where(_status)}');
          }
          final why = m.length > 3 && m[3] is String ? m[3] as String : '';
          if (why.isNotEmpty && why != _why) {
            // what each source returned, once per change: in the night's log and in logcat (tag "flutter")
            debugPrint('eeg_tracker share: $why');
            onLog('sharing on Wi-Fi: ${why.length > 400 ? '${why.substring(0, 400)}...' : why}');
          }
          _why = why;
          onChange?.call(_status);
        case 'marker':
          MarkerResult? r;
          try {
            r = onMarker?.call(m[2] as String);
          } catch (_) {
            r = null;
          }
          _port?.send(['m', m[1], r?.t, r?.i]);
        case 'copying':
          _copying = m[1] as int;
          _copiedAt = DateTime.now();
        case 'error':
          // the server goes on answering; the error goes to logcat (tag "flutter") and the night's log
          debugPrint('eeg_tracker share: an error in the server, which goes on: ${m[1]}');
          onLog('sharing on Wi-Fi: an error in the server, which goes on: ${m[1]}');
        case 'log':
          onLog(m[1] as String);
        case 'down':
          _end(m[1] == 'stopped' ? 'sharing on Wi-Fi off' : 'sharing on Wi-Fi off: ${m[1]}');
        default:
          // onError sends [error, stack] as two strings
          _end('sharing on Wi-Fi stopped by an error: ${m[0]}');
      }
    } catch (e) {
      _end('sharing on Wi-Fi stopped: $e');
    }
  }

  void _end(String line) {
    if (_ended) return;
    _ended = true;
    _port = null;
    _wifiTimer?.cancel();
    _wifiTimer = null;
    _why = '';
    if (ChunkWriter.onBatch == feed) ChunkWriter.onBatch = null;
    try {
      _events?.close();
    } catch (_) {}
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _isolate = null;
    _lock(false);
    _status = (up: false, addresses: const <String>[], port: _status.port, note: line);
    try {
      onLog(line.length > 200 ? '${line.substring(0, 200)}...' : line);
    } catch (_) {}
    try {
      onChange?.call(_status);
    } catch (_) {}
    final s = _stopped;
    _stopped = null;
    if (s != null && !s.isCompleted) s.complete();
  }

  void _lock(bool on) {
    final lock = wifiLock;
    if (lock == null) return;
    unawaited(lock(on).then((_) {}, onError: (Object _) {}));
  }
}

String _where(ShareStatus s) {
  final lan = s.addresses.where((a) => a != '127.0.0.1').toList();
  return lan.isEmpty ? 'no Wi-Fi address yet, port ${s.port}' : '${lan.join(', ')} port ${s.port}';
}

/// `192.168.1.23:8765`, or null without a Wi-Fi address.
String? shareAddress(ShareStatus s) {
  final lan = s.addresses.where((a) => a != '127.0.0.1').toList();
  return !s.up || lan.isEmpty ? null : '${lan.first}:${s.port}';
}
