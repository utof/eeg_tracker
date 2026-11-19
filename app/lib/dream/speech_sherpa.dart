// The phone's speech-to-text (DECISIONS rows 250-252): sherpa-onnx 2.0.1 (Apache-2.0, k2-fsa) with the Parakeet
// model downloaded into `files/models/` and Silero's voice detector (MIT, 0.6 MB, in the APK). Everything runs in
// one background isolate per batch: it loads the model once, then for each answer reads the WAV, raises a quiet
// answer, keeps the parts with a voice (each widened by a quarter second) and recognises them; no voice: no words.
// Closing lets the answer under way finish, frees the model and ends the isolate, so the memory (about 1 GB) goes
// back. The laptop runs the same steps on the same engine and model: scripts/dream_text_check.py.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'speech_audio.dart';
import 'speech_model.dart';
import 'text_runner.dart';

/// The voice detector's asset; copied to `files/models/` once (the engine needs a file).
const String vadAsset = 'assets/models/silero_vad.onnx';

/// Threads for the recognizer: the Snapdragon 888's four big cores.
const int speechThreads = 4;

/// The voice detector's file in [modelsDir], copied from the APK when missing or of another size.
Future<File> vadFile(Directory modelsDir, {AssetBundle? bundle}) async {
  final data = await (bundle ?? rootBundle).load(vadAsset);
  final f = File('${modelsDir.path}/silero_vad.onnx');
  if (f.existsSync() && f.lengthSync() == data.lengthInBytes) return f;
  modelsDir.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsBytesSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
  tmp.renameSync(f.path);
  return f;
}

class _Start {
  const _Start(this.reply, this.dir, this.vad, this.threads);
  final SendPort reply;
  final String dir;
  final String vad;
  final int threads;
}

class SherpaTranscriber implements Transcriber {
  SherpaTranscriber._(this.model, this._isolate, this._to, this._from, this._replies);

  @override
  final String model;
  final Isolate _isolate;
  final SendPort _to;
  final ReceivePort _from;
  final StreamIterator<Object?> _replies;
  Completer<Heard>? _pending;
  bool _closed = false;

  /// Loads [spec]'s model from [model] and the voice detector [vad] in a new isolate. Throws when it cannot.
  static Future<SherpaTranscriber> open(SpeechModelStore model, File vad, {int threads = speechThreads}) async {
    if (!model.ready) throw StateError('the speech model is not on the phone');
    final from = ReceivePort();
    final replies = StreamIterator<Object?>(from);
    final iso = await Isolate.spawn(_main, _Start(from.sendPort, model.dir.path, vad.path, threads), debugName: 'speech');
    final ok = await replies.moveNext() ? replies.current : 'the speech isolate ended';
    if (ok is! SendPort) {
      iso.kill();
      from.close();
      throw StateError('$ok');
    }
    final t = SherpaTranscriber._(model.spec.id, iso, ok, from, replies);
    unawaited(t._listen());
    return t;
  }

  Future<void> _listen() async {
    while (await _replies.moveNext()) {
      final r = _replies.current, p = _pending;
      _pending = null;
      if (p == null || p.isCompleted) continue;
      if (r case (final String text, final double audioS, final double voiceS)) {
        p.complete(Heard(text: text, audioS: audioS, voiceS: voiceS));
      } else {
        p.completeError(StateError('$r'));
      }
    }
    final p = _pending;
    if (p != null && !p.isCompleted) p.completeError(const TranscriberClosed());
  }

  @override
  Future<Heard> hear(String wavPath) {
    if (_closed) return Future.error(const TranscriberClosed());
    final p = _pending = Completer<Heard>();
    _to.send(wavPath);
    return p.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final p = _pending;
    if (p != null && !p.isCompleted) p.completeError(const TranscriberClosed());
    _to.send(null); // frees the model after the answer under way, then the isolate ends
    // should it hang in native code, the isolate is killed at its next Dart step
    Timer(const Duration(seconds: 60), () {
      _isolate.kill(priority: Isolate.immediate);
      _from.close();
    });
  }
}

// ---- inside the isolate ----

void _main(_Start s) {
  final inbox = ReceivePort();
  final so.OfflineRecognizer rec;
  try {
    so.initBindings();
    final d = s.dir;
    rec = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          transducer: so.OfflineTransducerModelConfig(
            encoder: '$d/encoder.int8.onnx',
            decoder: '$d/decoder.int8.onnx',
            joiner: '$d/joiner.int8.onnx',
          ),
          tokens: '$d/tokens.txt',
          modelType: 'nemo_transducer',
          numThreads: s.threads,
          debug: false,
        ),
      ),
    );
  } catch (e) {
    s.reply.send('$e');
    inbox.close();
    return;
  }
  s.reply.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg is! String) {
      rec.free();
      inbox.close();
      Isolate.exit();
    }
    try {
      s.reply.send(_hear(rec, s.vad, msg));
    } catch (e) {
      s.reply.send(e is FormatException ? 'the recording is not a 16 kHz WAV (${e.message})' : '$e');
    }
  });
}

(String, double, double) _hear(so.OfflineRecognizer rec, String vadPath, String wavPath) {
  final x = levelUp(readWav16k(File(wavPath)));
  final audioS = x.length / speechRate;
  final spans = voicedSpans(_voiceParts(x, vadPath), x.length);
  final voiced = joinVoiced([for (final (lo, hi) in spans) Float32List.sublistView(x, lo, hi)]);
  final voiceS = spans.fold(0, (n, s) => n + s.$2 - s.$1) / speechRate;
  if (voiced.length < speechRate ~/ 5) return ('', audioS, voiceS);
  final stream = rec.createStream();
  try {
    stream.acceptWaveform(samples: voiced, sampleRate: speechRate);
    rec.decode(stream);
    return (rec.getResult(stream).text.trim(), audioS, voiceS);
  } finally {
    stream.free();
  }
}

/// Silero's voiced parts of [x] as (first sample, samples); the same settings as the laptop check.
List<(int, int)> _voiceParts(Float32List x, String vadPath) {
  final vad = so.VoiceActivityDetector(
    config: so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: vadPath,
        threshold: 0.4,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 30,
      ),
      sampleRate: speechRate,
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  try {
    const window = 512;
    final padded = Float32List(x.length + window)..setAll(0, x);
    for (var i = 0; i + window <= padded.length; i += window) {
      vad.acceptWaveform(Float32List.sublistView(padded, i, i + window));
    }
    vad.flush();
    final out = <(int, int)>[];
    while (!vad.isEmpty()) {
      final seg = vad.front();
      out.add((seg.start, seg.samples.length));
      vad.pop();
    }
    return out;
  } finally {
    vad.free();
  }
}
