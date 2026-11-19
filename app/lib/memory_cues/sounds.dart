// The memory cues' two sounds (DECISIONS 501): sound 0, a soft bell (one struck tone with a bell's off-key overtone,
// fading); sound 1, a soft double knock (two short wooden strikes). Unlike each other in pitch and rhythm, unlike the
// lucid dream cue's three rising tones, and equally strong (the same RMS), so neither half of the board is learned with
// the louder sound. The app writes them once as WAV files in its own folder; Android's media player plays them on the
// media stream at a share of the media volume (lucid/bell.dart `CueBell`, PhoneChannel.kt `playCue`), from the screen
// in the evening and from the night recorder's service at night. Plain Dart: the recorder's isolate has no sound
// engine.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../sound/synth.dart' show synthRate, wav16;

/// The sounds' names in the files: sound_a.wav (the bell) and sound_b.wav (the knock).
const List<String> memorySoundFiles = ['sound_a.wav', 'sound_b.wav'];

/// The louder of the two peaks in the files.
const double memorySoundPeak = 0.9;

Float32List _bell() {
  const f = 660.0, over = 2.76, tau = 0.22, len = 0.7, attack = 0.005, release = 0.03;
  final n = (len * synthRate).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final t = i / synthRate;
    final env = math.exp(-t / tau) * _edges(t, len, attack, release);
    out[i] = env * (math.sin(2 * math.pi * f * t) + 0.3 * math.sin(2 * math.pi * f * over * t) * math.exp(-t / 0.08));
  }
  return out;
}

Float32List _knock() {
  const f = 520.0, tau = 0.05, strike = 0.18, apart = 0.2, len = 0.45, attack = 0.002, release = 0.03;
  final n = (len * synthRate).round();
  final out = Float32List(n);
  for (final at in [0.0, apart]) {
    final from = (at * synthRate).round(), m = (strike * synthRate).round();
    for (var i = 0; i < m && from + i < n; i++) {
      final t = i / synthRate;
      final env = math.exp(-t / tau) * _edges(t, strike, attack, release);
      out[from + i] += env * (math.sin(2 * math.pi * f * t) + 0.25 * math.sin(2 * math.pi * 4 * f * t));
    }
  }
  return out;
}

/// A raised-cosine start of [attack] s and end of [release] s on a sound [len] s long.
double _edges(double t, double len, double attack, double release) {
  if (t < attack) return 0.5 - 0.5 * math.cos(math.pi * t / attack);
  if (t > len - release) return math.max(0, 0.5 - 0.5 * math.cos(math.pi * (len - t) / release));
  return 1;
}

double _rms(Float32List x) => math.sqrt(x.fold(0.0, (a, v) => a + v * v) / x.length);
double _peak(Float32List x) => x.fold(0.0, (a, v) => math.max(a, v.abs()));

/// Both sounds scaled to one RMS, the larger peak at [memorySoundPeak].
List<Float32List> _scaled() {
  final raw = [_bell(), _knock()];
  final rms = math.min(memorySoundPeak / (_peak(raw[0]) / _rms(raw[0])), memorySoundPeak / (_peak(raw[1]) / _rms(raw[1])));
  return [
    for (final x in raw) Float32List.fromList([for (final v in x) v * rms / _rms(x)]),
  ];
}

final List<Uint8List> _bytes = [for (final x in _scaled()) wav16([x])];

/// Sound [sound] (0 the bell, 1 the knock) as 16-bit PCM WAV, mono, 48 kHz.
Uint8List memorySoundBytes(int sound) => _bytes[sound];

/// Writes both sound files into [dir] if missing or not this app's current sounds; returns them (sound 0, sound 1).
List<File> ensureMemorySounds(Directory dir) => [
  for (var s = 0; s < 2; s++) _ensure(File('${dir.path}/${memorySoundFiles[s]}'), memorySoundBytes(s)),
];

File _ensure(File f, Uint8List bytes) {
  var same = f.existsSync() && f.lengthSync() == bytes.length;
  if (same) {
    final have = f.readAsBytesSync();
    for (var i = 0; i < have.length && same; i++) {
      same = have[i] == bytes[i];
    }
  }
  if (!same) {
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(f.path);
  }
  return f;
}
