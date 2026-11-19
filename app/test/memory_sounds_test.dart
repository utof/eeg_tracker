// The memory cues' two sounds (DECISIONS 501): short, soft, unlike each other and unlike the lucid dream cue, equally
// strong, written once as WAV files the night recorder plays.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/lucid/bell.dart' show cueWavBytes;
import 'package:eeg_tracker/memory_cues/sounds.dart';
import 'package:flutter_test/flutter_test.dart';

Float64List _samples(Uint8List wav) {
  final b = ByteData.sublistView(wav);
  expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
  expect(b.getUint16(22, Endian.little), 1, reason: 'mono');
  expect(b.getUint32(24, Endian.little), 48000);
  final n = (wav.length - 44) ~/ 2;
  return Float64List.fromList([for (var i = 0; i < n; i++) b.getInt16(44 + 2 * i, Endian.little) / 32767]);
}

double _rms(Float64List x) => math.sqrt(x.fold(0.0, (a, v) => a + v * v) / x.length);

void main() {
  test('two short sounds, peaks under full scale, equally strong within 1 dB', () {
    final a = _samples(memorySoundBytes(0)), b = _samples(memorySoundBytes(1));
    for (final x in [a, b]) {
      expect(x.length / 48000, inInclusiveRange(0.3, 0.9));
      expect(x.map((v) => v.abs()).reduce(math.max), inInclusiveRange(0.5, 0.91));
      expect(x.first.abs(), lessThan(0.01), reason: 'a soft start, no click');
      expect(x.last.abs(), lessThan(0.01), reason: 'a soft end');
    }
    final db = 20 * math.log(_rms(a) / _rms(b)) / math.ln10;
    expect(db.abs(), lessThan(1.0));
  });

  test('the two sounds and the lucid cue are three different sounds', () {
    final a = memorySoundBytes(0), b = memorySoundBytes(1), lucid = cueWavBytes();
    expect(a, isNot(b));
    expect(a.length, isNot(lucid.length));
    expect(b.length, isNot(lucid.length));
  });

  test('the files are written once and rewritten only when not this app\'s sound', () {
    final dir = Directory.systemTemp.createTempSync('memory_sounds_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = ensureMemorySounds(dir);
    expect(files, hasLength(2));
    expect(files[0].readAsBytesSync(), memorySoundBytes(0));
    files[1].writeAsBytesSync([1, 2, 3]);
    ensureMemorySounds(dir);
    expect(files[1].readAsBytesSync(), memorySoundBytes(1));
  });
}
