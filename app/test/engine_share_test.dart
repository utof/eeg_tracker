// The audio engine shared by the sounds of one screen (flutter_soloud is one engine per app): the review of
// 2026-11-19 (finding 10) found a Listen preview, still fading out, closing the engine under the session that had just
// started on it. A fake engine stands in for SoLoud, which cannot run in `flutter test`.
import 'dart:async';

import 'package:eeg_tracker/sound/engine_share.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeEngine {
  bool up = false;
  int opens = 0, closes = 0;
  Completer<void>? closing;

  Future<void> open() async {
    opens++;
    up = true;
  }

  Future<void> close() async {
    final c = closing;
    if (c != null) await c.future;
    closes++;
    up = false;
  }
}

void main() {
  test('a preview fading out does not close the engine under the session that started on it', () async {
    final e = FakeEngine();
    final share = EngineShare(isUp: () => e.up, close: e.close);
    final preview = Object(), session = Object();
    await share.take(preview, e.open); // Listen
    await share.take(session, e.open); // Start, within the preview's fade
    expect(e.opens, 1, reason: 'the session plays on the engine the preview opened');
    await share.give(preview); // the preview's fade ends
    expect((e.up, e.closes), (true, 0), reason: 'the session still uses it');
    await share.give(session);
    expect((e.up, e.closes), (false, 1), reason: 'the last one closes it');
  });

  test('a sound that never took the engine cannot close it (leaving the screen with no preview playing)', () async {
    final e = FakeEngine();
    final share = EngineShare(isUp: () => e.up, close: e.close);
    final session = Object();
    await share.take(session, e.open);
    await share.give(Object()); // the idle preview stopped as the screen closes
    await share.give(session); // ...and given back twice: harmless
    await share.give(session);
    expect((e.opens, e.closes), (1, 1));
  });

  test('a take that comes while the last give is closing waits and opens a fresh engine', () async {
    final e = FakeEngine()..closing = Completer<void>();
    final share = EngineShare(isUp: () => e.up, close: e.close);
    final a = Object(), b = Object();
    await share.take(a, e.open);
    final gave = share.give(a);
    final took = share.take(b, e.open);
    await Future<void>.delayed(Duration.zero);
    expect(e.opens, 1, reason: 'b waits for the close');
    e.closing!.complete();
    await Future.wait([gave, took]);
    expect((e.up, e.opens, e.closes, share.users), (true, 2, 1, 1));
  });

  test('an engine that fails to open gives no share; the next take tries again', () async {
    final e = FakeEngine();
    final share = EngineShare(isUp: () => e.up, close: e.close);
    final a = Object();
    await expectLater(share.take(a, () async => throw StateError('no audio device')), throwsStateError);
    expect(share.users, 0);
    await share.take(a, e.open);
    expect((e.up, share.users), (true, 1));
  });
}
