// The sound's pure parts: generated material (WAV layout, seamless loops, struck tones), the generator matching
// the JS one, and the glide planner that hands targets to the audio engine.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/feedback/demo.dart';
import 'package:eeg_tracker/feedback/mapping.dart';
import 'package:eeg_tracker/sound/glide.dart';
import 'package:eeg_tracker/sound/synth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mulberry32 gives the same numbers as the JS generator', () {
    final u = uniform(7);
    // node: the rng of scripts/web/sound-demo.js with seed 7
    expect([u(), u(), u(), u()], [0.011704753153026104, 0.06195825757458806, 0.97690763277933, 0.6990287057124078]);
  });

  test('wav16: a valid 16-bit PCM header and interleaved, clipped samples', () {
    final l = Float32List.fromList([0, 0.5, -1.5]), r = Float32List.fromList([1, -0.5, 0]);
    final w = wav16([l, r], sampleRate: 48000), b = ByteData.sublistView(w);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 16)), 'WAVEfmt ');
    expect(b.getUint16(22, Endian.little), 2);
    expect(b.getUint32(24, Endian.little), 48000);
    expect(b.getUint32(40, Endian.little), 3 * 2 * 2);
    expect(w.length, 44 + 12);
    expect([for (var i = 0; i < 6; i++) b.getInt16(44 + 2 * i, Endian.little)], [0, 32767, 16384, -16384, -32767, 0]);
  });

  test('rain and wind loops join their own start smoothly and stay in range', () {
    for (final loop in [rainLoop(0.5, 1, sampleRate: 8000), windLoop(0.5, 3, sampleRate: 8000)]) {
      expect(loop.length, 4000);
      var maxStep = 0.0, peak = 0.0;
      for (var i = 1; i < loop.length; i++) {
        maxStep = math.max(maxStep, (loop[i] - loop[i - 1]).abs());
        peak = math.max(peak, loop[i].abs());
      }
      expect(peak, lessThan(1));
      // the wrap from the last sample to the first is no bigger a step than the signal's own steps
      expect((loop.first - loop.last).abs(), lessThanOrEqualTo(maxStep * 1.01));
    }
  });

  test('strike: rises in 10 ms, decays to silence, peak under full scale', () {
    final t = strike(440, bellPartials, sampleRate: 8000);
    expect(t.length, ((4.5 + 0.1) * 8000).ceil());
    final early = t.sublist(0, 80).map((v) => v.abs()).reduce(math.max);
    final mid = t.sublist(400, 1200).map((v) => v.abs()).reduce(math.max);
    final end = t.sublist(t.length - 1000).map((v) => v.abs()).reduce(math.max);
    expect(mid, greaterThan(early));
    expect(mid, lessThanOrEqualTo(1));
    expect(end, lessThan(0.001));
    expect(toneGain(bellPartials, bellLevel), closeTo(0.11 * 1.73, 1e-9));
    expect(bellOrder.every((i) => i >= 0 && i < bellNotes.length), isTrue);
  });

  test('glider: a fade only when a setting changes, rise and fall times from the mode, 1.4 tau long', () {
    final g = Glider();
    final calm = mapState(z: 2, jaw: 0, quality: 'good', veto: null);
    final first = g.next(calm);
    expect({for (final f in first) f.key}, containsAll(['rain', 'rainTone', 'drone', 'warmth', 'droneTone']));
    expect(first.firstWhere((f) => f.key == 'rain').seconds, closeTo(0.25 * fadePerTau, 1e-12));
    expect(first.firstWhere((f) => f.key == 'warmth').seconds, closeTo(1.5 * fadePerTau, 1e-12));
    expect(g.next(calm), isEmpty, reason: 'unchanged targets cost nothing');
    final clench = mapState(z: 2, jaw: 0.8, quality: 'good', veto: 'muscle');
    expect(g.next(clench).firstWhere((f) => f.key == 'rough').seconds, closeTo(0.08 * fadePerTau, 1e-12));
    for (var i = 0; i < 30; i++) {
      g.next(clench);
    }
    final relaxed = g.next(mapState(z: 2, jaw: 0, quality: 'good', veto: null));
    expect(relaxed.firstWhere((f) => f.key == 'rough').seconds, closeTo(1.2 * fadePerTau, 1e-12), reason: 'falls slowly');
    expect(() => Glider('loud'), throwsArgumentError);
  });
}
