import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:eeg_tracker/alarm/rule.dart';
import 'package:eeg_tracker/recorder/battery.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/night_recorder.dart';
import 'package:eeg_tracker/recorder/packets.dart';
import 'package:eeg_tracker/recorder/phone_steps.dart';
import 'package:eeg_tracker/recorder/status.dart';
import 'package:flutter_test/flutter_test.dart';

/// A headband that sends a 5-sample batch every 10 ms while its signal runs.
class FakeBand implements Headband {
  FakeBand(this.label, {this.hangOn, this.rssi = -60, bool outOfRange = false, this.packOf}) : lost = outOfRange;

  final String label;

  /// Packet number of the i-th sample sent; default counts up and wraps at 2048 like the headband.
  final int Function(int i)? packOf;

  /// An SDK call that never returns, to imitate the wedged SDK.
  final String? hangOn;
  final List<String> calls = [];
  final List<String> callsWhileLost = [];
  bool lost;
  bool sending = true;
  int emitted = 0;
  int _pack = 0;
  Timer? _timer;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true); // sync: a counted batch is a delivered one
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
  final int? rssi;
  @override
  BandId get id => BandId(name: name, address: address, serial: serial, family: 'leBrainBitBlack', model: 1);
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
      // Only batches someone receives count: one sent after the recorder unsubscribed is lost on a real
      // headband too, and counting it made the sample-count checks fail on a busy machine.
      if (!sending || !_signal.hasListener) return;
      int next() {
        final i = _pack++;
        return packOf == null ? i % 2048 : packOf!(i);
      }

      _signal.add([for (var i = 0; i < 5; i++) Sample.four(pack: next(), o1: 1e-6, o2: 2e-6, t3: 3e-6, t4: 4e-6)]);
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
  FakeFinder(this.bands, {List<Headband>? direct}) : direct = direct ?? [];

  /// Handed out by scans, then by direct connections; each one once.
  final List<Headband> bands;
  final List<Headband> direct;

  /// 'scan' or 'direct AA:BB', in order.
  final List<String> calls = [];

  /// A direct connection that never returns, to imitate the wedged SDK.
  bool hangDirect = false;

  int get scans => calls.where((c) => c == 'scan').length;
  int get directs => calls.where((c) => c.startsWith('direct')).length;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    calls.add('scan');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (bands.isEmpty) return null;
    final b = bands.removeAt(0);
    onFound?.call(b.name, b.rssi ?? 0);
    return b;
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    calls.add('direct ${id.address}');
    if (hangDirect) await Completer<void>().future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (direct.isEmpty) throw StateError('Sensor not founded');
    return direct.removeAt(0);
  }
}

/// Phone battery readings that fall by 100 mAh and 1 % a call, like a phone running on battery.
class FakePhone implements PhoneProbe {
  FakePhone({this.plugged = 'no', this.broken = false});
  final String plugged;
  final bool broken;
  int reads = 0;

  @override
  Future<PhoneBattery?> battery() async {
    reads++;
    if (broken) throw StateError('no battery service');
    return PhoneBattery(
      percent: 90 - reads,
      chargeUah: 4000000 - reads * 100000,
      currentUa: -300000,
      plugged: plugged,
      tempC: 31.25,
    );
  }

  @override
  Future<String?> powerLine() async => null;

  @override
  Future<List<String>> exitReasons(int sinceMs) async => const [];
}

/// A step counter that has counted [steps] more at every read; [state] is what start() says, [noValue] no sensor event yet.
class FakeSteps implements StepProbe {
  FakeSteps({this.state = 'on', this.noValue = false});
  final String state;
  final bool noValue;
  int starts = 0, reads = 0, stops = 0;

  @override
  Future<String> start() async {
    starts++;
    return state;
  }

  @override
  Future<int?> read() async => noValue ? null : 5000 + 7 * reads++;

  @override
  Future<void> stop() async => stops++;
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
  reconnectWaits: [Duration(milliseconds: 5), Duration(milliseconds: 10), Duration(milliseconds: 20)],
  scanEvery: 3,
  rescanFor: Duration(milliseconds: 20),
  phoneLogEvery: Duration(minutes: 1),
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

  // The drift-off detector is off here: these are the recording's own rules on a wall-clock budget of a few hundred
  // milliseconds, which the detector's first-call JIT warm-up in `flutter test` (about 90 ms) can eat; the phone runs
  // AOT code. live_drift_test.dart runs whole nights through the recorder with it on (every sample still saved).
  NightRecorder recorder(HeadbandFinder finder, {PhoneProbe? probe, DateTime Function()? clock}) => NightRecorder(
    finder: finder,
    probe: probe,
    clock: clock,
    dir: dir,
    store: store,
    onStatus: statuses.add,
    onStuck: (r) async => stuck.add(r),
    timing: fast,
    watch: null,
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

    expect(band.calls.take(5), ['state', 'battery', 'startResist', 'stopResist', 'startSignal']);
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
    expect(second.calls.take(2), ['state', 'battery']);
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
    expect(log, contains('still no data; reconnecting'));
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

  test('after a drop the same headband is reached directly, without a scan', () async {
    final first = FakeBand('a');
    final again = FakeBand('a again', rssi: null); // a direct connection has no scan, so no signal reading
    final finder = FakeFinder([first], direct: [again]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await r.stop();
    await running;

    expect(finder.calls, ['scan', 'direct AA:BB']);
    expect(first.callsWhileLost, isEmpty);
    expect(r.abandoned, [first]);
    expect(again.calls, contains('startSignal'));
    expect(again.calls, isNot(contains('startResist')));
    final logs = files('log');
    expect(logs, hasLength(2));
    final before = logs[0].readAsStringSync();
    expect(before, contains('drop (out of range); last data '));
    expect(before, contains('reconnect try 1 (direct to AA:BB): connected'));
    expect(logs[1].readAsStringSync(), contains('reconnected (direct, try 1) after a drop'));
    expect(logs[1].readAsStringSync(), contains('signal unknown (no scan)'));
    expect(store.state.band?.address, 'AA:BB');
    expect(store.state.directPending, isFalse);
  });

  test('failed direct tries back off, every third try is a scan, each try is logged', () async {
    final first = FakeBand('a');
    final second = FakeBand('b');
    final finder = FakeFinder([first, second]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;

    expect(finder.calls, ['scan', 'direct AA:BB', 'direct AA:BB', 'scan']);
    expect(second.calls, contains('startSignal'));
    final log = files('log')[0].readAsStringSync();
    expect(log, contains('reconnect try 1 (direct to AA:BB): failed after '));
    expect(log, contains('Sensor not founded'));
    expect(log, contains('reconnect try 2 (direct to AA:BB): failed'));
    expect(log, contains('reconnect try 3 (scan): connected'));
    expect(files('f32'), hasLength(2));
  }, tags: 'realtime');

  test('a headband that answers but reports out of range gets only the state read', () async {
    final first = FakeBand('a');
    final ghost = FakeBand('ghost', outOfRange: true);
    final again = FakeBand('a again');
    final finder = FakeFinder([first], direct: [ghost, again]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await r.stop();
    await running;

    expect(ghost.calls, ['state']);
    expect(r.abandoned, [first, ghost]);
    expect(again.calls, contains('startSignal'));
    expect(files('log')[0].readAsStringSync(), contains('reports out of range; left alone'));
  });

  test('a direct connection that blocks marks direct connections unsafe for the restarted process', () async {
    final first = FakeBand('a');
    final finder = FakeFinder([first])..hangDirect = true;
    final r = recorder(finder);
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await running.timeout(const Duration(seconds: 3));

    expect(stuck.single, contains('direct connect'));
    expect(store.state.active, isTrue);
    expect(store.state.directPending, isTrue);
  });

  test('a direct connection stays marked unsafe-if-we-crash until its first data', () async {
    final first = FakeBand('a');
    final silent = FakeBand('silent', rssi: null)..sending = false;
    final r = recorder(FakeFinder([first], direct: [silent]));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.goOutOfRange();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(silent.calls, contains('startSignal'));
    expect(store.state.directPending, isTrue);
    silent.sending = true;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(store.state.directPending, isFalse);
    await r.stop();
    await running;
  });

  test('a night begun through our own connection and continued with the SDK scans at once, not every third try', () async {
    // The switch was moved during the night and the process restarted: the saved headband has no SDK sensor family.
    store.state = const NightState(
      active: true,
      startMs: 1000,
      runs: 1,
      contactTried: true,
      band: BandId(name: 'BB Black', address: 'AA:BB', serial: '123', family: 'own'),
    );
    final band = FakeBand('a');
    final finder = _SdkLikeFinder([band]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;

    expect(finder.calls, ['direct AA:BB', 'scan']);
    expect(band.calls, contains('startSignal'));
    final log = files('log').single.readAsStringSync();
    expect(
      log,
      contains(
        "reconnect try 1 (direct to AA:BB): the night's headband was reached through our own connection; BrainBit's "
        'SDK needs a scan first; scanning instead',
      ),
    );
    expect(log, contains('reconnect try 1 (scan): connected'));
    expect(store.state.band?.family, 'leBrainBitBlack', reason: 'the next drop goes direct again');
    expect(store.state.directPending, isFalse);
  });

  test('a process that died during a direct connection scans only', () async {
    store.state = const NightState(
      active: true,
      startMs: 1000,
      samples: 2500,
      runs: 1,
      contactTried: true,
      band: BandId(name: 'BrainBit a', address: 'AA:BB', serial: '123', family: 'leBrainBitBlack', model: 1),
      directPending: true,
    );
    final band = FakeBand('a');
    final finder = FakeFinder([band], direct: [FakeBand('never')]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;

    expect(finder.directs, 0);
    expect(finder.scans, 1);
    expect(store.state.directOff, isTrue);
    expect(files('log').single.readAsStringSync(), contains('scans only for the rest of the night'));
  });

  test('a restarted process tries the known headband directly first', () async {
    store.state = const NightState(
      active: true,
      startMs: 1000,
      runs: 1,
      contactTried: true,
      band: BandId(name: 'BrainBit a', address: 'AA:BB', serial: '123', family: 'leBrainBitBlack', model: 1),
    );
    final band = FakeBand('a');
    final finder = FakeFinder([], direct: [band]);
    final r = recorder(finder);
    final running = r.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;

    expect(finder.calls, ['direct AA:BB']);
    expect(band.calls, contains('startSignal'));
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

  test('phone battery: a line every minute and a drain summary at the end of the night', () async {
    // The recorder's clock runs 3600 times faster than the wall clock: 0.4 s is 24 minutes.
    final t0 = DateTime(2026, 11, 18, 23);
    final sw = Stopwatch()..start();
    final phone = FakePhone();
    final r = recorder(
      FakeFinder([FakeBand('a')]),
      probe: phone,
      clock: () => t0.add(Duration(milliseconds: sw.elapsedMilliseconds * 3600)),
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;

    final log = files('log').single.readAsStringSync();
    final lines = RegExp(r'phone battery (\d+)% charge (\d+) uAh current -300000 uA unplugged temp 31\.3 C')
        .allMatches(log);
    expect(lines.length, greaterThanOrEqualTo(3)); // at connect, then each due check, then the last one at Stop
    expect(log, contains('phone battery summary: '));
    final m = RegExp(r'summary: (\d+)% in ([\d.]+) h = ([\d.]+) %/h, (\d+) mAh = (\d+) mAh/h').firstMatch(log);
    expect(m, isNotNull, reason: log);
    expect(int.parse(m!.group(1)!), phone.reads - 1);
    expect(int.parse(m.group(4)!), (phone.reads - 1) * 100);
    expect(log, isNot(contains('charger was connected')));
    expect(store.state.phoneBattery.first!.percent, 89);
  });

  test('phone battery: a charger is said in the summary', () async {
    final t0 = DateTime(2026, 11, 18, 23);
    final sw = Stopwatch()..start();
    final r = recorder(
      FakeFinder([FakeBand('a')]),
      probe: FakePhone(plugged: 'usb'),
      clock: () => t0.add(Duration(milliseconds: sw.elapsedMilliseconds * 3600)),
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;
    expect(files('log').single.readAsStringSync(), contains('plugged usb'));
    expect(files('log').single.readAsStringSync(), contains('a charger was connected at some point'));
  });

  test('phone battery: a broken battery service costs the lines, not the recording', () async {
    final broken = FakeBand('b');
    final r = recorder(FakeFinder([broken]), probe: FakePhone(broken: true));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await r.stop();
    await running;
    final log = files('log').single.readAsStringSync();
    expect(log, contains('phone battery summary: no readings'));
    expect(log, contains('total samples ${broken.emitted}')); // recording went on
  });

  Future<String> logWithSteps(StepProbe steps) async {
    // The recorder's clock runs 3600 times faster than the wall clock: 0.4 s is 24 minutes.
    final t0 = DateTime(2026, 11, 18, 23);
    final sw = Stopwatch()..start();
    final r = NightRecorder(
      finder: FakeFinder([FakeBand('a')]),
      stepProbe: steps,
      clock: () => t0.add(Duration(milliseconds: sw.elapsedMilliseconds * 3600)),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: fast,
      watch: null,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;
    return files('log').single.readAsStringSync();
  }

  test('phone steps: the counter is set up once, then one line per clock minute, in the format the readers parse', () async {
    final steps = FakeSteps();
    final log = await logWithSteps(steps);
    expect('phone step counter: on'.allMatches(log), hasLength(1));
    final lines = RegExp(r'^\S+ phone steps (\d+)\s*$', multiLine: true).allMatches(log).toList();
    expect(lines.length, greaterThanOrEqualTo(3));
    expect(lines.length, steps.reads);
    expect(int.parse(lines.first.group(1)!), 5000);
    expect(RegExp(r'^\S+ phone step counter: (.+?)\s*$', multiLine: true).firstMatch(log)!.group(1), 'on');
    expect(steps.starts, 1);
    expect(steps.stops, 1);
  });

  test('phone steps: no sensor event yet, no lines', () async {
    final log = await logWithSteps(FakeSteps(noValue: true));
    expect(log, contains('phone step counter: on'));
    expect(log, isNot(contains('phone steps')));
  });

  test('phone steps: no permission and the switch off are said once and read nothing', () async {
    for (final state in ['no permission', 'off', 'no sensor']) {
      final steps = FakeSteps(state: state);
      final log = await logWithSteps(steps);
      expect(log, contains('phone step counter: $state'));
      expect(log, isNot(contains('phone steps')));
      expect(steps.reads, 0);
      for (final f in dir.listSync()) {
        f.deleteSync();
      }
    }
  });

  test('phone steps: without a step probe the log says nothing about it', () async {
    final r = recorder(FakeFinder([FakeBand('a')]));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;
    expect(files('log').single.readAsStringSync(), isNot(contains('phone step')));
  });

  test('packet accounting: counted over the night, logged every 10 minutes, at run end and night end', () async {
    // 20 samples in order, a gap of 3 numbers, 20 more, a repeated number, then in order.
    int pack(int i) => i < 20 ? i : (i < 40 ? i + 3 : i + 2);
    final t0 = DateTime(2026, 11, 18, 23);
    final sw = Stopwatch()..start();
    final r = recorder(
      FakeFinder([FakeBand('a', packOf: pack)]),
      clock: () => t0.add(Duration(milliseconds: sw.elapsedMilliseconds * 3600)), // 0.4 s is 24 minutes
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await r.stop();
    await running;

    final log = files('log').single.readAsStringSync();
    expect(RegExp('packets: ').allMatches(log).length, greaterThanOrEqualTo(3), reason: log);
    expect(log, contains('missing 3 in 1 gaps, repeated 1, longest gap 3 samples'));
    expect(log, contains('end of night, packets: '));
    expect(store.state.packets.missing, 3);
    expect(store.state.packets.repeated, 1);
    expect(store.state.packets.longestGap, 3);
  });

  test('a write error (storage full) ends that run only: the night goes on in a new file set', () async {
    // The first run's .idx is a device that is always full (ENOSPC on every write), as a phone out of storage.
    final t0 = DateTime(2026, 11, 19, 23);
    final sw = Stopwatch()..start();
    Link('${dir.path}/${fileStem(t0)}.idx').createSync('/dev/full');
    final first = FakeBand('a');
    final second = FakeBand('b');
    final r = recorder(FakeFinder([first], direct: [second]), clock: () => t0.add(sw.elapsed));
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(r.finished, isFalse, reason: 'an IO error must never end the night');
    await r.stop();
    await running;

    final f32 = files('f32');
    expect(f32, hasLength(2));
    expect(f32[0].lengthSync() % recordBytes, 0);
    expect(f32Records(f32[1]), greaterThan(0));
    expect(f32Records(f32[1]), second.emitted);
    expect(first.calls, containsAllInOrder(['stopSignal', 'disconnect'])); // let go properly: it was in range
    expect(files('log').first.readAsStringSync(), contains('unexpected error'));
    expect(store.state.active, isFalse);
  });

  test('a night store that cannot save costs one log line, not the recording', () async {
    final band = FakeBand('a');
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: _BrokenStore(),
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: fast,
      watch: null,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(r.finished, isFalse);
    await r.stop();
    await running;
    expect(f32Records(files('f32').single), band.emitted);
    expect(band.emitted, greaterThan(0));
    expect(RegExp('could not save the night state').allMatches(files('log').single.readAsStringSync()), hasLength(1));
  });

  test('Lights off and Alarm off that come before the night is set up are kept, not lost', () async {
    // The service hands them over in the first moments of a start, before run() has loaded the saved night.
    final end = DateTime.now().add(const Duration(hours: 8)).millisecondsSinceEpoch;
    final band = FakeBand('a');
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: fast,
      watch: null,
      alarmPlan: AlarmPlan(endMs: end, windowMin: 30),
    );
    final at = DateTime.now();
    r.lightsOff(at: at);
    r.alarmOff();
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(r.status.lightsOffMs, at.millisecondsSinceEpoch);
    await r.stop();
    await running;

    expect(store.state.lightsOffMs, at.millisecondsSinceEpoch);
    expect(store.state.alarmOff, isTrue);
    expect(store.state.alarmEndMs, end);
    final log = files('log').single.readAsStringSync();
    expect(RegExp(r' lights off\n').allMatches(log), hasLength(1), reason: log);
    expect(log, contains('smart alarm: turned off'));
  });

  test('two quick saves of the night state land in the order they were made', () async {
    // SharedPreferences commits on a pool of threads: a save started first may finish last.
    final slow = _OrderStore();
    final r = NightRecorder(
      finder: FakeFinder([]),
      dir: dir,
      store: slow,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: fast,
      watch: null,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    slow.delays = [const Duration(milliseconds: 150), Duration.zero];
    final t1 = DateTime(2026, 11, 19, 23), t2 = DateTime(2026, 11, 19, 23, 1);
    r.lightsOff(at: t1);
    r.lightsOff(at: t2);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(slow.state.lightsOffMs, t2.millisecondsSinceEpoch, reason: 'an older state landed last');
    await r.stop();
    await running;
  });

  test('the saved sample count never counts a run twice (a save while the run is being closed)', () async {
    final saves = _KeepingStore();
    final first = _SlowBand('a');
    late final NightRecorder r;
    first.onStop = () => r.lightsOff(); // a save from outside the loop, while the run is closed
    r = NightRecorder(
      finder: FakeFinder([first]),
      dir: dir,
      store: saves,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: fast,
      watch: null,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    first.sending = false; // a stall: the run ends with the headband still in range, so it is stopped properly
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await r.stop();
    await running;

    final total = f32Records(files('f32').single);
    expect(total, greaterThan(0));
    expect(files('log').single.readAsStringSync(), contains('still no data; reconnecting'));
    expect(saves.saved.map((s) => s.samples).reduce(max), lessThanOrEqualTo(total));
    expect(saves.state.samples, total);
  });

  test('Stop that cannot wait for the run still saves its samples, counted once', () async {
    const slowSdk = RecorderTiming(
      tick: Duration(milliseconds: 10),
      ticksPerCheck: 5,
      scanFor: Duration(milliseconds: 20),
      contactFor: Duration(milliseconds: 20),
      settle: Duration(milliseconds: 5),
      retryWait: Duration(milliseconds: 5),
      sdkTimeout: Duration(seconds: 1),
      connectTimeout: Duration(milliseconds: 300),
      stopTimeout: Duration(milliseconds: 100), // on the phone 20 s, under the SDK's 30 s
      phoneLogEvery: Duration(minutes: 1),
    );
    final band = _SlowBand('a');
    final r = NightRecorder(
      finder: FakeFinder([band]),
      dir: dir,
      store: store,
      onStatus: statuses.add,
      onStuck: (r) async => stuck.add(r),
      timing: slowSdk,
      watch: null,
    );
    final running = r.run(restartedBySystem: false);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    band.hangBattery = true; // the next 10 s check blocks in the battery read
    final reads = band.calls.where((c) => c == 'battery').length;
    while (band.calls.where((c) => c == 'battery').length == reads) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await r.stop();
    final records = f32Records(files('f32').single);
    expect(records, greaterThan(0));
    expect(store.state.samples, records, reason: 'Stop closed the files, so the saved night must hold their samples');
    await running;
    expect(store.state.samples, records);
  });

  test('packet accounting: a restarted process continues the night\'s counts; a new run is not compared', () async {
    store.state = const NightState(
      active: true,
      startMs: 1000,
      runs: 1,
      contactTried: true,
      band: BandId(name: 'BrainBit a', address: 'AA:BB', serial: '123', family: 'leBrainBitBlack', model: 1),
      packets: PacketCounts(samples: 1000, missing: 5, gaps: 2, repeated: 1, longestGap: 4),
    );
    // The headband restarts its counter at 1500 on the new connection: no gap against the earlier run.
    final r = recorder(FakeFinder([], direct: [FakeBand('a', packOf: (i) => 1500 + i)]));
    final running = r.run(restartedBySystem: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await r.stop();
    await running;
    expect(store.state.packets.missing, 5);
    expect(store.state.packets.longestGap, 4);
    expect(store.state.packets.samples, greaterThan(1000));
  });
}

class _BrokenStore implements NightStore {
  @override
  Future<NightState> load() async => throw StateError('no preferences');

  @override
  Future<void> save(NightState state) async => throw StateError('no preferences');
}

/// Saves that each wait their own time (the next of [delays], then none) before they land, like commits on a pool of
/// threads.
class _OrderStore implements NightStore {
  NightState state = const NightState();
  List<Duration> delays = const [];

  @override
  Future<NightState> load() async => state;

  @override
  Future<void> save(NightState s) async {
    final wait = delays.isEmpty ? Duration.zero : delays.first;
    if (delays.isNotEmpty) delays = delays.sublist(1);
    await Future<void>.delayed(wait);
    state = s;
  }
}

/// Keeps every state saved.
class _KeepingStore extends MemoryNightStore {
  final List<NightState> saved = [];

  @override
  Future<void> save(NightState s) async {
    saved.add(s);
    await super.save(s);
  }
}

/// [onStop] runs as the signal is stopped, which takes a moment; with [hangBattery] the battery read never returns.
class _SlowBand extends FakeBand {
  _SlowBand(super.label);
  void Function()? onStop;
  bool hangBattery = false;

  @override
  Future<void> stopSignal() async {
    onStop?.call();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await super.stopSignal();
  }

  @override
  Future<int> battery() async {
    if (hangBattery) {
      calls.add('battery');
      await Completer<void>().future;
    }
    return super.battery();
  }
}

/// BrainBit's SDK as the finder sees it: it cannot reach a headband directly by an id our own connection made.
class _SdkLikeFinder extends FakeFinder {
  _SdkLikeFinder(super.bands);

  @override
  Future<Headband> connectDirect(BandId id) async {
    if (id.family != 'own') return super.connectDirect(id);
    calls.add('direct ${id.address}');
    throw NeedsScan("the night's headband was reached through our own connection; BrainBit's SDK needs a scan first");
  }
}
