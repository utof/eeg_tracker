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

import '../detectors/filters.dart' show Chain;
import '../detectors/harmonic.dart';
import '../feedback/features.dart' show median;

/// The detector's version: a walk file of another one is made again.
const String walkDetector = 'walk-v2';

/// The planning values (DECISIONS 800-809), the same as analysis/walking.py.
abstract final class WalkRule {
  static const double windowS = 10, hopS = 5;
  static const double highPassHz = 0.7, lowPassHz = 20;
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
int walkNfft(num rate) => harmonicNfft(rate, WalkRule.binHz);

/// The odd number of bins nearest to [WalkRule.whitenHz] (41 at 250 a second).
int walkWhitenBins(num rate) => harmonicWhitenBins(rate, WalkRule.binHz, WalkRule.whitenHz);

/// The candidate step rates (Hz).
final Float64List walkRates = Float64List.fromList([
  for (var k = 0; k < WalkRule.paceRates; k++) WalkRule.paceLoHz + k * WalkRule.paceStepHz,
]);

const List<double> _family = [1, WalkRule.harmonic];

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
/// With [quick] only whether each window walks is wanted (the sleep scorers' and the pulse's veto): a window whose
/// shake is under walking size is read without its spectrum (score and pace NaN); every window's
/// [WalkWindow.walks] is the same either way.
class WalkWindows {
  WalkWindows(this.channels, this.rate, {this.quick = false})
    : win = roundEven(WalkRule.windowS * rate),
      hop = roundEven(WalkRule.hopS * rate),
      nfft = walkNfft(rate),
      wb = walkWhitenBins(rate) {
    _chains = [
      for (var c = 0; c < channels; c++)
        bandPass(rate, highPassHz: WalkRule.highPassHz, lowPassHz: WalkRule.lowPassHz),
    ];
    _y = [for (var c = 0; c < channels; c++) Float64List(win)];
    _x = [for (var c = 0; c < channels; c++) Float64List(win)];
    _miss = Uint8List(win);
    _bin = rate / nfft;
    _lo = math.max(0, (walkRates.first / 3 / _bin).floor());
    _hi = (2 * walkRates.last / _bin).floor() + 1;
    _hann = hannWindow(win);
    _p = Float64List(_hi + wb ~/ 2 + 1);
    _w = Float64List(_hi + 1);
  }

  final int channels;
  final int rate;
  final bool quick;
  final int win, hop, nfft, wb;
  late final List<Chain> _chains;
  late final List<Float64List> _y, _x;
  late final Uint8List _miss;
  late final double _bin;

  /// The bins whitened: from a third of the slowest rate to twice the fastest.
  late final int _lo, _hi;
  late final Float64List _hann, _p, _w;
  PairSpectrum? _pair; // made at the first window that needs a spectrum (a quick pass over sleep never does)
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
    final amp = median(ranges);
    if (quick && amp < WalkRule.minShakeUv) return WalkWindow(t, double.nan, double.nan, amp, used.length, true);
    final tot = Float64List(WalkRule.paceRates);
    final wsum = Float64List(_hi + 1);
    final pair = _pair ??= PairSpectrum(nfft);
    for (var u = 0; u < used.length; u += 2) {
      final a = used[u], b = u + 1 < used.length ? used[u + 1] : -1;
      pair.clear();
      pair.load(_y[a], from, _hann, ring: true);
      if (b >= 0) pair.load(_y[b], from, _hann, second: true, ring: true);
      pair.transform();
      _score(tot, wsum, pair.first);
      if (b >= 0) _score(tot, wsum, pair.second);
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
    final thirds = (interpAt(f0 / 3, _bin, wsum) + interpAt(2 * f0 / 3, _bin, wsum)) / 2 / used.length;
    return WalkWindow(t, score, walkRates[best] * 60, amp, used.length, true, thirds);
  }

  /// Adds one channel's harmonic score to [tot] and its whitened spectrum to [wsum], its power at bin k from [power].
  void _score(Float64List tot, Float64List wsum, double Function(int k) power) {
    final p = _p, w = _w;
    final top = math.min(p.length - 1, nfft ~/ 2);
    p.fillRange(0, p.length, 0);
    for (var k = 0; k <= top; k++) {
      p[k] = power(k);
    }
    w.fillRange(0, w.length, 0);
    whitenInto(p, _lo, _hi, wb, w);
    for (var k = _lo; k <= _hi; k++) {
      wsum[k] += w[k];
    }
    for (var i = 0; i < WalkRule.paceRates; i++) {
      tot[i] += familyAt(walkRates[i], _bin, w, _family);
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

/// Walking per 30 s epoch (the sleep scorers' and the pulse's epoch), DECISIONS 920.
abstract final class WalkEpoch {
  static const double epochS = 30;

  /// Windows whose middle lies in one epoch (6).
  static final int windows = (epochS / WalkRule.hopS).round();

  /// An epoch is walking with this many of them in a walking stretch (half).
  static final int walkWindows = windows ~/ 2;
}

/// Whether epoch [e] (30 s, counted from the recording's first sample) is walking: at least half of the windows whose
/// middle lies in it belong to a walking or running stretch (a run of 30 s or more of the 7-window majority of
/// [flags], each window's own [WalkWindow.walks]). Reads only the windows up to 40 s either side of the epoch, so the
/// live scorer, which knows the signal up to 2 minutes past the epoch, gets what the whole recording gives. Stops
/// inside a walk are not walking. analysis/walking.py `epoch_walks`.
bool walkEpochWalks(List<bool> flags, int e) {
  final n = flags.length;
  final per = WalkEpoch.windows;
  final a = per * e - 1, b = per * e + per - 2; // middles at 5 i + 5 s in [30 e, 30 e + 30)
  final minLen = (WalkRule.minStretchS / WalkRule.hopS).ceil();
  final lo = math.max(0, a - minLen + 1), hi = math.min(n - 1, b + minLen - 1);
  if (hi < lo) return false;
  const half = WalkRule.smoothWindows ~/ 2;
  var count = 0, run = -1; // run: where the current run of the majority began (index), -1 outside one
  void close(int last) {
    if (run >= 0 && last - run + 1 >= minLen) {
      final int from = a > run ? a : run, to = b < last ? b : last;
      if (to >= from) count += to - from + 1;
    }
    run = -1;
  }

  for (var i = lo; i <= hi; i++) {
    var yes = 0, all = 0;
    for (var j = math.max(0, i - half); j <= i + half && j < n; j++) {
      all++;
      if (flags[j]) yes++;
    }
    if (yes * 2 > all) {
      if (run < 0) run = i;
    } else {
      close(i - 1);
    }
  }
  close(hi);
  return count >= WalkEpoch.walkWindows;
}

/// Walking or not for each of [epochs] 30 s epochs from the recording's first sample ([walkEpochWalks]).
List<bool> walkingEpochs(List<WalkWindow> ws, int epochs) {
  final flags = [for (final w in ws) w.walks];
  return [for (var e = 0; e < epochs; e++) walkEpochWalks(flags, e)];
}

/// The stages that the veto turns awake.
const Set<String> walkVetoStages = {'N1', 'N2', 'N3', 'R'};

/// [stages] with every asleep epoch (N1 N2 N3 R) that is [walking] scored awake: nobody sleeps while walking, and
/// the step shake reads as slow waves to a sleep model. Gaps and wake stay. The stages and how many changed.
(List<String>, int) walkingVeto(List<String> stages, List<bool> walking) {
  final out = List<String>.of(stages);
  var changed = 0;
  for (var e = 0; e < out.length && e < walking.length; e++) {
    if (walking[e] && walkVetoStages.contains(out[e])) {
      out[e] = 'W';
      changed++;
    }
  }
  return (out, changed);
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
    final parts = math.max(1, roundEven((t1 - t0) / 60));
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
