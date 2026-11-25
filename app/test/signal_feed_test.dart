// The Signal view's one rule (DECISIONS 595): while a night records it reads the night recorder's stream, while a
// session holds the headband it reads that session's link, and only when nothing holds the headband does it connect
// (and read the contact) by itself. It never opens a second connection and never switches a recording headband into
// resistance mode. Also: both taps (the recorder's side and the sessions' link) and the recorder's file writer's tap.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/live_signal.dart' show LiveBatch;
import 'package:eeg_tracker/signal/live_tap.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:flutter_test/flutter_test.dart';

/// A headband that answers a contact check with fixed ohms and streams when told to; every call recorded.
class TapBand implements Headband {
  final List<String> calls = [];
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast(sync: true);
  final _range = StreamController<bool>.broadcast(sync: true);
  int _pack = 0;

  void send([int n = 25]) => _signal.add([for (var i = 0; i < n; i++) Sample.four(pack: _pack++ % 2048, o1: 1e-5, o2: 2e-5, t3: 0, t4: -1e-5)]);

  @override
  String get name => 'BrainBit';
  @override
  String get address => 'AA:BB';
  @override
  String get serial => '1';
  @override
  int? get rssi => -60;
  @override
  BandId get id => const BandId(name: 'BrainBit', address: 'AA:BB', family: 'leBrainBitBlack');
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;
  @override
  Future<void> startSignal() async => calls.add('startSignal');
  @override
  Future<void> stopSignal() async => calls.add('stopSignal');
  @override
  Future<void> startResist() async {
    calls.add('startResist');
    scheduleMicrotask(() => _resist.add({'O1': 8.2e5, 'O2': 1.9e6, 'T3': 3.1e6, 'T4': double.infinity}));
  }

  @override
  Future<void> stopResist() async => calls.add('stopResist');
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async => calls.add('disconnect');
}

class CountingFinder implements HeadbandFinder {
  CountingFinder(this.band);
  final Headband? band;
  int finds = 0;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    finds++;
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('no direct tries in these tests');
}

const _quick = LinkTiming(
  scanFor: Duration(milliseconds: 10),
  connectTimeout: Duration(milliseconds: 50),
  sdkTimeout: Duration(milliseconds: 200),
  contactFor: Duration(milliseconds: 5),
  settle: Duration.zero,
  reconnectWaits: [Duration(milliseconds: 5)],
  rescanFor: Duration(milliseconds: 10),
);

/// The phone, made of switches the test sets.
class FakePhone {
  bool night = false;
  Readiness? missing;
  final List<bool> leases = [];

  /// What the headband watcher was told (AutoWatch.kt), with the searches made by then.
  final List<(bool, int)> holds = [];
  final StreamController<Object> recorder = StreamController<Object>.broadcast(sync: true);
  late final TapBand band = TapBand();
  late final CountingFinder finder = CountingFinder(band);
  SignalDevice device = SignalDevice(montage: brainBitMontage());

  SignalPhone get phone => SignalPhone(
    nightRunning: () async => night,
    leaseNight: leases.add,
    fromRecorder: () => recorder.stream,
    device: () async => device,
    readiness: (_) async => missing,
    finderFor: (_) => finder,
    holdHeadband: (on) async => holds.add((on, finder.finds)),
    timing: _quick,
    tickEvery: const Duration(milliseconds: 10),
  );
}

Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) fail('not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Map<String, Object?> _tapMessage(int first, {int n = 25, String run = '2026-11-20-231200'}) => {
  'kind': signalTapKind,
  'run': run,
  'batches': [
    [first, DateTime(2026, 11, 20, 1).millisecondsSinceEpoch, [for (var i = 0; i < n; i++) (first + i) % 2048], [for (var i = 0; i < n * 4; i++) 1e-5], 4],
  ],
};

void main() {
  setUp(LiveTap.reset);

  test('the rule itself', () {
    expect(chooseFeed(nightRunning: true, sessionHolds: true), FeedKind.night);
    expect(chooseFeed(nightRunning: true, sessionHolds: false), FeedKind.night);
    expect(chooseFeed(nightRunning: false, sessionHolds: true), FeedKind.session);
    expect(chooseFeed(nightRunning: false, sessionHolds: false), FeedKind.own);
  });

  test('during a night: the night\'s stream and its start-of-night contact; no search, no resistance mode', () async {
    final p = FakePhone()..night = true;
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.kind, FeedKind.night);
    expect(p.leases, [true]);
    p.recorder.add(
      const RecorderStatus(
        phase: Phase.recording,
        nightStartMs: 1763590000000,
        contactOhms: {'O1': 8e5, 'O2': 9e5, 'T3': null, 'T4': 2e6},
      ).toMap(nowMs: 0),
    );
    p.recorder.add(_tapMessage(100));
    p.recorder.add(_tapMessage(125));
    expect(f.signal!.count, 50);
    expect(f.signal!.latest(0), closeTo(10, 1e-3)); // volts in, µV kept
    expect(f.stage, SignalStage.live);
    expect(f.ohms['O1'], 8e5);
    expect(f.ohmsFrom, ContactFrom.nightStart);
    expect(f.canMeasure, isFalse);
    await f.measureAgain(); // refused
    await Future<void>.delayed(const Duration(milliseconds: 100)); // ticks pass: still the night
    expect(f.kind, FeedKind.night);
    expect(p.finder.finds, 0);
    expect(p.band.calls, isEmpty);
    await f.setActive(false);
    expect(p.leases.last, isFalse);
    expect(p.recorder.hasListener, isFalse);
  });

  test('the DIY board\'s night: its channel names from the recorder\'s status, contact not measured', () async {
    final p = FakePhone()..night = true;
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    p.recorder.add(
      const RecorderStatus(
        phase: Phase.recording,
        board: BoardLive(names: ['O1', 'O2', 'Fz', 'Fp1'], mode: 'test', modeText: '', notEeg: true),
      ).toMap(nowMs: 0),
    );
    expect(f.montage.names, ['O1', 'O2', 'Fz', 'Fp1']);
    expect(f.device.measuresContact, isFalse);
    p.recorder.add(_tapMessage(0));
    expect(f.signal!.count, 25);
  });

  test('while a session holds the headband: its link\'s batches and contact; no second connection', () async {
    final p = FakePhone();
    final session = BandLink(finder: CountingFinder(p.band), timing: _quick, onBatch: (_, _) {});
    expect(await session.connect(), isTrue);
    expect(LiveTap.heldByOther(), isTrue);
    final ohms = await session.contact();
    expect(ohms['T4'], isNull); // off the head
    await session.startSignal();
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.kind, FeedKind.session);
    expect(f.ohms['O1'], 8.2e5);
    expect(f.ohmsFrom, ContactFrom.session);
    p.band.send();
    await Future<void>.delayed(Duration.zero); // the tap's stream delivers on the next turn
    expect(f.signal!.count, 25);
    expect(f.stage, SignalStage.live);
    expect(f.canMeasure, isFalse);
    // only the session's own calls reached the headband: one contact check, one stream start
    expect(p.band.calls.where((c) => c == 'startResist'), hasLength(1));
    expect(p.finder.finds, 0);
    // the session ends: the view connects by itself
    await session.close();
    await until(() => f.kind == FeedKind.own && f.stage == SignalStage.live || p.finder.finds > 0);
    expect(p.finder.finds, 1);
  });

  test('nothing holds the headband: the view connects, reads the contact once, then streams; measure again', () async {
    final p = FakePhone();
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.kind, FeedKind.own);
    expect(p.finder.finds, 1);
    expect(p.band.calls, ['startResist', 'stopResist', 'startSignal']);
    expect(f.ohms, {'O1': 8.2e5, 'O2': 1.9e6, 'T3': 3.1e6, 'T4': null});
    expect(f.ohmsFrom, ContactFrom.now);
    p.band.send();
    expect(f.stage, SignalStage.live);
    expect(f.canMeasure, isTrue);
    await f.measureAgain();
    expect(p.band.calls.sublist(3), ['stopSignal', 'startResist', 'stopResist', 'startSignal']);
    await f.setActive(false);
    expect(p.band.calls.last, 'disconnect');
    expect(LiveTap.heldByOther(), isFalse);
  });

  test('a night starts while the view holds the headband: it lets go at once and reads the night instead', () async {
    final p = FakePhone();
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.kind, FeedKind.own);
    p.night = true;
    await until(() => f.kind == FeedKind.night);
    expect(p.band.calls, contains('disconnect'));
    expect(p.leases, [true]);
    final calls = p.band.calls.length;
    p.recorder.add(_tapMessage(0));
    expect(f.signal!.count, 25);
    expect(p.band.calls.length, calls); // nothing more went to the headband
  });

  test('the headband watcher keeps off while the view holds the headband: told before the search, until it lets go', () async {
    // own connection: the watcher is told before the first search and again once the view let go
    final p = FakePhone();
    final f = SignalFeed(p.phone);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.kind, FeedKind.own);
    expect(p.holds, [(true, 0)]);
    await f.setActive(false);
    expect(p.holds, [(true, 0), (false, 1)]);

    // a night starts: the view lets go and reads the night, and the watcher is told the view holds nothing
    await f.setActive(true);
    p.night = true;
    await until(() => f.kind == FeedKind.night);
    expect(p.holds, [(true, 0), (false, 1), (true, 1), (false, 2)]);
    await f.setActive(false);
    expect(p.holds, hasLength(4), reason: 'reading the night holds nothing of its own');

    // a session holds the headband: the view reads along and tells the watcher nothing (the session is its own hold)
    final q = FakePhone();
    final session = BandLink(finder: CountingFinder(q.band), timing: _quick, onBatch: (_, _) {});
    expect(await session.connect(), isTrue);
    final g = SignalFeed(q.phone);
    addTearDown(g.dispose);
    await g.setActive(true);
    expect(g.kind, FeedKind.session);
    expect(q.holds, isEmpty);
    await g.setActive(false);
    await session.close();

    // nothing found: given back at once
    final none = FakePhone();
    final h = SignalFeed(
      SignalPhone(
        nightRunning: () async => false,
        leaseNight: (_) {},
        fromRecorder: () => const Stream.empty(),
        device: () async => SignalDevice(montage: brainBitMontage()),
        readiness: (_) async => null,
        finderFor: (_) => CountingFinder(null),
        holdHeadband: (on) async => none.holds.add((on, 0)),
        timing: _quick,
        tickEvery: const Duration(milliseconds: 10),
      ),
    );
    addTearDown(h.dispose);
    await h.setActive(true);
    expect(h.stage, SignalStage.notFound);
    expect(none.holds, [(true, 0), (false, 0)]);
  });

  test('not ready: Nearby devices, Bluetooth, Wi-Fi; nothing is searched', () async {
    for (final (missing, stage) in [
      (Readiness.nearby, SignalStage.noPermission),
      (Readiness.bluetooth, SignalStage.bluetoothOff),
      (Readiness.wifi, SignalStage.noWifi),
    ]) {
      final p = FakePhone()..missing = missing;
      final f = SignalFeed(p.phone);
      await f.setActive(true);
      expect(f.stage, stage);
      expect(p.finder.finds, 0);
      expect(p.holds, isEmpty, reason: 'nothing searched: the watcher is not kept off');
      f.dispose();
    }
  });

  test('no headband: not found, and the kept signal and pose survive a look away', () async {
    final p = FakePhone();
    final none = SignalPhone(
      nightRunning: () async => false,
      leaseNight: (_) {},
      fromRecorder: () => const Stream.empty(),
      device: () async => SignalDevice(montage: helmetPlan8(), measuresContact: false),
      readiness: (_) async => null,
      finderFor: (_) => CountingFinder(null),
      timing: _quick,
      tickEvery: const Duration(milliseconds: 10),
    );
    final f = SignalFeed(none);
    addTearDown(f.dispose);
    await f.setActive(true);
    expect(f.stage, SignalStage.notFound);
    expect(f.montage.count, 8);
    final s = f.signal;
    await f.setActive(false);
    await f.setActive(true);
    expect(f.signal, same(s));
    expect(p.finder.finds, 0);
  });

  group('the night tap, the recorder\'s side', () {
    test('sends only under a lease, gathered; the message decodes to µV batches with their numbers', () {
      var now = DateTime(2026, 11, 20, 1);
      final sent = <Object>[];
      final tap = NightTapSender(send: sent.add, clock: () => now);
      final batch = [for (var i = 0; i < 10; i++) Sample.four(pack: i, o1: 1e-5, o2: 0.0, t3: 0.0, t4: 0.0)];
      tap.add('run', 0, now, batch);
      tap.flush();
      expect(sent, isEmpty); // no lease
      tap.lease(on: true);
      tap.add('run', 0, now, batch);
      tap.add('run', 10, now, batch);
      expect(sent, isEmpty); // gathered until the flush
      tap.flush();
      expect(sent, hasLength(1));
      final got = nightTapBatches(sent.single)!;
      expect(got.map((b) => b.first), [0, 10]);
      expect(got.first.values[0], closeTo(10, 1e-6));
      expect(got.first.packs, Int32List.fromList([for (var i = 0; i < 10; i++) i]));
      expect(got.first.run, 'run');
      // a new run sends what the old one had first
      tap.add('run', 20, now, batch);
      tap.add('run2', 0, now, batch);
      expect(sent, hasLength(2));
      expect(nightTapBatches(sent[1])!.single.run, 'run');
      // the lease runs out without a renewal: what was held is dropped, nothing more is sent
      now = now.add(nightTapLease + const Duration(seconds: 1));
      tap.add('run2', 10, now, batch);
      tap.flush();
      expect(sent, hasLength(2));
      expect(tap.on, isFalse);
      // a screen that went away: the tap ends quietly
      final dead = NightTapSender(send: (_) => throw StateError('gone'))..lease(on: true);
      dead.add('r', 0, DateTime.now(), batch);
      expect(dead.flush, returnsNormally);
      expect(dead.on, isFalse);
    });

    test('the lease message both ways, and damaged batches skipped', () {
      expect(nightTapLeaseFrom(nightTapLeaseMessage(on: true)), (on: true, user: tapPanel));
      expect(nightTapLeaseFrom(nightTapLeaseMessage(on: false, user: tapRide)), (on: false, user: tapRide));
      expect(nightTapLeaseFrom({'kind': signalTapKind, 'on': true}), (on: true, user: tapPanel), reason: 'an older screen');
      expect(nightTapLeaseFrom('status'), isNull);
      expect(nightTapBatches({'kind': 'status'}), isNull);
      final got = nightTapBatches({
        'kind': signalTapKind,
        'batches': [
          [0, 1, [1, 2], [0.0, 0.0, 0.0], 4], // values do not fit
          ['x', 1, [1], [0, 0, 0, 0], 4],
          [5, 1, [1], [0, 0, 0, 1e-6], 0], // no width
          [5, 1, [1], [0, 0, 0, 1e-6]], // no width
          [5, 1, [1], [0, 0, 0, 1e-6], 4],
        ],
      })!;
      expect(got, hasLength(1));
      expect(got.single.values[3], closeTo(1, 1e-6));
    });

    test('an 8-channel board\'s batches cross as eight values a sample (DECISIONS 630-639)', () {
      final sent = <Object?>[];
      final tap = NightTapSender(send: sent.add)..lease(on: true);
      tap.add('run', 0, DateTime.now(), [for (var i = 0; i < 3; i++) Sample(i, [for (var c = 0; c < 8; c++) (c + 1) * 1e-6])]);
      tap.flush();
      final got = nightTapBatches(sent.single)!.single;
      expect(got.channels, 8);
      expect(got.length, 3);
      expect(got.values.sublist(8, 16), [for (var c = 0; c < 8; c++) closeTo(c + 1, 1e-4)]);
      final b = LiveBatch.fromSamples(DateTime.now(), [Sample(7, List.filled(16, 1e-6))]);
      expect(b.channels, 16);
      expect(b.values, everyElement(closeTo(1, 1e-4)));
    });
  });

  test('the file writer\'s tap gets every batch with its run and index, and one that throws costs nothing', () {
    final dir = Directory.systemTemp.createTempSync('signal_tap');
    addTearDown(() {
      ChunkWriter.onLive = null;
      dir.deleteSync(recursive: true);
    });
    final w = ChunkWriter.open(dir, DateTime(2026, 11, 20, 1));
    final seen = <(String, int, int)>[];
    ChunkWriter.onLive = (stem, first, _, samples) => seen.add((stem, first, samples.length));
    final batch = [for (var i = 0; i < 5; i++) Sample.four(pack: i, o1: 0.0, o2: 0.0, t3: 0.0, t4: 0.0)];
    w.addBatch(DateTime.now(), batch);
    w.addBatch(DateTime.now(), batch);
    expect(seen, [(w.stem, 0, 5), (w.stem, 5, 5)]);
    ChunkWriter.onLive = (_, _, _, _) => throw StateError('broken');
    w.addBatch(DateTime.now(), batch);
    expect(ChunkWriter.onLive, isNull);
    expect(w.samplesReceived, 15);
    w.close();
    expect(File('${dir.path}/${w.stem}.f32').lengthSync(), 15 * recordBytes);
  });
}
