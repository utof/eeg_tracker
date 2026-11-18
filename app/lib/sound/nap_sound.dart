// The nap coach's sound on flutter_soloud (DECISIONS row 175): only the wake cue, alpha-theta's three rising notes
// (also the dream catcher's end), played quietly first and a little louder every 20 seconds until "I'm awake". No
// sound while you fall asleep. Not heard yet: the first volume is the dream catcher's cue level, a guess until the
// owner listens (the phone's media volume sets the rest).
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../nap/audio.dart';
import 'alpha_theta_sound.dart' show wakeTone;
import 'synth.dart';

Uint8List _make() => wav16([wakeTone()]);

class SoloudNapSound implements NapSound {
  SoLoud get _s => SoLoud.instance;
  AudioSource? _wake;
  bool _on = false;
  int _deviceFailures = 0;
  StreamSubscription<AudioDeviceStartFailure>? _failures;

  @override
  double get firstVolume => toneGain(cuePartials, cueLevel);

  @override
  Future<void> start() async {
    try {
      final wav = await Isolate.run(_make);
      if (!_s.isInitialized) await _s.init(sampleRate: synthRate, bufferSize: 2048);
      _failures ??= _s.audioDeviceStartFailures.listen((_) {
        _deviceFailures++;
        unawaited(_s.startAudioDevice().catchError((Object _) {}));
      });
      _wake = await _s.loadMem('nap-wake.wav', wav);
      _s.setGlobalVolume(1);
      _on = true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  void wake(double volume) {
    final w = _wake;
    if (!_on || w == null) return;
    try {
      _s.play(w, volume: volume.clamp(0.0, 1.0));
    } on SoLoudException catch (_) {}
  }

  @override
  Future<void> stop() async {
    final wasOn = _on;
    _on = false;
    if (wasOn && _s.isInitialized) {
      try {
        _s.fadeGlobalVolume(0, const Duration(milliseconds: 800));
      } on SoLoudException catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    await _failures?.cancel();
    _failures = null;
    _wake = null;
    try {
      if (_s.isInitialized) await _s.deinitAsync();
    } catch (_) {}
  }

  @override
  Map<String, Object?> info() => {
    'engine': 'flutter_soloud',
    'mode': 'nap coach',
    'sampleRate': synthRate,
    'firstVolume': firstVolume,
    'deviceStartFailures': _deviceFailures,
  };
}
