// The Lucid dreams page and the evening practice (DECISIONS 300-309): reads and writes files/lucid (lucid/store.dart),
// runs the morning search for dream signals in the background, and plays the practice's cues through the same
// player the night recorder uses (lucid/bell.dart). The page is lucid_view.dart; this file holds the state.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../lucid/bell.dart';
import '../lucid/morning.dart';
import '../lucid/plan.dart';
import '../lucid/practice.dart';
import '../lucid/store.dart';
import '../phone.dart';
import '../recorder/recorder_service.dart' show loadNight;
import 'evidence_sheet.dart';
import 'lucid_view.dart';

/// A night's morning questions may be answered until this long after the night's start.
const Duration answerWithin = Duration(hours: 30);

/// What the page needs from the files (pure, for tests).
LucidViewModel lucidModel({
  required LucidStore store,
  required DateTime now,
  required bool nightRunning,
  int? runningStartMs,
  LucidDraft draft = const LucidDraft(),
  Set<String> searching = const {},
}) {
  final s = store.settings();
  final records = store.nights();
  final practices = store.practices();
  final done = [
    for (final r in records)
      if (!(nightRunning && r.startMs == runningStartMs)) r,
  ];
  final last = done.isEmpty ? null : done.last;
  final answers = {for (final r in records) r.stamp: store.answers(r.stamp)};
  DateTime? practised;
  for (final p in practices) {
    if (!p.completed) continue;
    final age = now.difference(p.end);
    if (age >= Duration.zero && age <= const Duration(hours: 3)) practised = p.end;
  }
  final lastAnswers = last == null ? null : answers[last.stamp];
  final due = !s.on && last == null
      ? LucidDue.turnOn
      : last != null &&
            lastAnswers == null &&
            !nightRunning &&
            now.millisecondsSinceEpoch - last.startMs < answerWithin.inMilliseconds
      ? LucidDue.answer
      : !s.on
      ? LucidDue.turnOn
      : s.level == null || (practised == null && !nightRunning)
      ? LucidDue.practise
      : LucidDue.ready;
  LucidResults? results;
  final test = store.test();
  if (test != null) {
    results = lucidResults(
      plan: test.plan,
      planSha: test.planSha,
      sealed: test.sealed,
      nights: [
        for (final r in done)
          nightForResults(r, answers: answers[r.stamp], signals: store.signals(r.stamp), practices: practices),
      ],
    );
  }
  final byIndex = {for (final r in done) r.index: r};
  final count = done.isEmpty ? 0 : done.map((r) => r.index).reduce(math.max) + 1;
  return LucidViewModel(
    on: s.on,
    due: due,
    level: s.level,
    practisedAt: practised,
    nightRunning: nightRunning,
    last: last == null
        ? null
        : LucidLastNight(
            record: last,
            signals: store.signals(last.stamp),
            answers: lastAnswers,
            searching: searching.contains(last.stamp),
          ),
    nights: [
      for (var i = 0; i < count; i++)
        (
          answered: byIndex[i] != null && answers[byIndex[i]!.stamp] != null,
          lucid: byIndex[i] != null && answers[byIndex[i]!.stamp]?.lucid == 'yes',
        ),
    ],
    nextIndex: store.nextIndex(),
    results: results,
    draft: draft,
  );
}

/// The night screen's one line for the Lucid dreams section; null when the cues were never used.
String? lucidNightLine(String recordingsDir, {DateTime? now}) {
  try {
    final store = LucidStore(lucidDirFor(recordingsDir));
    final m = lucidModel(store: store, now: now ?? DateTime.now(), nightRunning: false);
    if (!m.on && m.last == null) return null;
    return switch (m.due) {
      LucidDue.answer => 'Last night\'s questions are waiting.',
      LucidDue.turnOn => 'Off.',
      LucidDue.practise =>
        m.level == null ? 'On: practise first, it sets the loudness.' : 'On: practise before you sleep.',
      LucidDue.ready =>
        'On; practised at ${m.practisedAt!.hour.toString().padLeft(2, '0')}:'
            '${m.practisedAt!.minute.toString().padLeft(2, '0')}.',
    };
  } catch (_) {
    return null;
  }
}

class LucidScreen extends StatefulWidget {
  const LucidScreen({super.key});

  @override
  State<LucidScreen> createState() => _LucidScreenState();
}

class _LucidScreenState extends State<LucidScreen> {
  String? _rec;
  LucidStore? _store;
  bool _running = false;
  int? _runningStart;
  LucidDraft _draft = const LucidDraft();
  final Set<String> _searching = {};
  LucidViewModel? _model;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      _rec = await Phone.recordingsDir();
      if (_rec != null) _store = LucidStore(lucidDirFor(_rec!));
      _running = await FlutterForegroundTask.isRunningService;
      if (_running) _runningStart = (await loadNight()).startMs;
    } catch (_) {}
    _reload();
    _searchIfDue();
  }

  void _reload() {
    final st = _store;
    if (!mounted || st == null) return;
    setState(() {
      try {
        _model = lucidModel(
          store: st,
          now: DateTime.now(),
          nightRunning: _running,
          runningStartMs: _runningStart,
          draft: _draft,
          searching: _searching,
        );
      } catch (_) {
        _model = const LucidViewModel(on: false, due: LucidDue.turnOn);
      }
    });
  }

  /// Last night's search for dream signals, when it has none yet or its stages came later.
  void _searchIfDue() {
    final st = _store, rec = _rec, last = _model?.last;
    if (st == null || rec == null || last == null || _running) return;
    final have = last.signals;
    if (have != null && have.staged) return;
    final stamp = last.record.stamp;
    if (_searching.contains(stamp)) return;
    _searching.add(stamp);
    _reload();
    unawaited(
      searchAndKeep(rec, st, last.record).catchError((Object _) => null).whenComplete(() {
        _searching.remove(stamp);
        _reload();
      }),
    );
  }

  Future<void> _turnOn() async {
    final st = _store;
    if (st == null) return;
    final now = DateTime.now();
    st.setOn(true, now);
    st.ensureTest(now);
    _reload();
    if (st.settings().level == null) await _practise();
  }

  void _turnOff() {
    _store?.setOn(false, DateTime.now());
    _reload();
  }

  Future<void> _practise() async {
    final st = _store;
    if (st == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LucidPracticeScreen(store: st)));
    _reload();
  }

  void _save() {
    final st = _store, last = _model?.last, a = _draft.answers;
    if (st == null || last == null || a == null) return;
    st.saveAnswers(last.record.stamp, a, DateTime.now());
    _draft = const LucidDraft();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final m = _model;
    if (m == null) return const Scaffold(body: SizedBox.shrink());
    return LucidView(
      model: m,
      onTurnOn: () => unawaited(_turnOn()),
      onTurnOff: _turnOff,
      onPractise: () => unawaited(_practise()),
      onDraft: (d) {
        _draft = d;
        _reload();
      },
      onSave: _save,
      onInfo: () => showEvidence(context, 'lucid-cues'),
    );
  }
}

class LucidPracticeScreen extends StatefulWidget {
  const LucidPracticeScreen({super.key, required this.store, this.bell});
  final LucidStore store;
  final CueBell? bell;

  @override
  State<LucidPracticeScreen> createState() => _LucidPracticeScreenState();
}

class _LucidPracticeScreenState extends State<LucidPracticeScreen> {
  late final CueBell _bell = widget.bell ?? ChannelCueBell();
  final DateTime _start = DateTime.now();
  PracticeViewModel _m = const PracticeViewModel(stage: PracticeStage.loudness);
  Timer? _timer;
  int _step = 0, _played = 0;
  double? _level;
  List<(int, PracticeCueKind)> _schedule = const [];
  DateTime? _partStart;
  int _next = 0;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    try {
      ensureCueWav(widget.store.cueWav);
    } catch (_) {}
    _timer = Timer.periodic(const Duration(seconds: PracticeRule.loudnessEveryS), (_) => _loudnessTick());
    _loudnessTick();
  }

  void _play(double gain) {
    _played++;
    unawaited(_bell.play(widget.store.cueWav, gain).catchError((Object _) => false));
  }

  void _loudnessTick() {
    if (_step >= loudnessSteps) {
      _heard(); // the full media volume: as loud as it goes
      return;
    }
    _play(loudnessGain(_step));
    _step++;
    if (mounted) setState(() => _m = PracticeViewModel(stage: PracticeStage.loudness, step: _step));
  }

  Future<void> _heard() async {
    _timer?.cancel();
    final level = loudnessGain(math.max(0, _step - 1));
    _level = level;
    final v = await _bell.mediaVolume().catchError((Object _) => null);
    widget.store.setLevel(level, DateTime.now(), mediaVolume: v?.volume, mediaVolumeMax: v?.max);
    _schedule = practiceSchedule(math.Random.secure());
    _partStart = DateTime.now();
    _next = 0;
    unawaited(Phone.keepScreenOn(on: true).catchError((Object _) {}));
    unawaited(Phone.dimScreen(on: true).catchError((Object _) {}));
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _cueTick());
    _cueTick();
  }

  void _cueTick() {
    final start = _partStart;
    if (start == null) return;
    final s = DateTime.now().difference(start).inMilliseconds / 1000;
    if (_next < _schedule.length && s >= _schedule[_next].$1) {
      final (_, kind) = _schedule[_next];
      _play(_level ?? PracticeRule.startGain);
      _next++;
      final inPart = kind == PracticeCueKind.guided ? _next : _next - PracticeRule.guided;
      setState(
        () => _m = PracticeViewModel(
          stage: kind == PracticeCueKind.guided ? PracticeStage.guided : PracticeStage.unguided,
          cue: inPart,
          showWords: kind == PracticeCueKind.guided,
          heardLevel: _level,
        ),
      );
    }
    if (_schedule.isNotEmpty && s >= practiceLengthS(_schedule)) _finish(completed: true);
  }

  void _finish({required bool completed}) {
    _timer?.cancel();
    unawaited(Phone.keepScreenOn(on: false).catchError((Object _) {}));
    unawaited(Phone.dimScreen(on: false).catchError((Object _) {}));
    if (!_saved && (_played > 0)) {
      _saved = true;
      widget.store.addPractice(
        PracticeRecord(start: _start, end: DateTime.now(), cues: math.max(0, _next), completed: completed),
      );
    }
    if (completed && mounted) setState(() => _m = PracticeViewModel(stage: PracticeStage.done, heardLevel: _level));
  }

  Future<void> _stop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        content: const Text('Stop the practice? The loudness is kept if you already tapped "I hear it".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Go on')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok != true) return;
    _finish(completed: false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_m.stage != PracticeStage.done) _finish(completed: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _m.stage == PracticeStage.done,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_stop());
    },
    child: PracticeView(
      model: _m,
      onHeard: () => unawaited(_heard()),
      onStop: () => unawaited(_stop()),
      onDone: () => Navigator.of(context).pop(),
    ),
  );
}
