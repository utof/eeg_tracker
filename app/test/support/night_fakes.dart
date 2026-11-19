// Fakes for the night's live model and sound cues in tests (lucid_live_test.dart, memory_live_test.dart): ONNX cannot
// run in `flutter test`, so a scripted model says which stage each epoch is; a fake bell records each cue's gain; a
// synthetic signal makes sideways eye movements with a quiet back of the head.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eeg_tracker/lucid/bell.dart';
import 'package:eeg_tracker/recorder/chunk_writer.dart';
import 'package:eeg_tracker/sleep/live_prep.dart' show LiveWindow;
import 'package:eeg_tracker/sleep/live_stager.dart';

/// Every epoch is the stage [script] says (top probability 0.9); [fail] makes every call throw.
class ScriptedModel implements LiveModel {
  ScriptedModel(this.script);
  final String Function(int epoch) script;
  Object? fail;
  bool closed = false;

  @override
  Future<Float64List> probabilities(Float32List x, int epochs, int runs, {required int first}) async {
    if (fail != null) throw fail!;
    const names = ['W', 'N1', 'N2', 'N3', 'R'];
    final p = Float64List(epochs * 5);
    for (var e = 0; e < epochs; e++) {
      for (var j = 0; j < 5; j++) {
        p[e * 5 + j] = 0.025;
      }
      p[e * 5 + names.indexOf(script(first + e))] = 0.9;
    }
    return p;
  }

  @override
  Future<void> close() async => closed = true;
}

class FakeBell implements CueBell {
  final List<double> gains = [];
  final List<String> files = [];
  Object? fail;

  @override
  Future<bool> play(File cue, double gain) async {
    if (fail != null) throw fail!;
    gains.add(gain);
    files.add(cue.path.split('/').last);
    return true;
  }

  @override
  Future<({int volume, int max})?> mediaVolume() async => (volume: 7, max: 15);
}

Future<Float32List> zeros(LiveWindow w) async => Float32List(w.epochs * 3840 * 4);

/// 2026-11-25 01:00:00 local: the night's first sample.
final int startMs = DateTime(2026, 11, 25, 1).millisecondsSinceEpoch;

/// Sample [i] in volts: a quiet back of the head, the temples held apart by a sideways eye movement each 20 s, back
/// 1 s later (a burst of two movements; none with [eyes] false, as in deep sleep); from [jawFrom] seconds on a little
/// jaw muscle each 7 s.
Sample sampleAt(int i, {double? jawFromS, bool eyes = true}) {
  final t = i / 250;
  final inLook = eyes && t % 20 >= 10 && t % 20 < 11;
  final eye = inLook ? 60.0 : 0.0;
  var t3 = 20000 + eye + 2 * math.sin(i * 0.7), t4 = -15000 - eye + 2 * math.cos(i * 0.9);
  if (jawFromS != null && t >= jawFromS && t % 7 < 1) {
    t3 += 40 * math.sin(i * 2.1);
    t4 += 40 * math.sin(i * 2.3);
  }
  return (
    pack: i % 2048,
    o1: (12000 + 10 * math.sin(i * 0.25)) * 1e-6,
    o2: (-8000 + 8 * math.cos(i * 0.1)) * 1e-6,
    t3: t3 * 1e-6,
    t4: t4 * 1e-6,
  );
}
