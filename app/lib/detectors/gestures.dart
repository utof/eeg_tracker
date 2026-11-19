// Hands-free gestures on top of the shared detectors (ROADMAP "Hands-free controls", DECISIONS 240-249). A
// line-by-line port of analysis/hands_free.py with the same constants; gestures_cross_check_test.dart runs
// recorded excerpts with gestures laid over them through both and expects the same gestures and clusters.
//
// - double clench: two short jaw clenches (each 0.2-1 s, 0.3-1.5 s apart), both temple electrodes over the clench
//   level at each clench's strongest 0.1 s, and no other jaw muscle (both sides up) within 2 s before the first and
//   after the second;
// - glance: look left, then right (while left is not known: look away and back): two opposite steps of T3-T4 of at
//   least the glance size, each within 1.5 s of the one before (a third, back to the middle, may follow), and no
//   other eye movement within 2 s before and after.
// A Bluetooth hole, movement, or a muscle rest level not yet known (the first 30 s) anywhere from 2 s before to 2 s
// after spoils it. Very few false triggers matter more than catching every gesture. The levels are planning values
// until the owner's calibration tunes them (calibrate below; handsfree/calibration_controller.dart runs it).
//
// Fed one whole second at a time as the detectors finish it ([GestureTap] builds the seconds from
// [Detectors.tap]). Pure: no clock. Whether the person is asleep is the caller's business (handsfree/live.dart).
import 'dart:math' as math;
import 'dart:typed_data';

import '../feedback/features.dart' show fs;
import 'detectors.dart';

const int tickSamples = 25;
const int ticksPerSecond = 10;

/// Planning values (DECISIONS 241, 243).
abstract final class GestureRule {
  /// A jaw tick: one side over 4x its own rest level and both over 2x (the detectors' jaw rule, at 0.1 s);
  /// one-sided muscle (a pillow, a hand, an electrode rubbing) does not count.
  static const double busyX = MuscleRule.x, bothX = MuscleRule.bothX;

  /// Each clench: both sides over this many times their rest at its strongest tick; the calibration's limits.
  static const double clenchX = 10, clenchXMin = 10, clenchXMax = 60;

  /// A one-tick dip inside a clench does not split it; each clench 2-10 ticks; 3-15 ticks between the two;
  /// nothing else 20 ticks before and after.
  static const int mergeTicks = 1, burstMin = 2, burstMax = 10, pauseMin = 3, pauseMax = 15, quietTicks = 20;

  /// Each of the first two steps of T3-T4 at least this (µV); the calibration's limits.
  static const double glanceUv = 80, glanceUvMin = 70, glanceUvMax = 250;

  /// Samples: each step within 1.5 s of the one before; 2 s of no other eye movement around; an eye movement at
  /// sample i is known once sample i + 75 is in.
  static const int glanceStep = 375, glanceQuiet = 500, eyeFoundAfter = 75;

  /// Spoiled ticks are remembered this long (10 s).
  static const int spoilKeepTicks = 100;

  /// Calibration: half the weakest clench, 0.6 of the smallest step; usable once 2 of 3 tries are recognised.
  static const double calShareClench = 0.5, calShareGlance = 0.6;
  static const int calNeed = 2;
}

enum GestureKind { clench, glance }

class GestureSettings {
  const GestureSettings({
    this.clenchX = GestureRule.clenchX,
    this.glanceUv = GestureRule.glanceUv,
    this.leftSign = 0,
    this.clenchOn = true,
    this.glanceOn = true,
  });

  final double clenchX;
  final double glanceUv;

  /// +1 or -1: the sign of T3-T4's step when the eyes go left; 0: not known (look away and back).
  final int leftSign;
  final bool clenchOn;
  final bool glanceOn;

  Map<String, Object?> toJson() => {
    'clenchX': clenchX,
    'glanceUv': glanceUv,
    'leftSign': leftSign,
    'clenchOn': clenchOn,
    'glanceOn': glanceOn,
  };

  /// Throws [FormatException] for anything that is not a settings object within the calibration's limits.
  static GestureSettings fromJson(Object? j) {
    if (j is! Map) throw const FormatException('gesture settings: not an object');
    final cx = j['clenchX'], gu = j['glanceUv'], left = j['leftSign'], co = j['clenchOn'], go = j['glanceOn'];
    if (cx is! num || gu is! num || left is! int || co is! bool || go is! bool) {
      throw const FormatException('gesture settings: missing or wrong fields');
    }
    if (cx < GestureRule.clenchXMin || cx > GestureRule.clenchXMax) throw const FormatException('clench level out of range');
    if (gu < GestureRule.glanceUvMin || gu > GestureRule.glanceUvMax) throw const FormatException('glance size out of range');
    if (left < -1 || left > 1) throw const FormatException('left sign must be -1, 0 or 1');
    return GestureSettings(clenchX: cx.toDouble(), glanceUv: gu.toDouble(), leftSign: left, clenchOn: co, glanceOn: go);
  }
}

/// One whole second as the recogniser takes it.
class GestureSecond {
  GestureSecond(this.k, this.p3, this.p4, this.tickGap, this.rest3, this.rest4, this.movement, this.moves);
  final int k;

  /// Ten ticks of mean 55-120 Hz power at T3 and T4, µV².
  final Float64List p3, p4;

  /// A missing sample in the tick.
  final List<bool> tickGap;

  /// The detectors' rest levels for this second (NaN while unknown).
  final double rest3, rest4;
  final bool movement;

  /// Eye movements first known during this second.
  final List<EyeMove> moves;
}

class GestureBurst {
  const GestureBurst(this.start, this.end, this.peak);

  /// First and last tick (inclusive).
  final int start, end;

  /// The strongest tick's weaker side, times its rest.
  final double peak;
}

class Gesture {
  const Gesture(this.kind, this.start, this.end, this.at, this.level);
  final GestureKind kind;

  /// First and last tick (clench) or sample (glance).
  final int start, end;

  /// The second whose end decided it.
  final int at;

  /// Clench: the weaker clench's peak (x rest); glance: the smaller of the first two steps (µV).
  final double level;
}

/// Muscle bursts under 2 s apart, or eye movements under 2 s apart: what a gesture is looked for in.
class GestureCluster {
  GestureCluster(this.kind, this.at, {this.bursts = const [], this.moves = const []});
  final GestureKind kind;
  final List<GestureBurst> bursts;
  final List<EyeMove> moves;

  /// The second it was decided in.
  final int at;

  /// Nothing spoiled from 2 s before to 2 s after.
  bool clean = false;
  Gesture? gesture;
}

double _level(double p, double rest) => rest.isNaN || rest <= 0 ? double.nan : p / rest;

/// The recogniser, fed one whole second at a time.
class Gestures {
  Gestures({this.settings = const GestureSettings(), this.keepClusters = true});

  GestureSettings settings;

  /// Keep every decided cluster in [clusters] (calibration, tests); the night recorder keeps none.
  final bool keepClusters;
  final List<Gesture> gestures = [];
  final List<GestureCluster> clusters = [];

  final List<int> _spoiled = [];
  GestureBurst? _open;
  List<GestureBurst> _bursts = [];
  int _lastBusy = -1000000000;
  List<EyeMove> _moves = [];
  int _tick = 0;

  List<Gesture> second(GestureSecond s) {
    if (s.p3.length != ticksPerSecond || s.p4.length != ticksPerSecond || s.tickGap.length != ticksPerSecond) {
      throw ArgumentError('a second has ten ticks');
    }
    final found = <Gesture>[];
    for (var j = 0; j < ticksPerSecond; j++) {
      final t = s.k * ticksPerSecond + j;
      _tick = t + 1;
      final x3 = _level(s.p3[j], s.rest3), x4 = _level(s.p4[j], s.rest4);
      final unknown = x3.isNaN || x4.isNaN;
      if (s.tickGap[j] || s.movement || unknown) _spoiled.add(t);
      final busy = !unknown && math.max(x3, x4) >= GestureRule.busyX && math.min(x3, x4) >= GestureRule.bothX;
      final both = unknown ? 0.0 : math.min(x3, x4);
      final g = _clenchTick(t, busy, both, s.k);
      if (g != null) found.add(g);
    }
    while (_spoiled.isNotEmpty && _spoiled.first < _tick - GestureRule.spoilKeepTicks) {
      _spoiled.removeAt(0);
    }
    final cutoff = (s.k + 1) * fs - 1 - GestureRule.eyeFoundAfter; // every eye movement up to here is known now
    for (final m in s.moves) {
      final g = _glanceMove(m, s.k);
      if (g != null) found.add(g);
    }
    if (_moves.isNotEmpty && cutoff >= _moves.last.i + GestureRule.glanceQuiet) {
      final g = _closeGlance(s.k);
      if (g != null) found.add(g);
    }
    gestures.addAll(found);
    return found;
  }

  bool _spoiledIn(int lo, int hi) => _spoiled.any((t) => lo <= t && t <= hi);

  void _log(GestureCluster c) {
    if (keepClusters) clusters.add(c);
  }

  // ---- double clench ----

  Gesture? _clenchTick(int t, bool busy, double both, int k) {
    final o = _open;
    if (busy) {
      if (o != null && t - o.end <= GestureRule.mergeTicks + 1) {
        _open = GestureBurst(o.start, t, math.max(o.peak, both));
      } else {
        if (o != null) _bursts.add(o);
        _open = GestureBurst(t, t, both);
      }
      _lastBusy = t;
      return null;
    }
    if (o != null && t - o.end > GestureRule.mergeTicks) {
      _bursts.add(o);
      _open = null;
    }
    if (_bursts.isNotEmpty && t - _lastBusy >= GestureRule.quietTicks) return _closeClench(t, k);
    return null;
  }

  Gesture? _closeClench(int t, int k) {
    final bursts = _bursts;
    _bursts = [];
    final c = GestureCluster(GestureKind.clench, k, bursts: bursts)
      ..clean = !_spoiledIn(bursts.first.start - GestureRule.quietTicks, t);
    if (settings.clenchOn && clenchWhy(c, settings) == 'ok') {
      c.gesture = Gesture(GestureKind.clench, bursts.first.start, bursts.last.end, k, bursts.map((b) => b.peak).reduce(math.min));
    }
    _log(c);
    return c.gesture;
  }

  // ---- glance ----

  Gesture? _glanceMove(EyeMove m, int k) {
    Gesture? g;
    if (_moves.isNotEmpty && m.i - _moves.last.i > GestureRule.glanceQuiet) g = _closeGlance(k);
    _moves.add(m);
    return g;
  }

  Gesture? _closeGlance(int k) {
    final moves = _moves;
    _moves = [];
    final c = GestureCluster(GestureKind.glance, k, moves: moves)
      ..clean = !_spoiledIn(
        (moves.first.i - GestureRule.glanceQuiet) ~/ tickSamples,
        (moves.last.i + GestureRule.glanceQuiet) ~/ tickSamples,
      );
    if (settings.glanceOn && glanceWhy(c, settings) == 'ok') {
      c.gesture = Gesture(GestureKind.glance, moves.first.i, moves.last.i, k, math.min(moves[0].step.abs(), moves[1].step.abs()));
    }
    _log(c);
    return c.gesture;
  }
}

/// Why a muscle cluster is or is not a double clench: 'ok', or the first rule it breaks.
String clenchWhy(GestureCluster c, GestureSettings s) {
  final b = c.bursts;
  if (!c.clean) return 'noisy'; // movement, a lost signal or an unknown rest level within 2 s
  if (b.length != 2) return b.length == 1 ? 'one' : 'many';
  if (b.any((x) => x.end - x.start + 1 > GestureRule.burstMax)) return 'long';
  if (b.any((x) => x.end - x.start + 1 < GestureRule.burstMin)) return 'short';
  final pause = b[1].start - b[0].end - 1;
  if (pause < GestureRule.pauseMin) return 'close';
  if (pause > GestureRule.pauseMax) return 'apart';
  if (math.min(b[0].peak, b[1].peak) < s.clenchX) return 'weak';
  return 'ok';
}

/// Why an eye-movement cluster is or is not a glance: 'ok', or the first rule it breaks.
String glanceWhy(GestureCluster c, GestureSettings s) {
  final m = c.moves;
  if (!c.clean) return 'noisy';
  if (m.length < 2 || m.length > 3) return m.length == 1 ? 'one' : 'many';
  for (var n = 0; n < m.length - 1; n++) {
    if (m[n + 1].i - m[n].i > GestureRule.glanceStep) return 'slow';
  }
  for (var n = 0; n < m.length - 1; n++) {
    if (m[n + 1].step * m[n].step >= 0) return 'same';
  }
  if (s.leftSign != 0 && m[0].step * s.leftSign <= 0) return 'way';
  if (math.min(m[0].step.abs(), m[1].step.abs()) < s.glanceUv) return 'small';
  return 'ok';
}

/// Builds [GestureSecond]s from what the detectors show their [Detectors.tap]: each sample's muscle values, the eye
/// movements as they are found, and each second as it ends.
class GestureTap implements DetectorTap {
  GestureTap(this.onSecond);
  final void Function(GestureSecond s) onSecond;

  Float64List _p3 = Float64List(ticksPerSecond), _p4 = Float64List(ticksPerSecond);
  List<bool> _gap = List.filled(ticksPerSecond, false);
  List<EyeMove> _moves = [];
  double _s3 = 0, _s4 = 0;
  bool _g = false;
  int _inTick = 0, _tickNo = 0;

  @override
  void muscle(double t3, double t4, bool missing) {
    if (_inTick == 0) {
      _s3 = 0;
      _s4 = 0;
      _g = false;
    }
    _s3 += t3 * t3;
    _s4 += t4 * t4;
    if (missing) _g = true;
    if (++_inTick == tickSamples) {
      if (_tickNo < ticksPerSecond) {
        _p3[_tickNo] = _s3 / tickSamples;
        _p4[_tickNo] = _s4 / tickSamples;
        _gap[_tickNo] = _g;
      }
      _tickNo++;
      _inTick = 0;
    }
  }

  @override
  void eyeMove(EyeMove e) => _moves.add(e);

  @override
  void secondEnd(Second s) {
    if (_tickNo != ticksPerSecond || _inTick != 0) {
      // attached in the middle of a second: its ticks are not whole, so it counts as spoiled
      _gap = List.filled(ticksPerSecond, true);
      _inTick = 0;
    }
    final out = GestureSecond(s.k, _p3, _p4, _gap, s.muscleRest[0], s.muscleRest[1], s.movement, _moves);
    _p3 = Float64List(ticksPerSecond);
    _p4 = Float64List(ticksPerSecond);
    _gap = List.filled(ticksPerSecond, false);
    _moves = [];
    _tickNo = 0;
    onSecond(out);
  }
}

// ---- calibration: "clench twice now" and "look left, then right", 3 times each ----

class GestureTry {
  const GestureTry(this.kind, this.cue, this.until);
  final GestureKind kind;

  /// The second of the cue, and the last second the answer may start in (inclusive).
  final int cue, until;
}

class TryResult {
  const TryResult(this.kind, this.cue, this.level, this.sign, this.why);
  final GestureKind kind;
  final int cue;

  /// Clench: the weaker of the two strongest bursts (x rest); glance: the smaller first step (µV); null: none.
  final double? level;

  /// Glance: the sign of the first step (0: none).
  final int sign;

  /// 'ok' (recognised with the tuned settings), 'none' (nothing seen) or the rule it broke.
  final String why;

  Map<String, Object?> toJson() => {'kind': kind.name, 'cue': cue, 'level': level, 'sign': sign, 'why': why};
}

class GestureCalibration {
  const GestureCalibration(this.settings, this.tries, this.clenchSeen, this.glanceSeen, this.leftKnown, this.others);
  final GestureSettings settings;
  final List<TryResult> tries;
  final int clenchSeen, glanceSeen;
  final bool leftKnown;

  /// Gestures recognised outside the cued windows (should be 0).
  final int others;
}

double _clamp(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

/// The seconds a cluster's bursts or eye movements start in.
List<int> _starts(GestureCluster c) => c.kind == GestureKind.clench
    ? [for (final b in c.bursts) b.start ~/ ticksPerSecond]
    : [for (final m in c.moves) m.i ~/ fs];

/// The first cluster of the try's kind with a burst or eye movement starting inside its window.
GestureCluster? _tryCluster(Gestures g, GestureTry t) {
  for (final c in g.clusters) {
    if (c.kind == t.kind && _starts(c).any((s) => t.cue <= s && s <= t.until)) return c;
  }
  return null;
}

/// Clench: the second-strongest burst's peak; glance: the first step and the next one the other way, the smaller of
/// the two, and the first one's sign.
({double? level, int sign}) _tryLevel(GestureCluster? c) {
  if (c == null) return (level: null, sign: 0);
  if (c.kind == GestureKind.clench) {
    final peaks = [for (final b in c.bursts) b.peak]..sort((a, b) => b.compareTo(a));
    return (level: peaks.length >= 2 ? peaks[1] : null, sign: 0);
  }
  final first = c.moves.first;
  EyeMove? other;
  for (final m in c.moves.skip(1)) {
    if (m.step * first.step < 0) {
      other = m;
      break;
    }
  }
  return (level: other == null ? null : math.min(first.step.abs(), other.step.abs()), sign: first.step > 0 ? 1 : -1);
}

String _why(GestureCluster c, GestureSettings s) => c.kind == GestureKind.clench ? clenchWhy(c, s) : glanceWhy(c, s);

/// Whether a try so far has a gesture's shape at any level (timing, quiet around, two opposite steps): the calibration
/// page's live mark before the levels are set. Not in the Python reference: it decides nothing that is saved.
bool tryShaped(Gestures g, GestureTry t) {
  final c = _tryCluster(g, t);
  return c != null && _why(c, const GestureSettings(clenchX: 0, glanceUv: 0)) == 'ok';
}

/// Tunes the clench level, the glance size and which way is left from a calibration run, then says for every cued
/// try whether the tuned settings recognise it (and if not, which rule it broke). Only tries that have a gesture's
/// shape at any level (timing, quiet around, two opposite steps) set the levels. Clusters do not depend on the
/// settings, so one pass finds them all.
GestureCalibration calibrate(List<GestureSecond> seconds, List<GestureTry> tries) {
  final g = Gestures(settings: const GestureSettings(clenchOn: false, glanceOn: false));
  for (final s in seconds) {
    g.second(s);
  }
  const loose = GestureSettings(clenchX: 0, glanceUv: 0);
  final found = [for (final t in tries) (t: t, c: _tryCluster(g, t))];
  final levels = [for (final f in found) _tryLevel(f.c)];
  final clench = <double>[], glance = <double>[], signs = <int>[];
  for (var n = 0; n < found.length; n++) {
    final c = found[n].c, l = levels[n], kind = found[n].t.kind;
    if (c == null || _why(c, loose) != 'ok') continue;
    if (kind == GestureKind.clench && l.level != null) clench.add(l.level!);
    if (kind == GestureKind.glance && l.level != null) glance.add(l.level!);
    if (kind == GestureKind.glance) signs.add(l.sign);
  }
  final tuned = GestureSettings(
    clenchX: clench.isEmpty
        ? GestureRule.clenchX
        : _clamp(GestureRule.calShareClench * clench.reduce(math.min), GestureRule.clenchXMin, GestureRule.clenchXMax),
    glanceUv: glance.isEmpty
        ? GestureRule.glanceUv
        : _clamp(GestureRule.calShareGlance * glance.reduce(math.min), GestureRule.glanceUvMin, GestureRule.glanceUvMax),
    leftSign: signs.length >= GestureRule.calNeed && signs.every((s) => s == signs.first) ? signs.first : 0,
  );
  final results = <TryResult>[];
  for (var n = 0; n < found.length; n++) {
    final t = found[n].t, c = found[n].c;
    results.add(TryResult(t.kind, t.cue, levels[n].level, levels[n].sign, c == null ? 'none' : _why(c, tuned)));
  }
  final cs = results.where((r) => r.kind == GestureKind.clench && r.why == 'ok').length;
  final gs = results.where((r) => r.kind == GestureKind.glance && r.why == 'ok').length;
  final ours = {for (final f in found) ?f.c};
  final others = g.clusters.where((c) => !ours.contains(c) && _why(c, tuned) == 'ok').length;
  final settings = GestureSettings(
    clenchX: tuned.clenchX,
    glanceUv: tuned.glanceUv,
    leftSign: tuned.leftSign,
    clenchOn: cs >= GestureRule.calNeed,
    glanceOn: gs >= GestureRule.calNeed,
  );
  return GestureCalibration(settings, results, cs, gs, tuned.leftSign != 0, others);
}
