// The work session (ROADMAP row 35, DECISIONS 440-449): the headband on while you work, the phone watching for
// drowsiness and suggesting breaks. Holds the headband from this screen, only between nights. The phone can be locked:
// the session keeper (SessionService.kt) holds it with a notification whose words follow the level and the hint; the
// screen is kept on only when the phone refused that. Layout in work_view.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../phone.dart';
import '../recorder/brainbit.dart';
import '../session_keeper.dart';
import '../sound/audio_route.dart' show phoneInCall, phoneMediaVolume;
import '../sound/soloud_work_sound.dart';
import '../wearer/wearer.dart';
import '../work/breaks.dart';
import '../work/controller.dart';
import '../work/store.dart';
import 'evidence_sheet.dart';
import 'nearby.dart';
import 'work_view.dart';

/// A work session holds the headband: the night screen must not start a night meanwhile.
bool workSessionRunning = false;

class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key});

  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final WorkController _c = WorkController(
    finder: _finder,
    sound: SoloudWorkSound(),
    keeper: PhoneSessionKeeper(),
    inCall: phoneInCall,
    mediaVolume: phoneMediaVolume,
  );
  bool _nightRunning = false, _eyesClosedFirst = false, _screenOn = false;
  List<WorkSummary> _sessions = const [];
  String? _recordings;
  bool _wearerOn = false;
  WorkStage _lastStage = WorkStage.setup;
  int? _rated;
  WorkHint? _ratedFor;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec != null) {
        _recordings = rec;
        _c.store = WorkStore(workDirFor(rec));
      }
    } catch (_) {
      // without the folder the session still runs; it is just not saved
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() => _nightRunning = running);
    await _load();
  }

  /// The earlier sessions (decoded away from the screen's thread; each file once while it is unchanged) and the
  /// "Was this you?" switch.
  Future<void> _load() async {
    final rec = _recordings;
    bool wearerOn;
    try {
      wearerOn = rec != null && WearerStore(wearerDirFor(rec)).on;
    } catch (_) {
      wearerOn = false;
    }
    List<WorkSummary> sessions;
    try {
      sessions = await (_c.store?.listAsync() ?? Future.value(const <WorkSummary>[]));
    } catch (_) {
      sessions = const [];
    }
    if (!mounted) return;
    setState(() {
      _wearerOn = wearerOn;
      _sessions = sessions;
    });
  }

  void _changed() {
    if (!mounted) return;
    if (_c.stage != _lastStage) {
      _lastStage = _c.stage;
      workSessionRunning = _c.active;
      if (!_c.active) {
        _finder.dispose(anyLost: _c.leftLost);
        unawaited(_load());
      }
      // the clock on screen (worn minutes, the strip) moves even between epochs
      _clock?.cancel();
      if (_c.active) _clock = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
    }
    // the phone refused the background hold: keep the screen on instead, as before sessions could be locked
    final on = _c.active && !_c.kept && _c.stage.index >= WorkStage.calibrating.index;
    if (on != _screenOn) {
      _screenOn = on;
      unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    _c.removeListener(_changed);
    _c.dispose(); // ends a running session and saves it
    if (_screenOn) unawaited(Phone.keepScreenOn(on: false).catchError((Object _) {}));
    workSessionRunning = false;
    super.dispose();
  }

  Future<void> _start() async {
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _nightRunning = true);
      return;
    }
    final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
    if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
      _say('Allow Nearby devices first: without it the headband cannot be found.');
      return;
    }
    if (!phone.bluetoothOn) {
      _say('Turn Bluetooth on, then start.');
      await Phone.openSettings('bluetooth');
      return;
    }
    // the hints and Stop live on the session's notification while the phone is locked
    if (phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
    _rated = null;
    await _c.start(eyesClosedMinute: _eyesClosedFirst);
  }

  Future<bool> _confirmStop() async {
    if (_c.stage.index < WorkStage.eyesClosed.index) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the work session?'),
        content: const Text('What it saw so far is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _stop() async {
    if (await _confirmStop()) await _c.stop();
  }

  void _rate(int v) {
    _c.rate(v);
    setState(() {
      _rated = v;
      _ratedFor = _c.hint;
    });
    // the "saved" line stays a few seconds, then the row is ready for the next time
    Timer(const Duration(seconds: 4), () {
      if (mounted && identical(_ratedFor, _c.hint)) setState(() => _rated = null);
    });
  }

  /// "Someone else wore it" (or Undo): kept in the session's own file, so the trends leave it out.
  void _answerWearer(WorkSummary session, String? answer) {
    final rec = _recordings;
    if (rec == null) return;
    try {
      answerWearer(rec, kindWork, session.id, answer, DateTime.now());
    } catch (e) {
      _say('Not saved: $e');
    }
    unawaited(_load());
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// The session that just ended, as its file now says (the answer to "Was this you?" lives there).
  WorkSummary? _summaryOf(Map<String, Object?>? last) {
    final s = last == null ? null : WorkSummary.fromJson(last);
    return s == null ? null : _sessions.where((x) => x.start == s.start).firstOrNull ?? s;
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final now = DateTime.now();
    final b = c.planner?.currentBreak;
    final last = c.last;
    final model = WorkViewModel(
      stage: c.stage,
      message: c.message,
      nightRunning: _nightRunning,
      eyesClosedFirst: _eyesClosedFirst,
      level: c.level,
      eyesClosedNow: c.drowsiness?.eyesClosed ?? false,
      noisy: c.drowsiness?.noisy ?? false,
      cells: c.active ? c.lastHour() : const [],
      wornMin: c.wornMin,
      stretchMin: c.stretchMin,
      hintsToday: c.planner?.hintsToday(now) ?? 0,
      signal: c.signal,
      hint: c.hint,
      rated: _rated,
      onBreak: c.onBreak,
      breakMin: b == null ? 0 : now.difference(b.start).inSeconds / 60,
      afterBreak: c.afterBreak,
      closedLeft: c.closedLeft,
      calibrationLeftMin: c.calibrationLeftMin,
      kept: c.kept || !c.active,
      summary: _summaryOf(last),
      wearerOn: _wearerOn,
      sessions: _sessions,
      saveNote: c.saveNote ?? (c.store == null && c.stage == WorkStage.done ? 'This session was not saved.' : null),
      volumeNote: c.active ? c.volumeNote : null,
    );
    return PopScope(
      canPop: !c.active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmStop()) return;
        await c.stop();
        if (mounted) Navigator.of(this.context).pop();
      },
      child: WorkView(
        model: model,
        onStart: _start,
        onStop: _stop,
        onBreak: c.takeBreak,
        onBack: c.back,
        onSnooze: () => c.answer(HintAnswer.snoozed),
        onNotNow: () => c.answer(HintAnswer.notNow),
        onRate: _rate,
        onEyesClosedFirst: (v) => setState(() => _eyesClosedFirst = v),
        onAgain: () {
          c.again();
          unawaited(_load());
        },
        onInfo: () => showEvidence(context, 'work-session'),
        onWearer: _answerWearer,
        onWearerInfo: () => showEvidence(context, 'was-this-you'),
      ),
    );
  }
}
