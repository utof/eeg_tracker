// The DIY ADS1299 board's "E9" wire protocol (eeg_ads1299_lab docs/PROTOCOL.md; its bench firmware
// firmware/esp32_ads1299_bench), ported line for line from the laptop driver scripts/diy_board.py: the frame decoder,
// the stream decoder (serial: frames among the firmware's text) and the sequence tracker. Checked against the Python
// driver on the very same bytes (test/fixtures/diy_vectors.json, test/diy_e9_test.dart), and through it against
// frames made by the firmware's own framing code.
//
// One E9 frame per conversion (25 + 3 x channels bytes: 37, 43 or 49):
//   0  "E9"   2 version 1   3 channels 4/6/8   4 flags   5 gain   6 samples/s (LE16)
//   8  sequence (LE32, DRDY count since boot)   12 device microseconds at DRDY (LE32)   16 cumulative overruns (LE32)
//   20 the chip's own 24-bit status word (big endian, high nibble 0xC)
//   23 channel values, 24-bit signed big endian    last 2: CRC-16/CCITT-FALSE (LE) over everything before it
// Flags: 1 internal test signal, 2 internal inputs shorted, 4 synthetic, 8 at least one overrun so far.
// Volts = counts x VREF / (gain x 2^23) (ADS1299 datasheet SBAS499C eq. 8); VREF is not in the frame (4.5 V, the
// chip's internal reference, which the bench firmware uses).
//
// Pure Dart: no sockets here (link.dart), so it runs in tests and in any isolate.
import 'dart:typed_data';

const String e9Magic = 'E9';
const int e9Version = 1;

/// Bytes before the native ADS1299 frame (magic, version, channels, flags, gain, rate, sequence, time, overruns).
const int e9HeaderSize = 20;
const List<int> e9Channels = [4, 6, 8];
const List<int> e9Gains = [1, 2, 4, 6, 8, 12, 24];
const List<int> e9Rates = [250, 500, 1000, 2000, 4000, 8000, 16000];
const int flagTest = 1, flagShort = 2, flagSynthetic = 4, flagOverrun = 8;

/// The 8-channel frame.
const int e9MaxSize = 49;

/// Longest firmware text line kept.
const int maxTextLine = 400;
const double defaultVref = 4.5;

/// The firmware sends its datagrams to this port (board_config.h `UDP_PORT`).
const int diyUdpPort = 9000;

/// A frame at most this far behind the last is a late datagram; farther back, the board restarted.
const int staleWindow = 64;
const int _u32 = 1 << 32;
const int _magic0 = 0x45, _magic1 = 0x39; // "E9"

const Map<int, (String, String)> _modes = {
  flagTest: ('test', "test signal: the chip's own square wave, not EEG"),
  flagShort: ('short', "shorted inputs: the chip's own noise, not EEG"),
  flagSynthetic: ('synthetic', 'synthetic: made-up data, not EEG'),
};

int frameSize(int channels) => 25 + 3 * channels;

/// CRC-16/CCITT-FALSE (poly 0x1021, start 0xFFFF, no reflection, no final XOR), as portable_core.h computes it.
int crc16(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  for (var i = start; i < (end ?? data.length); i++) {
    crc ^= data[i] << 8;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

double voltsPerCount(int gain, [double vref = defaultVref]) => vref / (gain * (1 << 23));

int _signed24(List<int> b, int at) {
  final v = (b[at] << 16) | (b[at + 1] << 8) | b[at + 2];
  return (v & 0x800000) != 0 ? v - (1 << 24) : v;
}

int _le16(List<int> b, int at) => b[at] | (b[at + 1] << 8);
int _le32(List<int> b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24);

/// A frame refused. [reason] names the first check that failed: `short`, `magic`, `channels`, `length`, `crc`,
/// `range` or `status` (the order of the Python driver's checks).
class FrameError implements Exception {
  const FrameError(this.reason, this.message);
  final String reason;
  final String message;

  @override
  String toString() => message;
}

class E9Frame {
  const E9Frame({
    required this.channels,
    required this.flags,
    required this.gain,
    required this.fs,
    required this.seq,
    required this.timeUs,
    required this.overruns,
    required this.status,
    required this.counts,
  });

  final int channels, flags, gain, fs, seq, timeUs, overruns;

  /// 1100 + LOFF_STATP[7:0] + LOFF_STATN[7:0] + GPIO[7:4] (SBAS499C, data output).
  final int status;
  final List<int> counts;

  /// test, short, synthetic, or electrodes (no mode bit: never sent by the bench firmware).
  String get mode {
    for (final e in _modes.entries) {
      if (flags & e.key != 0) return e.value.$1;
    }
    return 'electrodes';
  }

  String get modeText {
    for (final e in _modes.entries) {
      if (flags & e.key != 0) return e.value.$2;
    }
    return 'electrode inputs (the bench firmware has no such mode; unreviewed)';
  }

  /// Not EEG: the chip's own test signal, its shorted inputs, or made-up data.
  bool get notEeg => flags & (flagTest | flagShort | flagSynthetic) != 0;

  bool get overrunFlag => flags & flagOverrun != 0;

  /// Bit k set: channel k+1's positive input reads as off. Meaningless while lead-off detection is off.
  int get leadOffP => (status >> 12) & 0xFF;
  int get leadOffN => (status >> 4) & 0xFF;
  int get gpio => status & 0xF;

  /// What must stay the same within one capture: channels, gain, rate, mode bits.
  List<int> get config => [channels, gain, fs, flags & 7];

  bool sameConfig(E9Frame o) => channels == o.channels && gain == o.gain && fs == o.fs && (flags & 7) == (o.flags & 7);

  List<double> volts([double vref = defaultVref]) {
    final k = voltsPerCount(gain, vref);
    return [for (final c in counts) c * k];
  }
}

/// Exactly one frame -> [E9Frame]. Throws [FrameError] naming the first check that failed.
E9Frame decodeFrame(List<int> data) {
  final n = data.length;
  if (n < e9HeaderSize + 2) throw FrameError('short', '$n bytes is too short for a frame');
  final version = data[2], ch = data[3], flags = data[4], gain = data[5];
  if (data[0] != _magic0 || data[1] != _magic1 || version != e9Version) {
    throw FrameError('magic', 'not an E9 version 1 frame (version $version)');
  }
  if (!e9Channels.contains(ch)) throw FrameError('channels', 'channel count $ch');
  if (n != frameSize(ch)) throw FrameError('length', '$n bytes for $ch channels (expected ${frameSize(ch)})');
  if (crc16(data, 0, n - 2) != _le16(data, n - 2)) throw const FrameError('crc', 'CRC mismatch');
  final fs = _le16(data, 6);
  if (!e9Gains.contains(gain) || !e9Rates.contains(fs) || flags & ~15 != 0) {
    throw FrameError('range', 'gain $gain, rate $fs or flags 0x${flags.toRadixString(16)} out of range');
  }
  final status = (data[20] << 16) | (data[21] << 8) | data[22];
  if (status >> 20 != 0xC) {
    throw FrameError('status', 'status word ${status.toRadixString(16).padLeft(6, '0')} lacks the 0xC prefix');
  }
  return E9Frame(
    channels: ch,
    flags: flags,
    gain: gain,
    fs: fs,
    seq: _le32(data, 8),
    timeUs: _le32(data, 12),
    overruns: _le32(data, 16),
    status: status,
    counts: List.unmodifiable([for (var c = 0; c < ch; c++) _signed24(data, 23 + 3 * c)]),
  );
}

bool _printable(List<int> line) => line.length >= 8 && line.every((b) => (b >= 32 && b < 127) || b == 9);

/// Python's `bytes.strip(b"\r\t ")`.
List<int> _strip(List<int> b) {
  bool ws(int c) => c == 13 || c == 9 || c == 32;
  var s = 0, e = b.length;
  while (s < e && ws(b[s])) {
    s++;
  }
  while (e > s && ws(b[e - 1])) {
    e--;
  }
  return b.sublist(s, e);
}

/// Frames out of the serial byte stream. Bytes that are not part of a valid frame (a frame cut at the start, damaged
/// frames, the firmware's text) are skipped and counted; printable text lines among them are kept for [takeLines].
/// The buffer never holds more than one frame's worth. (The phone receives the board over Wi-Fi, one frame per
/// datagram; this is here for a later USB route and to keep the port whole.)
class StreamDecoder {
  final List<int> _buffer = [];
  final List<int> _text = [];
  List<String> _lines = [];
  int frames = 0, badFrames = 0, discardedBytes = 0;

  int get bufferLength => _buffer.length;
  int get textLength => _text.length;

  void _skip(int n) {
    for (var i = 0; i < n; i++) {
      final b = _buffer[i];
      if (b == 10) {
        final line = _strip(_text);
        if (_printable(line)) _lines.add(String.fromCharCodes(line));
        _text.clear();
      } else if (_text.length < maxTextLine) {
        _text.add(b);
      } else {
        _text.clear(); // too long for a firmware line: binary
      }
    }
    _buffer.removeRange(0, n);
    discardedBytes += n;
  }

  int _findMagic() {
    for (var i = 0; i + 1 < _buffer.length; i++) {
      if (_buffer[i] == _magic0 && _buffer[i + 1] == _magic1) return i;
    }
    return -1;
  }

  List<E9Frame> feed(List<int> chunk) {
    _buffer.addAll(chunk);
    final out = <E9Frame>[];
    while (_buffer.isNotEmpty) {
      final at = _findMagic();
      if (at < 0) {
        // keep a last "E": it may start the next magic
        _skip(_buffer.length - (_buffer.last == _magic0 ? 1 : 0));
        break;
      }
      if (at > 0) _skip(at);
      if (_buffer.length < 4) break;
      if (_buffer[2] != e9Version || !e9Channels.contains(_buffer[3])) {
        _skip(1);
        continue;
      }
      final size = frameSize(_buffer[3]);
      if (_buffer.length < size) break;
      final E9Frame frame;
      try {
        frame = decodeFrame(Uint8List.fromList(_buffer.sublist(0, size)));
      } on FrameError {
        badFrames++;
        _skip(1);
        continue;
      }
      _buffer.removeRange(0, size);
      frames++;
      out.add(frame);
    }
    return out;
  }

  List<String> takeLines() {
    final lines = _lines;
    _lines = [];
    return lines;
  }
}

enum TextKind { halted, prompt, banner, info }

/// halted (the firmware stopped and parked the chip), prompt (it waits for the operator), banner (it just started),
/// or info.
TextKind textKind(String line) {
  if (line.startsWith('HALTED')) return TextKind.halted;
  if (line.contains('type R') || line.contains('type V') || line.contains('type T')) return TextKind.prompt;
  if (line.startsWith('ADS1299 learning lab')) return TextKind.banner;
  return TextKind.info;
}

enum StepKind { first, next, duplicate, stale, restart, config }

class TrackStep {
  const TrackStep(this.kind, {this.lost = 0, this.boardMissed = 0});
  final StepKind kind;

  /// Sequence numbers missing before this frame.
  final int lost;

  /// Of those, conversions the board itself skipped (its overrun counter).
  final int boardMissed;
}

/// One capture of one board boot (PROTOCOL.md, host behaviour): forward sequence numbers are accepted and gaps
/// counted, never filled; a repeat or a late frame is dropped, never sorted in; a jump far back, a clock going back,
/// or a changed configuration (channels, gain, rate, mode) is a new capture: the tracker starts again from that frame
/// and says so ([StepKind.restart] / [StepKind.config]), and the recorder starts a new file set.
class Tracker {
  E9Frame? last;
  int accepted = 0, lost = 0, boardMissed = 0, duplicates = 0, stale = 0, timingAnomalies = 0;

  void reset() => last = null;

  TrackStep observe(E9Frame f) {
    final l = last;
    if (l == null) return _take(f, const TrackStep(StepKind.first));
    if (!f.sameConfig(l)) return _take(f, const TrackStep(StepKind.config));
    final ds = (f.seq - l.seq) % _u32;
    final dt = (f.timeUs - l.timeUs) % _u32;
    if (ds == 0) {
      duplicates++;
      return const TrackStep(StepKind.duplicate);
    }
    if (ds >= _u32 ~/ 2 || dt >= _u32 ~/ 2) {
      if (ds >= _u32 ~/ 2 && (l.seq - f.seq) % _u32 <= staleWindow) {
        stale++;
        return const TrackStep(StepKind.stale);
      }
      return _take(f, const TrackStep(StepKind.restart));
    }
    final gap = ds - 1;
    final board = (f.overruns - l.overruns) % _u32;
    final missed = gap < board ? gap : board;
    final expected = ds * 1e6 / f.fs;
    final allowed = 0.1 * expected > 500.0 ? 0.1 * expected : 500.0;
    if ((dt - expected).abs() > allowed) timingAnomalies++;
    lost += gap;
    boardMissed += missed;
    return _take(f, TrackStep(StepKind.next, lost: gap, boardMissed: missed));
  }

  TrackStep _take(E9Frame f, TrackStep step) {
    last = f;
    accepted++;
    return step;
  }
}
