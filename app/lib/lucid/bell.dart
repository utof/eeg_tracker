// The lucid dream cue and how it is played (DECISIONS 301, 303): three soft rising tones, 400, 600 and 800 Hz, about
// 0.65 s in all, as in the lab and home TLR studies (Konkoly 2021, 2024). The app writes it once as a WAV file in its
// own folder; Android's media player plays it on the media stream at a share of the media volume ("eeg_tracker/phone"
// `playCue`, PhoneChannel.kt), from the screen in the evening practice and from the night recorder's service at night,
// so the practice and the night use the same sound at the same loudness. Plain Dart besides the channel: the
// recorder's isolate carries no sound engine.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../sound/synth.dart' show synthRate, wav16;

/// The three tones (Hz), each this long with soft edges, this far apart (start to start).
const List<double> cueHz = [400, 600, 800];
const double cueToneS = 0.19, cueEdgeS = 0.015, cueEveryS = 0.23;

/// The cue's peak in the file; the player's gain scales it.
const double cuePeak = 0.9;

/// The cue as 16-bit PCM WAV (mono, 48 kHz).
Uint8List cueWavBytes() {
  final n = ((cueEveryS * (cueHz.length - 1) + cueToneS) * synthRate).round();
  final out = Float32List(n);
  final len = (cueToneS * synthRate).round(), edge = (cueEdgeS * synthRate).round();
  for (var k = 0; k < cueHz.length; k++) {
    final at = (k * cueEveryS * synthRate).round();
    for (var i = 0; i < len && at + i < n; i++) {
      final ramp = i < edge
          ? 0.5 - 0.5 * math.cos(math.pi * i / edge)
          : i >= len - edge
          ? 0.5 - 0.5 * math.cos(math.pi * (len - 1 - i) / edge)
          : 1.0;
      out[at + i] += cuePeak * ramp * math.sin(2 * math.pi * cueHz[k] * i / synthRate);
    }
  }
  return wav16([out]);
}

/// Writes the cue file if it is missing or not this app's current cue.
File ensureCueWav(File f) {
  final bytes = cueWavBytes();
  if (!f.existsSync() || f.lengthSync() != bytes.length) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(f.path);
  }
  return f;
}

/// How the cue reaches the speaker or the earbuds.
abstract interface class CueBell {
  /// Plays the cue file once at [gain] (0-1 of the media volume). False when the phone could not.
  Future<bool> play(File cue, double gain);

  /// The media volume step and its largest step; null when unknown.
  Future<({int volume, int max})?> mediaVolume();
}

class ChannelCueBell implements CueBell {
  static const MethodChannel _channel = MethodChannel('eeg_tracker/phone');

  @override
  Future<bool> play(File cue, double gain) async =>
      await _channel.invokeMethod<bool>('playCue', {'path': cue.path, 'gain': gain.clamp(0.0, 1.0)}) ?? false;

  @override
  Future<({int volume, int max})?> mediaVolume() async {
    try {
      final m = await _channel.invokeMethod<Map<Object?, Object?>>('mediaVolume');
      final v = m?['volume'], x = m?['max'];
      return v is int && x is int ? (volume: v, max: x) : null;
    } on MissingPluginException {
      return null;
    }
  }
}
