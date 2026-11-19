// SdkFinder against neurosdk2's own platform channels (pigeon), answered here: what a failed scan leaves behind.
import 'package:eeg_tracker/recorder/brainbit.dart';
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
}
