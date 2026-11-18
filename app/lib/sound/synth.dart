// Sound material made in memory (pure: no audio device): seamless noise loops for rain and wind, bell and cue
// tones, and the WAV bytes the engine loads. The recipes follow scripts/web/sound-engine.js (Paul Kellet's
// pink filter, a leaky brown integrator, inharmonic bell partials), so the phone sounds like the laptop page.
import 'dart:math' as math;
import 'dart:typed_data';

import '../feedback/demo.dart' show uniform;
import '../feedback/features.dart' show Biquad;

/// Sample rate of everything made here and of the engine (research: 48 kHz, DECISIONS row 72).
const int synthRate = 48000;

/// 16-bit PCM WAV of one or more equally long channels in -1..1 (clipped).
Uint8List wav16(List<Float32List> channels, {int sampleRate = synthRate}) {
  final ch = channels.length, n = channels.first.length, dataBytes = n * ch * 2;
  final b = ByteData(44 + dataBytes);
  void text(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, ch, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * ch * 2, Endian.little)
    ..setUint16(32, ch * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  text(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  var o = 44;
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      final v = channels[c][i].clamp(-1.0, 1.0);
      b.setInt16(o, (v * 32767).round(), Endian.little);
      o += 2;
    }
  }
  return b.buffer.asUint8List();
}

/// [frames] of a loop that joins its own start without a click: made [fade] samples longer, and the extra
/// tail is blended into the start, so the last sample flows into the first as in the made signal.
Float32List _seamless(Float32List made, int frames, int fade) {
  final out = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    out[i] = made[i];
  }
  for (var i = 0; i < fade; i++) {
    final a = i / fade;
    out[i] = made[i] * a + made[frames + i] * (1 - a);
  }
  return out;
}

/// RBJ high-pass, Butterworth (Q = 0.707), as [Biquad] coefficients.
List<double> _highPass(double f0, int sampleRate) {
  final w = 2 * math.pi * f0 / sampleRate, al = math.sin(w) / (2 * math.sqrt1_2), cw = math.cos(w), a0 = 1 + al;
  return [(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - al) / a0];
}

/// Rain: pink noise above 350 Hz (the engine's low-pass, the "rain tone", follows the brain), [seconds] long,
/// one channel per [seed].
Float32List rainLoop(double seconds, int seed, {int sampleRate = synthRate}) {
  final frames = (seconds * sampleRate).floor(), fade = math.min(2000, frames >> 2), r = uniform(seed);
  final made = Float32List(frames + fade), hp = Biquad(_highPass(350, sampleRate));
  var b0 = 0.0, b1 = 0.0, b2 = 0.0;
  for (var i = 0; i < made.length; i++) {
    final w = r() * 2 - 1; // Paul Kellet's economy pink filter
    b0 = 0.99765 * b0 + w * 0.099046;
    b1 = 0.963 * b1 + w * 0.2965164;
    b2 = 0.57 * b2 + w * 1.0526913;
    made[i] = hp.step((b0 + b1 + b2 + w * 0.1848) * 0.18);
  }
  return _seamless(made, frames, fade);
}

/// Wind: brown noise (the engine band-passes it around a slowly moving 420 Hz).
Float32List windLoop(double seconds, int seed, {int sampleRate = synthRate}) {
  final frames = (seconds * sampleRate).floor(), fade = math.min(2000, frames >> 2), r = uniform(seed);
  final made = Float32List(frames + fade);
  var br = 0.0;
  for (var i = 0; i < made.length; i++) {
    br = (br + 0.02 * (r() * 2 - 1)) / 1.02;
    made[i] = br * 3.5;
  }
  return _seamless(made, frames, fade);
}

/// One partial of a struck tone: frequency ratio, amplitude, decay time to -80 dB (s).
typedef Partial = (double ratio, double amp, double decay);

/// Reward bell: inharmonic partials, slow decay (sound-engine.js `bell`).
const List<Partial> bellPartials = [(1, 1, 4.5), (2.76, 0.45, 2.2), (5.4, 0.2, 1.1), (8.93, 0.08, 0.6)];

/// Calibration cue: one low, soft tone, unlike the bell.
const List<Partial> cuePartials = [(1, 1, 1.8), (2, 0.25, 1)];

/// A major pentatonic-ish set and an 11-step order against the 7 notes, so the bells do not repeat a pattern.
const List<double> bellNotes = [440, 554.37, 659.25, 493.88, 739.99, 587.33, 830.61];
const List<int> bellOrder = [0, 2, 1, 4, 2, 6, 3, 0, 5, 2, 1];

/// Level of a bell and of the cue against the bed (sound-engine.js: 0.11 and 0.14).
const double bellLevel = 0.11, cueLevel = 0.14;

/// A struck tone at [hz]: each partial rises in 10 ms, then decays exponentially to 1/10000 at its decay
/// time. Scaled so the sum of the partial amplitudes is 1 (play it at volume level x [toneGain]).
Float32List strike(double hz, List<Partial> parts, {int sampleRate = synthRate}) {
  final longest = parts.map((p) => p.$3).reduce(math.max);
  final n = ((longest + 0.1) * sampleRate).ceil(), out = Float32List(n);
  final total = parts.fold(0.0, (s, p) => s + p.$2), attack = 0.01;
  for (final (ratio, amp, decay) in parts) {
    final f = hz * ratio, k = math.log(0.0001) / (decay - attack);
    final end = math.min(n, (decay * sampleRate).ceil());
    for (var i = 0; i < end; i++) {
      final t = i / sampleRate;
      final env = t < attack ? amp * t / attack : amp * math.exp(k * (t - attack));
      out[i] += env * math.sin(2 * math.pi * f * t) / total;
    }
  }
  return out;
}

/// The volume that gives a [strike] of [parts] the loudness of the laptop page's tone at [level].
double toneGain(List<Partial> parts, double level) => level * parts.fold(0.0, (s, p) => s + p.$2);
