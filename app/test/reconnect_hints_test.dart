// The phone's hints for the reconnect ladder (lib/headband/reconnect_hints.dart, DECISIONS 943) over a fake channel,
// and the lost notice's words after "Reconnect now" found nothing.
import 'package:eeg_tracker/headband/reconnect_hints.dart';
import 'package:eeg_tracker/headband/reconnect_ladder.dart';
import 'package:eeg_tracker/recorder/recorder_service.dart' show triedTellAfter, triedText;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('eeg_tracker/hints');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> asked;
  var screen = true;

  setUp(() {
    asked = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call.method);
      return call.method == 'screenOn' ? screen : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> fromPhone(Object? name) => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('hint', name)),
    (_) {},
  );

  test('every hint Android sends reaches the listener by its name; unknown ones are dropped', () async {
    final hints = ReconnectHints();
    final got = <ReconnectHint>[];
    await hints.start(got.add);
    expect(asked, ['watch']);
    for (final name in ['unlocked', 'bluetoothOn', 'appOpened', 'reconnectNow', 'cameNear', 'nonsense', null]) {
      await fromPhone(name);
    }
    expect(got, [
      ReconnectHint.unlocked,
      ReconnectHint.bluetoothOn,
      ReconnectHint.appOpened,
      ReconnectHint.reconnectNow,
      ReconnectHint.cameNear,
    ]);
    await hints.stop();
    expect(asked, ['watch', 'unwatch']);
    await fromPhone('unlocked');
    expect(got, hasLength(5), reason: 'nothing after stop');
  });

  test('the screen: on, off, and "off" when the phone cannot be asked', () async {
    final hints = ReconnectHints();
    expect(await hints.screenOn(), isTrue);
    screen = false;
    expect(await hints.screenOn(), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
    expect(await hints.screenOn(), isFalse);
    await hints.start((_) {}); // a phone without the channel: no error
  });

  test('the notice after a try by hand that found nothing', () {
    expect(triedTellAfter, greaterThan(const Duration(seconds: 17)), reason: 'one direct try may take 17 s');
    expect(
      triedText(DateTime(2026, 11, 24, 9, 5)),
      'Tried again at 09:05: no answer yet. Is it switched on and charged? The recording keeps waiting for it.',
    );
  });
}
