// The keeper that lets a session go on with the phone locked (DECISIONS rows 190-196), against a fake Android side.
import 'package:eeg_tracker/session_keeper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('eeg_tracker/session');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? Function(MethodCall call) answer = (_) => null;

  setUp(() {
    calls.clear();
    answer = (call) => call.method == 'hold' ? <String>['headband', 'microphone'] : null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> tapStop() => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(const MethodCall('stopTapped')),
    (_) {},
  );

  test('hold sends the words and what is needed; the phone may be locked when all of it is kept', () async {
    final k = PhoneSessionKeeper();
    expect(await k.hold(const KeepSpec(title: 'Fall asleep', text: 'Sound session', headband: true)), isTrue);
    expect(calls.single.method, 'hold');
    expect(calls.single.arguments, {'title': 'Fall asleep', 'text': 'Sound session', 'headband': true, 'microphone': false});
    await k.release();
    expect(calls.last.method, 'release');
  });

  test('Android keeps less than asked (the microphone refused): do not lock', () async {
    answer = (call) => call.method == 'hold' ? <String>['headband'] : null;
    final k = PhoneSessionKeeper();
    expect(await k.hold(const KeepSpec(title: 'Dream catcher', headband: true, microphone: true)), isFalse);
    expect(await k.hold(const KeepSpec(title: 'Meditation', headband: true)), isTrue);
    await k.release();
  });

  test('a refused service is a plain no, never an error', () async {
    answer = (call) => throw PlatformException(code: 'session', message: 'not allowed');
    final k = PhoneSessionKeeper();
    expect(await k.hold(const KeepSpec(title: 'Relax')), isFalse);
    await k.release();
  });

  test('no Android side at all (a test, another platform): a plain no', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await PhoneSessionKeeper().hold(const KeepSpec(title: 'Relax')), isFalse);
  });

  test('Stop on the notification reaches the session that holds; a screen that left cannot release it', () async {
    final a = PhoneSessionKeeper(), b = PhoneSessionKeeper();
    var stopsA = 0, stopsB = 0;
    a.onStop = () => stopsA++;
    b.onStop = () => stopsB++;
    await a.hold(const KeepSpec(title: 'Relax'));
    await tapStop();
    expect((stopsA, stopsB), (1, 0));
    await b.hold(const KeepSpec(title: 'Meditation', headband: true));
    await a.release(); // the first screen closing late
    expect(calls.where((c) => c.method == 'release'), isEmpty);
    await tapStop();
    expect((stopsA, stopsB), (1, 1));
    await b.release();
    expect(calls.last.method, 'release');
    await tapStop(); // nobody holds: nothing happens
    expect((stopsA, stopsB), (1, 1));
  });

  test('a release never overtakes the hold before it', () async {
    final k = PhoneSessionKeeper();
    final held = k.hold(const KeepSpec(title: 'Relax'));
    final released = k.release();
    await Future.wait([held, released]);
    expect(calls.map((c) => c.method), ['hold', 'release']);
  });
}
