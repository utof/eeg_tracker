// Share on Wi-Fi next to a recording (lib/share/isolate.dart): the server runs in its own isolate, and whatever
// happens to it (it throws at once, it dies mid-night, it hangs) the recorder keeps every sample. Real isolates,
// real sockets, the night recorder with the fake headband of night_recorder_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

/// A server that finds no Wi-Fi address, and says so twice (the minute's look found the same).
Future<void> noAddress(List<Object?> args) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  toHost.send(['port', inbox.sendPort]);
  const why = 'no Wi-Fi address found (android: vpn tun0 10.10.10.1/30; interfaces: failed: x)';
  toHost.send(['up', <String>[], args[3], why]);
  toHost.send(['up', <String>[], args[3], why]);
  toHost.send(['up', <String>['192.168.1.5'], args[3], '']);
  inbox.listen((m) {
    if (m is List && m[0] == 'x') {
      toHost.send(['down', 'stopped']);
      inbox.close();
    }
  });
}

/// The real server, with an error from one of its timers a moment after it listens (row 587).
Future<void> serverWithStrayError(List<Object?> args) => guardedShare(args, (args, setOnError) async {
  await serveShare(args, setOnError);
  Timer(const Duration(milliseconds: 200), () => throw StateError('a stray error'));
});

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

  ShareHost makeHost(
    NightRecorder? r, {
    Future<void> Function(List<Object?>)? entry,
    Future<WifiNets> Function()? wifi,
    void Function(bool working, bool? meeting)? onWork,
  }) => host = ShareHost(
    filesDir: files.path,
    onLog: (line) {
      log.add(line);
      r?.note(line);
    },
    onMarker: (text) => r?.addMarker(text),
    onChange: changes.add,
    wifi: wifi,
    onWork: onWork,
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

  /// The time [path] takes to answer (any code), or null when it does not answer within [limit].
  Future<int?> answerMs(int port, String path, {Duration limit = const Duration(seconds: 5)}) async {
    final client = HttpClient()..connectionTimeout = limit;
    final t = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path')).timeout(limit);
      final res = await req.close().timeout(limit);
      await res.drain<void>().timeout(limit);
      return t.elapsedMilliseconds;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  test('an error inside the server does not stop it: it goes on answering and says so once (phone, 2026-11-19)', () async {
    // On the phone the laptop's connections were accepted and never answered: an uncaught error ended the server's
    // isolate, whose listening socket stayed open with nobody behind it.
    final port = await freePort();
    await makeHost(null, entry: serverWithStrayError).start(config(port));
    await until(() => host!.status.up);
    await until(() => log.any((l) => l.contains('a stray error')));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host!.running, isTrue);
    expect(await answerMs(port, '/'), isNotNull, reason: 'GET / (no code: 401) must answer');
    expect((await ask(port, '/state')).code, 200);
    expect(log.where((l) => l.contains('a stray error')), hasLength(1));
    expect(log.where((l) => l.contains('stopped')), isEmpty);
  });

  test('/ and /state answer at once while Android never says the address and /files reads a big file', () async {
    final port = await freePort();
    File('${files.path}/recordings/2026-11-18-231200.f32').writeAsBytesSync(Uint8List(48 << 20)); // 48 MB
    File('${files.path}/recordings/2026-11-18-231200.f32').setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    final t = Stopwatch()..start();
    await makeHost(null, wifi: () => Completer<WifiNets>().future).start(config(port)); // the answer never comes
    expect(t.elapsed, lessThan(const Duration(seconds: 5)), reason: 'it waits 3 s at most for Android');
    await until(() => host!.status.up);
    final listing = ask(port, '/files'); // works out the SHA-256 of 48 MB
    final waits = <int?>[];
    var listed = false;
    unawaited(listing.whenComplete(() => listed = true));
    while (!listed) {
      waits.add(await answerMs(port, '/state'));
      waits.add(await answerMs(port, '/'));
    }
    expect((await listing).code, 200);
    expect(waits, isNot(contains(null)));
    expect(waits.whereType<int>().reduce((a, b) => a > b ? a : b), lessThan(1000), reason: '$waits');
  }, timeout: const Timeout(Duration(seconds: 60)));

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
    final rows = [for (var i = 0; i < 5; i++) Sample.four(pack: i, o1: 1e-6, o2: 0.0, t3: 0.0, t4: 0.0)];
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
    final rows = [for (var i = 0; i < 5; i++) Sample.four(pack: i, o1: 1e-6, o2: 0.0, t3: 0.0, t4: 0.0)];
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

  test("between nights the laptop's work signal reaches the app (automatic recording's hook); a night's server says no", () async {
    final works = <(bool, bool?)>[];
    final port = await freePort();
    await makeHost(null, onWork: (w, m) => works.add((w, m))).start(config(port));
    await until(() => host!.status.up);
    expect((await ask(port, '/work', method: 'POST', body: '{"working": true}')).code, 202);
    await until(() => works.isNotEmpty);
    expect(works, [(true, null)]);
    // the meeting crosses the isolate border too (DECISIONS 685)
    expect((await ask(port, '/work', method: 'POST', body: '{"working": true, "meeting": true}')).code, 202);
    await until(() => works.length == 2);
    expect(works.last, (true, true));
    await host!.stop();

    // the night recorder's server has no hook: the laptop hears 503 and the night is not disturbed
    final night = await freePort();
    await makeHost(null).start(config(night));
    await until(() => host!.status.up);
    expect((await ask(night, '/work', method: 'POST', body: '{"working": true}')).code, 503);
  });

  test("the Work session's summary reaches /state through the server's isolate, also when set before it starts", () async {
    final port = await freePort();
    final h = makeHost(null);
    h.setSession({'kind': 'work', 'since': '2026-11-19T00:00:00.000Z', 'stage': 'calibrating', 'signal': 'good'});
    await h.start(config(port));
    await until(() => h.status.up);
    Future<Map<Object?, Object?>?> session() async => (jsonDecode((await ask(port, '/state')).body) as Map)['session'] as Map?;
    Future<void> waitFor(bool Function(Map<Object?, Object?>? s) ok) async {
      for (var i = 0; i < 100 && !ok(await session()); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(ok(await session()), isTrue);
    }

    await waitFor((s) => s?['stage'] == 'calibrating');
    h.setSession({'kind': 'work', 'since': '2026-11-19T00:00:00.000Z', 'stage': 'running', 'level': 'alert'});
    await waitFor((s) => s?['level'] == 'alert');
    h.setSession(null);
    await waitFor((s) => s == null);
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

  test("Android's Wi-Fi address comes first; the server answers on it and the phone itself", () async {
    // DECISIONS rows 560-562: what PhoneChannel.kt says wins over Dart's interface list (on this machine, its own).
    final port = await freePort();
    await makeHost(null, wifi: () async => (nets: ['192.168.77.5/24'], note: 'wifi wlan0 192.168.77.5/24')).start(config(port));
    host!.setLive(const {});
    await until(() => host!.status.up);
    expect(host!.status.addresses, ['192.168.77.5']);
    expect(shareAddress(host!.status), '192.168.77.5:$port');
    expect(log.single, 'sharing on Wi-Fi on: port $port, 1 Wi-Fi address'); // no address in a log (DECISIONS 757)
    expect((await ask(port, '/files')).code, 200); // 127.0.0.1: adb forward
  });

  test('Android failing to answer is not fatal: the interface list stands in', () async {
    final port = await freePort();
    await makeHost(null, wifi: () async => throw StateError('no channel')).start(config(port));
    await until(() => host!.status.up);
    expect(host!.running, isTrue);
    expect((await ask(port, '/files')).code, 200);
  });

  test('no Wi-Fi address: what each source returned goes to the log once, and the address when it comes', () async {
    await makeHost(null, entry: noAddress).start(config(8765));
    await until(() => host!.status.addresses.isNotEmpty);
    expect(log, [
      'sharing on Wi-Fi on: no Wi-Fi address yet, port 8765',
      'sharing on Wi-Fi: no Wi-Fi address found (android: vpn tun0 x.x.x.x/30; interfaces: failed: x)',
      'sharing on Wi-Fi: the Wi-Fi network changed (port 8765, 1 Wi-Fi address)',
    ]);
  });

  test('Stop while Android is still answering: no server starts at all', () async {
    final port = await freePort();
    final h = makeHost(null, wifi: () async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return (nets: ['192.168.1.5/24'], note: '');
    });
    final starting = h.start(config(port));
    await h.stop();
    await starting;
    expect(h.running, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await (await ServerSocket.bind(InternetAddress.anyIPv4, port)).close(); // the port was never taken
    expect(log, ['sharing on Wi-Fi off']);
  });

  test('the notification says it is shared, and where', () {
    const s = RecorderStatus(phase: Phase.recording, nightSamples: 250 * 60 * 12);
    expect(notificationText(s), 'Recording · 12 min');
    expect(notificationText(s, shareDown), 'Recording · 12 min');
    final up = shareStatusWith(shareDown, up: true, addresses: ['192.168.1.23', '127.0.0.1'], port: 8765, here: 'home', net: '192.168.1.0/24', copiedAtMs: 5, copiedBy: 'laptop');
    expect(notificationText(s, up), 'Recording · 12 min · shared on Wi-Fi at 192.168.1.23:8765');
    expect(notificationText(s, shareStatusWith(shareDown, up: true, addresses: const ['127.0.0.1'])), 'Recording · 12 min · shared on Wi-Fi');
    final back = shareStatusFrom(shareMessage(up))!; // the night recorder's word reaches the screen whole
    expect(back.addresses, ['192.168.1.23', '127.0.0.1']);
    expect((back.up, back.port, back.here, back.net, back.copiedAtMs, back.copiedBy), (true, 8765, 'home', '192.168.1.0/24', 5, 'laptop'));
    expect(shareStatusFrom({'kind': 'status'}), isNull);
    expect(shareStatusFrom({'kind': 'share', 'config': <String, Object?>{}}), isNull);
  });
}
