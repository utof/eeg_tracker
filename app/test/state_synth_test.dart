// The sound-for-states synthesis (lib/sound/state_synth.dart), without an audio device: loudness by the BS.1770
// reference, every bed and beat at the same loudness, the beat really in the sound (or, for binaural, only between the
// ears), soft isochronic edges, no seams between chunks, no clipping.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/sound/state_synth.dart';
import 'package:eeg_tracker/sound/synth.dart' show synthRate;
import 'package:eeg_tracker/states/presets.dart';
import 'package:flutter_test/flutter_test.dart';

/// [seconds] of a sine at [hz], amplitude [amp], in the left channel only (or both).
Float32List sine(double hz, double seconds, {double amp = 1, bool both = false}) {
  final n = (seconds * synthRate).round(), out = Float32List(2 * n);
  for (var i = 0; i < n; i++) {
    final v = amp * math.sin(2 * math.pi * hz * i / synthRate);
    out[2 * i] = v;
    if (both) out[2 * i + 1] = v;
  }
  return out;
}

/// The loudness envelope of one channel (or the sum, [ch] = null): mean square per millisecond.
List<double> envelope(Float32List x, {int? ch}) {
  final n = x.length ~/ 2, per = synthRate ~/ 1000, out = <double>[];
  for (var i = 0; i + per <= n; i += per) {
    var s = 0.0;
    for (var j = i; j < i + per; j++) {
      final v = ch == null ? x[2 * j] + x[2 * j + 1] : x[2 * j + ch];
      s += v * v;
    }
    out.add(s / per);
  }
  return out;
}

/// Share of the envelope's power (mean removed) at [hz], from a DFT of the 1 kHz envelope.
double rhythmShare(List<double> env, double hz) {
  final mean = env.reduce((a, b) => a + b) / env.length;
  var re = 0.0, im = 0.0, total = 0.0;
  for (var i = 0; i < env.length; i++) {
    final v = env[i] - mean, a = 2 * math.pi * hz * i / 1000;
    re += v * math.cos(a);
    im -= v * math.sin(a);
    total += v * v;
  }
  // a pure oscillation at hz puts (N/2)·A²/... : normalise so a pure sine of the envelope gives 1
  return total == 0 ? 0 : 2 * (re * re + im * im) / (env.length * total);
}

/// Zero crossings per second of one channel: twice its frequency.
double hzOf(Float32List x, int ch) {
  var n = 0;
  for (var i = 1; i < x.length ~/ 2; i++) {
    if ((x[2 * (i - 1) + ch] < 0) != (x[2 * i + ch] < 0)) n++;
  }
  return n / 2 / (x.length / 2 / synthRate);
}

Float32List render(SoundPlan plan, double seconds, {StateSynth? synth}) {
  final s = synth ?? StateSynth.calibrated(plan);
  return s.next((seconds * synthRate).round());
}

void main() {
  group('loudness (BS.1770 K-weighting, ungated)', () {
    test('a full-scale 1 kHz sine in one channel is -3.01 LUFS, in both 0', () {
      expect(kLoudness(sine(997, 4)), closeTo(-3.01, 0.05));
      expect(kLoudness(sine(997, 4, both: true)), closeTo(0, 0.05));
      expect(kLoudness(sine(997, 4, amp: 0.1, both: true)), closeTo(-20, 0.05));
      expect(kLoudness(Float32List(2000)), double.negativeInfinity);
    });
  });

  group('every sound at the same loudness', () {
    final cases = <(String, SoundPlan)>[
      for (final b in [Bed.rain, Bed.pink, Bed.brown, Bed.ocean]) ('${b.name} alone', SoundPlan.of(SoundState.relax, bed: b)),
      for (final b in [Beat.pulsed, Beat.isochronic, Beat.binaural])
        ('${b.name} alone', SoundPlan.of(SoundState.relax, bed: Bed.none, beat: b)),
      ('pink + pulsed, fall asleep', SoundPlan.of(SoundState.asleep, beat: Beat.pulsed)),
      ('rain + binaural, wake up', SoundPlan.of(SoundState.wake, bed: Bed.rain, beat: Beat.binaural)),
      ('ocean + isochronic, relax', SoundPlan.of(SoundState.relax, beat: Beat.isochronic)),
    ];
    for (final (name, plan) in cases) {
      test('$name: ${targetLufs.round()} LUFS within 0.5 dB, peaks under 0.9', () {
        final x = render(plan, 26);
        expect(kLoudness(x), closeTo(targetLufs, 0.5));
        var peak = 0.0;
        for (final v in x) {
          peak = math.max(peak, v.abs());
        }
        expect(peak, lessThan(0.9));
      });
    }

    test('beat or no beat is not louder or quieter: the bed alone matches the bed with a beat', () {
      final none = kLoudness(render(SoundPlan.of(SoundState.relax, bed: Bed.pink), 20));
      final beat = kLoudness(render(SoundPlan.of(SoundState.relax, bed: Bed.pink, beat: Beat.pulsed), 20));
      expect((none - beat).abs(), lessThan(0.5));
    });

    test('the beat sits about 6 dB above the bed under it', () {
      final plan = SoundPlan.of(SoundState.relax, bed: Bed.pink, beat: Beat.isochronic);
      final g = StateSynth.gainsFor(plan);
      final bed = kLoudness(StateSynth(plan, bedGain: g.bed, beatGain: 0).next(20 * synthRate));
      final beat = kLoudness(StateSynth(plan, bedGain: 0, beatGain: g.beat).next(20 * synthRate));
      expect(beat - bed, closeTo(6.02, 0.5));
    });
  });

  group('the beat', () {
    test('isochronic edges: raised cosine, 12 ms or a fifth of the period, then flat, then silence', () {
      // 10 Hz: period 100 ms, edge 12 ms = 0.12 of a period
      expect(isoEnvelope(0, 10), 0);
      expect(isoEnvelope(0.06, 10), closeTo(0.5, 1e-12));
      expect(isoEnvelope(0.12, 10), closeTo(1, 1e-12));
      expect(isoEnvelope(0.3, 10), 1);
      expect(isoEnvelope(0.44, 10), closeTo(0.5, 1e-12));
      expect(isoEnvelope(0.5, 10), closeTo(0, 1e-12));
      expect(isoEnvelope(0.75, 10), 0);
      // 40 Hz: a fifth of the 25 ms period (5 ms), not 12 ms
      expect(isoEnvelope(0.1, 40), closeTo(0.5, 1e-12));
      expect(isoEnvelope(0.2, 40), closeTo(1, 1e-12));
      // 2 Hz: still 12 ms (0.024 of the period)
      expect(isoEnvelope(0.012, 2), closeTo(0.5, 1e-12));
    });

    test('isochronic and pulsed noise carry the rhythm in the sound; no beat carries none', () {
      for (final b in [Beat.isochronic, Beat.pulsed]) {
        final x = render(SoundPlan.of(SoundState.relax, bed: Bed.none, beat: b), 4);
        expect(rhythmShare(envelope(x, ch: 0), 10), greaterThan(0.3), reason: '${b.name} at 10 Hz');
        expect(rhythmShare(envelope(x, ch: 0), 13), lessThan(0.02), reason: '${b.name} not at 13 Hz');
      }
      final plain = render(SoundPlan.of(SoundState.relax, bed: Bed.pink), 4);
      expect(rhythmShare(envelope(plain, ch: 0), 10), lessThan(0.02));
    });

    test('binaural: a steady tone in each ear (carrier - beat/2 left, + beat/2 right) that beats only when mixed', () {
      final x = render(SoundPlan.of(SoundState.relax, bed: Bed.none, beat: Beat.binaural), 4);
      expect(hzOf(x, 0), closeTo(195, 0.5));
      expect(hzOf(x, 1), closeTo(205, 0.5));
      expect(rhythmShare(envelope(x, ch: 0), 10), lessThan(0.02), reason: 'no pulse in one ear');
      expect(rhythmShare(envelope(x), 10), greaterThan(0.3), reason: 'a speaker mixes the ears: an ordinary beat');
    });

    test('the rate follows the plan\'s slide: fall asleep reaches 3 Hz', () {
      final plan = SoundPlan.of(SoundState.asleep, bed: Bed.none, beat: Beat.isochronic, minutes: 15);
      final end = StateSynth(plan, atS: plan.rampS).next(4 * synthRate);
      expect(rhythmShare(envelope(end, ch: 0), 3), greaterThan(0.3));
      expect(rhythmShare(envelope(end, ch: 0), 10), lessThan(0.02));
      final middle = StateSynth(plan, atS: plan.rampS / 2).next(4 * synthRate); // sqrt(10 * 3) = 5.48 Hz
      expect(rhythmShare(envelope(middle, ch: 0), math.sqrt(30)), greaterThan(0.3));
    });
  });

  group('streaming', () {
    test('chunks join without a seam: any chunking gives the same samples', () {
      final plan = SoundPlan.of(SoundState.relax, bed: Bed.rain, beat: Beat.pulsed);
      final whole = StateSynth(plan).next(30000);
      final parts = StateSynth(plan);
      final joined = Float32List.fromList([...parts.next(101), ...parts.next(4999), ...parts.next(24900)]);
      expect(joined, whole);
      expect(parts.seconds, closeTo(30000 / synthRate, 1e-12));
    });

    test('the same plan and seed make the same sound; another seed another noise', () {
      final plan = SoundPlan.of(SoundState.relax, bed: Bed.ocean);
      expect(StateSynth(plan).next(5000), StateSynth(plan).next(5000));
      expect(StateSynth(plan, seed: 2).next(5000), isNot(StateSynth(plan).next(5000)));
    });

    test('the two ears get different noise (a wide bed), and the bed never sits still', () {
      final x = render(SoundPlan.of(SoundState.relax, bed: Bed.pink), 1);
      var same = 0;
      for (var i = 0; i < x.length; i += 2) {
        if (x[i] == x[i + 1]) same++;
      }
      expect(same, lessThan(10));
    });
  });
}
