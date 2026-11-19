// One sound-for-states session (ROADMAP rows 17-18, DECISIONS rows 130-139): pick a state and a sound; with the
// headband, a quiet minute first and then what the brain does during the sound; for "fall asleep", the sound fades out
// once the drift-off detector says probably asleep, and is silent 45 minutes after lights off whatever it says.
// Without the headband (none, not found, or busy recording the night) the sound runs on its timer alone.
//
// Like the meditation and the dream catcher (rows 75, 110), a session with the headband holds it from the app's
// screen, only between nights. The shared detectors (rows 85-88) see every sample: their clean seconds feed the
// readout (readout.dart), and for "fall asleep" the drift-off detector, whose lights off is the first sample. Only
// "fall asleep" keeps its EEG, as a normal recording in `files/recordings` with the events as markers, so it joins
// that night (and may start the night recording when the sound has stopped, like the dream catcher's sleep ending).
//
// With the phone locked the session goes on: a [SessionKeeper] (the phone's foreground service, DECISIONS rows
// 190-193) is held from Start until the headband is let go and, for "fall asleep, then the night", until the night
// recording has started, so the app is never without a service in between.
//
// Hands-free (DECISIONS 244-246): with the owner's switch on, a double clench pauses the sound and the next one brings
// it back, and a look left then right marks a moment (as a double clench does when there is no sound to pause); each
// with a soft tone, never while the drift-off detector says probably asleep.
//
// Time: seconds after lights off are the larger of the samples received (holes held at their length) and a monotonic
// clock (session_clock.dart: a correction of the phone's clock moves nothing), so a test can stream a session in a
// fraction of a second, and a headband out of range does not stop the timers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../detectors/detectors.dart';
import '../detectors/drift_off.dart';
import '../detectors/gestures.dart';
import '../dream/band_link.dart';
import '../feedback/features.dart' show fs;
import '../handsfree/live.dart';
import '../meditation/controller.dart' show gapPauseS, gapSamples;
import '../recorder/chunk_writer.dart';
import '../recorder/headband.dart';
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../session_clock.dart';
import '../session_keeper.dart';
import '../sound/audio_route.dart';
import '../sound/gesture_tone.dart';
import '../sound/state_sound.dart';
import 'presets.dart';
import 'readout.dart';
import 'store.dart';
import 'timers.dart';

/// [quiet]: the silent quiet minute; [starting]: the sound is being made; [fading]: on its way to silence.
enum SoundStage { setup, connecting, contact, quiet, starting, playing, fading, ending, done, failed }

class StatesTiming {
  const StatesTiming({
    this.link = const LinkTiming(),
    this.tick = const Duration(milliseconds: 250),
    this.noDataAfter = const Duration(seconds: 2),
    this.quietCleanS = 60,
    this.quietMaxS = 120,
    this.saveEvery = const Duration(seconds: 60),
  });

  final LinkTiming link;
  final Duration tick;
  final Duration noDataAfter;

  /// The session file is rewritten this often from lights off (so a killed app keeps the session so far).
  final Duration saveEvery;

  /// The quiet minute ends once it has this many clean seconds, or after [quietMaxS] whatever it has.
  final int quietCleanS;
  final int quietMaxS;
}

class StatesController extends ChangeNotifier {
  StatesController({
    required this.finder,
    required StateSound Function() sound,
    this.store,
    this.recordingsDir,
    this.startNight,
    this.keeper,
    this.timing = const StatesTiming(),
    this.gestureTone,
    this.audioRoute,
    this.routeTimeout = const Duration(seconds: 2),
    DateTime Function()? clock,
    Duration Function()? monotonic,
  }) : _makeSound = sound,
       _now = clock ?? DateTime.now,
       _clock = SessionClock(wall: clock, monotonic: monotonic);

  final HeadbandFinder finder;
  final StateSound Function() _makeSound;
  final SessionClock _clock;

  /// The hands-free confirmation tone (null: none).
  final GestureTone Function()? gestureTone;

  /// The owner's calibrated gestures while the hands-free switch is on (set by the screen); null: off.
  GestureSettings? handsFree;

  /// The sound is paused by a double clench.
  bool paused = false;

  /// A call or another app has the sound now ([audioFocus]): the sound is paused until it is back.
  bool _interrupted = false;

  /// Where the sound goes (null: not known, nothing recorded); [route] is the latest answer (DECISIONS 470).
  final AudioRouteSource? audioRoute;
  final Duration routeTimeout;
  AudioRoute route = AudioRoute.unknown;
  AudioRoute? _routeAtStart;
  StreamSubscription<AudioRoute>? _routeSub;

  /// Where sessions are kept (null: nothing saved).
  SoundStore? store;

  /// Where "fall asleep"'s EEG goes (the night recorder's folder); null: not written.
  Directory? recordingsDir;

  /// Starts the night recording once the headband is free; null when it started, else why not.
  Future<String?> Function()? startNight;

  /// Keeps the session alive with the phone locked (null: nothing does, the screen must stay on).
  final SessionKeeper? keeper;
  final StatesTiming timing;
  final DateTime Function() _now;

  SoundStage stage = SoundStage.setup;

  /// One plain sentence about the stage (connecting, a fallback, a failure).
  String message = '';
  SoundPlan? plan;

  /// [HeadbandUse] of the session running now.
  String headband = HeadbandUse.soundOnly;

  /// "Fall asleep" with the headband: start the night recording once the sound is silent.
  bool thenNight = false;
  Map<String, double?> contact = const {};
  String? saveNote;
  bool noData = false;

  /// The phone may be locked: the keeper holds this session.
  bool canLock = false;

  /// The session that just ended.
  SoundSession? last;

  bool get active => stage.index >= SoundStage.connecting.index && stage.index <= SoundStage.ending.index;

  /// Seconds after lights off (0 before it).
  double get seconds => _lightsOffAt == null ? 0 : _t();

  /// Seconds of sound so far (null before the sound).
  double? get soundSeconds => _soundStartS == null ? null : math.max(0, seconds - _soundStartS!);

  /// Seconds until the sound is silent, by the plan and (fall asleep) the detector.
  double? get secondsLeft {
    final s = _stop();
    return s == null ? null : math.max(0, s.offAtS - seconds);
  }

  /// The beat's rate now (null without a beat or before the sound).
  double? get rateNow {
    final p = plan, t = soundSeconds;
    return p == null || t == null ? null : p.rateAt(t);
  }

  /// Clean seconds of the quiet minute so far.
  int get quietS => _readout?.baselineS ?? 0;

  /// The last 30 s against the quiet minute (null without one, or too few clean seconds).
  ReadSummary? get live => _readout?.live;
  bool get hasBaseline => _readout?.hasBaseline ?? false;

  /// The drift-off detector's state (fall asleep with the headband; null before its baseline).
  DriftState? get driftState => _drift?.state == DriftState.baseline ? null : _drift?.state;

  /// Why the sound is fading or stopped (null before).
  StopWhy? get stopWhy => _stopWhy;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _link?.leftLost ?? false;

  BandLink? _link;
  StateSound? _sound;
  ChunkWriter? _writer;
  String? _recording;
  Detectors? _seen;
  SpectrumFeed? _feed;
  Readout? _readout;
  DriftOff? _drift;
  HandsFree? _hands;
  DateTime? _lightsOffAt;
  Duration? _lightsOffMono;
  int? _soundStartS;
  int? _soundStartK;
  int? _fadeFromS;
  int? _offAtS;
  StopWhy? _stopWhy;
  final List<SoundEvent> _events = [];
  TrialTag? _trial;
  Timer? _ticker;
  int _ticks = 0;
  Duration? _lastSave;
  DateTime? _lastArrival;
  int? _lastPack;
  bool _gapPending = false;
  int _lostSamples = 0;
  List<double>? _lastRow;
  bool _starting = false;
  bool _ended = false;
  bool _disposed = false;

  /// The number of the latest start: a start that Stop or a newer start overtook touches nothing of the session
  /// (DECISIONS 450).
  int _run = 0;
  bool _live(int run) => run == _run && !_ended;

  /// Starts a session of [plan]. [useHeadband]: connect and measure (falls back to the sound alone if the headband is
  /// not found); [why]: the [HeadbandUse] when the headband is not used; [trial]: the fair test this session is
  /// played for (saved with it). Errors end in [SoundStage.failed].
  Future<void> start(
    SoundPlan plan, {
    bool useHeadband = true,
    String why = HeadbandUse.soundOnly,
    bool thenNight = false,
    TrialTag? trial,
  }) async {
    if (active) return;
    _reset();
    final run = ++_run;
    this.plan = plan;
    _trial = trial;
    this.thenNight = thenNight && useHeadband && plan.state == SoundState.asleep;
    headband = useHeadband ? HeadbandUse.used : why;
    _set(useHeadband ? SoundStage.connecting : SoundStage.starting, useHeadband ? 'Looking for the headband.' : '');
    await _readRoute();
    if (!_live(run)) return;
    _routeAtStart = audioRoute == null ? null : route;
    await _keep(plan, useHeadband, run);
    if (!_live(run)) return; // stopped meanwhile
    if (!useHeadband) return _soundOnly(why, '');
    final link = BandLink(finder: finder, timing: timing.link, onBatch: _onBatch, onEvent: _onLinkEvent, clock: _now);
    _link = link;
    try {
      if (!await link.connect(onFound: (name) => _set(SoundStage.connecting, 'Found $name. Connecting.'))) {
        if (!_live(run)) return;
        _link = null;
        return await _soundOnly(HeadbandUse.notFound, 'Headband not found, so the sound plays by its timer alone.');
      }
      if (!_live(run)) return await link.close();
      _set(SoundStage.contact, 'Checking contact. Keep still for a few seconds.');
      final ohms = await link.contact();
      if (!_live(run)) return await link.close();
      contact = ohms;
      if (plan.state == SoundState.asleep) _openWriter(link.name);
      _seen = Detectors(onSecond: _onSecond);
      _listen(_seen!);
      _feed = SpectrumFeed();
      _readout = Readout();
      if (plan.state == SoundState.asleep) _drift = DriftOff(0); // lights off: the first sample
      _lightsOff();
      await link.startSignal();
      if (!_live(run)) return await link.close(); // Stop came while the stream started
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _event('quiet minute (${plan.preset.eyesClosed ? 'eyes closed' : 'eyes open'})');
      _set(SoundStage.quiet, '');
    } on TimeoutException catch (e) {
      await _fail(
        'The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.',
        run,
      );
    } catch (e) {
      await _fail('Could not start: $e', run);
    }
  }

  /// Follows where the sound goes (the setup's line, the session's record) until [dispose].
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
    if (_disposed || r == route) return;
    route = r;
    if (_lightsOffAt != null && active) _event('audio route: ${routeWords(r)}');
    _notify();
  }

  /// Asks the keeper to hold this session, so the phone can be locked; Stop on its notification ends the session.
  Future<void> _keep(SoundPlan plan, bool useHeadband, int run) async {
    final k = keeper;
    if (k == null) return;
    k.onStop = () => unawaited(stop());
    k.onFocus = audioFocus;
    bool kept;
    try {
      kept = await k.hold(KeepSpec(title: plan.preset.name, text: 'Sound session · ${plan.line}', headband: useHeadband));
    } catch (_) {
      kept = false;
    }
    if (run != _run) return; // a newer start holds the service itself
    canLock = kept;
    _notify();
  }

  Future<void> _letGo() async {
    try {
      await keeper?.release();
    } catch (_) {}
  }

  /// Starts the sound now, without the rest of the quiet minute.
  void skipQuiet() {
    if (stage == SoundStage.quiet) {
      _event('quiet minute skipped');
      unawaited(_startSound());
    }
  }

  /// Ends now (the sound fades over 3 s) and keeps what there was.
  Future<void> stop() => _finish(SoundEnd.stopped);

  /// Your answer afterwards (1-5) for the session that just ended; saved at once.
  void rate(int value) {
    final s = last;
    if (s == null || value < 1 || value > 5) return;
    s.rating = value;
    _save(s);
    _notify();
  }

  /// Back to the setup after a session or a failure.
  void again() {
    if (active) return;
    _set(SoundStage.setup, '');
  }

  void _reset() {
    _link = null;
    _sound = null;
    _writer = null;
    _recording = null;
    _seen = null;
    _feed = null;
    _readout = null;
    _drift = null;
    _hands = null;
    paused = false;
    _interrupted = false;
    _lightsOffAt = null;
    _lightsOffMono = null;
    _soundStartS = null;
    _soundStartK = null;
    _fadeFromS = null;
    _offAtS = null;
    _stopWhy = null;
    _events.clear();
    _trial = null;
    _ticks = 0;
    _lastSave = null;
    _lastArrival = null;
    _lastPack = null;
    _gapPending = false;
    _lostSamples = 0;
    _lastRow = null;
    _starting = false;
    _ended = false;
    contact = const {};
    saveNote = null;
    noData = false;
    last = null;
    headband = HeadbandUse.soundOnly;
    canLock = false;
  }

  Future<void> _soundOnly(String why, String note) async {
    headband = why;
    _lightsOff();
    _ticker = Timer.periodic(timing.tick, (_) => _tick());
    message = note;
    await _startSound(note: note);
  }

  void _lightsOff() {
    _lightsOffAt = _now();
    _lightsOffMono = _clock.now;
  }

  double _t() {
    final at = _lightsOffMono;
    if (at == null) return 0;
    final samples = (_seen?.n ?? 0) / fs;
    return math.max(samples, _clock.secondsSince(at));
  }

  // ---- the sound ----

  Future<void> _startSound({String note = ''}) async {
    if (_starting || _ended || _soundStartS != null) return;
    final run = _run;
    _starting = true;
    _set(SoundStage.starting, note);
    final sound = _makeSound();
    try {
      await sound.start(plan!);
    } catch (e) {
      return _fail('The sound did not start ($e).', run);
    }
    if (!_live(run)) {
      await sound.stop(seconds: 0.2);
      return;
    }
    _sound = sound;
    _soundStartS = _t().floor();
    _soundStartK = (_seen?.n ?? 0) ~/ fs;
    if (_interrupted) sound.pause(on: true); // a call came while the sound was being made
    _event('sound on: ${plan!.line}');
    _set(SoundStage.playing, note);
    _saveRunning();
  }

  SoundStop? _stop() {
    final p = plan, s0 = _soundStartS;
    if (p == null || s0 == null) return null;
    if (_fadeFromS != null) return SoundStop(_fadeFromS!, _offAtS!, _stopWhy!);
    return soundStop(p, soundStartS: s0, asleepAtS: _drift?.asleepAt);
  }

  void _check() {
    if (_ended || _lightsOffAt == null) return;
    final t = _t();
    if (stage == SoundStage.quiet) {
      if (quietS >= timing.quietCleanS || t >= timing.quietMaxS) unawaited(_startSound());
      return;
    }
    final s = _stop();
    if (s == null || _sound == null) return;
    if (stage == SoundStage.playing && t >= s.fadeFromS) {
      _fadeFromS = s.fadeFromS;
      _offAtS = s.offAtS;
      _stopWhy = s.why;
      _sound!.fadeOut(math.max(1, s.offAtS - t));
      _event(switch (s.why) {
        StopWhy.asleep => 'probably asleep: fading out',
        StopWhy.cap => '45 minutes after lights off: fading out',
        StopWhy.time => 'time: fading out',
      });
      _set(SoundStage.fading, '');
    }
    if (stage == SoundStage.fading && t >= s.offAtS) {
      unawaited(_finish(switch (s.why) {
        StopWhy.asleep => SoundEnd.asleep,
        StopWhy.cap => SoundEnd.cap,
        StopWhy.time => SoundEnd.time,
      }));
    }
  }

  // ---- hands-free ----

  void _listen(Detectors seen) {
    final s = handsFree;
    if (s == null) return;
    _hands = HandsFree(s, onGesture: _gesture, tone: gestureTone?.call(), asleep: () => _drift?.state == DriftState.asleep)
      ..attach(seen);
  }

  /// A double clench while the sound plays pauses it or brings it back; anything else marks a moment.
  void _gesture(GestureKind kind) {
    if (_ended) return;
    final sound = _sound;
    if (kind == GestureKind.clench && sound != null && stage == SoundStage.playing) {
      paused = !paused;
      sound.pause(on: paused || _interrupted);
      _event('hands-free: ${paused ? 'sound paused' : 'sound back'} (${gestureWord(kind)})');
    } else {
      _event('hands-free: moment (${gestureWord(kind)})');
    }
    _notify();
  }

  /// A call or another app took the sound, or gave it back (the session keeper, DECISIONS row 468): the sound pauses
  /// meanwhile (its timers go on); each change is an event in the session file.
  void audioFocus(FocusChange f) {
    if (_ended) return;
    switch (f) {
      case FocusChange.lost || FocusChange.paused:
        if (_interrupted) return;
        _interrupted = true;
        _sound?.pause(on: true);
        _event('audio focus lost: a call or another app (sound paused)');
      case FocusChange.back:
        if (!_interrupted) return;
        _interrupted = false;
        _sound?.pause(on: paused);
        _event('audio focus back: sound on');
      case FocusChange.duck:
        _event('audio focus: a short sound over ours');
    }
    _notify();
  }

  // ---- the EEG file (fall asleep) ----

  void _openWriter(String band) {
    final dir = recordingsDir;
    if (dir == null) return;
    try {
      final w = ChunkWriter.open(dir, _now());
      w.log('sound for states session (${plan!.preset.name}); headband $band');
      w.log('contact ${[for (final e in contact.entries) '${e.key} ${e.value?.round() ?? 'none'}'].join(', ')}');
      _writer = w;
      _recording = w.stem;
    } catch (e) {
      saveNote = 'The EEG of this session could not be saved: $e';
    }
  }

  /// An event in the session file and, with an EEG file, a line in its `.log` and a marker in `.markers.jsonl`.
  void _event(String text) {
    _events.add((s: _t().floor(), text: text));
    final w = _writer, dir = recordingsDir;
    if (w == null || dir == null || w.isClosed) return;
    final now = _now();
    try {
      w.log('sound: $text', at: now);
      File('${dir.path}/${w.stem}.markers.jsonl').writeAsStringSync(
        '${jsonEncode({'t': unixSeconds(now), 'i': w.samplesReceived, 'text': 'sound: $text'})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  void _writeFiles({bool sync = false}) {
    final w = _writer;
    if (w == null) return;
    try {
      sync ? w.sync() : w.append();
    } catch (e) {
      saveNote = 'The EEG stopped saving: $e';
      try {
        w.close();
      } catch (_) {}
      _writer = null;
    }
  }

  // ---- the signal ----

  void _onLinkEvent(LinkEvent e, String line) {
    _writer?.log(line);
    if (e == LinkEvent.drop) _event('headband dropped out; reconnecting');
    if (e == LinkEvent.reconnected) _event('headband reconnected');
    if (e == LinkEvent.reconnected || e == LinkEvent.drop) {
      _lastPack = null;
      _gapPending = true;
    }
  }

  void _onBatch(DateTime now, List<Sample> batch) {
    final seen = _seen;
    if (seen == null || _ended) return;
    _writer?.addBatch(now, batch);
    final last = _lastArrival;
    if (last != null && now.difference(last).inMicroseconds / 1e6 > gapPauseS + batch.length / fs) {
      _gapPending = true;
      _lostSamples = 0; // unknown length
    }
    _lastArrival = now;
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
        // the detectors hold the last value over the hole (as the BDF does); unknown length: one second
        _hold(_lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; the detectors take µV
      if (!row.every((v) => v.isFinite)) continue;
      seen.push(row);
      _feed?.push(row[0], row[1]);
      _lastRow = row;
    }
    noData = false;
    _check();
  }

  /// A hole: the detectors and the spectra both get the last row again, so their seconds stay in step.
  void _hold(int samples) {
    final row = _lastRow, seen = _seen;
    if (row == null || seen == null) return;
    seen.hold(samples);
    for (var i = 0; i < samples; i++) {
      _feed?.push(row[0], row[1]);
    }
  }

  /// Each whole second from the detectors (one second late): the drift-off detector, then the readout.
  void _onSecond(Second sec) {
    final a = sec.backAlpha;
    _drift?.second(sec.k, a.alpha, a.clean, sec.movement, sec.sem, sec.blinks);
    final p = _feed?.take(sec), r = _readout;
    if (p == null || r == null) return;
    final k0 = _soundStartK;
    if (k0 == null) {
      if (stage == SoundStage.quiet) r.quiet(p);
    } else if (sec.k >= k0) {
      r.sound(sec.k - k0, p, plan!.rateAt((sec.k - k0).toDouble()));
    }
  }

  void _tick() {
    if (_ended) return;
    _link?.tick();
    _ticks++;
    final perSecond = math.max(1, 1000 ~/ timing.tick.inMilliseconds);
    if (_ticks % (10 * perSecond) == 0) {
      _writeFiles(sync: true);
    } else if (_ticks % perSecond == 0) {
      _writeFiles();
    }
    final last = _link?.lastData;
    noData = _link != null && last != null && _now().difference(last) > timing.noDataAfter;
    _check();
    final saved = _lastSave;
    if (!_ended && (saved == null || _clock.now - saved >= timing.saveEvery)) _saveRunning();
    _notify();
  }

  // ---- the end ----

  Future<void> _finish(String why) async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    final lightsOff = _lightsOffAt;
    if (lightsOff == null) {
      // stopped while connecting: nothing to keep
      await _link?.close();
      await _letGo();
      _set(SoundStage.setup, '');
      return;
    }
    final endS = _t();
    final h = _hands;
    if (h != null) _event('hands-free: ${h.heard} gestures acted on, ${h.ignoredAsleep} ignored while probably asleep');
    _set(SoundStage.ending, why == SoundEnd.stopped ? 'Stopping.' : '');
    _event(switch (why) {
      SoundEnd.stopped => 'stopped',
      SoundEnd.asleep => 'silent (probably asleep)',
      SoundEnd.cap => 'silent (45 minutes after lights off)',
      _ => 'silent (time)',
    });
    final sound = _sound;
    if (sound != null) await sound.stop(seconds: why == SoundEnd.stopped ? stopFadeS : 0.2);
    _seen?.finish();
    _closeWriter();
    await _link?.close();
    String? night;
    final starter = startNight;
    if (thenNight && why != SoundEnd.stopped && starter != null) {
      try {
        night = await starter() ?? 'started';
      } catch (e) {
        night = 'did not start: $e';
      }
    }
    await _letGo(); // only now: the night recorder's own service (if any) is already up
    final s = _session(endS, why, night: night);
    _save(s);
    last = s;
    _set(SoundStage.done, '');
  }

  SoundSession _session(double endS, String why, {String? night}) {
    final d = _drift, r = _readout;
    final lost = headband == HeadbandUse.used && (_seen?.n ?? 0) == 0;
    return SoundSession(
      start: _lightsOffAt!,
      plan: plan!,
      headband: lost ? HeadbandUse.lost : headband,
      contact: contact,
      recording: _recording,
      soundStartS: _soundStartS,
      baselineS: r?.baselineS ?? 0,
      fadeFromS: _fadeFromS,
      offAtS: _offAtS,
      endS: endS,
      end: why,
      drift: d == null ? const {} : _driftSummary(d),
      epochs: r?.epochs ?? const [],
      summary: r?.summary,
      events: List.of(_events),
      stalls: _sound?.stalls ?? 0,
      engine: _sound?.info() ?? const {},
      night: night,
      trial: _trial,
      audioRoute: _routeAtStart,
    );
  }

  /// The session so far, written at lights off, when the sound starts and every [StatesTiming.saveEvery], so a
  /// session cut short by the phone still leaves a file with its sound time and events.
  void _saveRunning() {
    _lastSave = _clock.now;
    _save(_session(_t(), SoundEnd.running));
  }

  void _save(SoundSession s) {
    final st = store;
    if (st == null) return;
    try {
      st.save(s);
    } catch (e) {
      saveNote = 'This session could not be saved: $e';
    }
  }

  static Map<String, Object?> _driftSummary(DriftOff d) => {
    'baselineAlpha': d.baselineAlpha,
    'baselineS': d.baselineDone,
    'drowsyS': d.drowsyAt,
    'onsetS': d.onset,
    'asleepAtS': d.asleepAt,
    'epochs': [
      for (final e in d.epochs)
        e.faded == null
            ? (e.state == DriftState.baseline ? 'b' : '-')
            : switch (e.state) {
                DriftState.baseline => 'b',
                DriftState.awake => 'a',
                DriftState.drowsy => 'd',
                DriftState.asleep => 's',
              },
    ].join(),
  };

  void _closeWriter() {
    final w = _writer;
    if (w == null) return;
    try {
      w.close();
    } catch (e) {
      saveNote = 'The EEG could not be closed cleanly: $e';
    }
  }

  /// [run]: the start that failed; one that Stop or a newer start overtook changes nothing (its headband was let go).
  Future<void> _fail(String why, int run) async {
    if (run != _run) return;
    final stoppedByUser = _ended;
    _ended = true;
    _ticker?.cancel();
    _closeWriter();
    await _link?.close();
    await _sound?.stop(seconds: 0.2);
    await _letGo();
    if (!stoppedByUser) _set(SoundStage.failed, why);
  }

  void _set(SoundStage s, String text) {
    stage = s;
    message = text;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (active) unawaited(_finish(SoundEnd.stopped));
    _disposed = true;
    unawaited(_routeSub?.cancel());
    _routeSub = null;
    super.dispose();
  }
}
