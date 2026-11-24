// Where the Signal view's samples come from, and the one rule about it (DECISIONS 595): while a night records, the view
// reads the night recorder's own stream (the night tap); while a daytime session holds the headband, it reads that
// session's link (LiveTap); only when nothing holds the headband does it connect by itself, through the sessions'
// shared link (dream/band_link.dart), and only then does it read the contact (resistance mode) itself. It never opens
// a second connection and never switches a recording headband into resistance mode: it shows the last contact
// reading instead. Everything that needs a phone comes in through [SignalPhone], so the rule is tested without one.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../dream/band_link.dart';
import '../headband/connection.dart' show HeadbandConnection;
import '../logs/metrics.dart' show Metrics;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart' show HeadbandFinder;
import '../recorder/status.dart' show RecorderStatus;
import 'head3d.dart' show HeadPose;
import 'layout.dart';
import 'live_signal.dart';
import 'live_tap.dart';

enum FeedKind { none, own, night, session }

/// Which feed the rule picks: the night's stream while one records, a session's while one holds the headband, else
/// a connection of the Signal view's own.
FeedKind chooseFeed({required bool nightRunning, required bool sessionHolds}) =>
    nightRunning ? FeedKind.night : (sessionHolds ? FeedKind.session : FeedKind.own);

enum SignalStage {
  /// Not on screen: nothing is read.
  idle,
  starting,

  /// Its own connection needs Nearby devices, Bluetooth on, or (the DIY board) Wi-Fi.
  noPermission,
  bluetoothOff,
  noWifi,
  searching,
  checkingContact,

  /// Connected (or reading along), no samples for a while yet.
  waiting,
  live,
  notFound,
  failed,
}

/// The device the view reads: its electrodes, and whether it measures contact.
class SignalDevice {
  const SignalDevice({required this.montage, this.measuresContact = true, this.diy = false});
  final Montage montage;
  final bool measuresContact;

  /// The DIY board (its frames over Wi-Fi), else the BrainBit.
  final bool diy;
}

/// What is ready for a connection of the view's own: null when it can go ahead.
enum Readiness { nearby, bluetooth, wifi }

/// Everything the view needs from the phone (signal_phone.dart in the app; fakes in tests).
class SignalPhone {
  const SignalPhone({
    required this.nightRunning,
    required this.leaseNight,
    required this.fromRecorder,
    required this.device,
    required this.readiness,
    required this.finderFor,
    this.disposeFinder,
    this.holdHeadband,
    this.diyConnection,
    this.timing = const LinkTiming(),
    this.clock = DateTime.now,
    this.tickEvery = const Duration(seconds: 1),
  });

  /// Whether the night recorder's service runs now.
  final Future<bool> Function() nightRunning;

  /// Takes, renews ([on]) or lets go the night tap's lease (and asks the recorder for its status).
  final void Function(bool on) leaseNight;

  /// The recorder's messages (statuses, the night tap's batches); listened to only while the night feed runs.
  final Stream<Object> Function() fromRecorder;

  /// The chosen device and its layout (positions file included).
  final Future<SignalDevice> Function() device;

  /// What is missing for a connection of the view's own (null: nothing).
  final Future<Readiness?> Function(SignalDevice device) readiness;

  /// The finder for a connection of the view's own (the BrainBit's switch, or the DIY board's listener).
  final HeadbandFinder Function(SignalDevice device) finderFor;
  final void Function(HeadbandFinder finder, {required bool anyLost})? disposeFinder;

  /// The owner of the view's own connection to the DIY board (headband/connection.dart: the same class that owns the
  /// BrainBit's one connection), when [finderFor] hands out its finder for that board: its status is the headband
  /// card's on the Signal tab (DECISIONS 947). Null: no card for the board.
  final HeadbandConnection? diyConnection;

  /// Tells the headband watcher of automatic recording (lib/auto, DECISIONS 602) that the view's own connection holds
  /// the headband ([on]: before its search; off once it let go), so no check of the watcher's starts meanwhile. Not for
  /// the night's or a session's stream: those hold the headband themselves.
  final Future<void> Function(bool on)? holdHeadband;
  final LinkTiming timing;
  final DateTime Function() clock;

  /// The feed's clock: the link's stream check, the data age, and (every third) the rule's look (tests go faster).
  final Duration tickEvery;
}

/// Where the shown contact reading comes from.
enum ContactFrom { none, now, nightStart, session }

/// The Signal view's state: the feed, its stage, the layout, the live signal and the contact reading.
class SignalFeed extends ChangeNotifier {
  SignalFeed(this.phone);

  final SignalPhone phone;

  FeedKind kind = FeedKind.none;
  SignalStage stage = SignalStage.idle;

  /// The trouble in words (not found, a failure).
  String? problem;
  SignalDevice device = SignalDevice(montage: brainBitMontage());
  LiveSignal? signal;

  /// Ohms per channel name (null: none or off the head); empty: no reading.
  Map<String, double?> ohms = const {};
  DateTime? ohmsAt;
  ContactFrom ohmsFrom = ContactFrom.none;

  /// When the newest batch came.
  DateTime? lastData;

  /// Bumped at most 15 times a second while samples come: the traces repaint on it, nothing else.
  final ValueNotifier<int> frames = ValueNotifier<int>(0);

  /// How the head is turned; kept while the app runs.
  final ValueNotifier<HeadPose> pose = ValueNotifier<HeadPose>(HeadPose.initial);

  bool _active = false;
  int _run = 0;
  BandLink? _link;
  HeadbandFinder? _finder;
  StreamSubscription<Object>? _recorderSub;
  StreamSubscription<LiveBatch>? _sessionSub;
  Timer? _clock;
  Timer? _frame;
  int _ticks = 0;
  bool _measuring = false;
  bool _switching = false;
  bool _disposed = false;

  /// The headband watcher was told the view's own connection holds the headband.
  bool _holding = false;

  bool get active => _active;
  Montage get montage => device.montage;

  /// The view's own connection may measure the contact again (never while a night or a session holds the headband).
  bool get canMeasure =>
      kind == FeedKind.own &&
      device.measuresContact &&
      !_measuring &&
      (stage == SignalStage.live || stage == SignalStage.waiting);

  /// Seconds since the newest batch (null before the first).
  int? get dataAge {
    final at = lastData;
    return at == null ? null : phone.clock().difference(at).inSeconds;
  }

  /// The view came on screen ([on]) or went away. Off lets go of everything it holds; the kept signal stays.
  Future<void> setActive(bool on) async {
    if (on == _active || _disposed) return;
    _active = on;
    if (on) {
      await _start();
    } else {
      await _stop(SignalStage.idle);
    }
  }

  /// Try again after "not found" or a failure, or after Nearby devices was allowed.
  Future<void> retry() async {
    if (!_active) return;
    await _stop(SignalStage.starting);
    await _start();
  }

  Future<void> _start() async {
    final run = ++_run;
    _set(SignalStage.starting, problem: null);
    SignalDevice dev;
    try {
      dev = await phone.device();
    } catch (_) {
      dev = SignalDevice(montage: brainBitMontage());
    }
    if (run != _run) return;
    _useDevice(dev);
    var night = false;
    try {
      night = await phone.nightRunning();
    } catch (_) {}
    if (run != _run) return;
    switch (chooseFeed(nightRunning: night, sessionHolds: LiveTap.heldByOther(_link))) {
      case FeedKind.night:
        _startNight();
      case FeedKind.session:
        _startSession();
      case FeedKind.own || FeedKind.none:
        await _startOwn(run);
    }
    if (run == _run && _active) _clock ??= Timer.periodic(phone.tickEvery, (_) => unawaited(_tick()));
  }

  void _useDevice(SignalDevice dev) {
    final same = signal != null && listEquals(signal!.names, dev.montage.names);
    device = dev;
    if (!same) signal = LiveSignal(names: dev.montage.names);
    signal!.newRun();
  }

  void _startNight() {
    kind = FeedKind.night;
    ohmsFrom = ContactFrom.nightStart;
    _recorderSub = phone.fromRecorder().listen(_onRecorder);
    phone.leaseNight(true);
    _set(SignalStage.waiting);
  }

  void _onRecorder(Object data) {
    final batches = nightTapBatches(data);
    if (batches != null) {
      for (final b in batches) {
        _take(b);
      }
      return;
    }
    final s = RecorderStatus.fromMap(data);
    if (s == null) return;
    final board = s.board;
    if (board != null && board.names.isNotEmpty && !listEquals(board.names, device.montage.names)) {
      _useDevice(SignalDevice(montage: diyBoardMontage(board.names), measuresContact: false, diy: true));
    }
    if (s.contactOhms.isNotEmpty && !mapEquals(s.contactOhms, ohms)) {
      ohms = Map.unmodifiable(s.contactOhms);
      ohmsAt = s.nightStartMs > 0 ? DateTime.fromMillisecondsSinceEpoch(s.nightStartMs) : null;
      notifyListeners();
    }
  }

  void _startSession() {
    kind = FeedKind.session;
    final c = LiveTap.lastContact;
    ohms = c.ohms;
    ohmsAt = c.at;
    ohmsFrom = c.ohms.isEmpty ? ContactFrom.none : ContactFrom.session;
    _sessionSub = LiveTap.batches.listen(_take);
    _set(SignalStage.waiting);
  }

  Future<void> _startOwn(int run) async {
    kind = FeedKind.own;
    Readiness? missing;
    try {
      missing = await phone.readiness(device);
    } catch (_) {}
    if (run != _run) return;
    if (missing != null) {
      _set(switch (missing) {
        Readiness.nearby => SignalStage.noPermission,
        Readiness.bluetooth => SignalStage.bluetoothOff,
        Readiness.wifi => SignalStage.noWifi,
      });
      return;
    }
    await _hold(true); // before the search: the watcher starts no check of its own meanwhile
    if (run != _run) return;
    final finder = _finder = phone.finderFor(device);
    final link = _link = BandLink(finder: finder, timing: phone.timing, onBatch: _onOwnBatch, clock: phone.clock);
    _set(SignalStage.searching);
    try {
      final found = await link.connect();
      if (run != _run) return;
      if (!found) {
        await _closeOwn();
        _set(SignalStage.notFound);
        return;
      }
      if (device.measuresContact) {
        _set(SignalStage.checkingContact);
        final read = await link.contact();
        if (run != _run) return;
        ohms = read;
        if (read.isNotEmpty) Metrics.write({'kind': 'contact', 'source': 'signal', 'ohms': read}); // contact over the day
        ohmsAt = phone.clock();
        ohmsFrom = read.isEmpty ? ContactFrom.none : ContactFrom.now;
      }
      await link.startSignal();
      if (run != _run) return;
      _set(SignalStage.waiting);
    } catch (e) {
      if (run != _run) return;
      await _closeOwn();
      _set(SignalStage.failed, problem: '$e');
    }
  }

  void _onOwnBatch(DateTime arrival, List<Sample> batch) => _take(LiveBatch.fromSamples(arrival, batch));

  void _take(LiveBatch b) {
    if (!_active || _disposed) return;
    final s = signal;
    if (s == null || !s.add(b)) return;
    lastData = b.arrival;
    if (stage != SignalStage.live && stage != SignalStage.checkingContact) _set(SignalStage.live);
    _frame ??= Timer(const Duration(milliseconds: 66), () {
      _frame = null;
      if (!_disposed) frames.value++;
    });
  }

  /// Every second: the own link's stream check, the data age, and every 3 s whether the rule picks another feed.
  Future<void> _tick() async {
    if (!_active || _disposed) return;
    _ticks++;
    final link = _link;
    if (link != null && !_measuring) link.tick();
    if (kind == FeedKind.night && _ticks % (nightTapRenew.inSeconds) == 0) phone.leaseNight(true);
    final age = dataAge;
    if (stage == SignalStage.live && (age == null || age >= 5)) _set(SignalStage.waiting);
    if (_ticks % 3 != 0) {
      if (stage == SignalStage.waiting) notifyListeners(); // the "no data for N s" line moves on
      return;
    }
    var night = false;
    try {
      night = await phone.nightRunning();
    } catch (_) {
      return;
    }
    if (!_active) return;
    final want = chooseFeed(nightRunning: night, sessionHolds: LiveTap.heldByOther(_link));
    if (want == kind) {
      if (stage == SignalStage.waiting) notifyListeners();
      return;
    }
    // the own connection gives way at once to a night or a session; once a night or a session ends, the view
    // connects by itself
    if (_switching) return;
    _switching = true;
    try {
      await _stop(SignalStage.starting);
      await _start();
    } finally {
      _switching = false;
    }
  }

  /// The view's own connection reads the contact again: the stream pauses for about 7 s.
  Future<void> measureAgain() async {
    final link = _link;
    if (!canMeasure || link == null) return;
    final run = _run;
    _measuring = true;
    _set(SignalStage.checkingContact);
    try {
      final read = await link.measureAgain();
      if (run != _run) return;
      if (read != null) {
        ohms = read;
        if (read.isNotEmpty) Metrics.write({'kind': 'contact', 'source': 'signal', 'ohms': read});
        ohmsAt = phone.clock();
        ohmsFrom = read.isEmpty ? ContactFrom.none : ContactFrom.now;
      }
      signal?.newRun();
    } catch (e) {
      if (run == _run) problem = '$e';
    } finally {
      _measuring = false;
      if (run == _run) _set(SignalStage.waiting);
    }
  }

  Future<void> _closeOwn() async {
    final link = _link, finder = _finder;
    _link = null;
    _finder = null;
    if (link != null) {
      try {
        await link.close();
      } catch (_) {}
    }
    if (finder != null) phone.disposeFinder?.call(finder, anyLost: link?.leftLost ?? false);
    await _hold(false);
  }

  /// Tells the headband watcher once per change; a failure (no channel) changes nothing here.
  Future<void> _hold(bool on) async {
    if (on == _holding) return;
    _holding = on;
    try {
      await phone.holdHeadband?.call(on);
    } catch (_) {}
  }

  Future<void> _stop(SignalStage next) async {
    _run++;
    _clock?.cancel();
    _clock = null;
    _frame?.cancel();
    _frame = null;
    final wasNight = kind == FeedKind.night;
    kind = FeedKind.none;
    await _recorderSub?.cancel();
    _recorderSub = null;
    await _sessionSub?.cancel();
    _sessionSub = null;
    if (wasNight) phone.leaseNight(false);
    await _closeOwn();
    _measuring = false;
    lastData = null;
    _set(next);
  }

  void _set(SignalStage s, {Object? problem = _keep}) {
    stage = s;
    if (!identical(problem, _keep)) this.problem = problem as String?;
    if (!_disposed) notifyListeners();
  }

  static const Object _keep = Object();

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    unawaited(_stop(SignalStage.idle));
    frames.dispose();
    pose.dispose();
    super.dispose();
  }
}
