// The DIY board's Wi-Fi route on the phone: its firmware sends each E9 frame as one UDP datagram to UDP_HOST:9000
// (eeg_ads1299_lab board_config.h), so the phone listens on UDP port 9000. This file only receives: the board has no
// command the host may send (the operator's R, V, T or N are typed in a serial terminal), so there is no send call
// here, and a test keeps it that way (DECISIONS row 352). Unauthenticated and unencrypted (PROTOCOL.md): a private
// network only; board.dart ignores senders outside it. USB OTG serial is not built (DECISIONS row 362).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'e9.dart' show diyUdpPort;

/// The port could not be opened (taken by another app, or no network permission).
class LinkFailed implements Exception {
  const LinkFailed(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Where the board's datagrams come from. Tests use a fake one.
abstract class DiyLink {
  /// For the night's log: `UDP port 9000 on every IPv4 interface (Wi-Fi route)`.
  String get describe;

  /// Starts listening: every datagram goes to [onDatagram] with its sender; a failing socket to [onError] (after
  /// which nothing more arrives). Throws [LinkFailed] when the port cannot be opened.
  Future<void> open(void Function(Uint8List data, InternetAddress from) onDatagram, void Function(Object error) onError);

  Future<void> close();
}

/// UDP on the phone. Bound on every IPv4 interface (the laptop's 0.0.0.0, scripts/diy_board.py): the board sends to
/// the phone's Wi-Fi address, which DHCP can change; mobile data does not deliver unasked datagrams, and senders
/// outside the local network are ignored (board.dart). The port is taken alone when it can be; when another program
/// already holds it with address reuse (the emulator's OpenThread simulator listens on a multicast address at 9000),
/// it is shared and the log says so: datagrams sent to the phone's own address still come here.
class UdpLink implements DiyLink {
  UdpLink({this.port = diyUdpPort, InternetAddress? host}) : host = host ?? InternetAddress.anyIPv4;

  final int port;
  final InternetAddress host;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  /// Another program holds the port too (bound with address reuse).
  bool shared = false;

  /// The port actually bound (differs from [port] only when that is 0, in tests); null until open.
  int? get boundPort => _socket?.port;

  @override
  String get describe =>
      'UDP port ${boundPort ?? port} on ${host == InternetAddress.anyIPv4 ? 'every IPv4 interface' : host.address} '
      '(Wi-Fi route${shared ? '; shared with another program on this phone' : ''})';

  @override
  Future<void> open(void Function(Uint8List data, InternetAddress from) onDatagram, void Function(Object error) onError) async {
    RawDatagramSocket s;
    try {
      // Alone when possible: a second app on the same port could take some of the board's datagrams.
      s = await RawDatagramSocket.bind(host, port, reuseAddress: false);
      shared = false;
    } on SocketException {
      try {
        s = await RawDatagramSocket.bind(host, port, reuseAddress: true);
        shared = true;
      } on SocketException catch (e) {
        throw LinkFailed('port $port is in use or not allowed (${e.osError?.message ?? e.message})');
      }
    }
    _socket = s;
    _sub = s.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        for (var d = s.receive(); d != null; d = s.receive()) {
          onDatagram(d.data, d.address);
        }
      },
      onError: onError,
      cancelOnError: true,
    );
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }
}
