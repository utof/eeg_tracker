// The reconnect ladder (lib/headband/reconnect_ladder.dart, DECISIONS 940-945) on a fake clock: every stage change,
// every hint, the waiting connect, the Bluetooth off/on and restart rules, the fallback.
import 'dart:async';

import 'package:eeg_tracker/headband/reconnect_ladder.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const BandId id = BandId(name: 'Band', address: 'AA:BB');
const List<Duration> recorderWaits = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
];

class _Band implements Headband {
  bool disposed = false;
  @override
  String get name => 'Band';
  @override
  String get address => 'AA:BB';
  @override
  String get serial => '';
  @override
  BandId get id => const BandId(name: 'Band', address: 'AA:BB');
  @override
  int? get rssi => null;
  @override
  Stream<List<Sample>> get signal => const Stream.empty();
  @override
  Stream<Map<String, double>> get resistance => const Stream.empty();
  @override
  Stream<bool> get rangeChanges => const Stream.empty();
  @override
  Future<void> startSignal() async {}
  @override
  Future<void> stopSignal() async {}
  @override
  Future<void> startResist() async {}
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 50;
  @override
  Future<void> disconnectAndDispose() async => disposed = true;
}

/// Counts the waiting connects a ladder opens and closes; a test lets the headband "show up" or the connect break.
class _Waits {
  int opened = 0, closed = 0;
  bool none = false;
  Object? openError;
  Completer<Headband>? current;

  Future<WaitingConnect?> open(BandId id) async {
    if (openError != null) throw openError!;
    if (none) return null;
    opened++;
    final c = current = Completer<Headband>();
    return WaitingConnect(
      band: c.future,
      cancel: () async {
        closed++;
        if (!c.isCompleted) c.completeError(StateError('closed'));
      },
    );
  }

  bool get isOpen => opened > closed;
}

class _Rig {
  _Rig(this.async, {_Waits? waits, bool screenOn = false, bool noWaiting = false}) : waits = waits ?? _Waits() {
    screen = screenOn;
    ladder = ReconnectLadder(
      waits: recorderWaits,
      waitFor: noWaiting ? null : this.waits.open,
      screenOn: () async => screen,
      log: lines.add,
      clock: now,
    );
  }

  final FakeAsync async;
  final _Waits waits;
  final DateTime t0 = DateTime(2026, 11, 24, 12);
  final List<String> lines = [];
  final List<({Duration at, LadderStep step})> steps = [];
  final Completer<void> stop = Completer<void>();
  late final ReconnectLadder ladder;
  bool screen = false;
  bool ended = false;

  DateTime now() => t0.add(async.elapsed);

  /// The owner's loop: every step is a try that fails at once, until [stop] or a headband.
  void run() {
    ladder.begin(now());
    unawaited(() async {
      while (true) {
        final s = await ladder.next(id, stop: stop.future);
        if (s == null) break;
        steps.add((at: async.elapsed, step: s));
        if (s.band != null) break;
      }
      ended = true;
    }());
  }

  List<int> get seconds => [for (final s in steps) s.at.inSeconds];
}

void main() {
  test('the planning values are the named constants', () {
    expect(ladderWaitAfter, const Duration(minutes: 10));
    expect(ladderSafetyEvery, const Duration(minutes: 15));
    expect(ladderFallbackEvery, const Duration(minutes: 5));
    expect(ladderFallbackEveryScreenOn, const Duration(minutes: 2));
    const t = LadderTiming();
    expect([t.waitAfter, t.safetyEvery, t.fallbackEvery, t.fallbackEveryScreenOn], [
      ladderWaitAfter,
      ladderSafetyEvery,
      ladderFallbackEvery,
      ladderFallbackEveryScreenOn,
    ]);
  });

  test('stages A and B: the old waits, every third try a scan, the stage by the time away', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(minutes: 9, seconds: 50));
      // 2, 5, 10, 30 s, then every 60 s
      expect(r.seconds.take(7), [2, 7, 17, 47, 107, 167, 227]);
      expect([for (final s in r.steps.take(5)) s.step.stage], [
        LadderStage.mend,
        LadderStage.mend,
        LadderStage.mend,
        LadderStage.mend,
        LadderStage.look,
      ]);
      expect([for (final s in r.steps.take(6)) s.step.scanDue], [false, false, true, false, false, true]);
      expect(r.steps.first.step.by, 'quick try');
      expect(r.steps[4].step.by, 'minute try');
      expect(r.waits.opened, 0, reason: 'no waiting connect before stage C');
      r.stop.complete();
      async.flushMicrotasks();
      expect(r.ended, isTrue);
    });
  });

  test('stage C: the 60 s tries stop; one waiting connect, a safety try every 15 min, never a scan', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(minutes: 10, seconds: 50));
      final early = r.steps.length; // the last 60 s try began its wait before the 10 minutes were over
      expect(r.seconds.last, 647);
      expect(r.waits.opened, 1);
      expect(r.waits.isOpen, isTrue);
      expect(r.ladder.stage, LadderStage.wait);
      expect(r.lines.single, contains('a waiting connect is open'));
      async.elapse(const Duration(minutes: 14));
      expect(r.steps.length, early, reason: 'no try while the phone listens');
      async.elapse(const Duration(minutes: 1));
      expect(r.steps.length, early + 1);
      final safety = r.steps.last;
      expect(safety.at, const Duration(seconds: 647) + ladderSafetyEvery);
      expect(safety.step.by, 'safety try');
      expect(safety.step.stage, LadderStage.wait);
      expect(safety.step.scanDue, isFalse);
      // closed for the try, opened again after it failed
      expect(r.waits.closed, 1);
      expect(r.waits.opened, 2);
      async.elapse(const Duration(hours: 3));
      expect(r.steps.skip(early).every((s) => !s.step.scanDue && s.step.by == 'safety try'), isTrue);
      expect(r.steps.length, early + 1 + 12);
      expect(r.waits.opened - r.waits.closed, 1, reason: 'never two waiting connects');
      r.stop.complete();
      async.flushMicrotasks();
      expect(r.ended, isTrue);
      expect(r.waits.isOpen, isFalse, reason: 'Stop closes the waiting connect');
    });
  });

  test('the headband shows up on the waiting connect: no try, the road is in the log line', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(hours: 3, minutes: 12, seconds: 5));
      final band = _Band();
      r.waits.current!.complete(band);
      async.flushMicrotasks();
      expect(r.ended, isTrue);
      expect(r.steps.last.step.band, same(band));
      expect(r.steps.last.step.by, 'waiting connect');
      expect(r.ladder.backLine(r.steps.last.step.by), 'waited 3 h 12 min; back by: waiting connect');
      expect(band.disposed, isFalse);
      r.ladder.end();
      expect(r.ladder.active, isFalse);
      expect(r.ladder.tries, 0);
    });
  });

  for (final h in ReconnectHint.values) {
    test('hint "${h.label}": an immediate direct try in every stage', () {
      fakeAsync((async) {
        final r = _Rig(async)..run();
        // stage A, in the 30 s wait
        async.elapse(const Duration(seconds: 20));
        var before = r.steps.length;
        r.ladder.hint(h);
        async.flushMicrotasks();
        expect(r.steps.length, before + 1);
        expect(r.steps.last.at, const Duration(seconds: 20));
        expect(r.steps.last.step.by, h.label);
        expect(r.steps.last.step.scanDue, isFalse);
        expect(r.steps.last.step.stage, LadderStage.mend);
        // stage B
        async.elapse(const Duration(minutes: 5));
        before = r.steps.length;
        r.ladder.hint(h);
        async.flushMicrotasks();
        expect(r.steps.length, before + 1);
        expect(r.steps.last.step.by, h.label);
        expect(r.steps.last.step.stage, LadderStage.look);
        // stage C: the waiting connect is closed for the try and opened again after it
        async.elapse(const Duration(minutes: 20));
        expect(r.waits.isOpen, isTrue);
        before = r.steps.length;
        final opened = r.waits.opened, closed = r.waits.closed;
        r.ladder.hint(h);
        async.flushMicrotasks();
        expect(r.steps.length, before + 1);
        expect(r.steps.last.step.by, h.label);
        expect(r.steps.last.step.stage, LadderStage.wait);
        expect(r.waits.closed, closed + 1);
        expect(r.waits.opened, opened + 1);
        expect(r.waits.isOpen, isTrue);
        r.stop.complete();
        async.flushMicrotasks();
      });
    });
  }

  test('a hint while nothing is lost, or while a try is under way, does nothing', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ladder.hint(ReconnectHint.appOpened); // nothing lost
      r.ladder.begin(r.now());
      LadderStep? got;
      unawaited(r.ladder.next(id, stop: r.stop.future).then((s) => got = s));
      async.elapse(const Duration(seconds: 2));
      expect(got!.by, 'quick try', reason: 'the early hint was not kept');
      // the owner's try is under way now: unlock and "app opened" arrive together
      r.ladder.hint(ReconnectHint.unlocked);
      r.ladder.hint(ReconnectHint.appOpened);
      got = null;
      unawaited(r.ladder.next(id, stop: r.stop.future).then((s) => got = s));
      async.elapse(const Duration(seconds: 4));
      expect(got, isNull, reason: 'the second try waits its 5 s');
      async.elapse(const Duration(seconds: 1));
      expect(got!.by, 'quick try');
    });
  });

  test('Bluetooth off and on in stage C: the broken waiting connect falls back, the hint tries, then it is reopened', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(minutes: 12));
      expect(r.waits.opened, 1);
      final before = r.steps.length;
      // Bluetooth off: Android ends the waiting connect
      r.waits.current!.completeError(StateError('Bluetooth is off'));
      r.waits.openError = StateError('Bluetooth is off');
      async.flushMicrotasks();
      expect(r.lines.last, contains('the waiting connect failed'));
      expect(r.steps.length, before, reason: 'no try at once: the fallback wait runs');
      async.elapse(ladderFallbackEvery);
      expect(r.steps.length, before + 1);
      expect(r.steps.last.step.by, 'timed try');
      // Bluetooth on again
      r.waits.openError = null;
      async.elapse(const Duration(minutes: 1));
      r.ladder.hint(ReconnectHint.bluetoothOn);
      async.flushMicrotasks();
      expect(r.steps.last.step.by, 'Bluetooth on');
      expect(r.waits.opened, 2, reason: 'opened again after the try');
      expect(r.waits.isOpen, isTrue);
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('Bluetooth off and on while the waiting connect died without a word: the hint reopens it', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(minutes: 12));
      final before = r.steps.length;
      r.ladder.hint(ReconnectHint.bluetoothOn);
      async.flushMicrotasks();
      expect(r.steps.length, before + 1);
      expect(r.waits.closed, 1);
      expect(r.waits.opened, 2);
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('after an app restart: one direct try at once, then the stage by the time since the drop', () {
    fakeAsync((async) {
      final r = _Rig(async);
      // the new process learns the drop was 2 hours ago
      r.ladder.begin(r.now().subtract(const Duration(hours: 2)));
      r.ladder.hint(ReconnectHint.restarted);
      unawaited(() async {
        while (true) {
          final s = await r.ladder.next(id, stop: r.stop.future);
          if (s == null) break;
          r.steps.add((at: async.elapsed, step: s));
        }
      }());
      async.flushMicrotasks();
      expect(r.steps.single.step.by, 'app restart');
      expect(r.steps.single.at, Duration.zero);
      expect(r.steps.single.step.stage, LadderStage.wait);
      expect(r.waits.opened, 1, reason: 'the waiting connect is open again after the restart');
      async.elapse(ladderSafetyEvery);
      expect(r.steps.last.step.by, 'safety try');
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('fallback (no waiting connect: the SDK): a try every 5 min, every 2 min with the screen on, plus hints', () {
    fakeAsync((async) {
      final r = _Rig(async, noWaiting: true)..run();
      async.elapse(const Duration(minutes: 10, seconds: 50));
      final early = r.steps.length;
      expect(r.lines.single, contains('no waiting connect with this connection'));
      async.elapse(const Duration(minutes: 20));
      expect([for (final s in r.steps.skip(early)) s.at.inSeconds], [947, 1247, 1547, 1847]);
      expect(r.steps.skip(early).every((s) => s.step.by == 'timed try' && !s.step.scanDue), isTrue);
      // the screen comes on: every 2 min
      r.screen = true;
      var n = r.steps.length;
      async.elapse(const Duration(minutes: 10));
      expect(r.steps.length - n, 5);
      // and off again
      r.screen = false;
      async.elapse(const Duration(minutes: 5)); // the try under way since the last 2-minute step ends first
      n = r.steps.length;
      async.elapse(const Duration(minutes: 20));
      expect(r.steps.length - n, 4);
      // a hint still tries at once
      n = r.steps.length;
      r.ladder.hint(ReconnectHint.reconnectNow);
      async.flushMicrotasks();
      expect(r.steps.length, n + 1);
      expect(r.steps.last.step.by, 'Reconnect now');
      expect(r.waits.opened, 0);
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('fallback when the finder says "no waiting connect here" or opening it throws', () {
    fakeAsync((async) {
      final w = _Waits()..none = true;
      final r = _Rig(async, waits: w)..run();
      async.elapse(const Duration(minutes: 16));
      expect(r.steps.last.step.by, 'timed try');
      expect(w.opened, 0);
      r.stop.complete();
      async.flushMicrotasks();
    });
    fakeAsync((async) {
      final w = _Waits()..openError = StateError('no plugin');
      final r = _Rig(async, waits: w)..run();
      async.elapse(const Duration(minutes: 16));
      expect(r.steps.last.step.by, 'timed try');
      expect(r.lines.any((l) => l.contains('could not be opened')), isTrue);
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('a headband that shows up in the same moment as a hint is let go, not kept twice', () {
    fakeAsync((async) {
      final r = _Rig(async)..run();
      async.elapse(const Duration(minutes: 12));
      final c = r.waits.current!;
      r.ladder.hint(ReconnectHint.unlocked);
      final band = _Band();
      c.complete(band);
      async.flushMicrotasks();
      expect(r.steps.last.step.by, anyOf('phone unlocked', 'waiting connect'));
      if (r.steps.last.step.band == null) expect(band.disposed, isTrue);
      r.stop.complete();
      async.flushMicrotasks();
    });
  });

  test('the words for the time away', () {
    expect(awayText(const Duration(seconds: 45)), '45 s');
    expect(awayText(const Duration(minutes: 12, seconds: 30)), '12 min');
    expect(awayText(const Duration(hours: 3)), '3 h');
    expect(awayText(const Duration(hours: 3, minutes: 12)), '3 h 12 min');
  });
}
