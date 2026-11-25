// The one owner of the headband connection in the screen's engine (DECISIONS 855). Every screen that needs the
// headband (Signal, Work, Meditation, the dream catcher, the nap coach, sound for states, the check-ins, the hands-free
// calibration) asks this owner through its [finder]; it keeps ONE real connection and hands each asker a handle to it.
// A handle looks like a headband (recorder/headband.dart), so the sessions' shared link (dream/band_link.dart) and its
// reconnect rules work unchanged on top of it. What the owner adds:
// - a start while the headband is connected and streaming reuses it: no search, no new connection, and no new contact
//   check while the signal has not changed since the last one ([KnownContact]);
// - after the last user lets go, the connection is kept for [linger] (3 minutes in the app), so Signal -> Start is one
//   connection; then it is let go for good;
// - one status for every screen ([status]: state, each electrode's word from the one judge, the battery estimate) and
//   one live signal for the foldable panel ([panel]);
// - a night started while it is live gets the same stream (lend.dart): the recorder records what this connection
//   receives until the first drop, then takes the headband over on its own proven path.
// - while a recording runs, whoever asks for the headband gets a [RecordingBand]: a handle that reads the recorder's
//   stream through the tap (signal/live_tap.dart) and never touches the headband (Record first, DECISIONS 897). Work,
//   Meditate and the other sessions run on it as activities of that recording.
// The recorder's engine has no owner: there the recorder is the owner, and its status is mirrored here
// ([recorderData]). Tests make their own owner over a fake finder; without one every finder is as it was.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../dream/band_link.dart';
import '../logs/app_log.dart';
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';
import '../recorder/status.dart';
import '../signal/live_signal.dart';
import '../signal/live_tap.dart' show nightTapBatches, nightTapRenew, nightTapSamples, tapPanel, tapRide;
import '../signal/quality.dart';
import 'battery_estimate.dart';
import 'device_status.dart';
import 'lend.dart';

class HeadbandConnection {
  HeadbandConnection({
    required this.makeFinder,
    this.disposeFinder,
    this.linger = Duration.zero,
    this.sdkTimeout = const Duration(seconds: 15),
    this.stallAfter = const Duration(seconds: 8),
    this.battery,
    this.hold,
    this.leaseNight,
    this.sendToNight,
    this.onStatus,
    this.sessionRuns,
    DateTime Function()? clock,
    this.tickEvery = const Duration(seconds: 1),
    this.batteryEvery = const Duration(seconds: 60),
  }) : _now = clock ?? DateTime.now;

  /// The screen's engine's owner (set in main.dart); null in the recorder's and the watcher's engines and in tests.
  static HeadbandConnection? shared;

  /// A new real finder for a new connection (the BrainBit's switch).
  final HeadbandFinder Function() makeFinder;
  final void Function(HeadbandFinder finder, {required bool anyLost})? disposeFinder;

  /// How long the connection is kept after its last user let go.
  Duration linger;
  final Duration sdkTimeout;

  /// No data this long on a stream that should run: the next start restarts it.
  final Duration stallAfter;
  /// The battery track's file (set once the app knows its folder).
  BandBatteryStore? battery;

  /// Tells the headband watcher that the screen holds the headband (lib/auto, DECISIONS 602).
  final Future<void> Function(bool on)? hold;

  /// Takes, renews or lets go one user's lease of the recorder's tap (signal/live_tap.dart): the panel's during a
  /// recording, and the one of the handles that ride on it.
  final void Function(bool on, String user)? leaseNight;

  /// Sends a lend message to the recorder's engine (lend.dart).
  final void Function(Object message)? sendToNight;

  /// Every new status, for whoever acts on it (the lost-headband notices).
  final void Function(DeviceStatus status)? onStatus;

  /// Whether a session with the headband runs now (the session keeper holds one): then the use is "session".
  final bool Function()? sessionRuns;
  final DateTime Function() _now;
  final Duration tickEvery, batteryEvery;

  final ValueNotifier<DeviceStatus> _status = ValueNotifier(const DeviceStatus());

  /// The one status every screen shows.
  ValueListenable<DeviceStatus> get status => _status;

  /// The live signal for the panel (null until someone watches), and its repaint clock.
  LiveSignal? panel;
  final ValueNotifier<int> frames = ValueNotifier<int>(0);

  HeadbandFinder? _finder;
  Headband? _real;
  bool _anyLost = false;
  bool _streaming = false;
  bool _resisting = false;
  bool _busy = false; // a real SDK call about the stream or the contact is under way
  DateTime? _streamFrom, _lastData, _lastRestart, _batteryAt;
  Future<Headband?>? _connecting;
  bool _searching = false;
  String? _problem;
  final Set<SharedBand> _handles = {};

  /// The handles that read the running recording's stream (Work, Meditate, ... as activities of it).
  final Set<RecordingBand> _riders = {};
  bool _rideInRange = false;
  StreamSubscription<List<Sample>>? _signalSub;
  StreamSubscription<bool>? _rangeSub;
  StreamSubscription<Map<String, double>>? _resistSub;
  Timer? _lingerTimer, _clock, _frame;
  Map<String, double?> _ohms = const {};
  DateTime? _ohmsAt;
  Map<String, double> _resistLast = const {};
  QualityJudge? _judge;
  SecondMaker? _seconds;
  List<String> _names = const [];
  BandBatteryTrack? _track;
  int _panelWatchers = 0;
  int _ticks = 0;
  bool _holding = false;
  bool _disposed = false;

  /// Handles whose headband went away under them: their links are reconnecting through this owner. [_triedAt] is their
  /// last try (or the loss): after a while without one nobody is reconnecting any more.
  int _orphans = 0;
  DateTime? _triedAt;
  static const Duration _orphanFor = Duration(seconds: 75);

  /// How long an offer waits for the recorder's `start` before an idle status withdraws it (the service's start on
  /// the phone takes about a second; 7 s on the owner's night of 2026-11-25).
  static const Duration lendStartWait = Duration(seconds: 20);
  DateTime? _lendAt;

  /// The recorder said nothing for this long (it sends its status about once a second): the recording is over for
  /// the handles that ride on it.
  static const Duration rideEndsAfter = Duration(seconds: 30);
  static final AppLog _log = AppLog('headband');

  bool get _reconnecting {
    final at = _triedAt;
    return _orphans > 0 && at != null && _now().difference(at) < _orphanFor;
  }

  // the night
  bool _lending = false, _forwarding = false;
  RecorderStatus? _night;
  DateTime? _nightAt;

  /// Whether a real connection is held now (used or kept).
  bool get connected => _real != null;

  /// Connected, streaming, and data came within the last 3 s: a start can use it as it is.
  bool get live {
    final at = _lastData;
    return _real != null && _streaming && !_resisting && at != null && _now().difference(at) < const Duration(seconds: 3);
  }

  bool get lending => _lending;

  /// A night records now (the recorder said so within the last 5 s).
  bool get nightRuns {
    final at = _nightAt, n = _night;
    return n != null && at != null && n.phase != Phase.idle && _now().difference(at) < const Duration(seconds: 5);
  }

  /// The finder every screen uses: its headbands are handles to the one connection.
  HeadbandFinder get finder => _SharedFinder(this);

  /// The contact reading in force (null: none, or the signal changed since): ohms per electrode and when measured.
  ({Map<String, double?> ohms, DateTime at})? get knownContact {
    final at = _ohmsAt;
    if (at == null || _ohms.isEmpty || !live) return null;
    if (_judge?.verdict.contactChanged ?? false) return null;
    return (ohms: _ohms, at: at);
  }

  // ---- reaching the headband ------------------------------------------------------------------------------------

  Future<Headband?> _acquire({
    Duration? scanFor,
    BandId? direct,
    void Function(String name, int rssi)? onFound,
  }) async {
    if (_disposed) return null;
    // a recording runs: its stream is the headband (no search, no connection, no contact check of the asker's own)
    if (_lending || nightRuns) {
      final h = _ride();
      onFound?.call(h.name, h.rssi ?? 0);
      return h;
    }
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _triedAt = _now();
    var real = _real;
    if (real != null && _stalled) {
      // kept or shared, but silent: let it go and reach it anew, as after a drop
      await _letGoReal();
      real = null;
    }
    if (real == null) {
      final going = _connecting ??= _connect(scanFor: scanFor, direct: direct, onFound: onFound);
      real = await going;
      if (real == null || !identical(real, _real)) return null;
    } else {
      onFound?.call(real.name, real.rssi ?? 0);
    }
    final h = real is MendsDrops ? _MendingBand(this, real) : SharedBand._(this, real);
    _handles.add(h);
    _emit();
    return h;
  }

  bool get _stalled {
    if (!_streaming || _resisting) return false;
    final from = _lastData ?? _streamFrom;
    return from != null && _now().difference(from) >= stallAfter;
  }

  Future<Headband?> _connect({Duration? scanFor, BandId? direct, void Function(String, int)? onFound}) async {
    _searching = true;
    _problem = null;
    _startClock();
    _emit();
    try {
      await _hold(true);
      final f = _finder ??= makeFinder();
      final band = direct != null ? await f.connectDirect(direct) : await f.find(scanFor!, onFound: onFound);
      if (band == null) return null;
      if (_disposed) {
        unawaited(_quietly(band.disconnectAndDispose()));
        return null;
      }
      _adopt(band);
      return band;
    } finally {
      _connecting = null;
      _searching = false;
      // a failed try after a drop keeps the finder: the headband is reached again through the scanner that found it
      if (_real == null && !_reconnecting) {
        _endFinder();
        await _hold(false);
      }
      _emit();
    }
  }

  void _adopt(Headband band) {
    _real = band;
    _orphans = 0;
    _streaming = false;
    _resisting = false;
    _lastData = null;
    _streamFrom = null;
    _ohms = const {};
    _ohmsAt = null;
    _names = headerOf(band).names;
    _judge = QualityJudge(names: _names, clock: _now)..fit();
    _seconds = SecondMaker(channels: _names.length);
    if (panel == null || !listEquals(panel!.names, _names)) panel = _panelWatchers > 0 ? LiveSignal(names: _names) : null;
    panel?.newRun();
    _rangeSub = band.rangeChanges.listen((inRange) {
      if (!inRange) _onLost(band);
    });
    _signalSub = band.signal.listen((batch) => _onSignal(band, batch));
    _startClock();
    unawaited(_readBattery(band));
  }

  void _onSignal(Headband band, List<Sample> batch) {
    if (!identical(band, _real) || batch.isEmpty) return;
    final now = _now();
    _lastData = now;
    for (final h in _handles) {
      if (h._streaming) h._signal.add(batch);
    }
    final maker = _seconds, judge = _judge;
    if (maker != null && judge != null) {
      final row = List<double>.filled(maker.channels, 0);
      for (final s in batch) {
        if (s.volts.length != maker.channels) break;
        for (var c = 0; c < row.length; c++) {
          row[c] = s.volts[c] * 1e6;
        }
        final sec = maker.push(row);
        if (sec != null) judge.second(sec);
      }
    }
    if (_forwarding) sendToNight?.call(lendBatch(batch, gauge: _track?.lastGauge));
    final p = panel;
    if (p != null && _panelWatchers > 0 && p.add(LiveBatch.fromSamples(now, batch))) _bump();
  }

  void _bump() {
    _frame ??= Timer(const Duration(milliseconds: 66), () {
      _frame = null;
      if (!_disposed) frames.value++;
    });
  }

  /// The real headband went out of range: no SDK call goes near it again (DECISIONS 49); every handle hears it.
  void _onLost(Headband band) {
    if (!identical(band, _real)) return;
    _anyLost = true;
    _dropReal();
    if (_lending) {
      _log.info('lend: the headband dropped; the recorder is told lost');
      sendToNight?.call(lendLost);
      _endLend();
    }
    final users = _orphan();
    if (!users) {
      _endFinder();
      unawaited(_hold(false));
    }
    _emit();
  }

  /// Tells every handle its headband is gone and forgets them (a lost headband is never let go by its user); true
  /// when there were any: their links reconnect through [_acquire].
  bool _orphan() {
    final users = _handles.toList();
    _handles.clear();
    for (final h in users) {
      h._lost();
    }
    if (users.isNotEmpty) {
      _orphans += users.length;
      _triedAt = _now();
    }
    return users.isNotEmpty;
  }

  void _dropReal() {
    unawaited(_signalSub?.cancel());
    unawaited(_rangeSub?.cancel());
    unawaited(_resistSub?.cancel());
    _signalSub = null;
    _rangeSub = null;
    _resistSub = null;
    _real = null;
    _streaming = false;
    _resisting = false;
    _lastData = null;
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _track?.streamingAt(_now(), streaming: false);
    final t = _track;
    if (t != null) battery?.save(t);
  }

  /// Lets the real headband go (one still in range): the stream stopped, then disconnected, each with a deadline.
  Future<void> _letGoReal() async {
    final band = _real;
    if (band == null) return;
    final streaming = _streaming || _resisting;
    _dropReal();
    final users = _orphan();
    if (streaming) await _quietly(band.stopSignal());
    await _quietly(band.disconnectAndDispose());
    if (!users && _connecting == null) {
      _endFinder();
      await _hold(false);
    }
    _emit();
  }

  void _endFinder() {
    final f = _finder;
    if (f == null || _real != null || _connecting != null) return;
    _finder = null;
    disposeFinder?.call(f, anyLost: _anyLost);
    _anyLost = false;
  }

  Future<void> _quietly(Future<void> call) async {
    try {
      await call.timeout(sdkTimeout);
    } catch (_) {}
  }

  Future<void> _hold(bool on) async {
    if (on == _holding) return;
    _holding = on;
    try {
      await hold?.call(on);
    } catch (_) {}
  }

  /// "Connect" on the headband card: reaches the headband, checks contact once, starts the signal and keeps the
  /// connection ([linger]) for whatever starts next. A failure is told in [status] (`problem`).
  Future<void> connectNow() async {
    if (_real != null || _connecting != null || _lending || nightRuns) return;
    final link = BandLink(finder: finder, onBatch: (_, _) {}, clock: _now);
    try {
      if (await link.connect()) {
        await link.contact();
        await link.startSignal();
        await Future<void>.delayed(const Duration(seconds: 1));
      } else {
        _problem = 'Headband not found. Is it switched on and charged?';
      }
    } catch (e) {
      _problem = 'Could not connect: $e';
    } finally {
      await link.close();
      _emit();
    }
  }

  // ---- what a handle asks ---------------------------------------------------------------------------------------

  Future<void> _startSignal(SharedBand h) async {
    final band = _real;
    if (band == null || !identical(band, h._real)) throw StateError('the headband is out of range');
    h._streaming = true;
    await _ensureStream(band);
  }

  /// The real stream runs after this: started when it did not, restarted when it stalled.
  Future<void> _ensureStream(Headband band) async {
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!identical(band, _real) || _resisting) return;
    final now = _now();
    _busy = true;
    try {
      if (!_streaming) {
        await band.startSignal().timeout(sdkTimeout);
        _streaming = true;
        _streamFrom = _now();
        _track?.streamingAt(_now(), streaming: true);
      } else if (_stalled && !(band is MendsDrops && _lastData != null)) {
        final last = _lastRestart;
        if (last != null && now.difference(last) < stallAfter) return;
        _lastRestart = now;
        await _quietly(band.stopSignal());
        await band.startSignal().timeout(sdkTimeout);
        _streamFrom = _now();
      }
    } finally {
      _busy = false;
    }
  }

  /// A handle stops listening. The real stream goes on for the others, the status and a later start; it stops when the
  /// headband is let go.
  Future<void> _stopSignal(SharedBand h) async {
    h._streaming = false;
  }

  /// A real contact check (the caller found no [knownContact], or asked for a fresh one): the stream pauses for everyone.
  Future<void> _startResist(SharedBand h) async {
    final band = _real;
    if (band == null || !identical(band, h._real)) throw StateError('the headband is out of range');
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _busy = true;
    try {
      if (_streaming) {
        await _quietly(band.stopSignal());
        _streaming = false;
        _track?.streamingAt(_now(), streaming: false);
      }
      _resistLast = const {};
      _resistSub ??= band.resistance.listen((r) {
        _resistLast = {..._resistLast, ...r};
        for (final x in _handles) {
          x._resistance.add(r);
        }
      });
      _resisting = true;
      await band.startResist().timeout(sdkTimeout);
    } finally {
      _busy = false;
    }
    _emit();
  }

  Future<void> _stopResist(SharedBand h) async {
    final band = _real;
    if (band == null || !identical(band, h._real) || !_resisting) return;
    _busy = true;
    try {
      await band.stopResist().timeout(sdkTimeout);
    } finally {
      _busy = false;
      _resisting = false;
      await _resistSub?.cancel();
      _resistSub = null;
      if (_resistLast.isNotEmpty) {
        _ohms = Map.unmodifiable({
          for (final n in _names)
            if (_resistLast.containsKey(n)) n: _resistLast[n]!.isFinite ? _resistLast[n] : null,
        });
        _ohmsAt = _now();
        _judge?.ohms(_ohms, at: _ohmsAt);
      }
    }
    panel?.newRun();
    // the others' streams (and a kept connection's) go on
    if (identical(band, _real) && _handles.any((x) => x._streaming && !identical(x, h))) {
      try {
        await _ensureStream(band);
      } catch (_) {}
    }
    _emit();
  }

  Future<void> _release(SharedBand h) async {
    if (!_handles.remove(h)) return;
    h._close();
    if (_handles.isNotEmpty || _lending || _real == null || !identical(h._real, _real)) {
      _emit();
      return;
    }
    if (linger > Duration.zero && !_stalled) {
      _lingerTimer?.cancel();
      _lingerTimer = Timer(linger, () {
        _lingerTimer = null;
        if (_handles.isEmpty && !_lending) unawaited(_letGoReal());
      });
      _emit();
      return;
    }
    await _letGoReal();
  }

  Future<int> _battery(SharedBand h) async {
    final band = _real;
    if (band == null || !identical(band, h._real)) throw StateError('the headband is out of range');
    return await _readBattery(band) ?? (throw StateError('no battery reading'));
  }

  Future<int?> _readBattery(Headband band) async {
    if (band is OtherBoard) return null;
    try {
      final g = await band.battery().timeout(sdkTimeout);
      if (!identical(band, _real)) return g;
      final now = _now();
      _batteryAt = now;
      final t = _track = (battery?.load() ?? _track ?? BandBatteryTrack())..note(g, now, streaming: _streaming);
      battery?.save(t);
      _emit();
      return g;
    } catch (_) {
      return null;
    }
  }

  // ---- the clock, the status ------------------------------------------------------------------------------------

  void _startClock() => _clock ??= Timer.periodic(tickEvery, (_) => _tick());

  void _tick() {
    if (_disposed) return;
    _ticks++;
    final band = _real;
    if (band != null) {
      final at = _batteryAt;
      if (at == null || _now().difference(at) >= batteryEvery) {
        _batteryAt = _now();
        unawaited(_readBattery(band));
      }
    }
    if (_ticks % nightTapRenew.inSeconds == 0 && nightRuns) {
      if (_panelWatchers > 0) leaseNight?.call(true, tapPanel);
      if (_riders.isNotEmpty) leaseNight?.call(true, tapRide);
    }
    // the recorder went quiet without saying idle (its service is gone): the riders hear that the stream ended
    final heard = _nightAt;
    if (_riders.isNotEmpty && !_lending && (heard == null || _now().difference(heard) >= rideEndsAfter)) _endRides();
    if (band == null && _connecting == null && !nightRuns && _panelWatchers == 0 && !_reconnecting && _riders.isEmpty) {
      _clock?.cancel();
      _clock = null;
    }
    _emit();
  }

  void _emit() {
    if (_disposed) return;
    final s = _build();
    _status.value = s;
    onStatus?.call(s);
  }

  DeviceStatus _build() {
    final now = _now();
    final night = _night;
    if (!_lending && night != null && nightRuns) {
      return DeviceStatus.fromRecorder(night, battery: _nightBattery(), now: now);
    }
    final band = _real;
    final bat = _track?.now ?? const BandBattery();
    if (band == null) {
      return DeviceStatus(
        link: _reconnecting ? LinkState.reconnecting : (_searching ? LinkState.searching : LinkState.off),
        use: _use(),
        battery: bat,
        problem: _problem,
      );
    }
    final at = _lastData;
    final fresh = at != null && now.difference(at) < const Duration(seconds: 5);
    return DeviceStatus(
      link: _resisting ? LinkState.checkingContact : (fresh ? LinkState.live : LinkState.waiting),
      use: _use(),
      name: band.name,
      quality: _judge?.verdict ?? const QualityVerdict(),
      battery: bat,
      measuresContact: band is! OtherBoard,
      lastData: at,
      lingering: _handles.isEmpty && !_lending,
    );
  }

  BandUse _use() {
    if (_lending) return BandUse.night;
    if (_handles.isEmpty) return BandUse.none;
    return (sessionRuns?.call() ?? false) ? BandUse.session : BandUse.signal;
  }

  DateTime? _nightBatteryAt;
  BandBattery _nightBatteryNow = const BandBattery();

  /// During a night the recorder's engine writes the battery track: read it at most twice a minute.
  BandBattery _nightBattery() {
    final at = _nightBatteryAt, now = _now();
    if (at == null || now.difference(at) >= const Duration(seconds: 30)) {
      _nightBatteryAt = now;
      _nightBatteryNow = battery?.load().now ?? const BandBattery();
    }
    return _nightBatteryNow;
  }

  // ---- the panel ------------------------------------------------------------------------------------------------

  /// A panel shows the live signal ([on]) or stopped showing it. While none does, no trace is worked out.
  void watchPanel(bool on) {
    _panelWatchers += on ? 1 : -1;
    if (_panelWatchers < 0) _panelWatchers = 0;
    if (on && _panelWatchers == 1) {
      if (_names.isNotEmpty && panel == null) panel = LiveSignal(names: _names);
      panel?.newRun();
      if (nightRuns) leaseNight?.call(true, tapPanel);
      _startClock();
    }
    if (!on && _panelWatchers == 0 && nightRuns) leaseNight?.call(false, tapPanel);
  }

  // ---- the night ------------------------------------------------------------------------------------------------

  /// Everything the recorder's engine sends to the screen: its status (mirrored into [status]), the night tap's batches
  /// (for the panel) and the lend's messages.
  void recorderData(Object data) {
    if (_disposed) return;
    final lend = lendFromNight(data);
    if (lend != null) return _onLendMessage(lend);
    if (_riders.isNotEmpty) {
      final samples = nightTapSamples(data);
      if (samples != null) {
        for (final batch in samples) {
          for (final h in _riders) {
            if (h._streaming) h._signal.add(batch);
          }
        }
      }
    }
    final batches = _panelWatchers > 0 && !_lending ? nightTapBatches(data) : null;
    if (batches != null) {
      for (final b in batches) {
        final p = panel == null || _mismatch(panel!, b) ? (panel = LiveSignal(names: _nightNames(b.channels))) : panel!;
        if (p.add(b)) _bump();
      }
      return;
    }
    final s = RecorderStatus.fromMap(data);
    if (s == null) return;
    final was = nightRuns;
    _night = s;
    _nightAt = _now();
    _rideRange(s);
    // idle ends the lend: the night is over. But a recorder that has not said `start` yet is idle because it is
    // newly born (the screen's status request can reach the new service before its first step): that answer is not
    // an end, while the offer is young. An offer nobody starts on is withdrawn by the same line after [lendStartWait].
    final offered = _lendAt;
    final unborn = !_forwarding && offered != null && _now().difference(offered) < lendStartWait;
    if (s.phase == Phase.idle && _lending) {
      if (unborn) {
        _log.info('lend: the recorder says idle before its start; the offer stands');
      } else {
        _log.info('lend: ended, the recorder is idle');
        _endLend(keep: true);
      }
    }
    if (!was && nightRuns) {
      _startClock();
      if (_panelWatchers > 0) leaseNight?.call(true, tapPanel);
    }
    if (s.phase == Phase.idle) _endRides();
    _emit();
  }

  // ---- riding on the recording ----------------------------------------------------------------------------------

  /// The running recording as the screens need it (its id, its spans); null when none runs.
  RecordingLive? get recording => nightRuns ? _night?.rec : null;

  RecordingBand _ride() {
    final h = RecordingBand._(this);
    if (_riders.isEmpty) _rideInRange = _night?.phase == Phase.recording || _lending;
    _riders.add(h);
    _startClock();
    _log.info('a session rides on the recording', {'riders': _riders.length});
    _emit();
    return h;
  }

  void _leaseRide() => leaseNight?.call(true, tapRide);

  /// The recorder lost the headband or has it back: the riders hear it as out of range and in range; they never
  /// reconnect by themselves (the recorder does).
  void _rideRange(RecorderStatus s) {
    if (_riders.isEmpty || s.phase == Phase.idle || s.phase == Phase.stopping) return;
    final inRange = s.phase == Phase.recording;
    if (inRange == _rideInRange) return;
    _rideInRange = inRange;
    for (final h in _riders.toList()) {
      if (!h._range.isClosed) h._range.add(inRange);
    }
  }

  /// The recording ended under its riders: each hears "out of range" and is over ([RecordingBand.ended]).
  void _endRides() {
    if (_riders.isEmpty) return;
    final users = _riders.toList();
    _riders.clear();
    _log.info('the recording ended under a session', {'riders': users.length});
    for (final h in users) {
      h._end();
    }
  }

  void _endRide(RecordingBand h) {
    if (!_riders.remove(h)) return h._close();
    h._close();
    if (_riders.isEmpty && nightRuns) leaseNight?.call(false, tapRide);
    _emit();
  }

  /// The recorder's contact reading and when it was measured (an empty reading when it has none: riding never checks
  /// contact by itself).
  ({Map<String, double?> ohms, DateTime at}) get _nightContact {
    final n = _night;
    final at = n?.contactAtMs ?? n?.nightStartMs ?? 0;
    return (
      ohms: n?.contactOhms ?? const {},
      at: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : _now(),
    );
  }

  static bool _mismatch(LiveSignal p, LiveBatch b) => p.channels != b.channels;

  List<String> _nightNames(int n) {
    final q = _night?.quality?.electrodes;
    if (q != null && q.length == n) return [for (final e in q) e.name];
    final b = _night?.board?.names;
    if (b != null && b.length == n) return b;
    return [for (var i = 0; i < n; i++) 'CH${i + 1}'];
  }

  /// The night's stop was seen by the screen (the service ended): the mirror ends at once.
  void nightEnded() {
    _night = null;
    _nightAt = null;
    _endRides();
    if (_lending) _endLend(keep: true);
    _emit();
  }

  /// Start of a night: when the connection is live, the offer the recorder records from (lend.dart); null when the
  /// recorder must reach the headband itself (then anything kept here is let go first, so its search finds it).
  Future<LendOffer?> lendToNight() async {
    final band = _real;
    if (band == null) return null;
    if (!live || band is OtherBoard || sendToNight == null) {
      await _letGoReal();
      return null;
    }
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _lending = true;
    _forwarding = false;
    _lendAt = _now();
    final known = knownContact;
    _log.info('lend: the live connection is offered to the recorder', {'contact': known != null});
    _emit();
    return LendOffer(
      band: band.id,
      names: _names,
      ohms: known?.ohms ?? const {},
      ohmsAtMs: known?.at.millisecondsSinceEpoch,
      gauge: _track?.lastGauge,
    );
  }

  /// The night did not start after all: the offer is withdrawn.
  void cancelLend() {
    if (_lending) _log.info('lend: the service did not start; the offer is withdrawn');
    if (_lending) _endLend(keep: true);
  }

  void _onLendMessage(LendMessage m) {
    switch (m) {
      case LendMessage.start:
        if (!_lending) {
          _log.info('lend: the recorder starts, but the offer is gone: it is told lost');
          return sendToNight?.call(lendLost);
        }
        _log.info('lend: the recorder starts on the live connection');
        _forwarding = true;
        final band = _real;
        if (band != null) unawaited(_ensureStream(band).catchError((Object _) {}));
      case LendMessage.endKeep:
        if (_lending) _endLend(keep: true);
      case LendMessage.take:
        _log.info('lend: the recorder reaches the headband itself; let go here');
        // the recorder reaches the headband itself now: nothing here may hold it
        _endLend();
        unawaited(_letGoReal().whenComplete(() => sendToNight?.call(lendReleased)));
    }
  }

  void _endLend({bool keep = false}) {
    _lending = false;
    _forwarding = false;
    if (keep && _real != null && _handles.isEmpty) {
      if (linger > Duration.zero) {
        _lingerTimer?.cancel();
        _lingerTimer = Timer(linger, () {
          _lingerTimer = null;
          if (_handles.isEmpty && !_lending) unawaited(_letGoReal());
        });
      } else {
        unawaited(_letGoReal());
      }
    }
    _emit();
  }

  /// The app goes away: everything is let go.
  Future<void> dispose() async {
    _disposed = true;
    _clock?.cancel();
    _frame?.cancel();
    _lingerTimer?.cancel();
    final band = _real;
    final streaming = _streaming;
    _dropReal();
    for (final h in _handles.toList()) {
      h._close();
    }
    _handles.clear();
    for (final h in _riders.toList()) {
      h._close();
    }
    _riders.clear();
    if (band != null) {
      if (streaming) await _quietly(band.stopSignal());
      await _quietly(band.disconnectAndDispose());
    }
    final f = _finder;
    _finder = null;
    if (f != null) disposeFinder?.call(f, anyLost: _anyLost);
  }
}

class _SharedFinder implements HeadbandFinder {
  _SharedFinder(this._owner);
  final HeadbandConnection _owner;

  @override
  Future<Headband?> find(Duration scanFor, {void Function(String name, int rssi)? onFound}) =>
      _owner._acquire(scanFor: scanFor, onFound: onFound);

  @override
  Future<Headband> connectDirect(BandId id) async =>
      await _owner._acquire(direct: id) ?? (throw StateError('the headband was not reached'));
}

/// A handle to the one connection: a headband to its user.
class SharedBand implements Headband, KnownContact {
  SharedBand._(this._owner, this._real);
  final HeadbandConnection _owner;
  final Headband _real;
  final StreamController<List<Sample>> _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final StreamController<Map<String, double>> _resistance = StreamController<Map<String, double>>.broadcast(sync: true);
  final StreamController<bool> _range = StreamController<bool>.broadcast(sync: true);
  bool _streaming = false;
  bool _gone = false;

  @override
  String get name => _real.name;
  @override
  String get address => _real.address;
  @override
  String get serial => _real.serial;
  @override
  BandId get id => _real.id;
  @override
  int? get rssi => _real.rssi;
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resistance.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  ({Map<String, double?> ohms, DateTime at})? get knownContact => _gone ? null : _owner.knownContact;

  @override
  Future<void> startSignal() => _owner._startSignal(this);
  @override
  Future<void> stopSignal() => _owner._stopSignal(this);
  @override
  Future<void> startResist() => _owner._startResist(this);
  @override
  Future<void> stopResist() => _owner._stopResist(this);
  @override
  Future<bool> isInRange() async => !_gone && identical(_owner._real, _real);
  @override
  Future<int> battery() => _owner._battery(this);
  @override
  Future<void> disconnectAndDispose() => _owner._release(this);

  void _lost() {
    if (_gone) return;
    _gone = true;
    _streaming = false;
    if (!_range.isClosed) _range.add(false);
  }

  void _close() {
    _gone = true;
    _streaming = false;
    unawaited(_signal.close());
    unawaited(_resistance.close());
    unawaited(_range.close());
  }
}

class _MendingBand extends SharedBand implements MendsDrops {
  _MendingBand(super.owner, super.real) : super._();
}

/// A handle to the recording that runs (Record first, DECISIONS 897): a headband to its user, fed by the recorder's
/// tap with every sample the recorder saves, in order, with its packet number. It never touches the headband: no
/// search, no connection, no contact check (it gives the recorder's reading), and when the recorder loses the headband
/// it only says "out of range" until the recorder has it back.
class RecordingBand implements Headband, KnownContact, RidesRecorder {
  RecordingBand._(this._owner);
  final HeadbandConnection _owner;
  final StreamController<List<Sample>> _signal = StreamController<List<Sample>>.broadcast(sync: true);
  final StreamController<Map<String, double>> _resistance = StreamController<Map<String, double>>.broadcast(sync: true);
  final StreamController<bool> _range = StreamController<bool>.broadcast(sync: true);
  bool _streaming = false;
  bool _gone = false;
  bool _ended = false;

  /// Called once when the user lets this handle go (an activity closes its span here, spans/activities.dart).
  Future<void> Function()? onLetGo;

  /// Called once when the recording stops under this handle.
  void Function()? onEnded;

  /// The recording stopped while this handle was in use: nothing more comes, and a new start is a new matter.
  @override
  bool get ended => _ended;

  /// The recording's headband by its own name, once the recorder has found it.
  @override
  String get name => _owner._night?.rec.band ?? 'The recording';
  @override
  String get address => 'recording';
  @override
  String get serial => '';
  @override
  BandId get id => BandId(name: name, address: address);
  @override
  int? get rssi => _owner._night?.rssi;
  @override
  Stream<List<Sample>> get signal => _signal.stream;
  @override
  Stream<Map<String, double>> get resistance => _resistance.stream;
  @override
  Stream<bool> get rangeChanges => _range.stream;

  @override
  ({Map<String, double?> ohms, DateTime at})? get knownContact => _gone ? null : _owner._nightContact;

  @override
  Future<void> startSignal() async {
    if (_gone) throw StateError('the recording has stopped');
    _streaming = true;
    _owner._leaseRide();
  }

  @override
  Future<void> stopSignal() async => _streaming = false;

  /// "Measure again" during a recording: the recorder's last reading, the headband is left alone.
  @override
  Future<void> startResist() async {
    final ohms = _owner._nightContact.ohms;
    if (ohms.isEmpty || _resistance.isClosed) return;
    scheduleMicrotask(() {
      if (!_resistance.isClosed) _resistance.add({for (final e in ohms.entries) e.key: e.value ?? double.infinity});
    });
  }

  @override
  Future<void> stopResist() async {}
  @override
  Future<bool> isInRange() async => !_gone && _owner._rideInRange;
  @override
  Future<int> battery() async => _owner._night?.battery ?? (throw StateError('no battery reading'));
  @override
  Future<void> disconnectAndDispose() async {
    _owner._endRide(this);
    final then = onLetGo;
    onLetGo = null;
    await then?.call();
  }

  void _end() {
    if (_gone) return;
    _gone = true;
    _ended = true;
    _streaming = false;
    if (!_range.isClosed) _range.add(false);
    final then = onEnded;
    onEnded = null;
    if (then != null) scheduleMicrotask(then);
  }

  void _close() {
    _gone = true;
    _streaming = false;
    unawaited(_signal.close());
    unawaited(_resistance.close());
    unawaited(_range.close());
  }
}
