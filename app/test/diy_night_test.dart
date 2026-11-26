// A night on the DIY board through the app's own night recorder (recorder/night_recorder.dart), the way the
// recorder's service runs it (headband/diy/night.dart): the fake board streams E9 datagrams; the files are the
// laptop's DIY layout in their own folder; the log says what the board is and that it is not EEG; a board restart
// and a new mode each start a new file set; damage and losses are counted, never filled; the contact check, the
// drift-off detector, the smart alarm's model, the lucid cues and the live sleep model they share are never given the
// board's samples.
@Tags(['realtime'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/alarm/live_alarm.dart';
import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/headband/diy/board.dart';
import 'package:eeg_tracker/headband/diy/night.dart';
import 'package:eeg_tracker/headband/diy/settings.dart';
import 'package:eeg_tracker/headband/reconnect_ladder.dart' show ladderWaitAfter;
import 'package:eeg_tracker/lucid/live_cues.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/header.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/live_drift.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/nights.dart' show nightsIn;
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/night_scorer.dart';
import 'package:eeg_tracker/sleep/night_signal.dart' show joinLayout;
import 'package:eeg_tracker/wearer/wearer.dart' show refreshWearer;
import 'package:flutter_test/flutter_test.dart';

import 'diy/fake_board.dart';

const _ms = Duration(milliseconds: 1);

/// The DIY night's rules (diyRecorderTiming) at test speed.
const fastNight = RecorderTiming(
  tick: Duration(milliseconds: 10),
  ticksPerCheck: 30,
  scanFor: Duration(milliseconds: 300),
  rescanFor: Duration(milliseconds: 300),
  connectTimeout: Duration(seconds: 2),
  sdkTimeout: Duration(seconds: 2),
  notFoundWait: Duration(milliseconds: 5),
  notFoundWaitLong: Duration(milliseconds: 5),
  reconnectWaits: [Duration(milliseconds: 5), Duration(milliseconds: 20)],
  scanEvery: 1,
  stallChecksToGiveUp: 3,
  stopTimeout: Duration(seconds: 2),
  contactFor: Duration(milliseconds: 40),
  settle: Duration(milliseconds: 5),
  retryWait: Duration(milliseconds: 5),
);

const fastBoard = DiyTiming(flushEvery: Duration(milliseconds: 8), notesEvery: Duration(milliseconds: 50), directWait: Duration(milliseconds: 300));

class SpyDrift implements DriftWatch {
  int adds = 0;
  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) => adds++;
  @override
  void lightsOff(DateTime at) {}
  @override
  List<String> takeEvents() => const [];
  @override
  DriftLive? get live => null;
  @override
  int get samples => 0;
}

class SpyAlarm implements AlarmWatch {
  int adds = 0;
  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) => adds++;
  @override
  void check(DateTime now) {}
  @override
  List<String> takeEvents() => const [];
  @override
  AlarmLive get live => const AlarmLive(phase: AlarmPhase.scoring);
  @override
  bool get finished => false;
  @override
  Future<void> close() async {}
}

class SpyCues implements CueWatch {
  int adds = 0, checks = 0;
  bool closed = false;
  @override
  String get who => 'lucid cues';
  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) => adds++;
  @override
  void check(DateTime now, {int? lightsOffMs, String? drift}) => checks++;
  @override
  List<String> takeEvents() => const [];
  @override
  bool get finished => false;
  @override
  Future<void> close() async => closed = true;
}

/// The night's shared live model, counting what reaches it; it can never open a model.
class SpyScorer extends NightScorer {
  SpyScorer() : super(model: () => throw StateError('no model for the DIY board'));
  int adds = 0;
  bool closed = false;
  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) => adds++;
  @override
  Future<void> close() async => closed = true;
}

/// The board streaming in real time (2 frames every 8 ms), with faults by hand.
class Pump {
  Pump(this.link, this.board);
  final FakeLink link;
  final FakeBoard board;
  Timer? _t;
  int corruptEvery = 0, loseEvery = 0, n = 0;

  void start() => _t = Timer.periodic(_ms * 8, (_) {
    for (final f in board.next(2)) {
      n++;
      if (loseEvery > 0 && n % loseEvery == 0) continue;
      final d = Uint8List.fromList(f);
      if (corruptEvery > 0 && n % corruptEvery == 0) d[30] ^= 0x10;
      link.send(d);
    }
  });

  void stop() => _t?.cancel();
}

Future<void> waitFor(bool Function() done, {Duration max = const Duration(seconds: 10)}) async {
  final t0 = DateTime.now();
  while (!done()) {
    if (DateTime.now().difference(t0) > max) fail('timed out waiting');
    await Future<void>.delayed(_ms * 10);
  }
}

/// (sequence, CH1..CH4 volts) of every record in a `.f32`.
List<(int, List<double>)> records(File f) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  return [
    for (var o = 0; o + recordBytes <= b.lengthInBytes; o += recordBytes)
      (b.getUint32(o, Endian.little), [for (var c = 0; c < 4; c++) b.getFloat32(o + 4 + 4 * c, Endian.little)]),
  ];
}

void main() {
  late Directory root;
  late FakeLink link;
  late FakeBoard board;
  late Pump pump;
  late List<RecorderStatus> statuses;

  setUp(() {
    root = Directory.systemTemp.createTempSync('diy_night');
    link = FakeLink();
    board = FakeBoard();
    pump = Pump(link, board);
    statuses = [];
  });

  tearDown(() {
    pump.stop();
    root.deleteSync(recursive: true);
  });

  NightRecorder recorder(
    DiyFinder finder,
    Directory dir, {
    DriftWatch Function()? watch,
    AlarmPlan? plan,
    AlarmWatch Function(AlarmPlan)? alarm,
    CueFactory? cues,
    NightScorer? scorer,
    List<String> notes = const [],
  }) =>
      NightRecorder(
        finder: finder,
        dir: dir,
        store: MemoryNightStore(),
        onStatus: statuses.add,
        onStuck: (_) async => fail('nothing may get stuck'),
        timing: fastNight,
        watch: watch,
        alarmPlan: plan,
        alarm: alarm,
        cues: cues,
        scorer: scorer,
        startNotes: notes,
      );

  List<String> stems(Directory dir) =>
      [for (final f in dir.listSync().whereType<File>()) if (f.path.endsWith('.f32')) f.path.substring(0, f.path.length - 4)]..sort();

  test('the service\'s plan: its own folder, its own finder and timing, no detectors', () {
    final rec = '${root.path}/files/recordings';
    final plan = DiyNight(const DiyBoardSettings(useDiy: true, names: ['A1', 'A2', 'A3', 'A4']), rec);
    expect(plan.dir.path, '${root.path}/files/recordings-diy');
    expect(plan.finder().names, ['A1', 'A2', 'A3', 'A4']);
    expect(diyRecorderTiming.scanEvery, 1); // every try listens; there is no "direct" for a UDP board
    expect(diyRecorderTiming.connectTimeout, greaterThan(const DiyTiming().directWait)); // a long wait is never "stuck"
    expect(diyRecorderTiming.scanFor + diyRecorderTiming.connectTimeout, greaterThan(diyRecorderTiming.scanFor));
    expect(diyRecorderTiming.reconnectWaits.last, lessThanOrEqualTo(const Duration(seconds: 1)));
    // listening for datagrams costs no radio: the ladder's long waits (stage C) never begin for the board
    expect(diyRecorderTiming.ladder.waitAfter, greaterThan(const Duration(days: 365)));
    expect(const RecorderTiming().ladder.waitAfter, ladderWaitAfter);
    expect(plan.notes.join('\n'), contains("off for the DIY board: they read BrainBit's O1 O2 T3 T4"));
    expect(plan.notes.join('\n'), contains('the lucid cues and the live sleep model they share'));
  });

  test('the service asks the setting once: the board when it is on, the BrainBit when off or damaged', () {
    final rec = '${root.path}/files/recordings';
    expect(diyNightFor(rec), isNull); // no file: the BrainBit
    final store = DiyBoardStore(diyBoardDirFor(rec));
    store.save(const DiyBoardSettings(useDiy: true));
    expect(diyNightFor(rec)?.dir.path, '${root.path}/files/recordings-diy');
    expect(diyNightFor(rec)?.settings.names, defaultDiyNames);
    store.save(const DiyBoardSettings());
    expect(diyNightFor(rec), isNull);
    store.file.writeAsStringSync('[1, 2');
    expect(diyNightFor(rec), isNull);
  });

  test('a night on the board: its own folder, the laptop\'s layout, its lines, no contact check, no detectors', () async {
    final dir = Directory('${root.path}/files/recordings-diy');
    final drift = SpyDrift();
    final alarm = SpyAlarm();
    final now = DateTime.now().millisecondsSinceEpoch;
    final finder = DiyFinder(link: () => link, timing: fastBoard, names: const ['O1', 'O2', 'Fz', 'Fp1']);
    final r = recorder(
      finder,
      dir,
      notes: DiyNight(const DiyBoardSettings(useDiy: true), '${root.path}/files/recordings').notes,
      watch: () => drift,
      plan: AlarmPlan(endMs: now + 30 * 60000, windowMin: 30),
      alarm: (_) => alarm,
    );
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording && r.status.nightSamples + 0 >= 0 && statuses.any((s) => s.board != null));
    await Future<void>.delayed(_ms * 700);
    r.lightsOff(); // a marker only: the detector does not start for this board
    await Future<void>.delayed(_ms * 100);
    await r.stop();
    await run;
    finder.dispose();
    final sets = stems(dir);
    expect(sets, hasLength(1));
    final recs = records(File('${sets.single}.f32'));
    expect(recs.length, greaterThan(100));
    expect([for (final r in recs) r.$1], [for (var i = 0; i < recs.length; i++) recs.first.$1 + i]); // nothing lost, nothing filled
    final lsb = 4.5 / (24 * 8388608);
    for (final (seq, v) in recs.take(300)) {
      final want = board.codes(seq)[0] * lsb;
      expect(v, everyElement(closeTo(want, 1e-9)));
    }
    final log = File('${sets.single}.log').readAsStringSync();
    expect(log, contains('driver DIY board (lib/headband/diy): eeg_ads1299_lab bench firmware, E9 protocol version 1'));
    expect(log, contains('connected DIY board udp:9000 (no battery or signal-strength reading from this board)'));
    expect(log, contains('channels O1 O2 Fz Fp1'));
    expect(log, contains('format .f32 records <I4f: board sequence number, then O1 O2 Fz Fp1 in volts; 250 Hz'));
    expect(log, contains("mode test signal: the chip's own square wave, not EEG (flags 0x01)"));
    expect(log, contains("drift-off detector stopped: it reads BrainBit's O1 O2 T3 T4, not this board's O1 O2 Fz Fp1"));
    expect(log, contains("smart alarm: the sleep model is off with this board (it reads BrainBit's O1 O2 T3 T4)"));
    expect(log, isNot(contains('battery null')));
    expect(log, isNot(contains('contact ohms')));
    expect(log, isNot(contains('contact check')));
    expect(log, contains('lights off'));
    expect(drift.adds, 0);
    // the night's own first lines come before the board's, so the log stays in time order
    expect(log.indexOf('headband: DIY board (test)'), lessThan(log.indexOf('driver DIY board')));
    final times = [for (final l in log.trim().split('\n')) l.substring(0, 23)];
    expect(times, [...times]..sort());
    expect(alarm.adds, 0);
    final live = statuses.lastWhere((s) => s.board != null).board!;
    expect(live.names, ['O1', 'O2', 'Fz', 'Fp1']);
    expect(live.notEeg, isTrue);
    // the screen's map carries the board across the isolate port
    final back = RecorderStatus.fromMap(statuses.last.toMap(nowMs: 0))!;
    expect(back.board?.names, ['O1', 'O2', 'Fz', 'Fp1']);
    expect(back.board?.modeText, contains('not EEG'));
    // never scored, so never asked "Was this you?": the sleep scorer and the check read files/recordings and
    // files/nights, and the board's night is in neither
    final rec = '${root.path}/files/recordings';
    expect(nightsIn(Directory(rec)), isEmpty);
    expect(Directory('${root.path}/files/nights').existsSync(), isFalse);
    final wearer = refreshWearer(rec, DateTime.now());
    expect(wearer.on, isTrue);
    expect(wearer.verdicts, isEmpty);
  });

  test('a night on the 8-channel chip: eight floats a record, a header naming them, the laptop\'s <I8f', () async {
    board = FakeBoard(channels: 8);
    pump = Pump(link, board);
    final dir = Directory('${root.path}/files/recordings-diy');
    final drift = SpyDrift();
    final names = ['Fz', 'Cz', 'Pz', 'O1', 'O2', 'T7', 'T8', 'Oz'];
    final finder = DiyFinder(link: () => link, timing: fastBoard, names: names);
    final r = recorder(finder, dir, watch: () => drift);
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording && statuses.any((s) => s.board != null));
    await Future<void>.delayed(_ms * 500);
    await r.stop();
    await run;
    finder.dispose();
    final sets = stems(dir);
    expect(sets, hasLength(1));
    final f = File('${sets.single}.f32');
    final h = readHeader(f);
    expect(h.source, HeaderSource.file);
    expect(h.names, names);
    expect(h.record, '<I8f');
    expect(h.counter, 'board sequence number');
    expect(h.device, 'DIY board');
    expect(f.lengthSync() % 36, 0);
    final b = ByteData.sublistView(f.readAsBytesSync());
    final n = b.lengthInBytes ~/ 36;
    expect(n, greaterThan(50));
    final lsb = 4.5 / (24 * 8388608);
    final first = b.getUint32(0, Endian.little);
    for (var i = 0; i < n; i++) {
      final seq = b.getUint32(36 * i, Endian.little);
      expect(seq, first + i); // nothing lost, nothing filled
      final want = board.codes(seq)[0] * lsb;
      for (var c = 0; c < 8; c++) {
        expect(b.getFloat32(36 * i + 4 + 4 * c, Endian.little), closeTo(want, 1e-9));
      }
    }
    final log = File('${sets.single}.log').readAsStringSync();
    expect(log, contains('format .f32 records <I8f: board sequence number, then Fz Cz Pz O1 O2 T7 T8 Oz in volts; 250 Hz'));
    expect(log, contains('board 8 channels, 250 Hz'));
    expect(drift.adds, 0); // the board's samples never reach the detectors (row 367), whatever its names
    expect(statuses.lastWhere((s) => s.board != null).board!.names, names);
    // the night readers pick the sleep sites by name from its header: O1 O2 T7 T8 are columns 3 4 5 6
    expect(joinLayout([f]).parts.firstWhere((p) => p.run != null).run!.columns, [3, 4, 5, 6]);
  });

  test('the lucid cues and the live sleep model they share are off before the board\'s first sample', () async {
    final dir = Directory('${root.path}/files/recordings-diy');
    final cues = SpyCues();
    final scorer = SpyScorer();
    final alarm = SpyAlarm();
    final now = DateTime.now().millisecondsSinceEpoch;
    final finder = DiyFinder(link: () => link, timing: fastBoard, names: const ['O1', 'O2', 'Fz', 'Fp1']);
    final r = recorder(
      finder,
      dir,
      plan: AlarmPlan(endMs: now + 30 * 60000, windowMin: 30),
      alarm: (_) => alarm,
      cues: (_) => cues,
      scorer: scorer,
    );
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording && statuses.any((s) => s.board != null));
    await Future<void>.delayed(_ms * 700); // past a 10-second check (30 ticks of 10 ms)
    await r.stop();
    await run;
    finder.dispose();
    expect(cues.adds, 0);
    expect(cues.checks, 0);
    expect(cues.closed, isTrue);
    expect(scorer.adds, 0);
    expect(scorer.closed, isTrue);
    expect(alarm.adds, 0);
    final log = File('${stems(dir).single}.log').readAsStringSync();
    expect(log, contains("lucid cues: off with this board (the sleep model reads BrainBit's O1 O2 T3 T4); no cue plays tonight"));
    expect(log, isNot(contains('live sleep model')));
  });

  test('storage full and a night store that cannot save end one run of the board, never its night', () async {
    // The night pipeline review's protections (DECISIONS 390) on the board's night: its first file set's .idx is a
    // device that is always full, and the night state can never be saved.
    final dir = Directory('${root.path}/files/recordings-diy')..createSync(recursive: true);
    final t0 = DateTime(2026, 11, 19, 23);
    final sw = Stopwatch()..start();
    Link('${dir.path}/${fileStem(t0)}.idx').createSync('/dev/full');
    final finder = DiyFinder(link: () => link, timing: fastBoard);
    final r = NightRecorder(
      finder: finder,
      dir: dir,
      store: _BrokenStore(),
      onStatus: statuses.add,
      onStuck: (_) async => fail('nothing may get stuck'),
      timing: fastNight,
      watch: null,
      clock: () => t0.add(sw.elapsed),
    );
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => stems(dir).length >= 2 && r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 400);
    expect(r.finished, isFalse, reason: 'an IO or store error must never end the night');
    await r.stop();
    await run;
    finder.dispose();
    final sets = stems(dir);
    expect(File('${sets.first}.f32').lengthSync() % recordBytes, 0); // never part of a record
    expect(records(File('${sets.last}.f32')).length, greaterThan(0));
    expect(File('${sets.first}.log').readAsStringSync(), contains('unexpected error'));
    final logs = [for (final s in sets) File('$s.log').readAsStringSync()].join();
    expect(RegExp('could not save the night state').allMatches(logs), hasLength(1));
  });

  test('an early Lights off, saves in order and each run counted once on the board\'s night too', () async {
    // The rest of the night pipeline review (DECISIONS 395-396) on the board's night: a Lights off from the first
    // moments of a start is kept; saves of the night state land in the order made; each run's samples are counted
    // once, across a board restart (two file sets).
    final dir = Directory('${root.path}/files/recordings-diy');
    final finder = DiyFinder(link: () => link, timing: fastBoard);
    final store = _SlowEveryOtherStore();
    final r = NightRecorder(
      finder: finder,
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async => fail('nothing may get stuck'),
      timing: fastNight,
      watch: null,
    );
    final tapped = DateTime.now();
    r.lightsOff(at: tapped); // before run(): the service hands it over as soon as the recorder exists
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording);
    expect(r.status.lightsOffMs, tapped.millisecondsSinceEpoch);
    await Future<void>.delayed(_ms * 300);
    board.restart();
    await waitFor(() => r.status.runs == 2 && r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 300);
    await r.stop();
    await run;
    finder.dispose();
    final sets = stems(dir);
    expect(sets, hasLength(2));
    final total = sets.map((s) => records(File('$s.f32')).length).reduce((a, b) => a + b);
    expect(total, greaterThan(0));
    expect(store.state.lightsOffMs, tapped.millisecondsSinceEpoch);
    expect(store.state.samples, total);
    final counts = [for (final s in store.landed) s.samples];
    expect(counts, [...counts]..sort(), reason: 'an older state landed after a newer one');
    final logs = [for (final s in sets) File('$s.log').readAsStringSync()].join();
    expect(RegExp(r' lights off\n').allMatches(logs), hasLength(1), reason: logs);
  });

  test('a board restart and a new mode: three file sets, never joined', () async {
    final dir = Directory('${root.path}/files/recordings-diy');
    final finder = DiyFinder(link: () => link, timing: fastBoard);
    final r = recorder(finder, dir);
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 300);
    board.restart(); // the DevKit restarted; the owner answered its prompts again
    await waitFor(() => r.status.runs == 2 && r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 300);
    board.restart(mode: 'N'); // ... and chose shorted inputs this time
    await waitFor(() => r.status.runs == 3 && r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 300);
    await r.stop();
    await run;
    finder.dispose();
    final sets = stems(dir);
    expect(sets, hasLength(3));
    final logs = [for (final s in sets) File('$s.log').readAsStringSync()];
    expect(logs[0], matches(RegExp(r'board restarted \(sequence went back from \d+ to 1\): this file set ends here')));
    expect(logs[1], matches(RegExp(r'a new capture: board restarted \(sequence went back from \d+ to 1\)')));
    expect(logs[1], contains('reconnected (scan, try 1)'));
    expect(logs[1], contains('this file set ends here'));
    expect(logs[2], contains('configuration changed from 4 ch 250 Hz gain 24 test to 4 ch 250 Hz gain 24 short'));
    expect(logs[2], contains("mode shorted inputs: the chip's own noise, not EEG (flags 0x02)"));
    final seqs = [for (final s in sets) [for (final r in records(File('$s.f32'))) r.$1]];
    expect(seqs[1].first, 1);
    expect(seqs[2].first, 1);
    for (final q in seqs) {
      for (var i = 1; i < q.length; i++) {
        expect(q[i], greaterThan(q[i - 1])); // each set one capture, in order
      }
    }
    expect(seqs[0].last, greaterThan(seqs[1].last)); // the old capture's numbers never continue in a later set
  });

  test('damage and losses: counted in the log, never filled in', () async {
    final dir = Directory('${root.path}/files/recordings-diy');
    final finder = DiyFinder(link: () => link, timing: fastBoard);
    final r = recorder(finder, dir);
    pump
      ..corruptEvery = 10
      ..loseEvery = 7;
    final run = r.run(restartedBySystem: false);
    pump.start();
    await waitFor(() => r.status.phase == Phase.recording);
    await Future<void>.delayed(_ms * 600);
    await r.stop();
    await run;
    finder.dispose();
    final s = stems(dir).single;
    final log = File('$s.log').readAsStringSync();
    expect(log, matches(RegExp(r'lost \d+ samples in \d+ gaps \(board missed 0, link lost \d+\)')));
    expect(log, matches(RegExp(r'bad datagrams \d+ \(CRC or framing\)')));
    final q = [for (final r in records(File('$s.f32'))) r.$1];
    final missing = q.last - q.first + 1 - q.length;
    expect(missing, greaterThan(0)); // the holes stay holes
    expect(q.toSet().length, q.length);
  });
}

/// Keeps every state as it lands; every other save takes 30 ms first (commits on a pool of threads finish out of order).
class _SlowEveryOtherStore extends MemoryNightStore {
  final List<NightState> landed = [];
  int _n = 0;

  @override
  Future<void> save(NightState s) async {
    if ((_n++).isEven) await Future<void>.delayed(const Duration(milliseconds: 30));
    landed.add(s);
    state = s;
  }
}

class _BrokenStore implements NightStore {
  @override
  Future<NightState> load() async => throw StateError('no preferences');

  @override
  Future<void> save(NightState state) async => throw StateError('no preferences');
}
