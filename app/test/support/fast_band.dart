// A synthetic headband on a clock of its own, for whole nights through the recorder in a few seconds: each batch is
// [FastBand.perBatch] samples and moves the clock on by their length (the drift-off tests use their own copy).
import 'dart:async';
import 'dart:math' as math;

import 'package:eeg_tracker/recorder/headband.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';

class FastBand implements Headband {
  FastBand({this.perBatch = 250, required this.start});

  final int perBatch;

  /// Unix seconds when the first sample was taken.
  final double start;

  /// Seconds of the headband's clock gone by.
  double clockS = 0;
  int sent = 0;
  int _pack = 0;
  int _i = 0;
  Timer? _timer;

  /// Called before each batch with the clock.
  void Function(double clockS)? onClock;
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast();
  final _range = StreamController<bool>.broadcast();

  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(((start + clockS) * 1e6).round());

  /// A batch as it arrives at [now] (just after its last sample).
  List<Sample> batch() => [
    for (var k = 0; k < perBatch; k++, _i++)
      Sample.four(
        pack: _pack++ % 2048,
        o1: (12000 + 20 * math.sin(_i * 0.25)) * 1e-6,
        o2: (-8000 + 15 * math.cos(_i * 0.1)) * 1e-6,
        t3: (20000 + (_i % 7)) * 1e-6,
        t4: -15000e-6,
      ),
  ];

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
      final b = batch();
      clockS += perBatch / 250;
      sent += perBatch;
      _signal.add(b);
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
  OneFinder(this.band);
  final Headband band;
  bool given = false;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    await Future<void>.delayed(Duration.zero);
    if (given) return null;
    given = true;
    onFound?.call(band.name, -60);
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async => throw StateError('out of range');
}

Future<void> until(bool Function() done, {Duration limit = const Duration(seconds: 90)}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) throw TimeoutException('not reached', limit);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
