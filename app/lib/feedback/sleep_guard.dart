// Drift-to-sleep detector for eyes-closed sessions, shared by every feature that must notice dozing
// (DECISIONS rows 46 and 62). A line-by-line port of scripts/web/sleep-guard.js, same constants.
//
// Three signs, each against the person's own eyes-closed baseline:
//   theta:  theta / alpha (4 s means) above 1.5x the baseline ratio for 10 s in a row
//   slow:   the alpha peak (median of the clear peaks of the last 10 s) 1 Hz or more below the baseline peak
//   faded:  alpha (1 s means) under half the baseline for more than half of the last 30 s
// It cannot tell open eyes from dozing: both lower alpha at O1/O2. All numbers are planning values.
// No clock inside: time is counted in steps.
import 'features.dart';

abstract final class Guard {
  static const double ratioX = 1.5, ratioS = 10; // theta/alpha above 1.5x baseline for 10 s
  static const double peakDropHz = 1, peakS = 10; // alpha peak 1 Hz slower over 10 s,
  static const int minPeaks = 5; // from at least 5 clear peaks
  static const double fadeX = 0.5, fadeS = 30, fadeShare = 0.5; // alpha under 0.5x baseline in over half of 30 s
  static const double meanS = 4, alphaS = 1; // averaging windows
}

/// The person's eyes-closed baseline: alpha power (µV²), theta/alpha ratio, alpha peak (Hz). Null = unknown.
class GuardBaseline {
  const GuardBaseline({required this.alpha, required this.ratio, required this.iaf});
  final double? alpha;
  final double? ratio;
  final double? iaf;

  Map<String, Object?> toJson() => {'alpha': alpha, 'ratio': ratio, 'iaf': iaf};
}

/// Baseline from eyes-closed steps: alpha and theta powers (one value per step), whether each step was
/// clean, and the alpha peak (Hz or null). Uses the same window means the guard uses.
GuardBaseline guardBaseline(List<double> alpha, List<double> theta, List<bool> clean, double? iaf, [double stepS = 0.1]) {
  final nMean = (Guard.meanS / stepS).round(), nAlpha = (Guard.alphaS / stepS).round();
  final ratios = <double>[], alphas = <double>[];
  for (var i = nMean - 1; i < alpha.length; i++) {
    if (!clean[i]) continue;
    var a4 = 0.0, t4 = 0.0, a1 = 0.0;
    for (var j = i - nMean + 1; j <= i; j++) {
      a4 += alpha[j];
      t4 += theta[j];
    }
    for (var j = i - nAlpha + 1; j <= i; j++) {
      a1 += alpha[j];
    }
    if (a4 > 0) ratios.add(t4 / a4);
    alphas.add(a1 / nAlpha);
  }
  return GuardBaseline(
    alpha: alphas.isNotEmpty ? median(alphas) : null,
    ratio: ratios.isNotEmpty ? median(ratios) : null,
    iaf: iaf,
  );
}

/// What the guard says after a step.
class GuardState {
  bool drowsy = false;
  bool theta = false;
  bool slow = false;
  bool faded = false;

  /// theta/alpha against the baseline ratio (1 = as at baseline).
  double? ratio;
  double? peakHz;
  double fadedShare = 0;

  GuardState copy() => GuardState()
    ..drowsy = drowsy
    ..theta = theta
    ..slow = slow
    ..faded = faded
    ..ratio = ratio
    ..peakHz = peakHz
    ..fadedShare = fadedShare;
}

class SleepGuard {
  SleepGuard(this.base, [this.stepS = 0.1])
    : _nMean = (Guard.meanS / stepS).round(),
      _nAlpha = (Guard.alphaS / stepS).round(),
      _nFade = (Guard.fadeS / stepS).round(),
      _nRatio = (Guard.ratioS / stepS).round(),
      _nPeak = (Guard.peakS / stepS).round() {
    reset();
  }

  final GuardBaseline base;
  final double stepS;
  final int _nMean, _nAlpha, _nFade, _nRatio, _nPeak;
  List<double> _alpha = [];
  List<double> _theta = [];
  List<bool> _faded = [];
  int _ratioRun = 0;
  List<(int, double)> _peaks = [];
  int _step = 0;
  GuardState state = GuardState();

  /// After a gap in the signal: start the windows again.
  void reset() {
    _alpha = [];
    _theta = [];
    _faded = [];
    _ratioRun = 0;
    _peaks = [];
    _step = 0;
    state = GuardState();
  }

  /// Once per step: alpha and theta power (µV²) of the clean back channels. Returns the state.
  GuardState update(double alpha, double theta) {
    final b = base, st = state;
    _step++;
    _push(_alpha, alpha, _nMean);
    _push(_theta, theta, _nMean);
    final n = _alpha.length;
    var a1 = 0.0;
    for (var j = n - _nAlpha < 0 ? 0 : n - _nAlpha; j < n; j++) {
      a1 += _alpha[j];
    }
    a1 /= n < _nAlpha ? n : _nAlpha;
    _push(_faded, b.alpha != null && a1 < Guard.fadeX * b.alpha!, _nFade);
    final fadedCount = _faded.where((f) => f).length;
    st.fadedShare = fadedCount / _nFade;
    st.faded = fadedCount > Guard.fadeShare * _nFade;

    if (n >= _nMean && b.ratio != null) {
      final a4 = _sum(_alpha), t4 = _sum(_theta);
      st.ratio = a4 > 0 ? t4 / a4 / b.ratio! : null;
      _ratioRun = st.ratio != null && st.ratio! > Guard.ratioX ? _ratioRun + 1 : 0;
    } else {
      st.ratio = null;
      _ratioRun = 0;
    }
    st.theta = _ratioRun >= _nRatio;

    while (_peaks.isNotEmpty && _peaks.first.$1 <= _step - _nPeak) {
      _peaks.removeAt(0);
    }
    final hz = [for (final p in _peaks) p.$2];
    st.peakHz = hz.isNotEmpty ? median(hz) : null;
    st.slow = b.iaf != null && hz.length >= Guard.minPeaks && st.peakHz! <= b.iaf! - Guard.peakDropHz + 1e-9;

    st.drowsy = st.theta || st.slow || st.faded;
    return st;
  }

  /// About once a second: the alpha peak of the last few seconds (Hz), or null when there is no clear peak.
  void peak(double? hz) {
    if (hz != null) _peaks.add((_step, hz));
  }
}

void _push<T>(List<T> a, T v, int max) {
  a.add(v);
  if (a.length > max) a.removeAt(0);
}

double _sum(List<double> a) {
  var s = 0.0;
  for (final v in a) {
    s += v;
  }
  return s;
}
