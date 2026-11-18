// The dream catcher (ROADMAP row 20, DECISIONS rows 110-115): record your two prompts, choose 3 or 4 rounds and how
// it ends, tap Lights off; afterwards play the answers back and type notes. Holds the headband from this screen, only
// between nights; during a session the screen stays on, black, at the lowest brightness, without the system bars
// (you may lock the phone yourself: a foreground service keeps the session going, DECISIONS row 195).
// With the sleep ending the night recording starts by itself and the app returns to the night screen.
// Layout in dream_view.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../dream/controller.dart';
import '../dream/record_mic.dart';
import '../dream/store.dart';
import '../phone.dart';
import '../recorder/brainbit.dart';
import '../recorder/recorder_service.dart';
import '../session_keeper.dart';
import '../sound/dream_sound.dart';
import 'dream_view.dart';
import 'evidence_sheet.dart';
import 'nearby.dart';

/// A dream catcher session holds the headband and writes a recording now: the night screen must not score that
/// night meanwhile (it would read a file still being written, and take the phone's CPU).
bool dreamSessionRunning = false;

/// Your prompts: at most this long (s).
const int promptMaxS = 20;

class DreamScreen extends StatefulWidget {
  const DreamScreen({super.key});

  @override
  State<DreamScreen> createState() => _DreamScreenState();
}

class _DreamScreenState extends State<DreamScreen> {
  final BrainBitFinder _finder = BrainBitFinder();
  final SoloudDreamSound _audio = SoloudDreamSound();
  final RecordMic _mic = RecordMic();
  late final DreamController _c = DreamController(
    finder: _finder,
    sound: () => _audio,
    mic: _mic,
    startNight: _startNight,
  );
  String? _recordings;
  int _rounds = 4;
  DreamEnding _ending = DreamEnding.wake;
  bool _nightRunning = false;
  bool _face = false;
  final SessionKeeper _keeper = PhoneSessionKeeper();
  DreamStage _lastStage = DreamStage.setup;
  List<DreamSession> _sessions = const [];
  final Map<PromptKind, double?> _promptS = {};
  PromptKind? _recordingPrompt;
  int _recordingS = 0;
  Timer? _recordTimer;
  String? _playing;
  bool _justEnded = false;
  Timer? _saveTimer;
  DreamSession? _dirty;

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
        _c.store = DreamStore(dreamDirFor(rec));
        _c.recordingsDir = Directory(rec);
      }
    } catch (_) {
      // without the folder the session still runs; nothing is saved and the tones play
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
    _sessions = st.list();
    for (final k in PromptKind.values) {
      final f = st.promptFile(k);
      _promptS[k] = st.promptPath(k) == null ? null : wavSeconds(f);
    }
  }

  void _changed() {
    if (!mounted) return;
    final stage = _c.stage;
    if (stage != _lastStage) {
      _lastStage = stage;
      _setFace(_c.active);
      dreamSessionRunning = _c.active;
      if (!_c.active) _finder.dispose(anyLost: _c.leftLost);
      if (stage == DreamStage.done) {
        _justEnded = true;
        _load();
        if (_c.last?.night == 'started') {
          // the night recorder has the headband now: back to the night screen, which shows it recording
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
        }
      }
    }
    setState(() {});
  }

  /// The session face: screen kept on, brightness at its lowest, system bars hidden; all undone afterwards.
  void _setFace(bool on) {
    if (_face == on) return;
    _face = on;
    unawaited(Phone.keepScreenOn(on: on).catchError((Object _) {}));
    unawaited(Phone.dimScreen(on: on).catchError((Object _) {}));
    // If you lock the phone yourself, a foreground service keeps the sound, the headband and the microphone going
    // (session_keeper.dart, DECISIONS row 195). It starts here, with the app on screen and the microphone allowed:
    // Android gives a locked app the microphone only then.
    _keeper.onStop = () => unawaited(_c.stop());
    unawaited(
      on
          ? _keeper.hold(const KeepSpec(title: 'Dream catcher', text: 'Session running', headband: true, microphone: true))
          : _keeper.release(),
    );
    unawaited(
      on
          ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
          : SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values),
    );
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
    dreamSessionRunning = false;
    _recordTimer?.cancel();
    _flushNotes();
    if (_recordingPrompt != null) unawaited(_mic.stop().catchError((Object _) {}));
    unawaited(_mic.dispose().catchError((Object _) {}));
    unawaited(_audio.close());
    _setFace(false);
    super.dispose();
  }

  // ---- lights off ----

  Future<void> _lightsOff() async {
    if (await FlutterForegroundTask.isRunningService) {
      setState(() => _nightRunning = true);
      return;
    }
    await _stopClip();
    final phone = await Phone.snapshot().catchError((Object _) => const PhoneSnapshot({}));
    if (!await nearbyAllowed(phone.sdkInt) && !await requestNearby(phone.sdkInt)) {
      return _say('Allow Nearby devices first: without it the headband cannot be found.');
    }
    if (!phone.bluetoothOn) {
      _say('Turn Bluetooth on, then tap Lights off.');
      await Phone.openSettings('bluetooth');
      return;
    }
    if (!await _micAllowed()) return;
    if (phone.sdkInt >= 33) {
      // the session's notification (Stop for a locked phone) and the night recorder's; ask now, not half-asleep
      await FlutterForegroundTask.requestNotificationPermission();
    }
    _justEnded = false;
    await _c.start(rounds: _rounds, ending: _ending);
  }

  Future<bool> _micAllowed() async {
    if (await _mic.allowed().catchError((Object _) => false)) return true;
    _say('Allow the microphone: the dream catcher records your answers with it.');
    return false;
  }

  Future<void> _stop() async {
    if (_c.stage == DreamStage.connecting || _c.stage == DreamStage.contact) return _c.stop();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop the session?'),
        content: const Text('The answers so far are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop')),
        ],
      ),
    );
    if (ok == true) await _c.stop();
  }

  // ---- your prompts ----

  Future<void> _record(PromptKind k) async {
    final st = _c.store;
    if (st == null) return _say('The app\'s folder is not known yet, so a prompt cannot be saved.');
    if (_recordingPrompt == k) return _endRecording(save: true);
    if (_recordingPrompt != null || _c.active) return;
    if (!await _micAllowed()) return;
    await _stopClip();
    st.promptsDir.createSync(recursive: true);
    try {
      await _mic.start(_tmp(st, k).path);
    } catch (e) {
      return _say('The microphone did not start: $e');
    }
    setState(() {
      _recordingPrompt = k;
      _recordingS = 0;
    });
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordingS++);
      if (_recordingS >= promptMaxS) unawaited(_endRecording(save: true));
    });
  }

  File _tmp(DreamStore st, PromptKind k) => File('${st.promptsDir.path}/${k.name}.new.wav');

  /// Ends a prompt recording; a take under half a second (a slip) keeps the old prompt.
  Future<void> _endRecording({required bool save}) async {
    final k = _recordingPrompt, st = _c.store;
    _recordTimer?.cancel();
    if (k == null || st == null) return;
    try {
      await _mic.stop();
    } catch (_) {}
    final tmp = _tmp(st, k);
    if (save && tmp.existsSync() && (wavSeconds(tmp) ?? 0) >= 0.5) {
      tmp.renameSync(st.promptFile(k).path);
    } else if (tmp.existsSync()) {
      tmp.deleteSync();
      if (save) _say('That was too short to keep. Tap Record and speak, then Stop.');
    }
    if (!mounted) return;
    setState(() {
      _recordingPrompt = null;
      _load();
    });
  }

  // ---- playback ----

  Future<void> _play(String id, String path, double volume) async {
    if (_playing == id) return _stopClip();
    await _stopClip();
    setState(() => _playing = id);
    try {
      await _audio.playClip(path, volume: volume);
    } catch (e) {
      _say('Could not play it: $e');
    }
    if (mounted && _playing == id) setState(() => _playing = null);
  }

  Future<void> _stopClip() async {
    if (_playing == null) return;
    setState(() => _playing = null);
    await _audio.stopClip();
  }

  void _playPrompt(PromptKind k) {
    final path = _c.store?.promptPath(k);
    if (path != null) unawaited(_play('prompt:${k.name}', path, promptVolume));
  }

  void _playAnswer(DreamSession s, DreamRound r) {
    final st = _c.store, f = r.answerFile;
    if (st == null || f == null) return;
    unawaited(_play(f, '${st.dir.path}/$f', 1));
  }

  // ---- notes ----

  void _note(DreamSession s, DreamRound r, String text) {
    r.note = text;
    _dirty = s;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _flushNotes);
  }

  void _flushNotes() {
    _saveTimer?.cancel();
    final s = _dirty, st = _c.store;
    _dirty = null;
    if (s == null || st == null) return;
    try {
      st.save(s);
    } catch (e) {
      _say('Your note could not be saved: $e');
    }
  }

  Future<void> _open(DreamSession s) async {
    await _stopClip();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SessionPage(session: s, play: _audio, dir: _c.store!.dir, onNote: _note, onLeave: _flushNotes),
      ),
    );
    if (mounted) setState(_load);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c, active = c.active;
    final latest = _sessions.isEmpty ? null : _sessions.first;
    final model = DreamViewModel(
      stage: c.stage,
      message: c.message,
      rounds: active ? c.rounds : _rounds,
      ending: active ? c.ending : _ending,
      roundsDone: c.roundsDone,
      roundNow: c.roundNow,
      minutes: (c.seconds / 60).floor(),
      noData: c.noData,
      contact: c.contact,
      notes: [?c.saveNote, ?c.micNote],
      nightRunning: _nightRunning,
      theme: PromptInfo(seconds: _promptS[PromptKind.theme]),
      question: PromptInfo(seconds: _promptS[PromptKind.question]),
      recording: _recordingPrompt,
      recordingS: _recordingS,
      playing: _playing,
      latest: latest,
      justEnded: _justEnded && c.stage == DreamStage.done,
      earlier: _sessions.length > 1 ? _sessions.sublist(1, _sessions.length.clamp(1, 11)) : const [],
    );
    return PopScope(
      canPop: !active && _recordingPrompt == null,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_recordingPrompt != null) return _endRecording(save: false);
        await _stop();
      },
      child: DreamView(
        model: model,
        onRounds: (v) => setState(() => _rounds = v),
        onEnding: (v) => setState(() => _ending = v),
        onLightsOff: _lightsOff,
        onStop: _stop,
        onDrifting: c.drifting,
        onRecord: _record,
        onPlayPrompt: _playPrompt,
        onPlayAnswer: _playAnswer,
        onNote: _note,
        onOpen: _open,
        onInfo: () => showEvidence(context, 'dream-catcher'),
      ),
    );
  }
}

/// An earlier session's answers on their own page.
class _SessionPage extends StatefulWidget {
  const _SessionPage({required this.session, required this.play, required this.dir, required this.onNote, required this.onLeave});
  final DreamSession session;
  final SoloudDreamSound play;
  final Directory dir;
  final void Function(DreamSession s, DreamRound r, String note) onNote;
  final VoidCallback onLeave;

  @override
  State<_SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<_SessionPage> {
  String? _playing;

  Future<void> _play(DreamSession s, DreamRound r) async {
    final f = r.answerFile;
    if (f == null) return;
    if (_playing == f) {
      setState(() => _playing = null);
      return widget.play.stopClip();
    }
    setState(() => _playing = f);
    try {
      await widget.play.playClip('${widget.dir.path}/$f');
    } catch (_) {}
    if (mounted && _playing == f) setState(() => _playing = null);
  }

  @override
  void dispose() {
    unawaited(widget.play.stopClip());
    widget.onLeave();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Dream catcher', style: text.titleMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        children: [DreamAnswers(session: widget.session, playing: _playing, onPlay: _play, onNote: widget.onNote)],
      ),
    );
  }
}
