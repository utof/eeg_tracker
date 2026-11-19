// Share on Wi-Fi next to a recording (lib/share/isolate.dart): the server runs in its own isolate, and whatever
// happens to it (it throws at once, it dies mid-night, it hangs) the recorder keeps every sample. Real isolates,
// real sockets, the night recorder with the fake headband of night_recorder_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart' show notificationText, shareMessage, shareStatusFrom;
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder, f32Records, fast;

const token = 'abcdefghjkmn';

/// A server that throws before it does anything.
Future<void> throwsAtOnce(List<Object?> args) async => throw StateError('boom at start');

/// A server that takes batches for a while, then throws from its message handler.
Future<void> diesAfterTenBatches(List<Object?> args) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  var n = 0;
  inbox.listen((m) {
    if (m is List && m[0] == 'b' && ++n == 10) throw StateError('boom mid-night');
  });
  toHost.send(['port', inbox.sendPort]);
  toHost.send(['up', <String>['192.168.1.23', '127.0.0.1'], 8765]);
}

/// A server that stops answering: its isolate spins and never reads another message.
Future<void> hangs(List<Object?> args) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  inbox.listen((m) {
    if (m is List && m[0] == 'b') {
      while (true) {} // ignore: empty_statements
    }
  });
  toHost.send(['port', inbox.sendPort]);
  toHost.send(['up', <String>['127.0.0.1'], 8765]);
}

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

void main() {
  late Directory files;
  late Directory dir;
  late List<String> log;
  late List<ShareStatus> changes;
  ShareHost? host;

  setUp(() {
    files = Directory.systemTemp.createTempSync('share_host_test');
    dir = Directory('${files.path}/recordings')..createSync();
    log = [];
    changes = [];
    host = null;
    ChunkWriter.onBatch = null;
  });
  tearDown(() async {
    await host?.stop();
    ChunkWriter.onBatch = null;
    files.deleteSync(recursive: true);
  });

  ShareConfig config(int port, {Duration onFor = const Duration(hours: 1)}) => ShareConfig(
    on: true,
    token: token,
    port: port,
    offAtMs: DateTime.now().add(onFor).millisecondsSinceEpoch,
  );

  NightRecorder recorder(FakeBand band) => NightRecorder(
    finder: FakeFinder([band]),
    dir: dir,
    store: MemoryNightStore(),
    onStatus: (s) => host?.setLive(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch)),
    onStuck: (_) async {},
    timing: fast,
  );

  ShareHost makeHost(NightRecorder? r, {Future<void> Function(List<Object?>)? entry}) => host = ShareHost(
    filesDir: files.path,
    onLog: (line) {
      log.add(line);
      r?.note(line);
    },
    onMarker: (text) => r?.addMarker(text),
    onChange: changes.add,
    entry: entry ?? shareIsolateMain,
  );

  Future<void> until(bool Function() ok, {int ms = 5000}) async {
    for (var i = 0; i < ms ~/ 10 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue);
  }

  Future<({int code, String body})> ask(int port, String path, {String method = 'GET', String? body}) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
      req.headers.set('Authorization', 'Bearer $token');
      if (body != null) req.add(utf8.encode(body));
      final res = await req.close();
      return (code: res.statusCode, body: await utf8.decodeStream(res));
    } finally {
      client.close(force: true);
    }
  }

  List<File> ext(String e) => dir.listSync().whereType<File>().where((f) => f.path.endsWith('.$e')).toList();

  test('Stop right after start, before the server is ready: it still closes its socket', () async {
    // A killed isolate keeps its sockets open (until a garbage collection), so the server must close them itself.
    final port = await freePort();
    await makeHost(null).start(config(port));
    await host!.stop();
    var bound = true;
    for (var i = 0; i < 20 && bound; i++) {
      try {
        await (await ServerSocket.bind(InternetAddress.loopbackIPv4, port)).close();
        bound = false;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    expect(bound, isFalse, reason: 'the port is still held after Stop');
  });

  test('a night started from another screen: the server waits for the app to let go of the port (up to its minute)', () async {
    // The dream catcher's or sound's "Record the night" starts the recorder while the app's own server still holds
    // the port; the night screen lets go at its next sync, up to a minute later (with the phone locked, no sooner).
    final port = await freePort();
    final app = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await makeHost(null).start(config(port));
    await Future<void>.delayed(const Duration(seconds: 22));
    expect(host!.running, isTrue, reason: 'the server gave up while the app still held the port');
    await app.close();
    await until(() => host!.status.up, ms: 10000);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a night with sharing on: the laptop reads the live signal, sets a marker and fetches the growing file', () async {
    final band = FakeBand('a');
    final r = recorder(band);
    final port = await freePort();
    await makeHost(r).start(config(port));
    final running = r.run(restartedBySystem: false);
    await until(() => host!.status.up && r.status.phase == Phase.recording && r.status.nightSamples > 100);

    final state = jsonDecode((await ask(port, '/state')).body) as Map<String, Object?>;
    expect(state['status'], 'recording');
    expect(state['battery'], 77);
    expect((state['data']! as List).first, isNotEmpty);
    expect(state['contact'], {'O1': 400000, 'O2': 1500000, 'T3': 3000000, 'T4': null});
    expect(state['age'], lessThan(2));

    final marked = await ask(port, '/marker', method: 'POST', body: 'eyes closed start');
    expect(marked.code, 200);
    final list = jsonDecode((await ask(port, '/files?sha=0')).body) as Map<String, Object?>;
    final paths = [for (final f in list['files']! as List) (f as Map)['path']];
    final stem = ext('f32').single.uri.pathSegments.last.replaceFirst('.f32', '');
    expect(paths, containsAll(['recordings/$stem.f32', 'recordings/$stem.idx', 'recordings/$stem.log', 'recordings/$stem.markers.jsonl']));
    expect(list['recording'], stem);

    await host!.stop();
    await r.stop();
    await running;
    expect(f32Records(ext('f32').single), band.emitted); // every sample, sharing or not
    final marker = jsonDecode(ext('markers.jsonl').single.readAsLinesSync().single) as Map<String, Object?>;
    expect(marker.keys.toList(), ['t', 'i', 'text']); // scripts/recorder_hub.py add_marker
    expect(marker['text'], 'eyes closed start');
    expect(marker['i'], inInclusiveRange(1, band.emitted));
    final lines = ext('log').single.readAsStringSync();
    expect(lines, contains('sharing on Wi-Fi on: '));
    expect(lines, contains('sharing on Wi-Fi off'));
    expect(ChunkWriter.onBatch, isNull);
    expect(changes.last.up, isFalse);
    // the port is free again for the app, which serves between nights
    final again = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await again.close();
  });

  for (final (name, entry, line) in [
    ('throws at once', throwsAtOnce, 'boom at start'),
    ('dies in the middle of the night', diesAfterTenBatches, 'boom mid-night'),
  ]) {
    test('a server that $name: the recording continues, sharing is off, one line in the log', () async {
      final band = FakeBand('a');
      final r = recorder(band);
      await makeHost(r, entry: entry).start(config(8765));
      final running = r.run(restartedBySystem: false);
      await until(() => !host!.running && r.status.nightSamples > 200);
      final before = r.status.nightSamples;
      await until(() => r.status.nightSamples > before + 200); // still recording after the server is gone
      expect(r.status.phase, Phase.recording);
      await r.stop();
      await running;

      expect(f32Records(ext('f32').single), band.emitted);
      expect(band.emitted, greaterThan(400));
      expect(log.where((l) => l.contains('stopped')), hasLength(1));
      expect(log.last, contains(line));
      expect(host!.status.up, isFalse);
      expect(ChunkWriter.onBatch, isNull);
      final text = ext('log').map((f) => f.readAsStringSync()).join();
      expect('sharing on Wi-Fi stopped by an error'.allMatches(text), hasLength(1));
      expect(text, contains('total samples ${band.emitted}'));
    });
  }

  test('a server that hangs: the recording continues, and Stop does not wait for it', () async {
    final band = FakeBand('a');
    final r = recorder(band);
    await makeHost(r, entry: hangs).start(config(8765));
    final running = r.run(restartedBySystem: false);
    await until(() => r.status.nightSamples > 500);
    expect(host!.running, isTrue); // nobody noticed, and nothing was lost
    final t = Stopwatch()..start();
    await host!.stop();
    expect(t.elapsed, lessThan(const Duration(seconds: 6)));
    await r.stop();
    await running;
    expect(f32Records(ext('f32').single), band.emitted);
  });

  test('a tap that throws is dropped and costs no sample', () {
    var calls = 0;
    ChunkWriter.onBatch = (stem, first, arrival, samples) {
      calls++;
      throw StateError('tap');
    };
    final w = ChunkWriter.open(dir, DateTime(2026, 11, 19, 3));
    final rows = [for (var i = 0; i < 5; i++) (pack: i, o1: 1e-6, o2: 0.0, t3: 0.0, t4: 0.0)];
    w.addBatch(DateTime.now(), rows);
    w.addBatch(DateTime.now(), rows);
    w.close();
    expect(calls, 1);
    expect(ChunkWriter.onBatch, isNull);
    expect(f32Records(ext('f32').single), 10);
  });

  test('the tap says which run and which sample each batch starts at', () {
    final seen = <(String, int, int)>[];
    ChunkWriter.onBatch = (stem, first, arrival, samples) => seen.add((stem, first, samples.length));
    final w = ChunkWriter.open(dir, DateTime(2026, 11, 19, 3));
    final rows = [for (var i = 0; i < 5; i++) (pack: i, o1: 1e-6, o2: 0.0, t3: 0.0, t4: 0.0)];
    w.addBatch(DateTime.now(), rows);
    w.addBatch(DateTime.now(), rows.sublist(0, 3));
    w.close();
    expect(seen, [('2026-11-19-030000', 0, 5), ('2026-11-19-030000', 5, 3)]);
  });

  test('between nights the app serves the files; a marker is refused; it turns itself off when its time is up', () async {
    File('${dir.path}/2026-11-18-231200.log').writeAsStringSync('connected\n');
    final port = await freePort();
    await makeHost(null).start(config(port, onFor: const Duration(milliseconds: 1500)));
    host!.setLive(const {});
    await until(() => host!.status.up);
    expect((await ask(port, '/files/recordings/2026-11-18-231200.log')).body, 'connected\n');
    expect((jsonDecode((await ask(port, '/state')).body) as Map)['status'], 'not recording');
    expect((await ask(port, '/marker', method: 'POST', body: 'x')).code, 503);
    await until(() => !host!.running);
    expect(log.last, 'sharing on Wi-Fi off: time is up');
    await expectLater(ask(port, '/state'), throwsA(isA<SocketException>()));
  });

  test('off, or past its time: nothing starts', () async {
    await makeHost(null).start(const ShareConfig());
    expect(host!.running, isFalse);
    await host!.start(config(8765, onFor: const Duration(seconds: -1)));
    expect(host!.running, isFalse);
    expect(log, isEmpty);
    expect(ChunkWriter.onBatch, isNull);
  });

  test('a marker with no run open is refused, never thrown', () {
    final r = recorder(FakeBand('a'));
    expect(r.addMarker('x'), isNull);
    r.note('a line with no run yet'); // kept for the next run's log
  });

  test('the notification says it is shared, and where', () {
    const s = RecorderStatus(phase: Phase.recording, nightSamples: 250 * 60 * 12);
    expect(notificationText(s), 'Recording · 12 min');
    expect(notificationText(s, shareDown), 'Recording · 12 min');
    const up = (up: true, addresses: ['192.168.1.23', '127.0.0.1'], port: 8765, note: '');
    expect(notificationText(s, up), 'Recording · 12 min · shared on Wi-Fi at 192.168.1.23:8765');
    expect(notificationText(s, (up: true, addresses: const ['127.0.0.1'], port: 8765, note: '')), 'Recording · 12 min · shared on Wi-Fi');
    final back = shareStatusFrom(shareMessage(up))!;
    expect(back.up, isTrue);
    expect(back.addresses, ['192.168.1.23', '127.0.0.1']);
    expect(back.port, 8765);
    expect(shareStatusFrom({'kind': 'status'}), isNull);
    expect(shareStatusFrom({'kind': 'share', 'config': <String, Object?>{}}), isNull);
  });
}
