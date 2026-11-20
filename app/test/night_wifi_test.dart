// The phone's Wi-Fi during a night (DECISIONS rows 610-619; the owner's Xiaomi left Wi-Fi soon after the screen went
// off on 2026-11-20 and the laptop lost the night's mirror): the lines in the night's log (lib/recorder/wifi_watch.dart),
// the Wi-Fi lock held by whoever serves across a night's start and Stop (the screen's engine between nights, the
// recorder's engine during one; one lock per process, PhoneChannel.kt), and the phone checks that name the settings.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/recorder/wifi_watch.dart';
import 'package:eeg_tracker/share/control.dart';
import 'package:eeg_tracker/share/isolate.dart';
import 'package:eeg_tracker/share/protocol.dart';
import 'package:eeg_tracker/ui/phone_checks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A server that comes up at once on a made-up address and stops when asked.
Future<void> fakeServer(List<Object?> args) async {
  final toHost = args[0]! as SendPort;
  final inbox = ReceivePort();
  toHost.send(['port', inbox.sendPort]);
  toHost.send(['up', <String>['192.168.1.5', '127.0.0.1'], args[3]]);
  inbox.listen((m) {
    if (m is List && m[0] == 'x') {
      toHost.send(['down', 'stopped']);
      inbox.close();
    }
  });
}

/// PhoneChannel.kt's Wi-Fi lock as the two engines see it: one lock, held while any holder asks.
class FakeWifiLock {
  final Set<String> holders = {};
  final List<String> calls = [];
  bool get held => holders.isNotEmpty;

  Future<void> Function(bool on) holder(String who) => (on) async {
    calls.add('$who ${on ? 'on' : 'off'}');
    on ? holders.add(who) : holders.remove(who);
  };
}

const connected = WifiState(
  enabled: true,
  connected: true,
  linkMbps: 866,
  rssi: -58,
  freqMhz: 5180,
  route: 'wifi',
  screenOn: false,
  idle: false,
  lockHeld: true,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  group('the Wi-Fi line', () {
    test('connected: link speed, signal and band; the default route, screen, Doze and the lock', () {
      expect(connected.line(), 'wifi connected, 866 Mbps, -58 dBm, 5 GHz; default route wifi; screen off; idle no; lock held');
    });

    test('not connected, switched off, and what Android did not say', () {
      const gone = WifiState(enabled: true, connected: false, route: 'cell', screenOn: false, idle: true, lockHeld: true);
      expect(gone.line(), 'wifi not connected; default route cell; screen off; idle yes; lock held');
      const off = WifiState(enabled: false, connected: false, route: 'none', lockHeld: false);
      expect(off.line(), 'wifi off; default route none; screen ?; idle ?; lock not held');
      const vpn = WifiState(enabled: true, connected: true, freqMhz: 2437, route: 'vpn over wifi', screenOn: true, idle: false, lockHeld: false);
      expect(vpn.line(), 'wifi connected, 2.4 GHz; default route vpn over wifi; screen on; idle no; lock not held');
      expect(const WifiState(enabled: true, connected: true, freqMhz: 5955, route: 'wifi', lockHeld: true).band, '6');
    });

    test("from the phone's answer; anything else is no answer, never a throw", () {
      final s = WifiState.fromMap({
        'enabled': true,
        'connected': true,
        'linkMbps': 866,
        'rssi': -58,
        'freqMhz': 5180,
        'route': 'wifi',
        'screenOn': false,
        'idle': false,
        'lock': true,
      });
      expect(s?.line(), connected.line());
      expect(WifiState.fromMap(null), isNull);
      expect(WifiState.fromMap('x'), isNull);
      expect(WifiState.fromMap({'connected': 'yes'}), isNull);
      // a route with a ";" would break the line's fields: it is cut at it
      expect(WifiState.fromMap({'connected': false, 'route': 'odd; thing', 'lock': false})?.route, 'odd');
    });
  });

  group('the watch', () {
    late List<String> lines;
    late WifiState? now;
    late Object? fails;
    late DateTime clock;
    late WifiWatch w;

    setUp(() {
      lines = [];
      now = connected;
      fails = null;
      clock = DateTime(2026, 11, 20, 3, 20);
      w = WifiWatch(
        read: () async {
          if (fails != null) throw fails!;
          return now;
        },
        log: lines.add,
        clock: () => clock,
      );
    });

    test('a line at the start, then one at every change, not for link speed or signal alone', () async {
      await w.check();
      expect(lines, [connected.line()]);
      clock = clock.add(const Duration(seconds: 10));
      now = const WifiState(enabled: true, connected: true, linkMbps: 433, rssi: -71, freqMhz: 5180, route: 'wifi', screenOn: false, idle: false, lockHeld: true);
      await w.check();
      expect(lines, hasLength(1));
      clock = clock.add(const Duration(minutes: 5));
      now = const WifiState(enabled: true, connected: false, route: 'cell', screenOn: false, idle: true, lockHeld: true);
      await w.check();
      expect(lines.last, 'wifi not connected; default route cell; screen off; idle yes; lock held');
      await w.check();
      expect(lines, hasLength(2));
      now = connected;
      await w.check();
      expect(lines, [connected.line(), 'wifi not connected; default route cell; screen off; idle yes; lock held', connected.line()]);
    });

    test('the screen, Doze, the default route and the lock count as changes too', () async {
      await w.check();
      for (final s in const [
        WifiState(enabled: true, connected: true, linkMbps: 866, rssi: -58, freqMhz: 5180, route: 'wifi', screenOn: true, idle: false, lockHeld: true),
        WifiState(enabled: true, connected: true, linkMbps: 866, rssi: -58, freqMhz: 5180, route: 'wifi', screenOn: true, idle: true, lockHeld: true),
        WifiState(enabled: true, connected: true, linkMbps: 866, rssi: -58, freqMhz: 5180, route: 'cell', screenOn: true, idle: true, lockHeld: true),
        WifiState(enabled: true, connected: true, linkMbps: 866, rssi: -58, freqMhz: 5180, route: 'cell', screenOn: true, idle: true, lockHeld: false),
        WifiState(enabled: true, connected: true, linkMbps: 866, rssi: -58, freqMhz: 2412, route: 'cell', screenOn: true, idle: true, lockHeld: false),
      ]) {
        now = s;
        await w.check();
      }
      expect(lines, hasLength(6));
    });

    test('every 30 minutes a line even without a change, so a quiet log means the watch was alive', () async {
      await w.check();
      clock = clock.add(const Duration(minutes: 29));
      await w.check();
      expect(lines, hasLength(1));
      clock = clock.add(const Duration(minutes: 1));
      await w.check();
      expect(lines, hasLength(2));
    });

    test('a failed read is one line until it changes; the next good read is written again', () async {
      await w.check();
      fails = StateError('channel gone');
      await w.check();
      await w.check();
      expect(lines.last, 'wifi unreadable: Bad state: channel gone');
      expect(lines, hasLength(2));
      fails = null;
      now = null; // no answer at all
      await w.check();
      expect(lines.last, 'wifi unreadable: no answer');
      now = connected;
      await w.check();
      expect(lines.last, connected.line());
      expect(lines, hasLength(4));
    });

    test('a log that throws costs the line, never the watch', () async {
      var n = 0;
      final bad = WifiWatch(read: () async => connected, log: (_) => throw StateError('disk full ${++n}'), clock: () => clock);
      await bad.check();
      clock = clock.add(const Duration(hours: 1));
      await bad.check();
      expect(n, 2);
    });

    test('a slow read is given up after its time; started, it looks at once and on its period; stopped, never again', () async {
      final slow = WifiWatch(read: () => Completer<WifiState?>().future, log: lines.add, readTimeout: const Duration(milliseconds: 50));
      await slow.check();
      expect(lines.single, startsWith('wifi unreadable: TimeoutException'));

      var reads = 0;
      final t = WifiWatch(
        read: () async {
          reads++;
          return connected;
        },
        log: (_) {},
        every: const Duration(milliseconds: 40),
      );
      t.start();
      t.start(); // twice is once
      await Future<void>.delayed(const Duration(milliseconds: 150));
      t.stop();
      final seen = reads;
      expect(seen, inInclusiveRange(3, 6));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(reads, seen);
    });
  });

  group('the Wi-Fi lock across a night', () {
    late Directory files;
    late ShareConfig saved;
    late FakeWifiLock lock;
    late ShareControl screen;

    setUp(() {
      files = Directory.systemTemp.createTempSync('night_wifi_test');
      saved = const ShareConfig();
      lock = FakeWifiLock();
      screen = ShareControl(
        load: () async => saved,
        save: (x) async => saved = x,
        sendToRecorder: (_) {},
        keepScreenOn: (_) async {},
        wifiLock: lock.holder('screen'),
        host: (dir, onChange, wifiLock) =>
            ShareHost(filesDir: dir, onLog: (_) {}, onChange: onChange, entry: fakeServer, wifiLock: wifiLock),
      );
    });
    tearDown(() async {
      await screen.setOn(false);
      screen.dispose();
      files.deleteSync(recursive: true);
    });

    ShareHost recorderHost() => ShareHost(filesDir: files.path, onLog: (_) {}, entry: fakeServer, wifiLock: lock.holder('recorder'));

    test('between nights the screen holds it while sharing is on, and lets go when it is off', () async {
      await screen.sync(night: false, filesDir: files.path);
      expect(lock.held, isFalse);
      await screen.setOn(true);
      await settle();
      expect(lock.holders, {'screen'});
      await screen.setOn(false);
      await settle();
      expect(lock.held, isFalse);
    });

    test('the night: held while the screen hands over to the recorder, and back after Stop, never a gap', () async {
      await screen.sync(night: false, filesDir: files.path);
      await screen.setOn(true);
      await settle();
      expect(lock.holders, {'screen'});

      // Start night: the screen lets go before the recorder's service serves
      await screen.beforeNight();
      await settle();
      final night = recorderHost();
      await night.start(saved);
      await settle();
      expect(lock.holders, {'recorder'});

      // the screen during the night (opened, closed, the phone locked): the recorder keeps it
      await screen.sync(night: true, filesDir: files.path);
      await settle();
      expect(lock.holders, {'recorder'});

      // Stop: the screen serves again before the recorder's server has closed (it takes up to 4 s): both hold it,
      // and the recorder letting go late leaves the screen's hold
      await screen.afterStop();
      await screen.sync(night: false, filesDir: files.path);
      await settle();
      expect(lock.holders, {'screen', 'recorder'});
      await night.stop();
      expect(lock.holders, {'screen'});

      // sharing ends 15 minutes after Stop (its time is up): nobody holds it
      await screen.setOn(false);
      await settle();
      expect(lock.held, isFalse);
      expect(lock.calls, ['screen on', 'screen off', 'recorder on', 'screen on', 'recorder off', 'screen off']);
    });

    test('a night the headband watcher starts: the recorder takes it while the screen still serves; the screen lets go '
        'at its next sync', () async {
      // The watcher starts the recorder from its own engine (lib/auto/task.dart): the screen hears of the night only
      // at its once-a-minute sync, and meanwhile its server and its lock stay (the recorder's server waits for the
      // port, isolate.dart). The screen's lock follows its server (DECISIONS 612; no keep since row 678).
      await screen.sync(night: false, filesDir: files.path);
      await screen.setOn(true);
      await settle();
      expect(lock.holders, {'screen'});

      final night = recorderHost();
      await night.start(saved);
      await settle();
      expect(lock.holders, {'screen', 'recorder'});

      await screen.sync(night: true, filesDir: files.path);
      await settle();
      expect(lock.holders, {'recorder'});

      // Stop (from the night's notification): the screen serves again with its lock
      await screen.sync(night: false, filesDir: files.path);
      await night.stop();
      await settle();
      expect(lock.holders, {'screen'});

      // sharing switched off: the lock ends with the server
      await screen.setOn(false);
      await settle();
      expect(lock.held, isFalse);
    });

    test('the recorder switching sharing off and on during the night lets go and takes it again', () async {
      final night = recorderHost();
      await night.start(ShareConfig(token: 'abcdefghjkmn').switchedOn(DateTime.now().millisecondsSinceEpoch));
      await settle();
      expect(lock.holders, {'recorder'});
      await night.stop();
      expect(lock.held, isFalse);
      final again = recorderHost();
      await again.start(ShareConfig(token: 'abcdefghjkmn').switchedOn(DateTime.now().millisecondsSinceEpoch));
      await settle();
      expect(lock.holders, {'recorder'});
      await again.stop();
      expect(lock.held, isFalse);
    });

    test('a server that ends by itself lets go of the lock', () async {
      final dies = ShareHost(
        filesDir: files.path,
        onLog: (_) {},
        entry: (args) async => (args[0]! as SendPort).send(['down', 'the port is taken']),
        wifiLock: lock.holder('recorder'),
      );
      await dies.start(ShareConfig(token: 'abcdefghjkmn').switchedOn(DateTime.now().millisecondsSinceEpoch));
      await settle();
      expect(dies.running, isFalse);
      expect(lock.held, isFalse);
    });
  });

  group('phone checks for a night on Wi-Fi', () {
    List<String> texts(PhoneSnapshot p, {bool wifi = true, bool bluetooth = true}) => [
      for (final c in phoneChecks(phone: p, nearbyAllowed: true, xiaomiDone: true, bluetooth: bluetooth, wifi: wifi)) c.text,
    ];

    const fine = {'ignoringBatteryOptimizations': true, 'notificationsEnabled': true};

    test('Wi-Fi set to sleep with the screen off is named, with the way to the Wi-Fi settings', () {
      final never = texts(const PhoneSnapshot({...fine, 'wifiSleepPolicy': 2}));
      expect(never, isEmpty);
      final sleeps = phoneChecks(
        phone: const PhoneSnapshot({...fine, 'wifiSleepPolicy': 0}),
        nearbyAllowed: true,
        xiaomiDone: true,
        wifi: true,
      );
      expect(sleeps.single.text, startsWith('Wi-Fi is set to sleep when the screen is off'));
      expect(sleeps.single.fixes.map((f) => f.$2), [FixAction.wifiSettings]);
      expect(texts(const PhoneSnapshot({...fine, 'wifiSleepPolicy': 1})).single, startsWith('Wi-Fi is set to sleep when the screen is off unless the phone charges'));
      // not sharing and not the DIY board: Wi-Fi does not matter tonight
      expect(texts(const PhoneSnapshot({...fine, 'wifiSleepPolicy': 0}), wifi: false), isEmpty);
    });

    test('battery saver says it can turn Wi-Fi off too when Wi-Fi matters tonight', () {
      expect(texts(const PhoneSnapshot({...fine, 'powerSaveMode': true}), wifi: false), ['Battery saver is on. It can stop the recording.']);
      expect(texts(const PhoneSnapshot({...fine, 'powerSaveMode': true})), [
        'Battery saver is on. It can stop the recording and turn Wi-Fi off while the screen is off.',
      ]);
    });

    test('a VPN on while sharing: a calm reminder of what may shut the laptop out', () {
      final c = phoneChecks(
        phone: const PhoneSnapshot({...fine, 'vpnActive': true}),
        nearbyAllowed: true,
        xiaomiDone: true,
        wifi: true,
      );
      expect(c.single.serious, isFalse);
      expect(c.single.text, contains('Block connections without VPN'));
      expect(c.single.fixes.map((f) => f.$2), [FixAction.vpnSettings]);
      expect(texts(const PhoneSnapshot({...fine, 'vpnActive': true}), wifi: false), isEmpty);
    });

    test('the snapshot reads the new facts; an older answer without them changes nothing', () {
      const p = PhoneSnapshot({'wifiSleepPolicy': 0, 'vpnActive': true});
      expect((p.wifiSleepPolicy, p.vpnActive), (0, true));
      const old = PhoneSnapshot({});
      expect((old.wifiSleepPolicy, old.vpnActive), (null, false));
    });
  });
}
