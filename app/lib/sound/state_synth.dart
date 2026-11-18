// The sound for states, made sample by sample in Dart (pure: no audio device), streamed to flutter_soloud by
// state_sound.dart. Made here rather than from looped files and engine filters so that every kind of sound is exact
// and tested: no loop seam ever (the noise runs on), raised-cosine pulse edges, a beat whose rate slides smoothly,
// and the same K-weighted loudness for every bed and beat, so "beat or no beat" is never "louder or quieter".
//   beds:  rain (the meditation's rain and wind recipe: pink noise 350-2400 Hz, brown-noise wind in a band that
//          wanders on a 19 s loop, gusts on an 11 s loop), pink noise (Paul Kellet's filter), brown noise (a leaky
//          integrator with a DC blocker), ocean (two layers of low-passed brown noise swelling on 9 s and 13 s loops)
//   beats: pulsed noise (pink noise whose gain swings between 1 - depth and 1 at the rate), isochronic tones (a
//          tone switched by a raised-cosine pulse, edges 12 ms or a fifth of the period, 50 % duty; the build guide's
//          worklet), binaural beats (carrier - rate/2 in the left ear, + rate/2 in the right)
// The two ears get independent noise. Every oscillator keeps its phase, so the slide and the chunks are seamless.
// Recipes follow scripts/web/beats.html and sound-engine.js; GPL beat generators were read for ideas only.
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/filters.dart' show bandPass, highPass, lowPass;
import '../feedback/features.dart' show Biquad;
import '../states/presets.dart';
import 'synth.dart' show synthRate;

// ---- loudness ----

/// BS.1770 K-weighting at 48 kHz: the head's high shelf, then the RLB high-pass.
const List<double> _kShelf = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585];
const List<double> _kHigh = [1, -2, 1, -1.99004745483398, 0.99007225036621];

/// K-weighted loudness of interleaved stereo frames (L, R), BS.1770 without gating, in LUFS: -0.691 + 10 log10 of
/// the summed mean squares of the two channels. Meant for steady sounds such as these beds and beats.
double kLoudness(Float32List interleaved) {
  final n = interleaved.length ~/ 2;
  if (n == 0) return double.negativeInfinity;
  var total = 0.0;
  for (var ch = 0; ch < 2; ch++) {
    final a = Biquad(_kShelf), b = Biquad(_kHigh);
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      final y = b.step(a.step(interleaved[2 * i + ch]));
      s += y * y;
    }
    total += s / n;
  }
  return total <= 0 ? double.negativeInfinity : -0.691 + 10 * math.log(total) / math.ln10;
}

// ---- the pulse ----

/// The isochronic envelope (0..1) at [phase] (0..1 of a period) for a pulse rate of [rateHz]: a raised-cosine rise
/// of 12 ms or a fifth of the period (whichever is shorter), a flat top, a raised-cosine fall, then silence for the
/// second half of the period.
double isoEnvelope(double phase, double rateHz) {
  final e = math.min(0.2, 0.012 * rateHz);
  if (phase < e) return 0.5 - 0.5 * math.cos(math.pi * phase / e);
  if (phase < 0.5 - e) return 1;
  if (phase < 0.5) return 0.5 + 0.5 * math.cos(math.pi * (phase - (0.5 - e)) / e);
  return 0;
}

// ---- noise ----

/// xorshift32: uniforms in [-1, 1), fast enough to run per sample on the phone.
class _Noise {
  _Noise(int seed) : _s = (seed * 2654435761 + 1) & 0xFFFFFFFF {
    if (_s == 0) _s = 1;
  }
  int _s;

  double next() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x;
    return x / 2147483648.0 - 1;
  }
}

/// Paul Kellet's refined pink filter (beats.html).
class _Pink {
  _Pink(int seed) : _w = _Noise(seed);
  final _Noise _w;
  double _b0 = 0, _b1 = 0, _b2 = 0, _b3 = 0, _b4 = 0, _b5 = 0, _b6 = 0;

  double next() {
    final w = _w.next();
    _b0 = 0.99886 * _b0 + w * 0.0555179;
    _b1 = 0.99332 * _b1 + w * 0.0750759;
    _b2 = 0.969 * _b2 + w * 0.153852;
    _b3 = 0.8665 * _b3 + w * 0.3104856;
    _b4 = 0.55 * _b4 + w * 0.5329522;
    _b5 = -0.7616 * _b5 - w * 0.016898;
    final out = _b0 + _b1 + _b2 + _b3 + _b4 + _b5 + _b6 + w * 0.5362;
    _b6 = w * 0.115926;
    return out * 0.11;
  }
}

/// Paul Kellet's economy pink filter, as the meditation's rain (synth.dart rainLoop).
class _EconomyPink {
  _EconomyPink(int seed) : _w = _Noise(seed);
  final _Noise _w;
  double _b0 = 0, _b1 = 0, _b2 = 0;

  double next() {
    final w = _w.next();
    _b0 = 0.99765 * _b0 + w * 0.099046;
    _b1 = 0.963 * _b1 + w * 0.2965164;
    _b2 = 0.57 * _b2 + w * 1.0526913;
    return (_b0 + _b1 + _b2 + w * 0.1848) * 0.18;
  }
}

/// Brown noise: a leaky integrator (beats.html) and a DC blocker, so it never drifts off zero.
class _Brown {
  _Brown(int seed) : _w = _Noise(seed);
  final _Noise _w;
  double _br = 0, _x1 = 0, _y1 = 0;

  double next() {
    _br = (_br + 0.02 * _w.next()) / 1.02;
    final y = _br - _x1 + 0.995 * _y1;
    _x1 = _br;
    _y1 = y;
    return y * 3.5;
  }
}

/// A slow swell between [lo] and [hi] over [periodS], starting at [lo].
double _swell(double t, double periodS, double lo, double hi) => lo + (hi - lo) * (1 - math.cos(2 * math.pi * t / periodS)) / 2;

/// Writes [n] frames of one layer into [l] and [r]; [frame0] is the first frame's number since the start, which was
/// [startS] seconds into the plan.
abstract class _Layer {
  void fill(Float32List l, Float32List r, int n, int frame0, double startS);
}

/// Settings that move (a filter's centre, a swell, the beat's rate) are recomputed every [_block] frames (1.3 ms),
/// counted from the start, so the sound does not depend on how it is cut into chunks.
const int _block = 64;

/// Calls [body] for each block of the frames 0 .. n-1 of a chunk starting at [frame0], with its plan time.
void _blocks(int n, int frame0, double startS, void Function(int i0, int end, double t) body) {
  var i0 = 0;
  while (i0 < n) {
    final into = (frame0 + i0) % _block, end = math.min(n, i0 + _block - into);
    body(i0, end, startS + (frame0 + i0 - into) / synthRate); // the time of the block's first frame
    i0 = end;
  }
}

class _RainBed implements _Layer {
  _RainBed(int seed)
    : _rain = [_EconomyPink(seed), _EconomyPink(seed + 1)],
      _wind = [_Brown(seed + 2), _Brown(seed + 3)],
      _hp = [Biquad(highPass(350, sampleRate: synthRate)), Biquad(highPass(350, sampleRate: synthRate))],
      _lp = [Biquad(lowPass(2400, sampleRate: synthRate)), Biquad(lowPass(2400, sampleRate: synthRate))],
      _band = [Biquad(bandPass(420, 0.8, sampleRate: synthRate)), Biquad(bandPass(420, 0.8, sampleRate: synthRate))];
  final List<_EconomyPink> _rain;
  final List<_Brown> _wind;
  final List<Biquad> _hp, _lp, _band;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    _blocks(n, frame0, startS, (i0, end, t) {
      final centre = _swell(t, 19, 240, 600), gust = 0.55 * _swell(t, 11, 0.3, 0.8);
      final c = bandPass(centre, 0.8, sampleRate: synthRate);
      for (final b in _band) {
        b.c.setAll(0, c);
      }
      for (var ch = 0; ch < 2; ch++) {
        final out = ch == 0 ? l : r, rain = _rain[ch], wind = _wind[ch], hp = _hp[ch], lp = _lp[ch], band = _band[ch];
        for (var i = i0; i < end; i++) {
          out[i] = lp.step(hp.step(rain.next())) + gust * band.step(wind.next());
        }
      }
    });
  }
}

class _PinkBed implements _Layer {
  _PinkBed(int seed) : _p = [_Pink(seed), _Pink(seed + 1)];
  final List<_Pink> _p;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    final a = _p[0], b = _p[1];
    for (var i = 0; i < n; i++) {
      l[i] = a.next();
      r[i] = b.next();
    }
  }
}

class _BrownBed implements _Layer {
  _BrownBed(int seed) : _b = [_Brown(seed), _Brown(seed + 1)];
  final List<_Brown> _b;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    final a = _b[0], b = _b[1];
    for (var i = 0; i < n; i++) {
      l[i] = a.next();
      r[i] = b.next();
    }
  }
}

/// Two wave layers (alpha-theta's ocean): brown noise under 650 Hz, swelling on 9 s and 13 s loops.
class _OceanBed implements _Layer {
  _OceanBed(int seed)
    : _n = [for (var k = 0; k < 4; k++) _Brown(seed + k)],
      _lp = [for (var k = 0; k < 4; k++) Biquad(lowPass(650, sampleRate: synthRate))];
  final List<_Brown> _n;
  final List<Biquad> _lp;
  static const List<(double, double)> _waves = [(9, 1.0), (13, 0.7)];

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    _blocks(n, frame0, startS, (i0, end, t) {
      final g = [for (final (period, level) in _waves) _swell(t, period, level * 0.15, level)];
      for (var ch = 0; ch < 2; ch++) {
        final out = ch == 0 ? l : r, a = _n[ch], b = _n[ch + 2], la = _lp[ch], lb = _lp[ch + 2];
        for (var i = i0; i < end; i++) {
          out[i] = g[0] * la.step(a.next()) + g[1] * lb.step(b.next());
        }
      }
    });
  }
}

/// The beat layers keep the pulse phase themselves: the rate comes from the plan at each block.
class _PulsedBeat implements _Layer {
  _PulsedBeat(this.plan, int seed) : _p = [_Pink(seed + 10), _Pink(seed + 11)];
  final SoundPlan plan;
  final List<_Pink> _p;
  double _phase = 0;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    final d = plan.depth;
    _blocks(n, frame0, startS, (i0, end, t) {
      final rate = plan.rateAt(t)!, step = rate / synthRate;
      for (var i = i0; i < end; i++) {
        final g = 1 - d / 2 + d / 2 * math.sin(2 * math.pi * _phase);
        l[i] = g * _p[0].next();
        r[i] = g * _p[1].next();
        _phase += step;
        if (_phase >= 1) _phase -= 1;
      }
    });
  }
}

class _IsochronicBeat implements _Layer {
  _IsochronicBeat(this.plan);
  final SoundPlan plan;
  double _pulse = 0, _carrier = 0;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    final d = plan.depth, cStep = plan.carrierHz / synthRate;
    _blocks(n, frame0, startS, (i0, end, t) {
      final rate = plan.rateAt(t)!, step = rate / synthRate;
      for (var i = i0; i < end; i++) {
        final v = math.sin(2 * math.pi * _carrier) * (1 - d + d * isoEnvelope(_pulse, rate));
        l[i] = v;
        r[i] = v;
        _pulse += step;
        if (_pulse >= 1) _pulse -= 1;
        _carrier += cStep;
        if (_carrier >= 1) _carrier -= 1;
      }
    });
  }
}

class _BinauralBeat implements _Layer {
  _BinauralBeat(this.plan);
  final SoundPlan plan;
  double _left = 0, _right = 0;

  @override
  void fill(Float32List l, Float32List r, int n, int frame0, double startS) {
    _blocks(n, frame0, startS, (i0, end, t) {
      final rate = plan.rateAt(t)!;
      final sl = (plan.carrierHz - rate / 2) / synthRate, sr = (plan.carrierHz + rate / 2) / synthRate;
      for (var i = i0; i < end; i++) {
        l[i] = math.sin(2 * math.pi * _left);
        r[i] = math.sin(2 * math.pi * _right);
        _left += sl;
        if (_left >= 1) _left -= 1;
        _right += sr;
        if (_right >= 1) _right -= 1;
      }
    });
  }
}

_Layer? _bedOf(Bed bed, int seed) => switch (bed) {
  Bed.rain => _RainBed(seed),
  Bed.pink => _PinkBed(seed),
  Bed.brown => _BrownBed(seed),
  Bed.ocean => _OceanBed(seed),
  Bed.none => null,
};

_Layer? _beatOf(SoundPlan plan, int seed) => switch (plan.beat) {
  Beat.pulsed => _PulsedBeat(plan, seed),
  Beat.isochronic => _IsochronicBeat(plan),
  Beat.binaural => _BinauralBeat(plan),
  Beat.none => null,
};

// ---- the session's sound ----

class StateSynth {
  /// [atS]: where in the plan's time the sound begins (the beat's slide); 0 for a session.
  StateSynth(this.plan, {this.bedGain = 1, this.beatGain = 1, int seed = 1, double atS = 0})
    : _bed = bedGain == 0 ? null : _bedOf(plan.bed, seed),
      _beat = beatGain == 0 ? null : _beatOf(plan, seed),
      _start = atS;

  /// [plan] at [targetLufs], each layer at its share (gainsFor).
  factory StateSynth.calibrated(SoundPlan plan, {int seed = 1}) {
    final g = gainsFor(plan, seed: seed);
    return StateSynth(plan, bedGain: g.bed, beatGain: g.beat, seed: seed);
  }

  final SoundPlan plan;
  final double bedGain;
  final double beatGain;
  final _Layer? _bed;
  final _Layer? _beat;
  final double _start;
  int _frames = 0;
  Float32List _l = Float32List(0), _r = Float32List(0), _l2 = Float32List(0), _r2 = Float32List(0);

  /// Seconds made so far.
  double get seconds => _frames / synthRate;

  /// The next [frames] stereo frames, interleaved left, right; -1..1.
  Float32List next(int frames) {
    if (_l.length < frames) {
      _l = Float32List(frames);
      _r = Float32List(frames);
      _l2 = Float32List(frames);
      _r2 = Float32List(frames);
    }
    final out = Float32List(2 * frames);
    final bed = _bed, beat = _beat;
    if (bed != null) bed.fill(_l, _r, frames, _frames, _start);
    if (beat != null) beat.fill(_l2, _r2, frames, _frames, _start);
    for (var i = 0; i < frames; i++) {
      var left = 0.0, right = 0.0;
      if (bed != null) {
        left += bedGain * _l[i];
        right += bedGain * _r[i];
      }
      if (beat != null) {
        left += beatGain * _l2[i];
        right += beatGain * _r2[i];
      }
      out[2 * i] = left.clamp(-1.0, 1.0);
      out[2 * i + 1] = right.clamp(-1.0, 1.0);
    }
    _frames += frames;
    return out;
  }

  /// Gains that bring the bed and the beat of [plan] to their shares of [targetLufs], each measured alone at gain 1
  /// over [bedSeconds] and [beatSeconds] from the start (the ocean's slowest swell is 13 s: 26 s holds two).
  static ({double bed, double beat}) gainsFor(SoundPlan plan, {int seed = 1, double bedSeconds = 26, double beatSeconds = 4}) {
    double gain(double share, double measured) =>
        share <= 0 || !measured.isFinite ? 0 : math.pow(10, (targetLufs + 10 * math.log(share) / math.ln10 - measured) / 20).toDouble();
    var bed = 0.0, beat = 0.0;
    if (plan.bedShare > 0) {
      final x = StateSynth(plan, beatGain: 0, seed: seed).next((bedSeconds * synthRate).round());
      bed = gain(plan.bedShare, kLoudness(x));
    }
    if (plan.beatShare > 0) {
      final x = StateSynth(plan, bedGain: 0, seed: seed).next((beatSeconds * synthRate).round());
      beat = gain(plan.beatShare, kLoudness(x));
    }
    return (bed: bed, beat: beat);
  }
}
