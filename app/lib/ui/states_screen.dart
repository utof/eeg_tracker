// Sound for states (ROADMAP rows 17-18, DECISIONS rows 130-139): pick a state and a sound, Listen to set the volume,
// Start. With the headband (only between nights; this screen holds it, like the dream catcher) a quiet minute comes
// first, then the sound and the readout; without it, or while the night records, the sound plays by its timer. During
// a session the screen stays on with a black face, dimmed for eyes-closed states. A "fall asleep" session that ends by
// itself leaves the screen dim and lets it time out, so nothing lights the bedroom; a touch brings the brightness back.
// Layout in states_view.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../phone.dart';
import '../recorder/brainbit.dart';
import '../recorder/recorder_service.dart';
import '../sound/soloud_state_sound.dart';
import '../states/controller.dart';
import '../states/presets.dart';
import '../states/store.dart';
import 'evidence_sheet.dart';
import 'nearby.dart';
import 'states_view.dart';

/// A session holds the headband and, for fall asleep, writes a recording now: the night screen must not score that
/// night meanwhile (as for the dream catcher).
bool soundSessionRunning = false;

/// Listen plays this long at most.
const Duration listenFor = Duration(seconds: 20);

class StatesScreen extends StatefulWidget {
  const StatesScreen({super.key});

  @override
  State<StatesScreen> createState() => _StatesScreenState();
}

class _StatesScreenState extends State<StatesScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  final SoloudStateSound _preview = SoloudStateSound();
  late final StatesController _c = StatesController(finder: _finder, sound: SoloudStateSound.new, startNight: _startNight);
  SoundState _state = SoundState.asleep;
  Bed _bed = presets[SoundState.asleep]!.bed;
  Beat _beat = Beat.none;
  int _minutes = presets[SoundState.asleep]!.defaultMinutes;
  bool _useHeadband = true;
  bool _thenNight = true;
  bool _nightRunning = false;
  bool _listening = false;
  Timer? _listenTimer;
  String? _recordings;
  List<SoundSession> _sessions = const [];
  SoundStage _lastStage = SoundStage.setup;
  bool _face = false;
  bool _dim = false;
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
        _recordings = rec;
        _c.store = SoundStore(soundStatesDirFor(rec));
        _c.recordingsDir = Directory(rec);
      }
    } catch (_) {
      // without the folder the session still runs; it is just not saved
    }
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() {
      _nightRunning = running;
      _load();
    });
  }

  void _load() => _sessions = _c.store?.list() ?? const [];

  SoundPlan get _plan => SoundPlan.of(_state, bed: _bed, beat: _beat, minutes: _minutes);

  void _changed() {
    if (!mounted) return;
    final stage = _c.stage;
    if (stage != _lastStage) {
      _lastStage = stage;
      soundSessionRunning = _c.active;
      if (_c.active) {
        _setFace(true, dim: _c.plan?.preset.eyesClosed ?? false);
      } else {
        _finder.dispose(anyLost: _c.leftLost);
        final last = _c.last;
        // fell asleep (or the timer ran out at bedtime): stay dim and let the screen time out
        final asleep = last != null && last.plan.state == SoundState.asleep && last.end != SoundEnd.stopped;
        _setFace(false, keepDim: asleep);
      }
      if (stage == SoundStage.done) {
        _justEnded = true;
        _load();
      }
    }
    setState(() {});
  }

  /// The session face: screen on, black, dimmed and without system bars for eyes-closed states; undone afterwards
  /// ([keepDim]: the window stays dim until a touch).
  void _setFace(bool on, {bool dim = false, bool keepDim = false}) {
    if (_face != on) {
      _face = on;
      unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
      unawaited(
        on && dim
            ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
            : SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values),
      );
    }
    final wantDim = on ? dim : keepDim && _dim;
    if (wantDim != _dim) {
      _dim = wantDim;
      unawaited(Phone.dimScreen(on: wantDim).catchError((Object _) {}));
    }
  }

  void _undim() {
    if (_dim && !_c.active) {
      _dim = false;
      unawaited(Phone.dimScreen(on: false).catchError((Object _) {}));
    }
  }

  Future<String?> _startNight() async {
    _finder.dispose(anyLost: _c.leftLost); // the headband is free: the recorder's own scanner takes over
    final r = await startRecorderService(_recordings);
    return r is ServiceRequestFailure ? 'did not start: ${r.error}' : null;
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.dispose(); // ends a running session and saves what there was
    soundSessionRunning = false;
    _listenTimer?.cancel();
    unawaited(_preview.stop(seconds: 0.3));
    _setFace(false);
    if (_dim) unawaited(Phone.dimScreen(on: false).catchError((Object _) {}));
    super.dispose();
  }

  // ---- choices ----

  void _choose(void Function() change) {
    if (_c.active) return;
    unawaited(_stopListening());
    setState(() {
      change();
      _justEnded = false;
      if (_c.stage != SoundStage.setup) _c.again();
    });
  }

  void _onState(SoundState s) => _choose(() {
    _state = s;
    _bed = _beat == Beat.none || _bed != Bed.none ? presets[s]!.bed : Bed.none;
    _minutes = presets[s]!.defaultMinutes;
  });

  // ---- listen ----

  Future<void> _listen() async {
    if (_listening) return _stopListening();
    setState(() => _listening = true);
    try {
      await _preview.start(_plan, fadeInS: 1);
    } catch (e) {
      if (mounted) setState(() => _listening = false);
      return _say('The sound did not start: $e');
    }
    _listenTimer?.cancel();
    _listenTimer = Timer(listenFor, () => unawaited(_stopListening()));
  }

  Future<void> _stopListening() async {
    _listenTimer?.cancel();
    if (!_listening) return;
    if (mounted) setState(() => _listening = false);
    await _preview.stop(seconds: 1);
  }

  // ---- start and stop ----

  Future<void> _start() async {
    if (_c.active) return;
    await _stopListening();
    final night = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => _nightRunning = night);
    final measure = _useHeadband && !night;
    if (measure) {
      final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
      if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
        return _say('Allow Nearby devices for the headband, or choose Sound only.');
      }
      if (!phone.bluetoothOn) {
        _say('Turn Bluetooth on for the headband, or choose Sound only.');
        await Phone.openSettings('bluetooth');
        return;
      }
      if (_state == SoundState.asleep && _thenNight && phone.sdkInt >= 33) {
        // the night recorder shows a notification; ask now, not half-asleep
        await FlutterForegroundTask.requestNotificationPermission();
      }
    }
    _justEnded = false;
    await _c.start(
      _plan,
      useHeadband: measure,
      why: night ? HeadbandUse.nightRecording : HeadbandUse.soundOnly,
      thenNight: _thenNight,
    );
  }

  Future<void> _stop() async {
    if (_c.stage == SoundStage.connecting || _c.stage == SoundStage.contact) return _c.stop();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the sound?'),
        content: const Text('It fades out over 3 seconds. What was measured is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok == true) await _c.stop();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c, active = c.active;
    final latest = _sessions.isEmpty ? null : _sessions.first;
    final model = StatesViewModel(
      stage: c.stage,
      plan: active ? c.plan! : _plan,
      message: c.message,
      useHeadband: _useHeadband,
      thenNight: _thenNight,
      nightRunning: _nightRunning,
      listening: _listening,
      seconds: c.seconds,
      soundSeconds: c.soundSeconds,
      secondsLeft: c.secondsLeft,
      quietS: c.quietS,
      quietTarget: c.timing.quietCleanS,
      rateNow: c.rateNow,
      live: c.live,
      hasBaseline: c.hasBaseline,
      driftState: c.driftState,
      stopWhy: c.stopWhy,
      headbandUse: c.headband,
      contact: c.contact,
      noData: c.noData,
      notes: [?c.saveNote],
      last: latest,
      justEnded: _justEnded && latest != null,
      earlier: _sessions.length > 1 ? _sessions.sublist(1, _sessions.length.clamp(1, 11)) : const [],
    );
    return Listener(
      onPointerDown: (_) => _undim(),
      child: PopScope(
        canPop: !active,
        onPopInvokedWithResult: (didPop, _) async {
          if (!didPop) await _stop();
        },
        child: StatesView(
          model: model,
          onState: _onState,
          onBed: (v) => _choose(() => _bed = v),
          onBeat: (v) => _choose(() => _beat = v),
          onMinutes: (v) => _choose(() => _minutes = v),
          onHeadband: (v) => _choose(() => _useHeadband = v),
          onThenNight: (v) => _choose(() => _thenNight = v),
          onListen: () => unawaited(_listen()),
          onStart: () => unawaited(_start()),
          onStop: () => unawaited(_stop()),
          onSkip: c.skipQuiet,
          onRate: (v) {
            if (latest == null) return;
            if (identical(c.last, latest) || c.last?.fileName == latest.fileName) {
              c.rate(v);
            } else {
              latest.rating = v;
              try {
                c.store?.save(latest);
              } catch (_) {}
            }
            setState(_load);
          },
          onInfo: () => showEvidence(context, 'sound-for-states'),
        ),
      ),
    );
  }
}
