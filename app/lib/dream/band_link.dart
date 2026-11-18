// The headband connection of a session run from the app's screen (the dream catcher; DECISIONS row 110), on the
// meditation's rules (row 76) at a 45-minute scale: contact checked once at the start, no SDK call on a headband
// that went out of range, reconnect straight to the same headband after 2, 5, 10 s and then every 10 s with a scan
// every third try, the stream restarted once if nothing arrives in 8 s, every SDK call with a deadline.
// It hands every batch over as it arrived; finding holes in the signal is the session's job.
// (The meditation controller still has its own copy of these rules; moving it onto this class is a later cleanup.)
import 'dart:async';
import 'dart:math' as math;

import '../feedback/features.dart' show channelNames;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';

class LinkTiming {
  const LinkTiming({
    this.scanFor = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 45),
    this.sdkTimeout = const Duration(seconds: 15),
    this.contactFor = const Duration(seconds: 6),
    this.settle = const Duration(seconds: 1),
    this.restartStreamAfter = const Duration(seconds: 8),
    this.reconnectWaits = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)],
    this.rescanFor = const Duration(seconds: 10),
  });

  final Duration scanFor;
  final Duration connectTimeout;
  final Duration sdkTimeout;
  final Duration contactFor;
  final Duration settle;
  final Duration restartStreamAfter;

  /// Waits before reconnect tries; the last one repeats. Every third try is a scan of [rescanFor].
  final List<Duration> reconnectWaits;
  final Duration rescanFor;
}

enum LinkEvent { drop, reconnectTry, reconnected, streamRestarted }

class BandLink {
  BandLink({required this.finder, this.timing = const LinkTiming(), required this.onBatch, this.onEvent, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final LinkTiming timing;

  /// Every batch as it arrived (volts, as the SDK gives them).
  final void Function(DateTime arrival, List<Sample> batch) onBatch;

  /// Drops, reconnect tries and restarts, with a plain line for the log.
  final void Function(LinkEvent event, String line)? onEvent;
  final DateTime Function() _now;

  Headband? _band;
  final List<Headband> _lostBands = [];
  StreamSubscription<List<Sample>>? _signalSub;
  StreamSubscription<bool>? _rangeSub;
  DateTime? _signalAt;
  bool _restarted = false;
  bool _closed = false;

  /// The headband is out of range now; the link is reconnecting.
  bool lost = false;

  /// When the last batch arrived (null before the first).
  DateTime? lastData;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _lostBands.isNotEmpty;
  String get name => _band?.name ?? '';

  Future<T> _sdk<T>(Future<T> call, String what) =>
      call.timeout(timing.sdkTimeout, onTimeout: () => throw TimeoutException(what, timing.sdkTimeout));

  /// Scans and connects; false when no headband was found. [onFound] fires between the scan and the connection.
  Future<bool> connect({void Function(String name)? onFound}) async {
    final band = await finder
        .find(timing.scanFor, onFound: (name, _) => onFound?.call(name))
        .timeout(timing.scanFor + timing.connectTimeout);
    if (band == null) return false;
    _band = band;
    if (_closed) {
      await close();
      return false;
    }
    _rangeSub = band.rangeChanges.listen(_onRange);
    return true;
  }

  /// The headband's resistance for [LinkTiming.contactFor]: ohms per channel, null where it has none (infinite),
  /// channels it did not report left out.
  Future<Map<String, double?>> contact() async {
    final band = _band;
    if (band == null) return const {};
    final readings = <Map<String, double>>[];
    final sub = band.resistance.listen(readings.add);
    try {
      await _sdk(band.startResist(), 'contact check');
      await Future<void>.delayed(timing.contactFor);
      await _sdk(band.stopResist(), 'contact check end');
    } finally {
      await sub.cancel();
    }
    await Future<void>.delayed(timing.settle);
    if (readings.isEmpty) return const {};
    final last = readings.last;
    return {
      for (final n in channelNames)
        if (last.containsKey(n)) n: last[n]!.isFinite && !last[n]!.isNaN ? last[n] : null,
    };
  }

  Future<void> startSignal() async {
    final band = _band;
    if (band == null) return;
    _signalSub = band.signal.listen(_onSignal);
    await _sdk(band.startSignal(), 'start signal');
    _signalAt = _now();
  }

  void _onSignal(List<Sample> batch) {
    if (_closed || batch.isEmpty) return;
    final now = _now();
    lastData = now;
    onBatch(now, batch);
  }

  /// Call about every second: restarts the stream once when nothing has arrived since it started.
  void tick() {
    final at = _signalAt;
    if (_closed || lost || _restarted || lastData != null || at == null) return;
    if (_now().difference(at) < timing.restartStreamAfter) return;
    _restarted = true;
    unawaited(_restartStream());
  }

  Future<void> _restartStream() async {
    final band = _band;
    if (band == null) return;
    onEvent?.call(LinkEvent.streamRestarted, 'no data since the start: stream restarted');
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      await _sdk(band.startSignal(), 'start signal');
    } catch (_) {}
  }

  void _onRange(bool inRange) {
    if (inRange || lost || _closed) return;
    lost = true;
    onEvent?.call(LinkEvent.drop, 'drop (out of range); reconnecting');
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    final old = _band!;
    _lostBands.add(old); // no SDK call goes near a headband that is out of range
    await _signalSub?.cancel();
    await _rangeSub?.cancel();
    _signalSub = null;
    _rangeSub = null;
    _band = null;
    for (var tries = 1; !_closed; tries++) {
      await Future<void>.delayed(timing.reconnectWaits[math.min(tries - 1, timing.reconnectWaits.length - 1)]);
      if (_closed) return;
      final scan = tries % 3 == 0;
      Headband? band;
      try {
        band = scan
            ? await finder.find(timing.rescanFor).timeout(timing.rescanFor + timing.connectTimeout)
            : await finder.connectDirect(old.id).timeout(timing.connectTimeout);
      } catch (_) {
        band = null;
      }
      onEvent?.call(LinkEvent.reconnectTry, 'reconnect try $tries (${scan ? 'scan' : 'direct'}): ${band == null ? 'failed' : 'connected'}');
      if (band == null) continue;
      _band = band;
      if (_closed) return _release();
      _rangeSub = band.rangeChanges.listen(_onRange);
      _signalSub = band.signal.listen(_onSignal);
      try {
        await _sdk(band.startSignal(), 'start signal');
        lost = false;
        onEvent?.call(LinkEvent.reconnected, 'reconnected');
        return;
      } catch (_) {
        continue;
      }
    }
  }

  /// Stops the signal and lets the headband go (only one still in range; a lost one is never touched).
  Future<void> close() async {
    _closed = true;
    await _release();
  }

  Future<void> _release() async {
    await _signalSub?.cancel();
    await _rangeSub?.cancel();
    _signalSub = null;
    _rangeSub = null;
    final band = _band;
    _band = null;
    if (band == null || lost) return;
    try {
      await _sdk(band.stopSignal(), 'stop signal');
    } catch (_) {}
    try {
      await _sdk(band.disconnectAndDispose(), 'disconnect');
    } catch (_) {}
  }
}
