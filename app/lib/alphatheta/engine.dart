// Alpha-theta rules per analysis step (ROADMAP row 22; DECISIONS rows 104-106), on top of the meditation's
// feedback core: the same filters, calibration (personal alpha peak, alpha = peak ± 2 Hz, theta = peak - 6 to
// peak - 2 Hz), muscle and blink gates. What differs:
//   - two lines, alpha and theta, each starting at the median of the silent eyes-closed minute and moved
//     0.15 SD between 3-minute blocks, aiming at alpha above its line 50-65 % of the time, theta 30-40 %
//   - the bed: a stream for alpha crossfading to ocean waves for theta, mix = S-curve of (theta z - alpha z)
//   - rewards: a high chime after 1 s of alpha above its line, a low gong after 1 s of theta above its line,
//     at most one per band every 2.5 s; theta wins ties (the chime waits)
//   - the core's drowsy gate is not used (theta rising is the point here); sleep is the drift-off detector's
//     job, in the controller (fade and wake gently)
//   - muscle, blink or a lost signal: no reward, the mix holds and the bed ducks a little
// Every step adds an 'at' line to the core's session log (the control stream a replay plays back) and each
// block end an 'at-block' line. Pure and sample-driven like the core, so a saved session replays exactly.
// All numbers are planning values (no published Peniston or Gruzelier thresholds exist).
import 'dart:math' as math;

import '../feedback/mapping.dart' show sCurve;
import '../feedback/session.dart';
import '../training/control.dart';

abstract final class AtRule {
  /// Seconds above a line before a reward, and the least time between two rewards of one band.
  static const double holdS = 1, gapS = 2.5;
  static const double blockS = 180, minCountedS = 30, stepSd = 0.15;

  /// Share of counted time above the line each band aims for (the line moves when outside).
  static const (double, double) alphaAim = (0.5, 0.65), thetaAim = (0.3, 0.4);

  /// The mix while nothing has been measured yet: halfway between stream and ocean.
  static const double startMix = 0.5;
}

/// One band's line, held still for 3-minute blocks.
class BandLine {
  BandLine(this.band, this.line, this.sd, this.aim);
  final String band;
  double line;
  final double sd;
  final (double, double) aim;
  int _steps = 0, _counted = 0, _above = 0;

  double z(double log) => (log - line) / sd;

  /// [above]: null when gated (not counted). Returns the block's log line at its end.
  Map<String, Object?>? update(bool? above, int n) {
    _steps++;
    if (above != null) {
      _counted++;
      if (above) _above++;
    }
    if (_steps < (AtRule.blockS / stepS).round()) return null;
    final share = _counted == 0 ? null : _above / _counted, from = line;
    var moved = 0;
    if (share != null && _counted * stepS >= AtRule.minCountedS) {
      if (share > aim.$2) {
        moved = 1;
      } else if (share < aim.$1) {
        moved = -1;
      }
    }
    line += moved * AtRule.stepSd * sd;
    _steps = 0;
    _counted = 0;
    _above = 0;
    return {'type': 'at-block', 'n': n, 'band': band, 'share': r3(share), 'from': from, 'to': line, 'moved': moved};
  }
}

/// The reward rule: a band earns its tone after [AtRule.holdS] above its line with no gate, at most once per
/// [AtRule.gapS]; when both are due at one step the gong sounds and the chime starts counting again.
class AtRewards {
  final int _hold = (AtRule.holdS / stepS).round(), _gap = (AtRule.gapS / stepS).round();
  int _alphaRun = 0, _thetaRun = 0;
  int _sinceChime = 1 << 30, _sinceGong = 1 << 30;

  /// [alphaAbove], [thetaAbove]: ignored when [gated]. Returns null, 'chime' or 'gong'.
  String? update({required bool gated, bool alphaAbove = false, bool thetaAbove = false}) {
    _sinceChime++;
    _sinceGong++;
    if (gated) {
      reset();
      return null;
    }
    _alphaRun = alphaAbove ? _alphaRun + 1 : 0;
    _thetaRun = thetaAbove ? _thetaRun + 1 : 0;
    if (_thetaRun >= _hold && _sinceGong >= _gap) {
      _sinceGong = 0;
      _thetaRun = 0;
      _alphaRun = 0; // theta wins the tie
      return 'gong';
    }
    if (_alphaRun >= _hold && _sinceChime >= _gap) {
      _sinceChime = 0;
      _alphaRun = 0;
      return 'chime';
    }
    return null;
  }

  /// A gate or a hole in the signal: both counts start again.
  void reset() {
    _alphaRun = 0;
    _thetaRun = 0;
  }
}

/// One step: the core's result, and the control (null outside the run phase).
typedef AtStep = ({StepResult r, Control? control});

class AlphaThetaEngine {
  AlphaThetaEngine() : core = Session() {
    core.log.header['protocol'] = SessionKind.alphaTheta.name;
  }

  final Session core;
  BandLine? alpha, theta;
  double _mix = AtRule.startMix;
  final AtRewards _rewards = AtRewards();

  /// Rows in µV ([O1, O2, T3, T4]). The core is fed up to each step boundary in turn, so every 'at' line
  /// follows its own step's lines whatever the chunking (live batches and replays give the same log).
  List<AtStep> push(List<List<double>> rows) {
    final out = <AtStep>[];
    var i = 0;
    while (i < rows.length) {
      final take = math.min(rows.length - i, stepSamples - core.n % stepSamples);
      for (final r in core.push(rows.sublist(i, i + take))) {
        out.add((r: r, control: r.phase == 'run' ? _step(r) : null));
      }
      i += take;
    }
    return out;
  }

  void gap() {
    core.gap();
    _rewards.reset();
  }

  void contact(Map<String, double?>? c) => core.contact(c);

  Control _step(StepResult r) {
    final b = core.baseline!;
    final a = alpha ??= BandLine('alpha', b.alpha, b.alphaSd, AtRule.alphaAim);
    final t = theta ??= BandLine('theta', b.theta, b.thetaSd, AtRule.thetaAim);
    final gated =
        r.quality != 'good' || r.veto == 'muscle' || r.veto == 'blink' || r.alphaLog == null || r.thetaLog == null;
    double? za, zt;
    if (!gated) {
      za = a.z(r.alphaLog!);
      zt = t.z(r.thetaLog!);
      _mix = sCurve(zt - za);
    }
    final blocks = [a.update(gated ? null : za! > 0, r.n), t.update(gated ? null : zt! > 0, r.n)];
    final reward = _rewards.update(gated: gated, alphaAbove: !gated && za! > 0, thetaAbove: !gated && zt! > 0);
    final rough = r.targets.rough;
    core.log.line({
      'type': 'at',
      'n': r.n,
      'mix': r3(_mix),
      'rough': r3(rough),
      'za': r3(za),
      'zt': r3(zt),
      if (gated) 'g': 1,
      'r': ?reward,
    });
    for (final bl in blocks) {
      if (bl != null) core.log.line(bl);
    }
    return (level: _mix, rough: rough, reward: reward, gated: gated);
  }
}

/// Feeds a saved alpha-theta session through a fresh engine; its log lines equal the saved ones.
AlphaThetaEngine replayAlphaTheta(Map<String, Object?> saved, [int chunk = 37]) {
  final e = AlphaThetaEngine();
  feedSaved(saved, push: e.push, gap: e.gap, contact: e.contact, chunk: chunk);
  return e;
}

/// What an alpha-theta session adds to the report: seconds with alpha and theta above their lines and with
/// theta above alpha (crossover) while awake and clean, seconds probably asleep, and the rewards heard.
class AtTally {
  int _alpha = 0, _theta = 0, _cross = 0, _asleep = 0, _counted = 0;
  int chimes = 0, gongs = 0;

  /// [control]: what was played (live or replayed); [asleep]: the drift-off detector says probably asleep.
  void add(StepResult r, Control played, {required bool asleep, required BandLine? alpha, required BandLine? theta}) {
    if (played.reward == 'chime') chimes++;
    if (played.reward == 'gong') gongs++;
    if (asleep) {
      _asleep++;
      return;
    }
    final a = r.alphaLog, t = r.thetaLog;
    if (r.quality != 'good' || r.veto == 'muscle' || r.veto == 'blink' || a == null || t == null) return;
    _counted++;
    if (alpha != null && alpha.z(a) > 0) _alpha++;
    if (theta != null && theta.z(t) > 0) _theta++;
    if (t > a) _cross++;
  }

  double get alphaS => _alpha * stepS;
  double get thetaS => _theta * stepS;
  double get crossoverS => _cross * stepS;
  double get asleepS => _asleep * stepS;
  double get countedS => _counted * stepS;

  Map<String, Object?> toJson() => {
    'alphaS': _r1(alphaS),
    'thetaS': _r1(thetaS),
    'crossoverS': _r1(crossoverS),
    'asleepS': _r1(asleepS),
    'countedS': _r1(countedS),
    'chimes': chimes,
    'gongs': gongs,
  };
}

double _r1(double v) => (v * 10).round() / 10;
