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

void main() {
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
