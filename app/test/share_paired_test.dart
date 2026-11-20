// Pairing that lasts (DECISIONS 675, 752): while a laptop is paired Share on Wi-Fi has no end time and survives a
// night's Stop and a new code; it shares only on the home Wi-Fi (or one allowed by hand for 12 hours), and the line
// under the switch says where and when the laptop last copied (no notification does); a network change reaches the
// server at once; and the Work session's summary goes to the app's own server for the laptop tray (671).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/link.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'share_link_test.dart' show until;

const key = '7d6f0c1b5a4e3d2c1b0a99887766554433221100ffeeddccbbaa998877665544';
const laptop = PairedLaptop(host: '192.168.1.10', port: 8771, key: key, name: 'my-laptop', pairedAtMs: 5);

/// What the next made-up server says of its Wi-Fi ([sharingStates]); each runs in its own isolate, so it is chosen
/// when the host is made.
String fakeHere = 'home';

Future<void> _fake(List<Object?> args, String here) async {
  final to = args[0]! as SendPort;
  to.send(['up', <String>['192.168.1.23', '127.0.0.1'], args[3]]);
  to.send(['here', here, '192.168.1.0/24']);
  if (here == 'home') to.send(['copied', 'laptop']);
  await Future<void>.delayed(const Duration(hours: 1));
}

/// A server that comes up at once on a made-up address, says it is home, and copies a file to the laptop.
Future<void> fakeServer(List<Object?> args) => _fake(args, 'home');
Future<void> fakeServerWaiting(List<Object?> args) => _fake(args, 'waiting');
Future<void> fakeServerHere(List<Object?> args) => _fake(args, 'here');

/// The app's host, counting what ShareControl hands it.
class CountingHost extends ShareHost {
  CountingHost(String dir, void Function(ShareStatus) onChange)
    : super(
        filesDir: dir,
        onLog: (_) {},
        onChange: onChange,
        entry: switch (fakeHere) {
          'waiting' => fakeServerWaiting,
          'here' => fakeServerHere,
          _ => fakeServer,
        },
      );
  int networkChanges = 0;
  final List<Map<String, Object?>?> sessions = [];

  @override
  Future<void> networkChanged() async => networkChanges++;

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
      fakeHere = 'home';
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

    test('stays on a day later and after a night; the line says it shares at home and when the laptop copied', () async {
      await c.sync(night: false, filesDir: files.path);
      await settle();
      expect(c.on, isTrue);
      expect(c.line().text, 'On, on your home Wi-Fi, for my-laptop. Last copied by my-laptop at ${clockText(DateTime.now())}.');
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
      expect(hosts, hasLength(2), reason: 'the server started again with the new token; the laptop never needs it');
    });

    test('away from home: paused, until the owner shares here for 12 hours (this Wi-Fi only)', () async {
      fakeHere = 'waiting';
      await c.sync(night: false, filesDir: files.path);
      await settle();
      expect(c.line().text, 'Paused on this Wi-Fi until my-laptop says it is your home Wi-Fi. Not at home? Address and code: Share here.');
      expect(c.status.net, '192.168.1.0/24');
      fakeHere = 'here';
      await c.shareHere(true);
      await settle();
      expect((saved.hereNet, saved.hereUntilMs), ('192.168.1.0/24', now.add(shareHereFor).millisecondsSinceEpoch));
      expect(hosts, hasLength(2), reason: 'the server started again with it');
      expect(c.line().text, startsWith('On, on this Wi-Fi until 20:00 (allowed by you).'));
      await c.shareHere(false);
      expect((saved.hereNet, saved.hereUntilMs), (null, 0));
    });

    test('a pairing from before this update: off, and the line asks for one new scan', () async {
      saved = ShareConfig.fromJson({
        'on': true,
        'token': 'abcdefghjkmn',
        'off_at_ms': 1,
        'laptop': {'host': '192.168.1.10', 'port': 8771, 'key': 'k' * 43, 'name': 'my-laptop'},
      });
      await c.sync(night: false, filesDir: files.path);
      expect(c.on, isFalse);
      expect(c.line(), (on: false, text: 'Paired with my-laptop before this update: pair once more (one scan of its code) to share safely.', warn: true, address: null));
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
  });

  test('copied: by whom and when, in words', () {
    final today = DateTime(2026, 11, 20, 18, 0);
    ShareStatus at(DateTime t, String by) => shareStatusWith(shareDown, copiedAtMs: t.millisecondsSinceEpoch, copiedBy: by);
    expect(copiedText(shareDown, 'my-laptop'), 'Nothing copied yet.');
    expect(copiedText(at(DateTime(2026, 11, 20, 14, 5), 'laptop'), 'my-laptop', now: today), 'Last copied by my-laptop at 14:05.');
    expect(copiedText(at(DateTime(2026, 11, 19, 7, 30), 'code'), 'my-laptop', now: today), 'Last copied by a device with the code on 19 Nov at 07:30.');
    expect(copiedText(at(DateTime(2026, 11, 20, 9, 0), 'cable'), null, now: today), 'Last copied by a computer on the USB cable at 09:00.');
  });

  test('the real share isolate: a paired phone waits for the laptop to say this Wi-Fi is home', () async {
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
          laptop: PairedLaptop(host: '127.0.0.1', port: 8771, key: key, name: 'my-laptop'),
        ),
      );
      expect(host.running, isTrue);
      await until(() => host.status.here == 'waiting', ms: 10000);
    } finally {
      await host.stop();
      files.deleteSync(recursive: true);
    }
  });
}
