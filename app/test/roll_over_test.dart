// A long recording goes on in a new file set (DECISIONS 1035-1037): the headband's stream is never touched, every
// sample lands in exactly one set, and what reads a recording sees no seam.
// Real time (a fake headband's timers): tagged `realtime`, run apart from the parallel step (dart_test.yaml).
@Tags(['realtime'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/replay.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/live_drift.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/nights.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/night_signal.dart';
import 'package:eeg_tracker/spans/span.dart';
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder, fast;

/// The counters of every record of [f32], in file order.
List<int> packs(File f32) {
  final b = ByteData.sublistView(f32.readAsBytesSync());
  return [for (var o = 0; o + recordBytes <= b.lengthInBytes; o += recordBytes) b.getUint32(o, Endian.little)];
}

/// A headband under load: 40 samples every 2 ms (20 kHz), its counter never wrapping.
class BusyBand extends FakeBand {
  BusyBand(super.label) : super(packOf: (i) => i);
  Timer? _busy;
  final _out = StreamController<List<Sample>>.broadcast(sync: true);
  int _n = 0;

  @override
  Stream<List<Sample>> get signal => _out.stream;

  @override
  Future<void> startSignal() async {
    calls.add('startSignal');
    _busy?.cancel();
    _busy = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (!_out.hasListener) return;
      _out.add([for (var i = 0; i < 40; i++) Sample.four(pack: _n++, o1: 1e-6, o2: 2e-6, t3: 3e-6, t4: 4e-6)]);
      emitted += 40;
    });
  }

  @override
  Future<void> stopSignal() async {
    calls.add('stopSignal');
    _busy?.cancel();
  }

  @override
  Future<void> disconnectAndDispose() async {
    calls.add('disconnect');
    _busy?.cancel();
  }
}

RecorderTiming rolling({int bytes = 1 << 40, Duration after = const Duration(days: 9)}) => RecorderTiming(
  tick: fast.tick,
  ticksPerCheck: fast.ticksPerCheck,
  scanFor: fast.scanFor,
  contactFor: fast.contactFor,
  settle: fast.settle,
  retryWait: fast.retryWait,
  sdkTimeout: fast.sdkTimeout,
  connectTimeout: fast.connectTimeout,
  notFoundWait: fast.notFoundWait,
  notFoundWaitLong: fast.notFoundWaitLong,
  stallChecksToGiveUp: fast.stallChecksToGiveUp,
  stopTimeout: fast.stopTimeout,
  reconnectWaits: fast.reconnectWaits,
  scanEvery: fast.scanEvery,
  rescanFor: fast.rescanFor,
  rollAfter: after,
  rollBytes: bytes,
  rollRetry: Duration.zero,
);

void main() {
  late Directory root, dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;

  setUp(() {
    root = Directory.systemTemp.createTempSync('roll_over_test');
    dir = Directory('${root.path}/recordings')..createSync();
    store = MemoryNightStore();
    statuses = [];
    forgetNightSets();
  });
  tearDown(() => root.deleteSync(recursive: true));

  NightRecorder recorder(
    HeadbandFinder finder,
    RecorderTiming timing, {
    Directory? into,
    NightStore? state,
    DateTime Function()? clock,
    ChunkWriter Function(Directory, DateTime, {RecordingHeader? header, bool inRecording, String? recording})? openSet,
    bool sleep = true,
  }) => NightRecorder(
    finder: finder,
    dir: into ?? dir,
    store: state ?? store,
    onStatus: statuses.add,
    onStuck: (_) async {},
    timing: timing,
    watch: null,
    clock: clock,
    openSet: openSet,
    sleep: sleep,
    spanLog: SpanLog(spansDirFor((into ?? dir).path)),
  );

  List<File> files(String ext, [Directory? of]) =>
      (of ?? dir).listSync().whereType<File>().where((f) => f.path.endsWith('.$ext')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('under load a recording rolls over many times: every sample once, in order, across the sets', () async {
    final band = BusyBand('a');
    final r = recorder(FakeFinder([band]), rolling(bytes: 40 * 1024));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await r.stop();
    await running;

    final sets = files('f32');
    expect(sets.length, greaterThan(3), reason: 'it rolled over');
    final all = [for (final f in sets) ...packs(f)];
    expect(all.length, band.emitted, reason: 'no sample lost');
    for (var i = 0; i < all.length; i++) {
      if (all[i] != i) fail('counter $i is ${all[i]}: lost or written twice at a boundary');
    }
    // one connection, one recording: the headband was never asked to stop or start again
    expect(band.calls.where((c) => c == 'startSignal'), hasLength(1));
    expect(band.calls.where((c) => c == 'stopSignal'), hasLength(1));
    expect(store.state.runs, 1, reason: 'a roll-over is not a drop');
    expect(store.state.samples, band.emitted);
    final ids = {for (final f in sets) readHeader(f).recording};
    expect(ids, {sets.first.uri.pathSegments.last.substring(0, 17)}, reason: 'every set names the same recording');
    // each set's index covers exactly its own samples, from 0
    for (final f in sets) {
      final idx = ByteData.sublistView(File('${f.path.substring(0, f.path.length - 4)}.idx').readAsBytesSync());
      expect(idx.getUint64(8, Endian.little), 0);
      expect(idx.lengthInBytes % indexBytes, 0);
    }
    final logs = files('log');
    expect(logs.first.readAsStringSync(), contains('the recording goes on without a gap in ${sets[1].uri.pathSegments.last.substring(0, 17)}'));
    expect(logs[1].readAsStringSync(), contains('continues ${sets[0].uri.pathSegments.last.substring(0, 17)} without a gap'));
    expect(logs.last.readAsStringSync(), isNot(contains('drop (')));
  });

  test('the readers see one unbroken recording: no gap is put between the sets, and one night holds them all', () async {
    final band = BusyBand('a');
    // a set a second at most (file names are to the second, and a set's place in a night is read from its name)
    final r = recorder(FakeFinder([band]), rolling(bytes: 480 * 1024));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 4200));
    await r.stop();
    await running;

    final sets = files('f32');
    expect(sets.length, greaterThan(2));
    final layout = joinLayout(sets);
    // (the hold before the first sample, from the whole second the join starts at, is not a seam)
    expect(layout.bad.where((b) => b.text == 'BAD_gap' && b.at > 0), isEmpty, reason: 'a roll-over is no missing time');
    expect(layout.parts.where((p) => p.run != null).fold(0, (n, p) => n + p.run!.count), band.emitted);
    final nights = nightsIn(dir);
    expect(nights, hasLength(1));
    // (a set opened in the very second of Stop lies at the sleep stretch's end, which is kept to the second)
    final inNight = nights.single.recordings.map((f) => f.path).toList();
    expect(inNight.length, greaterThanOrEqualTo(sets.length - 1));
    expect(inNight, sets.map((f) => f.path).take(inNight.length));
    expect(nights.single.recordingIds, hasLength(1));
    // the spans file is one, under the recording's id: the split is nothing to it
    expect(spansDirFor(dir.path).listSync(), hasLength(1));
  });

  test('a time limit rolls over too, and the live sleep kit hears no new file', () async {
    final band = FakeBand('a', packOf: (i) => i);
    final t0 = DateTime(2026, 11, 25, 9);
    final sw = Stopwatch()..start();
    // the clock runs 100 000 times faster: 4 hours every 144 ms
    DateTime clock() => t0.add(sw.elapsed * 100000);
    final firsts = <bool>[];
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: rolling(after: const Duration(hours: 4)),
      watch: () => _Listening(firsts),
      clock: clock,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await r.stop();
    await running;

    final sets = files('f32');
    expect(sets.length, greaterThan(2));
    final all = [for (final f in sets) ...packs(f)];
    expect(all, [for (var i = 0; i < band.emitted; i++) i]);
    expect(firsts.where((f) => f), hasLength(1), reason: 'only the connection\'s first batch is a new file to the detectors');
  });

  test('the next set cannot be opened (storage full): the open one goes on, nothing is lost, it is tried again', () async {
    final band = FakeBand('a', packOf: (i) => i);
    var refuse = 3;
    final r = recorder(
      FakeFinder([band]),
      rolling(bytes: 4 * 1024),
      openSet: (d, t, {header, inRecording = false, recording}) {
        if (d.listSync().any((f) => f.path.endsWith('.f32')) && refuse-- > 0) {
          throw const FileSystemException('No space left on device');
        }
        return ChunkWriter.open(d, t, header: header, inRecording: inRecording, recording: recording);
      },
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(r.finished, isFalse);
    await r.stop();
    await running;

    final sets = files('f32');
    expect(sets.length, greaterThan(1), reason: 'it rolled over once the set could be opened');
    expect([for (final f in sets) ...packs(f)], [for (var i = 0; i < band.emitted; i++) i]);
    expect(files('log').first.readAsStringSync(), contains('could not start the next file set'));
    expect(band.calls.where((c) => c == 'startSignal'), hasLength(1));
    // by default a failed roll-over is tried again 5 minutes later, not at every 10-second check
    expect(const RecorderTiming().rollRetry, const Duration(minutes: 5));
  });

  test('the emulator check\'s short roll-over is the replay plan\'s alone: no plan or no replay build, the app\'s own limits', () {
    const t = RecorderTiming();
    expect((t.rollAfter, t.rollBytes), (const Duration(hours: 4), 128 * 1024 * 1024));
    final replay = replayDirFor(dir.path)..createSync();
    expect(replayRollBytes(dir.path, allowed: true), isNull, reason: 'no plan');
    (ChunkWriter.open(replay, DateTime(2026, 11, 25, 9))..addBatch(DateTime(2026, 11, 25, 9), [Sample.four(pack: 0, o1: 0, o2: 0, t3: 0, t4: 0)])).close();
    File('${replay.path}/plan.json').writeAsStringSync('{"loop": true}');
    expect(replayRollBytes(dir.path, allowed: true), isNull, reason: 'a plan that does not ask');
    File('${replay.path}/plan.json').writeAsStringSync('{"loop": true, "roll_bytes": 100000}');
    expect(replayRollBytes(dir.path, allowed: true), 100000);
    expect(replayRollBytes(dir.path), isNull, reason: 'not a replay build: the plan is never read');
    File('${replay.path}/plan.json').writeAsStringSync('{"roll_bytes": 5}');
    expect(() => ReplayPlan.load(replay), throwsA(isA<ReplayError>()));
    expect(replayRollBytes(dir.path, allowed: true), isNull);
  });

  test('the app is killed in the middle of a roll-over: what was received is on disk, and the recording goes on', () async {
    // The disk as a kill leaves it right after the next set's files were made and before anything else: a copy of
    // the folder taken at that very moment (nothing runs between the two steps in the app).
    final killed = Directory('${root.path}/killed/recordings')..createSync(recursive: true);
    final band = FakeBand('a', packOf: (i) => i);
    var receivedAtKill = -1;
    NightState? savedAtKill;
    final r = recorder(
      FakeFinder([band]),
      rolling(bytes: 2 * 1024),
      openSet: (d, t, {header, inRecording = false, recording}) {
        final w = ChunkWriter.open(d, t, header: header, inRecording: inRecording, recording: recording);
        if (receivedAtKill < 0 && d.listSync().where((f) => f.path.endsWith('.f32')).length == 2) {
          receivedAtKill = band.emitted;
          savedAtKill = store.state;
          for (final f in d.listSync().whereType<File>()) {
            f.copySync('${killed.path}/${f.uri.pathSegments.last}');
          }
          final spans = spansDirFor(d.path);
          if (spans.existsSync()) {
            spansDirFor(killed.path).createSync();
            for (final f in spans.listSync().whereType<File>()) {
              f.copySync('${spansDirFor(killed.path).path}/${f.uri.pathSegments.last}');
            }
          }
        }
        return w;
      },
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await r.stop();
    await running;
    expect(receivedAtKill, greaterThan(0), reason: 'a roll-over happened');

    // on the killed disk: the first set holds every sample the app had received, the second is empty
    final before = files('f32', killed);
    expect(before, hasLength(2));
    expect(packs(before[0]), [for (var i = 0; i < receivedAtKill; i++) i]);
    expect(before[1].lengthSync(), 0);
    final id = readHeader(before[0]).recording;
    expect(readHeader(before[1]).recording, id);

    // Android starts the service again: the recording goes on in a third set, under the same id
    await Future<void>.delayed(const Duration(milliseconds: 2100)); // a restart takes seconds: a file name of its own
    final again = FakeBand('b', packOf: (i) => 1000000 + i);
    final after = MemoryNightStore()..state = savedAtKill!;
    final r2 = recorder(FakeFinder([again]), rolling(), into: killed, state: after);
    final running2 = r2.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    await r2.stop();
    await running2;

    final sets = files('f32', killed);
    expect(sets, hasLength(3));
    expect(readHeader(sets[2]).recording, id);
    expect(packs(sets[0]), [for (var i = 0; i < receivedAtKill; i++) i], reason: 'the closed set was not touched');
    expect(packs(sets[2]), [for (var i = 0; i < again.emitted; i++) 1000000 + i]);
    // the readers take the three sets as one recording, the empty one in the middle included
    forgetNightSets();
    final nights = nightsIn(killed);
    expect(nights, hasLength(1));
    expect(nights.single.recordings.map((f) => f.path), [sets[0].path, sets[2].path]);
    final layout = joinLayout(nights.single.recordings);
    expect(layout.parts.where((p) => p.run != null).fold(0, (n, p) => n + p.run!.count), receivedAtKill + again.emitted);
    final spans = spansIn(spansDirFor(killed.path));
    expect(spans.keys, [id]);
  });
}

/// A detector that only notes what the recorder tells it about each batch.
class _Listening implements DriftWatch {
  _Listening(this.firsts);
  final List<bool> firsts;

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) => firsts.add(firstOfFile);

  @override
  void lightsOff(DateTime at) {}

  @override
  List<String> takeEvents() => const [];

  @override
  DriftLive? get live => null;

  @override
  int samples = 0;
}
