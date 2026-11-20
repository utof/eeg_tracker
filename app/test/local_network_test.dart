// Android 17's local-network permission (ACCESS_LOCAL_NETWORK): asked only when the phone is Android 17 or newer AND
// the app targets 37 or newer; below that, Android grants it by itself and asking would be wrong.
import 'package:eeg_tracker/phone.dart';
import 'package:eeg_tracker/share/local_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('localNetworkNeedsAsking', () {
    for (final (device, target, asks) in [
      (36, 36, false), // today: Android 16, target 36
      (37, 36, false), // Android 17 phone, app still targets 36: implicit grant
      (36, 37, false), // an app that targets 37 on an older phone: the permission does not exist there
      (37, 37, true),
      (38, 40, true),
      (0, 37, false), // unknown phone (no Android): never ask
      (37, 0, false), // unknown target: never ask
    ]) {
      test('device $device, target $target -> ${asks ? 'asks' : 'does not ask'}', () {
        expect(localNetworkNeedsAsking(deviceSdk: device, targetSdk: target), asks);
      });
    }
  });

  group('ensureLocalNetwork', () {
    late int statusCalls;
    late int requestCalls;

    Future<bool> run({
      required int device,
      required int target,
      PermissionStatus status = PermissionStatus.denied,
      PermissionStatus asked = PermissionStatus.granted,
    }) {
      statusCalls = 0;
      requestCalls = 0;
      return ensureLocalNetwork(
        sdks: () async => (device: device, target: target),
        status: () async {
          statusCalls++;
          return status;
        },
        request: () async {
          requestCalls++;
          return asked;
        },
      );
    }

    test('below Android 17 it is true and touches nothing', () async {
      expect(await run(device: 36, target: 36), isTrue);
      expect(statusCalls + requestCalls, 0);
    });

    test('an app that targets 36 on an Android 17 phone is true and asks nothing', () async {
      expect(await run(device: 37, target: 36), isTrue);
      expect(statusCalls + requestCalls, 0);
    });

    test('already granted: true without a prompt', () async {
      expect(await run(device: 37, target: 37, status: PermissionStatus.granted), isTrue);
      expect(requestCalls, 0);
    });

    test('not granted yet: asks once and returns the answer', () async {
      expect(await run(device: 37, target: 37), isTrue);
      expect(requestCalls, 1);
      expect(await run(device: 37, target: 37, asked: PermissionStatus.denied), isFalse);
      expect(await run(device: 37, target: 37, asked: PermissionStatus.permanentlyDenied), isFalse);
    });

    test('limited counts as allowed', () async {
      expect(await run(device: 37, target: 37, asked: PermissionStatus.limited), isTrue);
    });

    test('the real defaults answer true when there is no phone to ask (a plain test run)', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await ensureLocalNetwork(), isTrue);
    });
  });

  test('the snapshot carries the app\'s own target SDK', () {
    expect(const PhoneSnapshot({'sdkInt': 37, 'targetSdk': 36}).targetSdkInt, 36);
    expect(const PhoneSnapshot({}).targetSdkInt, 0);
  });
}
