// The Memory cues page, the evening task and the morning test (DECISIONS 500-509): reads and writes
// files/memory_cues (memory_cues/store.dart), and plays the sounds through the player the night recorder uses
// (lucid/bell.dart). The views are memory_cues_view.dart and memory_task_view.dart; this file holds the state.
import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../lucid/bell.dart';
import '../lucid/practice.dart' show PracticeRule, loudnessGain, loudnessSteps;
import '../lucid/store.dart' show LucidStore, lucidDirFor;
import '../memory_cues/plan.dart';
import '../memory_cues/store.dart';
import '../memory_cues/task.dart';
import '../phone.dart';
import '../recorder/recorder_service.dart' show loadNight;
import 'evidence_sheet.dart';
import 'memory_cues_view.dart';
import 'memory_task_view.dart';

/// A night's morning test may be done until this long after the night's start (and before the next evening task).
const Duration morningTestWithin = Duration(hours: 30);

/// The sounds' share of the media volume in the evening task: soft but clear (a planning value).
const double taskGain = 0.25;

/// The night's evening and morning distances per half, as the results read them.
MemoryNight memoryNight(MemoryNightRecord r, MemorySession? s, MemoryMorning? m) => MemoryNight(
  index: r.index,
  cueMoments: r.cues.length,
  arousedMoments: r.cues.where((c) => c.aroused).length,
  evening: s == null ? const [0, 0] : [halfError(s, s.evening, 0), halfError(s, s.evening, 1)],
  morning: s == null || m == null ? null : [halfError(s, m.taps, 0), halfError(s, m.taps, 1)],
  heard: m?.heard,
);

/// What the page needs from the files (pure, for tests). [lucidOn]: the lucid cues are switched on.
MemoryViewModel memoryModel({
  required MemoryStore store,
  required DateTime now,
  required bool nightRunning,
  required bool lucidOn,
  int? runningStartMs,
}) {
  final on = store.settings().on;
  final records = store.nights();
  final sessions = store.sessions();
  final done = [
    for (final r in records)
      if (!(nightRunning && r.startMs == runningStartMs)) r,
  ];
  final byId = {for (final s in sessions) s.id: s};
  final mornings = {for (final r in done) r.stamp: store.morning(r.stamp)};
  bool expired(MemoryNightRecord r) =>
      now.millisecondsSinceEpoch - r.startMs >= morningTestWithin.inMilliseconds ||
      sessions.any((s) => s.made.millisecondsSinceEpoch > r.startMs + const Duration(hours: 1).inMilliseconds);
  final last = done.isEmpty ? null : done.last;
  final morningDue = last != null && mornings[last.stamp] == null && !expired(last) && !nightRunning;
  final used = {for (final r in records) r.session};
  MemorySession? fresh;
  for (final s in sessions) {
    if (!s.isComplete || used.contains(s.id)) continue;
    final age = now.difference(s.completed!);
    if (age >= Duration.zero && age <= sessionFreshFor) fresh = s;
  }
  final due = morningDue
      ? MemoryDue.morning
      : !on
      ? MemoryDue.turnOn
      : lucidOn
      ? MemoryDue.waiting
      : nightRunning
      ? MemoryDue.night
      : fresh != null
      ? MemoryDue.ready
      : MemoryDue.evening;
  final finished = [
    for (final r in done)
      if (mornings[r.stamp] != null || expired(r)) r,
  ];
  MemoryResults? results;
  final test = store.test();
  if (test != null) {
    results = memoryResults(
      plan: test.plan,
      planSha: test.planSha,
      sealed: test.sealed,
      nights: [for (final r in finished) memoryNight(r, byId[r.session], mornings[r.stamp])],
    );
  }
  final byIndex = {for (final r in finished) r.index: r};
  final count = finished.isEmpty ? 0 : finished.map((r) => r.index).reduce(math.max) + 1;
  final withLevels = [
    for (final s in sessions)
      if (s.levels != null) s,
  ];
  return MemoryViewModel(
    on: on,
    due: due,
    lucidOn: lucidOn,
    readyAt: fresh?.completed,
    nightRunning: nightRunning,
    last: last == null
        ? null
        : MemoryLastNight(
            record: last,
            session: byId[last.session],
            morning: mornings[last.stamp],
            expired: mornings[last.stamp] == null && expired(last),
          ),
    nights: [
      for (var i = 0; i < count; i++)
        (answered: byIndex[i] != null && mornings[byIndex[i]!.stamp] != null, lucid: false),
    ],
    nextIndex: store.nextIndex(),
    results: results,
    levels: withLevels.isEmpty ? null : withLevels.last.levels,
  );
}

/// The night screen's one line for the Memory cues section; null when they were never used.
String? memoryNightLine(String recordingsDir, {DateTime? now}) {
  try {
    final store = MemoryStore(memoryDirFor(recordingsDir));
    final lucidOn = LucidStore(lucidDirFor(recordingsDir)).settings().on;
    final m = memoryModel(store: store, now: now ?? DateTime.now(), nightRunning: false, lucidOn: lucidOn);
    if (!m.on && m.last == null) return null;
    return switch (m.due) {
      MemoryDue.morning => 'This morning\'s test is waiting: about 2 minutes.',
      MemoryDue.turnOn => 'Off.',
      MemoryDue.waiting => 'On, waiting: lucid cues are on tonight.',
      MemoryDue.evening => 'On: learn the board before Sleep.',
      MemoryDue.ready || MemoryDue.night => 'Ready: learned at ${_hm(m.readyAt)}.',
    };
  } catch (_) {
    return null;
  }
}

String _hm(DateTime? t) =>
    t == null ? '-' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class MemoryCuesScreen extends StatefulWidget {
  const MemoryCuesScreen({super.key});

  @override
  State<MemoryCuesScreen> createState() => _MemoryCuesScreenState();
}

class _MemoryCuesScreenState extends State<MemoryCuesScreen> {
  String? _rec;
  MemoryStore? _store;
  bool _running = false, _lucidOn = false;
  int? _runningStart;
  MemoryViewModel? _model;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      _rec = await Phone.recordingsDir();
      if (_rec != null) {
        _store = MemoryStore(memoryDirFor(_rec!));
        _lucidOn = LucidStore(lucidDirFor(_rec!)).settings().on;
      }
      _running = await FlutterForegroundTask.isRunningService;
      if (_running) _runningStart = (await loadNight()).startMs;
    } catch (_) {}
    _reload();
  }

  void _reload() {
    final st = _store;
    if (!mounted || st == null) return;
    setState(() {
      try {
        _model = memoryModel(
          store: st,
          now: DateTime.now(),
          nightRunning: _running,
          lucidOn: _lucidOn,
          runningStartMs: _runningStart,
        );
      } catch (_) {
        _model = const MemoryViewModel(on: false, due: MemoryDue.turnOn);
      }
    });
  }

  void _turnOn() {
    final st = _store;
    if (st == null) return;
    final now = DateTime.now();
    st.setOn(true, now);
    st.ensureTest(now);
    _reload();
  }

  void _turnOff() {
    _store?.setOn(false, DateTime.now());
    _reload();
  }

  Future<void> _task({required bool morning}) async {
    final st = _store, m = _model;
    if (st == null) return;
    MemorySession? session;
    MemoryNightRecord? night;
    if (morning) {
      night = m?.last?.record;
      session = m?.last?.session;
      if (night == null || session == null) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryTaskScreen(store: st, morningOf: night, session: session),
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    if (m == null) return const Scaffold(body: SizedBox.shrink());
    return MemoryView(
      model: m,
      onTurnOn: _turnOn,
      onTurnOff: _turnOff,
      onEvening: () => unawaited(_task(morning: false)),
      onMorning: () => unawaited(_task(morning: true)),
      onInfo: () => showEvidence(context, 'memory-cues'),
    );
  }
}

/// The evening task ([morningOf] null: a new session is drawn) or the morning test of the night [morningOf] on its
/// [session].
class MemoryTaskScreen extends StatefulWidget {
  const MemoryTaskScreen({super.key, required this.store, this.morningOf, this.session, this.bell, this.random});
  final MemoryStore store;
  final MemoryNightRecord? morningOf;
  final MemorySession? session;
  final CueBell? bell;
  final math.Random? random;

  @override
  State<MemoryTaskScreen> createState() => _MemoryTaskScreenState();
}

class _MemoryTaskScreenState extends State<MemoryTaskScreen> {
  late final CueBell _bell = widget.bell ?? ChannelCueBell();
  late final math.Random _r = widget.random ?? math.Random.secure();
  late List<File> _sounds;
  late TaskViewModel _m;
  LearnRounds? _learn;
  Timer? _timer;
  int _studyAt = 0, _testAt = 0, _step = 0;
  final List<double> _levels = [];
  late List<String> _testOrder;
  final Map<String, BoardPoint> _taps = {};
  bool _busy = false, _saved = false;

  bool get _morning => widget.morningOf != null;

  @override
  void initState() {
    super.initState();
    final st = widget.store;
    _sounds = st.ensureSounds();
    final session =
        widget.session ??
        drawSession(
          _r,
          DateTime.now(),
          avoid: {
            for (final s in st.sessions().reversed.take(1))
              for (final i in s.items) i.object,
          },
        );
    _testOrder = [for (final i in session.items) i.object]..shuffle(_r);
    _m = TaskViewModel(morning: _morning, phase: TaskPhase.intro, session: session);
  }

  void _play(int sound, double gain) => unawaited(_bell.play(_sounds[sound], gain).catchError((Object _) => false));

  void _set(TaskViewModel m) {
    if (mounted) setState(() => _m = m);
  }

  void _start() {
    final w = MediaQuery.sizeOf(context).width - 48;
    if (_morning) {
      _set(_m.copyWith(phase: TaskPhase.test, object: _testOrder.first, clearTap: true, done: {}));
      return;
    }
    final s = _m.session.copyWith(boardDp: w);
    widget.store.saveSession(s);
    _set(_m.copyWith(session: s, phase: TaskPhase.study));
    _studyNext();
  }

  void _studyNext() {
    final order = _m.session.studyOrder;
    if (_studyAt >= order.length) {
      _learn = LearnRounds(_m.session, _r);
      _set(_m.copyWith(phase: TaskPhase.learn, object: _learn!.current, clearTap: true, showPlace: false, done: {}));
      return;
    }
    final o = order[_studyAt];
    _set(_m.copyWith(object: o, done: order.take(_studyAt).toSet()));
    _play(_m.session.itemOf(o).sound, taskGain);
    _studyAt++;
    _timer = Timer(const Duration(milliseconds: TaskRule.studyMs + TaskRule.studyGapMs), _studyNext);
  }

  void _tap(BoardPoint p) {
    if (_busy) return;
    switch (_m.phase) {
      case TaskPhase.learn:
        final l = _learn!, o = l.current!;
        final close = l.place(p);
        final learned = {..._m.done, if (close) o};
        _busy = true;
        _set(_m.copyWith(tap: p, showPlace: true, close: close, done: learned));
        _play(_m.session.itemOf(o).sound, taskGain);
        _timer = Timer(const Duration(milliseconds: 1800), () {
          _busy = false;
          if (l.done) {
            final s = _m.session.copyWith(learn: l.placements);
            widget.store.saveSession(s);
            _testAt = 0;
            _taps.clear();
            _set(
              _m.copyWith(
                session: s,
                phase: TaskPhase.test,
                object: _testOrder.first,
                clearTap: true,
                showPlace: false,
                done: {},
              ),
            );
          } else {
            _set(_m.copyWith(object: l.current, clearTap: true, showPlace: false, round: l.round));
          }
        });
      case TaskPhase.test:
        final o = _testOrder[_testAt];
        _taps[o] = p;
        _testAt++;
        _busy = true;
        _set(_m.copyWith(tap: p, done: {..._m.done, o}));
        _timer = Timer(const Duration(milliseconds: 350), () {
          _busy = false;
          if (_testAt < _testOrder.length) {
            _set(_m.copyWith(object: _testOrder[_testAt], clearTap: true));
          } else {
            _testDone();
          }
        });
      default:
    }
  }

  void _testDone() {
    if (_morning) {
      _set(_m.copyWith(phase: TaskPhase.heard, morningTaps: Map.of(_taps)));
      return;
    }
    final s = _m.session.copyWith(evening: Map.of(_taps), eveningEnd: DateTime.now());
    widget.store.saveSession(s);
    unawaited(Phone.keepScreenOn(on: true).catchError((Object _) {}));
    _step = 0;
    _set(_m.copyWith(session: s, phase: TaskPhase.loudness, loudnessSound: 0, loudnessStep: 0));
    _loudnessTick();
    _timer = Timer.periodic(const Duration(seconds: PracticeRule.loudnessEveryS), (_) => _loudnessTick());
  }

  void _loudnessTick() {
    if (_step >= loudnessSteps) {
      _heardSound(); // the full media volume: as loud as it goes
      return;
    }
    _play(_m.loudnessSound, loudnessGain(_step));
    _step++;
    _set(_m.copyWith(loudnessStep: _step));
  }

  Future<void> _heardSound() async {
    _levels.add(loudnessGain(math.max(0, _step - 1)));
    _timer?.cancel();
    if (_levels.length == 1) {
      // the knock starts 12 dB under the bell's level, so the second ramp is short
      _step = math.max(0, _step - 1 - 6);
      _set(_m.copyWith(loudnessSound: 1, loudnessStep: _step));
      _loudnessTick();
      _timer = Timer.periodic(const Duration(seconds: PracticeRule.loudnessEveryS), (_) => _loudnessTick());
      return;
    }
    unawaited(Phone.keepScreenOn(on: false).catchError((Object _) {}));
    final v = await _bell.mediaVolume().catchError((Object _) => null);
    final s = _m.session.copyWith(
      levels: List.of(_levels),
      mediaVolume: v?.volume,
      mediaVolumeMax: v?.max,
      completed: DateTime.now(),
    );
    widget.store.saveSession(s);
    _saved = true;
    _set(_m.copyWith(session: s, phase: TaskPhase.done));
  }

  void _saveMorning() {
    final night = widget.morningOf, heard = _m.heard;
    if (night == null || heard == null) return;
    final s = _m.session;
    widget.store.saveMorning(
      night.stamp,
      MemoryMorning(session: s.id, made: DateTime.now(), taps: Map.of(_taps), heard: heard),
    );
    _saved = true;
    _set(
      _m.copyWith(
        phase: TaskPhase.result,
        numbers: (
          closeEvening: closeCount(s, s.evening),
          closeMorning: closeCount(s, _taps),
          distEvening: meanError(s, s.evening),
          distMorning: meanError(s, _taps),
        ),
      ),
    );
  }

  Future<void> _stop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: Text(
          _morning
              ? 'Stop the morning test? Nothing is saved; you can start it again until the next evening task.'
              : 'Stop the evening task? Tonight then has no sounds; you can start again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Go on')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _timer?.cancel();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_m.phase == TaskPhase.loudness) unawaited(Phone.keepScreenOn(on: false).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _saved || _m.phase == TaskPhase.intro,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_stop());
    },
    child: TaskView(
      model: _m,
      onStart: _start,
      onTap: _tap,
      onHeardSound: () => unawaited(_heardSound()),
      onStop: () => unawaited(_stop()),
      onHeardAnswer: (h) => _set(_m.copyWith(heard: h)),
      onSave: _saveMorning,
      onDone: () => Navigator.of(context).pop(),
    ),
  );
}
