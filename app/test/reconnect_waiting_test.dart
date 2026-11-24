// The waiting connect of our own connection (DECISIONS 940) on a fake Bluetooth transport, and the reconnect ladder
// inside the night recorder (lib/recorder/night_recorder.dart) with tiny times: stage C opens one waiting connect, the
// headband shows up on it and the night goes on; the fallback where the connection has none; hints; a restart; the
// log's "back by". The ladder's own rules run on a fake clock in reconnect_ladder_test.dart.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/headband/own/own_headband.dart';
import 'package:eeg_tracker/headband/own/settings.dart';
import 'package:eeg_tracker/headband/own/universal_transport.dart' show linkTimingLine;
import 'package:eeg_tracker/headband/reconnect_ladder.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder;
import 'own_ble/fake_headband.dart';

const _ms = Duration(milliseconds: 1);
const BandId fakeId = BandId(name: 'BB Black', address: fakeAddress, family: 'own');

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 8), String what = ''}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting $what');
    await Future<void>.delayed(_ms * 5);
  }
}

OwnFinder ownFinder(FakeHeadband hb) => OwnFinder(
  transport: hb,
  settings: const OwnBleSettings(address: fakeAddress, name: 'BB Black'),
  timing: OwnTiming(
    callTimeout: _ms * 300,
    healFor: _ms * 60,
    stall: _ms * 150,
    backoffs: [_ms * 10],
    contactFor: _ms * 30,
    poll: _ms * 5,
    stopWait: _ms * 20,
  ),
);

/// A finder like BrainBit's SDK: no waiting connect. Direct tries find the headband once [back] is set.
class _PlainFinder extends FakeFinder {
  _PlainFinder(super.bands);
  FakeBand? back;

  @override
  Future<Headband> connectDirect(BandId id) async {
    final b = back;
    if (b != null) {
      back = null;
      direct.add(b);
    }
    return super.connectDirect(id);
  }
}

/// The same with a waiting connect a test completes by hand.
class _WaitingFinder extends _PlainFinder implements WaitingFinder {
  _WaitingFinder(super.bands);
  int opened = 0, closed = 0;
  Completer<Headband>? current;

  @override
  Future<WaitingConnect?> waitFor(BandId id) async {
    opened++;
    final c = current = Completer<Headband>();
    c.future.ignore();
    return WaitingConnect(
      band: c.future,
      cancel: () async {
        closed++;
        if (!c.isCompleted) c.completeError(StateError('closed'));
      },
    );
  }
}

const fast = RecorderTiming(
  tick: Duration(milliseconds: 10),
  ticksPerCheck: 5,
  scanFor: Duration(milliseconds: 20),
  contactFor: Duration(milliseconds: 20),
  settle: Duration(milliseconds: 5),
  retryWait: Duration(milliseconds: 5),
  sdkTimeout: Duration(milliseconds: 300),
  connectTimeout: Duration(milliseconds: 300),
  notFoundWait: Duration(milliseconds: 10),
  notFoundWaitLong: Duration(milliseconds: 10),
  stallChecksToGiveUp: 3,
  stopTimeout: Duration(seconds: 2),
  reconnectWaits: [Duration(milliseconds: 5), Duration(milliseconds: 10), Duration(milliseconds: 20)],
  scanEvery: 1000, // no scans here: the plain finder's scan would hand out nothing anyway
  rescanFor: Duration(milliseconds: 20),
  // stage C after 150 ms; a safety try every 250 ms; the fallback every 200 ms, 80 ms with the screen on
  ladder: LadderTiming(
    mendFor: Duration(milliseconds: 40),
    waitAfter: Duration(milliseconds: 150),
    safetyEvery: Duration(milliseconds: 250),
    fallbackEvery: Duration(milliseconds: 200),
    fallbackEveryScreenOn: Duration(milliseconds: 80),
  ),
);

void main() {
  group('our own connection', () {
    test('a waiting connect gives the headband when it shows up, and the signal runs', () async {
      final hb = FakeHeadband(dropFor: _ms * 150)..linkFacts = ['link timing: interval 15 ms, latency 0, timeout 5.0 s'];
      hb.awayUntil = DateTime.now().add(_ms * 150);
      final finder = ownFinder(hb);
      final w = (await finder.waitFor(fakeId))!;
      expect(hb.waitingOpen, 1);
      expect(hb.connects, 0);
      final band = await w.band.timeout(const Duration(seconds: 3));
      expect(hb.waitingOpen, 0);
      expect(hb.connects, 1);
      expect(band, isA<OwnHeadband>());
      final notes = <String>[];
      (band as OwnHeadband).notes.listen((n) {
        if (n.line != null) notes.add(n.line!);
      });
      var got = 0;
      band.signal.listen((b) => got += b.length);
      await band.startSignal();
      await waitFor(() => got > 50, what: 'for samples');
      // the link's real timing is in the log, once
      expect(notes.where((n) => n.startsWith('link timing:')), ['link timing: interval 15 ms, latency 0, timeout 5.0 s']);
      await band.disconnectAndDispose();
    });

    test('closing a waiting connect leaves nothing open; a direct try can follow at once', () async {
      final hb = FakeHeadband()..awayUntil = DateTime.now().add(const Duration(seconds: 30));
      final finder = ownFinder(hb);
      final w = (await finder.waitFor(fakeId))!;
      Object? error;
      unawaited(w.band.then<void>((_) {}, onError: (Object e) => error = e));
      await Future<void>.delayed(_ms * 50);
      expect(hb.waitingOpen, 1);
      await w.cancel();
      await Future<void>.delayed(_ms * 10);
      expect(hb.waitingOpen, 0);
      expect(hb.waitingClosed, 1);
      expect(error, isNotNull);
      // the headband is back: the direct try is not held up by the closed waiting connect
      hb.awayUntil = DateTime.fromMillisecondsSinceEpoch(0);
      final t0 = DateTime.now();
      final band = await finder.connectDirect(fakeId);
      expect(DateTime.now().difference(t0), lessThan(const Duration(seconds: 1)));
      await band.disconnectAndDispose();
    });

    test('a new headband object waits for an open waiting connect to be closed (never two things open)', () async {
      final hb = FakeHeadband()..awayUntil = DateTime.now().add(const Duration(seconds: 30));
      final finder = ownFinder(hb);
      final w = (await finder.waitFor(fakeId))!;
      w.band.ignore();
      var done = false;
      final direct = finder.connectDirect(fakeId).then<Object?>((b) => b, onError: (Object e) => e).whenComplete(() => done = true);
      await Future<void>.delayed(_ms * 80);
      expect(done, isFalse, reason: 'the direct try waits while the waiting connect is open');
      await w.cancel();
      final r = await direct;
      expect(r, isNot(isA<Headband>())); // the headband is still away: the try fails, but it ran
    });

    test('Bluetooth off ends the waiting connect with an error', () async {
      final hb = FakeHeadband()..awayUntil = DateTime.now().add(const Duration(seconds: 30));
      final w = (await ownFinder(hb).waitFor(fakeId))!;
      hb.bluetoothOff = true;
      await expectLater(w.band.timeout(const Duration(seconds: 2)), throwsA(anything));
      expect(hb.waitingOpen, 0);
    });

    test('a transport without a waiting connect: the finder says so', () async {
      final hb = FakeHeadband()..hasWaiting = false;
      expect(await ownFinder(hb).waitFor(fakeId), isNull);
    });

    test('the timing line', () {
      expect(
        linkTimingLine(intervalMs: 15, latency: 0, timeoutMs: 5000),
        'link timing: interval 15 ms, latency 0, timeout 5.0 s',
      );
      expect(
        linkTimingLine(intervalMs: 48.75, latency: 2, timeoutMs: 720),
        'link timing: interval 48.75 ms, latency 2, timeout 0.7 s',
      );
    });
  });

  group('the night recorder on the ladder', () {
    late Directory dir;
    late MemoryNightStore store;
    late List<RecorderStatus> statuses;
    var screen = false;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('reconnect_ladder_test');
      store = MemoryNightStore();
      statuses = [];
      screen = false;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    NightRecorder recorder(HeadbandFinder finder) => NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: fast,
      watch: null,
      screenOn: () async => screen,
    );

    String logs() {
      final fs = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return fs.map((f) => f.readAsStringSync()).join('\n');
    }

    int tries(String log) => RegExp(r'reconnect try \d+ \(direct').allMatches(log).length;

    test('stage C: the tries stop, one waiting connect is open, and the headband comes back on it', () async {
      final first = FakeBand('a');
      final finder = _WaitingFinder([first]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: false);
      await Future<void>.delayed(_ms * 150);
      first.goOutOfRange();
      await waitFor(() => finder.opened == 1, what: 'for the waiting connect');
      expect(r.ladderStage, LadderStage.wait);
      expect(store.state.lostAtMs, greaterThan(0), reason: 'the time of the drop is kept with the night');
      final before = tries(logs());
      await Future<void>.delayed(_ms * 150);
      expect(tries(logs()), before, reason: 'no try while the phone listens');
      expect(statuses.last.note, contains('waiting for it'));
      final again = FakeBand('a again', rssi: null);
      finder.current!.complete(again);
      await waitFor(() => again.emitted > 20, what: 'for the new run');
      await r.stop();
      await running;

      final log = logs();
      expect(log, contains('the 60 s tries stop; a waiting connect is open'));
      expect(log, contains('the headband showed up on the waiting connect'));
      expect(
        log,
        matches(RegExp(r'reconnected \(waiting connect, try \d+\) after a drop \(out of range\); .*; waited \d+ s; back by: waiting connect')),
      );
      expect([finder.opened, finder.closed], [1, 0], reason: 'one waiting connect, and it became the connection');
      expect(again.calls, contains('startSignal'));
      expect(store.state.lostAtMs, 0, reason: 'data came: the next drop starts the ladder anew');
      expect(r.ladderStage, isNull);
    });

    test('stage C: a safety try closes the waiting connect, tries once, and opens it again', () async {
      final first = FakeBand('a');
      final finder = _WaitingFinder([first]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: false);
      await Future<void>.delayed(_ms * 150);
      first.goOutOfRange();
      await waitFor(() => finder.opened == 2, what: 'for the second waiting connect');
      expect(finder.closed, 1);
      expect(logs(), contains(RegExp(r'reconnect try \d+ \(direct to AA:BB, safety try\): failed')));
      // the headband is back: the next safety try finds it
      finder.back = FakeBand('a again', rssi: null);
      await waitFor(() => logs().contains('back by: safety try'), what: 'for the safety try to connect');
      await r.stop();
      await running;
      expect(logs(), contains(RegExp(r'reconnected \(direct, try \d+\) after a drop')));
      expect(finder.opened - finder.closed, 0, reason: 'closed before the try that connected');
    });

    test('the fallback (no waiting connect): one try per fallback time, more often with the screen on; hints', () async {
      final first = FakeBand('a');
      final finder = _PlainFinder([first]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: false);
      await Future<void>.delayed(_ms * 150);
      first.goOutOfRange();
      await waitFor(() => logs().contains('no waiting connect with this connection'), what: 'for stage C');
      final t0 = DateTime.now();
      final n0 = tries(logs());
      await waitFor(() => tries(logs()) == n0 + 1, what: 'for a timed try');
      expect(DateTime.now().difference(t0), greaterThan(_ms * 150), reason: 'screen off: the long wait');
      expect(logs(), contains(RegExp(r'reconnect try \d+ \(direct to AA:BB, timed try\): failed')));
      // the screen is on: the short wait
      screen = true;
      await waitFor(() => tries(logs()) == n0 + 2, what: 'for the try under way');
      final t1 = DateTime.now();
      await waitFor(() => tries(logs()) == n0 + 3, what: 'for a screen-on try');
      expect(DateTime.now().difference(t1), lessThan(_ms * 180));
      screen = false;
      // "Reconnect now": at once, and the headband is back
      await waitFor(() => tries(logs()) == n0 + 4, what: 'for the next try');
      await Future<void>.delayed(_ms * 20);
      final again = FakeBand('a again', rssi: null);
      finder.back = again;
      final t2 = DateTime.now();
      r.hint(ReconnectHint.reconnectNow);
      await waitFor(() => again.emitted > 0, what: 'for the headband after the hint');
      expect(DateTime.now().difference(t2), lessThan(_ms * 150));
      await r.stop();
      await running;
      final log = logs();
      expect(log, contains(RegExp(r'reconnect try \d+ \(direct to AA:BB, Reconnect now\): connected')));
      expect(log, contains('back by: Reconnect now'));
    });

    test('a hint while the headband is there does nothing', () async {
      final band = FakeBand('a');
      final finder = _PlainFinder([band]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: false);
      await Future<void>.delayed(_ms * 100);
      for (final h in ReconnectHint.values) {
        r.hint(h);
      }
      await Future<void>.delayed(_ms * 100);
      await r.stop();
      await running;
      expect(finder.calls, ['scan']);
      expect(logs(), isNot(contains('reconnect try')));
    });

    test('a process restarted hours after the drop: one try at once, then the waiting connect again', () async {
      final lostAt = DateTime.now().subtract(const Duration(hours: 2, minutes: 5));
      store.state = NightState(
        active: true,
        startMs: lostAt.millisecondsSinceEpoch - 3600000,
        samples: 2500,
        runs: 1,
        contactTried: true,
        band: const BandId(name: 'BrainBit a', address: 'AA:BB', serial: '123', family: 'leBrainBitBlack', model: 1),
        lostAtMs: lostAt.millisecondsSinceEpoch,
      );
      final finder = _WaitingFinder([]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: true);
      await waitFor(() => finder.opened == 1, what: 'for the waiting connect after the restart');
      expect(finder.calls, ['direct AA:BB'], reason: 'one direct try first');
      expect(r.ladderStage, LadderStage.wait);
      final again = FakeBand('a again', rssi: null);
      finder.current!.complete(again);
      await waitFor(() => again.emitted > 20, what: 'for the new run');
      await r.stop();
      await running;
      expect(logs(), contains('waited 2 h 5 min; back by: waiting connect'));
    });

    test('Stop while waiting closes the waiting connect', () async {
      final first = FakeBand('a');
      final finder = _WaitingFinder([first]);
      final r = recorder(finder);
      final running = r.run(restartedBySystem: false);
      await Future<void>.delayed(_ms * 150);
      first.goOutOfRange();
      await waitFor(() => finder.opened == 1, what: 'for the waiting connect');
      await r.stop();
      await running.timeout(const Duration(seconds: 3));
      expect(finder.closed, 1);
    });
  });
}
