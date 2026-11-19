// The real Bluetooth under our driver: the `universal_ble` plugin (BSD-3-Clause; DECISIONS row 210). The ONLY file
// that imports it, so another plugin, or our own Kotlin channel, replaces this one file.
//
// The plugin keeps one instance per Flutter engine and needs no Activity for connecting, reading, writing and
// notifications, so it works both on a screen and inside the night recorder's foreground service (its engine
// registers every plugin by itself). Permissions are asked by the screens (ui/nearby.dart) before any of this.
// Nothing here removes a bond or a device.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'protocol.dart' show mtuWanted;
import 'transport.dart';

/// Keep equal to the version pinned in pubspec.yaml (a test compares it with pubspec.lock).
const String blePackage = 'universal_ble 3.3.0';

class UniversalTransport implements BleTransport {
  @override
  String get describe => blePackage;

  @override
  Future<BleFound?> scan(bool Function(String name) match, Duration timeout) async {
    final found = Completer<BleFound?>();
    // No native filter: Android can filter by a whole name or a service, not by the start of a name, and whether
    // the headband advertises its service is not known yet. Android pauses such a scan while the screen is off;
    // the known address is the way in at night.
    final sub = UniversalBle.scanStream.listen((d) {
      final name = d.name ?? '';
      if (!found.isCompleted && match(name)) {
        found.complete((address: d.deviceId, name: name, rssi: d.rssi, services: d.services));
      }
    });
    final timer = Timer(timeout, () {
      if (!found.isCompleted) found.complete(null);
    });
    // The plugin queues scan commands without a deadline: a start that never answered would keep this scan (its
    // listener) for good, and the stop queued behind it would never answer either. So both have deadlines.
    try {
      await UniversalBle.startScan().timeout(timeout);
      return await found.future;
    } on TimeoutException {
      throw BleError('the scan did not start (no answer from Bluetooth)');
    } catch (e) {
      throw BleError(_text(e));
    } finally {
      timer.cancel();
      await sub.cancel();
      try {
        await UniversalBle.stopScan().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  @override
  Future<BleLink> connect(String address, {required Duration timeout, required void Function() onLost}) async {
    try {
      await UniversalBle.connect(address, timeout: timeout);
    } catch (e) {
      // Give up the try on Android's side too, so a connection that opens later is not left open and unowned.
      unawaited(
        UniversalBle.disconnect(address, timeout: const Duration(seconds: 5)).then<void>((_) {}, onError: (_) {}),
      );
      throw BleError(_text(e));
    }
    final link = _UniversalLink(address, onLost);
    try {
      await link._open();
    } catch (e) {
      await link.disconnect();
      throw BleError(_text(e));
    }
    return link;
  }
}

String _text(Object e) => e is BleError ? e.message : e.toString().replaceAll('\n', ' ');

class _UniversalLink implements BleLink {
  _UniversalLink(this.address, this._onLost);
  final String address;
  final void Function() _onLost;
  final List<StreamSubscription<Object?>> _subs = [];
  StreamSubscription<bool>? _state;
  List<BleService> _services = const [];
  bool _connected = true;
  int? _mtu;

  @override
  bool get isConnected => _connected;
  @override
  int? get mtu => _mtu;

  Future<void> _open() async {
    _state = UniversalBle.connectionStream(address).listen((connected) {
      if (connected || !_connected) return;
      _connected = false;
      unawaited(_stopListening());
      _onLost();
    });
    if (await UniversalBle.getConnectionState(address) != BleConnectionState.connected) {
      throw BleError('the link closed right after it opened');
    }
    // Android starts every link at 23-byte packets; the 108-byte signal packet needs more.
    try {
      _mtu = await UniversalBle.requestMtu(address, mtuWanted);
    } catch (e) {
      debugPrint('own BLE: the packet size request failed: $e');
    }
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    if (!_connected) throw BleError('Not connected');
    try {
      return await call();
    } catch (e) {
      throw BleError(_text(e));
    }
  }

  @override
  Future<List<GattService>> services() => _call(() async {
    _services = await UniversalBle.discoverServices(address);
    return [
      for (final s in _services)
        GattService(s.uuid.toLowerCase(), [
          for (final c in s.characteristics) GattChar(c.uuid.toLowerCase(), {for (final p in c.properties) p.name}),
        ]),
    ];
  });

  @override
  Future<Uint8List> read(String service, String characteristic) =>
      _call(() => UniversalBle.read(address, service, characteristic));

  @override
  Future<void> write(String service, String characteristic, Uint8List data, {required bool withResponse}) =>
      _call(() => UniversalBle.write(address, service, characteristic, data, withoutResponse: !withResponse));

  @override
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List data) onData) => _call(() async {
    _subs.add(UniversalBle.characteristicValueStream(address, characteristic).listen(onData));
    final notify = _services
        .where((s) => s.uuid.toLowerCase() == service.toLowerCase())
        .expand((s) => s.characteristics)
        .where((c) => c.uuid.toLowerCase() == characteristic.toLowerCase())
        .any((c) => c.properties.contains(CharacteristicProperty.notify));
    if (notify || _services.isEmpty) {
      await UniversalBle.subscribeNotifications(address, service, characteristic);
    } else {
      await UniversalBle.subscribeIndications(address, service, characteristic);
    }
  });

  @override
  Future<void> pair() => _call(() async {
    if (await UniversalBle.isPaired(address) == true) return;
    await UniversalBle.pair(address);
  });

  Future<void> _stopListening() async {
    final state = _state, subs = _subs.toList();
    _state = null;
    _subs.clear();
    await state?.cancel();
    for (final s in subs) {
      await s.cancel();
    }
  }

  /// Also for a link that was lost: it frees Android's side of the connection.
  @override
  Future<void> disconnect() async {
    _connected = false; // our own disconnect is not a loss
    await _stopListening();
    try {
      await UniversalBle.disconnect(address);
    } catch (_) {}
  }
}
