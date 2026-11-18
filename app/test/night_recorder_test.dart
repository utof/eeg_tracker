import 'dart:async';
import 'dart:io';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:flutter_test/flutter_test.dart';

/// A headband that sends a 5-sample batch every 10 ms while its signal runs.
class FakeBand implements Headband {
  FakeBand(this.label, {this.hangOn});

  final String label;

  /// An SDK call that never returns, to imitate the wedged SDK.
  final String? hangOn;
  final List<String> calls = [];
  final List<String> callsWhileLost = [];
  bool lost = false;
  bool sending = true;
  int emitted = 0;
  int _pack = 0;
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast();
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  Future<void> _call(String name) async {
    calls.add(name);
    if (lost) callsWhileLost.add(name);
    if (name == hangOn) await Completer<void>().future;
  }

  /// Out of range, as the SDK reports it: the state stream says so and the data stop.
  void goOutOfRange() {
    lost = true;
    _timer?.cancel();
    _range.add(false);
  }

  @override
  String get name => 'BrainBit $label';
  @override
  String get address => 'AA:BB';
  @override
  String get serial => '123';
  @override
  int get rssi => -60;
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  Future<void> startSignal() async {
    await _call('startSignal');
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!sending) return;
      _signal.add([for (var i = 0; i < 5; i++) (pack: _pack++ % 2048, o1: 1e-6, o2: 2e-6, t3: 3e-6, t4: 4e-6)]);
      emitted += 5;
    });
  }

  @override
  Future<void> stopSignal() async {
    await _call('stopSignal');
    _timer?.cancel();
  }

  @override
  Future<void> startResist() async {
    await _call('startResist');
    Timer(
      const Duration(milliseconds: 5),
      () => _resist.add({'O1': 4e5, 'O2': 1.5e6, 'T3': 3e6, 'T4': double.infinity}),
    );
  }

  @override
  Future<void> stopResist() => _call('stopResist');

  @override
  Future<bool> isInRange() async {
    await _call('state');
    return !lost;
  }

  @override
  Future<int> battery() async {
    await _call('battery');
    return 77;
  }

  @override
  Future<void> disconnectAndDispose() async {
    await _call('disconnect');
    _timer?.cancel();
  }
}

class FakeFinder implements HeadbandFinder {
  FakeFinder(this.bands);
  final List<Headband> bands;
  int scans = 0;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    scans++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (bands.isEmpty) return null;
    final b = bands.removeAt(0);
    onFound?.call(b.name, b.rssi);
    return b;
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
);

int f32Records(File f) => f.lengthSync() ~/ recordBytes;

void main() {
  late Directory dir;
  late MemoryNightStore store;
  late List<RecorderStatus> statuses;
  late List<String> stuck;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('night_recorder_test');
    store = MemoryNightStore();
    statuses = [];
    stuck = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  NightRecorder recorder(HeadbandFinder finder) => NightRecorder(
    finder: finder,
    dir: dir,
    store: store,
    onStatus: statuses.add,
    onStuck: (r) async => stuck.add(r),
    timing: fast,
  );

  List<File> files(String ext) =>
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.$ext')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('a normal run: contact check, signal saved, clean stop', () async {
    final band = FakeBand('a');
    final r = recorder(FakeFinder([band]));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;

    expect(band.calls.take(4), ['battery', 'startResist', 'stopResist', 'startSignal']);
    expect(band.calls, containsAllInOrder(['stopSignal', 'disconnect']));
    final f32 = files('f32');
    expect(f32, hasLength(1));
    expect(f32Records(f32.single), band.emitted);
    final log = files('log').single.readAsStringSync();
    expect(log, contains('connected BrainBit a AA:BB serial 123 battery 77% signal -60 dBm'));
    expect(log, contains('contact ohms O1=400000 O2=1500000 T3=3000000 T4=inf'));
    expect(log, contains('recording started, 250 Hz'));
    expect(log, contains('samples '));
    expect(log, contains('total samples ${band.emitted}'));
    expect(store.state.active, isFalse);
    expect(store.state.samples, band.emitted);
    expect(store.state.contactOhms['O1'], 4e5);
    expect(statuses.map((s) => s.phase), containsAllInOrder([Phase.searching, Phase.connecting, Phase.recording]));
    expect(statuses.last.phase, Phase.idle);
  });

  test('a lost headband gets no SDK call; a fresh one gets a new file set and no second contact check', () async {
    final first = FakeBand('a');
    final second = FakeBand('b');
    final finder = FakeFinder([first, second]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await r.stop();
    await running;

    expect(first.callsWhileLost, isEmpty);
    expect(r.abandoned, [first]);
    expect(second.calls, isNot(contains('startResist')));
    expect(second.calls.first, 'battery');
    final f32 = files('f32');
    expect(f32, hasLength(2));
    expect(f32Records(f32[0]), first.emitted);
    expect(f32Records(f32[1]), second.emitted);
    expect(files('log')[0].readAsStringSync(), contains('headband out of range'));
    expect(store.state.runs, 2);
    expect(store.state.samples, first.emitted + second.emitted);
  });

  test('a stalled stream is restarted, then given up for a fresh scan', () async {
    final first = FakeBand('a');
    final second = FakeBand('b');
    final r = recorder(FakeFinder([first, second]));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    first.sending = false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await r.stop();
    await running;

    final log = files('log').first.readAsStringSync();
    expect(log, contains('restarting stream (try 1)'));
    expect(log, contains('still no data; starting over with a fresh scan'));
    // Still in range, so it was stopped and disconnected properly.
    expect(first.calls, containsAllInOrder(['stopSignal', 'startSignal', 'stopSignal', 'disconnect']));
    expect(second.calls, contains('startSignal'));
    expect(files('f32'), hasLength(2));
  });

  test('a blocked SDK call saves the data and asks for a process restart', () async {
    final band = FakeBand('a', hangOn: 'stopSignal');
    final r = recorder(FakeFinder([band]));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    band.sending = false; // a stall makes the recorder call stopSignal, which hangs
    await running.timeout(const Duration(seconds: 3));

    expect(stuck.single, contains('stop signal'));
    expect(f32Records(files('f32').single), band.emitted);
    expect(files('log').single.readAsStringSync(), contains('restarting the app process'));
    expect(store.state.active, isTrue); // the restarted service continues the night
    expect(store.state.samples, band.emitted);
  });

  test('a service restarted by Android continues the night without a new contact check', () async {
    store.state = const NightState(
      active: true,
      startMs: 1000,
      samples: 2500,
      runs: 1,
      contactTried: true,
      contactOhms: {'O1': 5e5},
    );
    final band = FakeBand('a');
    final r = recorder(FakeFinder([band]));
    final running = r.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;

    expect(band.calls, isNot(contains('startResist')));
    expect(
      files('log').single.readAsLinesSync().first,
      endsWith('service restarted by Android after the app process ended'),
    );
    expect(statuses.first.nightSamples, 2500);
    expect(store.state.runs, 2);
    expect(store.state.samples, 2500 + band.emitted);
    expect(store.state.startMs, 1000);
  });

  test('no headband: keeps scanning, writes no files, stops promptly', () async {
    final finder = FakeFinder([]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await r.stop();
    await running.timeout(const Duration(seconds: 1));
    expect(finder.scans, greaterThan(2));
    expect(dir.listSync(), isEmpty);
    expect(statuses.any((s) => s.note.contains('not found')), isTrue);
  });
}
