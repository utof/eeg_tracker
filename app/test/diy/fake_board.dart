// A fake DIY ADS1299 board for tests: eeg_ads1299_lab's bench firmware on the Wi-Fi route as its PROTOCOL.md and
// sketch describe it (one E9 frame per UDP datagram, 250 a second), without hardware. Its encoder is written here,
// apart from lib/headband/diy/e9.dart (as the Python fake board's is apart from scripts/diy_board.py), and the test
// checks it against the firmware's own golden frames.
//
// Signals: mode T is the chip's internal test signal (a +-83886-count square wave at 0.9765625 Hz on every
// channel, VREF/2400 at gain 24); mode N is shorted inputs (a few counts of noise).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:eeg_tracker/headband/diy/link.dart';

const int square = 83886;
const double testHz = 2.048e6 / (1 << 21);
const String boardAddress = '192.168.1.50';

int _crc(List<int> d) {
  var crc = 0xFFFF;
  for (final b in d) {
    crc ^= b << 8;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// One E9 frame: little-endian header, the native ADS1299 frame (big-endian 24-bit words), CRC-16/CCITT-FALSE.
Uint8List encode(
  List<int> codes, {
  required int seq,
  required int timeUs,
  int overruns = 0,
  int flags = 1,
  int gain = 24,
  int fs = 250,
  int status = 0xC00000,
}) {
  final b = BytesBuilder();
  final h = ByteData(20)
    ..setUint8(0, 0x45)
    ..setUint8(1, 0x39)
    ..setUint8(2, 1)
    ..setUint8(3, codes.length)
    ..setUint8(4, flags)
    ..setUint8(5, gain)
    ..setUint16(6, fs, Endian.little)
    ..setUint32(8, seq & 0xFFFFFFFF, Endian.little)
    ..setUint32(12, timeUs & 0xFFFFFFFF, Endian.little)
    ..setUint32(16, overruns & 0xFFFFFFFF, Endian.little);
  b.add(h.buffer.asUint8List());
  b.add([(status >> 16) & 0xFF, (status >> 8) & 0xFF, status & 0xFF]);
  for (final c in codes) {
    final v = c & 0xFFFFFF;
    b.add([(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  }
  final body = b.takeBytes();
  final crc = _crc(body);
  return Uint8List.fromList([...body, crc & 0xFF, crc >> 8]);
}

/// A link that the test feeds by hand: [send] is a datagram arriving from the board.
class FakeLink implements DiyLink {
  FakeLink({this.failOpen});

  /// When set, [open] throws this (the port is taken).
  final String? failOpen;
  void Function(Uint8List data, InternetAddress from)? _on;
  void Function(Object error)? _err;
  int opens = 0, closes = 0;

  bool get isOpen => _on != null;

  @override
  String get describe => 'fake UDP link';

  @override
  Future<void> open(void Function(Uint8List data, InternetAddress from) onDatagram, void Function(Object error) onError) async {
    opens++;
    if (failOpen != null) throw LinkFailed(failOpen!);
    _on = onDatagram;
    _err = onError;
  }

  void send(List<int> data, {String from = boardAddress}) => _on?.call(Uint8List.fromList(data), InternetAddress(from));

  void fail(Object e) => _err?.call(e);

  @override
  Future<void> close() async {
    closes++;
    _on = null;
    _err = null;
  }
}

/// The board's state: its sequence (DRDY count since boot), clock, overruns and mode.
class FakeBoard {
  FakeBoard({this.channels = 4, this.mode = 'T', this.seq = 500, int seed = 1}) : _rng = Random(seed);

  int channels;
  String mode;

  /// The sequence number of the last conversion.
  int seq;
  int overruns = 0;
  final Random _rng;

  int get flags => (mode == 'T' ? 1 : 2) | (overruns > 0 ? 8 : 0);

  List<int> codes(int s) {
    if (mode == 'T') {
      final high = (s / 250 * testHz) % 1.0 < 0.5;
      return List.filled(channels, high ? square : -square);
    }
    return [for (var c = 0; c < channels; c++) (_rng.nextDouble() * 12 - 6).round()];
  }

  Uint8List frameAt(int s) => encode(codes(s), seq: s, timeUs: s * 4000 + 30000000, overruns: overruns, flags: flags);

  /// The next [n] conversions as datagrams (the next sequence numbers).
  List<Uint8List> next(int n) => [for (var i = 0; i < n; i++) frameAt(++seq)];

  /// The board misses [n] conversions itself (its overrun counter moves; the sequence moves on).
  void miss(int n) {
    seq += n;
    overruns += n;
  }

  /// The DevKit restarts: the operator answers its prompts again and it streams from sequence 1.
  void restart({String? mode}) {
    seq = 0;
    overruns = 0;
    if (mode != null) this.mode = mode;
  }
}

/// Sends [frames] through [link] one by one.
void sendAll(FakeLink link, Iterable<List<int>> frames, {String from = boardAddress}) {
  for (final f in frames) {
    link.send(f, from: from);
  }
}
