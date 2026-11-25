// Something else holds the share port (the owner's phone, 2026-11-20: "Address already in use" for 80 s, and the
// recording then shared nothing for 1 h 40 min): the server takes the next port, says what holds the first one, and
// the recording's service tries again by itself (lib/share/isolate.dart, lib/recorder/recorder_service.dart;
// DECISIONS 841). Real isolates and sockets.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/recorder/recorder_service.dart' show shareEndedByItself, shareRetryEvery;
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Four free ports in a row: the OS names the first (nothing picks a port by the clock, so two runs of this file on
/// one machine do not choose alike), the three after it are checked.
Future<int> freeRun() async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final p = probe.port;
    await probe.close();
    final held = <ServerSocket>[];
    try {
      for (var k = 1; k <= sparePorts; k++) {
        held.add(await ServerSocket.bind(InternetAddress.anyIPv4, p + k));
      }
      return p;
    } catch (_) {
      // one of the next three is taken: ask again
    } finally {
      for (final s in held) {
        await s.close();
      }
    }
  }
  throw StateError('no free ports');
}

void main() {
  late Directory files;
  late List<String> log;
  late List<ShareStatus> changes;

  setUp(() {
    files = Directory.systemTemp.createTempSync('spare_port');
    log = [];
    changes = [];
  });
  tearDown(() => files.deleteSync(recursive: true));

  ShareHost host() => ShareHost(filesDir: files.path, onLog: log.add, onChange: changes.add);
  ShareConfig config(int port) => ShareConfig(
    on: true,
    token: 'abcdefghjkmn',
    port: port,
    offAtMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
  );

  Future<void> up(ShareHost h) async {
    for (var i = 0; i < 300 && !h.status.up && h.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('a port held by something that never answers: the next port is used, and the log says what holds it', () async {
    final port = await freeRun();
    final squatter = await ServerSocket.bind(InternetAddress.anyIPv4, port); // listens, takes nothing
    addTearDown(squatter.close);
    final h = host();
    await h.start(config(port));
    await up(h);
    expect(h.status.up, isTrue, reason: '$log');
    expect(h.status.port, port + 1);
    expect(log, contains('sharing on Wi-Fi: port $port is taken (something listens there and does not answer); using port ${port + 1}'));
    final c = HttpClient();
    final res = await (await c.getUrl(Uri.parse('http://127.0.0.1:${port + 1}/'))).close();
    expect(res.statusCode, 401, reason: 'the app\'s own server answers on the spare port');
    await res.drain<void>();
    c.close(force: true);
    await h.stop();
    await (await ServerSocket.bind(InternetAddress.anyIPv4, port + 1)).close(); // let go of again
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('what holds a port, in the log\'s words', () async {
    final port = await freeRun();
    expect(await whoHolds(port), 'nothing answers there, yet Android says it is in use');
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    other.listen((r) {
      r.response
        ..statusCode = 401
        ..write('{"error":"token missing or wrong"}');
      unawaited(r.response.close());
    });
    expect(await whoHolds(port), 'an EEG Tracker server already answers there');
    await other.close(force: true);
    final web = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    web.listen((r) {
      r.response.write('<html>hello</html>');
      unawaited(r.response.close());
    });
    expect(await whoHolds(port), 'another program answers there');
    await web.close(force: true);
  });

  test('every port taken: the server says so and what holds the first one; that note asks for another try', () async {
    final port = await freeRun();
    final held = [for (var k = 0; k <= sparePorts; k++) await ServerSocket.bind(InternetAddress.anyIPv4, port + k)];
    addTearDown(() async {
      for (final s in held) {
        await s.close();
      }
    });
    final h = host();
    await h.start(config(port));
    for (var i = 0; i < 1000 && h.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(h.running, isFalse);
    expect(h.status.note, startsWith('sharing on Wi-Fi off: could not listen on port $port or the next $sparePorts'));
    expect(h.status.note, contains('something listens there and does not answer'));
    expect(shareEndedByItself(h.status.note), isTrue);
  }, timeout: const Timeout(Duration(seconds: 150)));

  test('only a server that ended by itself is started again', () {
    expect(shareEndedByItself('sharing on Wi-Fi off: could not listen on port 8765 or the next 3: x'), isTrue);
    expect(shareEndedByItself('sharing on Wi-Fi stopped by an error: boom'), isTrue);
    expect(shareEndedByItself('sharing on Wi-Fi stopped: the server ended'), isTrue);
    expect(shareEndedByItself('sharing on Wi-Fi off'), isFalse, reason: 'switched off, or Stop');
    expect(shareEndedByItself('sharing on Wi-Fi off: time is up'), isFalse);
    expect(shareRetryEvery, lessThanOrEqualTo(const Duration(minutes: 2)));
  });
}
