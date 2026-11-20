// The worn check of automatic recording (DECISIONS 601): Bluetooth presence is not "worn" (BrainBit has no off switch
// and advertises for weeks in standby), so a check connects, reads contact for about 6 s and the battery, and lets go,
// unless the app is about to ask: then it keeps the headband streaming into memory until the answer (preroll.dart).
// Contact is judged per channel by name, so any headband or helmet layout works; a board without contact readings
// (the DIY helmet must never use the ADS1299's lead-off currents on a person) is judged from 20 s of its signal
// instead: flat, railed or wild channels are not on skin.
import 'dart:async';
import 'dart:math' as math;

import '../detectors/detectors.dart' show Quality;
import '../dream/band_link.dart' show BandLink;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';

/// What one check found.
class ProbeResult {
  const ProbeResult({
    required this.near,
    this.worn,
    this.how = 'none',
    this.ohms = const {},
    this.battery,
    this.name,
    this.error,
  });

  /// A headband answered.
  final bool near;

  /// On the head; null when it could not be told (no contact reading and no signal).
  final bool? worn;

  /// `resistance`, `signal` or `none`.
  final String how;

  /// Ohms per channel (null: no contact, infinite); empty without a reading.
  final Map<String, double?> ohms;

  /// The headband's battery in percent; null when not read.
  final int? battery;
  final String? name;
  final String? error;

  ProbeResult withBattery(int? pct) =>
      ProbeResult(near: near, worn: worn, how: how, ohms: ohms, battery: pct, name: name, error: error);

  Map<String, Object?> toLog() => {
    'near': near,
    'worn': worn,
    'how': how,
    if (ohms.isNotEmpty) 'ohms': {for (final e in ohms.entries) e.key: e.value?.round()},
    'battery': battery,
    if (error != null) 'error': error,
  };
}

/// Planning values of the worn check (labelled assumptions, DECISIONS 601; the owner's phone tells the real numbers).
abstract final class WornRule {
  /// A channel reading at or below this is taken as touching skin. Off the head the owner's BrainBit read infinite;
  /// on the head the night recorder calls up to 2.5 MΩ "fair".
  static const double maxOhms = 10e6;

  /// Contact is read this long (the night recorder's and the sessions' check).
  static const Duration contactFor = Duration(seconds: 6);

  /// A board without contact readings: this much signal is judged.
  static const Duration signalFor = Duration(seconds: 20);

  /// The search for the headband.
  static const Duration scanFor = Duration(seconds: 12);
}

/// On the head when at least half the channels (at least one) read a finite resistance up to [WornRule.maxOhms];
/// null when there is no reading at all.
bool? wornFromOhms(Map<String, double?> ohms) {
  if (ohms.isEmpty) return null;
  final on = ohms.values.where((v) => v != null && v.isFinite && v >= 0 && v <= WornRule.maxOhms).length;
  return on >= math.max(1, (ohms.length / 2).ceil());
}

/// On the head when at least half the channels (at least one) look like skin over [fs] Hz samples in µV: not flat
/// (under the detectors' 1.4 µV after removing each second's mean), not railed, not wild (over 500 µV). Null with
/// under 10 s of signal.
bool? wornFromSignal(Map<String, List<double>> microvolts, {double fs = 250}) {
  final n = fs.round();
  final usable = microvolts.values.where((x) => x.length >= 10 * n).toList();
  if (usable.isEmpty) return null;
  var on = 0;
  for (final x in usable) {
    if (x.any((v) => v.abs() >= Quality.railUv || v.isNaN)) continue;
    var sum = 0.0;
    var count = 0;
    for (var s = 0; s + n <= x.length; s += n) {
      var mean = 0.0;
      for (var i = s; i < s + n; i++) {
        mean += x[i];
      }
      mean /= n;
      for (var i = s; i < s + n; i++) {
        sum += (x[i] - mean) * (x[i] - mean);
      }
      count += n;
    }
    final sd = math.sqrt(sum / count);
    if (sd >= Quality.flatUv && sd <= Quality.extremeUv) on++;
  }
  return on >= math.max(1, (usable.length / 2).ceil());
}

/// The check, as the watcher sees it (a fake in tests, a simulated headband in the debug build's smoke test).
abstract class HeadbandCheck {
  /// Finds the headband, reads contact and the battery. With [keepIfWorn] and a headband on the head, it is kept
  /// streaming into [onBatch] until [release]; otherwise it is let go before this returns.
  Future<ProbeResult> check({required bool keepIfWorn, required void Function(DateTime, List<Sample>) onBatch});

  /// Lets go of a kept headband (harmless when none is kept).
  Future<void> release();

  bool get holding;
}

/// The check through the app's own finder (BrainBit's SDK, or our own connection when its switch is on).
class BandCheck implements HeadbandCheck {
  BandCheck(this.finder, {this.sdkTimeout = const Duration(seconds: 15), DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final Duration sdkTimeout;
  final DateTime Function() _now;
  Headband? _held;
  StreamSubscription<List<Sample>>? _sub;
  bool _released = false;

  /// Completes on [release]: the check's waits (the contact reading, the signal) end at once.
  Completer<void> _cut = Completer<void>();

  Future<void> _pause(Duration d) => Future.any([Future<void>.delayed(d), _cut.future]);

  @override
  bool get holding => _held != null;

  Future<T> _sdk<T>(Future<T> f, String what) =>
      f.timeout(sdkTimeout, onTimeout: () => throw TimeoutException(what, sdkTimeout));

  @override
  Future<ProbeResult> check({required bool keepIfWorn, required void Function(DateTime, List<Sample>) onBatch}) async {
    _released = false;
    _cut = Completer<void>();
    Headband? band;
    try {
      band = await BandLink.within(
        finder.find(WornRule.scanFor),
        WornRule.scanFor + const Duration(seconds: 45),
        sdkTimeout: sdkTimeout,
        what: 'search',
      );
    } catch (e) {
      return ProbeResult(near: false, error: '$e');
    }
    if (band == null) return const ProbeResult(near: false);
    var result = ProbeResult(near: true, name: band.name);
    var streaming = false;
    try {
      int? battery;
      try {
        battery = await _sdk(band.battery(), 'battery');
      } catch (_) {
        battery = null;
      }
      // released (a start by hand, a session, the Signal tab): no further step, the headband is let go below
      final ohms = band is OtherBoard || _released ? const <String, double?>{} : await _contact(band);
      if (ohms.isNotEmpty) {
        result = ProbeResult(near: true, worn: wornFromOhms(ohms), how: 'resistance', ohms: ohms, battery: battery, name: band.name);
      } else if (_released) {
        result = ProbeResult(near: true, battery: battery, name: band.name, error: 'let go: a start by hand');
      } else {
        streaming = true;
        final worn = await _signalJudge(band);
        result = ProbeResult(near: true, worn: worn, how: worn == null ? 'none' : 'signal', battery: battery, name: band.name);
      }
      if (keepIfWorn && result.worn == true && !_released) {
        _held = band;
        _sub = band.signal.listen((rows) => onBatch(_now(), rows));
        if (!streaming) await _sdk(band.startSignal(), 'start signal');
        return result;
      }
    } catch (e) {
      result = ProbeResult(
        near: true,
        worn: result.worn,
        how: result.how,
        ohms: result.ohms,
        battery: result.battery,
        name: band.name,
        error: '$e',
      );
    }
    await _sub?.cancel();
    _sub = null;
    _held = null;
    await BandLink.letGo(band, sdkTimeout, streaming: streaming);
    return result;
  }

  /// The last resistance reading after [WornRule.contactFor]; empty when none arrived.
  Future<Map<String, double?>> _contact(Headband band) async {
    final last = <String, double>{};
    final sub = band.resistance.listen(last.addAll);
    try {
      await _sdk(band.startResist(), 'contact check');
      await _pause(WornRule.contactFor);
      await _sdk(band.stopResist(), 'contact check end');
    } catch (_) {
      // no contact on this route: the signal decides
    } finally {
      await sub.cancel();
    }
    if (_released) return const {}; // not judged: the headband is let go at once
    await _pause(const Duration(seconds: 1)); // the stream starts cleanly after a check
    return {for (final e in last.entries) e.key: e.value.isFinite && !e.value.isNaN ? e.value : null};
  }

  /// 20 s of signal, judged per channel (O1 O2 T3 T4 for a BrainBit). The stream stays on for a kept headband.
  Future<bool?> _signalJudge(Headband band) async {
    final ch = <String, List<double>>{'O1': [], 'O2': [], 'T3': [], 'T4': []};
    final sub = band.signal.listen((rows) {
      for (final r in rows) {
        ch['O1']!.add(r.o1 * 1e6);
        ch['O2']!.add(r.o2 * 1e6);
        ch['T3']!.add(r.t3 * 1e6);
        ch['T4']!.add(r.t4 * 1e6);
      }
    });
    try {
      await _sdk(band.startSignal(), 'start signal');
      await _pause(WornRule.signalFor);
    } finally {
      await sub.cancel();
    }
    return wornFromSignal(ch);
  }

  @override
  Future<void> release() async {
    _released = true;
    if (!_cut.isCompleted) _cut.complete();
    final band = _held;
    _held = null;
    await _sub?.cancel();
    _sub = null;
    if (band != null) await BandLink.letGo(band, sdkTimeout, streaming: true);
  }
}
