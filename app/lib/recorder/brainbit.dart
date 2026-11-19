// BrainBit (and BrainBit Black) through BrainBit's neurosdk2 plugin: [SdkFinder]. The plugin has one instance
// per Flutter engine, so its objects never cross isolates.
//
// Screens and the recorder ask for a `BrainBitFinder` (headband/finder.dart, exported here), which hands the work
// to this SDK finder by default, or to our own connection when its switch is on (DECISIONS row 211).
import 'dart:async';

import 'package:neurosdk2/neurosdk2.dart';

import 'chunk_writer.dart';
import 'headband.dart';

export '../headband/finder.dart' show BrainBitFinder;

const List<FSensorFamily> _families = [FSensorFamily.leBrainBit, FSensorFamily.leBrainBitBlack];

class SdkFinder implements HeadbandFinder {
  /// The scanner that last found or reached the headband, and what it reported. The SDK appears to make
  /// sensors only for devices its scanner knows ("Sensor not founded" in the library), so a direct
  /// connection goes through this scanner, without starting a scan.
  Scanner? _scanner;
  FSensorInfo? _info;

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
    final band = await _create(scanner, info, rssi: info.rssi, newScanner: true);
    _keep(scanner, info);
    return band;
  }

  @override
  Future<Headband> connectDirect(BandId id) async {
    final known = _scanner != null && _info?.address == id.address;
    // After a process restart no scanner knows the headband; the SDK may refuse, and the recorder scans.
    final scanner = known ? _scanner! : await Scanner.create(_families);
    final info = known ? _info! : _infoOf(id);
    final band = await _create(scanner, info, rssi: null, newScanner: !known);
    _keep(scanner, info);
    return band;
  }

  Future<_BrainBitBand> _create(
    Scanner scanner,
    FSensorInfo info, {
    required int? rssi,
    required bool newScanner,
  }) async {
    final Sensor? sensor;
    try {
      sensor = await scanner.createSensor(info); // also connects
    } catch (_) {
      if (newScanner) scanner.dispose();
      rethrow;
    }
    if (sensor is! BrainBit) {
      await sensor?.dispose();
      if (newScanner) scanner.dispose();
      throw StateError('not a BrainBit: ${info.sensFamily.name}');
    }
    return _BrainBitBand(sensor, info, rssi);
  }

  /// A replaced scanner is dropped without dispose: its sensor may have been left out of range, and no SDK
  /// call goes near a lost sensor. It ends with the process.
  void _keep(Scanner scanner, FSensorInfo info) {
    _scanner = scanner;
    _info = info;
  }

  /// End of the night. The scanner is disposed only if no headband was left behind out of range.
  void dispose({required bool anyLost}) {
    if (!anyLost) _scanner?.dispose();
    _scanner = null;
    _info = null;
  }

  static FSensorInfo _infoOf(BandId id) {
    final family = FSensorFamily.values.asNameMap()[id.family];
    if (family == null) throw StateError('unknown sensor family "${id.family}"');
    return FSensorInfo(
      name: id.name,
      address: id.address,
      serialNumber: id.serial,
      pairingRequired: id.pairingRequired,
      sensModel: id.model,
      sensFamily: family,
      rssi: 0,
    );
  }
}

class _BrainBitBand implements Headband {
  _BrainBitBand(this._sensor, this._info, this.rssi);

  final BrainBit _sensor;
  final FSensorInfo _info;

  @override
  String get name => _info.name;
  @override
  String get address => _info.address;
  @override
  String get serial => _info.serialNumber;
  @override
  final int? rssi;
  @override
  BandId get id => BandId(
    name: _info.name,
    address: _info.address,
    serial: _info.serialNumber,
    family: _info.sensFamily.name,
    model: _info.sensModel,
    pairingRequired: _info.pairingRequired,
  );

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

  /// The scanner stays with [SdkFinder] for the next direct connection.
  @override
  Future<void> disconnectAndDispose() async {
    await _sensor.disconnect();
    await _sensor.dispose();
  }
}
