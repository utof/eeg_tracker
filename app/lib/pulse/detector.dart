// Pulse (heart rate) from the headband's own signal, with no pulse sensor: a line-by-line port of
// analysis/pulse.py (DECISIONS 810-819), checked against it by test/pulse_cross_check_test.dart. Per 30 s epoch counted
// from the recording's first sample:
//   1. every channel the recording's header names (any number, any layout), 50 and 60 Hz notches, then band-passed
//      0.5-20 Hz (fourth-order Butterworth each way), forward only from the channel's first value;
//   2. not read: over 1 s missing (g), no usable channel (x: flat or at the rails), moving (m: the usable channels'
//      median band-passed range over 400 µV);
//   3. per usable channel the Welch spectrum (8 s Hann segments every 4 s, 0.061 Hz bins) whitened by the mean of the
//      15 bins around each bin, and the harmonic score of each rate 42-120 a minute: the mean whitened power at f0,
//      2 f0, 3 f0 and 4 f0; the channel with the highest confidence (best score over the median score) is read;
//   4. a reading (r) from 2.2 + 0.1 per doubling of the usable channels, not at the range's edge, and not when it
//      looks like steps (s: power at half the rate from 84 a minute; even harmonics stronger than the odd ones at
//      45-72; strong 5th-8th harmonics) or may be twice a slower rhythm (u: power at half the rate under 84);
//   5. the neighbours: the odd one out (o) 12 or more from two or more agreeing readings within 1.5 minutes; an unclear
//      epoch with its own peak of confidence 1.8 within 4 a minute of the readings within 1 minute is read with its
//      neighbours (n).
// Every threshold is a planning value; the summaries (pulse while asleep, the lowest 5 minutes) are the reference's.
// Plain Dart, no Flutter: the pass runs it in a background isolate.
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/filters.dart' show Chain, highPass, lowPass, notch;
import '../feedback/features.dart' show median;
import '../sleep/dsp.dart' show Fft;

/// The detector's version: a pulse file of another one is made again.
const String pulseDetector = 'pulse-v1';

/// The planning values (DECISIONS 810-819), the same as analysis/pulse.py.
abstract final class PulseRule {
  static const double epochS = 30;
  static const double highPassHz = 0.5, lowPassHz = 20;
  static final List<double> butterQ = [1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8))];
  static const List<double> notchesHz = [50, 60];
  static const double notchQ = 8;
  static const double segmentS = 8, segmentHopS = 4;
  static const double binHz = 250 / 4096;
  static const double whitenHz = 15 * binHz;
  static const double rateLoHz = 0.7, rateStepHz = 0.005;
  static const int rates = 261;
  static const int harmonics = 4;
  static const double maxMissingS = 1;
  static const double flatUv = 1, railUv = 390000;
  static const double movingUv = 400;
  static const double sureOne = 2.2, surePerDoubling = 0.1;
  static const double stepRateHz = 1.4, halfMax = 1.5;
  static const double strideLoHz = 0.75, strideHiHz = 1.2, oddEvenMin = 0.8;
  static const List<int> sharp = [5, 6, 7, 8];
  static const double sharpMax = 2.5;
  static const int oddEpochs = 3, oddNeighbours = 2;
  static const double oddAgreeBpm = 6, oddBpm = 12;
  static const int nearEpochs = 2;
  static const double nearBpm = 4, nearConf = 1.8;

  /// A night's number needs this many readings asleep (5 minutes).
  static const int minNightReadings = 10;

  /// The lowest 5 minutes: windows of this many epochs with at least [lowMinReadings] readings asleep.
  static const int lowWindow = 10, lowMinReadings = 5;
}

/// Why an epoch has no reading, or that it has one.
abstract final class PulseCode {
  static const String read = 'r', withNeighbours = 'n';
  static const String gap = 'g', noChannel = 'x', moving = 'm', steps = 's', unclear = 'u', oddOne = 'o';
  static bool isRead(String c) => c == read || c == withNeighbours;
}

/// The stages that count as asleep.
const Set<String> asleepStages = {'N1', 'N2', 'N3', 'R'};

/// The smallest power of two whose bins are at most [PulseRule.binHz] wide (4096 at 250 a second).
int pulseNfft(num rate) {
  var n = 1;
  while (rate / n > PulseRule.binHz * (1 + 1e-12)) {
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

/// The odd number of bins nearest to [PulseRule.whitenHz] (15 at 250 a second).
int pulseWhitenBins(num rate) => 2 * _roundEven((PulseRule.whitenHz / (rate / pulseNfft(rate)) - 1) / 2) + 1;

/// The candidate rates (Hz): 0.7, 0.705, ... 2.0.
final Float64List pulseRates = Float64List.fromList([
  for (var k = 0; k < PulseRule.rates; k++) PulseRule.rateLoHz + k * PulseRule.rateStepHz,
]);

/// The confidence a reading needs with [channels] usable channels.
double sureFor(int channels) => PulseRule.sureOne + PulseRule.surePerDoubling * _log2(channels);

/// log2, exact for powers of two (as Python's math.log2).
double _log2(int n) => n > 0 && n & (n - 1) == 0 ? (n.bitLength - 1).toDouble() : math.log(n) / math.ln2;

/// The highest bin read: the highest multiple of the fastest rate the steps check reads, plus one.
int pulseTopBin(num rate) =>
    (PulseRule.sharp.last * (PulseRule.rateLoHz + (PulseRule.rates - 1) * PulseRule.rateStepHz) / (rate / pulseNfft(rate)))
        .floor() +
    2;

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

/// A channel's local peak of the harmonic score: its confidence, the channel and the rate's index.
typedef PulsePeak = ({double conf, int channel, int rate});

/// One 30 s epoch.
class PulseEpoch {
  PulseEpoch(
    this.code, {
    this.bpm = double.nan,
    this.conf = double.nan,
    this.channel = -1,
    this.best = double.nan,
    this.channels = 0,
    this.peaks = const [],
  });

  /// [PulseCode]: r, n a reading; g, x, m, s, u, o why not.
  String code;

  /// A minute; NaN without a reading.
  double bpm;

  /// The reading's confidence; for u, s and o the best channel's; NaN for g, x and m.
  double conf;

  /// The channel read (its index in the recording's channels); -1 without a reading.
  int channel;

  /// The best channel's rate before the neighbours' rules, a minute; NaN for g, x and m.
  final double best;

  /// Usable channels.
  final int channels;

  /// Every channel's local peaks of confidence [PulseRule.nearConf] or more (r and u only).
  final List<PulsePeak> peaks;

  bool get read => PulseCode.isRead(code);
}

/// The epochs of a recording, sample by sample (every channel of its rows, µV): [push] each row, then [finish].
class PulseEpochs {
  PulseEpochs(this.channels, this.rate)
    : size = _roundEven(PulseRule.epochS * rate),
      segment = _roundEven(PulseRule.segmentS * rate),
      hop = _roundEven(PulseRule.segmentHopS * rate),
      nfft = pulseNfft(rate),
      wb = pulseWhitenBins(rate),
      top = pulseTopBin(rate) {
    final lo = math.min(PulseRule.lowPassHz, 0.4 * rate);
    _chains = [
      for (var c = 0; c < channels; c++)
        Chain([
          for (final f in PulseRule.notchesHz)
            if (f < 0.45 * rate) notch(f, PulseRule.notchQ, sampleRate: rate),
          for (final q in PulseRule.butterQ) highPass(PulseRule.highPassHz, q: q, sampleRate: rate),
          for (final q in PulseRule.butterQ) lowPass(lo, q: q, sampleRate: rate),
        ]),
    ];
    _y = [for (var c = 0; c < channels; c++) Float64List(size)];
    _railed = List<bool>.filled(channels, false);
    _bin = rate / nfft;
    _hann = Float64List.fromList([for (var i = 0; i < segment; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / segment)]);
    _fft = Fft(nfft);
    _re = Float64List(nfft);
    _im = Float64List(nfft);
  }

  final int channels;
  final int rate;
  final int size, segment, hop, nfft, wb, top;
  late final List<Chain> _chains;
  late final List<Float64List> _y;
  late final List<bool> _railed;
  late final double _bin;
  late final Float64List _hann;
  late final Fft _fft;
  late final Float64List _re, _im;
  var _at = 0, _missing = 0;
  final List<PulseEpoch> _epochs = [];
  bool _done = false;

  void push(List<double> row, {bool missing = false}) {
    if (missing) _missing++;
    for (var c = 0; c < channels; c++) {
      final v = row[c];
      _y[c][_at] = _chains[c].step(v);
      if (v.abs() >= PulseRule.railUv) _railed[c] = true;
    }
    _at++;
    if (_at == size) {
      _epochs.add(_epoch());
      _at = 0;
      _missing = 0;
      _railed.fillRange(0, channels, false);
    }
  }

  /// The epochs after the neighbours' rules (a last part of an epoch is not one).
  List<PulseEpoch> finish() {
    if (!_done) {
      pulseNeighbours(_epochs);
      _done = true;
    }
    return _epochs;
  }

  PulseEpoch _epoch() {
    if (_missing / rate > PulseRule.maxMissingS) return PulseEpoch(PulseCode.gap);
    final used = <int>[];
    final ranges = <double>[];
    for (var c = 0; c < channels; c++) {
      final y = _y[c];
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var i = 0; i < size; i++) {
        final v = y[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      final rng = hi - lo;
      if (rng < PulseRule.flatUv || _railed[c]) continue;
      used.add(c);
      ranges.add(rng);
    }
    if (used.isEmpty) return PulseEpoch(PulseCode.noChannel);
    if (median(ranges) > PulseRule.movingUv) return PulseEpoch(PulseCode.moving, channels: used.length);
    final spectra = _whitened(used);
    final n = used.length;
    var bestQ = double.nan, bestC = -1, bestI = -1;
    final curves = <(int, Float64List, double)>[];
    for (var u = 0; u < n; u++) {
      final s = _scores(spectra[u]);
      final med = median(s);
      var i = 0;
      for (var k = 1; k < s.length; k++) {
        if (s[k] > s[i]) i = k;
      }
      final q = s[i] / med;
      curves.add((used[u], s, med));
      if (bestC < 0 || q > bestQ) {
        bestQ = q;
        bestC = u;
        bestI = i;
      }
    }
    final q = bestQ, c = used[bestC], i = bestI;
    final bpm = pulseRates[i] * 60;
    List<PulsePeak> peaks() => [
      for (final (cc, s, med) in curves)
        for (var k = 1; k < s.length - 1; k++)
          if (s[k] >= s[k - 1] && s[k] >= s[k + 1] && s[k] / med >= PulseRule.nearConf) (conf: s[k] / med, channel: cc, rate: k),
    ];
    if (q >= sureFor(n) && i > 0 && i < PulseRule.rates - 1) {
      final why = pulseDoubt(spectra[bestC], _bin, pulseRates[i]);
      if (why == PulseCode.steps) return PulseEpoch(PulseCode.steps, conf: q, best: bpm, channels: n);
      if (why == null) return PulseEpoch(PulseCode.read, bpm: bpm, conf: q, channel: c, best: bpm, channels: n, peaks: peaks());
    }
    return PulseEpoch(PulseCode.unclear, conf: q, best: bpm, channels: n, peaks: peaks());
  }

  /// Bins 0..[top] of each used channel's whitened Welch spectrum; two channels share one complex transform (the
  /// first in the real part, the second in the imaginary part).
  List<Float64List> _whitened(List<int> used) {
    final p = [for (final _ in used) Float64List(nfft ~/ 2 + 1)];
    for (var u = 0; u < used.length; u += 2) {
      final a = used[u], b = u + 1 < used.length ? used[u + 1] : -1;
      for (var s = 0; s + segment <= size; s += hop) {
        _re.fillRange(0, nfft, 0);
        _im.fillRange(0, nfft, 0);
        _load(_y[a], s, _re);
        if (b >= 0) _load(_y[b], s, _im);
        _fft.transform(_re, _im);
        final pa = p[u];
        for (var k = 0; k <= top; k++) {
          final j = k == 0 ? 0 : nfft - k;
          final xr = (_re[k] + _re[j]) / 2, xi = (_im[k] - _im[j]) / 2;
          pa[k] += xr * xr + xi * xi;
        }
        if (b >= 0) {
          final pb = p[u + 1];
          for (var k = 0; k <= top; k++) {
            final j = k == 0 ? 0 : nfft - k;
            final yr = (_im[k] + _im[j]) / 2, yi = -(_re[k] - _re[j]) / 2;
            pb[k] += yr * yr + yi * yi;
          }
        }
      }
    }
    final half = wb ~/ 2;
    return [
      for (final pc in p)
        () {
          final w = Float64List(top + 1);
          for (var k = 0; k <= top; k++) {
            var sum = 0.0;
            for (var j = math.max(0, k - half); j <= k + half; j++) {
              sum += pc[j];
            }
            w[k] = pc[k] / (sum / wb);
          }
          return w;
        }(),
    ];
  }

  /// [segment] samples of [y] from [from], their mean removed and the Hann window on, into [out] (zero-padded).
  void _load(Float64List y, int from, Float64List out) {
    var sum = 0.0;
    for (var i = 0; i < segment; i++) {
      sum += y[from + i];
    }
    final mean = sum / segment;
    for (var i = 0; i < segment; i++) {
      out[i] = (y[from + i] - mean) * _hann[i];
    }
  }

  /// The harmonic score of every candidate rate: the mean of the whitened power at f0, 2 f0, ... harmonics x f0.
  Float64List _scores(Float64List w) {
    final out = Float64List(PulseRule.rates);
    for (var i = 0; i < PulseRule.rates; i++) {
      final f = pulseRates[i];
      var acc = _interp(f, _bin, w);
      for (var k = 2; k <= PulseRule.harmonics; k++) {
        acc = acc + _interp(k * f, _bin, w);
      }
      out[i] = acc / PulseRule.harmonics;
    }
    return out;
  }
}

/// Why a strong rhythm at [f0] (Hz) in the whitened spectrum [w] (bins [bin] wide) is no pulse reading: [PulseCode.steps]
/// it looks like steps, [PulseCode.unclear] it may be twice a rhythm slower than the range; null: it is a reading.
String? pulseDoubt(Float64List w, double bin, double f0) {
  if ((_interp(0.5 * f0, bin, w) + _interp(1.5 * f0, bin, w)) / 2 >= PulseRule.halfMax) {
    return f0 >= PulseRule.stepRateHz ? PulseCode.steps : PulseCode.unclear;
  }
  if (f0 >= PulseRule.strideLoHz && f0 <= PulseRule.strideHiHz) {
    final odd = _interp(f0, bin, w) + _interp(3 * f0, bin, w);
    final even = _interp(2 * f0, bin, w) + _interp(4 * f0, bin, w);
    if (odd < PulseRule.oddEvenMin * even) return PulseCode.steps;
  }
  var sharp = 0.0;
  for (final k in PulseRule.sharp) {
    sharp += _interp(k * f0, bin, w);
  }
  return sharp / PulseRule.sharp.length >= PulseRule.sharpMax ? PulseCode.steps : null;
}

/// The neighbours' rules, in place: the odd one out, then readings with their neighbours (see the top of the file).
void pulseNeighbours(List<PulseEpoch> eps) {
  final strong = <int, double>{
    for (var e = 0; e < eps.length; e++)
      if (eps[e].code == PulseCode.read) e: eps[e].bpm,
  };
  for (final MapEntry(key: e, value: b) in strong.entries) {
    final nb = [
      for (var j = e - PulseRule.oddEpochs; j <= e + PulseRule.oddEpochs; j++)
        if (j != e && strong.containsKey(j)) strong[j]!,
    ];
    if (nb.length >= PulseRule.oddNeighbours &&
        nb.reduce(math.max) - nb.reduce(math.min) <= PulseRule.oddAgreeBpm &&
        (b - median(nb)).abs() >= PulseRule.oddBpm) {
      eps[e]
        ..code = PulseCode.oddOne
        ..bpm = double.nan
        ..channel = -1;
    }
  }
  final accepted = <int, double>{
    for (var e = 0; e < eps.length; e++)
      if (eps[e].code == PulseCode.read) e: eps[e].bpm,
  };
  for (var e = 0; e < eps.length; e++) {
    final ep = eps[e];
    if (ep.code != PulseCode.unclear && ep.code != PulseCode.oddOne) continue;
    final nb = [
      for (var j = e - PulseRule.nearEpochs; j <= e + PulseRule.nearEpochs; j++)
        if (j != e && accepted.containsKey(j)) accepted[j]!,
    ];
    if (nb.isEmpty) continue;
    final target = median(nb);
    PulsePeak? found;
    for (final p in ep.peaks) {
      if ((pulseRates[p.rate] * 60 - target).abs() <= PulseRule.nearBpm && (found == null || p.conf > found.conf)) found = p;
    }
    if (found != null) {
      ep
        ..code = PulseCode.withNeighbours
        ..bpm = pulseRates[found.rate] * 60
        ..conf = found.conf
        ..channel = found.channel;
    }
  }
}

/// The share of epochs with a reading.
double pulseCoverage(List<PulseEpoch> eps) => eps.isEmpty ? 0 : eps.where((e) => e.read).length / eps.length;

/// The readings of a pass whose epochs start at [startMs] (unix ms), on another clock of [n] epochs from [atMs] (a
/// sleep report's): each reading goes to the epoch holding its middle.
List<double?> pulseAligned(int startMs, List<double?> bpm, int atMs, int n, {double epochS = PulseRule.epochS}) {
  final out = List<double?>.filled(n, null);
  for (var j = 0; j < bpm.length; j++) {
    final b = bpm[j];
    if (b == null || b.isNaN) continue;
    final e = ((startMs / 1000 + j * epochS + epochS / 2 - atMs / 1000) / epochS).floor();
    if (e >= 0 && e < n) out[e] = b;
  }
  return out;
}

/// Pulse while asleep: the asleep epochs, those with a reading, the readings' median (from
/// [PulseRule.minNightReadings]) and the lowest 5 minutes.
class PulseAsleep {
  const PulseAsleep({required this.epochs, required this.read, this.median, this.lowest});
  final int epochs, read;
  final double? median, lowest;
  double get share => epochs == 0 ? 0 : read / epochs;
}

/// Pulse while asleep from [bpm] aligned with [stages] ([pulseAligned]).
PulseAsleep pulseAsleep(List<double?> bpm, List<String> stages) {
  final n = math.min(bpm.length, stages.length);
  final vals = [for (var i = 0; i < n; i++) asleepStages.contains(stages[i]) ? bpm[i] : null];
  final read = [for (final v in vals) ?v];
  double? lowest;
  for (var a = 0; a + PulseRule.lowWindow <= n; a++) {
    final w = [for (var i = a; i < a + PulseRule.lowWindow; i++) ?vals[i]];
    if (w.length >= PulseRule.lowMinReadings) {
      final m = median(w);
      lowest = lowest == null ? m : math.min(lowest, m);
    }
  }
  return PulseAsleep(
    epochs: [for (var i = 0; i < n; i++) if (asleepStages.contains(stages[i])) i].length,
    read: read.length,
    median: read.length >= PulseRule.minNightReadings ? median(read) : null,
    lowest: lowest,
  );
}
