// A fake headband and finder that count every call, for the one-connection tests: what matters there is which SDK
// calls did NOT happen (no second scan, no second connection, no second contact check).
import 'dart:async';

import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/recorder/headband.dart';

class CountingBand implements Headband {
  CountingBand({this.label = 'A', this.gauge = 80, this.every = const Duration(milliseconds: 10)});
  final String label;
  int gauge;
  final Duration every;
  final List<String> calls = [];
  bool lost = false;
  bool sending = true;
  int emitted = 0;
  int _pack = 0;
  Timer? _timer;

  /// µV of each channel's 10 Hz swing (peak): a loose electrode is a big one.
  List<double> swingUv = [10, 10, 10, 10];
  final _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final _resist = StreamController<Map<String, double>>.broadcast(sync: true);
  final _range = StreamController<bool>.broadcast(sync: true);

  int count(String call) => calls.where((c) => c == call).length;

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
  int? get rssi => -60;
  @override
  BandId get id => BandId(name: name, address: address, serial: serial, family: 'leBrainBitBlack', model: 1);
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resist.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  List<Sample> batch(int n) => [
    for (var i = 0; i < n; i++)
      () {
        final k = _pack++;
        final s = k % 25 < 12 ? 1.0 : -1.0; // a 10 Hz square wave at 250 Hz
        return Sample.four(
          pack: k % 2048,
          o1: swingUv[0] * s * 1e-6,
          o2: swingUv[1] * s * 1e-6,
          t3: swingUv[2] * s * 1e-6,
          t4: swingUv[3] * s * 1e-6,
        );
      }(),
  ];

  @override
  Future<void> startSignal() async {
    calls.add('startSignal');
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) {
      if (!sending || lost) return;
      _signal.add(batch(5));
      emitted += 5;
    });
  }

  @override
  Future<void> stopSignal() async {
    calls.add('stopSignal');
    _timer?.cancel();
  }

  @override
  Future<void> startResist() async {
    calls.add('startResist');
    Timer(const Duration(milliseconds: 5), () => _resist.add({'O1': 1e5, 'O2': 2e5, 'T3': 5e5, 'T4': 1.5e6}));
  }

  @override
  Future<void> stopResist() async => calls.add('stopResist');

  @override
  Future<bool> isInRange() async => !lost;

  @override
  Future<int> battery() async {
    calls.add('battery');
    return gauge;
  }

  @override
  Future<void> disconnectAndDispose() async {
    calls.add('disconnect');
    _timer?.cancel();
  }
}

class CountingFinder implements HeadbandFinder {
  CountingFinder(this.bands);

  /// Handed out one after another, by scans and by direct connections alike.
  final List<Headband> bands;
  final List<String> calls = [];
  int disposed = 0;

  int get scans => calls.where((c) => c == 'scan').length;
  int get directs => calls.where((c) => c == 'direct').length;

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
    calls.add('direct');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (bands.isEmpty) throw StateError('not reached');
    return bands.removeAt(0);
  }
}
