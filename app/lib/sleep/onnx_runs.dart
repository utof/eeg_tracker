// The three AnySleep runs on ONNX Runtime through flutter_onnxruntime (DECISIONS row 95). The plugin runs each
// call on a background thread of its own, so the screen stays responsive while a night is scored. The models are
// assets (assets/models/, made by scripts/export_anysleep_onnx.py); the plugin copies one out of the APK the first
// time it is opened.
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'model.dart';
import 'prep.dart' show epochSamples;

const int anySleepRuns = 3;

String anySleepAsset(int run) => 'assets/models/anysleep-run$run.onnx';

class OnnxStageRun implements StageRun {
  OnnxStageRun._(this._session);
  final OrtSession _session;

  /// Opens run [run] (1-3). Without the memory arena: ONNX Runtime then frees each piece's activations instead of
  /// keeping the largest piece's worth for the session's lifetime.
  static Future<OnnxStageRun> open(int run) async {
    final session = await OnnxRuntime().createSessionFromAsset(
      anySleepAsset(run),
      options: OrtSessionOptions(intraOpNumThreads: 4, useArena: false),
    );
    return OnnxStageRun._(session);
  }

  @override
  Future<Float32List> logits(Float32List x, int epochs) async {
    final input = await OrtValue.fromList(x, [1, epochs * epochSamples, 4]);
    Map<String, OrtValue>? out;
    try {
      out = await _session.run({'eeg': input});
      final flat = await out['logits']!.asFlattenedList();
      return Float32List.fromList([for (final v in flat) (v as num).toDouble()]);
    } finally {
      await input.dispose();
      for (final v in out?.values ?? const <OrtValue>[]) {
        await v.dispose();
      }
    }
  }

  Future<void> close() => _session.close();
}
