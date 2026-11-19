// The shared headband link of the daytime sessions (lib/dream/band_link.dart) against a finder and headbands the
// test answers by hand: what happens to a headband that turns up after Stop or after a deadline, to a reconnect whose
// start fails, and to a search that never comes back (review 2026-11-19, findings 4, 7, 15).
import 'dart:async';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show Sample;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:flutter_test/flutter_test.dart';

/// A headband that streams only when told to ([send]) and records every SDK call made to it.
class HandBand implements Headband {
  HandBand(this.label);
  final String label;
  final List<String> calls = [];

  /// When set, [startSignal] waits for it (a start command the SDK is slow to answer).
  Completer<void>? startGate;

  /// When set, [startSignal] throws it (after the command may have taken effect: the band streams anyway).
  Object? startError;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast(sync: true);

  void send() => _signal.add([(pack: 0, o1: 0, o2: 0, t3: 0, t4: 0)]);
  void goOutOfRange() => _range.add(false);

  @override
  String get name => 'BrainBit $label';
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
  Future<void> startSignal() async {
    calls.add('startSignal');
    final gate = startGate;
    if (gate != null) await gate.future;
    final e = startError;
    if (e != null) throw e;
  }

  @override
  Future<void> stopSignal() async => calls.add('stopSignal');
  @override
  Future<void> startResist() async => calls.add('startResist');
  @override
  Future<void> stopResist() async => calls.add('stopResist');
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async => calls.add('disconnect');
}

/// Every search and direct try waits until the test answers it.
class HandFinder implements HeadbandFinder {
  final List<Completer<Headband?>> finds = [];
  final List<void Function(String name, int rssi)?> founds = [];
  final List<Completer<Headband>> directs = [];

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) {
    final c = Completer<Headband?>();
    finds.add(c);
    founds.add(onFound);
    return c.future;
  }

  @override
  Future<Headband> connectDirect(BandId id) {
    final c = Completer<Headband>();
    directs.add(c);
    return c.future;
  }
}

const quick = LinkTiming(
  scanFor: Duration(milliseconds: 20),
  connectTimeout: Duration(milliseconds: 30),
  sdkTimeout: Duration(milliseconds: 40),
  contactFor: Duration(milliseconds: 1),
  settle: Duration.zero,
  reconnectWaits: [Duration(milliseconds: 5)],
  rescanFor: Duration(milliseconds: 10),
);

Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 5)}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) fail('not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  late HandFinder finder;
  late List<String> events;
  late List<String> batches;
  late BandLink link;

  BandLink linkOf(HandFinder f, {LinkTiming timing = quick}) => BandLink(
    finder: f,
    timing: timing,
    onBatch: (_, b) => batches.add('batch'),
    onEvent: (e, line) => events.add(e.name),
  );

  /// The link connected to [first] and streaming.
  Future<void> streaming(HandBand first) async {
    final connected = link.connect();
    await until(() => finder.finds.isNotEmpty);
    finder.finds.first.complete(first);
    expect(await connected, isTrue);
    await link.startSignal();
  }

  setUp(() {
    BandLink.forgetAbandoned();
    finder = HandFinder();
    events = [];
    batches = [];
    link = linkOf(finder);
  });
  tearDown(BandLink.forgetAbandoned);

  group('a headband reached after Stop or after a deadline is let go (finding 4)', () {
    test('Stop during a direct reconnect try: the headband it reaches afterwards is disconnected', () async {
      final first = HandBand('A'), second = HandBand('B');
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 1);
      await link.close(); // Stop while the try runs
      finder.directs[0].complete(second); // the try connects after Stop
      await settle();
      expect(second.calls, contains('disconnect'));
      expect(first.calls, isNot(contains('disconnect')), reason: 'a lost headband is never touched');
      expect(events, isNot(contains('reconnected')));
    });

    test('Stop while a reconnected headband starts its stream: it is stopped and disconnected', () async {
      final first = HandBand('A'), second = HandBand('B')..startGate = Completer<void>();
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 1);
      finder.directs[0].complete(second);
      await until(() => second.calls.contains('startSignal'));
      await link.close();
      second.startGate!.complete();
      await settle();
      expect(second.calls, containsAllInOrder(['startSignal', 'stopSignal', 'disconnect']));
      expect(events, isNot(contains('reconnected')));
    });

    test('a search that answers after the connect deadline: its headband is disconnected', () async {
      final late = HandBand('late');
      await expectLater(link.connect(), throwsA(isA<TimeoutException>()));
      finder.finds[0].complete(late);
      await settle();
      expect(late.calls, contains('disconnect'));
    });

    test('a direct reconnect try that answers after its deadline: that headband is disconnected', () async {
      final first = HandBand('A'), late = HandBand('late'), good = HandBand('C');
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 2); // the first try timed out, the second is under way
      finder.directs[1].complete(good);
      await until(() => events.contains('reconnected'));
      finder.directs[0].complete(late);
      await settle();
      expect(late.calls, ['disconnect']);
      expect(good.calls, isNot(contains('disconnect')));
      await link.close();
    });
  });

  group('a reconnect whose start fails (finding 7)', () {
    test('that headband is let go and its batches never reach the session', () async {
      final first = HandBand('A'), failed = HandBand('B')..startError = StateError('start refused'), good = HandBand('C');
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 1);
      finder.directs[0].complete(failed);
      await until(() => finder.directs.length == 2);
      expect(failed.calls, containsAllInOrder(['startSignal', 'stopSignal', 'disconnect']));
      finder.directs[1].complete(good);
      await until(() => events.contains('reconnected'));
      batches.clear();
      failed.send(); // the start took effect after all: its stream runs
      good.send();
      expect(batches, hasLength(1), reason: 'only the reconnected headband feeds the session');
      await link.close();
      expect(good.calls, containsAllInOrder(['stopSignal', 'disconnect']));
    });

    test('a start that times out: the same, and the next try reconnects', () async {
      final first = HandBand('A'), slow = HandBand('B')..startGate = Completer<void>(), good = HandBand('C');
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 1);
      finder.directs[0].complete(slow);
      await until(() => finder.directs.length == 2); // past the start's deadline
      expect(slow.calls, containsAllInOrder(['startSignal', 'stopSignal', 'disconnect']));
      finder.directs[1].complete(good);
      await until(() => events.contains('reconnected'));
      batches.clear();
      slow.send();
      expect(batches, isEmpty);
      await link.close();
    });

    test('a headband that drops while its stream starts is left alone and not taken as reconnected', () async {
      final first = HandBand('A'), shaky = HandBand('B')..startGate = Completer<void>(), good = HandBand('C');
      await streaming(first);
      first.goOutOfRange();
      await until(() => finder.directs.length == 1);
      finder.directs[0].complete(shaky);
      await until(() => shaky.calls.contains('startSignal'));
      shaky.goOutOfRange();
      shaky.startGate!.complete();
      await until(() => finder.directs.length == 2);
      expect(events, isNot(contains('reconnected')));
      expect(shaky.calls, ['startSignal'], reason: 'no SDK call goes near a headband out of range');
      expect(link.leftLost, isTrue);
      finder.directs[1].complete(good);
      await until(() => events.contains('reconnected'));
      await link.close();
    });
  });

  group('a search that never comes back (finding 15)', () {
    test('the next search that misses its deadline says the app must be opened again', () async {
      await expectLater(link.connect(), throwsA(isA<TimeoutException>()));
      final next = linkOf(finder); // the next session, another screen: the same process
      await expectLater(
        next.connect(),
        throwsA(isA<LinkStuck>().having((e) => e.toString(), 'words', contains('Close the app'))),
      );
    });

    test('once the stuck search comes back, a missed deadline is a plain timeout again', () async {
      await expectLater(link.connect(), throwsA(isA<TimeoutException>()));
      finder.finds[0].complete(null);
      await settle();
      await expectLater(linkOf(finder).connect(), throwsA(isA<TimeoutException>()));
    });

    test('a connect that finds the headband in time is never called stuck', () async {
      await expectLater(link.connect(), throwsA(isA<TimeoutException>()));
      final next = linkOf(finder), band = HandBand('A');
      final connected = next.connect();
      await until(() => finder.finds.length == 2);
      finder.finds[1].complete(band);
      expect(await connected, isTrue);
      await next.close();
    });
  });

  test('a search that finds the headband after Stop: let go, no "found" for the screen', () async {
    final band = HandBand('A');
    final found = <String>[];
    final connected = link.connect(onFound: found.add);
    await until(() => finder.finds.isNotEmpty);
    await link.close();
    finder.founds[0]?.call(band.name, -60); // the scan saw it after Stop
    finder.finds[0].complete(band);
    expect(await connected, isFalse);
    expect(band.calls, contains('disconnect'));
    expect(found, isEmpty);
  });
}
