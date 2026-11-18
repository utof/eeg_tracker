// The little our driver needs from Bluetooth LE, so the driver itself never touches a plugin: the real one is in
// universal_transport.dart (the only file that imports the BLE package), tests use a fake headband
// (test/own_ble/fake_headband.dart).
//
// There is on purpose no way here to remove a bond or forget a device: BrainBit's SDK unpaired every Bluetooth
// device on the laptop (DECISIONS 84), ours cannot even ask for it.
import 'dart:typed_data';

/// Any Bluetooth failure below the driver. The driver turns it into a HeadbandLost.
class BleError implements Exception {
  BleError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A device seen by a scan.
typedef BleFound = ({String address, String name, int? rssi, List<String> services});

class GattChar {
  const GattChar(this.uuid, this.properties);

  /// Lower case, 128-bit.
  final String uuid;

  /// Of `read`, `write`, `writeWithoutResponse`, `notify`, `indicate`.
  final Set<String> properties;

  bool get notifies => properties.contains('notify') || properties.contains('indicate');
}

class GattService {
  const GattService(this.uuid, this.characteristics);
  final String uuid;
  final List<GattChar> characteristics;
}

abstract class BleTransport {
  /// What carries the bytes, for the log (e.g. `universal_ble 3.3.0`).
  String get describe;

  /// Scans up to [timeout] and returns the first device whose name [match] accepts; null when none turned up.
  /// The scan stops as soon as one is found.
  Future<BleFound?> scan(bool Function(String name) match, Duration timeout);

  /// Connects to [address] (no scan). [onLost] fires once if this link breaks later without [BleLink.disconnect].
  /// Throws [BleError] when the device does not answer in [timeout].
  Future<BleLink> connect(String address, {required Duration timeout, required void Function() onLost});
}

/// One open connection.
abstract class BleLink {
  bool get isConnected;

  /// The size of the largest packet the link carries (bytes of payload + 3), when known.
  int? get mtu;

  Future<List<GattService>> services();
  Future<Uint8List> read(String service, String characteristic);
  Future<void> write(String service, String characteristic, Uint8List data, {required bool withResponse});

  /// Notifications (or indications) of [characteristic] go to [onData] until the link ends.
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List data) onData);

  /// Bonds with the headband if it is not bonded yet (the headband must be in pairing mode). Never removes a bond.
  Future<void> pair();

  /// Closes this link only.
  Future<void> disconnect();
}
