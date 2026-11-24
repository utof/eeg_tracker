// The headband connection of a session run from the app's screen (the dream catcher; DECISIONS row 110), on the
// meditation's rules (row 76) at a 45-minute scale: contact checked once at the start, no SDK call on a headband
// that went out of range, reconnect straight to the same headband after 2, 5, 10 s and then every 10 s with a scan
// every third try, every SDK call with a deadline. A stream that stops while the headband stays in range (or never
// starts) is mended on the night recorder's rule (DECISIONS 49, 520): no data for 8 s, the stream is restarted once;
// still none 40 s after the last batch, the headband is let go and reached again as after a drop.
// It hands every batch over as it arrived; finding holes in the signal is the session's job.
// Used by the dream catcher, sound for states, the nap coach, the hands-free calibration, and the meditation and
// alpha-theta sessions (DECISIONS 270): the reconnect rules live here and nowhere else.
// Every headband it reaches is either the session's or let go: one reached after Stop, after a deadline, or by a
// reconnect whose stream did not start is disconnected at once (DECISIONS 451).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../feedback/features.dart' show channelNames;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';
import '../signal/live_tap.dart';

class LinkTiming {
  const LinkTiming({
    this.scanFor = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 45),
    this.sdkTimeout = const Duration(seconds: 15),
    this.contactFor = const Duration(seconds: 6),
    this.settle = const Duration(seconds: 1),
    this.restartStreamAfter = const Duration(seconds: 8),
    this.reconnectAfter = const Duration(seconds: 40),
    this.reconnectWaits = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)],
    this.rescanFor = const Duration(seconds: 10),
  });

  final Duration scanFor;
  final Duration connectTimeout;
  final Duration sdkTimeout;
  final Duration contactFor;
  final Duration settle;
  /// No data this long (since the stream started or the last batch) with the headband in range: the stream is
  /// restarted, once per stall (not for a headband that mends its own drops once it has streamed).
  final Duration restartStreamAfter;

  /// No data this long with the headband in range: it is let go (stopped, disconnected) and reached again as after a
  /// drop (the night recorder gives up a run after 40 s without data too).
  final Duration reconnectAfter;

  /// Waits before reconnect tries; the last one repeats. Every third try is a scan of [rescanFor].
  final List<Duration> reconnectWaits;
  final Duration rescanFor;
}

enum LinkEvent { drop, reconnectTry, reconnected, streamRestarted }

/// The headband connection is stuck in this run of the app: a search abandoned at its deadline has not come back,
/// and the next one missed its deadline too. BrainBit's SDK takes its calls one at a time on one thread per process
/// (DECISIONS 410), so every later search waits behind the stuck one; only a new app process helps (DECISIONS 452).
class LinkStuck implements Exception {
  const LinkStuck();

  @override
  String toString() =>
      'the headband connection is stuck in this run of the app (an earlier search never came back). Close the app '
      '(swipe it away) and open it again.';
}

class BandLink {
  BandLink({
    required this.finder,
    this.timing = const LinkTiming(),
    required this.onBatch,
    this.onEvent,
    this.onTry,
    DateTime Function()? clock,
  })
    : _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final LinkTiming timing;

  /// Every batch as it arrived (volts, as the SDK gives them).
  final void Function(DateTime arrival, List<Sample> batch) onBatch;

  /// Drops, reconnect tries and restarts, with a plain line for the log.
  final void Function(LinkEvent event, String line)? onEvent;

  /// Each reconnect try with its number, whether it was a scan, and whether it got a headband (for a log that
  /// keeps these as fields); fires just before the [LinkEvent.reconnectTry] line.
  final void Function(int tries, bool scan, bool connected)? onTry;
  final DateTime Function() _now;

  /// Searches and direct tries of this app process abandoned at their deadline that have not come back yet (all
  /// links: there is one per session, and BrainBit's SDK has one call thread per process).
  static final Set<Object> _abandoned = {};

  /// Forgets the abandoned tries (each test starts with a fresh process's state).
  @visibleForTesting
  static void forgetAbandoned() => _abandoned.clear();

  Headband? _band;
  final List<Headband> _lostBands = [];
  StreamSubscription<List<Sample>>? _signalSub;
  StreamSubscription<bool>? _rangeSub;
  /// The last batch, or the stream's start when none came since: the stall clock.
  DateTime? _quietFrom;
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

  /// [reach] (a search or a direct try) with a deadline of [limit]. The SDK goes on past it: a headband the try
  /// brings later is let go when it comes (a BrainBit held by a sensor object nobody has stops advertising, so the
  /// next scan, a session's or the night recorder's, would find nothing). When an earlier abandoned try has not come
  /// back either, the SDK is stuck: [LinkStuck]. Every link's searches go through it, and the morning check-in's.
  static Future<Headband?> within(
    Future<Headband?> reach,
    Duration limit, {
    required Duration sdkTimeout,
    String what = 'connection',
  }) => reach.timeout(
    limit,
    onTimeout: () {
      final stuck = _abandoned.isNotEmpty;
      final token = Object();
      _abandoned.add(token);
      unawaited(
        reach.then<void>(
          (band) async {
            _abandoned.remove(token);
            if (band != null) await letGo(band, sdkTimeout, streaming: false);
          },
          onError: (Object _) {
            _abandoned.remove(token);
          },
        ),
      );
      if (stuck) throw const LinkStuck();
      throw TimeoutException(what, limit);
    },
  );

  /// Lets go of a headband a session does not keep (one still in range): its stream stopped when it may run, then
  /// disconnected, each call with a deadline of [sdkTimeout]; a failure leaves nothing more to do.
  static Future<void> letGo(Headband band, Duration sdkTimeout, {required bool streaming}) async {
    Future<void> call(Future<void> f, String what) =>
        f.timeout(sdkTimeout, onTimeout: () => throw TimeoutException(what, sdkTimeout));
    if (streaming) {
      try {
        await call(band.stopSignal(), 'stop signal');
      } catch (_) {}
    }
    try {
      await call(band.disconnectAndDispose(), 'disconnect');
    } catch (_) {}
  }

  Future<Headband?> _within(Future<Headband?> reach, Duration limit, String what) =>
      within(reach, limit, sdkTimeout: timing.sdkTimeout, what: what);

  Future<void> _letGo(Headband band, {required bool streaming}) => letGo(band, timing.sdkTimeout, streaming: streaming);

  /// Scans and connects; false when no headband was found or the link was closed meanwhile. [onFound] fires between
  /// the scan and the connection (not after [close]).
  Future<bool> connect({void Function(String name)? onFound}) async {
    if (_closed) return false;
    final band = await _within(
      finder.find(timing.scanFor, onFound: (name, _) => _closed ? null : onFound?.call(name)),
      timing.scanFor + timing.connectTimeout,
      'connection',
    );
    if (band == null) return false;
    if (_closed) {
      await _letGo(band, streaming: false);
      return false;
    }
    _band = band;
    _rangeSub = band.rangeChanges.listen((inRange) => _onRange(band, inRange));
    LiveTap.hold(this); // the Signal view reads along instead of connecting (DECISIONS 595)
    return true;
  }

  /// The headband's resistance for [LinkTiming.contactFor]: ohms per channel, null where it has none (infinite),
  /// channels it did not report left out.
  /// On a handle to the one live connection (headband/connection.dart) the reading already in force is returned at
  /// once, with no check and no pause in the stream, unless [fresh] asks for a new one (DECISIONS 855).
  Future<Map<String, double?>> contact({bool fresh = false}) async {
    final band = _band;
    if (band == null) return const {};
    final known = fresh || band is! KnownContact ? null : (band as KnownContact).knownContact;
    if (known != null) {
      LiveTap.contact(known.ohms, known.at);
      return known.ohms;
    }
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
    final ohms = {
      for (final n in channelNames)
        if (last.containsKey(n)) n: last[n]!.isFinite && !last[n]!.isNaN ? last[n] : null,
    };
    LiveTap.contact(ohms, _now());
    return ohms;
  }

  Future<void> startSignal() async {
    final band = _band;
    if (band == null) return;
    _signalSub = band.signal.listen(_onSignal);
    await _sdk(band.startSignal(), 'start signal');
    _quietFrom = _now();
  }

  void _onSignal(List<Sample> batch) {
    if (_closed || batch.isEmpty) return;
    final now = _now();
    lastData = now;
    _quietFrom = now;
    _restarted = false;
    onBatch(now, batch);
    LiveTap.publish(now, batch);
  }

  /// Call about every second: mends a stream that stopped (or never started) while the headband is in range. No data
  /// for [LinkTiming.restartStreamAfter]: the stream is restarted once; none for [LinkTiming.reconnectAfter]: the
  /// headband is let go and reached again ([LinkEvent.drop], then the reconnect tries).
  void tick() {
    final band = _band, from = _quietFrom;
    if (_closed || lost || band == null || from == null) return;
    final quiet = _now().difference(from);
    if (quiet >= timing.reconnectAfter) {
      _stalled(band, quiet);
      return;
    }
    // a headband that mends its own drops (ours) is left to it once it has streamed, as in the night recorder
    if (_restarted || quiet < timing.restartStreamAfter || (band is MendsDrops && lastData != null)) return;
    _restarted = true;
    unawaited(_restartStream(band, quiet));
  }

  Future<void> _restartStream(Headband band, Duration quiet) async {
    onEvent?.call(
      LinkEvent.streamRestarted,
      lastData == null ? 'no data since the start: stream restarted' : 'no data for ${quiet.inSeconds} s: stream restarted',
    );
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      await _sdk(band.startSignal(), 'start signal');
    } catch (_) {}
  }

  /// No data for [LinkTiming.reconnectAfter] with the headband in range: it is let go and reached again.
  void _stalled(Headband band, Duration quiet) {
    lost = true;
    _band = null;
    onEvent?.call(LinkEvent.drop, 'no data for ${quiet.inSeconds} s with the headband in range; reconnecting');
    unawaited(_reconnect(band, inRange: true));
  }

  void _onRange(Headband band, bool inRange) {
    if (inRange || _closed || !identical(band, _band) || _lostBands.contains(band)) return;
    _lostBands.add(band); // no SDK call goes near a headband that is out of range
    if (lost) return; // a reconnect's headband dropped while its stream started: that try failed
    lost = true;
    _band = null;
    onEvent?.call(LinkEvent.drop, 'drop (out of range); reconnecting');
    unawaited(_reconnect(band));
  }

  /// [inRange]: the old headband stalled in range, so it is let go first (a BrainBit held by a sensor object nobody
  /// uses stops advertising); one that went out of range is never touched.
  Future<void> _reconnect(Headband old, {bool inRange = false}) async {
    final signalSub = _signalSub, rangeSub = _rangeSub;
    _signalSub = null;
    _rangeSub = null;
    await signalSub?.cancel();
    await rangeSub?.cancel();
    if (inRange && !_lostBands.contains(old)) await _letGo(old, streaming: true);
    for (var tries = 1; !_closed; tries++) {
      await Future<void>.delayed(timing.reconnectWaits[math.min(tries - 1, timing.reconnectWaits.length - 1)]);
      if (_closed) return;
      final scan = tries % 3 == 0;
      Headband? band;
      try {
        band = scan
            ? await _within(finder.find(timing.rescanFor), timing.rescanFor + timing.connectTimeout, 'rescan')
            : await _within(finder.connectDirect(old.id), timing.connectTimeout, 'direct connection');
      } catch (_) {
        band = null;
      }
      onTry?.call(tries, scan, band != null);
      onEvent?.call(LinkEvent.reconnectTry, 'reconnect try $tries (${scan ? 'scan' : 'direct'}): ${band == null ? 'failed' : 'connected'}');
      if (band == null) continue;
      if (_closed) return _letGo(band, streaming: false); // reached after Stop
      if (await _adopt(band)) return;
    }
  }

  /// Starts the stream of a headband a reconnect try reached; true once it is the link's headband again. False when
  /// it did not become it: its start failed (it may stream all the same), it dropped meanwhile, or Stop came; then
  /// nothing of it reaches the session and one still in range is let go.
  Future<bool> _adopt(Headband band) async {
    _band = band;
    _rangeSub = band.rangeChanges.listen((inRange) => _onRange(band, inRange));
    _signalSub = band.signal.listen(_onSignal);
    var started = true;
    try {
      await _sdk(band.startSignal(), 'start signal');
    } catch (_) {
      started = false;
    }
    if (!identical(_band, band)) return false; // Stop came meanwhile and let it go
    if (started && !_lostBands.contains(band)) {
      _quietFrom = _now();
      _restarted = false;
      lost = false;
      onEvent?.call(LinkEvent.reconnected, 'reconnected');
      return true;
    }
    _band = null;
    final signalSub = _signalSub, rangeSub = _rangeSub;
    _signalSub = null;
    _rangeSub = null;
    await signalSub?.cancel();
    await rangeSub?.cancel();
    if (!_lostBands.contains(band)) await _letGo(band, streaming: true);
    return false;
  }

  /// The Signal view's "Measure contact again", only on a link of its own (DECISIONS 596): the stream stops, the contact
  /// is read as at the start ([contact]), and the stream starts again. Null when no headband is in range now.
  Future<Map<String, double?>?> measureAgain() async {
    final band = _band;
    if (band == null || lost || _closed) return null;
    final sub = _signalSub;
    _signalSub = null;
    await sub?.cancel();
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      return await contact(fresh: true);
    } finally {
      if (!_closed && identical(_band, band)) await startSignal();
    }
  }

  /// Stops the signal and lets the headband go (only one still in range; a lost one is never touched).
  Future<void> close() async {
    _closed = true;
    LiveTap.release(this);
    final band = _band;
    _band = null;
    final signalSub = _signalSub, rangeSub = _rangeSub;
    _signalSub = null;
    _rangeSub = null;
    await signalSub?.cancel();
    await rangeSub?.cancel();
    if (band == null || _lostBands.contains(band)) return;
    await _letGo(band, streaming: true);
  }
}
