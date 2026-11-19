// What the electrodes see: blinks, sideways eye movements, slow eye rolls, jaw and muscle bursts, movement and a
// good / degraded / missing flag per 30 s epoch. A line-by-line port of analysis/eeg_detectors.py (the Python
// reference, validated on the owner's recordings) with the same constants; detectors_cross_check_test.dart
// runs excerpts through both and expects the same events (docs/detectors.md).
//
// Pure and sample-driven: no clock. Feed µV rows O1 O2 T3 T4 at 250 Hz, one at a time. Decisions come per
// sample (blinks and eye movements, 0.3 s after the fact), per whole second (quality, muscle, movement, alpha)
// and per 30 s epoch counted from the first sample. Channels are electrode minus the forehead reference
// (DECISIONS 78): a blink dips all four, T3-T4 cancels it and carries sideways eye movements.
import 'dart:math' as math;
import 'dart:typed_data';

import '../feedback/features.dart' show fs, percentile, median;
import 'filters.dart';

const int epochS = 30;
const List<int> backChannels = [0, 1];
const List<int> sideChannels = [2, 3];

/// Signal quality per second and per epoch.
abstract final class Quality {
  static const double flatUv = 1.4, railUv = 390000, qualityHpHz = 2, extremeUv = 500, cleanBackUv = 250;
  static const double moveUv = 200;
  static const int moveChannels = 3, maxGapS = 5, badChannelS = 3, degradedMoveS = 3, degradedMuscleS = 15;
}

/// Blinks: the lowest point of the 4-channel mean within ±0.3 s, deep on all four, near zero in T3-T4.
abstract final class BlinkRule {
  static const double hpHz = 0.5, lpHz = 15, minUv = 50, eachUv = 15, t34Share = 0.5, maxUv = 400;
  static const int half = 75, base0 = 150, base1 = 75, widthLo = 10, widthHi = 50; // samples
}

/// Sideways eye movements: the largest 0.1 s change of T3-T4 within ±0.3 s, T3 and T4 moving apart.
abstract final class EyeRule {
  static const double minUv = 40, commonShare = 0.5, balance = 0.5, maxUv = 400;
  static const int step = 25, half = 75; // samples
}

/// Slow eye rolls: 0.2-0.7 Hz power of T3-T4.
abstract final class SemRule {
  static const List<double> band = [0.2, 0.7];
  static const int windowS = 10;
  static const double x = 4;
}

/// Jaw and muscle: 55-120 Hz at T3/T4 with notches at 50 and 100 Hz (DECISIONS 65), against a personal
/// baseline: the 20th percentile of the channel's last 2 minutes.
abstract final class MuscleRule {
  static const List<double> band = [55, 120], notches = [50, 100];
  static const double notchQ = 8, restPct = 0.2, x = 4, bothX = 2;
  static const int restS = 120, restMinS = 30, joinS = 2;
}

const List<double> detAlphaBand = [8, 12];
const List<double> detThetaBand = [4, 7];

/// Every filter chain, by name (eeg_detectors.chains()).
Map<String, List<List<double>>> detectorChains() => {
  'blink': [highPass(BlinkRule.hpHz), lowPass(BlinkRule.lpHz)],
  'quality': [highPass(Quality.qualityHpHz)],
  'alpha': bandPair(detAlphaBand[0], detAlphaBand[1]),
  'theta': bandPair(detThetaBand[0], detThetaBand[1]),
  'muscle': [for (final f in MuscleRule.notches) notch(f, MuscleRule.notchQ), ...bandPair(MuscleRule.band[0], MuscleRule.band[1])],
  'sem': bandPair(SemRule.band[0], SemRule.band[1]),
};

class Blink {
  const Blink(this.i, this.depth, this.t34);

  /// Sample of the lowest point.
  final int i;

  /// µV, the 4-channel mean.
  final double depth;

  /// µV, T3 depth minus T4 depth (near 0 for a blink).
  final double t34;
}

class EyeMove {
  const EyeMove(this.i, this.step);
  final int i;

  /// µV change of T3-T4 over 0.1 s; its sign is the direction (which is left: the setup test's glances).
  final double step;
}

enum BurstKind { jaw, oneSided, movement }

class Burst {
  const Burst(this.start, this.end, this.kind, this.peakX);

  /// First and last second (inclusive).
  final int start;
  final int end;
  final BurstKind kind;

  /// Highest T3 or T4 power against its baseline.
  final double peakX;
}

enum EpochQuality { good, degraded, missing }

class QualityEpoch {
  const QualityEpoch(this.index, this.quality, this.gapS, this.badS, this.usable, this.movementS, this.muscleS);
  final int index;
  final EpochQuality quality;
  final int gapS;

  /// Per channel: flat, railed, extreme or gap seconds.
  final List<int> badS;
  final List<bool> usable;
  final int movementS;
  final int muscleS;
}

/// One whole second of features (index k: samples k*250 .. k*250+249).
class Second {
  Second(this.k);
  final int k;
  bool gap = false;
  final List<bool> flat = List.filled(4, false);
  final List<bool> railed = List.filled(4, false);

  /// Range of the 2 Hz high-passed signal, µV.
  final List<double> qrange = List.filled(4, 0);

  /// O1, O2 mean power 8-12 Hz and 4-7 Hz, µV².
  final List<double> alpha = List.filled(2, 0);
  final List<double> theta = List.filled(2, 0);

  /// Mean power 55-120 Hz per channel, µV².
  final List<double> muscle = List.filled(4, 0);

  /// T3-T4 mean power 0.2-0.7 Hz, µV².
  double sem = 0;

  /// T3 and T4 muscle power against their baselines (NaN while a baseline is unknown).
  final List<double> muscleX = [double.nan, double.nan];

  /// The T3 and T4 baselines themselves, µV² (NaN while unknown; eeg_detectors.muscle_rest).
  final List<double> muscleRest = [double.nan, double.nan];
  bool muscleOn = false;

  /// Blinks whose lowest point fell in this second (set when the second is handed out, 1 s later).
  int blinks = 0;

  bool get movement {
    var n = 0;
    for (final r in qrange) {
      if (r >= Quality.moveUv) n++;
    }
    return n >= Quality.moveChannels && !gap;
  }

  bool extreme(int c) => qrange[c] > Quality.extremeUv;

  bool backClean(int b) =>
      !(flat[backChannels[b]] || railed[backChannels[b]] || qrange[backChannels[b]] >= Quality.cleanBackUv) && !gap;

  /// Alpha of the usable back channels (mean), and whether any was usable.
  ({double alpha, bool clean}) get backAlpha {
    final ok0 = backClean(0), ok1 = backClean(1);
    final cnt = (ok0 ? 1 : 0) + (ok1 ? 1 : 0);
    final total = (ok0 ? alpha[0] : 0.0) + (ok1 ? alpha[1] : 0.0);
    return (alpha: cnt > 0 ? total / cnt : 0.0, clean: cnt > 0);
  }
}

/// A history of doubles indexed by absolute sample number; the size is a power of two.
class _Ring {
  _Ring(int size) : _a = Float64List(size), _mask = size - 1 {
    assert(size & _mask == 0);
  }
  final Float64List _a;
  final int _mask;
  double operator [](int i) => _a[i & _mask];
  void operator []=(int i, double v) => _a[i & _mask] = v;
}

class _BurstSpan {
  _BurstSpan(this.a, this.b);
  final int a;
  int b;
  bool move = false;
  bool both = false;
  double peak = double.negativeInfinity;
}

/// Something that looks over the detectors' shoulder without changing them (the hands-free gestures,
/// gestures.dart): every sample's 55-120 Hz values at T3 and T4, each eye movement as it is found (0.3 s after the
/// fact), and each second as soon as it ends (before [Detectors.onSecond] hands it out a second later).
abstract interface class DetectorTap {
  void muscle(double t3, double t4, bool missing);
  void eyeMove(EyeMove e);
  void secondEnd(Second s);
}

/// The detectors, fed one sample at a time.
class Detectors {
  Detectors({this.onSecond}) {
    final ch = detectorChains();
    _blink = [for (var c = 0; c < 4; c++) Chain(ch['blink']!)];
    _quality = [for (var c = 0; c < 4; c++) Chain(ch['quality']!)];
    _alpha = [for (final _ in backChannels) Chain(ch['alpha']!)];
    _theta = [for (final _ in backChannels) Chain(ch['theta']!)];
    _muscle = [for (var c = 0; c < 4; c++) Chain(ch['muscle']!)];
    _sem = Chain(ch['sem']!);
  }

  /// Each whole second, handed out one second late (once its blinks are known).
  final void Function(Second s)? onSecond;

  /// Null: nobody looks (set by the hands-free gestures while they are on).
  DetectorTap? tap;

  final List<Blink> blinks = [];
  final List<EyeMove> eyeMoves = [];
  final List<Burst> bursts = [];

  /// Movement seconds joined into spans (first, last second).
  final List<(int, int)> movement = [];
  final List<QualityEpoch> epochs = [];

  /// Samples received.
  int n = 0;

  late final List<Chain> _blink, _quality, _alpha, _theta, _muscle;
  late final Chain _sem;
  static const int _ringSize = 512;
  final List<_Ring> _f = [for (var c = 0; c < 4; c++) _Ring(_ringSize)];
  final _Ring _m = _Ring(_ringSize), _d = _Ring(_ringSize), _s = _Ring(_ringSize);
  final List<bool> _miss = List.filled(_ringSize, false);
  final Float64List _fv = Float64List(4);
  List<double>? _last;

  // the second being filled
  Second _cur = Second(0);
  final Float64List _rawLo = Float64List(4), _rawHi = Float64List(4), _rawAbs = Float64List(4);
  final Float64List _qLo = Float64List(4), _qHi = Float64List(4);
  final Float64List _sumA = Float64List(2), _sumT = Float64List(2), _sumM = Float64List(4);
  double _sumS = 0;
  int _inSecond = 0;

  Second? _pending;
  final Map<int, int> _blinkCount = {};
  final List<List<double>> _restHist = [<double>[], <double>[]];
  _BurstSpan? _span;
  bool _pendMove = false, _pendBoth = false;
  double _pendPeak = double.negativeInfinity;
  int _lastGap = -1;
  (int, int)? _moveSpan;
  final List<Second> _epoch = [];

  /// One row of µV (O1, O2, T3, T4). [missing]: a held value standing in for a lost sample.
  void push(List<double> row, {bool missing = false}) {
    if (row.length != 4 || !row[0].isFinite || !row[1].isFinite || !row[2].isFinite || !row[3].isFinite) {
      throw ArgumentError.value(row, 'row', 'four finite µV values');
    }
    _last = row;
    final t = n;
    final f = _fv;
    for (var c = 0; c < 4; c++) {
      f[c] = _blink[c].step(row[c]);
      _f[c][t] = f[c];
    }
    final m = (f[0] + f[1] + f[2] + f[3]) / 4, d = f[2] - f[3];
    _m[t] = m;
    _d[t] = d;
    _s[t] = t >= EyeRule.step ? d - _d[t - EyeRule.step] : 0;
    _miss[t & (_ringSize - 1)] = missing;
    _accumulate(row, missing);
    n++;
    _checkBlink(t - BlinkRule.half);
    _checkEye(t - EyeRule.half);
    if (_inSecond == fs) _endSecond();
  }

  /// A hole of [samples] lost samples (live stream): the last row is held and marked missing, as the BDF
  /// converter fills a gap, so the Python reference treats it the same way.
  void hold(int samples) {
    final last = _last;
    if (last == null) return;
    for (var i = 0; i < samples; i++) {
      push(last, missing: true);
    }
  }

  /// End of the input: hands out the last second and closes open bursts and movement spans.
  void finish() {
    final p = _pending;
    if (p != null) _settle(p);
    _pending = null;
    _closeBurst();
    _closeMove();
  }

  // ---- per sample ----

  void _accumulate(List<double> row, bool missing) {
    final first = _inSecond == 0;
    final s = _cur;
    if (missing) s.gap = true;
    var y3 = 0.0, y4 = 0.0;
    for (var c = 0; c < 4; c++) {
      final v = row[c], q = _quality[c].step(v);
      final y = _muscle[c].step(v);
      if (c == 2) y3 = y;
      if (c == 3) y4 = y;
      if (first) {
        _rawLo[c] = v;
        _rawHi[c] = v;
        _rawAbs[c] = v.abs();
        _qLo[c] = q;
        _qHi[c] = q;
        _sumM[c] = 0;
      } else {
        _rawLo[c] = math.min(_rawLo[c], v);
        _rawHi[c] = math.max(_rawHi[c], v);
        _rawAbs[c] = math.max(_rawAbs[c], v.abs());
        _qLo[c] = math.min(_qLo[c], q);
        _qHi[c] = math.max(_qHi[c], q);
      }
      _sumM[c] += y * y;
    }
    for (var b = 0; b < 2; b++) {
      final a = _alpha[b].step(row[backChannels[b]]), th = _theta[b].step(row[backChannels[b]]);
      if (first) {
        _sumA[b] = 0;
        _sumT[b] = 0;
      }
      _sumA[b] += a * a;
      _sumT[b] += th * th;
    }
    final se = _sem.step(row[2] - row[3]);
    if (first) _sumS = 0;
    _sumS += se * se;
    _inSecond++;
    tap?.muscle(y3, y4, missing);
  }

  bool _anyMissing(int from, int to) {
    for (var j = from; j <= to; j++) {
      if (_miss[j & (_ringSize - 1)]) return true;
    }
    return false;
  }

  double _range(int c, int from, int to) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (var j = from; j <= to; j++) {
      final v = _f[c][j];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    return hi - lo;
  }

  void _checkBlink(int i) {
    const h = BlinkRule.half;
    if (i < BlinkRule.base0) return;
    // the lowest point within ±0.3 s (strictly lower than everything before it); nearest samples first, so most
    // samples are turned down after one or two comparisons
    final mi = _m[i];
    for (var j = i + 1; j <= i + h; j++) {
      if (mi > _m[j]) return;
    }
    for (var j = i - 1; j >= i - h; j--) {
      if (!(mi < _m[j])) return;
    }
    if (_anyMissing(i - BlinkRule.base0, i + h)) return;
    final base = List<double>.filled(4, 0), depth = List<double>.filled(4, 0);
    for (var c = 0; c < 4; c++) {
      base[c] = median([for (var j = i - BlinkRule.base0; j < i - BlinkRule.base1; j++) _f[c][j]]);
      depth[c] = base[c] - _f[c][i];
    }
    final dm = (depth[0] + depth[1] + depth[2] + depth[3]) / 4;
    if (dm < BlinkRule.minUv || depth.reduce(math.min) < BlinkRule.eachUv) return;
    final t34 = depth[2] - depth[3];
    if (t34.abs() > BlinkRule.t34Share * dm) return;
    for (var c = 0; c < 4; c++) {
      if (_range(c, i - BlinkRule.base0, i + h) > BlinkRule.maxUv) return;
    }
    final baseM = (base[0] + base[1] + base[2] + base[3]) / 4, level = baseM - dm / 2;
    var width = 1;
    for (var j = i - 1; j >= i - h && _m[j] < level; j--) {
      width++;
    }
    for (var j = i + 1; j <= i + h && _m[j] < level; j++) {
      width++;
    }
    if (width < BlinkRule.widthLo || width > BlinkRule.widthHi) return;
    blinks.add(Blink(i, dm, t34));
    _blinkCount[i ~/ fs] = (_blinkCount[i ~/ fs] ?? 0) + 1;
  }

  void _checkEye(int i) {
    const h = EyeRule.half, k = EyeRule.step;
    if (i < h + k) return;
    final si = _s[i].abs();
    for (var j = i + 1; j <= i + h; j++) {
      if (si < _s[j].abs()) return;
    }
    for (var j = i - 1; j >= i - h; j--) {
      if (!(si > _s[j].abs())) return;
    }
    if (si < EyeRule.minUv || _anyMissing(i - h - k, i + h)) return;
    if ((_m[i] - _m[i - k]).abs() > EyeRule.commonShare * si) return;
    final d3 = _f[2][i] - _f[2][i - k], d4 = _f[3][i] - _f[3][i - k];
    if (d3 * d4 >= 0 || math.min(d3.abs(), d4.abs()) < EyeRule.balance * math.max(d3.abs(), d4.abs())) return;
    for (var c = 0; c < 4; c++) {
      if (_range(c, i - h - k, i + h) > EyeRule.maxUv) return;
    }
    final e = EyeMove(i, _s[i]);
    eyeMoves.add(e);
    tap?.eyeMove(e);
  }

  // ---- per second ----

  void _endSecond() {
    final s = _cur;
    for (var c = 0; c < 4; c++) {
      s.flat[c] = _rawHi[c] - _rawLo[c] < Quality.flatUv;
      s.railed[c] = _rawAbs[c] >= Quality.railUv;
      s.qrange[c] = _qHi[c] - _qLo[c];
      s.muscle[c] = _sumM[c] / fs;
    }
    for (var b = 0; b < 2; b++) {
      s.alpha[b] = _sumA[b] / fs;
      s.theta[b] = _sumT[b] / fs;
    }
    s.sem = _sumS / fs;
    _muscleSecond(s);
    _burstSecond(s);
    _moveSecond(s);
    _epochSecond(s);
    tap?.secondEnd(s);
    final p = _pending;
    if (p != null) _settle(p);
    _pending = s;
    _cur = Second(s.k + 1);
    _inSecond = 0;
  }

  void _settle(Second s) {
    s.blinks = _blinkCount.remove(s.k) ?? 0;
    onSecond?.call(s);
  }

  void _muscleSecond(Second s) {
    for (var j = 0; j < 2; j++) {
      final hist = _restHist[j];
      final rest = hist.length >= MuscleRule.restMinS ? percentile(hist, MuscleRule.restPct) : double.nan;
      s.muscleRest[j] = rest;
      s.muscleX[j] = rest.isNaN || rest <= 0 ? double.nan : s.muscle[sideChannels[j]] / rest;
      if (!s.gap) {
        hist.add(s.muscle[sideChannels[j]]);
        if (hist.length > MuscleRule.restS) hist.removeAt(0);
      }
    }
    final top = math.max(s.muscleX[0].isNaN ? -1.0 : s.muscleX[0], s.muscleX[1].isNaN ? -1.0 : s.muscleX[1]);
    s.muscleOn = top >= MuscleRule.x && !s.gap;
  }

  void _burstSecond(Second s) {
    final k = s.k;
    if (s.gap) _lastGap = k;
    final both = math.min(s.muscleX[0].isNaN ? 0.0 : s.muscleX[0], s.muscleX[1].isNaN ? 0.0 : s.muscleX[1]) >= MuscleRule.bothX;
    var peak = double.negativeInfinity;
    for (final x in s.muscleX) {
      if (!x.isNaN && x > peak) peak = x;
    }
    final span = _span;
    if (s.muscleOn) {
      if (span != null && k - span.b <= MuscleRule.joinS && _lastGap < span.b) {
        span
          ..b = k
          ..move = span.move || _pendMove || s.movement
          ..both = span.both || _pendBoth || both
          ..peak = math.max(span.peak, math.max(_pendPeak, peak));
      } else {
        _closeBurst();
        _span = _BurstSpan(k, k)
          ..move = s.movement
          ..both = both
          ..peak = peak;
      }
      _pendMove = false;
      _pendBoth = false;
      _pendPeak = double.negativeInfinity;
    } else if (span != null) {
      _pendMove = _pendMove || s.movement;
      _pendBoth = _pendBoth || both;
      _pendPeak = math.max(_pendPeak, peak);
      if (k - span.b >= MuscleRule.joinS || _lastGap >= span.b) _closeBurst();
    }
  }

  void _closeBurst() {
    final span = _span;
    if (span == null) return;
    final kind = span.move
        ? BurstKind.movement
        : span.both
        ? BurstKind.jaw
        : BurstKind.oneSided;
    bursts.add(Burst(span.a, span.b, kind, span.peak));
    _span = null;
    _pendMove = false;
    _pendBoth = false;
    _pendPeak = double.negativeInfinity;
  }

  void _moveSecond(Second s) {
    final k = s.k, span = _moveSpan;
    if (s.movement) {
      if (span != null && k - span.$2 <= MuscleRule.joinS) {
        _moveSpan = (span.$1, k);
      } else {
        _closeMove();
        _moveSpan = (k, k);
      }
    } else if (span != null && k - span.$2 >= MuscleRule.joinS) {
      _closeMove();
    }
  }

  void _closeMove() {
    final span = _moveSpan;
    if (span != null) movement.add(span);
    _moveSpan = null;
  }

  void _epochSecond(Second s) {
    _epoch.add(s);
    if (_epoch.length < epochS) return;
    var gapS = 0, mv = 0, mu = 0;
    final bad = List<int>.filled(4, 0);
    for (final e in _epoch) {
      if (e.gap) gapS++;
      if (e.movement) mv++;
      if (e.muscleOn) mu++;
      for (var c = 0; c < 4; c++) {
        if (e.flat[c] || e.railed[c] || e.extreme(c) || e.gap) bad[c]++;
      }
    }
    final usable = [for (final b in bad) b <= Quality.badChannelS];
    final EpochQuality q;
    if (gapS > Quality.maxGapS || !usable.contains(true)) {
      q = EpochQuality.missing;
    } else if (usable.contains(false) || mv >= Quality.degradedMoveS || mu >= Quality.degradedMuscleS) {
      q = EpochQuality.degraded;
    } else {
      q = EpochQuality.good;
    }
    epochs.add(QualityEpoch(epochs.length, q, gapS, bad, usable, mv, mu));
    _epoch.clear();
  }
}
