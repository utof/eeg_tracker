// Share on Wi-Fi: which address the phone shows and whom the server answers (lib/share/protocol.dart, DECISIONS
// rows 560-569). The owner's Xiaomi had Wi-Fi, mobile data and a VPN at once (wlan0 192.168.1.5/24, ccmni0
// 10.43.97.139/8, tun0 10.10.10.1/30) and showed "no Wi-Fi": Android's own answer (PhoneChannel.kt) now comes
// first, Dart's interface list is the fallback, and the server, which listens on every address, answers only the
// phone itself and clients inside the Wi-Fi network.
import 'dart:io';
import 'dart:typed_data';

import 'package:eeg_tracker/share/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class _Addr implements InterfaceAddress {
  _Addr(String a, this.prefixLength) : _a = InternetAddress(a);
  final InternetAddress _a;
  @override
  final int prefixLength;
  @override
  InternetAddress? get broadcast => null;
  @override
  String get address => _a.address;
  @override
  String get host => _a.host;
  @override
  Uint8List get rawAddress => _a.rawAddress;
  @override
  InternetAddressType get type => _a.type;
  @override
  bool get isLoopback => _a.isLoopback;
  @override
  bool get isLinkLocal => _a.isLinkLocal;
  @override
  bool get isMulticast => _a.isMulticast;
  @override
  Future<InternetAddress> reverse() => _a.reverse();
}

class _If implements NetworkInterface {
  _If(this.name, this.addresses);
  @override
  final String name;
  @override
  final List<InterfaceAddress> addresses;
  @override
  int get index => 0;
}

/// The owner's phone on the night of 2026-11-19 (`adb shell ip -4 addr`).
final List<NetworkInterface> owners = [
  _If('tun0', [_Addr('10.10.10.1', 30)]),
  _If('ccmni0', [_Addr('10.43.97.139', 8)]),
  _If('wlan0', [_Addr('192.168.1.5', 24)]),
];

String nets(List<LanNet> n) => [for (final x in n) '${x.address.address}/${x.prefix}'].join(' ');

void main() {
  test('the interface list (fallback): Wi-Fi only, never mobile data or the VPN, with its prefix', () {
    expect(nets(lanNets(owners)), '192.168.1.5/24');
    expect(lanAddresses(owners).map((a) => a.address), ['192.168.1.5']);
    expect(lanNets([_If('tun0', [_Addr('10.10.10.1', 30)]), _If('ccmni0', [_Addr('10.43.97.139', 8)])]), isEmpty);
    expect(nets(lanNets([_If('eth0', [_Addr('10.0.0.9', 16)]), _If('wlan1', [_Addr('172.20.1.2', 20)])])), '172.20.1.2/20 10.0.0.9/16');
    expect(describeInterfaces(owners), 'tun0 10.10.10.1/30, ccmni0 10.43.97.139/8, wlan0 192.168.1.5/24');
    expect(describeInterfaces(const []), 'none');
  });

  test("Android's answer: private IPv4 networks; a missing or odd prefix is read as /24", () {
    expect(nets(parseLanNets(['192.168.1.5/24'])), '192.168.1.5/24');
    expect(nets(parseLanNets(['192.168.1.5', '10.1.2.3/40', '172.16.0.2/0'])), '192.168.1.5/24 10.1.2.3/24 172.16.0.2/24');
    expect(parseLanNets(['8.8.8.8/24', 'fe80::1/64', 'wlan0', '', 7, null, '192.168.1.300/24']), isEmpty);
    expect(nets(parseLanNets(['192.168.1.5/24', '192.168.1.5/24'])), '192.168.1.5/24');
  });

  test("Android's answer comes first; the interface list only when Android has none", () {
    const android = (nets: ['192.168.1.5/24'], note: 'wifi wlan0 192.168.1.5/24');
    final a = chooseLan(android, interfaces: [_If('wlan0', [_Addr('192.168.9.9', 24)])]);
    expect(nets(a.nets), '192.168.1.5/24');
    expect(a.why, isEmpty);

    const silent = (nets: <String>[], note: 'vpn tun0 10.10.10.1/30; wifi manager none');
    final b = chooseLan(silent, interfaces: owners);
    expect(nets(b.nets), '192.168.1.5/24');
    expect(b.why, isEmpty);
  });

  test('neither source has an address: it says what each one returned', () {
    const silent = (nets: <String>[], note: 'vpn tun0 10.10.10.1/30; wifi manager none');
    final a = chooseLan(silent, interfaces: [_If('tun0', [_Addr('10.10.10.1', 30)])]);
    expect(a.nets, isEmpty);
    expect(a.why, 'no Wi-Fi address found (android: vpn tun0 10.10.10.1/30; wifi manager none; interfaces: tun0 10.10.10.1/30)');
    final b = chooseLan(noWifiAnswer, interfaceError: const SocketException('Failed listing interfaces'));
    expect(b.nets, isEmpty);
    expect(b.why, contains('android: no answer;'));
    expect(b.why, contains('interfaces: failed: SocketException: Failed listing interfaces'));
  });

  test('who is answered: the phone itself, and clients inside the Wi-Fi network only', () {
    final wifi = parseLanNets(['192.168.1.5/24']);
    for (final a in ['127.0.0.1', '::1', '192.168.1.6', '192.168.1.254', '::ffff:192.168.1.40']) {
      expect(isServedClient(InternetAddress(a), wifi), isTrue, reason: a);
    }
    // the VPN's other end (10.10.10.2 of tun0's /30), mobile data's carrier network (ccmni0's 10.0.0.0/8), another
    // private network routed in, and the internet: all private-looking or not, none is on this Wi-Fi
    for (final a in ['10.10.10.2', '10.43.0.1', '192.168.2.40', '172.16.0.9', '8.8.8.8', '2001:db8::1', '::ffff:10.10.10.2']) {
      expect(isServedClient(InternetAddress(a), wifi), isFalse, reason: a);
    }
  });

  test('no Wi-Fi network known: only the phone itself (adb forward over the cable)', () {
    expect(isServedClient(InternetAddress('127.0.0.1'), const []), isTrue);
    expect(isServedClient(InternetAddress('192.168.1.6'), const []), isFalse);
    expect(isServedClient(InternetAddress('10.10.10.2'), const []), isFalse);
  });

  test('a network is its prefix: /30 and /8 edges', () {
    final vpn = parseLanNets(['10.10.10.1/30']).single;
    expect(inLan(InternetAddress('10.10.10.2'), vpn), isTrue);
    expect(inLan(InternetAddress('10.10.10.4'), vpn), isFalse);
    final wide = parseLanNets(['10.43.97.139/8']).single;
    expect(inLan(InternetAddress('10.200.0.1'), wide), isTrue);
    expect(inLan(InternetAddress('11.0.0.1'), wide), isFalse);
    expect(inLan(InternetAddress('::1'), wide), isFalse);
  });
}
