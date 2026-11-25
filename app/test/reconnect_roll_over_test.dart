// The reconnect ladder (DECISIONS 940) and the roll-over of a long recording (DECISIONS 1035) in one night recorder
// (DECISIONS 1070): a roll-over is never a drop to the ladder, and a drop that comes with a roll-over is recovered
// from the ladder's first step, however long an earlier drop of the same night lasted. And main's long-loss rules
// (what was marked ends after 60 minutes without the headband, the recording stops itself after 6 hours) are not
// kept waiting by the ladder's long waits of stage C (DECISIONS 1073).
// Real time (a fake headband's timers): tagged `realtime`, run apart from the parallel step (dart_test.yaml).
@Tags(['realtime'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/reconnect_ladder.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/spans/span.dart' show spansDirFor;
import 'package:eeg_tracker/spans/span_log.dart';
import 'package:flutter_test/flutter_test.dart';

import 'night_recorder_test.dart' show FakeBand, FakeFinder;

const _ms = Duration(milliseconds: 1);

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 8), String what = ''}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting $what');
    await Future<void>.delayed(_ms * 5);
  }
}

/// The counters of every record of [f32], in file order.
List<int> packs(File f32) {
  final b = ByteData.sublistView(f32.readAsBytesSync());
  return [for (var o = 0; o + recordBytes <= b.lengthInBytes; o += recordBytes) b.getUint32(o, Endian.little)];
}

/// A finder with a waiting connect a test completes by hand; direct tries find the headband once [back] is set.
class _Finder extends FakeFinder implements WaitingFinder {
  _Finder(super.bands);
  FakeBand? back;
  int opened = 0, closed = 0;
  Completer<Headband>? current;

  @override
  Future<Headband> connectDirect(BandId id) async {
    final b = back;
    if (b != null) {
      back = null;
      direct.add(b);
    }
    return super.connectDirect(id);
  }

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

/// Tiny times: a new file set every [rollBytes]; stage C after 150 ms without the headband.
RecorderTiming timing(int rollBytes, {Duration awayCheckEvery = const Duration(minutes: 1)}) => RecorderTiming(
  tick: _ms * 10,
  ticksPerCheck: 5,
  scanFor: _ms * 20,
  contactFor: _ms * 20,
  settle: _ms * 5,
  retryWait: _ms * 5,
  sdkTimeout: _ms * 300,
  connectTimeout: _ms * 300,
  notFoundWait: _ms * 10,
  notFoundWaitLong: _ms * 10,
  stallChecksToGiveUp: 3,
  stopTimeout: const Duration(seconds: 2),
  reconnectWaits: [_ms * 5, _ms * 10, _ms * 20],
  scanEvery: 1000,
  rescanFor: _ms * 20,
  ladder: LadderTiming(
    mendFor: _ms * 40,
    waitAfter: _ms * 150,
    safetyEvery: const Duration(seconds: 30),
    fallbackEvery: const Duration(seconds: 30),
    fallbackEveryScreenOn: const Duration(seconds: 30),
  ),
  awayCheckEvery: awayCheckEvery,
  rollBytes: rollBytes,
  rollRetry: Duration.zero,
);

typedef OpenSet = ChunkWriter Function(Directory dir, DateTime start, {RecordingHeader? header, bool inRecording, String? recording});

void main() {
  late Directory root, dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;

  setUp(() {
    root = Directory.systemTemp.createTempSync('reconnect_roll_over_test');
    dir = Directory('${root.path}/recordings')..createSync();
    store = MemoryNightStore();
    statuses = [];
  });
  tearDown(() => root.deleteSync(recursive: true));

  NightRecorder recorder(HeadbandFinder finder, {int rollBytes = 4 * 1024, OpenSet? openSet}) => NightRecorder(
    finder: finder,
    dir: dir,
    store: store,
    onStatus: statuses.add,
    onStuck: (_) async {},
    timing: timing(rollBytes),
    watch: null,
    openSet: openSet,
  );

  List<File> files(String ext) =>
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.$ext')).toList()..sort((a, b) => a.path.compareTo(b.path));
  String logs() => files('log').map((f) => f.readAsStringSync()).join('\n');
  String stem(File f) => f.uri.pathSegments.last.split('.').first;

  test('a roll-over is not a drop: the ladder never starts, nothing is tried, no "lost" is shown', () async {
    final band = FakeBand('a', packOf: (i) => i);
    final finder = _Finder([band]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await waitFor(() => files('f32').length >= 4, what: 'for three roll-overs');
    expect(r.ladderStage, isNull);
    expect(store.state.lostAtMs, 0);
    for (final h in ReconnectHint.values) {
      r.hint(h); // a hint between roll-overs does nothing either
    }
    await Future<void>.delayed(_ms * 100);
    await r.stop();
    await running;

    expect(finder.calls, ['scan'], reason: 'one search for the whole recording');
    expect(finder.opened, 0, reason: 'no waiting connect');
    expect(statuses.where((s) => s.phase == Phase.reconnecting), isEmpty);
    final log = logs();
    expect(log, contains('the recording goes on without a gap'));
    expect(log, isNot(contains('reconnect try')));
    expect(log, isNot(contains('drop (')));
    expect(log, isNot(contains('reconnected')));
    expect(store.state.runs, 1);
    expect([for (final f in files('f32')) ...packs(f)], [for (var i = 0; i < band.emitted; i++) i]);
  });

  test('the headband drops as a roll-over opens the next set, after an earlier long drop: '
      'a new drop from the ladder\'s first step, recovered at the first try', () async {
    final first = FakeBand('a', packOf: (i) => i);
    final second = FakeBand('a again', rssi: null, packOf: (i) => 100000 + i);
    final third = FakeBand('a third', rssi: null, packOf: (i) => 200000 + i);
    final finder = _Finder([first]);
    var armed = false;
    String? emptySet;
    final r = recorder(
      finder,
      openSet: (d, t, {header, inRecording = false, recording}) {
        final w = ChunkWriter.open(d, t, header: header, inRecording: inRecording, recording: recording);
        // the second connection's first roll-over: the headband goes at this very moment, so the set that was just
        // opened never gets a sample
        if (armed && second.emitted > 0 && emptySet == null) {
          emptySet = w.stem;
          finder.back = third;
          second.goOutOfRange();
        }
        return w;
      },
    );
    final running = r.run(restartedBySystem: false);
    await waitFor(() => files('f32').length >= 2, what: 'for a roll-over on the first connection');

    // drop 1: long enough for stage C; the headband comes back on the waiting connect
    first.goOutOfRange();
    await waitFor(() => finder.opened == 1, what: 'for the waiting connect');
    expect(r.ladderStage, LadderStage.wait);
    final firstLostAt = store.state.lostAtMs;
    expect(firstLostAt, greaterThan(0));
    final triesInDrop1 = RegExp(r'reconnect try (\d+) \(direct').allMatches(logs()).length;
    expect(triesInDrop1, greaterThan(1));
    armed = true;
    finder.current!.complete(second);

    // drop 2 comes with the second connection's first roll-over; the third headband answers the first direct try
    await waitFor(() => third.emitted > 20, what: 'for the run after the second drop');
    await r.stop();
    await running;

    expect(emptySet, isNotNull, reason: 'the second connection rolled over');
    final log = logs();
    final sets = files('f32');
    final empty = sets.singleWhere((f) => stem(f) == emptySet);
    expect(packs(empty), isEmpty, reason: 'the drop came before the new set\'s first sample');
    // the drop is written into the set that was open, and it is a drop of its own
    final emptyLog = File('${dir.path}/$emptySet.log').readAsStringSync();
    expect(emptyLog, contains('continues '));
    expect(emptyLog, contains('drop (out of range)'));
    expect(finder.opened, 1, reason: 'not taken for the old drop going on: no second waiting connect');
    expect(
      emptyLog,
      contains(RegExp(r'reconnect try 1 \(direct to AA:BB\): connected')),
      reason: 'the ladder began again at its first step',
    );
    expect(
      log,
      contains(RegExp('reconnected \\(direct, try 1\\) after a drop \\(out of range\\); previous run $emptySet, .*; waited 0 s; back by: quick try')),
    );
    // every sample of the three connections is in one set, once, in order
    final all = [for (final f in sets) ...packs(f)];
    expect(all, [
      for (var i = 0; i < first.emitted; i++) i,
      for (var i = 0; i < second.emitted; i++) 100000 + i,
      for (var i = 0; i < third.emitted; i++) 200000 + i,
    ]);
    expect(store.state.runs, 3, reason: 'three connections; the roll-overs are not runs');
    expect(store.state.lostAtMs, 0);
    expect(r.ladderStage, isNull);
  });

  test('the next set cannot be opened and the headband drops at that moment: the open set keeps the drop, '
      'and the recording goes on after the reconnect', () async {
    final first = FakeBand('a', packOf: (i) => i);
    final again = FakeBand('a again', rssi: null, packOf: (i) => 100000 + i);
    final finder = _Finder([first]);
    var refused = false;
    final r = recorder(
      finder,
      openSet: (d, t, {header, inRecording = false, recording}) {
        if (!refused && first.emitted > 0) {
          refused = true;
          finder.back = again;
          first.goOutOfRange();
          throw const FileSystemException('No space left on device');
        }
        return ChunkWriter.open(d, t, header: header, inRecording: inRecording, recording: recording);
      },
    );
    final running = r.run(restartedBySystem: false);
    await waitFor(() => again.emitted > 20, what: 'for the run after the drop');
    await r.stop();
    await running;

    expect(refused, isTrue);
    final firstLog = files('log').first.readAsStringSync();
    expect(firstLog, contains('could not start the next file set'));
    expect(firstLog, contains('drop (out of range)'));
    expect(logs(), contains(RegExp(r'reconnected \(direct, try 1\) after a drop \(out of range\); .*back by: quick try')));
    expect([for (final f in files('f32')) ...packs(f)], [
      for (var i = 0; i < first.emitted; i++) i,
      for (var i = 0; i < again.emitted; i++) 100000 + i,
    ]);
    expect(readHeader(files('f32').last).recording, readHeader(files('f32').first).recording, reason: 'one recording');
  });

  test('while the ladder waits in stage C (its next try 30 s away) the 60-minute rule and the 6-hour stop still come '
      'on time', () async {
    var now = DateTime(2026, 11, 25, 21);
    DateTime clock() => now;
    final band = FakeBand('a');
    final finder = _Finder([band]);
    var gaveUp = 0;
    late NightRecorder r;
    r = NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: timing(1 << 40, awayCheckEvery: _ms * 20),
      watch: null,
      clock: clock,
      spanLog: SpanLog(spansDirFor(dir.path), clock: clock),
      onGiveUp: () {
        gaveUp++;
        r.stop();
      },
    );
    final running = r.run(restartedBySystem: false);
    await waitFor(() => band.emitted > 20, what: 'for the recording');
    final lastData = now;
    band.goOutOfRange();
    await waitFor(() => logs().contains('drop (out of range)'), what: 'for the drop');
    // 11 minutes: stage C, the waiting connect is open and the recorder waits inside the ladder
    now = now.add(const Duration(minutes: 11));
    await waitFor(() => finder.opened == 1, what: 'for the waiting connect');
    await Future<void>.delayed(_ms * 60);
    expect(statuses.last.rec.spans.single.closed, isFalse, reason: '11 minutes are not 60');
    // an hour after the last data: no loop turn comes (the ladder's next step is 30 s away), the rule still does
    now = now.add(const Duration(minutes: 50));
    await waitFor(() => statuses.last.rec.spans.single.closed, max: const Duration(seconds: 2), what: 'for the 60-minute rule');
    final sleep = statuses.last.rec.spans.single;
    expect((sleep.kind, sleep.endedBy, sleep.end), ('sleep', 'headband_off', lastData));
    expect(finder.opened - finder.closed, 1, reason: 'the waiting connect stays open: the recording still waits');
    expect(gaveUp, 0);
    now = now.add(const Duration(hours: 5));
    await running.timeout(const Duration(seconds: 2), onTimeout: () => fail('the recording did not stop itself after 6 hours'));
    expect(gaveUp, 1);
    expect(finder.closed, 1, reason: 'stopping closed the waiting connect');
    expect(logs(), contains('no data for 6 h: the recording stops itself'));
  });
}
