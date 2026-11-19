// One work session (ROADMAP row 35, DECISIONS 440-449): the headband on while you work, the phone watching for
// drowsiness and suggesting breaks. It holds the headband from the work screen (only between nights: the headband
// takes one connection) through the shared link (dream/band_link.dart: reconnects, deadlines), and keeps going with
// the phone locked through the session keeper (SessionService.kt), re-held every 20 minutes so its wake lock never
// runs out on a long day.
//
// Samples -> the shared detectors (lib/detectors) -> one [WorkInput] a second -> the drowsiness level (drowsiness.dart)
// -> the break planner (breaks.dart) with the worn time. Optional first: one minute with eyes closed, whose alpha
// tells closed eyes apart later. The session file is written whole every 5 minutes and at Stop (store.dart).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../detectors/detectors.dart';
import '../dream/band_link.dart';
import '../feedback/features.dart' show fs, median;
import '../recorder/chunk_writer.dart' show Sample;
import '../recorder/headband.dart' show HeadbandFinder;
import '../recorder/packets.dart' show maxGapSamples, packetWrap;
import '../session_keeper.dart';
import '../sound/work_sound.dart';
import 'breaks.dart';
import 'drowsiness.dart';
import 'store.dart';

enum WorkStage { setup, connecting, contact, eyesClosed, calibrating, running, ending, done, failed }

/// One 5-minute cell of the last hour's strip: what the level read at its end, or a break, or nothing yet.
enum WorkCell { none, unknown, alert, gettingDrowsy, drowsy, onBreak }

/// How the signal is now, in four words' worth.
enum WorkSignal { good, noisy, lost, off }

/// The strip: 12 cells of 5 minutes, oldest first, the newest ending now.
const int stripCells = 12, cellMinutes = 5;

/// A skip of this many packet numbers or more (0.1 s) is a hole (as in meditation).
const int workGapSamples = 25;

/// The optional eyes-closed minute: its length, and the clean seconds it needs to count.
const int closedMinuteS = 60, closedMinCleanS = 20;

/// Of the last 10 detector seconds, this many must have a usable back channel for the headband to count as worn.
const int wornOf = 10, wornNeeded = 3;

class WorkTiming {
  const WorkTiming({
    this.link = const LinkTiming(),
    this.tick = const Duration(seconds: 1),
    this.noDataAfter = const Duration(seconds: 3),
    this.saveEvery = const Duration(minutes: 5),
    this.holdEvery = const Duration(minutes: 20),
  });
  final LinkTiming link;
  final Duration tick, noDataAfter, saveEvery, holdEvery;
}

class WorkController extends ChangeNotifier {
  WorkController({
    required this.finder,
    WorkSound? sound,
    SessionKeeper? keeper,
    this.store,
    this.timing = const WorkTiming(),
    DateTime Function()? clock,
  }) : sound = sound ?? SilentWorkSound(),
       keeper = keeper ?? FakeSessionKeeper(grant: false),
       _now = clock ?? DateTime.now;

  final HeadbandFinder finder;
  final WorkSound sound;
  final SessionKeeper keeper;

  /// Where sessions are kept (null: not saved; set by the screen once the app's folder is known).
  WorkStore? store;
  final WorkTiming timing;
  final DateTime Function() _now;

  WorkStage stage = WorkStage.setup;
  String message = '';

  /// The phone may be locked: the keeper holds the session.
  bool kept = false;
  Map<String, double?> contact = const {};
  DateTime? startedAt;

  /// Seconds of the eyes-closed minute left (while [stage] is eyesClosed).
  int closedLeft = 0;
  double? closedAlpha;

  /// The hint on screen now (null: none, or answered).
  WorkHint? hint;

  /// One line after the last break: did drowsiness go back down?
  String? afterBreak;

  /// The session that just ended (for the done page).
  Map<String, Object?>? last;
  String? saveNote;

  WorkDrowsiness? get drowsiness => _drowsy;
  BreakPlanner? get planner => _planner;
  DrowsyLevel get level => _drowsy?.level ?? DrowsyLevel.unknown;
  bool get active => stage.index >= WorkStage.connecting.index && stage.index <= WorkStage.ending.index;
  bool get leftLost => _link?.leftLost ?? false;
  bool get onBreak => _planner?.onBreak ?? false;

  /// The headband sends a usable signal now.
  bool worn = false;

  /// The link is reconnecting, or nothing arrived for a few seconds.
  bool get signalLost => (_link?.lost ?? false) || _quiet;

  /// Worn minutes of this session, and of the stretch since the last real break.
  double get wornMin => (_planner?.activeS ?? 0) / 60;
  double get stretchMin => _planner?.stretchMin ?? 0;

  /// Minutes the baseline still needs (about; scored half minutes left after the settling minute).
  double get calibrationLeftMin {
    final d = _drowsy;
    if (d == null) return (WorkRule.settleEpochs + WorkRule.baselineEpochs) / 2;
    final settle = math.max(0, WorkRule.settleEpochs - d.epochs.length);
    return (settle + d.baselineLeft) / 2;
  }

  /// The last hour as 12 cells of 5 minutes (oldest first).
  List<WorkCell> lastHour() {
    final now = _now();
    final out = List<WorkCell>.filled(stripCells, WorkCell.none);
    final from = now.subtract(const Duration(minutes: stripCells * cellMinutes));
    int? cellOf(DateTime t) {
      if (t.isBefore(from) || t.isAfter(now)) return null;
      return math.min(stripCells - 1, t.difference(from).inSeconds ~/ (cellMinutes * 60));
    }

    for (final e in _epochs) {
      final t = DateTime.tryParse('${e['t']}');
      final i = t == null ? null : cellOf(t.add(const Duration(seconds: 30)));
      if (i == null) continue;
      out[i] = switch (levelOf(e['level'] as String?)) {
        DrowsyLevel.alert => WorkCell.alert,
        DrowsyLevel.gettingDrowsy => WorkCell.gettingDrowsy,
        DrowsyLevel.drowsy => WorkCell.drowsy,
        DrowsyLevel.unknown => (_drowsy?.calibrated ?? false) ? WorkCell.unknown : WorkCell.none,
      };
    }
    for (final b in _planner?.breaks ?? const <WorkBreak>[]) {
      final end = b.end ?? now;
      for (var i = 0; i < stripCells; i++) {
        final a = from.add(Duration(minutes: i * cellMinutes)), z = a.add(const Duration(minutes: cellMinutes));
        if (b.start.isBefore(z) && end.isAfter(a)) out[i] = WorkCell.onBreak;
      }
    }
    return out;
  }

  WorkSignal get signal {
    if (signalLost) return WorkSignal.lost;
    if (!worn) return WorkSignal.off;
    final last = _drowsy?.epochs.lastOrNull;
    return last != null && last.cleanS < WorkRule.minCleanS ? WorkSignal.noisy : WorkSignal.good;
  }

  BandLink? _link;
  Detectors? _seen;
  WorkDrowsiness? _drowsy;
  BreakPlanner? _planner;
  Timer? _ticker;
  DateTime? _lastData, _savedAt, _heldAt;
  int? _lastPack;
  bool _gapPending = false, _quiet = false, _ended = false, _disposed = false;
  int _lostSamples = 0, _moveCursor = 0;
  final List<bool> _usable = [];
  final List<double> _closedAlpha = [];
  int _closedSeconds = 0;
  final List<Map<String, Object?>> _epochs = [];
  final List<Map<String, Object?>> _events = [];

  /// Connects, checks contact and starts: the eyes-closed minute first when [eyesClosedMinute].
  Future<void> start({bool eyesClosedMinute = false}) async {
    if (active) return;
    _reset();
    _set(WorkStage.connecting, 'Looking for the headband.');
    try {
      final link = BandLink(finder: finder, timing: timing.link, onBatch: _onBatch, onEvent: _onLinkEvent, clock: _now);
      _link = link;
      if (!await link.connect(onFound: (name) => _set(WorkStage.connecting, 'Found $name. Connecting.'))) {
        return await _fail('Headband not found. Is it switched on, charged, and free (no night recording)?');
      }
      if (_ended) return await link.close();
      _set(WorkStage.contact, 'Checking contact. Keep still for a few seconds.');
      contact = await link.contact();
      if (_ended) return await link.close();
      final now = _now();
      startedAt = now;
      _planner = BreakPlanner(earlier: _earlierHints(now));
      _seen = Detectors(onSecond: _onSecond);
      if (!eyesClosedMinute) _drowsy = WorkDrowsiness(onEpoch: _onEpoch);
      await link.startSignal();
      _lastData = null;
      _ticker = Timer.periodic(timing.tick, (_) => _tick());
      kept = await keeper.hold(_keep());
      keeper.onStop = () => unawaited(stop());
      _heldAt = _now();
      if (eyesClosedMinute) {
        closedLeft = closedMinuteS;
        unawaited(sound.cue(close: true));
        _set(WorkStage.eyesClosed, 'Close your eyes and sit still for a minute. A higher tone says when to open them.');
      } else {
        _set(WorkStage.calibrating, '');
      }
    } on TimeoutException catch (e) {
      await _fail('The headband did not answer (${e.message ?? 'timeout'}). Switch it off and on, then try again.');
    } catch (e) {
      await _fail('Could not start: $e');
    }
  }

  List<WorkHint> _earlierHints(DateTime now) {
    try {
      return store?.hintsOfDay(now) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  KeepSpec _keep() {
    final h = hint;
    final String text;
    if (h != null) {
      text = hintTitle(h);
    } else if (onBreak) {
      text = 'On a break';
    } else if (stage == WorkStage.running) {
      text = '${levelWords[level]} · ${_minutes(wornMin)} worn';
    } else {
      text = 'Calibrating';
    }
    return KeepSpec(title: 'Work session', text: text, headband: true);
  }

  void _reset() {
    _link = null;
    _seen = null;
    _drowsy = null;
    _planner = null;
    _lastData = null;
    _savedAt = null;
    _lastPack = null;
    _gapPending = false;
    _quiet = false;
    _ended = false;
    _lostSamples = 0;
    _moveCursor = 0;
    _usable.clear();
    _closedAlpha.clear();
    _closedSeconds = 0;
    _epochs.clear();
    _events.clear();
    closedAlpha = null;
    closedLeft = 0;
    hint = null;
    afterBreak = null;
    last = null;
    saveNote = null;
    contact = const {};
    startedAt = null;
    worn = false;
    kept = false;
  }

  // ---- signal ----

  void _onBatch(DateTime now, List<Sample> batch) {
    final seen = _seen;
    if (seen == null || _ended || batch.isEmpty) return;
    final last = _lastData;
    if (last != null && now.difference(last).inMicroseconds / 1e6 > 1 + batch.length / fs) {
      _gapPending = true;
      _lostSamples = 0; // unknown length
    }
    _lastData = now;
    _quiet = false;
    for (final x in batch) {
      final prev = _lastPack;
      if (prev != null) {
        final skip = (x.pack - prev - 1) % packetWrap;
        if (skip >= workGapSamples && skip <= maxGapSamples) {
          _gapPending = true;
          _lostSamples = skip;
        }
      }
      _lastPack = x.pack;
      if (_gapPending) {
        seen.hold(_lostSamples > 0 ? math.min(_lostSamples, maxGapSamples) : fs);
        _gapPending = false;
        _lostSamples = 0;
      }
      final row = [x.o1 * 1e6, x.o2 * 1e6, x.t3 * 1e6, x.t4 * 1e6]; // the SDK gives volts
      if (row.every((v) => v.isFinite)) seen.push(row);
    }
  }

  void _onSecond(Second s) {
    final seen = _seen!;
    var moves = 0;
    while (_moveCursor < seen.eyeMoves.length && seen.eyeMoves[_moveCursor].i ~/ fs <= s.k) {
      if (seen.eyeMoves[_moveCursor].i ~/ fs == s.k) moves++;
      _moveCursor++;
    }
    final x = workInputOf(s, eyeMoves: moves);
    _usable.add(x.backClean && !x.gap);
    if (_usable.length > wornOf) _usable.removeAt(0);
    if (stage == WorkStage.eyesClosed) return _closedSecond(x);
    _drowsy?.second(x);
  }

  void _closedSecond(WorkInput x) {
    _closedSeconds++;
    if (x.backClean && !x.movement && !x.muscle && !x.gap && x.blinks == 0) _closedAlpha.add(x.alpha);
    closedLeft = math.max(0, closedMinuteS - _closedSeconds);
    if (_closedSeconds < closedMinuteS) return;
    closedAlpha = _closedAlpha.length >= closedMinCleanS ? median(_closedAlpha) : null;
    _events.add({
      'at': _now().toIso8601String(),
      'event': closedAlpha == null ? 'eyes-closed minute too noisy: not used' : 'eyes-closed minute done',
      'clean_s': _closedAlpha.length,
    });
    _drowsy = WorkDrowsiness(closedAlpha: closedAlpha, onEpoch: _onEpoch);
    unawaited(sound.cue(close: false));
    _set(WorkStage.calibrating, '');
  }

  void _onEpoch(WorkEpoch e) {
    final now = _now();
    _epochs.add({'t': now.subtract(const Duration(seconds: 30)).toIso8601String(), ...e.toJson()});
    _planner?.epoch(e.level, eyesClosed: e.eyesClosed, window: e.window);
    if (stage == WorkStage.calibrating && (_drowsy?.calibrated ?? false)) _set(WorkStage.running, '');
    _afterBreakLine();
    _notify();
  }

  void _afterBreakLine() {
    final b = _planner?.breaks.lastOrNull;
    if (b == null || b.end == null) return;
    afterBreak = afterBreakWords(b);
  }

  void _tick() {
    if (_ended) return;
    final now = _now(), lastData = _lastData;
    if (lastData != null && now.difference(lastData) > timing.noDataAfter) _quiet = true;
    worn = !signalLost && lastData != null && _usable.where((u) => u).length >= wornNeeded;
    _link?.tick();
    final p = _planner;
    if (p != null && stage.index >= WorkStage.calibrating.index && stage != WorkStage.ending) {
      final h = p.tick(now, worn: worn);
      if (h != null) _showHint(h);
    }
    if (_savedAt == null || now.difference(_savedAt!) >= timing.saveEvery) _save(now);
    if (_heldAt != null && now.difference(_heldAt!) >= timing.holdEvery) _rehold();
    _notify();
  }

  void _showHint(WorkHint h) {
    hint = h;
    _events.add({'at': h.at.toIso8601String(), 'event': 'hint', 'reason': h.reason.name});
    unawaited(sound.chime());
    _rehold();
  }

  void _rehold() {
    _heldAt = _now();
    unawaited(keeper.hold(_keep()).then((k) => kept = k));
  }

  // ---- taps ----

  /// "On a break" (also the hint's answer).
  void takeBreak() {
    final p = _planner;
    if (p == null || p.onBreak || !active) return;
    final now = _now();
    if (hint != null) {
      p.answer(HintAnswer.onBreak, now);
      hint = null;
    } else {
      p.startBreak(now);
    }
    afterBreak = null;
    _rehold();
    _notify();
  }

  /// "Back" from a break.
  void back() {
    final p = _planner;
    if (p == null || !p.onBreak) return;
    p.endBreak(_now());
    _afterBreakLine();
    _rehold();
    _notify();
  }

  /// Snooze 20 min, or Not now.
  void answer(HintAnswer a) {
    final p = _planner;
    if (p == null || hint == null || a == HintAnswer.onBreak) return;
    p.answer(a, _now());
    hint = null;
    _rehold();
    _notify();
  }

  /// "How sharp do you feel?" 1-5 (with a hint or on its own).
  void rate(int value) {
    _planner?.rate(value, _now());
    _notify();
  }

  void _onLinkEvent(LinkEvent e, String line) {
    if (e == LinkEvent.reconnectTry) return;
    _events.add({'at': _now().toIso8601String(), 'event': line});
    if (e == LinkEvent.drop) {
      _gapPending = true;
      _lastPack = null;
    }
    _notify();
  }

  // ---- end ----

  Future<void> stop() async {
    if (_ended) return;
    final connecting = stage.index < WorkStage.eyesClosed.index;
    _ended = true;
    _ticker?.cancel();
    if (connecting) {
      _set(WorkStage.setup, 'Stopped.');
      await keeper.release();
      return;
    }
    _set(WorkStage.ending, 'Stopping.');
    final p = _planner;
    if (p != null && p.onBreak) p.endBreak(_now());
    await _link?.close();
    await keeper.release();
    await sound.stop();
    _save(_now(), end: true);
    _set(WorkStage.done, '');
  }

  Future<void> _fail(String why) async {
    final stopped = _ended;
    _ended = true;
    _ticker?.cancel();
    await _link?.close();
    await keeper.release();
    if (!stopped) _set(WorkStage.failed, why);
  }

  /// Back to the start page after a session or a failure.
  void again() {
    if (active) return;
    _set(WorkStage.setup, '');
  }

  Map<String, Object?> sessionJson(DateTime now, {bool end = false}) {
    final d = _drowsy, p = _planner;
    final minutes = <String, double>{for (final l in DrowsyLevel.values) levelKey(l): 0, 'eyes_closed': 0};
    for (final e in d?.epochs ?? const <WorkEpoch>[]) {
      if (e.eyesClosed) minutes['eyes_closed'] = minutes['eyes_closed']! + 0.5;
      if (d!.calibratedAtS != null && e.startS >= d.calibratedAtS!) minutes[levelKey(e.level)] = minutes[levelKey(e.level)]! + 0.5;
    }
    return {
      'version': workFormatVersion,
      'kind': 'work_session',
      'app': 'eeg_tracker work',
      'start': startedAt!.toIso8601String(),
      'end': now.toIso8601String(),
      'ended': end ? 'stopped' : 'running',
      'headband': _link?.name,
      'contact_ohms': contact,
      'closed_alpha': closedAlpha,
      'baseline': d?.baseline?.toJson(),
      'calibrated_at_s': d?.calibratedAtS,
      'worn_min': (wornMin * 10).round() / 10,
      'minutes': minutes,
      ...?p?.toJson(),
      'events': _events,
      'epochs': _epochs,
    };
  }

  void _save(DateTime now, {bool end = false}) {
    _savedAt = now;
    if (startedAt == null) return;
    final json = sessionJson(now, end: end);
    if (end) last = json;
    final st = store;
    if (st == null) return;
    try {
      st.save(json);
      saveNote = null;
    } catch (e) {
      saveNote = 'This session could not be saved: $e';
    }
  }

  void _set(WorkStage s, String text) {
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
    if (!_ended && active) unawaited(stop());
    _ticker?.cancel();
    super.dispose();
  }
}

String _minutes(double m) {
  final total = m.floor();
  return total < 60 ? '$total min' : '${total ~/ 60} h ${(total % 60).toString().padLeft(2, '0')} min';
}

/// "1 h 05 min" or "42 min".
String workMinutes(double m) => _minutes(m);

/// The hint's first line.
String hintTitle(WorkHint h) => switch (h.reason) {
  HintReason.drowsy => 'You seem to be getting drowsy. A few minutes away?',
  HintReason.eyesClosed => 'Your eyes have been closed a while. Resting, or nodding off? A short break may help.',
  HintReason.stretch || HintReason.snooze => "You've been at it for ${_minutes(h.activeMin)}. A few minutes away from the screen?",
};

/// After a break: did drowsiness go back down? Null until the first 5 minutes after it are read.
String? afterBreakWords(WorkBreak b) {
  final after = b.after, before = b.before;
  if (after == null) return b.end == null ? null : 'Back from your break: drowsiness is read again over the next 5 minutes.';
  final words = levelWords[b.afterLevel ?? DrowsyLevel.unknown]!.toLowerCase();
  if (before == null) return 'After your break: $words.';
  final was = levelWords[b.beforeLevel ?? DrowsyLevel.unknown]!.toLowerCase();
  final d = after - before;
  final how = d <= -0.25
      ? 'went down'
      : d >= 0.25
      ? 'went up'
      : 'about the same';
  return 'After your break: drowsiness $how ($was before, $words after).';
}
