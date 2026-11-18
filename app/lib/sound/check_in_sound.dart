// The morning check-in's tones, as the laptop page plays them (scripts/web/morning.js `tone`): soft sine tones
// that rise over 0.15 s and fade by 0.9 s, so they do not startle with closed eyes. One low tone (G4) when the
// eyes close, a rising pair (G4 then C5, 0.55 s apart) to open them, one C5 at the end. Nothing else plays.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'synth.dart';

const double closeHz = 392, openHz = 523.25;

/// The page's level (gain 0.12 at the peak).
const double toneLevel = 0.12;

abstract class CheckInSound {
  /// Throws when the audio cannot start (the check-in then runs silently).
  Future<void> start();

  /// "Close your eyes" (one low tone).
  void close();

  /// "Open your eyes" (a rising pair).
  void open();

  /// The end of the recording part (one higher tone).
  void end();

  Future<void> stop();
}

/// One soft sine tone of the page: linear rise to 1 in 0.15 s, linear fade to 0 at 0.9 s, 1 s long.
Float32List softTone(double hz, {int sampleRate = synthRate}) {
  final n = sampleRate;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final env = t < 0.15 ? t / 0.15 : (t < 0.9 ? (0.9 - t) / 0.75 : 0.0);
    out[i] = env * math.sin(2 * math.pi * hz * t);
  }
  return out;
}

/// Tones one after another, [gapS] apart (overlapping tails add).
Float32List toneRow(List<double> hz, {double gapS = 0.55, int sampleRate = synthRate}) {
  final parts = [for (final f in hz) softTone(f, sampleRate: sampleRate)];
  final gap = (gapS * sampleRate).round();
  final out = Float32List(parts.first.length + gap * (parts.length - 1));
  for (var k = 0; k < parts.length; k++) {
    for (var i = 0; i < parts[k].length; i++) {
      out[k * gap + i] += parts[k][i];
    }
  }
  return out;
}

typedef _Tones = ({Uint8List close, Uint8List open, Uint8List end});

_Tones _make() => (
  close: wav16([toneRow([closeHz])]),
  open: wav16([toneRow([closeHz, openHz])]),
  end: wav16([toneRow([openHz])]),
);

class SoloudCheckInSound implements CheckInSound {
  SoLoud get _s => SoLoud.instance;
  late AudioSource _close, _open, _end;
  bool _running = false;

  @override
  Future<void> start() async {
    try {
      final m = await Isolate.run(_make);
      await _s.init(sampleRate: synthRate, bufferSize: 2048);
      _close = await _s.loadMem('close.wav', m.close);
      _open = await _s.loadMem('open.wav', m.open);
      _end = await _s.loadMem('end.wav', m.end);
      _running = true;
    } catch (_) {
      try {
        if (_s.isInitialized) await _s.deinitAsync();
      } catch (_) {}
      rethrow;
    }
  }

  void _play(AudioSource s) {
    if (!_running) return;
    try {
      _s.play(s, volume: toneLevel);
    } on SoLoudException catch (_) {}
  }

  @override
  void close() => _play(_close);
  @override
  void open() => _play(_open);
  @override
  void end() => _play(_end);

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await Future<void>.delayed(const Duration(milliseconds: 1200)); // let the last tone ring out
    try {
      await _s.deinitAsync();
    } catch (_) {}
  }
}

/// No sound: counts the tones, for tests and when the audio fails.
class SilentCheckInSound implements CheckInSound {
  final List<String> played = [];
  bool started = false, stopped = false;

  @override
  Future<void> start() async => started = true;
  @override
  void close() => played.add('close');
  @override
  void open() => played.add('open');
  @override
  void end() => played.add('end');
  @override
  Future<void> stop() async => stopped = true;
}
