// The hands-free calibration (DECISIONS 243): about 90 seconds with the headband, between nights. 32 s sitting
// still (the muscle rest level needs 30 s), then six tries 8 s apart, each on a soft tone: "Clench twice now" three
// times, "Look left, then right" three times. The gesture recogniser sees every second as it ends (the same tap the
// sessions use); at the end `calibrate` sets the clench level, the glance size and which way is left from the
// tries, says for each try whether the tuned settings catch it, and the result is saved (store.dart). The screen
// draws the last 10 seconds as two lanes, Jaw and Eyes, while it runs.
//
// Like the morning check-in it counts seconds of signal, and a headband that drops out ends it (nothing is kept):
// 90 seconds are quicker to repeat than to patch. Its EEG is kept beside the calibration
// (`files/hands-free/recordings/`, the recorder's format with a marker per cue), not with the nights, so it never
// joins a night's report; Export data takes it with the rest.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../detectors/detectors.dart';
import '../detectors/gestures.dart';
import '../dream/band_link.dart';
import '../feedback/features.dart' show fs;
import '../meditation/controller.dart' show gapSamples;
import '../recorder/chunk_writer.dart';
import '../recorder/headband.dart';
import '../spans/activities.dart' show ActivityRef, activityRef;
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../sound/check_in_sound.dart';
import 'store.dart';

enum CalStage { setup, connecting, contact, still, trying, result, failed }

class CalTiming {
  const CalTiming({
    this.link = const LinkTiming(),
    this.tick = const Duration(milliseconds: 250),
    this.stillS = 32,
    this.tryEveryS = 8,
    this.windowS = 5,
  });

  final LinkTiming link;
  final Duration tick;

  /// Seconds of sitting still before the first try (the rest level needs 30).
  final int stillS;

  /// Seconds from one cue to the next; a try may start up to [windowS] after its cue.
  final int tryEveryS;
  final int windowS;
}

/// The six tries in order.
const List<GestureKind> calTries = [
  GestureKind.clench,
  GestureKind.clench,
  GestureKind.clench,
  GestureKind.glance,
  GestureKind.glance,
  GestureKind.glance,
];

/// Seconds of the lanes on screen, and ticks of the jaw lane.
const int laneSeconds = 10;

/// One eye movement on the Eyes lane: when (seconds before now, 0..10) and how far (µV; the sign is the way).
typedef LaneStep = ({double ago, double step});

class CalibrationController extends ChangeNotifier {
  CalibrationController({
    required this.finder,
    required CheckInSound Function() sound,
    this.store,
    this.timing = const CalTiming(),
    DateTime Function()? clock,
  }) : _makeSound = sound,
       _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final CheckInSound Function() _makeSound;

  /// Where the calibration is saved (null: not saved).
  HandsFreeStore? store;
  final CalTiming timing;
  final DateTime Function() _now;

  CalStage stage = CalStage.setup;

  /// One plain sentence about the stage (connecting, a failure, why it was not saved).
  String message = '';
  Map<String, double?> contact = const {};

  /// The try being cued now (0..5), or null.
  int? tryNow;

  /// Seconds of signal so far, and seconds still to sit still.
  int seconds = 0;
  int get stillLeft => math.max(0, timing.stillS - seconds);

  /// The jaw lane: the last 100 ticks' weaker side against its rest (NaN while the rest is unknown), oldest first.
  final List<double> jaw = [];

  /// The eye lane: eye movements of the last 10 seconds.
  List<LaneStep> eyes = const [];

  /// The clench line on the jaw lane and the glance size (the planning values until a calibration exists).
  double clenchLine = GestureRule.clenchX;
  double glanceSize = GestureRule.glanceUv;

  /// The cued try's 5 seconds are still open.
  bool get inWindow {
    final t = tryNow;
    return t != null && seconds - tries[t].cue < timing.windowS;
  }

  /// Each try's live mark once the next one is cued: true when it had a gesture's shape, false when not (null: not
  /// judged yet). The result's verdicts replace them at the end.
  final List<bool?> shaped = List.filled(calTries.length, null);

  /// The clench line and glance size come from an earlier calibration (else they are the first guesses).
  bool linesAreYours = false;

  /// The result, once the six tries are done.
  GestureCalibration? result;
  CalibrationRecord? saved;
  String? saveNote;

  bool get active => stage.index >= CalStage.connecting.index && stage.index <= CalStage.trying.index;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _link?.leftLost ?? false;

  /// The tries with their cue seconds.
  List<GestureTry> get tries => [
    for (var i = 0; i < calTries.length; i++)
      GestureTry(calTries[i], timing.stillS + i * timing.tryEveryS, timing.stillS + i * timing.tryEveryS + timing.windowS),
  ];

  int get _endS => timing.stillS + calTries.length * timing.tryEveryS;

  BandLink? _link;
  CheckInSound? _sound;
  Detectors? _seen;
  ChunkWriter? _writer;
  ActivityRef? _rides;
  final List<GestureSecond> _inputs = [];
  Gestures _loose = Gestures(settings: const GestureSettings(clenchOn: false, glanceOn: false));
  final List<EyeMove> _moves = [];
  int? _lastPack;
  DateTime? _startedAt;
  Timer? _ticker;
  bool _ended = false;
  bool _disposed = false;

  /// The number of the latest start: a start that Stop or a newer start overtook touches nothing of the calibration
  /// now running (DECISIONS 450, 470).
  int _run = 0;
  bool _live(int run) => run == _run && !_ended;

  /// Connects, checks contact, then runs the plan. Errors end in [CalStage.failed].
  Future<void> start() async {
    if (active) return;
    _reset();
    final run = ++_run;
    _set(CalStage.connecting, 'Looking for the headband.');
    final link = BandLink(
      finder: finder,
      timing: timing.link,
      onBatch: (now, batch) => _onBatch(now, batch, run),
      onEvent: (e, line) => _onLinkEvent(e, line, run),
      clock: _now,
    );
    _link = link;
    try {
      final found = await link.connect(onFound: (name) {
        if (_live(run)) _set(CalStage.connecting, 'Found $name. Connecting.');
      });
      if (!_live(run)) return await link.close();
      if (!found) {
        _link = null;
        return await _fail('Headband not found. Is it switched on and charged?', run);
      }
      _set(CalStage.contact, 'Checking contact. Keep still for a few seconds.');
      final ohms = await link.contact();
      if (!_live(run)) return await link.close();
      contact = ohms;
      final sound = _makeSound();
      try {
        await sound.start();
        if (!_live(run)) {
          await sound.stop();
          return await link.close();
        }
        _sound = sound;
      } catch (_) {
        if (!_live(run)) return await link.close();
        message = 'The tones did not start; follow the words on the screen.';
      }
      _openWriter(link.name);
      _seen = Detectors()..tap = GestureTap(_second);
      _startedAt = _now();
      await link.startSignal();
      if (!_live(run)) return await link.close(); // Stop came while the stream started
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(CalStage.still, message);
    } on TimeoutException catch (e) {
      await _fail('The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.', run);
    } catch (e) {
      await _fail('Could not start: $e', run);
    }
  }

  /// Ends now; nothing is saved.
  Future<void> stop() async {
    if (!active) return;
    _ended = true;
    _ticker?.cancel();
    _closeWriter(keep: false);
    await _link?.close();
    await _sound?.stop();
    _set(CalStage.setup, '');
  }

  /// Back to the start after a result or a failure.
  void again() {
    if (active) return;
    _set(CalStage.setup, '');
  }

  void _reset() {
    _link = null;
    _sound = null;
    _seen = null;
    _writer = null;
    _inputs.clear();
    _loose = Gestures(settings: const GestureSettings(clenchOn: false, glanceOn: false));
    shaped.fillRange(0, shaped.length, null);
    _moves.clear();
    _lastPack = null;
    _startedAt = null;
    _ended = false;
    jaw.clear();
    eyes = const [];
    tryNow = null;
    seconds = 0;
    result = null;
    saved = null;
    saveNote = null;
    contact = const {};
    message = '';
    final before = store?.load().calibration?.settings;
    linesAreYours = before != null;
    clenchLine = before?.clenchX ?? GestureRule.clenchX;
    glanceSize = before?.glanceUv ?? GestureRule.glanceUv;
  }

  // ---- the signal ----

  void _onLinkEvent(LinkEvent e, String line, int run) {
    if (run != _run) return;
    _writer?.log(line);
    if (e == LinkEvent.drop && active) unawaited(_fail('The headband dropped out. Nothing was kept; please try again.', run));
  }

  void _onBatch(DateTime now, List<Sample> batch, int run) {
    final seen = _seen;
    if (seen == null || !_live(run)) return;
    _writer?.addBatch(now, batch);
    for (final x in batch) {
      if (_ended) return;
      final prev = _lastPack;
      if (prev != null) {
        final skip = (x.pack - prev - 1) % packetWrap;
        // lost packets: held at the last value and marked missing, as the BDF does (a try near them is spoiled)
        if (skip >= gapSamples && skip <= maxGapSamples) seen.hold(skip);
      }
      _lastPack = x.pack;
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts; the detectors take µV
      if (row.every((v) => v.isFinite)) seen.push(row);
    }
  }

  /// Every second as it ends: the recogniser's input, the lanes, and the plan.
  void _second(GestureSecond s) {
    _inputs.add(s);
    _loose.second(s);
    seconds = s.k + 1;
    for (var j = 0; j < ticksPerSecond; j++) {
      final r3 = s.rest3, r4 = s.rest4;
      final ok = !r3.isNaN && r3 > 0 && !r4.isNaN && r4 > 0;
      jaw.add(ok ? math.min(s.p3[j] / r3, s.p4[j] / r4) : double.nan);
    }
    if (jaw.length > laneSeconds * ticksPerSecond) jaw.removeRange(0, jaw.length - laneSeconds * ticksPerSecond);
    _moves.addAll(s.moves);
    final nowSample = seconds * fs;
    _moves.removeWhere((m) => m.i < nowSample - laneSeconds * fs);
    eyes = [for (final m in _moves) (ago: (nowSample - m.i) / fs, step: m.step)];
    _plan();
  }

  void _plan() {
    if (_ended) return;
    if (seconds >= _endS) {
      unawaited(_finish());
      return;
    }
    if (seconds < timing.stillS) return;
    final i = (seconds - timing.stillS) ~/ timing.tryEveryS;
    if (i == tryNow) return;
    if (i > 0) shaped[i - 1] = tryShaped(_loose, tries[i - 1]);
    tryNow = i;
    final kind = calTries[i];
    kind == GestureKind.clench ? _sound?.close() : _sound?.open();
    _mark('hands-free calibration: try ${i + 1} of ${calTries.length}, ${kind == GestureKind.clench ? 'clench twice now' : 'look left, then right'}');
    _set(CalStage.trying, '');
  }

  void _tick() {
    if (_ended) return;
    _link?.tick();
    try {
      _writer?.append();
    } catch (_) {}
    _notify();
  }

  // ---- the end ----

  Future<void> _finish() async {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    tryNow = null;
    _sound?.end();
    final cal = calibrate(_inputs, tries);
    result = cal;
    clenchLine = cal.settings.clenchX;
    glanceSize = cal.settings.glanceUv;
    _mark('hands-free calibration: double clench ${cal.clenchSeen} of 3, look left then right ${cal.glanceSeen} of 3');
    final stem = _rides?.recording ?? _writer?.stem;
    _closeWriter(keep: true);
    final rec = CalibrationRecord.of(cal, _startedAt ?? _now(), recording: stem, span: _rides?.span);
    final st = store;
    if (st == null) {
      saveNote = 'This calibration was not saved.';
    } else {
      try {
        st.saveCalibration(rec);
        saved = rec;
      } catch (e) {
        saveNote = 'This calibration could not be saved: $e';
      }
    }
    await _link?.close();
    await _sound?.stop();
    _set(CalStage.result, '');
  }

  /// [run]: the start that failed; one that Stop or a newer start overtook changes nothing (its headband was let go).
  Future<void> _fail(String why, int run) async {
    if (!_live(run)) return; // Stop, a newer start, or the end got there first
    _ended = true;
    _ticker?.cancel();
    _closeWriter(keep: false);
    await _link?.close();
    await _sound?.stop();
    _set(CalStage.failed, why);
  }

  // ---- the EEG beside the calibration ----

  Directory? get _eegDir {
    final st = store;
    return st == null ? null : Directory('${st.dir.path}/recordings');
  }

  void _openWriter(String band) {
    // an activity of the day's recording keeps no raw file of its own
    _rides = (_link?.ridesRecorder ?? false) ? activityRef() : null;
    if (_rides != null) return;
    final dir = _eegDir;
    if (dir == null) return;
    try {
      dir.createSync(recursive: true);
      final w = ChunkWriter.open(dir, _now());
      w.log('hands-free calibration; headband $band');
      w.log('contact ${[for (final e in contact.entries) '${e.key} ${e.value?.round() ?? 'none'}'].join(', ')}');
      _writer = w;
    } catch (_) {
      _writer = null; // the calibration works without its EEG
    }
  }

  void _mark(String text) {
    final w = _writer, dir = _eegDir;
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

  /// Closes the EEG file; a calibration that did not finish leaves nothing behind.
  void _closeWriter({required bool keep}) {
    final w = _writer, dir = _eegDir;
    _writer = null;
    if (w == null) return;
    try {
      w.close();
      if (!keep && dir != null) {
        for (final f in dir.listSync().whereType<File>()) {
          if (f.uri.pathSegments.last.startsWith(w.stem)) f.deleteSync();
        }
      }
    } catch (_) {}
  }

  void _set(CalStage s, String text) {
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
