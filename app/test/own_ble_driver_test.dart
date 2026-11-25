// Our own Bluetooth driver (lib/headband/own/driver.dart) on the fake headband (test/own_ble/fake_headband.dart):
// the same cases as the laptop driver's tests (analysis/tests/test_own_ble_driver.py).
@Tags(['realtime'])
library;

import 'dart:io';

import 'package:eeg_tracker/headband/own/driver.dart';
import 'package:eeg_tracker/headband/own/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'own_ble/fake_headband.dart';

const _ms = Duration(milliseconds: 1);

/// Drives [BrainBitBle.run] against the fake for a while and keeps what the callbacks saw.
class Run {
  Run(this.hb, {String? address = fakeAddress, this.mode = cmdSignal, Duration? stall, Layout? layout}) {
    drv = BrainBitBle(
      transport: hb,
      address: address,
      layout: layout,
      timeout: const Duration(seconds: 2),
      scanFor: const Duration(seconds: 1),
      stall: stall ?? _ms * 300,
      backoffs: [_ms * 50, _ms * 100, _ms * 200],
      contactTime: _ms * 300,
      poll: _ms * 20,
      log: logs.add,
    );
    drv.onSamples = (p, _, gap) {
      samples.addAll(p.samples);
      gaps.add(gap);
    };
    drv.onResist = (ohms, _) => resist.add(ohms);
  }

  final FakeHeadband hb;
  final int mode;
  late final BrainBitBle drv;
  final logs = <String>[], lost = <String>[];
  final samples = <BleSample>[];
  final gaps = <int>[], connected = <int>[];
  final resist = <Map<String, double>>[], contacts = <Map<String, double>>[];
  bool? result;

  Future<Run> go(
    bool Function(Run r) until, {
    Duration limit = const Duration(seconds: 10),
    void Function(Run r)? during,
    Duration? giveUpAfter,
  }) async {
    final stopping = Flag();
    Object? failure;
    final task = drv
        .run(
          mode,
          stopping,
          onConnected: (_, a) => connected.add(a),
          onLost: (e, _, _) => lost.add('$e'),
          onContact: contacts.add,
          giveUpAfter: giveUpAfter,
        )
        .then<void>((r) => result = r, onError: (Object e) => failure = e);
    final t0 = DateTime.now();
    while (!until(this) && DateTime.now().difference(t0) < limit && result == null && failure == null) {
      during?.call(this);
      await Future<void>.delayed(_ms * 20);
    }
    stopping.set();
    await task.timeout(const Duration(seconds: 5));
    if (failure != null) fail('run() threw $failure'); // a bug, not a drop: drops never leave run()
    return this;
  }
}

void main() {
  test('connects to a known address without scanning, and stops the stream when done', () async {
    final hb = FakeHeadband();
    final r = await Run(hb).go((r) => r.samples.length >= 400);
    expect(r.samples.length, greaterThanOrEqualTo(400));
    expect(hb.scans, 0);
    expect(hb.connects, 1);
    expect(hb.commands.first, cmdSignal);
    expect(hb.commands.last, cmdIdle);
    expect([for (final s in r.samples) s.pack], [for (var i = 0; i < r.samples.length; i++) i]); // one number per sample
    expect(hb.link, isNull); // disconnected at the end
    expect(r.result, isTrue);
  });

  test('scans by name only without an address', () async {
    final hb = FakeHeadband();
    final r = await Run(hb, address: null).go((r) => r.samples.length >= 80);
    expect(hb.scans, 1);
    expect(r.drv.address, fakeAddress);
    expect(r.drv.name, 'BB Black');
    expect(r.samples.length, greaterThanOrEqualTo(80));
  });

  test('finds the service by pattern with either suffix', () async {
    final r = await Run(FakeHeadband(suffix: '9')).go((r) => r.samples.length >= 80);
    expect(r.drv.service, '7e400001-b534-f393-68a9-e50e24dcca99');
    expect(r.samples.length, greaterThanOrEqualTo(80));
  });

  test('reads device information, battery and the packet size the link carries', () async {
    final hb = FakeHeadband(battery: 64);
    final drv = BrainBitBle(transport: hb, address: fakeAddress);
    final info = await drv.connect();
    expect(info.info, {
      'model': 'BrainBit Black (fake)',
      'serial': 'fake-serial',
      'firmware': '1.10.0',
      'hardware': '1.0.0',
      'manufacturer': 'fake',
    });
    expect(info.status!.battery, 64);
    expect(info.mtu, 517);
    expect(info.service, fakeUuid(1, '7'));
    await drv.close();
    expect(hb.commands, [cmdIdle]);
  });

  test('decoded volts match the samples the fake sent, within one count', () async {
    final hb = FakeHeadband(seed: 11);
    final r = await Run(hb).go((r) => r.samples.length >= 300);
    for (var n = 0; n < 300; n++) {
      final got = r.samples[n], want = hb.sent[n];
      expect(got.pack, n);
      expect(got.o1, closeTo(want['O1']!, fakeVoltsPerCount));
      expect(got.o2, closeTo(want['O2']!, fakeVoltsPerCount));
      expect(got.t3, closeTo(want['T3']!, fakeVoltsPerCount));
      expect(got.t4, closeTo(want['T4']!, fakeVoltsPerCount));
    }
  });

  test('reconnects by itself after drops, with growing pauses', () async {
    final hb = FakeHeadband(dropAfter: _ms * 300, dropFor: _ms * 350, maxDrops: 2);
    // where the packet number went back: a new stream after a reconnect
    List<int> restarts(Run r) => [
      for (var i = 1; i < r.samples.length; i++)
        if (r.samples[i].pack < r.samples[i - 1].pack) i,
    ];
    final r = await Run(hb).go((r) {
      final at = restarts(r);
      return at.length == 2 && r.samples.length - at.last > 100;
    });
    expect(hb.drops, 2);
    expect(hb.connects, 3);
    expect(r.connected.length, 3);
    expect(r.connected[0], 0);
    expect(r.connected[1], greaterThanOrEqualTo(1)); // refused tries while it was away came first
    expect(r.lost.length, greaterThanOrEqualTo(4), reason: '${r.lost}'); // each drop: "link dropped", then refused tries
    expect(r.lost.any((x) => x.contains('link dropped')), isTrue);
    expect(r.lost.any((x) => x.contains('not found')), isTrue);
    expect(
      hb.connectTimes[1].difference(hb.connectTimes[0]),
      greaterThanOrEqualTo(_ms * (300 + 350 - 50)),
    );
    expect(restarts(r).length, 2); // the counter starts again after each reconnect
    expect(r.gaps.every((g) => g == 0), isTrue); // and nothing counts as lost: the gap is in the arrival times
  });

  test('the pauses between tries are 1, 2, 5, 10, 20, then 30 s for ever', () async {
    expect([for (final d in backoff) d.inSeconds], [1, 2, 5, 10, 20, 30]);
    final hb = FakeHeadband()..awayUntil = DateTime.now().add(const Duration(hours: 1));
    final pauses = <Duration>[];
    final stopping = Flag();
    final drv = BrainBitBle(
      transport: hb,
      address: fakeAddress,
      backoffs: [_ms * 10, _ms * 20, _ms * 30],
    );
    final task = drv.run(cmdSignal, stopping, onLost: (_, attempt, pause) {
      pauses.add(pause);
      if (attempt == 5) stopping.set();
    });
    await task.timeout(const Duration(seconds: 5));
    expect(pauses, [_ms * 10, _ms * 20, _ms * 30, _ms * 30, _ms * 30, _ms * 30]);
  });

  test('a late "disconnected" of an earlier link does not end the next session', () async {
    final hb = FakeHeadband();
    final drv = BrainBitBle(transport: hb, address: fakeAddress);
    await drv.connect();
    final old = hb.link!;
    await drv.close(idle: false);
    await drv.connect();
    old.lateLostCallback(); // the first link's "disconnected" arrives only now
    expect(drv.lost!.isSet, isFalse);
    hb.drop(); // the current link breaking still counts
    await Future<void>.delayed(_ms * 10);
    expect(drv.lost!.isSet, isTrue);
    expect(drv.isConnected, isFalse);
    await drv.close();
  });

  test('lost packets are counted from the headband\'s own counter', () async {
    final r = await Run(FakeHeadband(loseEvery: 5)).go((r) => r.samples.length >= 400);
    final jumps = r.gaps.where((g) => g != 0).toList();
    expect(jumps.toSet(), {8});
    expect(r.drv.lostSamples, 8 * jumps.length);
  });

  test('a stall gets the start command again, then a reconnect', () async {
    final hb = FakeHeadband(stallAfter: _ms * 200);
    final r = await Run(hb, stall: _ms * 250).go(
      (r) => hb.connects >= 2 && r.samples.length > 100,
      limit: const Duration(seconds: 8),
    );
    expect(r.logs.any((x) => x.contains('sending the start command again')), isTrue, reason: '${r.logs}');
    expect(r.lost.any((x) => x.contains('no signal for')), isTrue, reason: '${r.lost}');
    expect(hb.connects, greaterThanOrEqualTo(2));
  });

  test('a contact check runs in the same connection and the signal comes back', () async {
    final hb = FakeHeadband();
    int? asked;
    final r = await Run(hb).go(
      (r) => asked != null && r.contacts.isNotEmpty && r.samples.length > asked! + 200,
      during: (r) {
        if (r.samples.length > 100 && asked == null) {
          asked = r.samples.length;
          r.drv.checkContact();
        }
      },
    );
    expect(r.contacts.first, {'O1': 150000.0, 'O2': 220000.0, 'T3': 400000.0, 'T4': 180000.0});
    expect(hb.commands.take(5), [cmdSignal, cmdIdle, cmdResist, cmdIdle, cmdSignal]);
    expect(hb.connects, 1); // no reconnect, no restart
  });

  test('signal and resistance together with command 5', () async {
    final hb = FakeHeadband();
    final r = await Run(hb, mode: cmdSignalResist).go((r) => r.samples.length >= 300 && r.resist.length >= 3);
    expect(hb.commands.first, cmdSignalResist);
    expect(r.resist.last['T3'], 400000.0);
  });

  test('command 5 without a signal falls back to command 3', () async {
    final hb = FakeHeadband(ignoreCmd5: true);
    final r = await Run(hb, mode: cmdSignalResist).go((r) => r.samples.length >= 200);
    expect(hb.commands.take(3), [cmdSignalResist, cmdIdle, cmdSignal]);
    expect(r.logs.any((x) => x.contains('falling back to signal only')), isTrue);
  });

  test('power down is never sent', () async {
    final hb = FakeHeadband();
    final drv = BrainBitBle(transport: hb, address: fakeAddress);
    await drv.connect();
    expect(() => drv.command(cmdPowerDown), throwsArgumentError);
    await drv.close();
    expect(hb.commands.contains(cmdPowerDown), isFalse);
  });

  test('a headband that needs pairing: a plain hint without it, works with it', () async {
    final hb = FakeHeadband(needsPairing: true);
    final logs = <String>[];
    final plain = BrainBitBle(transport: hb, address: fakeAddress, log: logs.add);
    await expectLater(
      plain.connect(),
      throwsA(isA<HeadbandLost>().having((e) => e.message, 'message', contains('pairing'))),
    );
    expect(hb.link, isNull); // the failed link was closed
    expect(hb.paired, isFalse);
    final paired = BrainBitBle(transport: hb, address: fakeAddress, pair: true);
    final info = await paired.connect();
    expect(info.status!.battery, 87);
    expect(hb.paired, isTrue);
    await paired.close();
  });

  test('a known address that does not answer: the caller can fall back to a name scan', () async {
    final hb = FakeHeadband(directFails: true);
    final drv = BrainBitBle(transport: hb, address: fakeAddress, timeout: _ms * 200, scanFor: _ms * 500);
    await expectLater(drv.connect(), throwsA(isA<HeadbandLost>()));
    expect(await drv.scanForBand(), fakeAddress);
    final info = await drv.connect();
    expect(info.rssi, -61);
    await drv.close();
  });

  test('with a give-up time the loop ends by itself once the headband stays away', () async {
    final hb = FakeHeadband(dropAfter: _ms * 200, dropFor: const Duration(seconds: 30), maxDrops: 1);
    final r = await Run(hb).go((r) => false, giveUpAfter: _ms * 400, limit: const Duration(seconds: 5));
    expect(r.result, isFalse); // gave up
    expect(r.samples.length, greaterThan(20));
    expect(r.lost.length, greaterThanOrEqualTo(2));
    expect(hb.link, isNull);
  });

  test('the wire order and gain come from the layout', () async {
    final hb = FakeHeadband(rows: (n) => {'O1': 10e-6, 'O2': 20e-6, 'T3': 30e-6, 'T4': 40e-6});
    final r = await Run(
      hb,
      layout: Layout(order: ['T3', 'T4', 'O1', 'O2'], gain: 12),
    ).go((r) => r.samples.length >= 16);
    final s = r.samples.first; // the fake sends O2 T3 T4 O1 at gain 6: read as T3 T4 O1 O2 at gain 12
    expect(s.t3, closeTo(10e-6, 1e-7));
    expect(s.t4, closeTo(15e-6, 1e-7));
    expect(s.o1, closeTo(20e-6, 1e-7));
    expect(s.o2, closeTo(5e-6, 1e-7));
  });

  test('our connection code cannot unpair or remove a device (DECISIONS 84)', () {
    // BrainBit's SDK removed every known Bluetooth device on the laptop. Ours must not even contain such a call.
    final banned = RegExp(r'\b(unpair|removeBond|removeDevice|RemoveDevice|disableBluetooth|clearGattCache)\s*\(');
    final files = Directory('lib/headband').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files.length, greaterThanOrEqualTo(4));
    for (final f in files) {
      final code = f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
      expect(banned.hasMatch(code), isFalse, reason: f.path);
    }
  });

  test('Flag: wait returns at once when set, false after the time, and wakes every waiter', () async {
    final f = Flag();
    expect(await f.wait(_ms * 10), isFalse);
    final a = f.wait(const Duration(seconds: 5)), b = Flag.either([Flag(), f], const Duration(seconds: 5));
    f.set();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(await f.wait(Duration.zero), isTrue);
  });
}
