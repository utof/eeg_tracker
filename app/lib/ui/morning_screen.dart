// The morning check-in (DECISIONS rows 120 and 125): the laptop page moved to the phone. Owns the headband while
// it runs, from this screen, only between nights (as meditation, row 75). Layout in morning_view.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../morning/controller.dart';
import '../morning/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../recorder/contact.dart';
import '../sound/check_in_sound.dart';
import '../trends/days.dart';
import '../trends/trends.dart';
import 'evidence_sheet.dart';
import 'morning_view.dart';
import 'nearby.dart';
import 'trends_screen.dart';

/// "09:12" for the first check-in of today, or null.
String? checkedInTodayAt(List<MorningRecord> records, DateTime now) {
  final today = dayKey(now);
  final todays = records.where((r) => r.day == today).toList()..sort((a, b) => a.start.compareTo(b.start));
  if (todays.isEmpty) return null;
  final t = todays.first.start;
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// This check-in's numbers with yesterday and your usual: the trends' morning rows with this check-in standing
/// for its day (an earlier one of the same day is set aside, so the page shows what was just measured).
MorningOutcome outcomeFor(MorningRecord done, TrendInputs inputs) {
  final mornings = [
    for (final r in inputs.mornings)
      if (r.day != done.day) r,
    done,
  ];
  final m = buildTrends((nights: inputs.nights, mornings: mornings, sessions: inputs.sessions), done.start);
  final rows = [
    for (final r in m.group(TrendGroup.morning))
      if (r.day == done.day) r,
  ];
  final t = done.start;
  return (
    rows: rows,
    today: done.day,
    time: '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
    cleanShare: done.cleanShare,
    noPeak: done.alphaEc != null && done.iafHz == null,
  );
}

class MorningScreen extends StatefulWidget {
  const MorningScreen({super.key});

  @override
  State<MorningScreen> createState() => _MorningScreenState();
}

class _MorningScreenState extends State<MorningScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final MorningController _c = MorningController(finder: _finder, sound: SoloudCheckInSound.new);
  String? _recordings;
  String? _doneAt;
  bool _nightRunning = false;
  bool _screenOn = false;
  MorningStage _lastStage = MorningStage.intro;
  MorningOutcome? _outcome;

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
        final store = MorningStore(morningsDirFor(rec));
        _c.store = store;
        _doneAt = checkedInTodayAt(store.list(), DateTime.now());
      }
    } catch (_) {
      // without the folder the check-in still runs; it is just not saved
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => _nightRunning = running);
  }

  void _changed() {
    if (!mounted) return;
    final stage = _c.stage;
    if (stage != _lastStage) {
      _lastStage = stage;
      _screen(on: _c.active);
      if (!_c.active && stage != MorningStage.connecting) _finder.dispose(anyLost: _c.leftLost);
      if (stage == MorningStage.result) _makeOutcome();
    }
    setState(() {});
  }

  void _makeOutcome() {
    final rec = _recordings, res = _c.result;
    final done = res == null ? null : MorningRecord.fromJson(res);
    if (rec == null || done == null) return;
    try {
      _outcome = outcomeFor(done, readTrendInputs(rec));
      _doneAt = checkedInTodayAt(_c.store?.list() ?? const [], DateTime.now());
    } catch (_) {
      _outcome = null;
    }
  }

  void _screen({required bool on}) {
    if (_screenOn == on) return;
    _screenOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose(); // a check-in still running is stopped; nothing of it is kept
    _screen(on: false);
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
    _outcome = null;
    await _c.start();
  }

  Future<bool> _confirmStop() async {
    final s = _c.stage;
    if (s == MorningStage.intro || s == MorningStage.failed || s == MorningStage.result) return true;
    if (s == MorningStage.connecting || s == MorningStage.contact) return true; // nothing recorded yet
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the check-in?'),
        content: const Text('Nothing of this check-in is kept.'),
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

  Future<void> _trends() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrendsScreen(recordingsDir: _recordings)));
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final grades = c.stage == MorningStage.contact ? c.grades : null;
    final model = MorningViewModel(
      stage: c.stage,
      message: c.message,
      soundNote: c.soundNote,
      saveNote: c.saveNote ?? (c.store == null && c.stage == MorningStage.result ? 'This check-in was not saved.' : null),
      contact: [
        if (grades != null && c.contact.isNotEmpty)
          for (final ch in channelNames)
            (
              channel: ch,
              contact: classifyOhms(c.contact[ch]),
              grade: grades[ch]!.grade,
              word: grades[ch]!.word,
              spread: grades[ch]!.spread,
            ),
      ],
      rechecking: c.rechecking,
      noSignal: c.noSignal,
      secondsLeft: c.secondsLeft,
      nightRunning: _nightRunning,
      doneTodayAt: _doneAt,
      outcome: _outcome,
    );
    final busy = c.active || c.stage == MorningStage.questions || c.stage == MorningStage.saving;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || c.stage == MorningStage.saving || !await _confirmStop()) return;
        await c.stop();
        if (mounted) Navigator.of(this.context).pop();
      },
      child: MorningView(
        model: model,
        onCheckContact: _start,
        onRecheck: c.recheck,
        onBegin: c.begin,
        onStop: _stop,
        onSave: c.save,
        onDone: () => Navigator.of(context).maybePop(),
        onTrends: _trends,
        onInfo: () => showEvidence(context, 'morning-check-in'),
      ),
    );
  }
}
