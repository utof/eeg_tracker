// A Bluetooth transport around the fake headband whose connection tries take a while when the headband is away (as
// a phone's do, up to the driver's limit), and that counts what is open at once: tries in flight and links not yet
// let go. Our own connection must never have two at a time (universal_ble answers a second try for the same address
// with "Connection already in progress", and its disconnect goes by address).
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/headband/own/transport.dart';

import 'fake_headband.dart';

class SlowConnect implements BleTransport {
  SlowConnect(this.hb, {required this.whileAway});

  final FakeHeadband hb;

  /// How long a try takes when the headband is away as it starts; it then ends as the headband is then.
  final Duration whileAway;

  /// Tries under way, and links handed out and not yet disconnected by their owner.
  int inFlight = 0, open = 0;

  /// The most of both at once.
  int most = 0;
  int tries = 0;

  void _count() => most = math.max(most, inFlight + open);

  @override
  String get describe => hb.describe;

  @override
  Future<BleFound?> scan(bool Function(String name) match, Duration timeout) => hb.scan(match, timeout);

  @override
  Future<BleLink> connect(String address, {required Duration timeout, required void Function() onLost}) async {
    tries++;
    inFlight++;
    _count();
    final BleLink link;
    try {
      if (hb.away) await Future<void>.delayed(whileAway);
      link = await hb.connect(address, timeout: timeout, onLost: onLost);
    } finally {
      inFlight--;
    }
    open++;
    _count();
    return _CountedLink(link, this);
  }
}

class _CountedLink implements BleLink {
  _CountedLink(this._link, this._t);
  final BleLink _link;
  final SlowConnect _t;
  bool _let = false;

  @override
  bool get isConnected => _link.isConnected;
  @override
  int? get mtu => _link.mtu;
  @override
  Future<List<GattService>> services() => _link.services();
  @override
  Future<Uint8List> read(String service, String characteristic) => _link.read(service, characteristic);
  @override
  Future<void> write(String service, String characteristic, Uint8List data, {required bool withResponse}) =>
      _link.write(service, characteristic, data, withResponse: withResponse);
  @override
  Future<void> subscribe(String service, String characteristic, void Function(Uint8List data) onData) =>
      _link.subscribe(service, characteristic, onData);
  @override
  Future<void> pair() => _link.pair();

  @override
  Future<void> disconnect() async {
    await _link.disconnect();
    if (!_let) {
      _let = true;
      _t.open--;
    }
  }
}
