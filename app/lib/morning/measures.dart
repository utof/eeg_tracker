// The morning check-in's measures, a line-by-line port of scripts/morning_check.py (DECISIONS rows 22-25), so the
// phone and the laptop give the same numbers for the same signal (app/test/morning_cross_check_test.dart):
//   - each phase cut into 2 s segments; a segment is dropped when, after a 1-40 Hz band-pass (SciPy's 4th-order
//     Butterworth run forward and back, `sosfiltfilt`), it swings over 150 µV, is flat (spread under 0.5 µV) or
//     is over 3x the phase's median spread; a channel needs 10 clean segments (20 s) per phase;
//   - the mean spectrum of the kept segments (SciPy's `periodogram`: linear detrend, Hann window, zero-padded to
//     0.25 Hz, power density in µV²/Hz);
//   - alpha power 8-13 Hz, the 1/f line (2-40 Hz without 7-14 Hz), and alpha speed: the centre of gravity of the
//     power above that line in 7-14 Hz, empty without a peak 0.1 log units above it.
// Plain Dart, no Flutter: it runs in a background isolate and in tests.
import 'dart:math' as math;
import 'dart:typed_data';

import 'pyfmt.dart';

const int morningFs = 250;
const List<String> backChannels = ['O1', 'O2'];
const double segS = 2.0;
const double p2pUv = 150.0;
const double flatUv = 0.5;
const double relSpread = 3.0;
const double skipStartS = 3.0, skipEndS = 1.0;
const (double, double) alphaBand = (8.0, 13.0);
const (double, double) iafRange = (7.0, 14.0);
const (double, double) fitRange = (2.0, 40.0);

/// A channel's values stay empty with fewer clean segments than this in a phase (20 s).
const int minCleanSegs = 10;

/// log10 units above the 1/f line (about +26 %) for an alpha peak to count.
const double peakMin = 0.1;

/// Spectrum resolution (Hz) and the highest bin kept (50 Hz: everything the measures use).
const double binHz = 0.25;
const int nfft = 1000; // morningFs / binHz
const int maxBin = 200;

const int _segN = 500; // segS * morningFs

// ---------------------------------------------------------------- the 1-40 Hz band-pass

typedef _C = (double, double);

_C _add(_C a, _C b) => (a.$1 + b.$1, a.$2 + b.$2);
_C _sub(_C a, _C b) => (a.$1 - b.$1, a.$2 - b.$2);
_C _mul(_C a, _C b) => (a.$1 * b.$1 - a.$2 * b.$2, a.$1 * b.$2 + a.$2 * b.$1);
_C _div(_C a, _C b) {
  final d = b.$1 * b.$1 + b.$2 * b.$2;
  return ((a.$1 * b.$1 + a.$2 * b.$2) / d, (a.$2 * b.$1 - a.$1 * b.$2) / d);
}

_C _sqrt(_C a) {
  final r = math.sqrt(a.$1 * a.$1 + a.$2 * a.$2);
  final re = math.sqrt((r + a.$1) / 2);
  final im = math.sqrt(math.max(0.0, (r - a.$1) / 2));
  return (re, a.$2 < 0 ? -im : im);
}

/// `scipy.signal.butter(4, [lo, hi], btype="bandpass", fs=fs, output="sos")` as four sections [b0 b1 b2 a1 a2]:
/// the analog prototype's poles moved to the band (lp2bp_zpk), through the bilinear transform; each section takes
/// one pole pair and the zeros +1 and -1, the gain sits on the first. A different grouping than SciPy's, the same
/// filter.
List<List<double>> butterBandpass(double lo, double hi, {int fs = morningFs}) {
  const order = 4;
  const fsDesign = 2.0;
  final w1 = 2 * fsDesign * math.tan(math.pi * (lo / (fs / 2)) / fsDesign);
  final w2 = 2 * fsDesign * math.tan(math.pi * (hi / (fs / 2)) / fsDesign);
  final bw = w2 - w1, wo2 = w1 * w2;
  final analog = <_C>[];
  for (var m = -order + 1; m < order; m += 2) {
    final p = (-math.cos(math.pi * m / (2 * order)), -math.sin(math.pi * m / (2 * order)));
    final pl = (p.$1 * bw / 2, p.$2 * bw / 2);
    final root = _sqrt(_sub(_mul(pl, pl), (wo2, 0)));
    analog
      ..add(_add(pl, root))
      ..add(_sub(pl, root));
  }
  const fs2 = 2 * fsDesign;
  var gain = math.pow(bw, order).toDouble() * math.pow(fs2, order).toDouble(); // zeros at 0: prod(fs2 - 0)
  var den = (1.0, 0.0);
  final digital = <_C>[];
  for (final p in analog) {
    den = _mul(den, _sub((fs2, 0), p));
    digital.add(_div(_add((fs2, 0), p), _sub((fs2, 0), p)));
  }
  gain = _div((gain, 0), den).$1;
  final upper = digital.where((p) => p.$2 > 0).toList();
  return [
    for (final (i, p) in upper.indexed)
      [i == 0 ? gain : 1.0, 0.0, i == 0 ? -gain : -1.0, -2 * p.$1, p.$1 * p.$1 + p.$2 * p.$2],
  ];
}

final List<List<double>> _band = butterBandpass(1, 40);

/// The cascade's response to [x] from rest (transposed direct form II, as `sosfilt`).
Float64List _sosZeroState(List<List<double>> sos, Float64List x) {
  final y = Float64List.fromList(x);
  for (final s in sos) {
    final b0 = s[0], b1 = s[1], b2 = s[2], a1 = s[3], a2 = s[4];
    var z1 = 0.0, z2 = 0.0;
    for (var i = 0; i < y.length; i++) {
      final v = y[i];
      final out = b0 * v + z1;
      z1 = b1 * v - a1 * out + z2;
      z2 = b2 * v - a2 * out;
      y[i] = out;
    }
  }
  return y;
}

/// `sosfiltfilt(sos, x)` with its defaults (odd extension of 3 x (2 x sections + 1) samples, each pass starting
/// in the steady state of its first value). The band-pass passes no constant, so a pass from that steady state
/// is the pass from rest of the signal minus its first value.
Float64List filtfilt(List<List<double>> sos, Float64List x) {
  final edge = 3 * (2 * sos.length + 1);
  final n = x.length;
  if (n <= edge) throw ArgumentError('the signal must be longer than $edge samples');
  final ext = Float64List(n + 2 * edge);
  for (var i = 0; i < edge; i++) {
    ext[i] = 2 * x[0] - x[edge - i];
    ext[n + edge + i] = 2 * x[n - 1] - x[n - 2 - i];
  }
  ext.setRange(edge, edge + n, x);
  final x0 = ext[0];
  for (var i = 0; i < ext.length; i++) {
    ext[i] -= x0;
  }
  final fwd = _sosZeroState(sos, ext);
  final m = fwd.length, y0 = fwd[m - 1];
  final rev = Float64List(m);
  for (var i = 0; i < m; i++) {
    rev[i] = fwd[m - 1 - i] - y0;
  }
  final back = _sosZeroState(sos, rev);
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = back[m - 1 - edge - i];
  }
  return out;
}

/// The 1-40 Hz band-pass the rejection rules look through.
Float64List bandpass1to40(Float64List x) => filtfilt(_band, x);

// ---------------------------------------------------------------- clean segments

typedef Segments = ({List<Float64List> all, List<bool> keep});

extension KeptSegments on Segments {
  List<Float64List> get kept => [
    for (var i = 0; i < all.length; i++)
      if (keep[i]) all[i],
  ];
}

double _mean(Float64List x) {
  var s = 0.0;
  for (final v in x) {
    s += v;
  }
  return s / x.length;
}

double _std(Float64List x) {
  final m = _mean(x);
  var s = 0.0;
  for (final v in x) {
    s += (v - m) * (v - m);
  }
  return math.sqrt(s / x.length);
}

/// NumPy's median.
double median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// One channel of one phase cut into 2 s segments, and which of them are clean (morning_check.clean_segments).
Segments cleanSegments(Float64List x) {
  final k = x.length ~/ _segN;
  if (k == 0) return (all: const <Float64List>[], keep: const <bool>[]);
  final raw = [for (var i = 0; i < k; i++) Float64List.sublistView(x, i * _segN, (i + 1) * _segN)];
  final List<Float64List> f;
  if (x.length > 3 * _segN) {
    final b = bandpass1to40(x);
    f = [for (var i = 0; i < k; i++) Float64List.sublistView(b, i * _segN, (i + 1) * _segN)];
  } else {
    f = [
      for (final s in raw) Float64List.fromList([for (final v in s) v - _mean(s)]),
    ];
  }
  final sd = [for (final s in f) _std(s)];
  final keep = [
    for (var i = 0; i < k; i++) f[i].reduce(math.max) - f[i].reduce(math.min) <= p2pUv && sd[i] >= flatUv,
  ];
  final kept = [
    for (var i = 0; i < k; i++)
      if (keep[i]) sd[i],
  ];
  if (kept.isNotEmpty) {
    final limit = relSpread * median(kept);
    for (var i = 0; i < k; i++) {
      keep[i] = keep[i] && sd[i] <= limit;
    }
  }
  return (all: raw, keep: keep);
}

// ---------------------------------------------------------------- spectrum

final Float64List _hann = Float64List.fromList([
  for (var i = 0; i < _segN; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / _segN),
]);
final double _hannPower = _hann.fold(0.0, (s, w) => s + w * w);
final Float64List _cos = Float64List.fromList([for (var m = 0; m < nfft; m++) math.cos(2 * math.pi * m / nfft)]);
final Float64List _sin = Float64List.fromList([for (var m = 0; m < nfft; m++) math.sin(2 * math.pi * m / nfft)]);

/// One segment's power density (µV²/Hz) at bins 0..[maxBin] (0.25 Hz apart), as scipy.signal.periodogram with
/// window="hann", nfft=1000, detrend="linear" (one-sided: every bin but 0 doubled).
Float64List segmentSpectrum(Float64List seg) {
  final n = seg.length;
  final m = _mean(seg), c = (n - 1) / 2;
  var stx = 0.0, stt = 0.0;
  for (var i = 0; i < n; i++) {
    stx += (i - c) * (seg[i] - m);
    stt += (i - c) * (i - c);
  }
  final slope = stx / stt;
  final y = Float64List(n);
  for (var i = 0; i < n; i++) {
    y[i] = (seg[i] - m - slope * (i - c)) * _hann[i];
  }
  final p = Float64List(maxBin + 1);
  final scale = 1 / (morningFs * _hannPower);
  for (var k = 0; k <= maxBin; k++) {
    var re = 0.0, im = 0.0;
    for (var i = 0; i < n; i++) {
      final at = (k * i) % nfft;
      re += y[i] * _cos[at];
      im -= y[i] * _sin[at];
    }
    p[k] = (re * re + im * im) * scale * (k == 0 ? 1 : 2);
  }
  return p;
}

/// The mean spectrum of the segments (morning_check.spectrum).
Float64List meanSpectrum(List<Float64List> segs) {
  final p = Float64List(maxBin + 1);
  for (final s in segs) {
    final q = segmentSpectrum(s);
    for (var k = 0; k <= maxBin; k++) {
      p[k] += q[k];
    }
  }
  for (var k = 0; k <= maxBin; k++) {
    p[k] /= segs.length;
  }
  return p;
}

double _f(int k) => k * binHz;
bool _in(int k, (double, double) r) => _f(k) >= r.$1 && _f(k) <= r.$2;

/// Power between [lo] and [hi] Hz by the trapezoid rule (np.trapezoid).
double bandPower(Float64List p, double lo, double hi) {
  var s = 0.0;
  int? prev;
  for (var k = 0; k < p.length; k++) {
    if (_f(k) < lo || _f(k) > hi) continue;
    if (prev != null) s += (p[prev] + p[k]) / 2 * (_f(k) - _f(prev));
    prev = k;
  }
  return s;
}

/// The straight line of log10 power on log10 frequency, 2-40 Hz without 7-14 Hz (np.polyfit, degree 1).
({double slope, double intercept}) aperiodicFit(Float64List p) {
  final xs = <double>[], ys = <double>[];
  for (var k = 0; k < p.length; k++) {
    if (_in(k, fitRange) && !_in(k, iafRange) && p[k] > 0) {
      xs.add(math.log(_f(k)) / math.ln10);
      ys.add(math.log(p[k]) / math.ln10);
    }
  }
  final mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
  var sxy = 0.0, sxx = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sxy += (xs[i] - mx) * (ys[i] - my);
    sxx += (xs[i] - mx) * (xs[i] - mx);
  }
  final slope = sxy / sxx;
  return (slope: slope, intercept: my - slope * mx);
}

double _log10(double v) => math.log(v) / math.ln10;

/// Alpha speed: centre of gravity and peak of the power above the 1/f line in 7-14 Hz.
({double? iafHz, double? iafPeakHz, bool present, double aboveLine}) alphaFrequency(
  Float64List p,
  double slope,
  double intercept,
) {
  final ks = [
    for (var k = 0; k < p.length; k++)
      if (_in(k, iafRange)) k,
  ];
  final line = [for (final k in ks) math.pow(10, intercept + slope * _log10(_f(k))).toDouble()];
  final resid = [for (var i = 0; i < ks.length; i++) _log10(math.max(p[ks[i]], 1e-12)) - _log10(line[i])];
  var best = 0;
  for (var i = 1; i < resid.length; i++) {
    if (resid[i] > resid[best]) best = i;
  }
  var peak = _f(ks[best]);
  if (best > 0 && best < ks.length - 1) {
    final a = resid[best - 1], b = resid[best], c = resid[best + 1];
    final d = a - 2 * b + c;
    if (d < 0) peak += 0.5 * (a - c) / d * binHz;
  }
  final present = resid[best] >= peakMin;
  var num = 0.0, sum = 0.0;
  for (var i = 0; i < ks.length; i++) {
    final e = math.max(p[ks[i]] - line[i], 0.0);
    num += _f(ks[i]) * e;
    sum += e;
  }
  final cog = present && sum > 0 ? num / sum : null;
  return (
    iafHz: cog == null ? null : pyRound(cog, 2),
    iafPeakHz: present ? pyRound(peak, 2) : null,
    present: present,
    aboveLine: pyRound(resid[best], 3),
  );
}

// ---------------------------------------------------------------- one channel, both channels

/// One back channel's values (the `channels.O1` object of `<start>.morning.json`).
class ChannelMeasures {
  const ChannelMeasures({
    required this.cleanShareEc,
    required this.cleanSEc,
    this.alphaEc,
    this.slopeEc,
    this.iafHz,
    this.iafPeakHz,
    this.peakPresent,
    this.peakAboveLine,
    this.alphaEo,
    this.ecRise,
    this.cleanShareEo,
    this.cleanSEo,
  });

  final double cleanShareEc, cleanSEc;
  final double? alphaEc, slopeEc, iafHz, iafPeakHz;
  final bool? peakPresent;
  final double? peakAboveLine, alphaEo, ecRise, cleanShareEo, cleanSEo;

  Map<String, Object?> toJson() => {
    'clean_share_ec': cleanShareEc,
    'clean_s_ec': cleanSEc,
    'alpha_ec_uv2': alphaEc,
    'aperiodic_slope_ec': slopeEc,
    'iaf_hz': iafHz,
    'iaf_peak_hz': iafPeakHz,
    'alpha_peak_present': peakPresent,
    'alpha_peak_above_1f': peakAboveLine,
    'alpha_eo_uv2': alphaEo,
    'ec_rise': ecRise,
    'clean_share_eo': cleanShareEo,
    'clean_s_eo': cleanSEo,
  };

  /// Null unless [j] holds a channel's two clean values.
  static ChannelMeasures? fromJson(Object? j) {
    if (j is! Map) return null;
    double? d(String k) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).toDouble() : null;
    final share = d('clean_share_ec'), s = d('clean_s_ec');
    if (share == null || s == null) return null;
    return ChannelMeasures(
      cleanShareEc: share,
      cleanSEc: s,
      alphaEc: d('alpha_ec_uv2'),
      slopeEc: d('aperiodic_slope_ec'),
      iafHz: d('iaf_hz'),
      iafPeakHz: d('iaf_peak_hz'),
      peakPresent: j['alpha_peak_present'] is bool ? j['alpha_peak_present'] as bool : null,
      peakAboveLine: d('alpha_peak_above_1f'),
      alphaEo: d('alpha_eo_uv2'),
      ecRise: d('ec_rise'),
      cleanShareEo: d('clean_share_eo'),
      cleanSEo: d('clean_s_eo'),
    );
  }
}

/// All values of one channel from its eyes-closed and eyes-open samples (µV), as morning_check.channel_measures.
ChannelMeasures channelMeasures(Float64List ec, Float64List? eo) {
  final c = cleanSegments(ec);
  final nEc = c.keep.where((k) => k).length;
  final shareEc = c.keep.isEmpty ? 0.0 : pyRound(nEc / c.keep.length, 3);
  double? alphaEc, slopeEc, iaf, peak, above;
  bool? present;
  final okEc = nEc >= minCleanSegs;
  if (okEc) {
    final p = meanSpectrum(c.kept);
    alphaEc = pyRound(bandPower(p, alphaBand.$1, alphaBand.$2), 2);
    final line = aperiodicFit(p);
    slopeEc = pyRound(line.slope, 3);
    final a = alphaFrequency(p, line.slope, line.intercept);
    iaf = a.iafHz;
    peak = a.iafPeakHz;
    present = a.present;
    above = a.aboveLine;
  }
  double? alphaEo, rise, shareEo, sEo;
  if (eo != null) {
    final o = cleanSegments(eo);
    final nEo = o.keep.where((k) => k).length;
    shareEo = o.keep.isEmpty ? 0.0 : pyRound(nEo / o.keep.length, 3);
    sEo = nEo * segS;
    if (nEo >= minCleanSegs) {
      alphaEo = pyRound(bandPower(meanSpectrum(o.kept), alphaBand.$1, alphaBand.$2), 2);
      if (okEc && alphaEo > 0) rise = pyRound(alphaEc! / alphaEo, 2);
    }
  }
  return ChannelMeasures(
    cleanShareEc: shareEc,
    cleanSEc: nEc * segS,
    alphaEc: alphaEc,
    slopeEc: slopeEc,
    iafHz: iaf,
    iafPeakHz: peak,
    peakPresent: present,
    peakAboveLine: above,
    alphaEo: alphaEo,
    ecRise: rise,
    cleanShareEo: shareEo,
    cleanSEo: sEo,
  );
}

/// O1 and O2 combined (the `back` object): geometric mean for the powers and the rise, plain mean for alpha speed
/// and the slope, the mean clean share of both phases and both channels.
Map<String, double?> backSummary(Map<String, ChannelMeasures> ch) {
  double? comb(double? Function(ChannelMeasures m) get, {required bool geo}) {
    final v = [
      for (final n in backChannels)
        if (ch[n] != null && get(ch[n]!) != null) get(ch[n]!)!,
    ];
    if (v.isEmpty) return null;
    if (geo) return pyRound(math.exp(v.map(math.log).reduce((a, b) => a + b) / v.length), 2);
    return pyRound(v.reduce((a, b) => a + b) / v.length, 3);
  }

  final shares = [
    for (final n in backChannels)
      if (ch[n] != null) ...[ch[n]!.cleanShareEc, ?ch[n]!.cleanShareEo],
  ];
  return {
    'alpha_ec_uv2': comb((m) => m.alphaEc, geo: true),
    'alpha_eo_uv2': comb((m) => m.alphaEo, geo: true),
    'ec_rise': comb((m) => m.ecRise, geo: true),
    'iaf_hz': comb((m) => m.iafHz, geo: false),
    'aperiodic_slope_ec': comb((m) => m.slopeEc, geo: false),
    'clean_share': shares.isEmpty ? null : pyRound(shares.reduce((a, b) => a + b) / shares.length, 3),
  };
}
