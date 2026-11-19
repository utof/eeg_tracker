// The three AnySleep runs on ONNX Runtime through flutter_onnxruntime (DECISIONS row 95). The plugin runs each
// call on a background thread of its own, so the screen stays responsive while a night is scored. The models are
// assets (assets/models/, made by scripts/export_anysleep_onnx.py). ONNX Runtime needs a file, so each run is
// copied once into `files/models/`, under a name that carries a hash of its bytes: an app update with re-exported
// models never reuses an old copy (the plugin's own asset cache is keyed by file name only).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'model.dart';
import 'prep.dart' show epochSamples;

const int anySleepRuns = 3;

String anySleepAsset(int run) => 'assets/models/anysleep-run$run.onnx';

/// The models folder for the app's recordings folder.
Directory modelsDirFor(String recordingsDir) => Directory('${Directory(recordingsDir).parent.path}/models');

/// FNV-1a, 32 bit: enough to tell two exports apart.
String contentKey(Uint8List bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  return '${bytes.length}-${h.toRadixString(16).padLeft(8, '0')}';
}

/// The model file for [run] in [dir], copied from the assets when missing; older copies of that run are removed.
Future<File> modelFile(int run, Directory dir, {AssetBundle? bundle}) async {
  final data = await (bundle ?? rootBundle).load(anySleepAsset(run));
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final file = File('${dir.path}/anysleep-run$run-${contentKey(bytes)}.onnx');
  if (file.existsSync() && file.lengthSync() == bytes.length) return file;
  dir.createSync(recursive: true);
  for (final old in dir.listSync().whereType<File>()) {
    if (old.uri.pathSegments.last.startsWith('anysleep-run$run-')) old.deleteSync();
  }
  final tmp = File('${file.path}.tmp');
  tmp.writeAsBytesSync(bytes, flush: true);
  tmp.renameSync(file.path);
  return file;
}

class OnnxStageRun implements StageRun {
  OnnxStageRun._(this._session);
  final OrtSession _session;

  /// Opens run [run] (1-3). Without the memory arena: ONNX Runtime then frees each piece's activations instead of
  /// keeping the largest piece's worth for the session's lifetime.
  static Future<OnnxStageRun> open(int run, {required Directory modelsDir}) async {
    final file = await modelFile(run, modelsDir);
    final session = await OnnxRuntime().createSession(
      file.path,
      options: OrtSessionOptions(intraOpNumThreads: 4, useArena: false),
    );
    return OnnxStageRun._(session);
  }

  @override
  Future<Float32List> logits(Float32List x, int epochs, {Float32List? means}) async =>
      (await _run(x, epochs, 0, epochs, means, const ['logits'])).single;

  @override
  Future<SkipSums> sums(Float32List x, int epochs, {required int from, required int to}) async {
    final out = await _run(x, epochs, from, to, null, const ['sums', 'counts']);
    return (sums: out[0], counts: out[1]);
  }

  /// One model call (inputs as scripts/export_anysleep_onnx.py `two_pass_module`): [x] weighed by [means] or by its own
  /// averages, its features summed over epochs [from, to); returns the outputs [names].
  Future<List<Float32List>> _run(
    Float32List x,
    int epochs,
    int from,
    int to,
    Float32List? means,
    List<String> names,
  ) async {
    final inputs = <String, OrtValue>{};
    Map<String, OrtValue>? out;
    try {
      inputs['eeg'] = await OrtValue.fromList(x, [1, epochs * epochSamples, 4]);
      inputs['keep'] = await OrtValue.fromList(Float32List.fromList([from.toDouble(), to.toDouble()]), [2]);
      inputs['means'] = await OrtValue.fromList(means ?? Float32List(4 * meansWidth), [4, meansWidth]);
      inputs['use_means'] = await OrtValue.fromList(Float32List.fromList([means == null ? 0 : 1]), [1]);
      out = await _session.run(inputs);
      return [
        for (final n in names)
          Float32List.fromList([for (final v in await out[n]!.asFlattenedList()) (v as num).toDouble()]),
      ];
    } finally {
      for (final v in [...inputs.values, ...?out?.values]) {
        await v.dispose();
      }
    }
  }

  Future<void> close() => _session.close();
}
