// One dream catcher session (ROADMAP row 20, DECISIONS rows 110-115): lights off, a quiet theme, and 3 or 4 rounds
// of "what is going through your mind?" as you drift off, each answer recorded; then a gentle wake tone, or the
// night recording starts by itself.
//
// Like meditation (row 75), the session is its own mode: it holds the headband from the app's screen, only between
// nights, with the screen kept on and dimmed. Its EEG is written as a normal recording (`files/recordings`, the night
// recorder's format, with the rounds as markers), so it joins that night: the morning sleep report covers the
// drift-off too, and the detector can be checked against the sleep model. The shared detectors and the drift-off
// detector (rows 85-88) see every sample; "lights off" is the first sample, whose first 60 clean, blink-free
// seconds give the eyes-closed baseline. RoundPlan (rounds.dart) says when to ask; VoiceGate (voice.dart) when an
// answer is over.
//
// Hands-free (DECISIONS 244-246): with the owner's switch on, "were you drifting?" can be answered without a tap: a
// double clench is Drifting (a nod), a look left then right is Awake (a shake of the head); at any other time either
// gesture marks a moment. Off while the drift-off detector says probably asleep, except while the question waits
// for its answer: the question has just woken you.
//
// Time: seconds after lights off are the larger of the samples received (holes held at their length) and a monotonic
// clock (session_clock.dart: a correction of the phone's clock moves nothing), so a test can stream a session in a
// fraction of a second, and a headband out of range does not stop the timers or the 45-minute cap.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../detectors/detectors.dart';
import '../detectors/drift_off.dart';
import '../detectors/gestures.dart';
import '../feedback/features.dart' show fs;
import '../handsfree/live.dart';
import '../meditation/controller.dart' show gapPauseS, gapSamples;
import '../spans/activities.dart' show activityRef;
import '../recorder/chunk_writer.dart';
import '../recorder/headband.dart';
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../session_clock.dart';
import '../session_keeper.dart' show FocusChange;
import '../sound/gesture_tone.dart';
import 'audio.dart';
import 'band_link.dart';
import 'rounds.dart';
import 'store.dart';
import 'voice.dart';

/// [baseline]: the first eyes-closed minute; [drifting]: waiting for the next round; [asking]: the question plays;
/// [answering]: your answer is recorded; [checking]: "were you drifting?".
enum DreamStage { setup, connecting, contact, baseline, drifting, asking, answering, checking, ending, done, failed }

class DreamTiming {
  const DreamTiming({
    this.link = const LinkTiming(),
    this.tick = const Duration(milliseconds: 250),
    this.noDataAfter = const Duration(seconds: 2),
    this.tapWindow = const Duration(seconds: 20),
    this.answerWall = const Duration(seconds: 33),
    this.promptMax = const Duration(seconds: 40),
    this.wakeRingOut = const Duration(seconds: 4),
    this.micTimeout = const Duration(seconds: 10),
  });

  final LinkTiming link;

  /// The screen, the file writer and the timers update this often.
  final Duration tick;

  /// No data for this long: the screen says so.
  final Duration noDataAfter;

  /// How long "were you drifting?" waits for a tap.
  final Duration tapWindow;

  /// The answer's clock deadline, should the microphone's levels stop coming (VoiceRule.capS is 30 s).
  final Duration answerWall;

  /// The longest a prompt may play.
  final Duration promptMax;

  /// After the wake tone, before the sound stops.
  final Duration wakeRingOut;

  /// The microphone's start and stop calls: a plugin stuck past this loses the answer, not the session.
  final Duration micTimeout;
}

class DreamController extends ChangeNotifier {
  DreamController({
    required this.finder,
    required DreamSound Function() sound,
    required this.mic,
    this.store,
    this.recordingsDir,
    this.startNight,
    this.timing = const DreamTiming(),
    this.gestureTone,
    DateTime Function()? clock,
    Duration Function()? monotonic,
    double Function()? random,
  }) : _makeSound = sound,
       _now = clock ?? DateTime.now,
       _clock = SessionClock(wall: clock, monotonic: monotonic),
       _random = random ?? math.Random().nextDouble;

  final SessionClock _clock;

  final HeadbandFinder finder;
  final DreamSound Function() _makeSound;
  final Mic mic;

  /// The hands-free confirmation tone (null: none).
  final GestureTone Function()? gestureTone;

  /// The owner's calibrated gestures while the hands-free switch is on (set by the screen); null: off.
  GestureSettings? handsFree;

  /// Where sessions and your prompts are kept (null: nothing saved, the tones play).
  DreamStore? store;

  /// Where the session's EEG goes (the night recorder's folder); null: not written.
  Directory? recordingsDir;

  /// With the sleep ending: starts the night recording once the headband is free; null when it started, else why not.
  Future<String?> Function()? startNight;
  final DreamTiming timing;
  final DateTime Function() _now;
  final double Function() _random;

  DreamStage stage = DreamStage.setup;

  /// One plain sentence about the stage (connecting, a failure).
  String message = '';
  int rounds = 4;
  DreamEnding ending = DreamEnding.wake;

  /// Contact at the start: ohms per channel, null = no contact.
  Map<String, double?> contact = const {};

  /// Set when the EEG or the session could not be saved, or the microphone did not record.
  String? saveNote;
  String? micNote;

  /// Nothing from the headband for a moment.
  bool noData = false;

  /// The session that just ended (shown afterwards).
  DreamSession? last;

  bool get active => stage.index >= DreamStage.connecting.index && stage.index <= DreamStage.ending.index;

  /// Rounds finished in the session running now, and the round under way (null between rounds).
  int get roundsDone => _rounds.length;
  int? roundNow;

  /// Seconds after lights off (0 before it).
  double get seconds => _lightsOffAt == null ? 0 : _t();

  /// The drift-off detector's state now (null before its baseline is complete).
  DriftState? get driftState => _drift?.state == DriftState.baseline ? null : _drift?.state;

  /// The plan of the session running now, for tests.
  @visibleForTesting
  RoundPlan? get plan => _plan;

  /// What the electrodes saw in the session running now (or the last one).
  Detectors? get seen => _seen;
  DriftOff? get drift => _drift;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _link?.leftLost ?? false;

  BandLink? _link;
  DreamSound? _sound;
  ChunkWriter? _writer;
  String? _recording;

  /// The span this session runs on as an activity of the day's recording (then it writes no EEG file of its own).
  String? _span;
  Detectors? _seen;
  DriftOff? _drift;
  RoundPlan? _plan;
  DateTime? _lightsOffAt;
  Duration? _lightsOffMono;
  final List<DreamRound> _rounds = [];
  Map<String, String> _prompts = const {};
  int _epochsSeen = 0;
  bool _baselineMarked = false;
  Timer? _ticker;
  int _ticks = 0;
  DateTime? _lastArrival;
  int? _lastPack;
  bool _gapPending = false;
  int _lostSamples = 0;
  bool _busy = false;
  bool _interrupted = false;
  Future<void>? _roundFuture;
  Completer<AnswerEnd>? _answerDone;
  Completer<bool?>? _tap;
  bool _ended = false;
  bool _disposed = false;

  /// The number of the latest start: a start that Stop or a newer start overtook touches nothing of the session
  /// (DECISIONS 450).
  int _run = 0;
  bool _live(int run) => run == _run && !_ended;

  /// Lights off: connects, checks contact, starts the sound and the EEG file, then the baseline and the rounds.
  /// Errors end in [DreamStage.failed].
  Future<void> start({int rounds = 4, DreamEnding ending = DreamEnding.wake}) async {
    if (active) return;
    _reset();
    final run = ++_run;
    this.rounds = rounds;
    this.ending = ending;
    _set(DreamStage.connecting, 'Looking for the headband.');
    final link = BandLink(finder: finder, timing: timing.link, onBatch: _onBatch, onEvent: _onLinkEvent, clock: _now);
    _link = link;
    try {
      if (!await link.connect(onFound: (name) => _set(DreamStage.connecting, 'Found $name. Connecting.'))) {
        return await _fail('Headband not found. Is it switched on and charged?', run);
      }
      if (!_live(run)) return await link.close();
      _set(DreamStage.contact, 'Checking contact. Lie still for a few seconds.');
      final ohms = await link.contact();
      if (!_live(run)) return await link.close();
      contact = ohms;
      final sound = _makeSound();
      try {
        await sound.start();
      } catch (e) {
        return await _fail('The sound did not start ($e), so the questions could not be heard.', run);
      }
      if (!_live(run)) {
        await sound.stop();
        return await link.close();
      }
      _sound = sound;
      final st = store;
      _prompts = {for (final k in PromptKind.values) k.name: st?.promptPath(k) == null ? 'tone' : 'own'};
      final earlier = st?.list() ?? const <DreamSession>[];
      _plan = RoundPlan(rounds: rounds, firstTimerS: dreamFallbackS(earlierLatenciesMin(earlier), _random()), random: _random);
      _openWriter(link.name);
      _seen = Detectors(onSecond: _onSecond);
      _listen(_seen!);
      _drift = DriftOff(0); // lights off: the first sample
      _lightsOffAt = _now();
      _lightsOffMono = _clock.now;
      await link.startSignal();
      if (!_live(run)) return await link.close(); // Stop came while the stream started
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(DreamStage.baseline, '');
      _mark('dream catcher: lights off; rounds $rounds, ending ${ending.name}, round 1 timer ${_plan!.firstTimerS} s');
      unawaited(_play(PromptKind.theme)); // the theme to drift off with
    } on TimeoutException catch (e) {
      await _fail(
        'The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.',
        run,
      );
    } catch (e) {
      await _fail('Could not start: $e', run);
    }
  }

  /// Ends now and keeps what there was (the answers so far and the EEG).
  Future<void> stop() => _finish(DreamEnd.stopped);

  /// The tap after an answer: drifting (true), awake (false).
  void drifting(bool yes) {
    final t = _tap;
    if (t != null && !t.isCompleted) t.complete(yes);
  }

  /// Back to the setup after a session or a failure.
  void again() {
    if (active) return;
    _set(DreamStage.setup, '');
  }

  void _reset() {
    _link = null;
    _sound = null;
    _writer = null;
    _recording = null;
    _span = null;
    _seen = null;
    _drift = null;
    _hands = null;
    _plan = null;
    _lightsOffAt = null;
    _lightsOffMono = null;
    _rounds.clear();
    _prompts = const {};
    _epochsSeen = 0;
    _baselineMarked = false;
    _ticks = 0;
    _lastArrival = null;
    _lastPack = null;
    _gapPending = false;
    _lostSamples = 0;
    _busy = false;
    _interrupted = false;
    _roundFuture = null;
    _answerDone = null;
    _tap = null;
    _ended = false;
    roundNow = null;
    contact = const {};
    saveNote = null;
    micNote = null;
    noData = false;
    last = null;
  }

  double _t() {
    final at = _lightsOffMono;
    if (at == null) return 0;
    final samples = (_seen?.n ?? 0) / fs;
    return math.max(samples, _clock.secondsSince(at));
  }

  // ---- the EEG file ----

  void _openWriter(String band) {
    final ref = (_link?.ridesRecorder ?? false) ? activityRef() : null;
    if (ref != null) {
      // an activity of the day's recording: its signal is that recording's samples inside the span
      _recording = ref.recording;
      _span = ref.span;
      return;
    }
    final dir = recordingsDir;
    if (dir == null) return;
    try {
      final w = ChunkWriter.open(dir, _now());
      w.log('dream catcher session; headband $band');
      w.log('contact ${[for (final e in contact.entries) '${e.key} ${e.value?.round() ?? 'none'}'].join(', ')}');
      _writer = w;
      _recording = w.stem;
    } catch (e) {
      saveNote = 'The EEG of this session could not be saved: $e';
    }
  }

  /// A line in the EEG's `.log` and a marker in its `.markers.jsonl` (an annotation in the night's BDF).
  void _mark(String text) {
    final w = _writer, dir = recordingsDir;
    if (w == null || dir == null || w.isClosed) return;
    final now = _now();
    try {
      w.log(text, at: now);
      File('${dir.path}/${w.stem}.markers.jsonl').writeAsStringSync(
        '${jsonEncode({'t': unixSeconds(now), 'i': w.samplesReceived, 'text': text})}\n',
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

  // ---- hands-free ----

  HandsFree? _hands;

  void _listen(Detectors seen) {
    final s = handsFree;
    if (s == null) return;
    _hands = HandsFree(
      s,
      onGesture: _gesture,
      tone: gestureTone?.call(),
      asleep: () => stage != DreamStage.checking && _drift?.state == DriftState.asleep,
    )..attach(seen);
  }

  /// While "were you drifting?" waits: a double clench answers Drifting, a look left then right Awake. Otherwise a
  /// moment.
  void _gesture(GestureKind kind) {
    if (_ended) return;
    final t = _tap;
    if (stage == DreamStage.checking && t != null && !t.isCompleted) {
      final yes = kind == GestureKind.clench;
      _mark('hands-free: ${yes ? 'drifting' : 'awake'} (${gestureWord(kind)})');
      drifting(yes);
    } else {
      _mark('hands-free: moment (${gestureWord(kind)})');
    }
  }

  // ---- the signal ----

  void _onLinkEvent(LinkEvent e, String line) {
    _writer?.log(line);
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
        seen.hold(_lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; the detectors take µV
      if (row.every((v) => v.isFinite)) seen.push(row);
    }
    noData = false;
    _check();
  }

  /// Each whole second from the detectors (one second late): the drift-off detector's input, then its new epochs
  /// for the round plan.
  void _onSecond(Second sec) {
    final d = _drift, plan = _plan;
    if (d == null || plan == null) return;
    final a = sec.backAlpha;
    d.second(sec.k, a.alpha, a.clean, sec.movement, sec.sem, sec.blinks);
    for (; _epochsSeen < d.epochs.length; _epochsSeen++) {
      final e = d.epochs[_epochsSeen];
      plan.epoch(e.start, e.state);
    }
    if (!_baselineMarked && d.baselineDone != null) {
      _baselineMarked = true;
      _mark('dream catcher: eyes-closed baseline done');
      if (stage == DreamStage.baseline) _set(DreamStage.drifting, '');
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
    noData = last != null && _now().difference(last) > timing.noDataAfter;
    _check();
    _notify();
  }

  /// A call or another app took the sound, or gave it back (the session keeper, DECISIONS row 468): no question is
  /// asked meanwhile (an answer would record the call); each change is a marker in the recording.
  void audioFocus(FocusChange f) {
    if (_ended) return;
    switch (f) {
      case FocusChange.lost || FocusChange.paused:
        if (_interrupted) return;
        _interrupted = true;
        _mark('dream catcher: audio focus lost: a call or another app (no question until it is back)');
      case FocusChange.back:
        if (!_interrupted) return;
        _interrupted = false;
        _mark('dream catcher: audio focus back');
        _check();
      case FocusChange.duck:
        _mark('dream catcher: audio focus: a short sound over ours');
    }
  }

  // ---- rounds ----

  void _check() {
    final plan = _plan;
    if (plan == null || _ended || _lightsOffAt == null) return;
    final t = _t();
    if (t >= DreamRule.capS) {
      // the cap first, also while a round runs: a round that hangs must not hold the session past it
      unawaited(_finish(plan.done >= plan.rounds ? DreamEnd.rounds : DreamEnd.cap));
      return;
    }
    if (_busy) return;
    if (plan.over(t)) {
      unawaited(_finish(plan.done >= plan.rounds ? DreamEnd.rounds : DreamEnd.cap));
      return;
    }
    if (_interrupted) return; // no question during a call
    final cause = plan.due(t, driftState);
    if (cause == null) return;
    _busy = true;
    plan.start();
    _roundFuture = _round(cause, t);
  }

  Future<void> _round(DreamCause cause, double atS) async {
    final plan = _plan!, n = plan.done + 1, at = _now();
    final state = _drift?.state.name ?? DriftState.baseline.name;
    roundNow = n;
    _mark('dream round $n: question (${cause == DreamCause.drowsy ? 'alpha faded' : 'timer'}, detector $state)');
    _set(DreamStage.asking, '');
    await _play(PromptKind.question);
    var answer = (file: null as String?, secs: 0.0, voice: 0.0, end: AnswerEnd.stopped);
    if (!_ended) {
      _set(DreamStage.answering, '');
      answer = await _answer(n);
      _mark('dream round $n: answer ${answer.secs.toStringAsFixed(1)} s (${answer.end.name})');
    }
    bool? drifting;
    if (!_ended) {
      final tap = _tap = Completer<bool?>();
      _set(DreamStage.checking, '');
      drifting = await tap.future.timeout(timing.tapWindow, onTimeout: () => null);
      _tap = null;
      _mark('dream round $n: drifting ${drifting == null ? 'not answered' : drifting ? 'yes' : 'no'}');
    }
    final end = _t();
    _rounds.add(
      DreamRound(
        n: n,
        atS: atS,
        at: at,
        cause: cause,
        state: state,
        answerFile: answer.file,
        answerS: answer.secs,
        voiceS: answer.voice,
        end: answer.end,
        drifting: drifting,
        endS: end,
      ),
    );
    roundNow = null;
    plan.finish(end, signalS: (_seen?.n ?? 0) / fs);
    if (_ended) {
      _busy = false;
      return; // the end saves the session with this round
    }
    _saveSession(end, DreamEnd.running);
    // "You can drift off again": the theme once more, unless the session wakes you now
    if (!plan.over(end) || ending == DreamEnding.sleep) {
      _set(DreamStage.drifting, '');
      await _play(PromptKind.theme);
    }
    _busy = false;
    _check();
  }

  /// Records round [n]'s answer until VoiceGate says it is over (or Stop).
  Future<({String? file, double secs, double voice, AnswerEnd end})> _answer(int n) async {
    final st = store;
    if (st == null) return (file: null, secs: 0.0, voice: 0.0, end: AnswerEnd.failed);
    final f = st.answerFile(fileStem(_lightsOffAt!), n);
    final gate = VoiceGate(), done = _answerDone = Completer<AnswerEnd>();
    StreamSubscription<double>? sub;
    var end = AnswerEnd.failed;
    try {
      st.dir.createSync(recursive: true);
      await mic.start(f.path).timeout(timing.micTimeout);
      sub = mic.levels.listen((db) {
        final e = gate.add(db);
        if (e != null && !done.isCompleted) done.complete(e);
      });
      end = await done.future.timeout(timing.answerWall, onTimeout: () => AnswerEnd.cap);
    } catch (e) {
      micNote = 'The microphone did not record: $e';
    } finally {
      _answerDone = null;
      await sub?.cancel();
      try {
        await mic.stop().timeout(timing.micTimeout);
      } catch (_) {}
    }
    final kept = f.existsSync() && f.lengthSync() > 44;
    return (
      file: kept ? f.uri.pathSegments.last : null,
      secs: kept ? (wavSeconds(f) ?? gate.seconds) : 0.0,
      voice: gate.voiceSeconds,
      end: kept ? end : AnswerEnd.failed,
    );
  }

  Future<void> _play(PromptKind kind) async {
    final s = _sound;
    if (s == null || _ended) return;
    try {
      await s.prompt(kind, store?.promptPath(kind)).timeout(timing.promptMax);
    } catch (_) {}
  }

  // ---- the end ----

  Future<void> _finish(String why) async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    final lightsOff = _lightsOffAt;
    if (lightsOff == null) {
      // stopped while connecting: nothing to keep
      await _release();
      await _sound?.stop();
      _set(DreamStage.setup, '');
      return;
    }
    final endS = _t();
    final a = _answerDone;
    if (a != null && !a.isCompleted) a.complete(AnswerEnd.stopped);
    final tap = _tap;
    if (tap != null && !tap.isCompleted) tap.complete(null);
    final r = _roundFuture;
    if (_busy && r != null) await r.timeout(const Duration(seconds: 15), onTimeout: () {});
    _set(DreamStage.ending, why == DreamEnd.stopped ? 'Stopping.' : 'Session over.');
    if (why != DreamEnd.stopped && ending == DreamEnding.wake) {
      _sound?.wake();
      await Future<void>.delayed(timing.wakeRingOut);
    }
    final h = _hands;
    if (h != null) _mark('hands-free: ${h.heard} gestures acted on, ${h.ignoredAsleep} ignored while probably asleep');
    _mark('dream catcher: end ($why)');
    _seen?.finish();
    _closeWriter();
    await _release();
    await _sound?.stop();
    String? night;
    final starter = startNight;
    if (ending == DreamEnding.sleep && why != DreamEnd.stopped && starter != null) {
      try {
        night = await starter() ?? 'started';
      } catch (e) {
        night = 'did not start: $e';
      }
    }
    last = _saveSession(endS, why, night: night);
    _set(DreamStage.done, '');
  }

  DreamSession _saveSession(double endS, String why, {String? night}) {
    final d = _drift, plan = _plan!;
    final s = DreamSession(
      start: _lightsOffAt!,
      plannedRounds: rounds,
      ending: ending,
      prompts: _prompts,
      recording: _recording,
      span: _span,
      firstTimerS: plan.firstTimerS,
      baselineS: d?.baselineDone,
      rounds: List.of(_rounds),
      endS: endS,
      endWhy: why,
      drift: d == null ? const {} : _driftSummary(d),
      night: night,
    );
    final st = store;
    if (st != null) {
      try {
        st.save(s);
      } catch (e) {
        saveNote = 'This session could not be saved: $e';
      }
    }
    return s;
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

  Future<void> _release() async {
    await _link?.close();
  }

  /// [run]: the start that failed; one that Stop or a newer start overtook changes nothing (its headband was let go).
  Future<void> _fail(String why, int run) async {
    if (run != _run) return;
    final stoppedByUser = _ended;
    _ended = true;
    _ticker?.cancel();
    _closeWriter();
    await _release();
    await _sound?.stop();
    if (!stoppedByUser) _set(DreamStage.failed, why);
  }

  void _set(DreamStage s, String text) {
    stage = s;
    message = text;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (active) unawaited(_finish(DreamEnd.stopped));
    _disposed = true;
    super.dispose();
  }
}
