// Share on Wi-Fi from the screen's side (lib/share/control.dart): off by default, who serves when, the hand-over
// around a night, the 15 minutes after Stop, and the sentence under the switch.
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// A server that comes up at once on a made-up address.
Future<void> fakeServer(List<Object?> args) async {
  (args[0]! as SendPort).send(['up', <String>['192.168.1.23', '127.0.0.1'], args[3]]);
  await Future<void>.delayed(const Duration(hours: 1));
}

void main() {
  late Directory files;
  late ShareConfig saved;
  late List<Map<String, Object?>> sent;
  late List<bool> awake;
  late List<String> alive;
  late ShareControl c;
  var now = DateTime(2026, 11, 22, 22, 5);

  setUp(() {
    files = Directory.systemTemp.createTempSync('share_control_test');
    saved = const ShareConfig();
    sent = [];
    awake = [];
    alive = [];
    now = DateTime(2026, 11, 22, 22, 5);
    c = ShareControl(
      load: () async => saved,
      save: (x) async => saved = x,
      sendToRecorder: sent.add,
      keepScreenOn: (on) async => awake.add(on),
      keepAlive: (on, offAtMs) async => alive.add(on ? 'on until ${clockText(DateTime.fromMillisecondsSinceEpoch(offAtMs))}' : 'off'),
      clock: () => now,
      host: (dir, onChange) => ShareHost(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: fakeServer),
    );
  });
  tearDown(() async {
    await c.setOn(false);
    c.dispose();
    files.deleteSync(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

  test('off by default: nothing serves, the line says what it is for', () async {
    await c.sync(night: false, filesDir: files.path);
    expect(c.on, isFalse);
    expect(c.line().on, isFalse);
    expect(c.line().text, contains('home Wi-Fi'));
    expect(c.status.up, isFalse);
    expect(awake, isEmpty);
  });

  test('switched on between nights: the app serves, keeps the screen on, says where and until when', () async {
    await c.sync(night: false, filesDir: files.path);
    await c.setOn(true);
    await settle();
    expect(saved.on, isTrue);
    expect(saved.token, hasLength(12));
    expect(c.status.up, isTrue);
    expect(c.line().text, 'On at 192.168.1.23:8765 until 10:05. Keep this app open while the laptop copies.');
    expect(awake, [true]);
    expect(sent, isEmpty);

    // 15 minutes later the screen may sleep again; sharing itself stays on for its 12 hours
    now = now.add(const Duration(minutes: 16));
    await c.sync(night: false, filesDir: files.path);
    expect(awake.last, isFalse);
    expect(c.on, isTrue);

    now = now.add(const Duration(hours: 12));
    await c.sync(night: false, filesDir: files.path);
    await settle();
    expect(c.on, isFalse);
    expect(saved.on, isFalse);
    expect(saved.token, hasLength(12)); // kept for the next time
    expect(c.status.up, isFalse);
  });

  test('a night: the app lets go of the port, the recorder is told, its answer is shown', () async {
    await c.sync(night: false, filesDir: files.path);
    await c.setOn(true);
    await settle();
    await c.beforeNight();
    expect(c.status.up, isFalse);
    await c.sync(night: true, filesDir: files.path);
    expect(c.line().text, 'Starting.');
    c.onRecorderStatus((up: true, addresses: const ['10.0.0.7', '127.0.0.1'], port: 8765, note: ''));
    expect(c.line().text, 'On at 10.0.0.7:8765 until 10:05.');

    // the switch during a night goes to the recorder
    await c.setOn(false);
    expect(sent.last['kind'], 'share');
    expect((sent.last['config']! as Map)['on'], isFalse);
    await c.setOn(true);
    expect((sent.last['config']! as Map)['on'], isTrue);
    expect((sent.last['config']! as Map)['token'], saved.token);

    // Stop: 15 more minutes, served by the app again
    now = DateTime(2026, 11, 23, 7, 30);
    await c.afterStop();
    expect(saved.offAtMs, now.add(const Duration(minutes: 15)).millisecondsSinceEpoch);
    await c.sync(night: false, filesDir: files.path);
    await settle();
    expect(c.status.up, isTrue);
    expect(c.line().text, startsWith('On at 192.168.1.23:8765 until 07:45.'));
    expect(awake.last, isTrue);
    now = now.add(const Duration(minutes: 15));
    await c.sync(night: false, filesDir: files.path);
    expect(c.on, isFalse);
  });

  test('a new code restarts the server with it; no Wi-Fi and a stopped server are said in words', () async {
    await c.sync(night: false, filesDir: files.path);
    await c.setOn(true);
    final old = saved.token;
    await c.newToken();
    expect(saved.token, isNot(old));
    expect(saved.on, isTrue);

    await c.beforeNight();
    await c.sync(night: true, filesDir: files.path);
    c.onRecorderStatus((up: true, addresses: const ['127.0.0.1'], port: 8765, note: ''));
    expect(c.line().text, 'On, but no Wi-Fi address found. Join your home Wi-Fi, or use a USB cable: see Address and code.');
    expect(c.line().warn, isTrue);
    c.onRecorderStatus((up: false, addresses: const [], port: 8765, note: 'sharing on Wi-Fi stopped by an error: x'));
    expect(c.line().text, 'Sharing stopped by itself. Switch it off and on again.');
    expect(c.line().warn, isTrue);
  });

  test('between nights the app keeps itself running while it shares, so Android cannot freeze it (row 589)', () async {
    await c.sync(night: false, filesDir: files.path);
    expect(alive, isEmpty, reason: 'off by default');
    await c.setOn(true);
    await settle();
    expect(alive, ['on until 10:05']);
    await c.sync(night: false, filesDir: files.path); // the minute's sync changes nothing
    expect(alive, ['on until 10:05']);
    await c.beforeNight(); // the recorder's own service keeps the app running during the night
    expect(alive.last, 'off');
    await c.sync(night: true, filesDir: files.path);
    expect(alive.last, 'off');
    now = now.add(const Duration(hours: 8));
    await c.afterStop(); // Stop: 15 more minutes for the laptop to get the end of the night, screen off or not
    await c.sync(night: false, filesDir: files.path);
    expect(alive.last, 'on until 06:20');
    await c.setOn(false);
    expect(alive.last, 'off');
    expect(shareKeepText(DateTime(2026, 11, 23, 6, 20).millisecondsSinceEpoch),
        'Your laptop can copy the files until 06:20. Stop turns it off.');
  });
}
