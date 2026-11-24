// UniversalTransport (lib/headband/own/universal_transport.dart) on a stand-in for universal_ble's platform side.
import 'dart:async';

import 'package:eeg_tracker/headband/own/protocol.dart' show isBrainBit;
import 'package:eeg_tracker/headband/own/transport.dart';
import 'package:eeg_tracker/headband/own/universal_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

/// A platform whose scan start never answers; everything else this test does not use.
class _StartNeverAnswers extends UniversalBlePlatform {
  int stops = 0;

  @override
  Future<void> startScan({ScanFilter? scanFilter, PlatformConfig? platformConfig}) => Completer<void>().future;

  @override
  Future<void> stopScan() async => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Android's side of one headband for the waiting connect: it records the calls, and the test says when the headband
/// shows up, drops, or Android reports the link's timing.
class _WaitingPlatform extends UniversalBlePlatform {
  final List<String> calls = [];
  bool connected = false;
  Object? connectError;

  /// A disconnect that takes this long to reach Android (the "give up" after a failed direct try).
  Duration disconnectTakes = Duration.zero;

  void showUp() {
    connected = true;
    updateConnection(_addr, true);
  }

  void drop() {
    connected = false;
    updateConnection(_addr, false);
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    calls.add('connect auto=$autoConnect');
    if (connectError != null) throw connectError!;
  }

  @override
  Future<void> disconnect(String deviceId) async {
    if (disconnectTakes > Duration.zero) await Future<void>.delayed(disconnectTakes);
    calls.add('disconnect');
    final was = connected;
    connected = false;
    if (was) updateConnection(deviceId, false);
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connected ? BleConnectionState.connected : BleConnectionState.disconnected;

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => 247;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const String _addr = 'C0:FF:EE:00:00:01';

void main() {
  group('the waiting connect (DECISIONS 942)', () {
    late _WaitingPlatform p;
    final long = waitingAskFor;
    setUp(() {
      p = _WaitingPlatform();
      UniversalBle.setInstance(p);
      waitingAskFor = const Duration(milliseconds: 60);
    });
    tearDown(() => waitingAskFor = long);

    test('connect(autoConnect: true); the plugin\'s call ending by its time limit means "still waiting"', () async {
      var lost = 0;
      final w = UniversalTransport().connectWaiting(_addr, onLost: () => lost++)!;
      BleLink? link;
      Object? error;
      unawaited(w.link.then<void>((l) => link = l, onError: (Object e) => error = e));
      await Future<void>.delayed(const Duration(milliseconds: 200)); // three time limits of the plugin's own call
      expect(p.calls, ['connect auto=true'], reason: 'asked once; nothing closed when the call timed out');
      expect((link, error), (null, null), reason: 'still waiting');
      // the headband shows up: the connection stream says so
      p.showUp();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(link, isNotNull);
      expect(link!.isConnected, isTrue);
      expect(link!.mtu, 247);
      // the link is its owner's now: closing the (ended) waiting connect closes nothing
      await w.cancel();
      expect(p.calls, ['connect auto=true']);
      // the link's real timing, as Android reports it: once per value
      final facts = <String>[];
      (link! as LinkFacts).onFacts = facts.add;
      BleConnectionParametersChange change(int interval) =>
          BleConnectionParametersChange(deviceId: _addr, interval: interval, latency: 0, supervisionTimeout: 500, status: 0);
      p.updateConnectionParameters(change(6));
      p.updateConnectionParameters(change(12));
      p.updateConnectionParameters(change(12));
      expect(facts, [
        'link timing: interval 7.50 ms, latency 0, timeout 5.0 s',
        'link timing: interval 15 ms, latency 0, timeout 5.0 s',
      ]);
      // a drop reaches the owner once
      p.drop();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(lost, 1);
      await link!.disconnect();
      expect(p.calls.last, 'disconnect', reason: 'the owner closes it: Android must not reconnect it by itself');
    });

    test('closing it while it waits closes Android\'s side and ends it with an error', () async {
      final w = UniversalTransport().connectWaiting(_addr, onLost: () {})!;
      Object? error;
      unawaited(w.link.then<void>((_) {}, onError: (Object e) => error = e));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await w.cancel();
      expect(p.calls, ['connect auto=true', 'disconnect']);
      expect(error, isA<BleError>());
      p.showUp(); // too late: nobody takes it
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(p.calls, ['connect auto=true', 'disconnect']);
    });

    test('Android refusing the waiting connect ends it with the error (the ladder falls back)', () async {
      p.connectError = StateError('Bluetooth is off');
      final w = UniversalTransport().connectWaiting(_addr, onLost: () {})!;
      await expectLater(w.link, throwsA(isA<BleError>().having((e) => e.message, 'message', contains('Bluetooth is off'))));
    });

    test('a failed direct try\'s late "give up" is waited for: it cannot close the waiting connect opened after it', () async {
      p.connectError = StateError('no answer');
      p.disconnectTakes = const Duration(milliseconds: 80);
      await expectLater(
        UniversalTransport().connect(_addr, timeout: const Duration(milliseconds: 50), onLost: () {}),
        throwsA(isA<BleError>()),
      );
      p.connectError = null;
      final w = UniversalTransport().connectWaiting(_addr, onLost: () {})!;
      w.link.ignore();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(p.calls, ['connect auto=false', 'disconnect', 'connect auto=true'], reason: 'the give-up first, then the waiting connect');
      await w.cancel();
    });
  });

  test('a scan whose start never answers ends at its own time and lets go of its listener', () async {
    UniversalBle.setInstance(_StartNeverAnswers());
    final sw = Stopwatch()..start();
    await expectLater(
      UniversalTransport().scan(isBrainBit, const Duration(milliseconds: 200)).timeout(const Duration(seconds: 10)),
      throwsA(isA<BleError>().having((e) => e.message, 'message', contains('the scan did not start'))),
    );
    // The plugin queues the stop behind the start that never ends: the stop gets a few seconds, not for ever.
    expect(sw.elapsed, lessThan(const Duration(seconds: 6)));
  });
}
