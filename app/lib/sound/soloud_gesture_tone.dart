// The soft confirmation tone of the hands-free gestures (DECISIONS 245): the check-in's soft sine tones (rise over
// 0.15 s, gone by 0.9 s), quieter. A double clench answers with two low notes (A4, 0.3 s apart), as the two clenches;
// a glance with one higher note (E5). It plays through the session's own sound engine (flutter_soloud is one engine
// per app), so it needs nothing of its own and is silent when the session has no sound running; it never starts or
// stops the engine itself.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../detectors/gestures.dart';
import 'check_in_sound.dart' show toneRow;
import 'gesture_tone.dart';
import 'synth.dart';

const double clenchToneHz = 440, glanceToneHz = 659.25;

/// Quieter than the check-in's 0.12: a confirmation, not a cue.
const double gestureToneLevel = 0.08;

/// The two tones as WAV files (the check-in's recipe).
Uint8List gestureToneWav(GestureKind kind) =>
    wav16([kind == GestureKind.clench ? toneRow([clenchToneHz, clenchToneHz], gapS: 0.3) : toneRow([glanceToneHz])]);

class SoloudGestureTone implements GestureTone {
  SoLoud get _s => SoLoud.instance;
  final Map<GestureKind, AudioSource> _loaded = {};

  @override
  void confirm(GestureKind kind) => unawaited(_play(kind));

  Future<void> _play(GestureKind kind) async {
    try {
      if (!_s.isInitialized) return; // no session sound running: nothing to play through
      var src = _loaded[kind];
      if (src == null) {
        src = await _s.loadMem('gesture-${kind.name}.wav', gestureToneWav(kind));
        _loaded[kind] = src;
      }
      _s.play(src, volume: gestureToneLevel);
    } catch (_) {
      _loaded.remove(kind); // the engine was restarted under us: load again next time
    }
  }
}
