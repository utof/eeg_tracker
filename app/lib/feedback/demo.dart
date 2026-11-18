// Synthetic headband for the tests (a port of scripts/web/sound-demo.js, same recipe and generator).
// O1/O2 alpha strong when "eyes closed", weak when open; T3/T4 3 s bursts of fast muscle noise every 45 s;
// a blink-like bump every 7 s. The alpha amplitude wanders slowly (+-30 %, loops of 3.1, 5.3 and 8.9 s) and
// its frequency can be lowered (alphaHz) to imitate drifting toward sleep.
// Eyes: follow [eyes] when set ('open' | 'closed'), otherwise closed 60 s, open 60 s, from the start.
// The generator is mulberry32 + Box-Muller as in JS; sin, log and cos may differ from JS in the last bit,
// so a seed gives the same signal shape here and there, not bit-identical samples.
import 'dart:math' as math;

import 'features.dart';

bool autoEyesClosed(double t) => (t / 60).floor() % 2 == 0;
bool autoJaw(double t) => t.remainder(45) < 3;
double wander(double t) =>
    1 +
    0.3 *
        (0.5 * math.sin((2 * math.pi * t) / 3.1) +
            0.3 * math.sin((2 * math.pi * t) / 5.3 + 1) +
            0.2 * math.sin((2 * math.pi * t) / 8.9 + 2));

int _imul(int a, int b) => (a * b) & 0xFFFFFFFF;

/// mulberry32 uniforms in [0, 1), then Box-Muller normals.
double Function() gaussian(int seed) {
  var a = seed & 0xFFFFFFFF;
  double u() {
    a = (a + 0x6d2b79f5) & 0xFFFFFFFF;
    var t = a;
    t = _imul(t ^ (t >> 15), t | 1);
    t ^= (t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296;
  }

  return () {
    final u1 = u();
    final r = math.sqrt(-2 * math.log(u1 == 0 ? 1e-12 : u1));
    return r * math.cos(2 * math.pi * u());
  };
}

class DemoSignal {
  DemoSignal([int seed = 1]) : _gauss = gaussian(seed);

  final double Function() _gauss;
  int n = 0;
  double _phase = 0;

  /// 'open', 'closed' or null (automatic: a minute each).
  String? eyes;
  double jawUntil = -1;
  double alphaHz = 10;
  double alphaGain = 1;
  bool wanders = true;
  bool blinks = true;
  bool jawBursts = true;

  double get t => n / fs;
  bool closed(double t) => eyes != null ? eyes == 'closed' : autoEyesClosed(t);
  bool jaw(double t) => (jawBursts && autoJaw(t)) || t < jawUntil;

  List<double> _sample(double t) {
    final g = _gauss;
    _phase = (_phase + (2 * math.pi * alphaHz) / fs).remainder(2 * math.pi);
    final alpha = (closed(t) ? 25 : 6) * alphaGain * (wanders ? wander(t) : 1) * math.sin(_phase);
    final jawUv = jaw(t) ? 40 * g() : 0.0;
    final d = ((t.remainder(7)) - 0.15) / 0.08;
    final blink = blinks ? 80 * math.exp(-(d * d)) : 0.0;
    final o1 = alpha + blink + 4 * g();
    final o2 = 0.9 * alpha + blink + 4 * g();
    final t3 = jawUv + 0.3 * blink + 4 * g();
    final t4 = jawUv + 0.3 * blink + 4 * g();
    return [o1, o2, t3, t4];
  }

  /// The next k samples, [[O1, O2, T3, T4], ...] in µV.
  List<List<double>> next(int k) {
    final rows = <List<double>>[];
    for (var i = 0; i < k; i++) {
      rows.add(_sample(n / fs));
      n++;
    }
    return rows;
  }
}
