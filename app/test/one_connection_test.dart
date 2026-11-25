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
import 'package:eeg_tracker/recorder/chunk_writer.dart' show ChunkWriter, Sample;
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
  World({
    Duration linger = const Duration(seconds: 30),
    List<Headband>? nightBands,
    Duration quietAfter = recorderQuietAfter,
    this.timing = _fast,
  }) {
    nightFinder = CountingFinder(nightBands ?? []);
    owner = HeadbandConnection(
      makeFinder: () => real,
      disposeFinder: (_, {required anyLost}) => real.disposed++,
      linger: linger,
      tickEvery: const Duration(milliseconds: 20),
      // Android's word on the recorder's service
      serviceRuns: () async => serviceUp,
      quietAfter: quietAfter,
      sendToNight: (m) {
        if (screenAlive) lend?.onMessage(m);
      },
      // the recorder's tap, as recorder_service.dart wires it
      leaseNight: (on, user) {
        leases.add((on, user));
        tap.lease(on: on, user: user);
        ChunkWriter.onLive = tap.on ? saved : null;
      },
    );
    tapTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => tap.on ? tap.flush() : null);
  }

  final List<(bool, String)> leases = [];
  late final NightTapSender tap = NightTapSender(
    send: (m) {
      if (screenAlive) owner.recorderData(m);
    },
  );
  late final Timer tapTimer;

  /// The packet numbers of every sample the recorder saved while the tap was leased.
  final List<int> savedPacks = [];

  void saved(String stem, int first, DateTime arrival, List<Sample> samples) {
    savedPacks.addAll(samples.map((x) => x.pack));
    tap.add(stem, first, arrival, samples);
  }

  final CountingBand band = CountingBand();
  late final CountingFinder real = CountingFinder([band]);
  late final CountingFinder nightFinder;
  late final HeadbandConnection owner;
  LendFinder? lend;
  NightRecorder? recorder;
  bool nightOn = false;
  final RecorderTiming timing;

  /// The recorder's service exists (it does from the start of a recording until [serviceGone]).
  bool serviceUp = false;

  /// The service's heartbeat, as recorder_service.dart runs it: [beatOn] false plays a recorder that says nothing.
  bool beatOn = true;
  int beats = 0;
  late final StatusBeat beat = StatusBeat(
    read: () => beatOn ? recorder?.status : null,
    send: (s) {
      beats++;
      if (screenAlive) owner.recorderData(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));
    },
    every: const Duration(milliseconds: 20),
  );

  /// Android took the service away without a word from the recorder.
  void serviceGone() {
    serviceUp = false;
    beatOn = false;
    sayStatus = false;
  }

  /// False: the recorder's own statuses do not reach the screen any more (with [serviceGone]).
  bool sayStatus = true;

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
    serviceUp = true;
    beat.start();
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
        if (screenAlive && sayStatus) owner.recorderData(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));
      },
      onStuck: (_) async {},
      timing: timing,
      watch: null,
    );
    unawaited(r.run(restartedBySystem: false));
    return offer;
  }

  bool get recording => statuses.isNotEmpty && statuses.last.phase == Phase.recording && statuses.last.nightSamples > 0;

  String log() => dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).map((f) => f.readAsStringSync()).join();

  Future<void> close() async {
    beat.stop();
    tapTimer.cancel();
    ChunkWriter.onLive = null;
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

  // ---- Record first, step 4 (DECISIONS 897): a session started during a recording rides on the recorder's stream ----

  test('during a recording a session gets the recorder\'s stream: every saved sample in order, and no SDK call', () async {
    final nightBand = CountingBand(label: 'N');
    final w = World(nightBands: [nightBand]);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.recording);
    int own() => nightBand.calls.where((c) => c != 'battery').length; // the recorder reads its battery by itself
    final callsBefore = own();

    final packs = <int>[];
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, b) => packs.addAll(b.map((x) => x.pack)));
    expect(await link.connect(), isTrue);
    final sw = Stopwatch()..start();
    final ohms = await link.contact();
    expect(sw.elapsedMilliseconds, lessThan(15), reason: 'a contact check of its own was made');
    expect(ohms, w.statuses.last.contactOhms, reason: "the recorder's reading is the session's");
    await link.startSignal();
    await until(() => packs.length >= 300, what: '300 samples through the tap');
    await link.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(w.real.calls, isEmpty, reason: "the screen's engine reached for the headband");
    expect(w.nightFinder.scans + w.nightFinder.directs, 1, reason: 'a second connection was made');
    expect(own(), callsBefore, reason: 'the session made an SDK call on the recording headband');
    expect(nightBand.count('startResist'), 1, reason: 'only the recorder\'s own check at its start');
    // every sample the recorder saved while the session listened, in the recorder's order
    expect(packs, isNotEmpty);
    final from = w.savedPacks.indexOf(packs.first);
    expect(from, greaterThanOrEqualTo(0));
    expect(packs, w.savedPacks.sublist(from, from + packs.length));
    for (var i = 1; i < packs.length; i++) {
      expect(packs[i], (packs[i - 1] + 1) % 2048, reason: 'a sample is missing at $i');
    }
    expect(w.leases.where((l) => l.$2 == tapRide && l.$1), isNotEmpty);
    expect(w.leases.last, (false, tapRide), reason: 'the session let its lease go');
    expect(w.statuses.last.phase, Phase.recording, reason: 'the recording goes on');
  }, tags: 'realtime');

  // The recorder's waits in these tests are many times the screen's patience ([quietAfter] 60 ms): a recorder that
  // searches or reconnects sends no sample for all that time, and the screen must still know it exists.
  const slow = RecorderTiming(
    tick: Duration(milliseconds: 10),
    ticksPerCheck: 5,
    scanFor: Duration(milliseconds: 20),
    contactFor: Duration(milliseconds: 20),
    settle: Duration(milliseconds: 5),
    retryWait: Duration(milliseconds: 5),
    sdkTimeout: Duration(milliseconds: 300),
    connectTimeout: Duration(milliseconds: 300),
    notFoundWait: Duration(milliseconds: 400),
    notFoundWaitLong: Duration(milliseconds: 400),
    stallChecksToGiveUp: 3,
    stopTimeout: Duration(seconds: 2),
    reconnectWaits: [Duration(milliseconds: 600)],
    scanEvery: 3,
    rescanFor: Duration(milliseconds: 20),
  );
  const patience = Duration(milliseconds: 60);

  test('the recording headband drops under a session for longer than the screen waits for a beat: the session waits, '
      'the recorder reconnects, the stream is back', () async {
    final first = CountingBand(label: 'N'), second = CountingBand(label: 'N2');
    final w = World(nightBands: [first, second], quietAfter: patience, timing: slow);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.recording);
    final got = <int>[];
    final events = <LinkEvent>[];
    final link = BandLink(
      finder: w.owner.finder,
      timing: _quick,
      onBatch: (_, b) => got.add(b.length),
      onEvent: (e, _) => events.add(e),
    );
    await link.connect();
    await link.startSignal();
    await until(() => got.isNotEmpty);
    first.goOutOfRange();
    await until(() => link.lost, what: 'the session hearing of the drop');
    // the recorder waits 600 ms before its try: ten times the screen's patience without one sample
    await Future<void>.delayed(patience * 5);
    expect(w.statuses.last.phase, Phase.reconnecting);
    expect(w.owner.nightRuns, isTrue, reason: 'the screen forgot the recording while the recorder reconnects');
    expect(w.owner.status.value.link, LinkState.reconnecting, reason: 'the card must not offer Connect');
    expect(link.recordingEnded, isFalse, reason: 'the session was ended as if the recording had stopped');
    await w.owner.connectNow();
    expect(w.real.calls, isEmpty, reason: "Connect made the screen's engine reach for the headband");
    await until(() => !link.lost && second.emitted > 0, what: 'the recorder reconnected');
    final n = got.length;
    await until(() => got.length > n, what: 'samples after the reconnect');
    link.tick();
    expect(events, [LinkEvent.drop, LinkEvent.reconnected]);
    expect(w.real.calls, isEmpty, reason: 'the session searched or connected by itself');
    expect(w.nightFinder.scans + w.nightFinder.directs, 2, reason: 'only the recorder reconnects');
    await link.close();
  });

  test('the recorder looks for the headband and has no sample yet: the screen knows a recording runs, Connect and a '
      'session do not reach for the headband', () async {
    final w = World(nightBands: [], quietAfter: patience, timing: slow);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.statuses.isNotEmpty && w.statuses.last.note.contains('not found'), what: 'the first failed search');
    await Future<void>.delayed(patience * 4);
    expect(w.owner.nightRuns, isTrue, reason: 'no status for four times the patience, and the recording was forgotten');
    expect(w.owner.status.value.link, isNot(LinkState.off), reason: 'the card says off and offers Connect');
    await w.owner.connectNow();
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, _) {});
    expect(await link.connect(), isTrue, reason: 'a session rides on the recording, also while it searches');
    expect(w.real.calls, isEmpty, reason: "the screen's engine reached for the headband under the recorder");
    expect(w.beats, greaterThan(3));
    await link.close();
  });

  test('a recorder that says nothing at all is still a recording while its service exists', () async {
    final w = World(nightBands: [], quietAfter: patience, timing: slow);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.owner.nightRuns);
    w.beatOn = false;
    w.sayStatus = false;
    await Future<void>.delayed(patience * 5);
    expect(w.owner.nightRuns, isTrue);
    await w.owner.connectNow();
    expect(w.real.calls, isEmpty);
  });

  test('a screen that has heard nothing yet (it just opened) does not connect while the recorder\'s service exists', () async {
    final w = World(nightBands: [], quietAfter: patience, timing: slow);
    addTearDown(w.close);
    w.serviceUp = true; // the service runs; its first beat has not reached this screen
    expect(w.owner.nightRuns, isFalse);
    await w.owner.connectNow();
    final band = await w.owner.finder.find(const Duration(milliseconds: 10));
    expect(band, isA<RecordingBand>());
    expect(w.real.calls, isEmpty);
    // and when that service goes without a word, the rider hears the end
    w.serviceUp = false;
    await until(() => (band! as RecordingBand).ended, what: 'the rider hearing that the service is gone');
    await band!.disconnectAndDispose();
  });

  test('the recorder\'s service goes without a word under a session: the session hears the end, and the next start '
      'connects as before', () async {
    final w = World(nightBands: [CountingBand(label: 'N')], quietAfter: patience);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.recording);
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, _) {});
    await link.connect();
    await link.startSignal();
    w.serviceGone();
    await until(() => link.recordingEnded && link.lost, what: 'the session hearing that the recorder is gone');
    expect(w.owner.nightRuns, isFalse);
    await link.close();
    final a = await startLink(w.owner);
    await until(() => a.got.isNotEmpty);
    expect(w.real.scans, 1);
    await a.link.close();
  });

  test('the recording stops under a session: the session hears it from the recorder\'s own last word, and the next '
      'start connects as before', () async {
    final w = World(nightBands: [CountingBand(label: 'N')]);
    addTearDown(w.close);
    await w.startNight();
    await until(() => w.recording);
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, _) {});
    await link.connect();
    await link.startSignal();
    expect(link.recordingEnded, isFalse);
    await w.recorder!.stop();
    w.serviceUp = false;
    await until(() => link.recordingEnded && link.lost, what: 'the session hearing the stop');
    expect(w.owner.nightRuns, isFalse);
    await link.close();
    final a = await startLink(w.owner);
    await until(() => a.got.isNotEmpty);
    expect(w.real.scans, 1, reason: 'between recordings a session connects by itself, as before');
    await a.link.close();
  });

  test('the heartbeat sends the status whether or not samples come, and never an idle one', () async {
    var status = const RecorderStatus();
    RecorderStatus? read() => status;
    final sent = <Phase>[];
    final beat = StatusBeat(read: read, send: (s) => sent.add(s.phase), every: const Duration(milliseconds: 10))..start();
    addTearDown(beat.stop);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sent, isEmpty, reason: 'a recorder that has not begun is idle: that is not an end to tell');
    for (final p in [Phase.searching, Phase.reconnecting, Phase.recording, Phase.stopping]) {
      status = RecorderStatus(phase: p);
      final n = sent.length;
      await until(() => sent.length >= n + 2, what: 'two beats while $p');
      expect(sent.last, p);
    }
    beat.stop();
    final n = sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(sent.length, n);
  });

  test('a session on a lent recording (Signal, Sleep, then Work): still one connection', () async {
    final w = World();
    addTearDown(w.close);
    final a = await startLink(w.owner);
    await until(() => w.owner.live);
    await a.link.close();
    await w.startNight();
    await until(() => w.recording);
    final got = <int>[];
    final link = BandLink(finder: w.owner.finder, timing: _quick, onBatch: (_, b) => got.add(b.length));
    expect(await link.connect(), isTrue);
    await link.contact();
    await link.startSignal();
    await until(() => got.length > 5, what: 'the lent recording\'s samples at the session');
    await link.close();
    expect(w.real.scans, 1);
    expect(w.real.directs, 0);
    expect(w.band.count('startResist'), 1);
    expect(w.band.count('startSignal'), 1);
    expect(w.nightFinder.calls, isEmpty);
  });

  test("the tap's leases are one per user: the panel letting go does not cut a session's stream", () {
    var now = DateTime(2099, 1, 1, 12);
    final sent = <Object>[];
    final tap = NightTapSender(send: sent.add, clock: () => now);
    final batch = [for (var i = 0; i < 4; i++) Sample(i, [for (var c = 0; c < 8; c++) (c + 1) * 1e-6])];
    tap.lease(on: true, user: tapPanel);
    tap.lease(on: true, user: tapRide);
    tap.lease(on: false, user: tapPanel);
    expect(tap.on, isTrue);
    tap.add('run', 0, now, batch);
    // the last user lets go: what was gathered for it still goes out
    tap.lease(on: false, user: tapRide);
    expect(tap.on, isFalse);
    final got = nightTapSamples(sent.single)!.single;
    expect(got.map((x) => x.pack), [0, 1, 2, 3]);
    expect(got.first.volts, hasLength(8), reason: 'any number of channels');
    expect(got.first.volts[7], closeTo(8e-6, 1e-12));
    // one user's lease running out leaves the other's
    tap.lease(on: true, user: tapPanel);
    now = now.add(const Duration(seconds: 10));
    tap.lease(on: true, user: tapRide);
    now = now.add(const Duration(seconds: 10));
    expect(tap.on, isTrue);
    now = now.add(const Duration(seconds: 10));
    expect(tap.on, isFalse);
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
