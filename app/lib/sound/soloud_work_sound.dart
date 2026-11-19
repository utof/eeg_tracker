// The work session's sounds through flutter_soloud (DECISIONS 444): the check-in's soft sine tones (rise over 0.15 s,
// gone by 0.9 s). The chime is two falling notes (C5, then G4, 0.45 s apart) at the check-in's 0.12; the cues are its
// close (low) and open (higher) tones. The engine starts only to play and stops a few seconds later, so a work day
// does not keep the phone's audio running for hours between hints.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'check_in_sound.dart' show toneRow, closeHz, openHz;
import 'synth.dart';
import 'work_sound.dart';

const double chimeHighHz = 523.25, chimeLowHz = 392.0, workToneLevel = 0.12;

Uint8List workChimeWav() => wav16([toneRow([chimeHighHz, chimeLowHz], gapS: 0.45)]);

class SoloudWorkSound implements WorkSound {
  SoLoud get _s => SoLoud.instance;
  Timer? _off;
  bool _mine = false;
  final Map<String, AudioSource> _loaded = {};

  Future<void> _play(String name, Uint8List wav) async {
    try {
      _off?.cancel();
      if (!_s.isInitialized) {
        await _s.init(sampleRate: synthRate, bufferSize: 2048);
        _mine = true;
      }
      final src = _loaded[name] ??= await _s.loadMem(name, wav);
      _s.play(src, volume: workToneLevel);
      if (_mine) _off = Timer(const Duration(seconds: 4), () => unawaited(_release()));
    } catch (_) {
      _loaded.remove(name); // the engine was restarted under us: load again next time
      // no sound this time; the hint is on screen and in the notification
    }
  }

  Future<void> _release() async {
    _loaded.clear();
    try {
      if (_mine && _s.isInitialized) await _s.deinitAsync();
    } catch (_) {}
    _mine = false;
  }

  @override
  Future<void> chime() => _play('work-chime.wav', workChimeWav());

  @override
  Future<void> cue({required bool close}) => _play(close ? 'work-close.wav' : 'work-open.wav', wav16([toneRow([close ? closeHz : openHz])]));

  @override
  Future<void> stop() async {
    _off?.cancel();
    await _release();
  }
}
