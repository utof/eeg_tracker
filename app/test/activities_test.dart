// Work, Meditate and the other sessions as activities of the recording (lib/spans/activities.dart; Record first step 4,
// DECISIONS 980-984; the spec's tests 2 and 6). The recorder is the real one over a fake headband that counts every
// call; the screen's side is the real connection owner, the real finder door and a session's real link.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/dream/band_link.dart';
import 'package:eeg_tracker/headband/connection.dart';
import 'package:eeg_tracker/headband/device_status.dart';
import 'package:eeg_tracker/headband/finder.dart';
import 'package:eeg_tracker/headband/lend.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart' show ChunkWriter;
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/signal/live_tap.dart';
import 'package:eeg_tracker/spans/activities.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
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

/// The phone for one day: the screen's engine (owner, activities) and the recorder's, joined by messages as the app
/// joins them.
class Day {
  Day({List<Headband>? bands}) {
    nightFinder = CountingFinder(bands ?? [band]);
    owner = HeadbandConnection(
      makeFinder: () => screenFinder,
      linger: const Duration(seconds: 30),
      tickEvery: const Duration(milliseconds: 20),
      sendToNight: toRecorder,
      leaseNight: (on, user) {
        tap.lease(on: on, user: user);
        ChunkWriter.onLive = tap.on ? tap.add : null;
      },
    );
    acts = Activities(
      owner: owner,
      send: toRecorder,
      serviceRuns: () async => recorder != null && !stopped,
      askStatus: () => toRecorder('status'),
      answerWait: const Duration(seconds: 3),
      askEvery: const Duration(milliseconds: 5),
    );
    acts.startRecording = (kind) async {
      startedBy.add(kind);
      await record(firstSpan: kind);
      return null;
    };
    acts.stopRecording = stop;
    tapTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => tap.on ? tap.flush() : null);
    HeadbandConnection.shared = owner;
    Activities.shared = acts;
    BrainBitFinder.diyChosen = () async => false;
  }

  final CountingBand band = CountingBand();

  /// What the screen's engine would reach the headband with by itself: nothing may ask it while a recording runs.
  final CountingFinder screenFinder = CountingFinder([]);
  late final CountingFinder nightFinder;
  late final HeadbandConnection owner;
  late final Activities acts;
  late final NightTapSender tap = NightTapSender(send: (m) => owner.recorderData(m));
  late final Timer tapTimer;
  NightRecorder? recorder;
  bool stopped = false;
  final List<String> startedBy = [];
  final List<RecorderStatus> statuses = [];
  final MemoryNightStore store = MemoryNightStore();
  late final Directory files = Directory.systemTemp.createTempSync('activities');
  late final Directory dir = Directory('${files.path}/recordings')..createSync();
  late final SpanLog log = SpanLog(spansDirFor(dir.path));

  void _status(RecorderStatus s) {
    statuses.add(s);
    owner.recorderData(s.toMap(nowMs: DateTime.now().millisecondsSinceEpoch));
  }

  /// Record (or Sleep, or an activity's start): the recorder as recorder_service.dart makes it.
  Future<void> record({bool sleep = false, String? firstSpan}) async {
    final made = await owner.lendToNight();
    final offer = made == null ? null : LendOffer.fromJson(made.toJson());
    stopped = false;
    final r = recorder = NightRecorder(
      finder: LendFinder(inner: nightFinder, toScreen: owner.recorderData, offer: offer, takeWait: const Duration(milliseconds: 100)),
      dir: dir,
      store: store,
      onStatus: _status,
      onStuck: (_) async {},
      timing: _fast,
      watch: null,
      spanLog: log,
      sleep: sleep,
      firstSpan: firstSpan,
    );
    unawaited(r.run(restartedBySystem: false));
  }

  /// What recorder_service.dart does with a message from the screen.
  void toRecorder(Object m) {
    final r = recorder;
    if (r == null || stopped) return;
    if (m == 'status') return _status(r.status);
    if (m is Map && m['kind'] == 'span') {
      r.spanCommand(m);
      _status(r.status);
    }
  }

  Future<void> stop() async {
    stopped = true;
    await recorder?.stop();
    owner.nightEnded();
  }

  bool get recording => statuses.isNotEmpty && statuses.last.phase == Phase.recording && statuses.last.nightSamples > 0;

  String get recordingId => statuses.last.rec.id!;

  List<Span> get spans => log.read(recordingId).spans;

  List<Map<String, Object?>> headers() => [
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.header.json')))
      (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>(),
  ];

  int get rawSets => dir.listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).length;

  /// A session as its screen makes it: the door for its kind, the link, the contact step, the stream.
  Future<({BrainBitFinder door, BandLink link, List<int> got})> session(String kind) async {
    final door = BrainBitFinder(activity: kind);
    final got = <int>[];
    final link = BandLink(finder: door, timing: _quick, onBatch: (_, b) => got.add(b.length));
    expect(await link.connect(), isTrue);
    await link.contact();
    await link.startSignal();
    return (door: door, link: link, got: got);
  }

  Future<void> close() async {
    tapTimer.cancel();
    ChunkWriter.onLive = null;
    await stop();
    await owner.dispose();
    HeadbandConnection.shared = null;
    Activities.shared = null;
    try {
      files.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  setUp(() {
    LiveTap.reset();
    BandLink.forgetAbandoned();
  });

  test('Record, Work, Stop work, Meditate, Stop: one recording, one connection, one contact check, the spans as pressed', () async {
    final d = Day();
    addTearDown(d.close);
    await d.record();
    await until(() => d.recording, what: 'the recording');
    expect(d.acts.ref, isNull);

    final work = await d.session('work');
    await until(() => work.got.length > 5, what: "Work reading the recording's stream");
    expect(d.acts.current.value?.kind, 'work');
    expect(work.link.name, 'BrainBit A', reason: "the session's file names the recording's headband");
    expect(d.acts.ref?.recording, d.recordingId);
    expect(d.acts.ref?.span, '${d.recordingId}-1');
    expect(d.statuses.last.rec.open('work'), isNotNull);
    await work.link.close();
    await until(() => d.statuses.last.rec.open('work') == null, what: 'the work span closed');
    expect(d.acts.ask.value, isNull, reason: 'Record started this recording: stopping Work asks nothing');
    expect(d.statuses.last.phase, Phase.recording, reason: 'the recording goes on after Stop work');

    final med = await d.session('meditate');
    await until(() => med.got.length > 5);
    await med.link.close();
    await until(() => d.statuses.last.rec.open() == null);
    final id = d.recordingId;
    await d.stop();

    expect(d.screenFinder.calls, isEmpty, reason: "the screen's engine searched or connected");
    expect(d.nightFinder.scans + d.nightFinder.directs, 1, reason: 'the headband was asked for more than once');
    expect(d.band.count('startResist'), 1, reason: 'a second contact check');
    expect(d.band.count('startSignal'), 1);
    expect(d.rawSets, 1, reason: 'an activity wrote a raw set of its own');
    expect(d.headers().map((h) => h['recording']).toSet(), {id});
    final spans = d.log.read(id).spans;
    expect([for (final s in spans) (s.kind, s.label, s.source, s.startedRecording, s.endedBy)], [
      ('work', 'working', 'owner_button', false, 'owner'),
      ('meditate', 'meditating', 'owner_button', false, 'owner'),
    ]);
    expect(spans.every((s) => s.closed), isTrue);
    expect(spans[0].end!.isAfter(spans[1].start), isFalse, reason: 'one activity at a time');
  });

  test('Work pressed with nothing recording starts the recorder; its Stop asks, and Stop everything stops it', () async {
    final d = Day();
    addTearDown(d.close);
    final work = await d.session('work');
    expect(d.startedBy, ['work']);
    await until(() => d.recording && work.got.length > 5, what: 'the recording Work started');
    final span = d.statuses.last.rec.open('work')!;
    expect(span.startedRecording, isTrue);
    expect(span.source, 'owner_button');
    await work.link.close();
    final asked = d.acts.ask.value;
    expect(asked?.kind, 'work', reason: 'Work started the recording: Stop everything or Keep recording?');
    await d.acts.answer(stopEverything: true);
    expect(d.acts.ask.value, isNull);
    expect(d.stopped, isTrue);
    final spans = d.log.read(d.recordingId).spans;
    expect(spans.single.endedBy, 'owner');
    expect(spans.single.closed, isTrue);
    expect(d.nightFinder.scans + d.nightFinder.directs, 1);
    expect(d.screenFinder.calls, isEmpty);
  });

  test('Keep recording: the activity ends, the recording goes on, and the next activity asks nothing', () async {
    final d = Day();
    addTearDown(d.close);
    final med = await d.session('meditate');
    await until(() => d.recording && med.got.isNotEmpty);
    await med.link.close();
    expect(d.acts.ask.value, isNotNull);
    await d.acts.answer(stopEverything: false);
    expect(d.stopped, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(d.statuses.last.phase, Phase.recording);
    final work = await d.session('work');
    await until(() => work.got.length > 3);
    await work.link.close();
    expect(d.acts.ask.value, isNull, reason: 'Work did not start this recording');
    expect(d.startedBy, ['meditate']);
    expect([for (final s in d.spans) (s.kind, s.startedRecording)], [('meditate', true), ('work', false)]);
  });

  test('no headband found yet: the span opens anyway, the session waits, and reads once the headband is there', () async {
    final d = Day(bands: []);
    addTearDown(d.close);
    final door = BrainBitFinder(activity: 'work');
    final got = <int>[];
    final link = BandLink(finder: door, timing: _quick, onBatch: (_, b) => got.add(b.length));
    expect(await link.connect(), isTrue, reason: 'the activity starts without the headband: it is what you are doing');
    await link.startSignal();
    expect(d.statuses.last.rec.open('work'), isNotNull);
    expect(d.statuses.last.phase, isNot(Phase.recording));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(got, isEmpty);
    d.nightFinder.bands.add(d.band);
    await until(() => got.length > 3, what: 'the stream after the headband was found');
    // the span opened before the recording had its id: it is the recording's first all the same
    expect(d.spans.single.id, '${d.recordingId}-1');
    await link.close();
    await until(() => d.spans.single.closed, what: 'the span closed under its final id');
    expect(d.screenFinder.calls, isEmpty);
  });

  test('the recording is stopped under an activity: no command to a recorder that is gone, no question', () async {
    final d = Day();
    addTearDown(d.close);
    final work = await d.session('work');
    await until(() => d.recording && work.got.isNotEmpty);
    await d.stop();
    await until(() => work.link.recordingEnded, what: 'the session hearing the stop');
    await work.link.close();
    expect(d.acts.ask.value, isNull);
    expect(d.acts.current.value, isNull);
    final span = d.log.read(d.recordingId).spans.single;
    expect(span.endedBy, 'recording_stopped', reason: 'Stop of the recording closes every open span');
  });

  test('the DIY board is chosen: an activity is refused in words before anything is started', () async {
    final d = Day();
    addTearDown(d.close);
    BrainBitFinder.diyChosen = () async => true;
    await expectLater(BrainBitFinder(activity: 'work').find(const Duration(milliseconds: 10)), throwsA(isA<NotForDiyBoard>()));
    expect(d.startedBy, isEmpty);
    expect(d.recorder, isNull);
  });

  test('a door without an activity (the Signal view) opens no span and starts nothing', () async {
    final d = Day();
    addTearDown(d.close);
    await d.record();
    await until(() => d.recording);
    final link = BandLink(finder: BrainBitFinder(), timing: _quick, onBatch: (_, _) {});
    expect(await link.connect(), isTrue);
    await link.startSignal();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(d.statuses.last.rec.spans, isEmpty);
    await link.close();
    expect(d.acts.ask.value, isNull);
  });

  test('while Sleep is marked no other activity starts: it says so, and nothing is written', () async {
    final d = Day();
    addTearDown(d.close);
    await d.record(sleep: true);
    await until(() => d.recording);
    final door = BrainBitFinder(activity: 'work');
    await expectLater(
      door.find(const Duration(milliseconds: 10)),
      throwsA(isA<ActivityRefused>().having((e) => e.why, 'why', allOf(contains('Sleep'), contains('Stop sleep')))),
    );
    expect([for (final s in d.statuses.last.rec.spans) s.kind], ['sleep']);
    expect(d.acts.current.value, isNull);
  });

  test('a span left open by a session whose screen went away is ended when another activity starts', () async {
    final d = Day();
    addTearDown(d.close);
    await d.record();
    await until(() => d.recording);
    d.toRecorder(openSpanCommand('work')); // Work of an earlier run of the app: its screen is gone, its span is open
    final med = await d.session('meditate');
    await until(() => med.got.isNotEmpty);
    final spans = d.statuses.last.rec.spans;
    expect([for (final s in spans) (s.kind, s.closed, s.endedBy)], [('work', true, 'other_activity'), ('meditate', false, null)]);
    await med.link.close();
  });

  test('the same activity pressed again while its span is still open goes on in that span', () async {
    final d = Day();
    addTearDown(d.close);
    await d.record();
    await until(() => d.recording);
    d.toRecorder(openSpanCommand('work'));
    final work = await d.session('work');
    await until(() => work.got.isNotEmpty);
    expect(d.statuses.last.rec.spans, hasLength(1));
    await work.link.close();
    await until(() => d.statuses.last.rec.open() == null);
    expect(d.spans.single.kind, 'work');
  });

  test('the headband card says what is marked on the recording', () {
    final now = DateTime(2099, 1, 1, 14, 30);
    RecorderStatus st(List<Span> spans) => RecorderStatus(
      phase: Phase.recording,
      nightStartMs: now.millisecondsSinceEpoch - 60000,
      lastDataMs: now.millisecondsSinceEpoch - 500,
      rec: RecordingLive(id: 'r', sleep: false, spans: spans),
    );
    final work = Span(id: 'r-1', kind: 'work', start: now, source: 'owner_button');
    expect(DeviceStatus.fromRecorder(st([work]), now: now).word, 'Recording · Work');
    expect(DeviceStatus.fromRecorder(st([work.closedAt(now, 'owner')]), now: now).word, 'Recording');
    expect(DeviceStatus.fromRecorder(st(const []), now: now).word, 'Recording');
  });

  test('the span commands as plain maps', () {
    expect(openSpanCommand('work'), {'kind': 'span', 'op': 'open', 'span_kind': 'work'});
    expect(openSpanCommand('work', startedRecording: true)['started_recording'], isTrue);
    expect(closeSpanCommand('r-1', by: 'activity'), {'kind': 'span', 'op': 'close', 'id': 'r-1', 'by': 'activity'});
  });
}
