// The meditation mode (DECISIONS rows 72-75): pick a length, calibrate in silence, meditate with sound that
// follows the alpha rhythm, then a short report. Owns the headband while it runs, from this screen; only when
// no night is being recorded. Layout in meditation_view.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../meditation/controller.dart';
import '../meditation/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../sound/soloud_sound.dart';
import 'evidence_sheet.dart';
import 'meditation_view.dart';
import 'nearby.dart';

class MeditationScreen extends StatefulWidget {
  const MeditationScreen({super.key});

  @override
  State<MeditationScreen> createState() => _MeditationScreenState();
}

class _MeditationScreenState extends State<MeditationScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final MeditationController _c = MeditationController(finder: _finder, sound: () => SoloudSound());
  int _minutes = 10;
  bool _nightRunning = false;
  bool _screenOn = false;
  Stage _lastStage = Stage.setup;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec != null) _c.store = MeditationStore(meditationsDirFor(rec));
    } catch (_) {
      // without the folder the session still runs; it is just not saved
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
      // a finished session lets the scanner go (unless a headband was left out of range)
      if (!_c.active) _finder.dispose(anyLost: _c.leftLost);
    }
    setState(() {});
  }

  void _screen({required bool on}) {
    if (_screenOn == on) return;
    _screenOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose(); // ends a running session and saves what there was
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
    await _c.start(Duration(minutes: _minutes));
  }

  Future<bool> _confirmStop() async {
    if (_c.stage == Stage.connecting || _c.stage == Stage.contact) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the session?'),
        content: Text(
          _c.stage == Stage.running
              ? 'What you have done so far is kept and shown.'
              : 'Calibration is not finished, so nothing is kept.',
        ),
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

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final model = meditationModel(
      stage: c.stage,
      minutes: c.active || c.stage == Stage.report ? c.length.inMinutes : _minutes,
      message: c.message,
      chip: c.chip,
      calPhase: c.calPhase,
      calSecondsLeft: c.calSecondsLeft,
      calNeedsClean: c.calNeedsClean,
      runSeconds: c.runSeconds,
      bells: c.bells,
      contact: c.contact,
      soundNote: c.soundNote,
      saveNote: c.saveNote ?? (c.store == null && c.stage == Stage.report ? 'This session was not saved.' : null),
      report: c.report,
      comparison: c.comparison,
      earlier: c.earlier,
      nightRunning: _nightRunning,
    );
    return PopScope(
      canPop: !c.active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmStop()) return;
        await c.stop();
        if (mounted) Navigator.of(this.context).pop();
      },
      child: MeditationView(
        model: model,
        onMinutes: (v) => setState(() => _minutes = v),
        onStart: _start,
        onStop: _stop,
        onDone: () => Navigator.of(context).maybePop(),
        onInfo: () => showEvidence(context, 'meditation-feedback'),
      ),
    );
  }
}
