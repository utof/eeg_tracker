// Turns the core's sound settings into fades for the audio engine (pure, so it is tested without audio).
// The engine moves each setting itself, on the audio thread, in a straight line over the given time; Dart
// only hands it a new target when the setting changes (sound-engine.js `glide`, DECISIONS rows 39 and 45).
// A straight fade over 1.4 tau passes half-way at 0.7 tau, where the page's exponential glide (tau from
// MIX_TIMES) is half-way too (0.69 tau), so the phone answers as fast as the laptop page.
import '../feedback/mapping.dart';

/// One setting to move: [key] as in [Targets.settings], to [to], over [seconds].
typedef Fade = ({String key, double to, double seconds});

/// Linear fade time per exponential time constant (see the file comment).
const double fadePerTau = 1.4;

class Glider {
  Glider([String mode = 'training'])
    : times = mixTimes[mode] ?? (throw ArgumentError.value(mode, 'mode', 'training or relax')),
      _mirror = Mixer(Targets.layers(neutralCalm, 0).settings, mixTimes[mode]);

  final Map<String, (double, double)> times;

  /// Where each setting is now, as the engine's glide would have it (picks the rise or fall time).
  final Mixer _mirror;
  final Map<String, double> _sent = {};

  /// The settings now (mirror of the engine).
  Map<String, double> get now => {..._mirror.values};

  /// Called once per analysis step ([dt] seconds after the last call): the fades to start now. Settings that
  /// moved by under 0.1 % are skipped, so a steady target costs nothing.
  List<Fade> next(Targets target, {double dt = 0.1}) {
    final want = target.settings, fades = <Fade>[];
    final now = _mirror.values;
    for (final e in times.entries) {
      final v = want[e.key];
      if (v == null || !v.isFinite) continue;
      final last = _sent[e.key];
      if (last != null && (v - last).abs() < 1e-3 * (v.abs() > 1 ? v.abs() : 1)) continue;
      _sent[e.key] = v;
      final tau = v > (now[e.key] ?? v) ? e.value.$1 : e.value.$2;
      fades.add((key: e.key, to: v, seconds: tau * fadePerTau));
    }
    _mirror.step(want, dt);
    return fades;
  }
}
