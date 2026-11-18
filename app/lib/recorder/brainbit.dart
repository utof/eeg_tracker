// BrainBit (and BrainBit Black) through BrainBit's neurosdk2 plugin. Used only inside the recorder
// isolate: the plugin has one instance per Flutter engine, so its objects never cross isolates.
import 'dart:async';

import 'package:neurosdk2/neurosdk2.dart';

import 'chunk_writer.dart';
import 'headband.dart';

const List<FSensorFamily> _families = [FSensorFamily.leBrainBit, FSensorFamily.leBrainBitBlack];

class BrainBitFinder implements HeadbandFinder {
  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) async {
    final scanner = await Scanner.create(_families);
    final seen = <String, FSensorInfo>{};
    final sub = scanner.sensorsStream.listen((list) {
      for (final s in list) {
        seen[s.address] = s;
      }
    });
    try {
      await scanner.start();
      final until = DateTime.now().add(scanFor);
      while (seen.isEmpty && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        // The stream reports only new devices after a restarted scan; the list has them all.
        for (final s in await scanner.getSensors()) {
          if (s != null) seen[s.address] = s;
        }
      }
      // A second more, so a second headband nearby can be told apart by signal strength.
      if (seen.isNotEmpty) await Future<void>.delayed(const Duration(seconds: 1));
      await scanner.stop();
    } finally {
      await sub.cancel();
    }
    if (seen.isEmpty) {
      scanner.dispose();
      return null;
    }
    final info = seen.values.reduce((a, b) => a.rssi >= b.rssi ? a : b);
    onFound?.call(info.name, info.rssi);
    final Sensor? sensor;
    try {
      sensor = await scanner.createSensor(info); // also connects
    } catch (_) {
      scanner.dispose();
      rethrow;
    }
    if (sensor is! BrainBit) {
      await sensor?.dispose();
      scanner.dispose();
      throw StateError('not a BrainBit: ${info.sensFamily.name}');
    }
    return _BrainBitBand(scanner, sensor, info);
  }
}

class _BrainBitBand implements Headband {
  _BrainBitBand(this._scanner, this._sensor, this._info);

  final Scanner _scanner;
  final BrainBit _sensor;
  final FSensorInfo _info;

  @override
  String get name => _info.name;
  @override
  String get address => _info.address;
  @override
  String get serial => _info.serialNumber;
  @override
  int get rssi => _info.rssi;

  @override
  Stream<List<Sample>> get signal => _sensor.signalDataStream.map(
    (batch) => [for (final s in batch) (pack: s.packNum, o1: s.o1, o2: s.o2, t3: s.t3, t4: s.t4)],
  );

  @override
  Stream<Map<String, double>> get resistance =>
      _sensor.resistDataStream.map((r) => {'O1': r.o1, 'O2': r.o2, 'T3': r.t3, 'T4': r.t4});

  @override
  Stream<bool> get rangeChanges => _sensor.sensorStateStream.map((s) => s == FSensorState.inRange);

  @override
  Future<void> startSignal() => _sensor.execute(FSensorCommand.startSignal);
  @override
  Future<void> stopSignal() => _sensor.execute(FSensorCommand.stopSignal);
  @override
  Future<void> startResist() => _sensor.execute(FSensorCommand.startResist);
  @override
  Future<void> stopResist() => _sensor.execute(FSensorCommand.stopResist);

  @override
  Future<bool> isInRange() async => await _sensor.state.value == FSensorState.inRange;

  @override
  Future<int> battery() => _sensor.batteryPower.value;

  @override
  Future<void> disconnectAndDispose() async {
    await _sensor.disconnect();
    await _sensor.dispose();
    _scanner.dispose();
  }
}
