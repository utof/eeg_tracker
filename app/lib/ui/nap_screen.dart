// The nap coach (ROADMAP "Nap coach", DECISIONS rows 173-177): pick a length, tap Lights off, sleep; it wakes you
// before deep sleep starts or at the length, then shows how the nap went. Holds the headband from this screen, only
// between nights; during the nap the screen stays on, black, at the lowest brightness, without the system bars; at the
// wake the brightness comes back. The live sleep model is AnySleep on ONNX (sleep/live_stager.dart); while last
// night's scoring runs, its checks wait (memory). Layout in nap_view.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'hands_free_screen.dart' show activeGestures;
import '../sound/soloud_gesture_tone.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../nap/controller.dart';
import '../nap/rules.dart';
import '../nap/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../sleep/live_stager.dart';
import '../sleep/onnx_runs.dart';
import '../sound/nap_sound.dart';
import 'evidence_sheet.dart';
import 'nap_view.dart';
import 'nearby.dart';
import 'sleep_scoring.dart' show nightScoringBusy;

/// A nap holds the headband and writes a recording now: the night screen must not score meanwhile (it would read a
/// file still being written, and two sleep models at once may not fit the phone's memory).
bool napSessionRunning = false;

class NapScreen extends StatefulWidget {
  const NapScreen({super.key});

  @override
  State<NapScreen> createState() => _NapScreenState();
}

class _NapScreenState extends State<NapScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  final SoloudNapSound _audio = SoloudNapSound();
  late final NapController _c = NapController(
    finder: _finder,
    sound: () => _audio,
    mayRunModel: () => !nightScoringBusy,
    gestureTone: SoloudGestureTone.new,
  );
  int _length = NapRule.defaultMin;
  bool _nightRunning = false;
  bool _face = false;
  bool _dim = false;
  NapStage _lastStage = NapStage.setup;
  List<NapSession> _naps = const [];
  bool _justEnded = false;

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
        _c.store = NapStore(napDirFor(rec));
        _c.recordingsDir = Directory(rec);
        final models = modelsDirFor(rec);
        _c.model = () => RunsLiveModel(
          open: (run) => OnnxStageRun.open(run, modelsDir: models),
          closeRun: (run) => (run as OnnxStageRun).close(),
        );
      }
    } catch (_) {
      // without the folder the nap still runs on the timer; nothing is saved
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() {
      _nightRunning = running;
      _load();
    });
  }

  void _load() {
    final st = _c.store;
    if (st == null) return;
    try {
      _naps = st.list();
    } catch (_) {
      _naps = const [];
    }
  }

  void _changed() {
    if (!mounted) return;
    final stage = _c.stage;
    if (stage != _lastStage) {
      _lastStage = stage;
      _setFace(_c.active);
      _setDim(stage == NapStage.connecting || stage == NapStage.contact || stage == NapStage.resting);
      napSessionRunning = _c.active;
      if (!_c.active) _finder.dispose(anyLost: _c.leftLost);
      if (stage == NapStage.done) {
        _justEnded = true;
        _load();
      }
    }
    setState(() {});
  }

  /// The nap face: screen kept on and system bars hidden; all undone afterwards.
  void _setFace(bool on) {
    if (_face == on) return;
    _face = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
    unawaited(
      on
          ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
          : SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values),
    );
  }

  /// The lowest brightness while you rest; the phone's own at the wake, so "I'm awake" is easy to find.
  void _setDim(bool on) {
    if (_dim == on) return;
    _dim = on;
    unawaited(Phone.dimScreen(on: on).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose(); // ends a running nap and saves what there was
    napSessionRunning = false;
    unawaited(_audio.stop());
    _setDim(false);
    _setFace(false);
    super.dispose();
  }

  Future<void> _lightsOff() async {
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _nightRunning = true);
      return;
    }
    final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
    if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
      return _say('Allow Nearby devices first: without it the headband cannot be found.');
    }
    if (!phone.bluetoothOn) {
      _say('Turn Bluetooth on, then tap Lights off.');
      await Phone.openSettings('bluetooth');
      return;
    }
    _justEnded = false;
    _c.handsFree = await activeGestures();
    await _c.start(lengthMin: _length);
  }

  Future<void> _stop() async {
    if (_c.stage == NapStage.waking) return _c.awake();
    if (_c.stage == NapStage.connecting || _c.stage == NapStage.contact) return _c.stop();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('End the nap?'),
        content: const Text('What the nap recorded so far is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep napping')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('End it')),
        ],
      ),
    );
    if (ok == true) await _c.stop();
  }

  Future<void> _open(NapSession s) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (c) => Scaffold(
        appBar: AppBar(title: Text('Nap coach', style: Theme.of(c).textTheme.titleMedium)),
        body: ListView(padding: const EdgeInsets.fromLTRB(24, 4, 24, 24), children: [NapReport(session: s)]),
      ),
    ),
  );

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c, active = c.active;
    final latest = _naps.isEmpty ? null : _naps.first;
    final l = c.latest;
    final model = NapViewModel(
      stage: c.stage,
      message: c.message,
      lengthMin: active ? c.lengthMin : _length,
      seconds: c.seconds,
      drift: c.driftState,
      live: c.live,
      liveNote: c.liveNote,
      lightSleep: l != null && (l.stage == 'N1' || l.stage == 'N2'),
      noData: c.noData,
      end: c.end,
      notes: [?c.saveNote],
      nightRunning: _nightRunning,
      latest: latest,
      justEnded: _justEnded && c.stage == NapStage.done,
      earlier: _naps.length > 1 ? _naps.sublist(1, _naps.length.clamp(1, 11)) : const [],
    );
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _stop();
      },
      child: NapView(
        model: model,
        onLength: (v) => setState(() => _length = v),
        onLightsOff: _lightsOff,
        onStop: _stop,
        onAwake: () => unawaited(_c.awake()),
        onOpen: _open,
        onInfo: () => showEvidence(context, 'nap-coach'),
      ),
    );
  }
}
