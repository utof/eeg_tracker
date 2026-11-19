// Audio focus through the session keeper (review 2026-11-19, finding 14; DECISIONS row 468): Android's focus changes
// (a call, another app's sound) come back over the session channel and reach only the screen that holds; each
// session reacts in its own way (the controllers' tests).
import 'package:eeg_tracker/session_keeper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('eeg_tracker/session');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'hold' ? <String>['headband'] : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> focus(String change) => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('focus', change)),
    (_) {},
  );

  test('hold asks for the sound (audio focus) unless the session says not to', () async {
    final k = PhoneSessionKeeper();
    await k.hold(const KeepSpec(title: 'Meditation', headband: true));
    expect((calls.last.arguments as Map)['focus'], isTrue);
    await k.hold(const KeepSpec(title: 'Nap', headband: true, focus: false));
    expect((calls.last.arguments as Map)['focus'], isFalse);
    await k.release();
  });

  test('a focus change reaches the session that holds, in words; a screen that left gets nothing', () async {
    final a = PhoneSessionKeeper(), b = PhoneSessionKeeper();
    final seenA = <FocusChange>[], seenB = <FocusChange>[];
    a.onFocus = seenA.add;
    b.onFocus = seenB.add;
    await a.hold(const KeepSpec(title: 'Relax'));
    await focus('lossTransient'); // a call rings
    await focus('gain'); // it ended
    await b.hold(const KeepSpec(title: 'Dream catcher', microphone: true));
    await focus('loss'); // another app plays music
    await focus('duck');
    await focus('something new'); // an answer this app does not know: nothing
    expect(seenA, [FocusChange.paused, FocusChange.back]);
    expect(seenB, [FocusChange.lost, FocusChange.duck]);
    await b.release();
    await focus('gain'); // nobody holds: nothing happens
    expect(seenB.length, 2);
  });
}
