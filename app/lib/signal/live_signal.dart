// What the Signal view keeps of the live signal, for any number of channels (DECISIONS 594): the last 5 minutes of
// every channel as it arrived (µV), its arrival times and packet numbers, the last 10 seconds through each display
// filter, and per channel the numbers worked out from the last seconds (RMS, mains, flat, railed, swings, the bands).
// It only reads what it is handed; nothing here touches a headband. The filters are the shared detectors' biquads
// (detectors/filters.dart) and their quality limits (detectors.dart `Quality`).
import 'dart:math' as math;
import 'dart:typed_data';

import '../detectors/detectors.dart' show Quality;
import '../detectors/filters.dart';
import '../feedback/features.dart' show spectrum;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/packets.dart';

/// Samples a second, every device so far (the BrainBit, the DIY board's ADS1299 at its default).
const int liveRate = 250;

/// One batch: [values] channel by channel per sample (sample 0's channels, then sample 1's ...) in microvolts.
class LiveBatch {
  LiveBatch({required this.arrival, required this.values, required this.channels, this.packs, this.first, this.run})
    : assert(channels > 0 && values.length % channels == 0);

  final DateTime arrival;
  final Float32List values;
  final int channels;

  /// The device's packet numbers, one a sample, when it numbers them.
  final Int32List? packs;

  /// The index of the first sample in its run (a night's file set), when known.
  final int? first;

  /// The night's file set ('2026-11-20-231200'), when known.
  final String? run;

  int get length => values.length ~/ channels;

  /// The app's sample record: its channels in volts, as many as the device sends (the BrainBit's O1 O2 T3 T4, the
  /// DIY board's CH1..; DECISIONS 630-639). [batch] is not empty.
  static LiveBatch fromSamples(DateTime arrival, List<Sample> batch, {int? first, String? run}) {
    final n = batch.first.volts.length;
    final v = Float32List(batch.length * n);
    final p = Int32List(batch.length);
    for (var i = 0; i < batch.length; i++) {
      final s = batch[i];
      final x = s.volts;
      for (var c = 0; c < n && c < x.length; c++) {
        v[n * i + c] = x[c] * 1e6;
      }
      p[i] = s.pack;
    }
    return LiveBatch(arrival: arrival, values: v, channels: n, packs: p, first: first, run: run);
  }
}

/// What a trace shows: the signal as it came, 1-40 Hz (with the 50 Hz notch), or only the 50 Hz notch.
enum TraceFilter { raw, band, notch }

/// One channel's numbers over the last seconds; null where there is not enough signal yet.
class ChannelNumbers {
  const ChannelNumbers({
    this.rmsUv,
    this.lineUv,
    this.swingUv,
    this.flat = false,
    this.railed = false,
    this.swinging = false,
    this.bands,
    this.latestUv,
  });

  /// RMS of the 1-40 Hz signal over the last 2 s.
  final double? rmsUv;

  /// RMS of the mains (45-55 Hz) over the last 2 s.
  final double? lineUv;

  /// Peak to peak of the signal above 2 Hz over the last second (the detectors' quality range).
  final double? swingUv;

  /// The last second moved less than [Quality.flatUv] (no contact, or a dead channel).
  final bool flat;

  /// The last second reached [Quality.railUv] (the amplifier's limit).
  final bool railed;

  /// Swings over [Quality.extremeUv] in the last second (movement, a loose electrode).
  final bool swinging;

  /// Shares of 1-30 Hz power in delta, theta, alpha and beta over the last 2 s (they add up to 1).
  final List<double>? bands;
  final double? latestUv;
}

/// The bands of the strip: delta 1-4, theta 4-8, alpha 8-13, beta 13-30 Hz.
const List<(String, double, double)> liveBands = [('δ', 1, 4), ('θ', 4, 8), ('α', 8, 13), ('β', 13, 30)];

/// A ring of the last [capacity] values of a stream; index i is the stream's i-th value.
class _Ring {
  _Ring(int capacity) : _a = Float32List(capacity);
  final Float32List _a;
  int n = 0;

  int get capacity => _a.length;
  int get oldest => math.max(0, n - _a.length);

  void push(double v) {
    _a[n % _a.length] = v;
    n++;
  }

  double at(int i) => _a[i % _a.length];

  /// Values from [from] (inclusive) to [to] (exclusive), clipped to what is kept.
  Float32List range(int from, int to) {
    final a = math.max(from, oldest), b = math.min(to, n);
    final out = Float32List(math.max(0, b - a));
    for (var i = a; i < b; i++) {
      out[i - a] = _a[i % _a.length];
    }
    return out;
  }
}

class _Channel {
  _Channel(int keep, int trace)
    : raw = _Ring(keep),
      band = _Ring(trace),
      notched = _Ring(trace),
      line = _Ring(2 * liveRate),
      swing = _Ring(liveRate);

  final _Ring raw, band, notched, line, swing;
  final Chain bandChain = Chain([highPass(1), notch(50, 8), lowPass(40), lowPass(40)]);
  final Chain notchChain = Chain([notch(50, 8)]);
  final Chain lineChain = Chain([bandPass(50, 5)]);
  final Chain swingChain = Chain([highPass(Quality.qualityHpHz)]);

  void push(double uv) {
    raw.push(uv);
    band.push(bandChain.step(uv));
    notched.push(notchChain.step(uv));
    line.push(lineChain.step(uv));
    swing.push(swingChain.step(uv));
  }
}

/// The live signal of one device: N channels at [rate].
class LiveSignal {
  LiveSignal({required this.names, this.rate = liveRate, int keepSeconds = 300, int traceSeconds = 10})
    : _ch = [for (final _ in names) _Channel(keepSeconds * rate, traceSeconds * rate)],
      _times = Float64List(keepSeconds * rate),
      _packs = Int32List(keepSeconds * rate),
      traceSeconds = traceSeconds;

  final List<String> names;
  final int rate;

  /// How far back the filtered traces go.
  final int traceSeconds;
  final List<_Channel> _ch;
  final Float64List _times;
  final Int32List _packs;
  final PacketAccount _account = PacketAccount();
  String? _run;
  int? _nextFirst;
  int _runs = 0;
  bool _fresh = true;
  bool _hasPacks = false;
  final Map<int, ({int at, ChannelNumbers numbers})> _numbers = {};

  int get channels => names.length;

  /// Samples taken since this view opened (every channel has as many).
  int get count => _ch.isEmpty ? 0 : _ch.first.raw.n;

  /// The oldest sample still kept.
  int get oldest => _ch.isEmpty ? 0 : _ch.first.raw.oldest;

  /// Samples a ring keeps (5 minutes).
  int get keep => _times.length;

  /// Missing and repeated packet numbers so far (BrainBit's 11-bit numbers, the board's sequence).
  PacketCounts get packets => _account.counts;
  bool get numbered => _hasPacks;

  /// Stretches of signal seen: a new one after every drop of a night, a reconnect or a return to the view.
  int get runs => _runs;
  String? get run => _run;

  /// The next batch starts a new stretch (a new connection, or the view came back): its packet numbers are not
  /// compared with the ones before.
  void newRun() {
    _fresh = true;
    _nextFirst = null;
  }

  /// Takes one batch; a batch with another channel count is refused (false).
  bool add(LiveBatch b) {
    if (b.channels != channels || b.length == 0) return false;
    final changed =
        (b.run != null && _run != null && b.run != _run) ||
        (b.first != null && _nextFirst != null && b.first != _nextFirst);
    if (changed || _fresh) {
      _runs++;
      _fresh = false;
      _account.startRun();
    }
    _run = b.run ?? _run;
    if (b.first != null) _nextFirst = b.first! + b.length;
    final packs = b.packs;
    if (packs != null) {
      _hasPacks = true;
      _account.add([for (final p in packs) Sample.four(pack: p, o1: 0.0, o2: 0.0, t3: 0.0, t4: 0.0)]);
    }
    final n = b.length, end = b.arrival.millisecondsSinceEpoch.toDouble();
    for (var i = 0; i < n; i++) {
      final k = count;
      _times[k % _times.length] = end - (n - 1 - i) * 1000 / rate;
      _packs[k % _packs.length] = packs == null ? k : packs[i];
      for (var c = 0; c < channels; c++) {
        _ch[c].push(b.values[i * channels + c]);
      }
    }
    return true;
  }

  /// When sample [i] arrived (ms since the epoch; within a batch spread back at the sample rate).
  double timeOf(int i) => _times[i % _times.length];

  /// Packet number of sample [i] (its index when the device sends none).
  int packOf(int i) => _packs[i % _packs.length];

  /// The newest value of channel [c] as it came, µV.
  double? latest(int c) => count == 0 ? null : _ch[c].raw.at(count - 1);

  /// Channel [c] through [filter], the [samples] values before [end] (default: the newest). Raw goes back 5 minutes;
  /// the filtered traces [traceSeconds].
  Float32List window(int c, TraceFilter filter, int samples, {int? end}) {
    final e = end ?? count;
    final ring = switch (filter) {
      TraceFilter.raw => _ch[c].raw,
      TraceFilter.band => _ch[c].band,
      TraceFilter.notch => _ch[c].notched,
    };
    return ring.range(e - samples, e);
  }

  /// Samples a second by the arrival times over the last 10 s (null before 2 s of signal).
  double? measuredRate() {
    final n = count;
    if (n < 2 * rate) return null;
    final back = math.min(n - oldest - 1, 10 * rate);
    final dt = timeOf(n - 1) - timeOf(n - 1 - back);
    return dt <= 0 ? null : back * 1000 / dt;
  }

  /// Channel [c]'s numbers, worked out at most every quarter second.
  ChannelNumbers numbers(int c) {
    final n = count;
    final cached = _numbers[c];
    if (cached != null && n - cached.at < rate ~/ 4) return cached.numbers;
    final out = _work(c);
    _numbers[c] = (at: n, numbers: out);
    return out;
  }

  ChannelNumbers _work(int c) {
    final ch = _ch[c];
    final n = count;
    if (n < rate) return ChannelNumbers(latestUv: latest(c));
    final second = ch.raw.range(n - rate, n);
    var lo = double.infinity, hi = double.negativeInfinity, top = 0.0;
    for (final v in second) {
      lo = math.min(lo, v);
      hi = math.max(hi, v);
      top = math.max(top, v.abs());
    }
    final swing = _p2p(ch.swing.range(n - rate, n));
    final two = math.min(2 * rate, n);
    final band = ch.band.range(n - two, n);
    final bands = n >= 2 * rate ? bandShares(band, rate) : null;
    return ChannelNumbers(
      rmsUv: _rms(band),
      lineUv: _rms(ch.line.range(n - two, n)),
      swingUv: swing,
      flat: hi - lo < Quality.flatUv,
      railed: top >= Quality.railUv,
      swinging: swing > Quality.extremeUv,
      bands: bands,
      latestUv: latest(c),
    );
  }
}

double _p2p(Float32List x) {
  if (x.isEmpty) return 0;
  var lo = x.first, hi = x.first;
  for (final v in x) {
    lo = math.min(lo, v);
    hi = math.max(hi, v);
  }
  return hi - lo;
}

/// Root mean square around the mean.
double _rms(Float32List x) {
  if (x.isEmpty) return 0;
  var mean = 0.0;
  for (final v in x) {
    mean += v;
  }
  mean /= x.length;
  var s = 0.0;
  for (final v in x) {
    s += (v - mean) * (v - mean);
  }
  return math.sqrt(s / x.length);
}

/// Shares of [liveBands] in the power of [x] (the shared Goertzel spectrum, 0.5 Hz steps); null for a flat signal.
List<double>? bandShares(Float32List x, int rate) {
  if (x.length < rate) return null;
  final spec = spectrum(x, rate, 1, 30, 0.5);
  final sums = List<double>.filled(liveBands.length, 0);
  for (var i = 0; i < spec.f.length; i++) {
    final f = spec.f[i];
    for (var b = 0; b < liveBands.length; b++) {
      final (_, lo, hi) = liveBands[b];
      // each step counted once: [lo, hi), the last band up to its top
      if (f >= lo && (f < hi || (b == liveBands.length - 1 && f <= hi))) sums[b] += spec.p[i];
    }
  }
  final total = sums.fold(0.0, (a, b) => a + b);
  if (!(total > 0) || !total.isFinite) return null;
  return [for (final s in sums) s / total];
}

/// A symmetric scale (±µV) that fits [x] around its mean: the next of 10, 20, 50, 100, 200, 500 ... above its largest
/// excursion.
double autoScaleUv(Float32List x) {
  if (x.isEmpty) return 50;
  var mean = 0.0;
  for (final v in x) {
    mean += v;
  }
  mean /= x.length;
  var top = 0.0;
  for (final v in x) {
    top = math.max(top, (v - mean).abs());
  }
  var step = 10.0;
  for (var k = 0; step < top * 1.05 && k < 40; k++) {
    step *= k % 3 == 1 ? 2.5 : 2; // 10 20 50 100 200 500 ...
  }
  return step;
}
