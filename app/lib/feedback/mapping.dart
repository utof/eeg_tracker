// Brain state -> sound settings, and the glide times per mode. Pure: same input, same output. A port of
// scripts/web/sound-mapping.js and sound-mixer.js, same constants.
//
// The bed follows an S-curve centred on the target line: flat beyond 2 SD either side, steepest at the line.
// Any gate moves it to neutral; drifting toward sleep goes a little brighter than neutral, as a nudge to stay
// awake.
import 'dart:math' as math;

/// Where the sound rests when it cannot follow the brain.
const double neutralCalm = 0.35;

/// Drowsy: brighter rain than neutral.
const double nudgeCalm = 0.2;

/// Any jaw score above this is a muscle gate.
const double jawBlock = 0.05;

double _clamp01(double v) => math.min(1, math.max(0, v));
double _lerp(double a, double b, double t) => a + (b - a) * t;

/// 0 at z <= -2, 1 at z >= +2, 0.5 on the line, smooth (zero slope) at both ends.
double sCurve(double z) {
  final u = _clamp01((z + 2) / 4);
  return u * u * (3 - 2 * u);
}

/// Sound settings for the engine. Gains are 0..1 before the engine's own level trims; tones in Hz.
class Targets {
  const Targets({
    required this.calm,
    required this.rain,
    required this.rainTone,
    required this.drone,
    required this.warmth,
    required this.droneTone,
    required this.rough,
    this.bellsAllowed = false,
    this.neutral = true,
  });

  /// Layer settings from two numbers (so a logged control stream can drive the sound later).
  factory Targets.layers(double calm, double rough, {bool bellsAllowed = false, bool neutral = true}) => Targets(
    calm: calm,
    rain: _lerp(0.9, 0.12, calm), // rain/wind quietens as alpha rises
    rainTone: _lerp(3200, 900, calm), // and gets darker
    drone: _lerp(0.55, 0.85, calm), // the drone comes forward
    warmth: calm, // fuller: low octave and third fade in
    droneTone: _lerp(420, 1300, calm), // and opens up
    rough: rough, // jaw tension roughens the sound
    bellsAllowed: bellsAllowed,
    neutral: neutral,
  );

  final double calm;
  final double rain;
  final double rainTone;
  final double drone;
  final double warmth;
  final double droneTone;
  final double rough;
  final bool bellsAllowed;
  final bool neutral;

  /// The glided settings by name (the keys of [mixTimes]).
  Map<String, double> get settings => {
    'calm': calm,
    'rain': rain,
    'rainTone': rainTone,
    'drone': drone,
    'warmth': warmth,
    'droneTone': droneTone,
    'rough': rough,
  };
}

/// [z]: alpha against the line in robust SDs (null = unknown); [jaw]: 0 relaxed .. 1 clenched (null =
/// unknown); [quality]: 'good', or why the sound cannot follow ('learning', 'settling', 'poor', 'none');
/// [veto]: null, 'muscle', 'blink' or 'drowsy'.
Targets mapState({required double? z, required double? jaw, required String quality, required String? veto}) {
  final usable = quality == 'good' && z != null && z.isFinite;
  var calm = neutralCalm;
  if (usable && veto == null) {
    calm = sCurve(z);
  } else if (usable && veto == 'drowsy') {
    calm = nudgeCalm;
  }
  final jawKnown = jaw != null && jaw.isFinite;
  final rough = quality == 'none' || !jawKnown ? 0.0 : _clamp01(jaw);
  return Targets.layers(calm, rough, bellsAllowed: usable && veto == null && jawKnown, neutral: !usable || veto != null);
}

/// [rise, fall] time constants (s) per setting. training = fast bed (0.25-0.3 s, warmth 1.5 s), so the sound
/// answers within about 0.3 s; relax = the slower, smoother bed (about 1 s). DECISIONS row 45.
const Map<String, Map<String, (double, double)>> mixTimes = {
  'training': {
    'calm': (0.25, 0.25),
    'rain': (0.25, 0.25),
    'rainTone': (0.3, 0.3),
    'drone': (0.3, 0.3),
    'warmth': (1.5, 1.5),
    'droneTone': (0.3, 0.3),
    'rough': (0.08, 1.2),
  },
  'relax': {
    'calm': (0.8, 0.8),
    'rain': (0.9, 1.2),
    'rainTone': (0.9, 1.2),
    'drone': (1.0, 1.0),
    'warmth': (1.0, 1.0),
    'droneTone': (1.0, 1.0),
    'rough': (0.08, 1.2),
  },
};

/// Each setting follows its target with its own rise and fall time constant, so a clench roughens fast and
/// fades slowly. The engine runs the glide on the audio thread; this copy mirrors it (for the screen, tests).
class Mixer {
  Mixer(Map<String, double> initial, [Map<String, (double, double)>? times])
    : times = times ?? mixTimes['training']!,
      values = {for (final k in (times ?? mixTimes['training']!).keys) k: initial[k] ?? 0};

  final Map<String, (double, double)> times;
  final Map<String, double> values;

  Map<String, double> step(Map<String, double> target, double dt) {
    for (final e in times.entries) {
      final t = target[e.key];
      if (t == null || !t.isFinite) continue;
      final v = values[e.key]!;
      final tau = t > v ? e.value.$1 : e.value.$2;
      values[e.key] = v + (t - v) * (1 - math.exp(-dt / tau));
    }
    return {...values};
  }
}
