// The drift-off detector during the night (lib/recorder/live_drift.dart, DECISIONS 180-184): it runs in the
// recorder's isolate on the batches as they arrive, places them on the clock as the morning's night pass does (so
// both find the same onset), starts again at Lights off, writes its moments as markers, and can never stop the
// recording: a detector that throws or takes too long is switched off with one log line.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eeg_tracker/detectors/drift_off.dart';
import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/live_drift.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:eeg_tracker/sleep/drift.dart';
import 'package:eeg_tracker/sleep/extras.dart';
import 'package:flutter_test/flutter_test.dart';

/// An eyes-closed synthetic headband on a clock of its own: each batch is [perBatch] samples and moves the clock on
/// by their length, so a night's minutes go by in a second. Alpha fades to a quarter from [fadeAtS] (drifting off).
class FastBand implements Headband {
  FastBand({this.fadeAtS = 240, this.perBatch = 125, this.start = 1795468320.25});

  final double fadeAtS;
  final int perBatch;

  /// Unix seconds when the first sample was taken.
  final double start;
  final DemoSignal demo = DemoSignal(5)
    ..eyes = 'closed'
    ..blinks = false
    ..jawBursts = false;

  /// Seconds of the headband's clock gone by (samples sent plus holes).
  double clockS = 0;
  int sent = 0;
  int _pack = 0;
  Timer? _timer;

  /// Called before each batch with the clock: lets a test press Lights off or drop out at a set moment.
  void Function(double clockS)? onClock;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(((start + clockS) * 1e6).round());

  /// [seconds] of the headband's clock with no samples arriving (a Bluetooth hole inside a run).
  void hole(double seconds) {
    clockS += seconds;
    _pack += (seconds * 250).round();
  }

  @override
  String get name => 'BrainBit F';
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
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!_signal.hasListener) return;
      onClock?.call(clockS);
      demo.alphaGain = clockS < fadeAtS ? 1 : 0.25;
      final batch = [
        for (final r in demo.next(perBatch))
          (pack: _pack++ % 2048, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6),
      ];
      clockS += perBatch / 250;
      sent += perBatch;
      _signal.add(batch);
    });
  }

  @override
  Future<void> stopSignal() async => _timer?.cancel();
  @override
  Future<void> startResist() async =>
      Timer(const Duration(milliseconds: 1), () => _resist.add({'O1': 4e5, 'O2': 6e5, 'T3': 1.2e6, 'T4': 1.5e6}));
  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => true;
  @override
  Future<int> battery() async => 80;
  @override
  Future<void> disconnectAndDispose() async => _timer?.cancel();
}

class OneFinder implements HeadbandFinder {
  OneFinder(this.band, {this.delay = Duration.zero});
  final Headband band;
  final Duration delay;
  bool given = false;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(delay);
    if (given) return null;
    given = true;
    onFound?.call(band.name, -60);
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('out of range');
}

/// A detector that fails on its [failAt]-th batch, or spends [slowMs] on every batch.
class BrokenWatch implements DriftWatch {
  BrokenWatch({this.failAt, this.slowMs = 0});
  final int? failAt;
  final int slowMs;
  int batches = 0;

  @override
  void add(DateTime arrival, List<Sample> rows, {bool firstOfFile = false}) {
    if (++batches == failAt) throw StateError('detector broke');
    if (slowMs > 0) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < slowMs) {}
    }
  }

  @override
  void lightsOff(DateTime at) {}
  @override
  List<String> takeEvents() => const [];
  @override
  DriftLive? get live => null;
  @override
  int get samples => batches;
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
  stopTimeout: Duration(seconds: 2),
  reconnectWaits: [Duration(milliseconds: 5)],
  rescanFor: Duration(milliseconds: 20),
);

List<Map<String, dynamic>> markersIn(Directory dir) => [
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.markers.jsonl')))
    for (final l in f.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>,
];

List<File> f32In(Directory dir) =>
    dir.listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).toList()..sort((a, b) => a.path.compareTo(b.path));

Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 60)}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) throw TimeoutException('not reached', limit);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('live_drift_test');
    store = MemoryNightStore();
    statuses = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('LiveDrift on its own', () {
    /// Feeds a FastBand's batches straight into [live] and into a ChunkWriter, as the recorder does.
    Future<File> stream(LiveDrift live, FastBand band, double untilS) async {
      final w = ChunkWriter.open(dir, band.now());
      final sub = band.signal.listen((rows) {
        final first = w.samplesReceived == 0;
        w.addBatch(band.now(), rows);
        live.add(band.now(), rows, firstOfFile: first);
      });
      await band.startSignal();
      await until(() => band.clockS >= untilS);
      await band.stopSignal();
      await sub.cancel();
      w.close();
      return File('${dir.path}/${w.stem}.f32');
    }

    test('lights off counts from the first sample until tapped; the same onset as the morning\'s night pass', () async {
      final live = LiveDrift();
      final band = FastBand(fadeAtS: 240);
      band.onClock = (s) {
        if (s >= 100 && s < 100.5) band.hole(3.2); // a 3.2 s Bluetooth hole inside the run: held, marked missing
      };
      final f = await stream(live, band, 480);
      final d = live.driftOff!;
      expect(d.lightsOff, 0);
      expect(d.onset, isNotNull);
      final night = seeNight([f])!.drift!;
      expect(night.from, LightsOffFrom.nightStart);
      expect((d.baselineDone, d.drowsyAt, d.onset, d.asleepAt), (night.baselineS, night.drowsyS, night.onsetS, night.knownS));
      // live, the newest second waits for the next one (its blinks): at most the last epoch is still open
      expect(night.epochs, startsWith(driftEpochs(d)));
      expect(night.epochs.length - driftEpochs(d).length, lessThanOrEqualTo(1));
      expect(live.live!.state, DriftState.asleep);
      expect(live.live!.lightsOffMs, isNull, reason: 'not tapped');
      expect(live.live!.onsetMs, ((live.startUnix! + d.onset!) * 1000).round());
      final events = live.takeEvents();
      expect(events, [
        'drift-off: eyes-closed baseline done',
        'drift-off: drowsy',
        startsWith('drift-off: probably asleep, onset '),
      ]);
      expect(live.takeEvents(), isEmpty);
    });

    test('Lights off: the detector starts again on the next epoch, as the night pass does from the marker', () async {
      final live = LiveDrift();
      final band = FastBand(fadeAtS: 300);
      DateTime? tapped;
      band.onClock = (s) {
        if (tapped == null && s >= 65) {
          tapped = band.now();
          live.lightsOff(tapped!);
        }
      };
      final f = await stream(live, band, 540);
      File(f.path.replaceFirst('.f32', '.markers.jsonl'))
          .writeAsStringSync('${jsonEncode({'t': unixSeconds(tapped!), 'i': 0, 'text': lightsOffMarker})}\n');
      final d = live.driftOff!;
      final night = seeNight([f])!.drift!;
      expect((night.from, night.lightsOffS), (LightsOffFrom.button, 90));
      expect(d.lightsOff, 90);
      expect((d.baselineDone, d.onset, d.asleepAt), (night.baselineS, night.onsetS, night.knownS));
      expect(night.epochs, startsWith(driftEpochs(d)));
      expect(night.epochs.length - driftEpochs(d).length, lessThanOrEqualTo(1));
      expect(live.live!.lightsOffMs, tapped!.millisecondsSinceEpoch);
    });

    test('Lights off before the first sample counts from the first sample', () {
      final live = LiveDrift();
      final band = FastBand();
      live.lightsOff(band.now().subtract(const Duration(minutes: 2)));
      live.add(band.now().add(const Duration(milliseconds: 500)), [
        for (final r in band.demo.next(125)) (pack: 0, o1: r[0] * 1e-6, o2: r[1] * 1e-6, t3: r[2] * 1e-6, t4: r[3] * 1e-6),
      ], firstOfFile: true);
      expect(live.driftOff!.lightsOff, 0);
      expect(live.live!.state, DriftState.baseline);
    });
  });

  group('in the night recorder', () {
    NightRecorder recorder(
      FastBand band, {
      DriftWatch Function()? watch,
      RecorderTiming timing = fast,
      Duration findAfter = Duration.zero,
    }) => NightRecorder(
      finder: OneFinder(band, delay: findAfter),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (_) async {},
      timing: timing,
      clock: band.now,
      watch: watch ?? LiveDrift.new,
    );

    test('a night with the detector: its moments become markers, the screen sees its state, the log its cost', () async {
      final band = FastBand(fadeAtS: 240);
      final live = LiveDrift();
      final r = recorder(band, watch: () => live);
      band.onClock = (s) {
        if (s >= 65 && r.status.lightsOffMs == null) r.lightsOff();
      };
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 480);
      await until(() => statuses.any((s) => s.drift == DriftState.asleep));
      await r.stop();
      await running;

      final f32 = f32In(dir);
      expect(f32, hasLength(1));
      expect(f32.single.lengthSync() ~/ recordBytes, band.sent, reason: 'every sample saved');
      final texts = [for (final m in markersIn(dir)) m['text']];
      expect(texts, [
        'drift-off: eyes-closed baseline done', // from the first sample, before the tap
        lightsOffMarker,
        'drift-off: eyes-closed baseline done',
        'drift-off: drowsy',
        startsWith('drift-off: probably asleep, onset '),
      ]);
      final night = seeNight(f32)!.drift!;
      expect(night.from, LightsOffFrom.button);
      expect((live.driftOff!.lightsOff, live.driftOff!.onset), (night.lightsOffS, night.onsetS));
      expect(store.state.lightsOffMs, isNotNull);
      final s = statuses.lastWhere((s) => s.drift == DriftState.asleep);
      expect(s.lightsOffMs, store.state.lightsOffMs);
      expect(s.driftOnsetMs, ((live.startUnix! + night.onsetS!) * 1000).round());
      final log = dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.log')).readAsStringSync();
      expect(log, contains('drift-off detector on; lights off counts from the first sample until Lights off'));
      expect(log, contains('lights off'));
      expect(log, matches(RegExp(r'drift-off detector: [0-9.]+ s of work for [0-9.]+ h of signal')));
    });

    test('a detector that throws is switched off with one log line; the recording goes on', () async {
      final band = FastBand();
      final r = recorder(band, watch: () => BrokenWatch(failAt: 20));
      final running = r.run(restartedBySystem: false);
      await until(() => band.clockS >= 60);
      await r.stop();
      await running;

      expect(f32In(dir).single.lengthSync() ~/ recordBytes, band.sent, reason: 'every sample saved');
      final log = dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.log')).readAsStringSync();
      expect(RegExp('drift-off detector stopped').allMatches(log), hasLength(1));
      expect(log, contains('detector broke; the recording goes on'));
      expect(statuses.last.drift, isNull);
      expect(store.state.samples, band.sent);
    });

    test('a detector that takes too long is switched off', () async {
      final band = FastBand(perBatch: 250);
      final r = recorder(
        band,
        watch: () => BrokenWatch(slowMs: 3),
        timing: const RecorderTiming(
          tick: Duration(milliseconds: 10),
          ticksPerCheck: 5,
          scanFor: Duration(milliseconds: 20),
          contactFor: Duration(milliseconds: 20),
          settle: Duration(milliseconds: 5),
          sdkTimeout: Duration(milliseconds: 300),
          stopTimeout: Duration(seconds: 2),
          driftBudget: 0.05,
          driftBudgetAfter: Duration(milliseconds: 200),
        ),
      );
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.isNotEmpty && statuses.last.phase == Phase.recording);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await r.stop();
      await running;
      final log = dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.log')).readAsStringSync();
      expect(log, contains('drift-off detector stopped: it took'));
      expect(f32In(dir).single.lengthSync() ~/ recordBytes, band.sent);
    });

    test('Lights off while the headband is still being found is written into the first run', () async {
      final band = FastBand();
      final r = recorder(band, findAfter: const Duration(milliseconds: 100));
      final running = r.run(restartedBySystem: false);
      await until(() => statuses.isNotEmpty && statuses.last.phase == Phase.searching);
      r.lightsOff(); // nothing recorded yet
      await until(() => band.clockS >= 5);
      await r.stop();
      await running;
      final m = markersIn(dir);
      expect([for (final x in m) x['text']], contains(lightsOffMarker));
      expect(m.first['t'], lessThanOrEqualTo(band.start));
    });

    test('after Android restarts the service the detector waits for the next Lights off', () async {
      store.state = NightState(active: true, startMs: 1, lightsOffMs: 1795468000000);
      final band = FastBand();
      final r = recorder(band);
      final running = r.run(restartedBySystem: true);
      await until(() => band.clockS >= 20);
      expect(statuses.last.drift, isNull);
      expect(statuses.last.lightsOffMs, 1795468000000, reason: 'the screen still shows when it was tapped');
      r.lightsOff();
      await until(() => band.clockS >= 30);
      expect(statuses.last.drift, DriftState.baseline);
      await r.stop();
      await running;
      final log = dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.log')).readAsStringSync();
      expect(log, contains('drift-off detector off after the restart; it starts again at Lights off'));
    });
  });
}
