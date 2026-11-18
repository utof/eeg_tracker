// One meditation: headband -> feedback core -> sound and screen, then the report (DECISIONS rows 72-75).
//
// Meditation is its own mode: it owns the headband connection while it runs, from the app's screen, and only
// when no night is being recorded (the night recorder's service owns the headband during a night; a headband
// takes one connection). The connection follows the night recorder's rules where they matter for 5-20
// minutes: contact checked once at the start, no SDK call on a headband that went out of range, reconnect
// straight to the same headband with a scan every third try, every SDK call with a deadline.
//
// Time: the session length counts seconds of signal after calibration (the core's sample clock), so a drop
// pauses the countdown instead of eating the session, and a test can run a session in a fraction of a second.
//
// Beside the feedback core, the shared detectors (app/lib/detectors) see the same samples: blinks, eye movements,
// jaw and movement bursts, epoch quality, and the drift-off detector, whose "lights off" is the calibration's
// close-eyes cue (its 60 s eyes-closed baseline is the calibration minute). Its drowsy / probably-asleep state
// joins the core's drowsy gate in the "drifting" chip; both are exposed for later features (dream catcher,
// sleep-sound auto-stop).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../detectors/detectors.dart';
import '../detectors/drift_off.dart';
import '../feedback/features.dart' show channelNames, fs;
import '../feedback/mapping.dart';
import '../feedback/session.dart';
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart';
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../sound/feedback_sound.dart';
import 'store.dart';
import 'tracker.dart';

enum Stage { setup, connecting, contact, calibrating, running, ending, report, failed }

/// A skip of this many packet numbers or more (0.1 s) is a hole in the signal: the core restarts its filters.
/// Smaller skips (a lost packet or two) pass through. Planning value until the phone test counts real gaps.
const int gapSamples = 25;

/// A pause in arrivals longer than this (beyond the batch's own length) is a hole too (sound-source.js GAP_S).
const double gapPauseS = 1;

/// Sessions shorter than this after calibration are not saved (nothing to report).
const double minReportS = 10;

class MeditationTiming {
  const MeditationTiming({
    this.scanFor = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 45),
    this.sdkTimeout = const Duration(seconds: 15),
    this.contactFor = const Duration(seconds: 6),
    this.settle = const Duration(seconds: 1),
    this.tick = const Duration(milliseconds: 250),
    this.noDataAfter = const Duration(seconds: 2),
    this.restartStreamAfter = const Duration(seconds: 8),
    this.reconnectWaits = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)],
    this.rescanFor = const Duration(seconds: 10),
    this.endRingOut = const Duration(seconds: 3),
  });

  final Duration scanFor;
  final Duration connectTimeout;
  final Duration sdkTimeout;

  /// How long the contact check (resistance) runs at the start.
  final Duration contactFor;

  /// Pause between the contact check and the signal (the laptop once got no stream right after it).
  final Duration settle;

  /// The screen and the no-data check update this often.
  final Duration tick;

  /// No data for this long: the sound goes neutral and the chip says so (sound-app.js: 2 s).
  final Duration noDataAfter;

  /// The stream never started: stop and start it once after this long.
  final Duration restartStreamAfter;

  /// Waits before reconnect tries; the last one repeats. Every third try is a scan of [rescanFor].
  final List<Duration> reconnectWaits;
  final Duration rescanFor;

  /// After the end cue, before the sound stops.
  final Duration endRingOut;
}

class MeditationController extends ChangeNotifier {
  MeditationController({
    required this.finder,
    required FeedbackSound Function() sound,
    this.store,
    this.timing = const MeditationTiming(),
    DateTime Function()? clock,
  }) : _makeSound = sound,
       _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final FeedbackSound Function() _makeSound;
  /// Where sessions are kept; set by the screen once the app's folder is known (null: not saved).
  MeditationStore? store;
  final MeditationTiming timing;
  final DateTime Function() _now;

  Stage stage = Stage.setup;

  /// One plain sentence about the stage (connecting, a failure, why a session was not saved).
  String message = '';
  Duration length = const Duration(minutes: 10);
  Moment chip = Moment.calibrating;

  /// 'open' or 'closed' while calibrating.
  String? calPhase;

  /// Seconds left in the calibration phase; after the eyes-closed minute, the clean seconds still needed.
  int calSecondsLeft = 0;
  bool calNeedsClean = false;

  /// Set when the sound could not start (the session then runs silently) or the session could not be saved.
  String? soundNote;
  String? saveNote;

  /// Contact at the start: ohms per channel, null = no contact.
  Map<String, double?> contact = const {};
  MeditationSummary? report;
  List<MeditationSummary> earlier = const [];
  String comparison = '';

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _lostBands.isNotEmpty;

  /// Seconds of signal since calibration ended.
  double get runSeconds => _tracker?.runSeconds ?? 0;
  int get secondsLeft => math.max(0, (length.inMilliseconds / 1000 - runSeconds).ceil());
  int get bells => _tracker?.bells ?? 0;
  bool get active => stage.index >= Stage.connecting.index && stage.index <= Stage.ending.index;

  /// What the electrodes saw in the session running now (or the last one): blinks, eye movements, bursts,
  /// movement, epoch quality. For later features; the screen does not show it yet.
  Detectors? get seen => _seen;

  /// The drift-off detector of this session, from the close-eyes cue on (null before it).
  DriftOff? get drift => _drift;

  /// The drift-off detector's state now (null before its baseline is complete).
  DriftState? get driftState => _drift?.state == DriftState.baseline ? null : _drift?.state;

  /// The feedback core of the session running now (its log), for tests and tools.
  @visibleForTesting
  Session? get session => _session;

  Headband? _band;
  final List<Headband> _lostBands = [];
  FeedbackSound? _sound;
  Session? _session;
  MeditationTracker? _tracker;
  Detectors? _seen;
  DriftOff? _drift;
  int _lostSamples = 0;
  DateTime? _startedAt;
  StreamSubscription<List<Sample>>? _signalSub;
  StreamSubscription<bool>? _rangeSub;
  Timer? _ticker;
  DateTime? _lastData;
  DateTime? _signalAt;
  DateTime _notifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int? _lastPack;
  int _closedFromN = 0;
  bool _gapPending = false;
  bool _lost = false;
  bool _ended = false;
  bool _restartedStream = false;
  bool _quiet = false;
  bool _disposed = false;

  /// Connects, checks contact, starts the sound and the calibration. Errors end in [Stage.failed].
  Future<void> start(Duration sessionLength) async {
    if (active) return;
    _reset(sessionLength);
    _set(Stage.connecting, 'Looking for the headband.');
    try {
      final band = await finder
          .find(timing.scanFor, onFound: (name, _) => _set(Stage.connecting, 'Found $name. Connecting.'))
          .timeout(timing.scanFor + timing.connectTimeout);
      if (band == null) {
        return await _fail('Headband not found. Is it switched on, charged, and free (no night recording)?');
      }
      _band = band;
      if (_ended) return await _release();
      _rangeSub = band.rangeChanges.listen(_onRange);
      _set(Stage.contact, 'Checking contact. Keep still for a few seconds.');
      contact = await _checkContact(band);
      if (_ended) return await _release();

      var sound = _makeSound();
      try {
        await sound.start();
      } catch (e) {
        soundNote = 'The sound did not start ($e). This session runs without sound.';
        sound = SilentSound();
      }
      _sound = sound;
      if (_ended) {
        await sound.stop();
        return await _release();
      }

      final s = Session()..contact(contact);
      s.log.note({'app': 'eeg_tracker meditation', 'lengthS': sessionLength.inSeconds, 'headband': band.name});
      _session = s;
      _tracker = MeditationTracker(sessionLength);
      _seen = Detectors(onSecond: _onSecond);
      _startedAt = _now();
      calPhase = 'open';
      calSecondsLeft = Cal.openS.toInt();
      _signalSub = band.signal.listen(_onBatch);
      await _sdk(band.startSignal(), 'start signal');
      _signalAt = _now();
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(Stage.calibrating, '');
    } on TimeoutException catch (e) {
      await _fail('The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.');
    } catch (e) {
      await _fail('Could not start: $e');
    }
  }

  /// Ends early. With at least [minReportS] of session after calibration, the report shows what there was.
  Future<void> stop() => _finish(complete: false);

  /// Back to the length choice after a report or a failure.
  void again() {
    if (active) return;
    _set(Stage.setup, '');
  }

  void _reset(Duration sessionLength) {
    length = sessionLength;
    _band = null;
    _session = null;
    _tracker = null;
    _seen = null;
    _drift = null;
    _lostSamples = 0;
    _sound = null;
    _lastData = null;
    _signalAt = null;
    _lastPack = null;
    _gapPending = false;
    _lost = false;
    _ended = false;
    _restartedStream = false;
    _quiet = false;
    chip = Moment.calibrating;
    calPhase = null;
    calNeedsClean = false;
    soundNote = null;
    saveNote = null;
    report = null;
    contact = const {};
    comparison = '';
  }

  Future<T> _sdk<T>(Future<T> call, String what) => call.timeout(timing.sdkTimeout, onTimeout: () {
    throw TimeoutException(what, timing.sdkTimeout);
  });

  /// The headband's resistance for [MeditationTiming.contactFor]: ohms per channel, null where it has none
  /// (infinite), channels it did not report left out (unknown, not held against them).
  Future<Map<String, double?>> _checkContact(Headband band) async {
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

  void _onBatch(List<Sample> batch) {
    final s = _session;
    if (s == null || _ended || batch.isEmpty) return;
    final now = _now(), last = _lastData;
    if (last != null && now.difference(last).inMicroseconds / 1e6 > gapPauseS + batch.length / fs) {
      _gapPending = true;
      _lostSamples = 0; // unknown length
    }
    _lastData = now;
    var rows = <List<double>>[];
    final steps = <StepResult>[];
    for (final x in batch) {
      final prev = _lastPack;
      if (prev != null) {
        final skip = (x.pack - prev - 1) % packetWrap;
        if (skip >= gapSamples && skip <= maxGapSamples) {
          _gapPending = true;
          _lostSamples = skip;
        }
      }
      _lastPack = x.pack;
      if (_gapPending) {
        if (rows.isNotEmpty) steps.addAll(s.push(rows));
        rows = [];
        s.gap();
        // the detectors hold the last value over the hole (as the BDF does); unknown length: one second
        _seen?.hold(_lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; the core takes µV
      rows.add(row);
      if (row.every((v) => v.isFinite)) _seen?.push(row);
    }
    steps.addAll(s.push(rows));
    for (final r in steps) {
      if (_ended) break;
      _onStep(r);
    }
    if (_quiet) _quiet = false;
    if (now.difference(_notifiedAt) >= timing.tick) _notify();
  }

  void _onStep(StepResult r) {
    final sound = _sound!, tracker = _tracker!;
    if (r.cue == 'close-eyes') {
      sound.cue();
      calPhase = 'closed';
      _closedFromN = r.n;
      final seen = _seen;
      if (seen != null) _drift = DriftOff(seen.n ~/ fs); // lights off: the eyes close now
    } else if (r.cue == 'calibration-done') {
      sound.cue();
      sound.bed(on: true);
      calPhase = null;
      _set(Stage.running, '');
    }
    if (r.phase == 'cal-open') {
      calSecondsLeft = math.max(0, (Cal.openS - r.n / fs).ceil());
    } else if (r.phase == 'cal-closed' && r.cue == null) {
      final left = (Cal.closedS - (r.n - _closedFromN) / fs).ceil();
      calNeedsClean = left <= 0;
      calSecondsLeft = left > 0 ? left : _session!.calibrationCleanLeft.ceil();
    } else if (r.phase == 'run') {
      sound.glide(r.targets);
      if (r.ring) sound.bell();
      tracker.add(r, drift: driftState);
      chip = tracker.chip;
      if (tracker.done) unawaited(_finish(complete: true));
    }
  }

  /// Each whole second from the detectors (one second late): the drift-off detector's input after lights off.
  void _onSecond(Second sec) {
    final d = _drift;
    if (d == null || sec.k < d.lightsOff) return;
    final a = sec.backAlpha;
    d.second(sec.k, a.alpha, a.clean, sec.movement, sec.sem, sec.blinks);
  }

  void _tick() {
    if (_ended) return;
    final now = _now(), last = _lastData;
    final quiet = now.difference(last ?? _signalAt ?? now);
    if (quiet > timing.noDataAfter) {
      if (!_quiet) {
        _quiet = true;
        _sound?.glide(mapState(z: null, jaw: null, quality: 'none', veto: null));
      }
      if (last == null && !_restartedStream && !_lost && quiet > timing.restartStreamAfter) {
        _restartedStream = true;
        unawaited(_restartStream());
      }
    }
    _notify();
  }

  /// No data since the start: stop and start the stream once (a stream right after a contact check once sent
  /// nothing on the laptop; the night recorder restarts it the same way).
  Future<void> _restartStream() async {
    final band = _band;
    if (band == null) return;
    _session?.log.note({'event': 'stream restarted', 'n': _session?.n});
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      await _sdk(band.startSignal(), 'start signal');
    } catch (_) {}
  }

  void _onRange(bool inRange) {
    if (inRange || _lost || _ended || _session == null) return;
    _lost = true;
    _gapPending = true;
    _lastPack = null;
    _session!.log.note({'event': 'drop', 'n': _session!.n, 'at': _now().toIso8601String()});
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
    for (var tries = 1; !_ended; tries++) {
      await Future<void>.delayed(timing.reconnectWaits[math.min(tries - 1, timing.reconnectWaits.length - 1)]);
      if (_ended) return;
      final scan = tries % 3 == 0;
      Headband? band;
      try {
        band = scan
            ? await finder.find(timing.rescanFor).timeout(timing.rescanFor + timing.connectTimeout)
            : await finder.connectDirect(old.id).timeout(timing.connectTimeout);
      } catch (_) {
        band = null;
      }
      _session?.log.note({'event': 'reconnect try', 'try': tries, 'scan': scan, 'ok': band != null});
      if (band == null) continue;
      if (_ended) {
        _band = band;
        return _release();
      }
      _band = band;
      _lastPack = null;
      _gapPending = true;
      _rangeSub = band.rangeChanges.listen(_onRange);
      _signalSub = band.signal.listen(_onBatch);
      try {
        await _sdk(band.startSignal(), 'start signal');
        _lost = false;
        _session?.log.note({'event': 'reconnected', 'n': _session?.n, 'at': _now().toIso8601String()});
        return;
      } catch (_) {
        continue;
      }
    }
  }

  Future<void> _finish({required bool complete}) async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    final s = _session, t = _tracker, sound = _sound, start = _startedAt;
    _set(Stage.ending, complete ? 'Session over. Open your eyes when you like.' : 'Stopping.');
    if (complete) sound?.cue();
    sound?.bed(on: false);
    await _release();
    if (complete) await Future<void>.delayed(timing.endRingOut);
    await sound?.stop();
    if (s == null || t == null || start == null || t.runSeconds < minReportS) {
      _set(Stage.setup, s == null ? '' : 'Stopped before the session began, so nothing was saved.');
      return;
    }
    final st = store;
    final summary = t.summary(
      start: start,
      complete: complete,
      iafHz: s.iaf,
      note: s.note,
      logFile: '${st?.stemFor(start) ?? 'session'}.session.json',
    );
    _seen?.finish();
    s.log.note({'sound': sound?.info(), 'end': complete ? 'length reached' : 'stopped', 'runS': t.runSeconds});
    final d = _drift, seen = _seen;
    if (seen != null) {
      s.log.note({
        'detectors': {
          'blinks': seen.blinks.length,
          'eyeMoves': seen.eyeMoves.length,
          'bursts': {for (final k in BurstKind.values) k.name: seen.bursts.where((b) => b.kind == k).length},
          'epochs': {for (final q in EpochQuality.values) q.name: seen.epochs.where((e) => e.quality == q).length},
          if (d != null) 'drift': {'lightsOffS': d.lightsOff, 'baseline': d.baselineAlpha, 'onsetS': d.onset, 'asleepAtS': d.asleepAt},
        },
      });
    }
    if (st != null) {
      try {
        await st.save(summary, s.log);
        earlier = [
          for (final e in st.list())
            if (e.start != summary.start) e,
        ];
      } catch (e) {
        saveNote = 'This session could not be saved: $e';
      }
    }
    comparison = compareWithEarlier(summary, earlier).line;
    report = summary;
    _set(Stage.report, '');
  }

  /// Stops the signal and lets the headband go (only one still in range; a lost one is never touched).
  Future<void> _release() async {
    await _signalSub?.cancel();
    await _rangeSub?.cancel();
    _signalSub = null;
    _rangeSub = null;
    final band = _band;
    _band = null;
    if (band == null || _lost) return;
    try {
      await _sdk(band.stopSignal(), 'stop signal');
    } catch (_) {}
    try {
      await _sdk(band.disconnectAndDispose(), 'disconnect');
    } catch (_) {}
  }

  Future<void> _fail(String why) async {
    final stoppedByUser = _ended; // a stop during connecting already went back to the start
    _ended = true;
    _ticker?.cancel();
    await _release();
    await _sound?.stop();
    if (!stoppedByUser) _set(Stage.failed, why);
  }

  void _set(Stage s, String text) {
    stage = s;
    message = text;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    _notifiedAt = _now();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_ended) unawaited(_finish(complete: false));
    super.dispose();
  }
}
