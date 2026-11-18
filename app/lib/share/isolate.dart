// Share on Wi-Fi: where the server runs (DECISIONS row 221). The server lives in a Dart isolate of its own, with
// its own memory and event loop. The isolate that records (the night recorder's service isolate, or the app
// between nights) only ever *sends* to it: sample batches and a status map through a port, which never waits
// and never blocks. A crash, an exception or a hang in the server therefore cannot stop or slow the recording;
// [ShareHost] hears that the isolate ended, writes one log line and stops feeding it.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../recorder/chunk_writer.dart';
import 'protocol.dart';
import 'server.dart';

/// How often the server looks for a changed Wi-Fi address (a new lease, another network).
const Duration _addressCheck = Duration(seconds: 60);

/// The other host (the app, or the recorder) may still hold the port for a moment at a hand-over.
const int _bindTries = 10;
const Duration _bindWait = Duration(seconds: 2);

/// What a host passes to the isolate. A plain list crosses the isolate border.
List<Object?> shareIsolateArgs(SendPort toHost, String filesDir, ShareConfig c) => [
  toHost,
  filesDir,
  c.token,
  c.port,
  c.offAtMs,
];

/// The server isolate. Messages in: `['b', stem, first, t, Float32List]` a batch, `['s', map]` the status,
/// `['m', id, t, i]` a marker's answer (t null = not recording), `['x']` stop. Messages out: `['port', SendPort]`,
/// `['up', addresses, port]`, `['marker', id, text]`, `['down', why]`.
@pragma('vm:entry-point')
Future<void> shareIsolateMain(List<Object?> args) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  final waiting = <int, Completer<MarkerResult?>>{};
  var nextId = 0;
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
  );
  Timer? addressTimer;
  Timer? offTimer;
  var closing = false;

  Future<void> end(String why) async {
    if (closing) return;
    closing = true;
    addressTimer?.cancel();
    offTimer?.cancel();
    try {
      await server.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    toHost.send(['down', why]);
    inbox.close();
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
      case 'x':
        unawaited(end('stopped'));
    }
  });
  toHost.send(['port', inbox.sendPort]);

  Future<List<InternetAddress>> lan() async {
    try {
      return lanAddresses(await NetworkInterface.list(type: InternetAddressType.IPv4));
    } catch (_) {
      return const [];
    }
  }

  var shown = '';
  Future<void> listen() async {
    await server.listenOn(await lan());
    final now = server.addresses.join(',');
    if (now != shown) {
      shown = now;
      toHost.send(['up', server.addresses, server.boundPort]);
    }
  }

  for (var attempt = 1; ; attempt++) {
    try {
      await listen();
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
  final left = (args[4]! as int) - DateTime.now().millisecondsSinceEpoch;
  offTimer = Timer(Duration(milliseconds: left < 0 ? 0 : left), () => unawaited(end('time is up')));
  addressTimer = Timer.periodic(_addressCheck, (_) async {
    try {
      await listen();
    } catch (_) {
      // no address right now (Wi-Fi off): keep looking
    }
  });
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

  /// Tests replace the server with one that throws.
  final Future<void> Function(List<Object?> args) entry;

  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _port;
  ShareStatus _status = shareDown;
  bool _ended = true;
  Map<Object?, Object?>? _live;

  ShareStatus get status => _status;
  bool get running => !_ended;

  Future<void> start(ShareConfig config) async {
    if (!_ended) return;
    try {
      if (!config.activeAt(DateTime.now().millisecondsSinceEpoch)) return;
      _ended = false;
      final events = _events = ReceivePort();
      events.listen(_onEvent);
      _isolate = await Isolate.spawn(
        entry,
        shareIsolateArgs(events.sendPort, filesDir, config),
        onError: events.sendPort,
        onExit: events.sendPort,
        errorsAreFatal: true,
        debugName: 'share',
      );
      ChunkWriter.onBatch = feed;
      _lock(true);
    } catch (e) {
      _end('sharing on Wi-Fi could not start: $e');
    }
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

  void _onEvent(Object? m) {
    try {
      if (m == null) return _end('sharing on Wi-Fi stopped: the server ended'); // onExit
      if (m is! List || m.isEmpty) return;
      switch (m[0]) {
        case 'port':
          _port = m[1] as SendPort;
          final live = _live;
          if (live != null) _port!.send(['s', live]);
        case 'up':
          final addresses = [for (final a in m[1] as List) a as String];
          final first = !_status.up;
          _status = (up: true, addresses: addresses, port: m[2] as int, note: '');
          if (first) onLog('sharing on Wi-Fi on: ${_where(_status)}');
          onChange?.call(_status);
        case 'marker':
          MarkerResult? r;
          try {
            r = onMarker?.call(m[2] as String);
          } catch (_) {
            r = null;
          }
          _port?.send(['m', m[1], r?.t, r?.i]);
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
