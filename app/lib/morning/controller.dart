// One morning check-in on the phone (DECISIONS rows 120 and 125): the laptop page's routine (scripts/web/morning.js)
// with the phone holding the headband: find it, check contact (resistance, then a live word per electrode), 2 min
// eyes closed and 2 min eyes open on a dot with the page's tones, then the questions and the reaction test; the
// numbers are worked out on the phone exactly as scripts/morning_check.py works them out (result.dart).
//
// Like meditation (row 75) it owns the headband only between nights. The phases count seconds of signal, so a
// stall pauses the countdown. A headband that drops out stops the check-in (nothing is kept): 5 minutes are
// quicker to repeat than to patch, and a phase with a hole in it is not the routine the numbers assume.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../recorder/chunk_writer.dart' show ChunkWriter, Sample, fileStem, unixSeconds;
import '../recorder/contact.dart' show channelNames;
import '../recorder/headband.dart';
import '../sound/check_in_sound.dart';
import 'live.dart';
import 'measures.dart';
import 'result.dart';
import 'store.dart';

enum MorningStage { intro, connecting, contact, closed, open, questions, saving, result, failed }

class MorningTiming {
  const MorningTiming({
    this.scanFor = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 45),
    this.sdkTimeout = const Duration(seconds: 15),
    this.contactFor = const Duration(seconds: 6),
    this.settle = const Duration(seconds: 1),
    this.tick = const Duration(milliseconds: 250),
    this.noDataAfter = const Duration(seconds: 2),
    this.restartStreamAfter = const Duration(seconds: 8),
    this.phaseS = 120,
  });

  final Duration scanFor, connectTimeout, sdkTimeout, contactFor, settle, tick, noDataAfter, restartStreamAfter;

  /// Seconds of signal per phase (the laptop: 120, or 60 with ?short=1).
  final int phaseS;
}

/// The answers after the recording part. [cups] and [drinks]: 0-5, 5 meaning 5 or more.
class MorningAnswers {
  const MorningAnswers({
    required this.kss,
    required this.mood,
    required this.tension,
    required this.cups,
    required this.drinks,
    required this.caffeineToday,
    this.caffeineLate,
    this.reaction,
  });

  final int kss, mood, tension, cups, drinks;
  final bool caffeineToday;

  /// Any caffeine in the 8 hours before sleep (asked only when [cups] > 0).
  final bool? caffeineLate;

  /// The reaction test: median_ms (null with too few taps), taps, lapses, false_starts, length_s; null if skipped.
  final Map<String, Object?>? reaction;

  Map<String, int> get ratings => {'kss': kss, 'mood': mood, 'tension': tension};
  Map<String, Object?> get habits => {
    'caffeine_cups': cups,
    'caffeine_late': cups == 0 ? false : caffeineLate,
    'caffeine_today': caffeineToday,
    'alcohol_drinks': drinks,
  };
}

/// What the background isolate needs: whole channels (µV) and the phase windows.
typedef _Job = ({Map<String, Float64List> channels, Map<String, PhaseWindow> win});

({Map<String, ChannelMeasures> channels, Map<String, double?> back}) _analyse(_Job j) =>
    analyseCheckIn(cutPhases(j.channels, j.win));

class MorningController extends ChangeNotifier {
  MorningController({
    required this.finder,
    CheckInSound Function()? sound,
    this.store,
    this.timing = const MorningTiming(),
    DateTime Function()? clock,
  }) : _makeSound = sound ?? SilentCheckInSound.new,
       _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final CheckInSound Function() _makeSound;

  /// Where check-ins are kept (null: not saved; set by the screen once the app's folder is known).
  MorningStore? store;
  final MorningTiming timing;
  final DateTime Function() _now;

  MorningStage stage = MorningStage.intro;
  String message = '';
  String? soundNote, saveNote;

  /// Contact at the start (ohms per channel, null = no contact); empty before the check.
  Map<String, double?> contact = const {};

  /// Checking contact again from the contact step.
  bool rechecking = false;

  /// No data for [MorningTiming.noDataAfter]: the countdown waits.
  bool noSignal = false;

  /// The saved result (`<start>.morning.json`) after Save.
  Map<String, Object?>? result;

  bool get active => stage.index >= MorningStage.connecting.index && stage.index <= MorningStage.open.index;

  /// A headband was left out of range (the finder must not dispose its scanner then).
  bool get leftLost => _lostBand;

  Headband? _band;
  CheckInSound? _sound;
  ChunkWriter? _writer;
  StreamSubscription<List<Sample>>? _signalSub;
  StreamSubscription<bool>? _rangeSub;
  Timer? _ticker;
  final Map<String, List<double>> _uv = {for (final c in channelNames) c: <double>[]};
  final List<Marker> _markers = [];
  final Float32List _f32 = Float32List(4);
  int _received = 0;
  int _phaseFrom = 0;
  DateTime? _signalAt, _lastData;
  bool _restarted = false, _lostBand = false, _ended = false, _disposed = false;
  Future<({Map<String, ChannelMeasures> channels, Map<String, double?> back})>? _analysis;

  int get _phaseSamples => timing.phaseS * morningFs;

  /// Seconds left in the running phase.
  int get secondsLeft => math.max(0, ((_phaseSamples - (_received - _phaseFrom)) / morningFs).ceil());

  /// The live word per electrode from the last 4 s of its signal.
  Map<String, ({Grade grade, String word, double spread})> get grades {
    final n = (gradeWindowS * morningFs).round();
    return {
      for (final c in channelNames)
        c: gradeChannel(
          contact[c],
          _uv[c]!.isEmpty ? null : _uv[c]!.sublist(math.max(0, _uv[c]!.length - n)),
        ),
    };
  }

  /// Finds the headband, checks contact and starts the signal; then the contact step waits for [begin].
  Future<void> start() async {
    if (active) return;
    _reset();
    _set(MorningStage.connecting, 'Looking for the headband.');
    try {
      final band = await finder
          .find(timing.scanFor, onFound: (name, _) => _set(MorningStage.connecting, 'Found $name. Connecting.'))
          .timeout(timing.scanFor + timing.connectTimeout);
      if (band == null) {
        return await _fail('Headband not found. Is it switched on, charged, and free (no night recording)?');
      }
      _band = band;
      if (_ended) return await _release();
      _rangeSub = band.rangeChanges.listen(_onRange);
      _set(MorningStage.contact, 'Checking contact. Keep still for a few seconds.');
      rechecking = true;
      contact = await _checkContact(band);
      rechecking = false;
      if (_ended) return await _release();
      var sound = _makeSound();
      try {
        await sound.start();
      } catch (e) {
        soundNote = 'The tones did not start ($e): watch the screen for when to open your eyes.';
        sound = SilentCheckInSound();
      }
      _sound = sound;
      final st = store;
      if (st != null) {
        try {
          _writer = ChunkWriter.open(st.dir, _now());
        } catch (e) {
          saveNote = 'The raw signal cannot be kept ($e); the numbers still are.';
        }
      }
      _signalSub = band.signal.listen(_onBatch);
      await _sdk(band.startSignal(), 'start signal');
      _signalAt = _now();
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      _set(MorningStage.contact, '');
    } on TimeoutException catch (e) {
      await _fail('The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.');
    } catch (e) {
      await _fail('Could not start: $e');
    }
  }

  /// Checks contact again (the laptop's "Check again"): the signal pauses for a few seconds.
  Future<void> recheck() async {
    final band = _band;
    if (stage != MorningStage.contact || band == null || rechecking) return;
    rechecking = true;
    _notify();
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      contact = await _checkContact(band);
      if (_ended) return;
      await _sdk(band.startSignal(), 'start signal');
    } catch (e) {
      message = 'The contact check did not finish ($e).';
    } finally {
      rechecking = false;
      _notify();
    }
  }

  /// From the contact step: eyes closed now.
  void begin() {
    if (stage != MorningStage.contact || rechecking) return;
    _mark(MorningMarker.start, _received);
    _mark(MorningMarker.phase('eyes_closed', 'start'), _received);
    _phaseFrom = _received;
    _sound?.close();
    _set(MorningStage.closed, '');
  }

  /// Ends the check-in early; nothing is kept.
  Future<void> stop() async {
    if (!active && stage != MorningStage.questions) return;
    await _abort('Stopped. Nothing was kept; you can start again any time.');
  }

  /// Back to the start after a result or a failure.
  void again() {
    if (active || stage == MorningStage.saving) return;
    _set(MorningStage.intro, '');
  }

  void _reset() {
    _band = null;
    _sound = null;
    _writer = null;
    for (final c in channelNames) {
      _uv[c]!.clear();
    }
    _markers.clear();
    _received = 0;
    _phaseFrom = 0;
    _signalAt = null;
    _lastData = null;
    _restarted = false;
    _ended = false;
    _analysis = null;
    contact = const {};
    rechecking = false;
    noSignal = false;
    soundNote = null;
    saveNote = null;
    result = null;
  }

  Future<T> _sdk<T>(Future<T> call, String what) => call.timeout(timing.sdkTimeout, onTimeout: () {
    throw TimeoutException(what, timing.sdkTimeout);
  });

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
        if (last.containsKey(n)) n: last[n]!.isFinite ? last[n] : null,
    };
  }

  void _mark(String text, int i) => _markers.add((t: unixSeconds(_now()), i: i, text: text));

  void _onBatch(List<Sample> batch) {
    if (_ended || batch.isEmpty) return;
    final now = _now();
    _lastData = now;
    noSignal = false;
    _writer?.addBatch(now, batch);
    for (final x in batch) {
      // The SDK gives volts; the file keeps them as float32 and the laptop analyses float32 x 1e6 as float64 µV.
      // The same steps here, so an exported check-in gives the laptop the very numbers the phone showed.
      _f32
        ..[0] = x.o1
        ..[1] = x.o2
        ..[2] = x.t3
        ..[3] = x.t4;
      for (var c = 0; c < 4; c++) {
        _uv[channelNames[c]]!.add(_f32[c] * 1e6);
      }
    }
    _received += batch.length;
    final end = _phaseFrom + _phaseSamples;
    if (stage == MorningStage.closed && _received >= end) {
      _mark(MorningMarker.phase('eyes_closed', 'end'), end);
      _mark(MorningMarker.phase('eyes_open', 'start'), end);
      _phaseFrom = end;
      _sound?.open();
      _set(MorningStage.open, '');
    } else if (stage == MorningStage.open && _received >= end) {
      _mark(MorningMarker.phase('eyes_open', 'end'), end);
      _sound?.end();
      unawaited(_recorded());
    }
  }

  /// The recording part is over: let the headband go and work the numbers out while the questions are answered.
  Future<void> _recorded() async {
    _ended = true;
    _ticker?.cancel();
    final w = morningWindows(_markers)!;
    final job = (
      channels: {for (final c in backChannels) c: Float64List.fromList(_uv[c]!)},
      win: w.win,
    );
    _analysis = Isolate.run(() => _analyse(job));
    unawaited(_analysis!.then((_) {}, onError: (Object _) {})); // a failure is reported at Save
    await _release(); // before the stage changes: the screen lets the scanner go then
    _writer?.close();
    _set(MorningStage.questions, '');
    unawaited(_sound?.stop()); // lets the end tone ring out
  }

  /// Saves the check-in with the answers and shows the numbers.
  Future<void> save(MorningAnswers a) async {
    final analysis = _analysis;
    if (stage != MorningStage.questions || analysis == null) return;
    _set(MorningStage.saving, 'Working out your numbers.');
    try {
      final m = await analysis;
      _mark(MorningMarker.ratings(a.ratings), _received);
      _mark(MorningMarker.end, _received);
      final w = morningWindows(_markers)!;
      final st = store, start = DateTime.fromMicrosecondsSinceEpoch((w.t * 1e6).round());
      final res = buildMorningResult(
        source: _writer == null ? '' : '${_writer!.stem}.f32',
        win: w.win,
        channels: m.channels,
        back: m.back,
        ratings: a.ratings,
        past: st?.historyBefore(start) ?? const [],
        habits: a.habits,
        reaction: a.reaction,
        contact: contact,
      );
      if (st != null) {
        final wr = _writer;
        if (wr != null) {
          File('${st.dir.path}/${wr.stem}.markers.jsonl').writeAsStringSync(
            _markers.map((m) => '${jsonEncode(markerJson(m))}\n').join(),
            flush: true,
          );
        }
        st.save(res, start);
      }
      result = res;
      _set(MorningStage.result, '');
    } catch (e) {
      saveNote = 'This check-in could not be worked out or saved: $e';
      _set(MorningStage.failed, saveNote!);
    }
  }

  void _tick() {
    if (_ended) return;
    final now = _now(), last = _lastData;
    final quiet = now.difference(last ?? _signalAt ?? now);
    noSignal = !rechecking && quiet > timing.noDataAfter;
    if (last == null && !_restarted && quiet > timing.restartStreamAfter) {
      _restarted = true;
      unawaited(_restartStream());
    }
    _notify();
  }

  Future<void> _restartStream() async {
    final band = _band;
    if (band == null) return;
    try {
      await _sdk(band.stopSignal(), 'stop signal');
      await _sdk(band.startSignal(), 'start signal');
    } catch (_) {}
  }

  void _onRange(bool inRange) {
    if (inRange || !active || _ended) return;
    _lostBand = true;
    unawaited(_abort('The headband dropped out, so the check-in stopped and nothing was kept. Start again when it '
        'is close.'));
  }

  /// Stops everything and keeps nothing (the raw files of this visit are deleted).
  Future<void> _abort(String why) async {
    final wasActive = active || stage == MorningStage.questions;
    _ended = true;
    _ticker?.cancel();
    await _release();
    await _sound?.stop();
    final w = _writer, st = store;
    _writer = null;
    if (w != null && st != null) {
      w.close();
      for (final ext in ['f32', 'idx', 'log', 'markers.jsonl']) {
        final f = File('${st.dir.path}/${w.stem}.$ext');
        if (f.existsSync()) f.deleteSync();
      }
    }
    if (wasActive) _set(MorningStage.intro, why);
  }

  Future<void> _release() async {
    await _signalSub?.cancel();
    await _rangeSub?.cancel();
    _signalSub = null;
    _rangeSub = null;
    final band = _band;
    _band = null;
    if (band == null || _lostBand) return;
    try {
      await _sdk(band.stopSignal(), 'stop signal');
    } catch (_) {}
    try {
      await _sdk(band.disconnectAndDispose(), 'disconnect');
    } catch (_) {}
  }

  Future<void> _fail(String why) async {
    final stopped = _ended;
    _ended = true;
    _ticker?.cancel();
    await _release();
    await _sound?.stop();
    if (!stopped) _set(MorningStage.failed, why);
  }

  void _set(MorningStage s, String text) {
    stage = s;
    message = text;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (active || stage == MorningStage.questions) unawaited(_abort(''));
    super.dispose();
  }
}

/// A file stem for a check-in's start (for tests and the screens).
String morningStem(DateTime start) => fileStem(start);
