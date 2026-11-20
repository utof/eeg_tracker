// Walking, pace and estimated steps from the headband's own signal, with no motion sensor: a line-by-line port of
// analysis/walking.py (the Python reference; DECISIONS 800-809). Every step shakes the headband a little, which shows
// in the EEG as a rhythm at the step rate and its harmonics:
//   1. every channel of the recording (any number, any layout) band-passed 0.7-20 Hz, forward only from its first value
//      (the shared detectors' RBJ biquads, detectors/filters.dart);
//   2. windows of 10 s every 5 s: per usable channel (not flat, not at the rails) the mean removed, a Hann window, the
//      power spectrum in bins of at most 0.0305 Hz (8192 points at 250 a second), each bin over the mean of the 41
//      around it ("whitened");
//   3. the harmonic score of each step rate from 1.2 to 3.4 Hz (0.02 Hz apart): W(f) + 0.5 W(2f), averaged over the
//      channels; the best rate is the pace, its score over the median of all rates the window's score;
//   4. a window walks at a score of 4 or more and a pace of 90-200 a minute, when it is no pulse: a walking-sized shake
//      (the channels' median band-passed range at least 300 µV) and no family at a third and two thirds of the pace
//      (the whitened power there under 2.5: a sleeping pulse of about 57 a minute reads 115 or 172 otherwise); a
//      majority of 7 windows smooths that, runs of 30 s or more are walking stretches, a pace held at 150 or more for
//      a minute is running; gaps of a minute or more between stretches are stops, stretches under 15 minutes apart
//      one walk;
//   5. steps: pace x 5 s for each window of a stretch whose own rhythm is clear; a confidence word from the median
//      score; per clock minute the phone's step counter wins wherever it counted steps.
// Plain Dart; walking_cross_check_test.dart checks it against the reference on made-up recordings.
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/filters.dart' show Chain, highPass, lowPass;
import '../feedback/features.dart' show median;
import '../sleep/dsp.dart' show Fft;

/// The detector's version: a walk file of another one is made again.
const String walkDetector = 'walk-v2';

/// The planning values (DECISIONS 800-809), the same as analysis/walking.py.
abstract final class WalkRule {
  static const double windowS = 10, hopS = 5;
  static const double highPassHz = 0.7, lowPassHz = 20;
  static final List<double> butterQ = [1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8))];
  static const double binHz = 250 / 8192;
  static const double whitenHz = 41 * binHz;
  static const double paceLoHz = 1.2, paceStepHz = 0.02;
  static const int paceRates = 111;
  static const double harmonic = 0.5;
  static const double scoreWalk = 4;
  static const double paceMinSpm = 90, paceMaxSpm = 200;
  static const double minShakeUv = 300, maxThirds = 2.5;
  static const int smoothWindows = 7;
  static const double minStretchS = 30, minStopS = 60, walkGapS = 900;
  static const double runSpm = 150, minRunS = 60;
  static const double maxMissingS = 1;
  static const double flatUv = 1, railUv = 390000;
  static const double sureScore = 6, likelyScore = 5;
  static const double phoneWalkSteps = 60, phoneMaxGapS = 180;
  static const int checkMinMinutes = 10;
  static const double checkPaceShare = 0.05, checkRightShare = 0.8, checkTotalShare = 0.15;
}

/// The smallest power of two whose bins are at most [WalkRule.binHz] wide (8192 at 250 a second).
int walkNfft(num rate) {
  var n = 1;
  while (rate / n > WalkRule.binHz * (1 + 1e-12)) {
    n *= 2;
  }
  return n;
}

/// Python's round(): halves go to the even neighbour.
int _roundEven(double v) {
  final f = v.floorToDouble(), d = v - f;
  if (d > 0.5) return f.toInt() + 1;
  if (d < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// The odd number of bins nearest to [WalkRule.whitenHz] (41 at 250 a second).
int walkWhitenBins(num rate) => 2 * _roundEven((WalkRule.whitenHz / (rate / walkNfft(rate)) - 1) / 2) + 1;

/// The candidate step rates (Hz).
final Float64List walkRates = Float64List.fromList([
  for (var k = 0; k < WalkRule.paceRates; k++) WalkRule.paceLoHz + k * WalkRule.paceStepHz,
]);

/// Linear interpolation of [w] (bin k at k * [bin]) at [x]: np.interp's formula.
double _interp(double x, double bin, Float64List w) {
  var j = (x / bin).floor();
  if ((j + 1) * bin <= x) {
    j++;
  } else if (j * bin > x) {
    j--;
  }
  final x0 = j * bin, x1 = (j + 1) * bin;
  return (w[j + 1] - w[j]) / (x1 - x0) * (x - x0) + w[j];
}

/// One 10 s window.
class WalkWindow {
  const WalkWindow(this.t, this.score, this.pace, this.amp, this.channels, this.read, [this.thirds = double.nan]);

  /// Its centre, seconds from the recording's first sample.
  final double t;

  /// NaN when not read.
  final double score, pace, amp;

  /// Usable channels.
  final int channels;

  /// False: over 1 s of it missing, or no usable channel.
  final bool read;

  /// The mean whitened power at a third and two thirds of the pace: high for a pulse caught at its 2nd or 3rd harmonic.
  final double thirds;

  bool get walks =>
      read &&
      score >= WalkRule.scoreWalk &&
      pace >= WalkRule.paceMinSpm &&
      pace <= WalkRule.paceMaxSpm &&
      amp >= WalkRule.minShakeUv &&
      thirds < WalkRule.maxThirds;
}

/// The windows of a recording, sample by sample (every channel of its rows, µV): [push] each row, then [windows].
class WalkWindows {
  WalkWindows(this.channels, this.rate)
    : win = _roundEven(WalkRule.windowS * rate),
      hop = _roundEven(WalkRule.hopS * rate),
      nfft = walkNfft(rate),
      wb = walkWhitenBins(rate) {
    final lo = math.min(WalkRule.lowPassHz, 0.4 * rate);
    _chains = [
      for (var c = 0; c < channels; c++)
        Chain([
          for (final q in WalkRule.butterQ) highPass(WalkRule.highPassHz, q: q, sampleRate: rate),
          for (final q in WalkRule.butterQ) lowPass(lo, q: q, sampleRate: rate),
        ]),
    ];
    _y = [for (var c = 0; c < channels; c++) Float64List(win)];
    _x = [for (var c = 0; c < channels; c++) Float64List(win)];
    _miss = Uint8List(win);
    _bin = rate / nfft;
    _lo = math.max(0, (walkRates.first / 3 / _bin).floor());
    _hi = (2 * walkRates.last / _bin).floor() + 1;
    _hann = Float64List.fromList([for (var i = 0; i < win; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / win)]);
    _fft = Fft(nfft);
    _re = Float64List(nfft);
    _im = Float64List(nfft);
  }

  final int channels;
  final int rate;
  final int win, hop, nfft, wb;
  late final List<Chain> _chains;
  late final List<Float64List> _y, _x;
  late final Uint8List _miss;
  late final double _bin;
  /// The bins whitened: from a third of the slowest rate to twice the fastest.
  late final int _lo, _hi;
  late final Float64List _hann;
  late final Fft _fft;
  late final Float64List _re, _im;
  var _n = 0, _missing = 0;
  final List<WalkWindow> windows = [];

  void push(List<double> row, {bool missing = false}) {
    final at = _n % win;
    _missing += (missing ? 1 : 0) - _miss[at];
    _miss[at] = missing ? 1 : 0;
    for (var c = 0; c < channels; c++) {
      _x[c][at] = row[c];
      _y[c][at] = _chains[c].step(row[c]);
    }
    _n++;
    if (_n >= win && (_n - win) % hop == 0) windows.add(_window(_n - win));
  }

  /// The window from sample [s]: its samples sit in the rings from [s] % win on.
  WalkWindow _window(int s) {
    final t = (s + win / 2) / rate;
    if (_missing > WalkRule.maxMissingS * rate) return WalkWindow(t, double.nan, double.nan, double.nan, 0, false);
    final from = s % win;
    final used = <int>[];
    final ranges = <double>[];
    for (var c = 0; c < channels; c++) {
      final y = _y[c], x = _x[c];
      var lo = double.infinity, hi = double.negativeInfinity, rail = false;
      for (var i = 0; i < win; i++) {
        final v = y[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
        if (x[i].abs() >= WalkRule.railUv) rail = true;
      }
      final rng = hi - lo;
      if (rng < WalkRule.flatUv || rail) continue;
      used.add(c);
      ranges.add(rng);
    }
    if (used.isEmpty) return WalkWindow(t, double.nan, double.nan, double.nan, 0, false);
    final tot = Float64List(WalkRule.paceRates);
    final wsum = Float64List(_hi + 1);
    // two channels in one complex transform: the first in the real part, the second in the imaginary part
    for (var u = 0; u < used.length; u += 2) {
      final a = used[u], b = u + 1 < used.length ? used[u + 1] : -1;
      _re.fillRange(0, nfft, 0);
      _im.fillRange(0, nfft, 0);
      _load(_y[a], from, _re);
      if (b >= 0) _load(_y[b], from, _im);
      _fft.transform(_re, _im);
      _score(tot, wsum, (k) {
        final j = k == 0 ? 0 : nfft - k;
        final xr = (_re[k] + _re[j]) / 2, xi = (_im[k] - _im[j]) / 2;
        return xr * xr + xi * xi;
      });
      if (b >= 0) {
        _score(tot, wsum, (k) {
          final j = k == 0 ? 0 : nfft - k;
          final yr = (_im[k] + _im[j]) / 2, yi = -(_re[k] - _re[j]) / 2;
          return yr * yr + yi * yi;
        });
      }
    }
    var best = 0;
    for (var k = 0; k < tot.length; k++) {
      tot[k] /= used.length;
    }
    for (var k = 1; k < tot.length; k++) {
      if (tot[k] > tot[best]) best = k;
    }
    final score = tot[best] / median(tot);
    final f0 = walkRates[best];
    final thirds = (_interp(f0 / 3, _bin, wsum) + _interp(2 * f0 / 3, _bin, wsum)) / 2 / used.length;
    return WalkWindow(t, score, walkRates[best] * 60, median(ranges), used.length, true, thirds);
  }

  /// The ring's window from [from], its mean removed and the Hann window on, into [out] (zero-padded).
  void _load(Float64List ring, int from, Float64List out) {
    var sum = 0.0;
    for (var i = 0; i < win; i++) {
      sum += ring[(from + i) % win];
    }
    final mean = sum / win;
    for (var i = 0; i < win; i++) {
      out[i] = (ring[(from + i) % win] - mean) * _hann[i];
    }
  }

  /// Adds one channel's harmonic score to [tot] and its whitened spectrum to [wsum], its power at bin k from [power].
  void _score(Float64List tot, Float64List wsum, double Function(int k) power) {
    final half = wb ~/ 2;
    final p = Float64List(_hi + half + 1);
    for (var k = 0; k <= _hi + half && k <= nfft ~/ 2; k++) {
      p[k] = power(k);
    }
    final w = Float64List(_hi + 1);
    for (var k = _lo; k <= _hi; k++) {
      // each bin over the mean of the wb around it (zeros below bin 0)
      var s = 0.0;
      for (var j = math.max(0, k - half); j <= k + half; j++) {
        s += p[j];
      }
      w[k] = p[k] / (s / wb);
      wsum[k] += w[k];
    }
    for (var i = 0; i < WalkRule.paceRates; i++) {
      final f = walkRates[i];
      tot[i] += _interp(f, _bin, w) + WalkRule.harmonic * _interp(2 * f, _bin, w);
    }
  }
}

/// Each flag replaced by the majority of the [width] around it (fewer at the ends).
List<bool> walkMajority(List<bool> flags, {int width = WalkRule.smoothWindows}) {
  final half = width ~/ 2;
  return [
    for (var i = 0; i < flags.length; i++)
      () {
        final a = math.max(0, i - half), b = math.min(flags.length, i + half + 1);
        var on = 0;
        for (var j = a; j < b; j++) {
          if (flags[j]) on++;
        }
        return on * 2 > b - a;
      }(),
  ];
}

/// (first, last) of each run of true.
List<(int, int)> walkRuns(List<bool> flags) {
  final out = <(int, int)>[];
  int? a;
  for (var i = 0; i < flags.length; i++) {
    if (flags[i] && a == null) a = i;
    if (!flags[i] && a != null) {
      out.add((a, i - 1));
      a = null;
    }
  }
  if (a != null) out.add((a, flags.length - 1));
  return out;
}

String walkConfidence(double score) =>
    score >= WalkRule.sureScore ? 'sure' : (score >= WalkRule.likelyScore ? 'likely' : 'unsure');

enum StretchKind { walking, running, stopped }

class Stretch {
  const Stretch(this.first, this.last, this.kind, {this.steps = 0, this.pace, this.score, this.confidence});

  /// Window indices, both included.
  final int first, last;
  final StretchKind kind;
  final double steps;

  /// The median pace and score of its clear windows.
  final double? pace, score;
  final String? confidence;

  double get seconds => (last - first + 1) * WalkRule.hopS;
}

class Walk {
  const Walk(this.stretches, {required this.walkingS, required this.stoppedS, required this.steps, this.pace});

  /// In time order: walking, running and stopped.
  final List<Stretch> stretches;

  /// Walking and running.
  final double walkingS, stoppedS, steps;
  final double? pace;
}

/// What the detector found: its windows, the walking flag after the majority, the moving stretches, the walks.
class WalkFound {
  const WalkFound(this.windows, this.smoothed, this.moving, this.walks);
  final List<WalkWindow> windows;
  final List<bool> smoothed;
  final List<Stretch> moving;
  final List<Walk> walks;
}

(double, double?, double?) _summary(List<WalkWindow> ws, Iterable<int> idx) {
  final clear = [for (final i in idx) if (ws[i].walks) i];
  var steps = 0.0;
  for (final i in clear) {
    steps += ws[i].pace / 60 * WalkRule.hopS;
  }
  if (clear.isEmpty) return (steps, null, null);
  return (steps, median([for (final i in clear) ws[i].pace]), median([for (final i in clear) ws[i].score]));
}

Stretch _stretch(List<WalkWindow> ws, int a, int b, StretchKind kind) {
  final (steps, pace, score) = _summary(ws, [for (var i = a; i <= b; i++) i]);
  return Stretch(a, b, kind, steps: steps, pace: pace, score: score, confidence: score == null ? null : walkConfidence(score));
}

List<Stretch> _splitRunning(List<WalkWindow> ws, int a, int b) {
  final fast = walkMajority([for (var i = a; i <= b; i++) ws[i].walks && ws[i].pace >= WalkRule.runSpm]);
  final minRun = (WalkRule.minRunS / WalkRule.hopS).ceil();
  final parts = <Stretch>[];
  var at = a;
  for (final (r0, r1) in walkRuns(fast)) {
    if (r1 - r0 + 1 < minRun) continue;
    if (a + r0 > at) parts.add(_stretch(ws, at, a + r0 - 1, StretchKind.walking));
    parts.add(_stretch(ws, a + r0, a + r1, StretchKind.running));
    at = a + r1 + 1;
  }
  if (at <= b) parts.add(_stretch(ws, at, b, StretchKind.walking));
  return parts;
}

/// The stretches and walks in [ws] (see the top of the file).
WalkFound findWalks(List<WalkWindow> ws) {
  final smoothed = walkMajority([for (final w in ws) w.walks]);
  final minLen = (WalkRule.minStretchS / WalkRule.hopS).ceil();
  final moving = <Stretch>[];
  for (final (a, b) in walkRuns(smoothed)) {
    if (b - a + 1 >= minLen) moving.addAll(_splitRunning(ws, a, b));
  }
  const gapWindows = WalkRule.walkGapS / WalkRule.hopS;
  final stopWindows = (WalkRule.minStopS / WalkRule.hopS).ceil();
  final walks = <Walk>[];
  final walk = <Stretch>[];
  void close() {
    if (walk.isEmpty) return;
    final moved = [for (final s in walk) if (s.kind != StretchKind.stopped) s];
    final (steps, pace, _) = _summary(ws, [for (final s in moved) for (var i = s.first; i <= s.last; i++) i]);
    walks.add(
      Walk(
        List.unmodifiable(walk),
        walkingS: moved.fold(0.0, (t, s) => t + s.seconds),
        stoppedS: walk.where((s) => s.kind == StretchKind.stopped).fold(0.0, (t, s) => t + s.seconds),
        steps: steps,
        pace: pace,
      ),
    );
    walk.clear();
  }

  for (final s in moving) {
    if (walk.isNotEmpty) {
      final gap = s.first - walk.last.last - 1;
      if (gap >= gapWindows) {
        close();
      } else if (gap >= stopWindows && [for (var i = walk.last.last + 1; i < s.first; i++) ws[i].read].every((r) => r)) {
        walk.add(Stretch(walk.last.last + 1, s.first - 1, StretchKind.stopped));
      }
    }
    walk.add(s);
  }
  close();
  return WalkFound(ws, smoothed, moving, walks);
}

/// The phone's steps per clock minute (key: unix seconds of the minute's start) from its step counter's readings
/// (unix seconds, steps since the phone started): the steps between two readings at most [WalkRule.phoneMaxGapS]
/// apart go to the minute holding the middle of that time (a longer time in minute-long parts); a counter that went
/// down (the phone restarted) says nothing until the next reading; minutes no reading covers are absent.
Map<int, double> phoneMinutes(List<(double, int)> readings) {
  final rs = [...readings]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final steps = <int, double>{};
  for (var i = 0; i + 1 < rs.length; i++) {
    final (t0, c0) = rs[i];
    final (t1, c1) = rs[i + 1];
    if (t1 <= t0 || t1 - t0 > WalkRule.phoneMaxGapS || c1 < c0) continue;
    final parts = math.max(1, _roundEven((t1 - t0) / 60));
    for (var j = 0; j < parts; j++) {
      final mid = t0 + (j + 0.5) * (t1 - t0) / parts;
      final m = (mid / 60).floor() * 60;
      steps[m] = (steps[m] ?? 0) + (c1 - c0) / parts;
    }
  }
  return {for (final k in steps.keys.toList()..sort()) k: steps[k]!};
}

/// One clock minute with walking or phone steps.
class WalkMinute {
  const WalkMinute({
    required this.t,
    required this.walkS,
    required this.runS,
    required this.hbSteps,
    this.hbPace,
    this.phone,
    required this.steps,
    required this.source,
    required this.walkingS,
  });

  /// Unix seconds of the minute's start.
  final int t;

  /// The headband's walking seconds (running included) and of them running.
  final double walkS, runS;

  /// The headband's steps (clear windows of its stretches) and their median pace.
  final double hbSteps;
  final double? hbPace;

  /// The phone's steps; null: no step counter for that minute.
  final double? phone;

  /// The minute's steps: the phone's when it counted any, else the headband's.
  final double steps;

  /// `phone`, `headband` or '' (no steps).
  final String source;

  /// 60 when the phone counted [WalkRule.phoneWalkSteps] or more, else [walkS].
  final double walkingS;
}

/// Per clock minute with walking or phone steps: the headband's and the phone's numbers, and which one counts.
List<WalkMinute> walkMinutes(WalkFound found, int startUnix, [Map<int, double> phone = const {}]) {
  final kindAt = <int, StretchKind>{};
  for (final s in found.moving) {
    for (var i = s.first; i <= s.last; i++) {
      kindAt[i] = s.kind;
    }
  }
  final walk = <int, double>{}, run = <int, double>{}, steps = <int, double>{};
  final paces = <int, List<double>>{};
  for (final i in kindAt.keys.toList()..sort()) {
    final w = found.windows[i];
    final m = ((startUnix + w.t) / 60).floor() * 60;
    walk[m] = (walk[m] ?? 0) + WalkRule.hopS;
    run[m] = (run[m] ?? 0) + (kindAt[i] == StretchKind.running ? WalkRule.hopS : 0);
    steps[m] ??= 0;
    paces[m] ??= [];
    if (w.walks) {
      steps[m] = steps[m]! + w.pace / 60 * WalkRule.hopS;
      paces[m]!.add(w.pace);
    }
  }
  final keys = {...walk.keys, for (final e in phone.entries) if (e.value > 0) e.key}.toList()..sort();
  return [
    for (final m in keys)
      () {
        final p = phone[m], hb = steps[m] ?? 0, ws = walk[m] ?? 0;
        final ps = paces[m] ?? const <double>[];
        final (double s, String src) = p != null && p > 0 ? (p, 'phone') : (hb > 0 ? (hb, 'headband') : (0.0, ''));
        return WalkMinute(
          t: m,
          walkS: ws,
          runS: run[m] ?? 0,
          hbSteps: hb,
          hbPace: ps.isEmpty ? null : median(ps),
          phone: p,
          steps: s,
          source: src,
          walkingS: p != null && p >= WalkRule.phoneWalkSteps ? 60 : ws,
        );
      }(),
  ];
}

enum CheckStatus { unchecked, passed, failed }

/// Does the headband's pace hold against the phone's step counter (the research note's gate)?
class WalkCheck {
  const WalkCheck(this.paired, this.right, this.hbSteps, this.phoneSteps, this.status);

  /// Minutes both walked the whole of (the headband all 60 s, the phone 60 steps or more), and of them those with the
  /// headband's pace within 5 % of the phone's steps.
  final int paired, right;
  final double hbSteps, phoneSteps;
  final CheckStatus status;
}

WalkCheck walkCheck(Iterable<WalkMinute> rows) {
  final paired = [
    for (final r in rows)
      if (r.walkS >= 60 && r.hbPace != null && r.phone != null && r.phone! >= WalkRule.phoneWalkSteps) r,
  ];
  var right = 0;
  var hb = 0.0, ph = 0.0;
  for (final r in paired) {
    if ((r.hbPace! - r.phone!).abs() <= WalkRule.checkPaceShare * r.phone!) right++;
    hb += r.hbSteps;
    ph += r.phone!;
  }
  final CheckStatus status;
  if (paired.length < WalkRule.checkMinMinutes) {
    status = CheckStatus.unchecked;
  } else if (right >= WalkRule.checkRightShare * paired.length && (hb - ph).abs() <= WalkRule.checkTotalShare * ph) {
    status = CheckStatus.passed;
  } else {
    status = CheckStatus.failed;
  }
  return WalkCheck(paired.length, right, hb, ph, status);
}
