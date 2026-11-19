// One meditation: headband -> feedback core -> sound and screen, then the report (DECISIONS rows 72-75).
//
// Meditation is its own mode: it owns the headband connection while it runs, from the app's screen, and only
// when no night is being recorded (the night recorder's service owns the headband during a night; a headband
// takes one connection). The connection follows the night recorder's rules where they matter for 5-20
// minutes (the shared headband link, dream/band_link.dart, DECISIONS 270): contact checked once at the start,
// no SDK call on a headband that went out of range, reconnect straight to the same headband with a scan every
// third try, every SDK call with a deadline.
//
// Time: the session length counts seconds of signal after calibration (the core's sample clock), so a drop
// pauses the countdown instead of eating the session, and a test can run a session in a fraction of a second.
// Arrivals and pauses are timed on a monotonic clock (session_clock.dart): a correction of the phone's clock is
// not a hole in the signal.
//
// Beside the feedback core, the shared detectors (app/lib/detectors) see the same samples: blinks, eye movements,
// jaw and movement bursts, epoch quality, and the drift-off detector, whose "lights off" is the calibration's
// close-eyes cue (its 60 s eyes-closed baseline is the calibration minute). Its drowsy / probably-asleep state
// joins the core's drowsy gate in the "drifting" chip; both are exposed for later features (dream catcher,
// sleep-sound auto-stop).
//
// Two kinds of session run here (training/control.dart): meditation, and alpha-theta (ROADMAP row 22), whose
// rules (alphatheta/engine.dart) sit on the same core and whose sleep guard is the drift-off detector: when it
// says "probably asleep" the bed fades and a soft rising cue wakes you, again every minute while it lasts.
// With the replay check on (ROADMAP row 23), a session can be a replay: the sound then plays the control stream of
// your own earlier live sessions (training/replay.dart) while the live gates still act. Which one it is stays in
// here: the screen gets the same fields either way, without live bells or the settled / settling word.
// Hands-free (DECISIONS 244-246): with the owner's switch on, a double clench in a meditation pauses the sound (the
// bed fades, no bells) and the next brings it back; a look left then right, and any gesture in alpha-theta, marks a
// moment in the session log. Never while the drift-off detector says probably asleep.
// The silent minutes (silent_block.dart, DECISIONS 420): a meditation's length is its time with sound; then a cue,
// the sound fades out, and the headband goes on measuring for [silentBlock] (eyes still closed). The core keeps
// running (its log replays as before); the log marks where the sound stopped, so a replay of this session in the
// replay check plays only the time with sound. Stop in the silent minutes keeps the session whole. Alpha-theta has
// none yet (its own after-session steps come first).
// Kept as it goes (DECISIONS row 463): every minute after the first 10 s with sound the summary and the log are
// written (the summary says "running"), and at the end they are written before the slow steps (the headband's
// release, the ring-out, the fade), so a swipe, a kill or a crash loses at most the last minute.
// Clock limits (DECISIONS row 464), on the session clock from Start: a headband silent for 5 minutes, a calibration
// still short of its clean seconds after 10 minutes, or the length + the silent minutes + 20 minutes end the session
// as Stop would, with a sentence; so a dead headband cannot keep the sound, the service and the reconnects going.
// Where the sound goes (sound/audio_route.dart, DECISIONS 424): read at the start and followed while the screen is
// open, so the setup can warn about Bluetooth (0.25-0.5 s late); the session log keeps the route and every change,
// and the summary whether any of it went over Bluetooth. The session goes on either way.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../alphatheta/engine.dart';
import '../dream/band_link.dart';
import '../detectors/detectors.dart';
import '../detectors/drift_off.dart';
import '../detectors/gestures.dart';
import '../feedback/features.dart' show fs;
import '../feedback/mapping.dart';
import '../feedback/session.dart';
import '../recorder/chunk_writer.dart' show Sample, fileStem;
import '../recorder/headband.dart' show HeadbandFinder;
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../handsfree/live.dart';
import '../session_clock.dart';
import '../session_keeper.dart' show FocusChange;
import '../sound/audio_route.dart';
import '../sound/feedback_sound.dart';
import '../sound/gesture_tone.dart';
import '../sound/session_sound.dart';
import '../training/check.dart';
import '../training/check_store.dart';
import '../training/control.dart';
import '../training/outcome.dart';
import '../training/replay.dart';
import 'learning.dart';
import 'silent_block.dart';
import 'store.dart';
import 'tracker.dart';

/// [rating]: the session is over and saved; the after-session questions come before the report (the replay
/// check's guess, and for alpha-theta its checklist and alertness check).
enum Stage { setup, connecting, contact, calibrating, running, ending, rating, report, failed }

/// While the drift-off detector says probably asleep in alpha-theta, the wake cue repeats this often.
const double wakeEveryS = 60;

/// The live control of a meditation step: the core's calm, roughness and bell.
Control meditationControl(StepResult r) => (
  level: r.targets.calm,
  rough: r.targets.rough,
  reward: r.ring ? 'bell' : null,
  gated: r.veto != null || r.quality != 'good',
);

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
    this.saveEvery = const Duration(seconds: 60),
    this.noSignalEnd = const Duration(minutes: 5),
    this.calibrationLimit = const Duration(minutes: 10),
    this.clockMargin = const Duration(minutes: 20),
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

  /// The session's files are rewritten this often while it runs (so a killed app keeps it up to then).
  final Duration saveEvery;

  /// No signal at all for this long ends the session (the headband died or is gone).
  final Duration noSignalEnd;

  /// Still calibrating this long after Start (the clean seconds never came): the session ends.
  final Duration calibrationLimit;

  /// The session ends this long after its length with sound and its silent minutes, counted from Start (drops
  /// pause the session's own count, which could otherwise run on for hours).
  final Duration clockMargin;

  /// The shared headband link's timing: these same fields (the reconnect rules are in dream/band_link.dart).
  LinkTiming get link => LinkTiming(
    scanFor: scanFor,
    connectTimeout: connectTimeout,
    sdkTimeout: sdkTimeout,
    contactFor: contactFor,
    settle: settle,
    restartStreamAfter: restartStreamAfter,
    reconnectWaits: reconnectWaits,
    rescanFor: rescanFor,
  );
}

class MeditationController extends ChangeNotifier {
  MeditationController({
    required this.finder,
    required FeedbackSound Function() sound,
    SessionSound Function()? alphaThetaSound,
    this.store,
    this.checkStore,
    this.timing = const MeditationTiming(),
    this.gestureTone,
    this.silentBlock = silentBlockLength,
    this.audioRoute,
    this.routeTimeout = const Duration(seconds: 2),
    DateTime Function()? clock,
    Duration Function()? monotonic,
  }) : _makeSound = sound,
       _makeAtSound = alphaThetaSound ?? SilentSessionSound.new,
       _now = clock ?? DateTime.now,
       _clock = SessionClock(wall: clock, monotonic: monotonic);

  final SessionClock _clock;

  final HeadbandFinder finder;
  final FeedbackSound Function() _makeSound;
  final SessionSound Function() _makeAtSound;

  /// The hands-free confirmation tone (null: none).
  final GestureTone Function()? gestureTone;

  /// How long a meditation's silent minutes last after its time with sound (zero: none).
  final Duration silentBlock;

  /// Where the sound goes (null: not known, nothing recorded); [route] is the latest answer.
  final AudioRouteSource? audioRoute;
  final Duration routeTimeout;
  AudioRoute route = AudioRoute.unknown;
  AudioRoute? _routeAtStart;
  bool _bluetoothUsed = false;
  StreamSubscription<AudioRoute>? _routeSub;

  /// The owner's calibrated gestures while the hands-free switch is on (set by the screen); null: off.
  GestureSettings? handsFree;

  /// A meditation's sound is paused by a double clench.
  bool paused = false;

  /// A call or another app has the sound now ([audioFocus]): the bed is quiet and nothing rewards.
  bool get interrupted => _interrupted;
  bool _interrupted = false;

  /// Where sessions of this controller's kind are kept; set by the screen once the app's folder is known
  /// (null: not saved).
  MeditationStore? store;

  /// The replay check of this kind while the toggle is on; null when it is off.
  CheckStore? checkStore;

  /// The kind of the session running now (or the last one).
  SessionKind kind = SessionKind.meditation;

  /// The replay check's words for this session (never live or replay); null with the check off.
  String? checkStatus;

  /// The check is on for the session running now: the screen hides live bells and the settled word.
  bool get checkOn => _slot != null;

  /// The after-session questions include the replay check's guess.
  bool get asksGuess => _slot?.phase == SlotPhase.randomised;
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

  /// After a meditation: the learning verdict over every saved meditation (learning.dart).
  Learning? learning;

  /// Where the replay check's results are kept, toggle on or off (set by the screen): the learning verdict shows
  /// its test of the silent minutes once a set is revealed.
  CheckStore? checkResults;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _link?.leftLost ?? false;

  /// Alpha-theta: the drift-off detector says probably asleep now, so the bed has faded.
  bool asleepGuard = false;

  /// Alpha-theta: what the session adds to the report.
  AtTally? get tally => _tally;

  /// Seconds of signal since calibration ended (the time with sound).
  double get runSeconds => _tracker?.runSeconds ?? 0;
  int get secondsLeft => math.max(0, (length.inMilliseconds / 1000 - runSeconds).ceil());

  /// This session's silent minutes (zero for alpha-theta), and how far they are.
  Duration silentLength = Duration.zero;
  bool get inSilentBlock => _silent != null && !_ended;
  double get silentSeconds => _silent?.seconds ?? 0;
  int get silentSecondsLeft => math.max(0, (silentLength.inMilliseconds / 1000 - silentSeconds).ceil());
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

  BandLink? _link;
  SessionSound? _sound;
  Session? _session;
  AlphaThetaEngine? _engine;
  Slot? _slot;
  Replayer? _replayer;
  OutcomeMeter? _outcome;
  AtTally? _tally;
  double _wokeAt = -1e9;
  bool _replayFailed = false;
  MeditationTracker? _tracker;
  SilentMeter? _silent;
  Detectors? _seen;
  DriftOff? _drift;
  HandsFree? _hands;
  int _lostSamples = 0;
  DateTime? _startedAt;
  Duration _startMono = Duration.zero;
  Duration? _lastSave;
  Future<void>? _saving;
  Timer? _ticker;
  Duration? _lastData;
  Duration? _signalAt;
  Duration _notifiedAt = const Duration(days: -1);
  int? _lastPack;
  int _closedFromN = 0;
  bool _gapPending = false;
  bool _ended = false;
  bool _quiet = false;
  bool _disposed = false;

  /// The number of the latest start: a start that Stop or a newer start overtook touches nothing of the session
  /// (DECISIONS 450).
  int _run = 0;
  bool _live(int run) => run == _run && !_ended;

  /// Connects, checks contact, starts the sound and the calibration. Errors end in [Stage.failed]. With
  /// [checkStore] set, the replay check decides first whether this session is live or a replay.
  Future<void> start(Duration sessionLength, {SessionKind kind = SessionKind.meditation}) async {
    if (active) return;
    _reset(sessionLength);
    final run = ++_run;
    this.kind = kind;
    silentLength = kind == SessionKind.meditation ? silentBlock : Duration.zero;
    _set(Stage.connecting, 'Looking for the headband.');
    try {
      await _readRoute();
      if (!_live(run)) return;
      await _prepareCheck(sessionLength, run);
      if (!_live(run)) return;
      final link = BandLink(
        finder: finder,
        timing: timing.link,
        onBatch: _onBatch,
        onEvent: _onLinkEvent,
        onTry: _onTry,
        clock: _now,
      );
      _link = link;
      if (!await link.connect(onFound: (name) => _set(Stage.connecting, 'Found $name. Connecting.'))) {
        return await _fail('Headband not found. Is it switched on, charged, and free (no night recording)?', run);
      }
      if (!_live(run)) return await link.close();
      _set(Stage.contact, 'Checking contact. Keep still for a few seconds.');
      final ohms = await link.contact();
      if (!_live(run)) return await link.close();
      contact = ohms;

      SessionSound sound = kind == SessionKind.meditation ? MeditationSound(_makeSound()) : _makeAtSound();
      String? note;
      try {
        await sound.start();
      } catch (e) {
        note = 'The sound did not start ($e). This session runs without sound.';
        sound = SilentSessionSound();
      }
      if (!_live(run)) {
        await sound.stop();
        return await link.close();
      }
      soundNote = note;
      _sound = sound;

      final engine = kind == SessionKind.alphaTheta ? AlphaThetaEngine() : null;
      final s = engine?.core ?? Session();
      engine != null ? engine.contact(contact) : s.contact(contact);
      _routeAtStart = route;
      _bluetoothUsed = route.bluetooth;
      s.log.note({
        'app': 'eeg_tracker ${kind.name}',
        'lengthS': sessionLength.inSeconds,
        if (silentLength > Duration.zero) 'silentS': silentLength.inSeconds,
        'headband': link.name,
        if (audioRoute != null) 'audioRoute': route.toJson(),
        if (_slot != null) 'check': _checkInfo(),
      });
      _session = s;
      _engine = engine;
      _outcome = OutcomeMeter(kind);
      _tally = engine == null ? null : AtTally();
      _tracker = MeditationTracker(sessionLength);
      _seen = Detectors(onSecond: _onSecond);
      _listen(_seen!);
      _startedAt = _now();
      calPhase = 'open';
      calSecondsLeft = Cal.openS.toInt();
      await link.startSignal();
      if (!_live(run)) return await link.close(); // Stop came while the stream started
      _signalAt = _clock.now;
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(Stage.calibrating, '');
    } on TimeoutException catch (e) {
      await _fail(
        'The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.',
        run,
      );
    } catch (e) {
      await _fail('Could not start: $e', run);
    }
  }

  /// Follows where the sound goes (the setup's warning, the session's record) until [dispose].
  void watchRoute() {
    final src = audioRoute;
    if (src == null || _routeSub != null) return;
    _routeSub = src.changes.listen(_onRoute, onError: (Object _) {});
    unawaited(src.current().then(_onRoute, onError: (Object _) {}));
  }

  /// The route right before a session (unknown when the phone does not answer in [routeTimeout]).
  Future<void> _readRoute() async {
    final src = audioRoute;
    if (src == null) return;
    watchRoute();
    try {
      route = await src.current().timeout(routeTimeout);
    } catch (_) {
      route = AudioRoute.unknown;
    }
  }

  void _onRoute(AudioRoute r) {
    if (r == route) return;
    route = r;
    final s = _session;
    if (s != null && !_ended) {
      if (r.bluetooth) _bluetoothUsed = true;
      s.log.note({'event': 'audio route', 'route': r.toJson(), 'n': s.n});
    }
    _notify();
  }

  /// Ends early. With at least [minReportS] of session after calibration, the report shows what there was.
  Future<void> stop() => _finish(complete: false);

  /// Back to the length choice after a report or a failure.
  void again() {
    if (stage == Stage.rating) return;
    if (active) return;
    _set(Stage.setup, '');
  }

  /// With the check on: the next slot (the plan is frozen before the first randomised session) and, for a
  /// replay, the donors' control streams. A donor that cannot be read makes this session live instead; the
  /// record says so and the reveal counts it as a deviation.
  Future<void> _prepareCheck(Duration sessionLength, int run) async {
    final cs = checkStore, st = store;
    if (cs == null) return;
    final sessions = st?.list() ?? const <MeditationSummary>[];
    final slot = prepareSlot(cs, st == null ? const [] : donorCandidates(st, sessions), sessionLength.inSeconds.toDouble(), _now());
    _slot = slot;
    checkStatus = slot.status;
    if (slot.arm != Arm.replay || st == null) return;
    try {
      final streams = await loadStreams(st.dir, slot.donors, kind);
      if (_live(run)) _replayer = Replayer(streams, cleanSteps: cleanStepsFor(kind));
    } catch (_) {
      if (_live(run)) _replayFailed = true;
    }
  }

  Map<String, Object?> _checkInfo() => {'phase': _slot!.phase.name, if (_slot!.index != null) 'index': _slot!.index};

  void _reset(Duration sessionLength) {
    length = sessionLength;
    _startMono = _clock.now;
    _lastSave = null;
    _saving = null;
    _link = null;
    _session = null;
    _engine = null;
    _slot = null;
    _replayer = null;
    _replayFailed = false;
    _outcome = null;
    _tally = null;
    _wokeAt = -1e9;
    asleepGuard = false;
    checkStatus = null;
    _tracker = null;
    _silent = null;
    _seen = null;
    _drift = null;
    _hands = null;
    paused = false;
    _interrupted = false;
    _lostSamples = 0;
    _routeAtStart = null;
    _bluetoothUsed = false;
    _sound = null;
    _lastData = null;
    _signalAt = null;
    _lastPack = null;
    _gapPending = false;
    _ended = false;
    _quiet = false;
    chip = Moment.calibrating;
    calPhase = null;
    calNeedsClean = false;
    soundNote = null;
    saveNote = null;
    report = null;
    learning = null;
    contact = const {};
    comparison = '';
  }

  void _onBatch(DateTime _, List<Sample> batch) {
    final s = _session;
    if (s == null || _ended || batch.isEmpty) return;
    final now = _clock.now, last = _lastData;
    if (last != null && (now - last).inMicroseconds / 1e6 > gapPauseS + batch.length / fs) {
      _gapPending = true;
      _lostSamples = 0; // unknown length
    }
    _lastData = now;
    var rows = <List<double>>[];
    final steps = <AtStep>[];
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
        if (rows.isNotEmpty) steps.addAll(_push(rows));
        rows = [];
        _engine != null ? _engine!.gap() : s.gap();
        // the detectors hold the last value over the hole (as the BDF does); unknown length: one second
        _seen?.hold(_lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; the core takes µV
      rows.add(row);
      if (row.every((v) => v.isFinite)) _seen?.push(row);
    }
    steps.addAll(_push(rows));
    for (final st in steps) {
      if (_ended) break;
      _onStep(st.r, st.control);
    }
    if (_quiet) _quiet = false;
    if (now - _notifiedAt >= timing.tick) _notify();
  }

  /// The core's steps with the control each run step would play live.
  List<AtStep> _push(List<List<double>> rows) {
    final e = _engine;
    if (e != null) return e.push(rows);
    return [for (final r in _session!.push(rows)) (r: r, control: r.phase == 'run' ? meditationControl(r) : null)];
  }

  void _onStep(StepResult r, Control? live) {
    final sound = _sound!, tracker = _tracker!;
    if (r.cue == 'close-eyes') {
      sound.cue();
      calPhase = 'closed';
      _closedFromN = r.n;
      final seen = _seen;
      if (seen != null) _drift = DriftOff(seen.n ~/ fs); // lights off: the eyes close now
    } else if (r.cue == 'calibration-done') {
      sound.cue();
      sound.bed(on: !paused && !_interrupted);
      calPhase = null;
      _set(Stage.running, '');
    }
    if (r.phase == 'cal-open') {
      calSecondsLeft = math.max(0, (Cal.openS - r.n / fs).ceil());
    } else if (r.phase == 'cal-closed' && r.cue == null) {
      final left = (Cal.closedS - (r.n - _closedFromN) / fs).ceil();
      calNeedsClean = left <= 0;
      calSecondsLeft = left > 0 ? left : _session!.calibrationCleanLeft.ceil();
    } else if (r.phase == 'run' && _silent != null) {
      _silentStep(r);
    } else if (r.phase == 'run' && live != null) {
      final drift = driftState, asleep = drift == DriftState.asleep, at = kind == SessionKind.alphaTheta;
      // the same gates act whether the sound is live or replayed; in alpha-theta sleep is one of them
      final gated = live.gated || (at && asleep) || paused || _interrupted;
      final played = _replayer?.next(live, gated: gated) ??
          (gated && !live.gated ? (level: live.level, rough: live.rough, reward: null, gated: true) : live);
      sound.play(played);
      if (at) _sleepGuard(asleep, r.n / fs);
      tracker.add(r, drift: drift, level: played.level, reward: played.reward != null, coreDrowsy: !at);
      _outcome?.add(r, _session?.baseline, drift: drift);
      _tally?.add(r, played, asleep: asleep, alpha: _engine?.alpha, theta: _engine?.theta);
      chip = tracker.chip;
      if (tracker.done) silentLength > Duration.zero ? _startSilent(r) : unawaited(_finish(complete: true));
    }
  }

  /// The time with sound is over: a cue, the bed fades out, and the silent minutes begin (nothing plays in them).
  void _startSilent(StepResult r) {
    _silent = SilentMeter();
    _sound?.cue();
    _sound?.bed(on: false);
    _session?.log.note({
      'silentBlock': {'fromN': r.n, 'lengthS': silentLength.inSeconds},
    });
    _notify();
  }

  void _silentStep(StepResult r) {
    final m = _silent!, drift = driftState;
    m.add(r, _session?.baseline, drift: drift);
    chip = momentOf(r, drift: drift)?.moment ?? chip;
    if (m.seconds >= silentLength.inMilliseconds / 1000 - 1e-9) unawaited(_finish(complete: true));
  }

  /// Alpha-theta's sleep guard: "probably asleep" fades the bed (over 10 s) and plays the rising wake cue, again
  /// every minute while it lasts; awake again, the bed comes back.
  void _sleepGuard(bool asleep, double t) {
    final sound = _sound!;
    if (asleep) {
      if (!asleepGuard) {
        asleepGuard = true;
        sound.bed(on: false);
        _session?.log.note({'event': 'asleep: bed faded', 'n': _session?.n});
      }
      if (t - _wokeAt >= wakeEveryS) {
        _wokeAt = t;
        sound.wake();
      }
    } else if (asleepGuard) {
      asleepGuard = false;
      _wokeAt = -1e9;
      sound.bed(on: !_interrupted);
      _session?.log.note({'event': 'awake again: bed back', 'n': _session?.n});
    }
  }

  void _listen(Detectors seen) {
    final s = handsFree;
    if (s == null) return;
    _hands = HandsFree(s, onGesture: _gesture, tone: gestureTone?.call(), asleep: () => _drift?.state == DriftState.asleep)
      ..attach(seen);
  }

  /// A double clench in a running meditation pauses the sound or brings it back; anything else marks a moment.
  void _gesture(GestureKind g) {
    final s = _session;
    if (_ended || s == null) return;
    if (g == GestureKind.clench && kind == SessionKind.meditation && stage == Stage.running && _silent == null) {
      paused = !paused;
      _sound?.bed(on: !paused && !_interrupted);
      s.log.note({'event': 'hands-free: ${paused ? 'sound paused' : 'sound back'} (${gestureWord(g)})', 'n': s.n});
    } else {
      s.log.note({'event': 'hands-free: moment (${gestureWord(g)})', 'n': s.n});
    }
    _notify();
  }

  /// A call or another app took the sound, or gave it back (the session keeper, DECISIONS row 468): the bed goes quiet
  /// and nothing rewards meanwhile (the core goes on measuring); each change is a line in the session log.
  void audioFocus(FocusChange f) {
    if (_ended) return;
    final s = _session; // null while connecting: the change still counts, nothing to log yet
    void log(String event) => s?.log.note({'event': event, 'n': s.n});
    switch (f) {
      case FocusChange.lost || FocusChange.paused:
        if (_interrupted) return;
        _interrupted = true;
        _sound?.bed(on: false);
        log('audio focus lost: a call or another app (sound paused)');
      case FocusChange.back:
        if (!_interrupted) return;
        _interrupted = false;
        if (stage == Stage.running && _silent == null && !paused && !asleepGuard) _sound?.bed(on: true);
        log('audio focus back: sound on');
      case FocusChange.duck:
        log('audio focus: a short sound over ours');
    }
    _notify();
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
    final now = _clock.now, last = _lastData;
    final quiet = now - (last ?? _signalAt ?? now);
    if (_overTime(now - _startMono, quiet)) return;
    if (quiet > timing.noDataAfter) {
      if (!_quiet && _silent == null) {
        _quiet = true;
        final t = mapState(z: null, jaw: null, quality: 'none', veto: null);
        _sound?.play((level: kind == SessionKind.meditation ? t.calm : AtRule.startMix, rough: 0, reward: null, gated: true));
      }
    }
    _link?.tick(); // the stream that never started is restarted once (after restartStreamAfter)
    _checkpoint();
    _notify();
  }

  /// The clock limits: true when one ended the session.
  bool _overTime(Duration since, Duration quiet) {
    final String? why = since >= length + silentLength + timing.clockMargin
        ? MeditationSummary.endClock
        : stage == Stage.calibrating && since >= timing.calibrationLimit
        ? _endCalibration
        : quiet >= timing.noSignalEnd
        ? MeditationSummary.endNoSignal
        : null;
    if (why == null) return false;
    unawaited(_finish(complete: false, end: why));
    return true;
  }

  static const String _endCalibration = 'calibration';

  /// Every [MeditationTiming.saveEvery]: the session so far, its summary saying "running" (one save at a time).
  void _checkpoint() {
    final st = store, t = _tracker;
    if (st == null || t == null || _saving != null || t.runSeconds < minReportS) return;
    if (_clock.now - (_lastSave ?? _startMono) < timing.saveEvery) return;
    _lastSave = _clock.now;
    final summary = _summary(complete: false, end: MeditationSummary.endRunning);
    if (summary == null) return;
    _saving = st
        .save(summary, _session!.log)
        .catchError((Object _) {}) // storage full: the final save says so
        .whenComplete(() => _saving = null);
  }

  /// The summary of the session so far (null before there is one).
  MeditationSummary? _summary({required bool complete, String? end}) {
    final s = _session, t = _tracker, start = _startedAt;
    if (s == null || t == null || start == null) return null;
    final outcome = _outcome;
    return t.summary(
      start: start,
      complete: complete || t.done, // Stop in the silent minutes: the time with sound was reached
      iafHz: s.iaf,
      note: s.note,
      logFile: '${store?.stemFor(start) ?? fileStem(start)}.session.json',
      kind: kind,
      check: _slot == null ? null : _checkInfo(),
      outcome: outcome?.value,
      excludedShare: outcome == null ? null : (outcome.excludedShare * 1000).round() / 1000,
      at: _tally?.toJson(),
      silent: _silent?.block(silentLength.inSeconds.toDouble()),
      audioRoute: _routeAtStart != null && audioRoute != null ? _routeAtStart : null,
      bluetoothSound: _bluetoothUsed,
      end: end,
    );
  }

  /// What the shared link reports, as the session log's lines. A drop is a hole in the signal for the core.
  void _onLinkEvent(LinkEvent e, String line) {
    final s = _session;
    if (s == null) return;
    switch (e) {
      case LinkEvent.drop:
        if (_ended) return;
        _gapPending = true;
        _lastPack = null;
        s.log.note({'event': 'drop', 'n': s.n, 'at': _now().toIso8601String()});
      case LinkEvent.reconnected:
        s.log.note({'event': 'reconnected', 'n': s.n, 'at': _now().toIso8601String()});
      case LinkEvent.streamRestarted:
        s.log.note({'event': 'stream restarted', 'n': s.n});
      case LinkEvent.reconnectTry:
        break; // logged as fields by _onTry
    }
  }

  void _onTry(int tries, bool scan, bool connected) =>
      _session?.log.note({'event': 'reconnect try', 'try': tries, 'scan': scan, 'ok': connected});

  /// [end]: a clock limit's reason (MeditationSummary.end), null for the length or Stop.
  Future<void> _finish({required bool complete, String? end}) async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    final s = _session, t = _tracker, sound = _sound, start = _startedAt;
    _set(
      Stage.ending,
      complete
          ? 'Session over. Open your eyes when you like.'
          : kind == SessionKind.alphaTheta
          ? 'Stopping: the sound fades over about 10 seconds.'
          : 'Stopping.',
    );
    if (complete) sound?.cue();
    sound?.bed(on: false);
    // the session is kept first: the release (up to 30 s), the ring-out and the fade (up to 10 s) come after
    final kept = s != null && t != null && start != null && t.runSeconds >= minReportS;
    if (kept) await _keep(complete: complete, sound: sound, end: end);
    await _release();
    if (complete) await Future<void>.delayed(timing.endRingOut);
    await sound?.stop();
    if (!kept) {
      _set(Stage.setup, s == null ? '' : _notKept(end));
      return;
    }
    _set(kind == SessionKind.alphaTheta || asksGuess ? Stage.rating : Stage.report, '');
  }

  /// Why nothing was saved, for the setup page.
  String _notKept(String? end) => switch (end) {
    _endCalibration =>
      'The calibration did not get enough clean signal in ${timing.calibrationLimit.inMinutes} minutes, so the '
          'session ended and nothing was saved. Check the headband\'s contact, sit still and try again.',
    MeditationSummary.endNoSignal =>
      'The headband sent no signal for ${timing.noSignalEnd.inMinutes} minutes, so the session ended before it '
          'began and nothing was saved.',
    _ => 'Stopped before the session began, so nothing was saved.',
  };

  /// Saves the ended session (after a checkpoint still being written) and makes its report.
  Future<void> _keep({required bool complete, SessionSound? sound, String? end}) async {
    final s = _session!, t = _tracker!, start = _startedAt!;
    final st = store, stem = st?.stemFor(start) ?? fileStem(start);
    final summary = _summary(complete: complete, end: end)!;
    _seen?.finish();
    s.log.note({'sound': sound?.info(), 'end': end ?? (complete ? 'length reached' : 'stopped'), 'runS': t.runSeconds});
    final h = _hands;
    if (h != null) s.log.note({'handsFree': h.summary()});
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
        await _saving; // a checkpoint's rename must not come after the final one
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
    _keepCheckRecord(summary, stem); // first, so a set it completes is in the replay check's test below
    if (kind == SessionKind.meditation) learning = learningVerdict([...earlier, summary], tested: _silentTest());
  }

  /// The replay check's revealed test of the silent minutes (null before a set is revealed, or without one).
  SilentTest? _silentTest() {
    try {
      return silentTestOf((checkStore ?? checkResults)?.reveal());
    } catch (_) {
      return null; // the results could not be read: the verdict stands without them
    }
  }

  /// A randomised session goes into the check's records right away (before the answers), so every session is
  /// counted, with what actually played.
  void _keepCheckRecord(MeditationSummary summary, String stem) {
    final slot = _slot, cs = checkStore;
    if (slot == null || cs == null || slot.phase != SlotPhase.randomised) return;
    final played = _replayer != null ? Arm.replay : Arm.live;
    try {
      cs.add(CheckRecord(
        index: slot.index!,
        stem: stem,
        start: summary.start,
        arm: played,
        donors: played == Arm.replay ? slot.donors : const [],
        runS: summary.runS,
        outcome: summary.outcome,
        silent: summary.silent?.alpha,
        excludedShare: summary.excludedShare ?? 1,
        asleepS: (_tally?.asleepS ?? summary.drowsyS),
      ));
      if (_replayFailed) cs.event(_now(), 'a donor could not be read: the session played live', {'index': slot.index});
    } catch (e) {
      saveNote = 'The replay check could not keep this session: $e';
    }
  }

  /// The answers after the session (the check's part, when it asked), then the report.
  void submitRatings(CheckRatings? ratings) {
    if (stage != Stage.rating) return;
    final slot = _slot, cs = checkStore;
    if (ratings != null && slot?.phase == SlotPhase.randomised && cs != null) {
      try {
        cs.rate(slot!.index!, ratings);
      } catch (e) {
        saveNote = 'Your answers could not be saved: $e';
      }
    }
    _set(Stage.report, '');
  }

  /// Stops the signal and lets the headband go (only one still in range; a lost one is never touched).
  Future<void> _release() async => await _link?.close();

  /// [run]: the start that failed; one that Stop or a newer start overtook changes nothing (its headband was let go).
  Future<void> _fail(String why, int run) async {
    if (run != _run) return;
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
    _notifiedAt = _clock.now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_routeSub?.cancel());
    _routeSub = null;
    if (!_ended) unawaited(_finish(complete: false));
    super.dispose();
  }
}
