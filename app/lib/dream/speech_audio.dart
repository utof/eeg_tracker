// The audio steps before the speech recognizer (DECISIONS row 252), pure: an answer's WAV as samples, a quiet answer
// raised, and the voice detector's parts joined. The same steps as scripts/dream_text_check.py's `level` and
// `voiced`, where they were measured.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// The recognizer's and the answers' sample rate.
const int speechRate = 16000;

/// A quiet answer is raised so its peak is here (dBFS), by at most [levelMaxDb].
const double levelPeakDb = -3;
const double levelMaxDb = 30;

/// Silence put between two voiced parts (s).
const double joinGapS = 0.3;

/// Each voiced part is widened by this much on both sides (s): the voice detector starts a part a little late and
/// ends it a little early, which cost the first and last sounds of words (scripts/dream_text_check.py).
const double voicePadS = 0.25;

/// The samples of a 16 kHz mono 16-bit PCM WAV (what the `record` package writes), -1..1. A `data` size left unset
/// by a recorder stopped hard counts what is in the file. Throws [FormatException] for any other file and
/// [FileSystemException] when it cannot be read.
Float32List readWav16k(File f) {
  final bytes = f.readAsBytesSync();
  final b = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('not a WAV file');
  int? rate, channels, bits, format;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at), size = b.getUint32(at + 4, Endian.little);
    if (id == 'fmt ' && at + 24 <= bytes.length) {
      format = b.getUint16(at + 8, Endian.little);
      channels = b.getUint16(at + 10, Endian.little);
      rate = b.getUint32(at + 12, Endian.little);
      bits = b.getUint16(at + 22, Endian.little);
    }
    if (id == 'data') {
      if (format != 1 || channels != 1 || bits != 16 || rate != speechRate) {
        throw FormatException('not 16 kHz mono 16-bit PCM (rate $rate, channels $channels, bits $bits)');
      }
      final start = at + 8, avail = bytes.length - start;
      final n = (size == 0 || size == 0xFFFFFFFF || size > avail ? avail : size) ~/ 2;
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = b.getInt16(start + 2 * i, Endian.little) / 32768;
      }
      return out;
    }
    at += 8 + size + (size & 1);
  }
  throw const FormatException('no sound in the WAV file');
}

/// [x] raised so its peak is at [levelPeakDb], by at most [levelMaxDb]; never lowered. A new list.
Float32List levelUp(Float32List x) {
  var peak = 0.0;
  for (final v in x) {
    peak = math.max(peak, v.abs());
  }
  final out = Float32List.fromList(x);
  if (peak == 0) return out;
  final gain = math.min(math.pow(10, levelPeakDb / 20) / peak, math.pow(10, levelMaxDb / 20)).toDouble();
  if (gain <= 1) return out;
  for (var i = 0; i < out.length; i++) {
    out[i] *= gain;
  }
  return out;
}

/// The voice detector's parts as (first sample, samples), widened by [voicePadS] on both sides, kept inside
/// [total] samples, overlaps merged: (first sample, end sample).
List<(int, int)> voicedSpans(List<(int, int)> parts, int total) {
  final pad = (voicePadS * speechRate).round(), out = <(int, int)>[];
  for (final (start, n) in parts) {
    final lo = math.max(0, start - pad), hi = math.min(total, start + n + pad);
    if (out.isNotEmpty && lo <= out.last.$2) {
      out.last = (out.last.$1, math.max(out.last.$2, hi));
    } else {
      out.add((lo, hi));
    }
  }
  return out;
}

/// The voice detector's [parts], each followed by [joinGapS] of silence; empty when there are none.
Float32List joinVoiced(List<Float32List> parts) {
  if (parts.isEmpty) return Float32List(0);
  final gap = (joinGapS * speechRate).round();
  final out = Float32List(parts.fold(0, (n, p) => n + p.length + gap));
  var at = 0;
  for (final p in parts) {
    out.setAll(at, p);
    at += p.length + gap;
  }
  return out;
}
