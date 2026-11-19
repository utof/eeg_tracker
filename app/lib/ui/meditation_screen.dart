// The meditation mode (DECISIONS rows 72-75): pick a length, calibrate in silence, meditate with sound that
// follows the alpha rhythm, then a short report. Owns the headband while it runs, from this screen; only when
// no night is being recorded. Layout in meditation_view.dart.
// From here: the training settings (the replay check's toggle, DECISIONS rows 100-103) and alpha-theta training
// (rows 104-107), until the main screen gets its own entries.
import 'dart:async';

import 'package:flutter/material.dart';
import 'hands_free_screen.dart' show activeGestures;
import '../sound/soloud_gesture_tone.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../meditation/controller.dart';
import '../meditation/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../session_keeper.dart';
import '../sound/audio_route.dart';
import '../sound/soloud_sound.dart';
import '../training/check_store.dart';
import '../training/control.dart';
import 'alpha_theta_screen.dart';
import 'evidence_sheet.dart';
import 'meditation_view.dart';
import 'nearby.dart';
import 'training_settings_screen.dart';

class MeditationScreen extends StatefulWidget {
  const MeditationScreen({super.key});

  @override
  State<MeditationScreen> createState() => _MeditationScreenState();
}

class _MeditationScreenState extends State<MeditationScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final MeditationController _c = MeditationController(
    finder: _finder,
    sound: () => SoloudSound(),
    gestureTone: SoloudGestureTone.new,
    audioRoute: PhoneAudioRoute(),
  );
  int _minutes = 10;
  bool _nightRunning = false;
  bool _screenOn = false;
  final SessionKeeper _keeper = PhoneSessionKeeper();
  Stage _lastStage = Stage.setup;
  String? _recordings;
  String? _checkPreview;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _c.watchRoute(); // the setup warns as soon as the sound goes to Bluetooth headphones
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final rec = await Phone.recordingsDir();
      if (rec != null) {
        _recordings = rec;
        _c.store = MeditationStore(meditationsDirFor(rec));
        _loadCheck();
      }
    } catch (_) {
      // without the folder the session still runs; it is just not saved
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => _nightRunning = running);
  }

  /// The replay check's toggle as saved, and the words the setup shows while it is on.
  void _loadCheck() {
    final rec = _recordings, store = _c.store;
    if (rec == null || store == null || _c.active) return;
    final files = filesDirFor(rec);
    final on = SettingsStore(files).load().replayCheck;
    final cs = on ? CheckStore(files, SessionKind.meditation) : null;
    _c.checkStore = cs;
    _c.checkResults = CheckStore(files, SessionKind.meditation); // its test of the silent minutes, once revealed
    _checkPreview = cs == null ? null : previewStatus(cs, donorCandidates(store, store.list()));
  }

  Future<void> _openSettings() async {
    final rec = _recordings;
    if (rec == null) return _say('The app\'s folder is not known yet, so settings cannot be saved.');
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrainingSettingsScreen(recordingsDir: rec)));
    if (!mounted) return;
    setState(_loadCheck);
  }

  Future<void> _openAlphaTheta() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AlphaThetaScreen()));
    if (mounted) setState(_loadCheck);
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

  /// A session: the screen is kept on, and a foreground service keeps the session going if you lock the phone
  /// yourself (session_keeper.dart, DECISIONS row 194); Stop on its notification ends the session.
  void _screen({required bool on}) {
    if (_screenOn == on) return;
    _screenOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
    _keeper.onStop = () => unawaited(_c.stop());
    _keeper.onFocus = _c.audioFocus; // a call or another app's sound (DECISIONS row 468)
    unawaited(
      on
          ? _keeper.hold(const KeepSpec(title: 'Meditation', text: 'Session running', headband: true))
          : _keeper.release(),
    );
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
    // the session's notification carries Stop for a locked phone
    if (phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
    _loadCheck();
    _c.handsFree = await activeGestures();
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
      checkOn: c.stage == Stage.setup || c.stage == Stage.failed ? c.checkStore != null : c.checkOn,
      checkStatus: c.stage == Stage.setup || c.stage == Stage.failed ? _checkPreview : c.checkStatus,
      silentSeconds: c.active || c.stage == Stage.report ? c.silentLength.inSeconds : c.silentBlock.inSeconds,
      silentRun: c.silentSeconds,
      inSilent: c.inSilentBlock,
      route: c.route,
      learning: c.learning,
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
        onSettings: _openSettings,
        onAlphaTheta: _openAlphaTheta,
        onRatings: c.submitRatings,
      ),
    );
  }
}
