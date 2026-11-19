// One nap coach session (ROADMAP "Nap coach", DECISIONS rows 173-177): Lights off, then a nap that ends before deep
// sleep starts or at the length you picked, whichever comes first, with a soft rising wake cue; then a short report
// (time to fall asleep, the stages, why it woke you).
//
// Like the dream catcher (row 110) it is its own mode: it holds the headband from the app's screen, only between
// nights, with the screen kept on and dimmed. Its EEG is written as a normal recording (`files/recordings`, with
// markers), so it joins that day's "night", is scored in full afterwards and exported. Every sample goes to the
// shared detectors and the drift-off detector (rows 85-88: "asleep" time) and to the live scorer
// (sleep/live_stager.dart: AnySleep every 30 s on the last 60 minutes, the stage 2 minutes behind). The length
// always ends the nap, so it works on the timer alone when the model is too slow or the signal is lost, and the
// screen says so. The night recorder's service is never touched (row 177).
//
// Hands-free (DECISIONS 244-246): with the owner's switch on, a double clench or a look left then right marks a
// moment in the nap's recording, with a soft tone; never while the drift-off detector says probably asleep.
//
// Time: seconds after lights off are the larger of the samples received (holes held at their length) and the clock,
// so a test can stream a nap in a fraction of a second, and a headband out of range does not stop the timer.
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
import '../sleep/live_stager.dart';
import '../sound/gesture_tone.dart';
import '../sleep/periods.dart' show gapStage;
import 'audio.dart';
import 'rules.dart';
import 'store.dart';

/// [resting]: lights off until the wake (the first minute is the eyes-closed baseline); [waking]: the cue rises
/// until "I'm awake".
enum NapStage { setup, connecting, contact, resting, waking, done, failed }

/// What the sleep model is doing, for the screen.
enum NapLive {
  /// Before its first stage (it needs 5 minutes, then reads 2 behind).
  starting,

  /// AnySleep's 3 runs.
  on,

  /// 1 run (a check took too long with 3).
  light,

  /// Running, but the signal is lost or poor now: the timer decides until it is back.
  poor,

  /// No model: the timer alone (too slow, failed, or not available).
  timer,
}

class NapTiming {
  const NapTiming({
    this.link = const LinkTiming(),
    this.tick = const Duration(milliseconds: 250),
    this.noDataAfter = const Duration(seconds: 2),
    this.saveEvery = const Duration(seconds: 60),
  });

  final LinkTiming link;

  /// The screen, the file writer and the timers update this often.
  final Duration tick;

  /// No data for this long: the screen says so.
  final Duration noDataAfter;

  /// The session file is rewritten this often (so a killed app keeps the nap so far).
  final Duration saveEvery;
}

class NapController extends ChangeNotifier {
  NapController({
    required this.finder,
    required NapSound Function() sound,
    this.model,
    this.store,
    this.recordingsDir,
    this.mayRunModel,
    this.scale = scaleInBackground,
    this.timing = const NapTiming(),
    this.gestureTone,
    DateTime Function()? clock,
  }) : _makeSound = sound,
       _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final NapSound Function() _makeSound;

  /// The hands-free confirmation tone (null: none).
  final GestureTone Function()? gestureTone;

  /// The owner's calibrated gestures while the hands-free switch is on (set by the screen); null: off.
  GestureSettings? handsFree;
  HandsFree? _hands;

  /// The sleep model for a session (null: the timer alone, e.g. the app's folder is unknown).
  LiveModel Function()? model;

  /// Where naps are kept (null: nothing saved).
  NapStore? store;

  /// Where the nap's EEG goes (the night recorder's folder); null: not written.
  Directory? recordingsDir;

  /// False while another model runs (last night's scoring): the live checks wait (memory).
  bool Function()? mayRunModel;
  final ScaleFn scale;
  final NapTiming timing;
  final DateTime Function() _now;

  NapStage stage = NapStage.setup;

  /// One plain sentence about the stage (connecting, a failure).
  String message = '';
  int lengthMin = NapRule.defaultMin;

  /// Contact at the start: ohms per channel, null = no contact.
  Map<String, double?> contact = const {};

  /// Set when the EEG or the nap could not be saved.
  String? saveNote;

  /// Nothing from the headband for a moment.
  bool noData = false;

  /// Why the nap is ending or ended (set at the wake or Stop).
  NapEnd? end;

  /// The nap that just ended (the report).
  NapSession? last;

  bool get active => stage.index >= NapStage.connecting.index && stage.index <= NapStage.waking.index;

  /// Seconds after lights off (0 before it).
  double get seconds => _lightsOffAt == null ? 0 : _t();

  /// The drift-off detector's state now (null before its baseline is complete).
  DriftState? get driftState => _drift?.state == DriftState.baseline ? null : _drift?.state;
  DriftOff? get drift => _drift;

  /// The live scorer of the session running now (or the last one).
  LiveStager? get stager => _stager;

  /// The newest live stage (null before the first).
  LiveStage? get latest => (_stager?.stages.isEmpty ?? true) ? null : _stager!.stages.last;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _link?.leftLost ?? false;

  NapLive get live {
    final s = _stager;
    if (s == null || s.mode == LiveMode.timer) return NapLive.timer;
    if ((_link?.lost ?? false) || noData) return NapLive.poor;
    final l = latest;
    if (l == null) return NapLive.starting;
    if (l.stage == gapStage) return NapLive.poor;
    return s.mode == LiveMode.light ? NapLive.light : NapLive.on;
  }

  /// Why the model is not giving stages now, in a sentence (null when it is, or before its first).
  String? get liveNote => switch (live) {
    NapLive.timer => _stager?.why ?? 'The sleep model is not available here, so the timer alone ends the nap.',
    NapLive.poor =>
      (_link?.lost ?? false) || noData
          ? 'The headband\'s signal is lost; the timer ends the nap until it is back.'
          : 'The signal is too poor for the sleep model right now; the timer ends the nap until it is better.',
    NapLive.starting when (_stager?.waited ?? 0) > 0 =>
      'The sleep model waits for last night\'s scoring to finish; the timer covers until then.',
    _ => _stager?.why,
  };

  BandLink? _link;
  NapSound? _sound;
  ChunkWriter? _writer;
  String? _recording;
  Detectors? _seen;
  DriftOff? _drift;
  LiveStager? _stager;
  NapRules? _rules;
  DateTime? _lightsOffAt;
  double? _wakeS, _upS;
  int _cues = 0;
  Timer? _ticker;
  int _ticks = 0;
  DateTime? _lastArrival;
  DateTime? _lastSave;
  int? _lastPack;
  bool _gapPending = false;
  int _lostSamples = 0;
  bool _baselineMarked = false, _drowsyMarked = false, _asleepMarked = false;
  bool _ended = false;
  bool _disposed = false;

  /// Lights off: connects, checks contact, starts the sound, the EEG file, the detectors and the live scorer.
  /// Errors end in [NapStage.failed].
  Future<void> start({int lengthMin = NapRule.defaultMin}) async {
    if (active) return;
    _reset();
    this.lengthMin = lengthMin;
    _set(NapStage.connecting, 'Looking for the headband.');
    final link = BandLink(finder: finder, timing: timing.link, onBatch: _onBatch, onEvent: _onLinkEvent, clock: _now);
    _link = link;
    try {
      if (!await link.connect(onFound: (name) => _set(NapStage.connecting, 'Found $name. Connecting.'))) {
        return await _fail('Headband not found. Is it switched on, charged, and free (no night recording)?');
      }
      if (_ended) return await link.close();
      _set(NapStage.contact, 'Checking contact. Lie still for a few seconds.');
      contact = await link.contact();
      if (_ended) return await link.close();
      final sound = _makeSound();
      try {
        await sound.start();
      } catch (e) {
        return await _fail('The sound did not start ($e), so the nap could not wake you.');
      }
      _sound = sound;
      if (_ended) return await _release();
      _openWriter(link.name);
      _seen = Detectors(onSecond: _onSecond);
      final hf = handsFree;
      if (hf != null) {
        _hands = HandsFree(
          hf,
          onGesture: (k) => _ended ? null : _mark('hands-free: moment (${gestureWord(k)})'),
          tone: gestureTone?.call(),
          asleep: () => _drift?.state == DriftState.asleep,
        )..attach(_seen!);
      }
      _drift = DriftOff(0); // lights off: the first sample
      _rules = NapRules(lengthS: lengthMin * 60);
      final m = model;
      _stager = m == null
          ? null
          : LiveStager(model: m(), scale: scale, mayRun: mayRunModel, onStage: _onStage, onChange: _onLiveChange);
      _lightsOffAt = _now();
      _lastSave = _lightsOffAt;
      await link.startSignal();
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(NapStage.resting, '');
      _mark('nap coach: lights off; length $lengthMin min; sleep model ${m == null ? 'none' : 'on'}');
      _save();
    } on TimeoutException catch (e) {
      await _fail('The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.');
    } catch (e) {
      await _fail('Could not start: $e');
    }
  }

  /// "I'm awake" while the cue plays; before the wake it ends the nap as stopped.
  Future<void> awake() async {
    if (stage == NapStage.waking) {
      _upS = _t();
      _mark('nap coach: I\'m awake');
      await _finish(end ?? NapEnd.length);
    } else {
      await stop();
    }
  }

  /// Ends now and keeps what there was.
  Future<void> stop() async {
    if (stage == NapStage.waking) return awake();
    end ??= NapEnd.stopped;
    await _finish(NapEnd.stopped);
  }

  /// Back to the setup after a nap or a failure.
  void again() {
    if (active) return;
    _set(NapStage.setup, '');
  }

  void _reset() {
    _link = null;
    _sound = null;
    _writer = null;
    _recording = null;
    _seen = null;
    _hands = null;
    _drift = null;
    _stager = null;
    _rules = null;
    _lightsOffAt = null;
    _wakeS = null;
    _upS = null;
    _cues = 0;
    _ticks = 0;
    _lastArrival = null;
    _lastSave = null;
    _lastPack = null;
    _gapPending = false;
    _lostSamples = 0;
    _baselineMarked = _drowsyMarked = _asleepMarked = false;
    _ended = false;
    contact = const {};
    saveNote = null;
    noData = false;
    end = null;
    last = null;
  }

  double _t() {
    final at = _lightsOffAt;
    if (at == null) return 0;
    final samples = (_seen?.n ?? 0) / fs;
    return math.max(samples, _now().difference(at).inMicroseconds / 1e6);
  }

  // ---- the EEG file ----

  void _openWriter(String band) {
    final dir = recordingsDir;
    if (dir == null) return;
    try {
      final w = ChunkWriter.open(dir, _now());
      w.log('nap coach session; headband $band');
      w.log('contact ${[for (final e in contact.entries) '${e.key} ${e.value?.round() ?? 'none'}'].join(', ')}');
      _writer = w;
      _recording = w.stem;
    } catch (e) {
      saveNote = 'The EEG of this nap could not be saved: $e';
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
    final live = stage == NapStage.resting ? _stager : null; // after the wake nothing more is scored
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
        // the detectors and the live scorer hold the last value over the hole (as the BDF does); unknown: 1 s
        final n = _lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs;
        seen.hold(n);
        live?.hold(n);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; µV from here on
      if (row.every((v) => v.isFinite)) {
        seen.push(row);
        live?.push(row);
      }
    }
    noData = false;
  }

  /// Each whole second from the detectors (one second late): the drift-off detector's input.
  void _onSecond(Second sec) {
    final d = _drift;
    if (d == null) return;
    final a = sec.backAlpha;
    d.second(sec.k, a.alpha, a.clean, sec.movement, sec.sem, sec.blinks);
    if (!_baselineMarked && d.baselineDone != null) {
      _baselineMarked = true;
      _mark('nap coach: eyes-closed baseline done');
    }
    if (!_drowsyMarked && d.drowsyAt != null) {
      _drowsyMarked = true;
      _mark('nap coach: drowsy (alpha faded)');
    }
    if (!_asleepMarked && d.onset != null) {
      _asleepMarked = true;
      _mark('nap coach: probably asleep (onset ${d.onset} s after lights off)');
    }
  }

  void _onStage(LiveStage s) {
    final r = _rules;
    if (r == null || _ended || stage != NapStage.resting) return;
    if (r.stage(s)) {
      _mark('nap coach: deep sleep starting (epoch ${s.epoch}, read ${s.behind} epochs behind)');
      _wake(NapEnd.deepSleep);
    }
  }

  void _onLiveChange() {
    final s = _stager;
    if (s != null) _mark('nap coach: sleep model ${s.mode.name}: ${s.why ?? ''}');
    _notify();
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
    final lastData = _link?.lastData;
    noData = lastData != null && _now().difference(lastData) > timing.noDataAfter;
    final t = _t();
    if (stage == NapStage.resting) {
      final due = _rules?.due(t);
      if (due != null) _wake(due);
    }
    if (stage == NapStage.waking) _ring(t);
    final saved = _lastSave;
    if (saved != null && _now().difference(saved) >= timing.saveEvery) {
      _lastSave = _now();
      _save();
    }
    _notify();
  }

  // ---- the wake ----

  void _wake(NapEnd why) {
    if (stage != NapStage.resting || _ended) return;
    end = why;
    _wakeS = _t();
    _mark('nap coach: wake (${why.name})');
    _set(NapStage.waking, '');
    unawaited(_stager?.close()); // nothing more to score: free the model's memory now
    _ring(_wakeS!);
  }

  /// The cue now and every 20 s, a little louder each time, until "I'm awake" or 5 minutes.
  void _ring(double t) {
    final from = _wakeS, s = _sound;
    if (from == null || s == null) return;
    if (t - from >= NapRule.wakeForS) {
      _mark('nap coach: no "I\'m awake" in ${NapRule.wakeForS ~/ 60} minutes');
      unawaited(_finish(end ?? NapEnd.length));
      return;
    }
    final due = ((t - from) / NapRule.wakeEveryS).floor();
    while (_cues <= due) {
      s.wake(wakeVolume(_cues, s.firstVolume));
      _cues++;
    }
  }

  // ---- the end ----

  Future<void> _finish(NapEnd why) async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    final lightsOff = _lightsOffAt;
    if (lightsOff == null) {
      // stopped while connecting: nothing to keep
      await _release();
      await _sound?.stop();
      _set(NapStage.setup, '');
      return;
    }
    end = why;
    final endS = _t();
    final h = _hands;
    if (h != null) _mark('hands-free: ${h.heard} gestures acted on, ${h.ignoredAsleep} ignored while probably asleep');
    _mark('nap coach: end (${why.name})');
    _seen?.finish();
    _closeWriter();
    await _release();
    await _sound?.stop();
    await _stager?.close();
    last = _save(endS: endS, why: why);
    _set(NapStage.done, '');
  }

  NapSession? _save({double? endS, NapEnd? why}) {
    final at = _lightsOffAt;
    if (at == null) return null;
    final t = endS ?? _t();
    final d = _drift, s = _stager;
    final n = (t / 30).floor();
    final letters = List.filled(n, unscored);
    for (final st in s?.stages ?? const <LiveStage>[]) {
      if (st.epoch < n) letters[st.epoch] = stageLetters[st.stage] ?? unscored;
    }
    final times = s?.callTimes;
    final session = NapSession(
      start: at,
      lengthMin: lengthMin,
      recording: _recording,
      live: NapLiveInfo(
        mode: s?.mode ?? LiveMode.timer,
        why: s == null ? 'The sleep model was not available.' : s.why,
        calls: s?.calls.length ?? 0,
        medianMs: times?.median,
        maxMs: times?.max,
        waited: s?.waited ?? 0,
        poorEpochs: letters.where((l) => l == 'g').length,
      ),
      endS: t,
      end: why,
      wakeS: _wakeS,
      upS: _upS,
      baselineS: d?.baselineDone,
      drowsyS: d?.drowsyAt,
      onsetS: d?.onset,
      deepEpoch: _rules?.deepEpoch,
      stages: letters.join(),
      contact: contact,
    );
    final st = store;
    if (st != null) {
      try {
        st.save(session);
      } catch (e) {
        saveNote = 'This nap could not be saved: $e';
      }
    }
    return session;
  }

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

  Future<void> _fail(String why) async {
    final stoppedByUser = _ended;
    _ended = true;
    _ticker?.cancel();
    _closeWriter();
    await _release();
    await _sound?.stop();
    await _stager?.close();
    if (!stoppedByUser) _set(NapStage.failed, why);
  }

  void _set(NapStage s, String text) {
    stage = s;
    message = text;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (active) unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
