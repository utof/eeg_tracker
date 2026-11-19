// Hands-free controls (DECISIONS 240-249): the Settings page (a gear in the night screen's app bar) with the one
// switch, and the calibration page, which holds the headband from this screen only between nights, like the morning
// check-in. Layouts in hands_free_view.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../auto/store.dart' show AutoStore, autoDirFor;
import '../detectors/gestures.dart' show GestureSettings;
import '../handsfree/calibration_controller.dart';
import '../handsfree/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../study/store.dart' show StudyStore, studyDirFor;
import '../sound/check_in_sound.dart';
import '../training/check_store.dart' show filesDirFor;
import '../wearer/wearer.dart';
import 'auto_start_screen.dart';
import 'auto_start_view.dart' show autoSummary;
import 'evidence_sheet.dart';
import 'hands_free_view.dart';
import 'nearby.dart';
import 'study_screen.dart';

/// The hands-free settings of the app's folder, or null when the folder is not known.
Future<HandsFreeStore?> handsFreeStore() async {
  try {
    final rec = await Phone.recordingsDir();
    return rec == null ? null : HandsFreeStore(filesDirFor(rec));
  } catch (_) {
    return null;
  }
}

/// The owner's calibrated gestures while the switch is on, for a session about to start; null: off (or unknown).
Future<GestureSettings?> activeGestures() async => (await handsFreeStore())?.load().active;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  HandsFreeStore? _store;
  HandsFreeState _state = const HandsFreeState();
  bool _nightRunning = false;
  bool? _studyOn;
  String? _error;

  /// "Was this you?" (DECISIONS 370-379): the app's recordings folder and the check's state, when known.
  String? _recordings;
  WearerResult? _wearer;

  /// "When I put the headband on" in words (DECISIONS 600), when the folder is known.
  String? _auto;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = await handsFreeStore();
    final running = await FlutterForegroundTask.isRunningService;
    String? rec;
    WearerResult? wearer;
    try {
      rec = await Phone.recordingsDir();
      if (rec != null) wearer = refreshWearer(rec, DateTime.now());
    } catch (_) {
      wearer = null; // the section is left out; hands-free still works
    }
    final studyOn = await _readStudyOn();
    String? auto;
    try {
      auto = rec == null ? null : autoSummary(AutoStore(autoDirFor(rec)).settings());
    } catch (_) {
      auto = null;
    }
    if (!mounted) return;
    setState(() {
      _auto = auto;
      _studyOn = studyOn;
      _store = store;
      _state = store?.load() ?? const HandsFreeState();
      _nightRunning = running;
      _error = store == null ? 'The app\'s folder is not known yet, so nothing can be saved.' : null;
      _recordings = rec;
      _wearer = wearer;
    });
  }

  void _setWearer(bool on) {
    final rec = _recordings;
    if (rec == null) return;
    try {
      WearerStore(wearerDirFor(rec)).setOn(on, DateTime.now());
      setState(() => _wearer = refreshWearer(rec, DateTime.now()));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('The setting could not be saved: $e')));
    }
  }

  /// The study reminders' switch, read from their own file (null when the app's folder is not known).
  Future<bool?> _readStudyOn() async {
    try {
      final dir = await Phone.recordingsDir();
      return dir == null ? null : StudyStore(studyDirFor(dir)).settings()?.on == true;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openStudy() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StudyScreen()));
    final on = await _readStudyOn();
    if (mounted) setState(() => _studyOn = on);
  }

  void _set(bool on) {
    final s = _store;
    if (s == null) return;
    try {
      s.setOn(on, DateTime.now());
      setState(() {
        _state = s.load();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'The setting could not be saved: $e');
    }
  }

  /// On without a usable calibration: calibrate first, and switch on only if a gesture was caught.
  Future<void> _toggle(bool on) async {
    if (!on || (_state.calibration?.usable ?? false)) return _set(on);
    final ok = await _calibrate();
    if (ok) {
      _set(true);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Still off: calibrate first, so the app knows your gestures.')),
      );
    }
  }

  /// Opens the calibration; true when it ended with a usable gesture.
  Future<bool> _calibrate() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CalibrationScreen(store: _store)));
    await _load();
    return _state.calibration?.usable ?? false;
  }

  @override
  Widget build(BuildContext context) => SettingsView(
    model: SettingsViewModel(
      on: _state.on,
      calibration: _state.calibration,
      nightRunning: _nightRunning,
      error: _error,
      wearerOn: _wearer?.on,
      wearerStatus: _wearer == null ? '' : wearerStatus(_wearer!),
    ),
    onToggle: (on) => unawaited(_toggle(on)),
    onCalibrate: () => unawaited(_calibrate()),
    onInfo: () => showEvidence(context, 'hands-free'),
    onWearerSwitch: _setWearer,
    onWearerInfo: () => showEvidence(context, 'was-this-you'),
    studyOn: _studyOn,
    onStudy: () => unawaited(_openStudy()),
    autoStart: _auto,
    onAutoStart: () => unawaited(_openAuto()),
  );

  Future<void> _openAuto() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutoStartScreen()));
    await _load();
  }
}

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, this.store});
  final HandsFreeStore? store;

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  late final CalibrationController _c = CalibrationController(finder: _finder, sound: SoloudCheckInSound.new, store: widget.store);
  bool _nightRunning = false;
  bool _screenOn = false;
  CalStage _lastStage = CalStage.setup;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    unawaited(FlutterForegroundTask.isRunningService.then((r) {
      if (mounted) setState(() => _nightRunning = r);
    }));
  }

  void _changed() {
    if (!mounted) return;
    if (_c.stage != _lastStage) {
      _lastStage = _c.stage;
      _screen(on: _c.active);
      if (!_c.active && _c.stage != CalStage.connecting) _finder.dispose(anyLost: _c.leftLost);
    }
    setState(() {});
  }

  void _screen({required bool on}) {
    if (_screenOn == on) return;
    _screenOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
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
    await _c.start();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose(); // a calibration still running is stopped; nothing of it is kept
    _screen(on: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return PopScope(
      canPop: !c.active,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await c.stop();
        if (mounted) Navigator.of(this.context).pop();
      },
      child: CalibrationView(
        model: CalViewModel(
          stage: c.stage,
          message: c.message,
          tryNow: c.tryNow,
          inWindow: c.inWindow,
          stillLeft: c.stillLeft,
          jaw: c.jaw,
          eyes: c.eyes,
          clenchLine: c.clenchLine,
          glanceSize: c.glanceSize,
          result: c.result,
          saveNote: c.saveNote,
          nightRunning: _nightRunning,
          shaped: List.of(c.shaped),
          linesAreYours: c.linesAreYours,
        ),
        onStart: () => unawaited(_start()),
        onStop: () => unawaited(c.stop()),
        onDone: () => Navigator.of(context).maybePop(),
        onInfo: () => showEvidence(context, 'hands-free'),
      ),
    );
  }
}
