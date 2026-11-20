// Pairing that lasts (DECISIONS 675-676): while a laptop is paired Share on Wi-Fi has no end time and survives a
// night's Stop and a new code; a network that comes back makes the phone tell the laptop at once; and the Work
// session's summary goes to the app's own server for the laptop tray (671).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'share_link_test.dart' show FakeLaptop, until;

const key = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';
const laptop = PairedLaptop(host: '192.168.1.10', port: 8771, key: key, name: 'my-laptop', pairedAtMs: 5);

/// A server that comes up at once on a made-up address.
Future<void> fakeServer(List<Object?> args) async {
  (args[0]! as SendPort).send(['up', <String>['192.168.1.23', '127.0.0.1'], args[3]]);
  await Future<void>.delayed(const Duration(hours: 1));
}

/// The app's host, counting what ShareControl hands it.
class CountingHost extends ShareHost {
  CountingHost(String dir, void Function(ShareStatus) onChange)
    : super(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: fakeServer);
  int networkChanges = 0, tells = 0;
  final List<Map<String, Object?>?> sessions = [];

  @override
  Future<void> networkChanged() async => networkChanges++;

  @override
  Future<void> tellLaptop() async => tells++;

  @override
  void setSession(Map<String, Object?>? session) {
    sessions.add(session);
    super.setSession(session);
  }
}

void main() {
  group('ShareConfig while paired', () {
    test('no end time: on past its 12 hours, after Stop, through a new code; forgetting brings the end time back', () {
      final on = const ShareConfig().switchedOn(1000);
      final paired = on.withLaptop(laptop);
      final late = on.offAtMs + const Duration(days: 3).inMilliseconds;
      expect(on.activeAt(late), isFalse);
      expect(paired.activeAt(late), isTrue);
      expect(paired.endsAtMs, isNull);
      expect(on.endsAtMs, on.offAtMs);
      expect(paired.afterStop(2000).activeAt(late), isTrue, reason: 'a night\'s Stop does not start a 15-minute end');
      expect(paired.afterStop(2000).awakeUntilMs, 2000 + shareAfterStop.inMilliseconds);
      expect(on.afterStop(2000).offAtMs, 2000 + shareAfterStop.inMilliseconds);
      final newCode = paired.withNewToken();
      expect(newCode.laptop, laptop, reason: 'New code changes the token, never the pairing key');
      expect(newCode.laptop!.key, key);
      expect(newCode.token, isNot(paired.token));
      expect(newCode.activeAt(late), isTrue);
      expect(paired.switchedOff().activeAt(late), isFalse, reason: 'the owner can still switch it off');
      expect(paired.withLaptop(null).activeAt(late), isFalse);
    });

    test('the share isolate gets no end time while paired', () {
      final rp = ReceivePort();
      final on = const ShareConfig(on: true, token: 'abcdefghjkmn', offAtMs: 9);
      expect(shareIsolateArgs(rp.sendPort, '/files', on)[4], 9);
      expect(shareIsolateArgs(rp.sendPort, '/files', on.withLaptop(laptop))[4], -1);
      rp.close();
    });
  });

  group('ShareControl while paired', () {
    late Directory files;
    late ShareConfig saved;
    late StreamController<void> network;
    late ValueNotifier<Map<String, Object?>?> session;
    late List<CountingHost> hosts;
    late ShareControl c;
    var now = DateTime(2026, 11, 22, 8, 0);

    setUp(() {
      files = Directory.systemTemp.createTempSync('share_paired_test');
      saved = const ShareConfig().switchedOn(now.millisecondsSinceEpoch).withLaptop(laptop);
      network = StreamController<void>.broadcast();
      session = ValueNotifier(null);
      hosts = [];
      now = DateTime(2026, 11, 22, 8, 0);
      c = ShareControl(
        load: () async => saved,
        save: (x) async => saved = x,
        sendToRecorder: (_) {},
        keepScreenOn: (_) async {},
        clock: () => now,
        session: session,
        networkChanges: network.stream,
        host: (dir, onChange, _) {
          final h = CountingHost(dir, onChange);
          hosts.add(h);
          return h;
        },
      );
    });
    tearDown(() async {
      await c.setOn(false);
      c.dispose();
      await network.close();
      files.deleteSync(recursive: true);
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

    test('stays on a day later and after a night; the line says it is paired and when the laptop copies', () async {
      await c.sync(night: false, filesDir: files.path);
      await settle();
      expect(c.on, isTrue);
      expect(c.line().text, 'On at 192.168.1.23:8765, paired with my-laptop. The laptop copies while this app is open or records.');
      now = now.add(const Duration(hours: 30));
      await c.sync(night: false, filesDir: files.path);
      expect(c.on, isTrue);
      expect(saved.on, isTrue, reason: 'not switched off at its old time');
      await c.beforeNight();
      await c.afterStop();
      now = now.add(const Duration(hours: 1));
      await c.sync(night: false, filesDir: files.path);
      expect(c.on, isTrue, reason: 'no 15-minute end after Stop while paired');
    });

    test('New code keeps the pairing: the server restarts with the new token and still knows the laptop', () async {
      await c.sync(night: false, filesDir: files.path);
      final before = saved.token;
      await c.newToken();
      expect(saved.token, isNot(before));
      expect(saved.laptop, laptop);
      expect(hosts, hasLength(2), reason: 'the server started again: its announcer tells the laptop the new token');
    });

    test('forgetting the laptop brings back the end time: past it, sharing goes off at the next look', () async {
      await c.sync(night: false, filesDir: files.path);
      now = now.add(const Duration(hours: 13));
      await c.forgetLaptop();
      await c.sync(night: false, filesDir: files.path);
      expect(c.on, isFalse);
      expect(saved.on, isFalse);
    });

    test("Android's network change reaches the running server; none is lost before it runs", () async {
      network.add(null); // nothing serves yet: nothing to tell
      await settle();
      await c.sync(night: false, filesDir: files.path);
      network.add(null);
      network.add(null);
      await settle();
      expect(hosts.single.networkChanges, 2);
    });

    test("the Work session's summary goes to the server, also one that started before it", () async {
      session.value = {'kind': 'work', 'stage': 'calibrating'};
      await c.sync(night: false, filesDir: files.path);
      expect(hosts.single.sessions.last, containsPair('stage', 'calibrating'));
      session.value = {'kind': 'work', 'stage': 'running'};
      expect(hosts.single.sessions.last, containsPair('stage', 'running'));
      session.value = null;
      expect(hosts.single.sessions.last, isNull);
    });

    test('with no notification between nights (row 678) the laptop hears from the phone when a session starts and when '
        'the app comes back to the front', () async {
      await c.sync(night: false, filesDir: files.path);
      session.value = {'kind': 'work', 'stage': 'calibrating'};
      session.value = {'kind': 'work', 'stage': 'running'}; // the same session: told once
      expect(hosts.single.tells, 1);
      session.value = null;
      session.value = {'kind': 'work', 'stage': 'calibrating'}; // a new one
      expect(hosts.single.tells, 2);
      c.resumed();
      expect(hosts.single.tells, 3);
    });
  });

  group('telling the laptop at once', () {
    late FakeLaptop fake;
    setUp(() async => fake = await FakeLaptop.start());
    tearDown(() => fake.close());

    test('soon(): a network that comes back is told at once, not at the next 5 minutes', () async {
      fake.key = key;
      final a = LaptopAnnouncer(
        laptop: PairedLaptop(host: '127.0.0.1', port: fake.port, key: key, name: 'my-laptop'),
        sharePort: 8765,
        token: 'abcdefghjkmn',
        client: LinkClient(timeout: const Duration(seconds: 2)),
        every: const Duration(hours: 1),
        retries: const [Duration(hours: 1)],
      )..start();
      await until(() => fake.finishes.length == 1);
      fake.status = 503; // the laptop's Wi-Fi is down
      a.soon();
      await until(() => fake.hellos >= 1 && fake.finishes.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fake.status = 200; // back: the next try would be an hour away
      a.soon();
      await until(() => fake.finishes.length == 2);
      a.soon();
      a.soon(); // two at once: one more try, never two handshakes side by side
      await until(() => fake.finishes.length == 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fake.finishes, hasLength(3));
      a.stop();
      a.soon();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fake.finishes, hasLength(3));
    });

    test('the real share isolate tells the laptop again when Android says the network changed', () async {
      fake.key = key;
      final files = Directory.systemTemp.createTempSync('share_paired_isolate');
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final host = ShareHost(filesDir: files.path, onLog: (_) {});
      try {
        await host.start(
          ShareConfig(
            on: true,
            token: 'abcdefghjkmn',
            port: port,
            offAtMs: 1, // long past: paired, so it serves anyway
            laptop: PairedLaptop(host: '127.0.0.1', port: fake.port, key: key, name: 'my-laptop'),
          ),
        );
        expect(host.running, isTrue);
        await until(() => fake.finishes.length == 1, ms: 10000);
        await host.networkChanged();
        await until(() => fake.finishes.length == 2, ms: 10000);
        expect(fake.finishes.last, containsPair('port', port));
      } finally {
        await host.stop();
        files.deleteSync(recursive: true);
      }
    });
  });
}
