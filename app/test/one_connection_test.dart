// One headband connection for every screen (lib/headband/connection.dart, lend.dart; DECISIONS 855-856): what did NOT
// happen is the point. The fake headband counts every call: a start on a connection that is already live makes no
// second search, no second connection and no second contact check, whether the starter is a session in the screen's
// engine or the night recorder in its own.
import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/headband/connection.dart';
import 'package:eeg_tracker/headband/device_status.dart';
import 'package:eeg_tracker/headband/lend.dart';
import 'package:eeg_tracker/recorder/header.dart' show recordsIn;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/signal/layout.dart';
import 'package:eeg_tracker/signal/live_tap.dart';
import 'package:eeg_tracker/signal/quality.dart';
import 'package:eeg_tracker/signal/signal_feed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/band_fakes.dart';

const _quick = LinkTiming(
  scanFor: Duration(milliseconds: 10),
  connectTimeout: Duration(milliseconds: 200),
  sdkTimeout: Duration(milliseconds: 300),
  contactFor: Duration(milliseconds: 20),
  settle: Duration.zero,
  reconnectWaits: [Duration(milliseconds: 5)],
  rescanFor: Duration(milliseconds: 10),
);

const _fast = RecorderTiming(
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
  scanEvery: 3,
  rescanFor: Duration(milliseconds: 20),
);

Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 6), String what = 'the state'}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) fail('$what not reached in $limit');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// One link as a screen makes it: connect, the contact check, the stream.
Future<({BandLink link, List<int> got, Map<String, double?> ohms})> startLink(HeadbandConnection owner) async {
  final got = <int>[];
  final link = BandLink(finder: owner.finder, timing: _quick, onBatch: (_, b) => got.add(b.length));
  expect(await link.connect(), isTrue);
  final ohms = await link.contact();
  await link.startSignal();
  return (link: link, got: got, ohms: ohms);
}

/// The screen's engine and the recorder's, joined as the app joins them (messages both ways).
class World {
  World({Duration linger = const Duration(seconds: 30), List<Headband>? nightBands}) {
    nightFinder = CountingFinder(nightBands ?? []);
    owner = HeadbandConnection(
      makeFinder: () => real,
      disposeFinder: (_, {required anyLost}) => real.disposed++,
      linger: linger,
      tickEvery: const Duration(milliseconds: 20),
      sendToNight: (m) {
        if (screenAlive) lend?.onMessage(m);
      },
    );
  }

  final CountingBand band = CountingBand();
  late final CountingFinder real = CountingFinder([band]);
  late final CountingFinder nightFinder;
  late final HeadbandConnection owner;
  LendFinder? lend;
  NightRecorder? recorder;
  bool nightOn = false;

  /// False plays the screen's engine going away: nothing crosses any more, either way.
  bool screenAlive = true;
  final List<RecorderStatus> statuses = [];
  final MemoryNightStore store = MemoryNightStore();
  late final Directory dir = Directory.systemTemp.createTempSync('one-connection');

  SignalFeed feed() => SignalFeed(
    SignalPhone(
      nightRunning: () async => nightOn,
      leaseNight: (_) {},
      fromRecorder: () => const Stream<Object>.empty(),
      device: () async => SignalDevice(montage: brainBitMontage()),
      readiness: (_) async => null,
      finderFor: (_) => owner.finder,
      timing: _quick,
      tickEvery: const Duration(milliseconds: 10),
    ),
  );

  /// Start sleep, as recorder_service.dart does it: the offer, then the recorder over the lend finder.
  Future<LendOffer?> startNight({Duration takeWait = const Duration(milliseconds: 100), void Function()? afterOffer}) async {
    final made = await owner.lendToNight();
    afterOffer?.call();
    // the offer crosses as saved JSON
    final offer = made == null ? null : LendOffer.fromJson(made.toJson());
    nightOn = true;
    final finder = lend = LendFinder(
      inner: nightFinder,
      toScreen: (m) {
        if (screenAlive) owner.recorderData(m);
      },
      offer: offer,
      takeWait: takeWait,
    );
    final r = recorder = NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: (s) {
        statuses.add(s);
        if (screenAlive) owner.recorderData(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));
      },
      onStuck: (_) async {},
      timing: _fast,
      watch: null,
    );
    unawaited(r.run(restartedBySystem: false));
    return offer;
  }

  bool get recording => statuses.isNotEmpty && statuses.last.phase == Phase.recording && statuses.last.nightSamples > 0;

  String log() => dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).map((f) => f.readAsStringSync()).join();

  Future<void> close() async {
    await recorder?.stop();
    await owner.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  setUp(() {
    LiveTap.reset();
    BandLink.forgetAbandoned();
  });

  test('two screens, one connection: the second start makes no search, no connection and no contact check', () async {
    final w = World();
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => a.got.isNotEmpty && w.owner.live);
    expect(a.ohms['O1'], 1e5);

    final b = await startLink(w.owner);
    await until(() => b.got.isNotEmpty);
    expect(w.real.scans, 1, reason: 'the second start searched again');
    expect(w.real.directs, 0);
    expect(w.band.count('startResist'), 1, reason: 'the contact was measured again');
    expect(w.band.count('startSignal'), 1, reason: 'the stream was started again');
    expect(b.ohms, a.ohms, reason: 'the reading in force comes along');

    // the first lets go: the second goes on, nothing is disconnected
    await a.link.close();
    final n = b.got.length;
    await until(() => b.got.length > n + 3);
    expect(w.band.count('disconnect'), 0);
    expect(w.band.count('stopSignal'), 0);
    await b.link.close();
  });

  test('the connection is kept after the last user, reused by the next start, and let go after the wait', () async {
    final w = World(linger: const Duration(milliseconds: 300));
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close();
    expect(w.band.count('disconnect'), 0, reason: 'kept for the next start');
    expect(w.owner.status.value.lingering, isTrue);
    expect(w.owner.status.value.link, anyOf(LinkState.live, LinkState.waiting));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    final b = await startLink(w.owner);
    await until(() => b.got.isNotEmpty);
    expect(w.real.scans, 1);
    expect(w.band.count('startResist'), 1);
    expect(w.band.count('startSignal'), 1);
    await b.link.close();

    await until(() => w.band.count('disconnect') == 1, what: 'let go after the wait');
    expect(w.band.count('stopSignal'), 1);
    expect(w.real.disposed, 1, reason: 'the finder goes with the connection');
    expect(w.owner.status.value.link, LinkState.off);
  });

  test('Measure again is a real check: the stream pauses for it and comes back', () async {
    final w = World();
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    final again = await a.link.measureAgain();
    expect(again?['T4'], 1.5e6);
    expect(w.band.count('startResist'), 2);
    expect(w.band.count('stopSignal'), 1);
    final n = a.got.length;
    await until(() => a.got.length > n + 3, what: 'the stream after the check');
    await a.link.close();
  });

  test('a drop reaches every user; their reconnects share one new connection', () async {
    final w = World();
    addTearDown(w.close);
    final second = CountingBand(label: 'B');
    w.real.bands.add(second);
    final a = await startLink(w.owner);
    final b = await startLink(w.owner);
    await until(() => a.got.isNotEmpty && b.got.isNotEmpty);
    final before = w.band.calls.length;
    w.band.goOutOfRange();
    await until(() => !a.link.lost && !b.link.lost && second.emitted > 0, what: 'both reconnected');
    expect(w.band.calls.length, before, reason: 'an SDK call went to the lost headband');
    expect(w.real.directs + w.real.scans - 1, 1, reason: 'one new connection for both');
    expect(second.count('startSignal'), 1);
    await a.link.close();
    await b.link.close();
  });

  test('Signal, then Start sleep: the night records the live connection (no scan, no reconnect, no contact check)', () async {
    final w = World();
    addTearDown(w.close);
    final feed = w.feed();
    addTearDown(feed.dispose);
    await feed.setActive(true);
    await until(() => feed.stage == SignalStage.live && w.owner.live, what: 'Signal live');
    expect(w.real.scans, 1);
    expect(w.band.count('startResist'), 1);

    final offer = await w.startNight();
    expect(offer, isNotNull, reason: 'a live connection is lent');
    await until(() => w.recording, what: 'the night recording');
    // the Signal view gives way to the night (it reads the night from here on) without touching the headband
    await until(() => feed.kind == FeedKind.night, what: 'the Signal view reading the night');

    expect(w.real.scans, 1, reason: 'the night searched again');
    expect(w.real.directs, 0, reason: 'the night connected again');
    expect(w.nightFinder.calls, isEmpty, reason: 'the recorder reached for a headband of its own');
    expect(w.band.count('startResist'), 1, reason: 'the contact was checked again');
    expect(w.band.count('startSignal'), 1, reason: 'the stream was started again');
    expect(w.band.count('stopSignal'), 0);
    expect(w.band.count('disconnect'), 0);

    // the contact reading came along with its time, and the night says so
    expect(w.statuses.last.contactOhms['O1'], 1e5);
    expect(w.statuses.last.contactOhms['T4'], 1.5e6);
    expect(w.statuses.last.contactAtMs, offer!.ohmsAtMs);
    expect(w.log(), contains('not measured again'));
    expect(w.owner.status.value.use, BandUse.night);

    // the samples are the headband's own, numbers and all
    await until(() => w.statuses.last.nightSamples >= 300 && w.statuses.last.quality != null, what: 'a judged second');
    expect(w.statuses.last.quality, isNotNull, reason: "the recorder's judge sees the lent signal");

    // Stop: the files close, the connection stays with the screen for the next start
    await w.recorder!.stop();
    final f32 = w.dir.listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).single;
    expect(recordsIn(f32), greaterThanOrEqualTo(100));
    expect(w.band.count('disconnect'), 0, reason: 'Stop took the connection away from the screen');
    expect(w.owner.lending, isFalse);
  });

  test("the recorder's first answer (nothing started yet) reaches the screen before its start: the lend holds", () async {
    // the emulator's Signal -> Sleep of 2026-11-25 01:21: the screen asked the new service for its status, the
    // recorder answered with the status it is born with (idle), the owner took that for "the night is over" and
    // withdrew the lend; the recorder's start then got "lost" and it had to connect by itself
    final w = World();
    addTearDown(w.close);
    final feed = w.feed();
    addTearDown(feed.dispose);
    await feed.setActive(true);
    await until(() => feed.stage == SignalStage.live && w.owner.live, what: 'Signal live');
    final offer = await w.startNight(
      afterOffer: () => w.owner.recorderData(const RecorderStatus().toMap(nowMs: DateTime.now().millisecondsSinceEpoch)),
    );
    expect(offer, isNotNull);
    expect(w.owner.lending, isTrue, reason: 'an idle status before the start ended the lend');
    await until(() => w.recording, what: 'the night recording');
    expect(w.nightFinder.calls, isEmpty, reason: 'the recorder reached for a headband of its own');
    expect(w.log(), isNot(contains('out of range')));
    expect(w.band.count('startSignal'), 1);
    // once it records, idle does mean the night is over
    await w.recorder!.stop();
    await until(() => !w.owner.lending, what: 'the lend ended by the stop');
  });

  test('a live connection with no contact reading: the night starts on it at once and says none was measured', () async {
    // the owner's night of 2026-11-25 00:36: the recorder waited its whole contact time on the lent connection, which
    // never sends resistance, and wrote "contact check: no resistance data arrived"
    final w = World();
    addTearDown(w.close);
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, _) {});
    expect(await link.connect(), isTrue);
    await link.startSignal(); // a screen that streams without a contact check
    await until(() => w.owner.live);
    expect(w.owner.knownContact, isNull);
    final offer = await w.startNight();
    expect(offer, isNotNull);
    expect(offer!.ohms, isEmpty);
    await until(() => w.recording, what: 'the night recording');
    expect(w.log(), contains('no contact reading on the live connection; not measured now'));
    expect(w.log(), isNot(contains('no resistance data arrived')));
    expect(w.statuses.any((s) => s.phase == Phase.checkingContact), isFalse, reason: 'it waited for a check that cannot run');
    expect(w.band.count('startResist'), 0);
    expect(w.nightFinder.calls, isEmpty);
    await link.close();
  });

  test('the lent headband drops: the recorder takes over on a connection of its own, the lost one is not touched', () async {
    final second = CountingBand(label: 'B');
    final w = World(nightBands: [second]);
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close(); // Signal was left; the connection is kept
    expect(await w.startNight(), isNotNull);
    await until(() => w.recording, what: 'the night on the lent connection');
    final before = w.band.calls.length;
    w.band.goOutOfRange();
    await until(() => second.emitted > 0 && w.statuses.last.runs == 2 && w.statuses.last.phase == Phase.recording, what: 'the recorder on its own connection');
    expect(w.band.calls.length, before, reason: 'an SDK call went to the lost headband');
    expect(w.nightFinder.calls, isNotEmpty);
    expect(w.owner.lending, isFalse);
    expect(w.owner.connected, isFalse, reason: 'the screen holds nothing while the recorder owns the headband');
    // tonight's contact reading stays the one that came along: no second check on the new connection
    expect(second.count('startResist'), 0);
  });

  test("the screen's engine goes away while lent: the recorder waits out its stall and connects by itself", () async {
    final second = CountingBand(label: 'B');
    final w = World(nightBands: [second]);
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close();
    expect(await w.startNight(takeWait: const Duration(milliseconds: 40)), isNotNull);
    await until(() => w.recording);
    w.screenAlive = false;
    await until(() => second.emitted > 0 && w.statuses.last.phase == Phase.recording && w.statuses.last.runs == 2, what: 'the recorder on its own connection');
    expect(w.log(), contains('still no data; reconnecting'));
  });

  test('Start sleep with nothing live: no offer, and a kept connection is let go so the recorder can find the headband', () async {
    final w = World();
    addTearDown(w.close);
    expect(await w.owner.lendToNight(), isNull);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close();
    w.band.sending = false; // connected but silent: not live
    await Future<void>.delayed(const Duration(seconds: 3, milliseconds: 100));
    expect(w.owner.live, isFalse);
    expect(await w.owner.lendToNight(), isNull);
    expect(w.band.count('disconnect'), 1);
  }, tags: 'realtime');

  test('during a night no session takes the headband: the owner refuses in plain words', () async {
    final w = World();
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close();
    await w.startNight();
    await until(() => w.recording);
    await expectLater(w.owner.finder.find(const Duration(milliseconds: 10)), throwsA(isA<HeldByNight>()));
    expect(const HeldByNight().toString(), contains('night'));
  });

  test('the status every screen shows: state, electrodes from the one judge, the battery estimate', () async {
    final w = World();
    addTearDown(w.close);
    expect(w.owner.status.value.link, LinkState.off);
    final a = await startLink(w.owner);
    await until(() => w.owner.status.value.link == LinkState.live);
    final s = w.owner.status.value;
    expect(s.name, 'BrainBit A');
    expect(s.battery.percent, 80, reason: 'a new connection\'s first reading is believed');
    expect(s.quality.ohmsAt, isNotNull);
    expect(s.quality.electrodes.map((e) => e.name), ['O1', 'O2', 'T3', 'T4']);
    expect(s.quality.gradeOf('O1'), Contact.good);
    expect(s.quality.gradeOf('T3'), Contact.ok, reason: '500 kΩ');
    expect(s.quality.gradeOf('T4'), Contact.poor, reason: '1.5 MΩ');
    await a.link.close();
  });
}
