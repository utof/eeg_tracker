// Share on Wi-Fi: where the server runs (DECISIONS row 221). The server lives in a Dart isolate of its own, with
// its own memory and event loop. The isolate that records (the night recorder's service isolate, or the app
// between nights) only ever *sends* to it: sample batches and a status map through a port, which never waits
// and never blocks. A crash, an exception or a hang in the server therefore cannot stop or slow the recording;
// [ShareHost] hears that the isolate ended, writes one log line and stops feeding it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

import '../logs/activity.dart' show Activity;
import '../logs/log.dart' show AppLog;
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

/// After this many tries (about 15 s) the next ports are tried too.
const int _spareAfter = 7;

/// How many ports after the asked one may be used instead (8766-8768 for 8765).
const int sparePorts = 3;

/// What holds [port] on this phone, in words for the log: asked on the phone itself, at most about 4 s.
Future<String> whoHolds(int port) async {
  Socket? s;
  try {
    s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
  } catch (_) {
    return 'nothing answers there, yet Android says it is in use';
  }
  try {
    s.write('GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n');
    await s.flush();
    final first = await s.timeout(const Duration(seconds: 2)).first;
    final text = String.fromCharCodes(first.take(400));
    return text.contains('"error"') && text.startsWith('HTTP/1.')
        ? 'an EEG Tracker server already answers there'
        : 'another program answers there';
  } catch (_) {
    return 'something listens there and does not answer';
  } finally {
    s.destroy();
  }
}

/// How long after its last file request the laptop still counts as copying.
const Duration copyingQuiet = Duration(seconds: 15);
const Duration _bindWait = Duration(seconds: 2);

/// What a host passes to the isolate, with Android's first answer about the Wi-Fi address. A plain list crosses the
/// isolate border. [work]: the host takes the laptop's work signal (`POST /work`; the app between nights).
List<Object?> shareIsolateArgs(
  SendPort toHost,
  String filesDir,
  ShareConfig c, [
  WifiNets wifi = noWifiAnswer,
  bool work = false,
]) => [
  toHost,
  filesDir,
  c.token,
  c.port,
  c.endsAtMs ?? -1, // -1: no end while a laptop is paired (DECISIONS 675)
  wifi.nets,
  wifi.note,
  c.laptop?.toJson(), // the paired laptop: its signed requests are checked with its key (server.dart)
  work,
  c.hereUntilMs, // "Share here for 12 hours" (DECISIONS 752)
  c.hereNet,
];

/// The server isolate. Messages in: `['b', stem, first, t, Float32List]` a batch, `['s', map]` the status,
/// `['m', id, t, i]` a marker's answer (t null = not recording), `['w', nets, note]` Android's answer about the
/// Wi-Fi address again, `['n']` Android said the network changed (home is forgotten: DECISIONS 752), `['k', map or null]` the daytime session for /state, `['x']` stop. Messages out:
/// `['port', SendPort]`, `['up', addresses, port, why]` (why: empty, or what each source returned when no Wi-Fi
/// address was found), `['marker', id, text]`, `['copying', n]` file requests being answered, `['work', working,
/// meeting]` the laptop's work signal, `['here', state]` what the phone says of its Wi-Fi (server.dart
/// `sharingStates`), `['copied', by]` a file was sent (`laptop`, `code` or `cable`), `['proved', n]` the laptop proved
/// it still holds n files asked about before deleting (recheck.dart), `['error', text]` an error that did not stop it,
/// `['log', line]`, `['down', why]`.
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
  late final ShareServer server;
  server = ShareServer(
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
    onWork: args.length > 8 && args[8] == true ? (working, meeting) => toHost.send(['work', working, meeting]) : null,
    key: PairedLaptop.fromJson(args.length > 7 ? args[7] : null)?.key, // the paired laptop's signatures
    hereUntilMs: args.length > 9 && args[9] is int ? args[9]! as int : 0,
    hereNet: args.length > 10 && args[10] is String ? args[10]! as String : null,
    onHere: (h) => toHost.send(['here', h, lanSignature(server.lanNets)]),
    onCopied: (by) => toHost.send(['copied', by]),
    onProved: (n) => toHost.send(['proved', n]),
  );
  Timer? addressTimer;
  Timer? offTimer;
  var closing = false;

  // what the laptop copied, every 10 minutes it copied anything (the app log, DECISIONS 718)
  var told = (files: 0, bytes: 0);
  void tellCopied() {
    final f = server.servedFiles - told.files, b = server.servedBytes - told.bytes;
    if (f == 0) return;
    told = (files: server.servedFiles, bytes: server.servedBytes);
    toHost.send(['log', 'sharing on Wi-Fi: the laptop fetched $f files or parts of files, ${(b / 1e6).toStringAsFixed(1)} MB']);
  }

  final copiedTimer = Timer.periodic(const Duration(minutes: 10), (_) => tellCopied());

  /// The bind in flight: [end] waits for it, so a socket it opens is closed too (a killed isolate keeps its
  /// sockets open, so this isolate closes them itself before it says it is down).
  Future<void>? binding;

  Future<void> end(String why) async {
    if (closing) return;
    closing = true;
    addressTimer?.cancel();
    offTimer?.cancel();
    copiedTimer.cancel();
    tellCopied();
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
        server.addBatch(m[1] as String, m[2] as int, m[3] as double, m[4] as Float32List, channels: m.length > 5 ? m[5] as int : 4);
      case 's':
        server.setLive(m[1] as Map);
      case 'm':
        final t = m[2], i = m[3];
        waiting[m[1]]?.complete(t is double && i is int ? (t: t, i: i) : null);
      case 'w':
        android = (nets: [for (final n in m[1] as List) n as String], note: m[2] as String);
        unawaited(look());
      case 'n':
        server.networkChanged();
      case 'k': // the daytime session that holds the headband, for /state (DECISIONS 671)
        server.setSession(m[1] as Map<Object?, Object?>?);
      case 'x':
        unawaited(end('stopped'));
    }
  });
  toHost.send(['port', inbox.sendPort]);

  // The port asked for; when it stays taken for [_spareAfter] tries, also the next [sparePorts] ones (the paired
  // laptop looks at them too: scripts/phone_link.py), so something else holding the port never ends sharing.
  for (var attempt = 1; !bound; attempt++) {
    Object? why;
    for (final p in [server.port, if (attempt > _spareAfter) for (var k = 1; k <= sparePorts; k++) server.port + k]) {
      try {
        await (binding = server.listen(on: p));
        bound = true;
        break;
      } catch (e) {
        why ??= e;
        if (closing) return;
      }
    }
    if (bound) break;
    if (attempt >= _bindTries) {
      await end('could not listen on port ${server.port} or the next $sparePorts: $why; ${await whoHolds(server.port)}');
      return;
    }
    await Future<void>.delayed(_bindWait);
    if (closing) return;
  }
  if (closing) return; // stopped while binding: end() closed what was bound
  if (server.boundPort != server.port) {
    final holder = await whoHolds(server.port);
    if (closing) return;
    toHost.send(['log', 'sharing on Wi-Fi: port ${server.port} is taken ($holder); using port ${server.boundPort}']);
  }
  var said = 0;
  setOnError((e) {
    if (closing || ++said > 5) return; // the first few are enough to find it
    final text = '$e';
    toHost.send(['error', text.length > 300 ? '${text.substring(0, 300)}...' : text]);
  });
  final offAt = args[4]! as int;
  if (offAt >= 0) {
    final left = offAt - DateTime.now().millisecondsSinceEpoch;
    offTimer = Timer(Duration(milliseconds: left < 0 ? 0 : left), () => unawaited(end('time is up')));
  }
  await look();
  if (closing) return;
  toHost.send(['here', server.here, lanSignature(server.lanNets)]);
  addressTimer = Timer.periodic(_addressCheck, (_) => unawaited(look()));
}

/// What the screen shows: whether it serves, where, why not; [here] what the phone says of its Wi-Fi (server.dart
/// `sharingStates`: open, home, here, waiting); [copiedAtMs] and [copiedBy] the last file sent and to whom
/// (`laptop`, `code`, `cable`; 0 and empty for none yet).
/// [net] the Wi-Fi network as "home" and "Share here" remember it (protocol.dart `lanSignature`).
typedef ShareStatus = ({bool up, List<String> addresses, int port, String note, String here, String net, int copiedAtMs, String copiedBy});

const ShareStatus shareDown = (up: false, addresses: <String>[], port: sharePort, note: '', here: '', net: '', copiedAtMs: 0, copiedBy: '');

/// [s] with some fields changed.
ShareStatus shareStatusWith(
  ShareStatus s, {
  bool? up,
  List<String>? addresses,
  int? port,
  String? note,
  String? here,
  String? net,
  int? copiedAtMs,
  String? copiedBy,
}) => (
  up: up ?? s.up,
  addresses: addresses ?? s.addresses,
  port: port ?? s.port,
  note: note ?? s.note,
  here: here ?? s.here,
  net: net ?? s.net,
  copiedAtMs: copiedAtMs ?? s.copiedAtMs,
  copiedBy: copiedBy ?? s.copiedBy,
);

/// `files/transfer/copied.json`: when a file was last sent and to whom, so the screen says it after a restart too.
File _copiedFile(String filesDir) => File('$filesDir/transfer/copied.json');

({int atMs, String by}) readCopied(String filesDir) {
  try {
    final j = jsonDecode(_copiedFile(filesDir).readAsStringSync());
    final at = j is Map ? j['at_ms'] : null, by = j is Map ? j['by'] : null;
    if (at is int && by is String && const ['laptop', 'code', 'cable'].contains(by)) return (atMs: at, by: by);
  } catch (_) {}
  return (atMs: 0, by: '');
}

/// Also the push (push/run.dart), when the laptop took files from it.
void writeCopied(String filesDir, int atMs, String by) {
  try {
    final f = _copiedFile(filesDir);
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode({'at_ms': atMs, 'by': by}), flush: true);
    tmp.renameSync(f.path);
  } catch (_) {
    // the screen then says it from memory only
  }
}

/// Owns the server isolate from the recording side. Every method is safe to call at any time and never throws.
final AppLog _log = AppLog('share');

class ShareHost {
  ShareHost({
    required this.filesDir,
    required this.onLog,
    this.onMarker,
    this.onChange,
    this.wifiLock,
    this.wifi,
    this.onWork,
    this.entry = shareIsolateMain,
  });

  final String filesDir;

  /// One line when sharing starts, and one when it stops or fails.
  final void Function(String line) onLog;

  /// Writes a marker into the run being recorded; null when nothing records.
  final MarkerResult? Function(String text)? onMarker;
  final void Function(ShareStatus status)? onChange;

  /// Keeps Wi-Fi awake while the server runs (PhoneChannel.kt): true after it starts, false when it ends however it
  /// ends. The recorder's service and the app's own server between nights pass it, each under its own name.
  final Future<void> Function(bool on)? wifiLock;

  /// Android's own answer about the phone's Wi-Fi address (`Phone.wifiNets`, PhoneChannel.kt), asked before the
  /// server starts and every minute; it runs here because the server's isolate has no platform channel. Null in
  /// tests: the server then uses Dart's interface list alone.
  final Future<WifiNets> Function()? wifi;

  /// The paired laptop's work signal (`POST /work`): a work session started ([working]) or ended there. Only the app
  /// between nights takes it (automatic recording, lib/auto/laptop.dart); null: the server answers 503.
  final void Function(bool working, bool? meeting)? onWork;

  /// Tests replace the server with one that throws.
  final Future<void> Function(List<Object?> args) entry;

  /// The laptop proved it still holds files asked about before deleting (recheck.dart): the app may delete them now.
  void Function(int proven)? onProved;

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

  /// When the server came up (its uptime goes into the app log at the end).
  DateTime? _upSince;

  /// A line for the night's log (or logcat) and the app log.
  void _say(String line) {
    _log.info(line);
    onLog(line);
  }

  Future<void> start(ShareConfig config) async {
    if (!_ended) return;
    try {
      if (!config.activeAt(DateTime.now().millisecondsSinceEpoch)) return;
      _ended = false;
      final copied = readCopied(filesDir);
      _status = shareStatusWith(_status, copiedAtMs: copied.atMs, copiedBy: copied.by);
      final events = _events = ReceivePort();
      events.listen(_onEvent);
      final wifiNow = await _askWifi();
      if (_ended) return;
      if (_stopped != null) return _end('sharing on Wi-Fi off'); // Stop came while Android answered: no server
      _isolate = await Isolate.spawn(
        entry,
        shareIsolateArgs(events.sendPort, filesDir, config, wifiNow, onWork != null),
        onError: events.sendPort,
        onExit: events.sendPort,
        errorsAreFatal: true,
        debugName: 'share',
      );
      ChunkWriter.onBatch = feed;
      _lock(true);
      _upSince = DateTime.now();
      Activity.begin('share'); // for the battery samples (lib/logs, DECISIONS 715)
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
      if (samples.isEmpty) return;
      final n = samples.first.volts.length; // one recording: every sample as wide as its header says
      final v = Float32List(samples.length * n);
      var o = 0;
      for (final s in samples) {
        v.setRange(o, o + n, s.volts);
        o += n;
      }
      port.send(['b', stem, first, unixSeconds(arrival), v, n]);
    } catch (e) {
      _end('sharing on Wi-Fi stopped: $e');
    }
  }

  /// The daytime session that holds the headband (`WorkController.shareState`), or null: /state's `session`
  /// (DECISIONS 671). Kept, so a server that starts later gets it too.
  void setSession(Map<String, Object?>? session) {
    _session = session;
    try {
      _port?.send(['k', session]);
    } catch (e) {
      _end('sharing on Wi-Fi stopped: $e');
    }
  }

  Map<String, Object?>? _session;

  /// Android says a network came or went (`Phone.networkChanges`): the Wi-Fi address is asked again at once, so the
  /// server answers on the new network (and forgets that the old one was home) without waiting a minute.
  Future<void> networkChanged() async {
    if (_ended) return;
    try {
      _port?.send(['n']);
    } catch (_) {}
    if (wifi != null) await _sendWifi();
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
          final session = _session;
          if (session != null) _port!.send(['k', session]);
        case 'up':
          final addresses = [for (final a in m[1] as List) a as String];
          final first = !_status.up, moved = addresses.join(',') != _status.addresses.join(',');
          _status = shareStatusWith(_status, up: true, addresses: addresses, port: m[2] as int, note: '');
          // never the addresses themselves in a log (DECISIONS 757): the screen shows them, the logs leave the phone
          if (first) {
            _say('sharing on Wi-Fi on: ${_where(_status)}');
          } else if (moved) {
            _say('sharing on Wi-Fi: the Wi-Fi network changed (${_where(_status)})');
          }
          final why = m.length > 3 && m[3] is String ? redactAddresses(m[3] as String) : '';
          if (why.isNotEmpty && why != _why) {
            // what each source returned, once per change: in the night's log and in logcat (tag "flutter")
            debugPrint('eeg_tracker share: $why');
            _say('sharing on Wi-Fi: ${why.length > 400 ? '${why.substring(0, 400)}...' : why}');
          }
          _why = why;
          onChange?.call(_status);
        case 'here':
          final h = m[1] as String, net = m.length > 2 && m[2] is String ? m[2] as String : '';
          if (net != _status.net) {
            _status = shareStatusWith(_status, net: net);
            if (h == _status.here) onChange?.call(_status);
          }
          if (h != _status.here) {
            _status = shareStatusWith(_status, here: h);
            final words = switch (h) {
              'home' => 'the paired laptop says this is the home Wi-Fi',
              'here' => 'allowed on this Wi-Fi by hand',
              'waiting' => 'not shared on this Wi-Fi until the paired laptop says it is home',
              _ => null,
            };
            if (words != null) _say('sharing on Wi-Fi: $words');
            onChange?.call(_status);
          }
        case 'proved':
          _say('sharing on Wi-Fi: the laptop proved it still holds ${m[1]} files asked about before deleting');
          try {
            onProved?.call(m[1] as int);
          } catch (_) {}
        case 'copied':
          final now = DateTime.now().millisecondsSinceEpoch, by = m[1] as String;
          final again = now - _status.copiedAtMs < 60000 && by == _status.copiedBy;
          _status = shareStatusWith(_status, copiedAtMs: now, copiedBy: by);
          if (!again) {
            writeCopied(filesDir, now, by); // once a minute at most
            onChange?.call(_status);
          }
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
        case 'work':
          try {
            onWork?.call(m[1] == true, m.length > 2 && m[2] is bool ? m[2] as bool : null);
          } catch (_) {}
        case 'error':
          // the server goes on answering; the error goes to logcat (tag "flutter") and the night's log
          debugPrint('eeg_tracker share: an error in the server, which goes on: ${m[1]}');
          _say('sharing on Wi-Fi: an error in the server, which goes on: ${m[1]}');
        case 'log':
          _say(m[1] as String);
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
    _status = shareStatusWith(_status, up: false, addresses: const <String>[], note: line, here: '', net: '');
    try {
      final up = _upSince;
      _upSince = null;
      if (up != null) {
        Activity.end('share');
        _log.info('sharing on Wi-Fi ended after ${DateTime.now().difference(up).inMinutes} min', {
          'up_s': DateTime.now().difference(up).inSeconds,
        });
      }
      _say(line.length > 200 ? '${line.substring(0, 200)}...' : line);
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

/// For the logs: the port and how many Wi-Fi addresses, never the addresses (DECISIONS 757).
String _where(ShareStatus s) {
  final lan = s.addresses.where((a) => a != '127.0.0.1').length;
  return lan == 0 ? 'no Wi-Fi address yet, port ${s.port}' : 'port ${s.port}, $lan Wi-Fi ${lan == 1 ? 'address' : 'addresses'}';
}

/// `192.168.1.23:8765`, or null without a Wi-Fi address.
String? shareAddress(ShareStatus s) {
  final lan = s.addresses.where((a) => a != '127.0.0.1').toList();
  return !s.up || lan.isEmpty ? null : '${lan.first}:${s.port}';
}
