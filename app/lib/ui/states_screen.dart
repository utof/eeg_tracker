// Sound for states (ROADMAP rows 17-18, DECISIONS rows 130-139): pick a state and a sound, Listen to set the volume,
// Start. With the headband (only between nights; this screen holds it, like the dream catcher) a quiet minute comes
// first, then the sound and the readout; without it, or while the night records, the sound plays by its timer. During
// a session the face is black, dimmed for eyes-closed states, and the phone can be locked: a foreground service keeps
// the sound and the headband going (session_keeper.dart, DECISIONS rows 190-193). The screen is kept on only when you
// choose "Stays on", when the service did not start, or when the night must start afterwards and the app is not yet
// allowed to run in the background. A "fall asleep" session that ends by itself leaves the screen dim and lets it time
// out, so nothing lights the bedroom; a touch brings the brightness back.
// Over weeks (ROADMAP row 18, DECISIONS rows 430-439): the chosen state's sounds compared (states/weeks.dart, with
// the sleep reports' falling-asleep results), and its fair test (states/trial.dart): on a day of a test the sound
// and the length are the day's draw, and the session carries the test's tag.
// Layout in states_view.dart and states_weeks_view.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'hands_free_screen.dart' show activeGestures;
import '../sound/soloud_gesture_tone.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../phone.dart';
import '../recorder/brainbit.dart';
import '../recorder/recorder_service.dart';
import '../session_keeper.dart';
import '../sleep/drift.dart' show DriftResult;
import '../sleep/report.dart' show NightReportStore, nightsDirFor;
import '../sound/soloud_state_sound.dart';
import '../states/controller.dart';
import '../states/presets.dart';
import '../states/store.dart';
import '../states/trial.dart';
import '../states/trial_store.dart';
import '../states/weeks.dart';
import 'evidence_sheet.dart';
import 'nearby.dart';
import 'states_view.dart';
import 'states_weeks_view.dart';

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
  late final StatesController _c = StatesController(
    finder: _finder,
    sound: SoloudStateSound.new,
    startNight: _startNight,
    keeper: PhoneSessionKeeper(),
    gestureTone: SoloudGestureTone.new,
  );
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

  /// The sleep reports' falling-asleep results (fall asleep's number when the session did not see sleep).
  List<DriftResult> _nights = const [];
  TrialStore? _trials;

  /// The chosen state's fair test under way, or its latest; today is one of its days ([_locked]).
  TrialState? _test;
  bool _locked = false;

  /// Answers already worked out, by test (the test runs over every possible order).
  final Map<String, TrialResults> _answers = {};
  SoundStage _lastStage = SoundStage.setup;
  bool _face = false;
  bool _keptOn = false;
  bool _dim = false;

  /// Your choice on the setup page: keep the screen on during sessions, as before the phone could be locked.
  bool _staysOn = false;

  /// This session must start the night afterwards, and the app is not allowed to do that with the phone locked.
  bool _nightNeedsScreen = false;
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
        _trials = TrialStore(trialsDirFor(soundStatesDirFor(rec)));
        _staysOn = _c.store!.screenStaysOn;
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

  void _load() {
    _sessions = _c.store?.list() ?? const [];
    _nights = _readNights();
    _answers.clear();
    _pickTest();
  }

  List<DriftResult> _readNights() {
    final rec = _recordings;
    if (rec == null) return const [];
    try {
      return [for (final r in NightReportStore(nightsDirFor(rec)).all()) ?r.driftOff];
    } catch (_) {
      return const [];
    }
  }

  /// The chosen state's test; on one of its days its draw sets the sound and the length.
  void _pickTest() {
    TrialState? t;
    try {
      t = _trials?.shownFor(_state, DateTime.now());
    } catch (_) {
      t = null; // an unreadable folder: no test
    }
    _test = t;
    final sound = t?.todaySound;
    _locked = sound != null;
    if (sound != null) {
      _bed = sound.bed;
      _beat = sound.beat;
      _minutes = t!.plan.minutes;
    }
  }

  TrialResults? get _answer {
    final t = _test;
    if (t == null || !t.open) return null;
    return _answers[t.plan.id] ??= trialResults(t, _sessions, nights: _nights);
  }

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
    _keepOn(_c.active && _mustStayOn);
    setState(() {});
  }

  /// The session face: screen on, black, dimmed and without system bars for eyes-closed states; undone afterwards
  /// ([keepDim]: the window stays dim until a touch).
  void _setFace(bool on, {bool dim = false, bool keepDim = false}) {
    if (_face != on) {
      _face = on;
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

  /// The screen may turn off and the phone be locked, unless one of these holds.
  bool get _mustStayOn => !_c.canLock || _staysOn || _nightNeedsScreen;

  void _keepOn(bool on) {
    if (_keptOn == on) return;
    _keptOn = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
  }

  /// One line on the session face about locking the phone.
  String get _screenNote {
    if (!_c.active || _staysOn) return '';
    if (_nightNeedsScreen) {
      return 'The screen stays on: the night must start afterwards. To lock the phone next time, allow the app to run '
          'in the background (main screen, under Phone).';
    }
    if (_c.canLock) return 'You can lock the phone. The sound goes on.';
    return _c.stage == SoundStage.connecting || _c.stage == SoundStage.starting
        ? ''
        : 'Keep the app open: this phone did not allow the sound to go on when locked.';
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
    _keepOn(false);
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
    _pickTest();
  });

  /// The sound and the length, unless today's draw set them.
  void _chooseSound(void Function() change) {
    if (!_locked) _choose(change);
  }

  // ---- the fair test ----

  Future<void> _planTest() async {
    final trials = _trials;
    if (trials == null) return _say('The app\'s folder is not known, so a test cannot be saved.');
    await _stopListening();
    if (!mounted) return;
    final state = _state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => FairTestSetup(
          state: state,
          first: SoundPick(_bed, _beat),
          minutes: _minutes,
          now: DateTime.now(),
          onInfo: () => showEvidence(ctx, 'sound-for-states'),
          onStart: (c) {
            try {
              trials.create(state: state, a: c.a, b: c.b, minutes: c.minutes, weeks: c.weeks, now: DateTime.now());
            } catch (e) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('The test could not be saved: $e')));
              return;
            }
            Navigator.of(ctx).pop();
          },
        ),
      ),
    );
    if (mounted) setState(_pickTest);
  }

  Future<void> _stopTest() async {
    final t = _test, trials = _trials;
    if (t == null || trials == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop this test?'),
        content: const Text(
          'The days that are over stay counted, and the answer opens now, marked as stopped early. The days ahead '
          'are never shown.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop the test')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      trials.stop(t.plan.id, DateTime.now());
    } catch (e) {
      return _say('The test could not be stopped: $e');
    }
    setState(() {
      _answers.remove(t.plan.id);
      _pickTest();
    });
  }

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
    final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
    // the session's own notification carries Stop for the locked phone; the night recorder shows one too
    if (phone.sdkInt >= 33) await FlutterForegroundTask.requestNotificationPermission();
    // Android starts the night recording from a locked phone only for an app allowed to run in the background
    _nightNeedsScreen = measure && _thenNight && _state == SoundState.asleep && !phone.ignoringBatteryOptimizations;
    // the same system dialog the night screen shows; this session keeps its screen on whatever the answer
    if (_nightNeedsScreen) await Phone.openSettings('batteryOptimization').catchError((Object _) => false);
    if (measure) {
      if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
        return _say('Allow Nearby devices for the headband, or choose Sound only.');
      }
      if (!phone.bluetoothOn) {
        _say('Turn Bluetooth on for the headband, or choose Sound only.');
        await Phone.openSettings('bluetooth');
        return;
      }
    }
    _justEnded = false;
    _c.handsFree = await activeGestures();
    if (mounted) setState(_pickTest); // the day may have turned since the page opened
    await _c.start(
      _plan,
      useHeadband: measure,
      why: night ? HeadbandUse.nightRecording : HeadbandUse.soundOnly,
      thenNight: _thenNight,
      trial: _test?.tagFor(_state),
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
      screenStaysOn: _staysOn,
      screenNote: _screenNote,
      last: latest,
      justEnded: _justEnded && latest != null,
      earlier: _sessions.length > 1 ? _sessions.sublist(1, _sessions.length.clamp(1, 11)) : const [],
      comparison: active ? null : compareSounds(_state, _sessions, nights: _nights),
      test: _test,
      testResults: active ? null : _answer,
      soundLocked: _locked && !active,
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
          onBed: (v) => _chooseSound(() => _bed = v),
          onBeat: (v) => _chooseSound(() => _beat = v),
          onMinutes: (v) => _chooseSound(() => _minutes = v),
          onHeadband: (v) => _choose(() => _useHeadband = v),
          onThenNight: (v) => _choose(() => _thenNight = v),
          onScreen: (v) => _choose(() {
            _staysOn = v;
            try {
              _c.store?.screenStaysOn = v;
            } catch (_) {}
          }),
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
          onPlanTest: () => unawaited(_planTest()),
          onStopTest: () => unawaited(_stopTest()),
        ),
      ),
    );
  }
}
