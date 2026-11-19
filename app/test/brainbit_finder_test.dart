// SdkFinder against neurosdk2's own platform channels (pigeon), answered here: what a failed scan leaves behind, and
// what the night recorder does when the SDK never answers.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/recorder/brainbit.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurosdk2/constants.dart';

const String _api = 'dev.flutter.pigeon.pigeon_neuro_api_package.NeuroApi';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMessageCodec();
  late List<String> calls;

  /// Answers [method] with [reply] (pigeon's reply list: `[value]`, or `[code, message, details]` for an error).
  void answer(String method, List<Object?> reply) => messenger.setMockMessageHandler('$_api.$method', (_) async {
    calls.add(method);
    return codec.encodeMessage(reply);
  });

  setUp(() {
    calls = [];
    answer('createScanner', ['scanner-1']);
    answer('stopScan', [null]);
    answer('closeScanner', [null]);
    messenger.setMockStreamHandler(
      const EventChannel(Constants.sensorListChangedEventName),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  test('a scan that fails (Bluetooth off) closes its scanner, so no scanner or scan is left open all night', () async {
    answer('startScan', ['bluetooth-off', 'Bluetooth is off', null]);
    await expectLater(SdkFinder().find(const Duration(milliseconds: 50)), throwsA(isA<PlatformException>()));
    await Future<void>.delayed(Duration.zero); // Scanner.dispose closes asynchronously
    expect(calls, containsAllInOrder(['createScanner', 'startScan', 'closeScanner']));
  });

  test('a scan that fails while scanning stops and closes its scanner', () async {
    answer('startScan', [null]);
    answer('getSensors', ['error', 'the SDK lost its scanner', null]);
    await expectLater(SdkFinder().find(const Duration(milliseconds: 50)), throwsA(isA<PlatformException>()));
    await Future<void>.delayed(Duration.zero);
    expect(calls, containsAllInOrder(['startScan', 'getSensors', 'stopScan', 'closeScanner']));
  });

  test('a scan that finds nothing closes its scanner (as before)', () async {
    answer('startScan', [null]);
    answer('getSensors', [<Object?>[]]);
    expect(await SdkFinder().find(const Duration(milliseconds: 1200)), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(calls, containsAllInOrder(['startScan', 'getSensors', 'stopScan', 'closeScanner']));
  });

  // The sixth integration's freeze (DECISIONS rows 410-413): BrainBit's library never returned from getSensors. The
  // plugin now answers on its own thread (packages/neurosdk2/VENDORED.md), so for Dart such a call is one that never
  // answers, and the recorder's own deadline (row 50) must turn it into a saved night and a process restart.
  test('a getSensors that never answers ends in the recorder\'s stuck path: night kept, restart asked', () async {
    final hung = Completer<ByteData?>(); // never completed
    answer('startScan', [null]);
    messenger.setMockMessageHandler('$_api.getSensors', (_) {
      calls.add('getSensors');
      return hung.future;
    });
    final dir = Directory.systemTemp.createTempSync('sdk_never_answers');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = MemoryNightStore();
    final stuck = <String>[];
    final recorder = NightRecorder(
      finder: SdkFinder(),
      dir: dir,
      store: store,
      onStatus: (_) {},
      onStuck: (r) async => stuck.add(r),
      watch: null,
      // the finder asks for the list once a second, so the deadline (scan + connect) must be longer than that
      timing: const RecorderTiming(
        scanFor: Duration(milliseconds: 100),
        connectTimeout: Duration(milliseconds: 1500),
        sdkTimeout: Duration(milliseconds: 300),
        notFoundWait: Duration(milliseconds: 10),
        stopTimeout: Duration(seconds: 2),
      ),
    );

    await recorder.run(restartedBySystem: false).timeout(const Duration(seconds: 10));

    expect(calls, containsAllInOrder(['createScanner', 'startScan', 'getSensors']));
    expect(hung.isCompleted, isFalse);
    expect(stuck.single, contains('scan and connect'));
    expect(store.state.active, isTrue); // the restarted process goes on with the night
  });
}
