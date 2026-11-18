// The dream catcher's sound on flutter_soloud (DECISIONS row 113): your own recorded prompts played quietly, a soft
// built-in tone for a prompt you have not recorded, and alpha-theta's rising wake tone at the end. No bed, no
// reverb: a voice in a dark room. The same engine plays your prompts and answers outside a session (ClipPlayer).
// Not heard yet: the volumes are guesses until the owner listens (set the phone's media volume with "Play").
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../dream/audio.dart';
import '../dream/store.dart' show PromptKind;
import 'alpha_theta_sound.dart' show wakeTone;
import 'synth.dart';

/// Your own prompts during a session, against the phone's media volume (quiet: you are drifting off).
const double promptVolume = 0.45;

/// The built-in tones: theme = one low soft tone ("drift off"); question = two notes rising ("speak now").
const double themeToneHz = 220;
const List<double> questionToneHz = [440, 659.25];

typedef _Material = ({Uint8List theme, Uint8List question, Uint8List wake});

Float32List _questionTone() {
  final a = strike(questionToneHz[0], cuePartials), b = strike(questionToneHz[1], cuePartials);
  final gap = (0.35 * synthRate).round(), out = Float32List(gap + b.length);
  for (var i = 0; i < a.length; i++) {
    out[i] += a[i] / 2;
  }
  for (var i = 0; i < b.length; i++) {
    out[gap + i] += b[i] / 2;
  }
  return out;
}

_Material _make() => (
  theme: wav16([strike(themeToneHz, cuePartials)]),
  question: wav16([_questionTone()]),
  wake: wav16([wakeTone()]),
);

class SoloudDreamSound implements DreamSound, ClipPlayer {
  SoLoud get _s => SoLoud.instance;
  AudioSource? _theme, _question, _wake;
  bool _session = false;
  int _n = 0;
  int _deviceFailures = 0;
  StreamSubscription<AudioDeviceStartFailure>? _failures;
  SoundHandle? _clip;
  Completer<void>? _clipDone;

  Future<void> _ensure() async {
    if (_s.isInitialized) return;
    await _s.init(sampleRate: synthRate, bufferSize: 2048);
    _failures ??= _s.audioDeviceStartFailures.listen((_) {
      _deviceFailures++;
      unawaited(_s.startAudioDevice().catchError((Object _) {}));
    });
    _s.setGlobalVolume(1);
  }

  @override
  Future<void> start() async {
    await stopClip();
    try {
      final m = await Isolate.run(_make);
      await _ensure();
      _theme = await _s.loadMem('dream-theme-tone.wav', m.theme);
      _question = await _s.loadMem('dream-question-tone.wav', m.question);
      _wake = await _s.loadMem('dream-wake.wav', m.wake);
      _s.setGlobalVolume(1);
      _session = true;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> prompt(PromptKind kind, String? file) async {
    if (!_session) return;
    if (file == null) {
      final tone = kind == PromptKind.theme ? _theme : _question;
      if (tone != null) await _playAndWait(tone, toneGain(cuePartials, cueLevel));
      return;
    }
    final src = await _s.loadMem('dream-${kind.name}-${_n++}.wav', await File(file).readAsBytes());
    try {
      await _playAndWait(src, promptVolume);
    } finally {
      await _s.disposeSource(src);
    }
  }

  Future<void> _playAndWait(AudioSource src, double volume, {Completer<void>? stopped}) async {
    final length = _s.getLength(src);
    final finished = src.allInstancesFinished.first;
    final h = _s.play(src, volume: volume);
    if (stopped != null) _clip = h;
    await Future.any([finished, if (stopped != null) stopped.future]).timeout(length + const Duration(seconds: 2), onTimeout: () {});
  }

  @override
  void wake() {
    final w = _wake;
    if (_session && w != null) _guard(() => _s.play(w, volume: toneGain(cuePartials, cueLevel)));
  }

  @override
  Future<void> stop() async {
    if (!_session) return;
    _session = false;
    _guard(() => _s.fadeGlobalVolume(0, const Duration(milliseconds: 1000)));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await close();
  }

  @override
  Future<void> playClip(String path, {double volume = 1}) async {
    await stopClip();
    await _ensure();
    final done = _clipDone = Completer<void>();
    final src = await _s.loadMem('dream-clip-${_n++}.wav', await File(path).readAsBytes());
    try {
      await _playAndWait(src, volume, stopped: done);
    } finally {
      _clip = null;
      if (!done.isCompleted) done.complete();
      if (identical(_clipDone, done)) _clipDone = null;
      await _s.disposeSource(src);
    }
  }

  @override
  Future<void> stopClip() async {
    final h = _clip, done = _clipDone;
    _clip = null;
    _clipDone = null;
    if (h != null && _s.isInitialized) {
      try {
        await _s.stop(h);
      } catch (_) {}
    }
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Releases the audio device (when the screen closes).
  Future<void> close() async {
    _session = false;
    await stopClip();
    await _failures?.cancel();
    _failures = null;
    _theme = _question = _wake = null;
    try {
      if (_s.isInitialized) await _s.deinitAsync();
    } catch (_) {}
  }

  @override
  Map<String, Object?> info() => {
    'engine': 'flutter_soloud',
    'mode': 'dream catcher',
    'sampleRate': synthRate,
    'bufferFrames': 2048,
    'promptVolume': promptVolume,
    'deviceStartFailures': _deviceFailures,
  };

  static void _guard(void Function() f) {
    try {
      f();
    } on SoLoudException catch (_) {}
  }
}
